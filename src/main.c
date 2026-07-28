/* Blackout — 全屏大字待办提醒
 *
 * 按热键（默认 Ctrl+Shift+`）整屏变黑，白色巨大文字逐行显示待办；
 * 全屏本身就是编辑器，直接打字增删；Esc 保存并隐藏。常驻托盘。
 *
 * 设计目标：单 exe、零依赖、隐藏时工作集只有几 MB、空闲 CPU 0%。
 *
 * https://github.com/CharlesGuooo/blackout   MIT License
 */

#define WINVER       0x0A00
#define _WIN32_WINNT 0x0A00

#include <windows.h>
#include <shellapi.h>
#include "resource.h"

/* ------------------------------------------------------------------ 常量 */

#define APP_CLASS        L"BlackoutOverlayWnd"
#define APP_TITLE        L"Blackout"
#define MUTEX_NAME       L"Local\\BlackoutSingleton"
#define RUNKEY_PATH      L"Software\\Microsoft\\Windows\\CurrentVersion\\Run"
#define RUNKEY_VALUE     L"Blackout"

#define WM_TRAY          (WM_APP + 1)
#define HOTKEY_ID        1
#define TIMER_AUTOSAVE   1
#define AUTOSAVE_MS      3000
#define EDIT_ID          1000

#define IDM_SHOW         100
#define IDM_OPENTXT      101
#define IDM_STARTUP      102
#define IDM_EXIT         103

#define PAD_X_PCT        6   /* 内容区左右留白，占显示器宽度百分比 */
#define PAD_Y_PCT        4   /* 内容区上下留白，占显示器高度百分比 */
#define FIT_ATTEMPTS     8   /* 字号收敛的最大迭代次数 */

/* ------------------------------------------------------------------ 全局 */

static HINSTANCE g_inst;
static HWND      g_wnd;
static HWND      g_edit;
static WNDPROC   g_editProc;
static HBRUSH    g_black;
static HFONT     g_font;
static int       g_fontSize;
static int       g_lineH = 1;
static int       g_lastLines = -1;
static BOOL      g_visible;
static BOOL      g_dirty;
static DWORD     g_showTick;     /* 弹出时刻，用于抑制刚弹出就被误判为失焦 */
static UINT      g_msgTaskbarCreated;
static NOTIFYICONDATAW g_nid;
static FILETIME  g_fileTime;
static RECT      g_content;      /* 内容区，窗口客户区坐标 */

static WCHAR g_pathExe[MAX_PATH];
static WCHAR g_pathTxt[MAX_PATH];
static WCHAR g_pathIni[MAX_PATH];
static WCHAR g_pathTmp[MAX_PATH];

static WCHAR g_fontName[LF_FACESIZE] = L"Microsoft YaHei UI";
static int   g_bold    = 1;
static int   g_minSize = 24;
static int   g_maxSize = 400;   /* 上限放宽，实际大小基本由"最长一行的宽度"决定 */
static UINT  g_hkMods  = MOD_CONTROL | MOD_SHIFT;
static UINT  g_hkVk    = VK_OEM_3;
static WCHAR g_hkText[64] = L"Ctrl+Shift+`";

/* ------------------------------------------------------- 小工具 / 内存 */

static void *xalloc(SIZE_T n)
{
    return HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, n);
}

static void xfree(void *p)
{
    if (p) HeapFree(GetProcessHeap(), 0, p);
}

static void trim_working_set(void)
{
    SetProcessWorkingSetSize(GetCurrentProcess(), (SIZE_T)-1, (SIZE_T)-1);
}

/* 动态取 SetProcessDpiAwarenessContext：它只存在于 Win10 1703+。静态导入的话
 * 更老的系统上 exe 会直接加载失败，用户看到的是一句看不懂的报错而不是程序。
 * 取不到就算了——降级成 DPI 不感知，高分屏上字会糊，但程序照常能用。 */
static void enable_per_monitor_dpi(void)
{
    typedef DPI_AWARENESS_CONTEXT (WINAPI *PFN_SetCtx)(DPI_AWARENESS_CONTEXT);
    HMODULE u32 = GetModuleHandleW(L"user32.dll");
    PFN_SetCtx fn;

    if (!u32) return;
    fn = (PFN_SetCtx)(void *)GetProcAddress(u32, "SetProcessDpiAwarenessContext");
    if (fn) fn(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
}

static int clampi(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* ------------------------------------------------------------ 文本处理 */

/* 把裸 LF / 裸 CR 统一成 CRLF。EDIT 控件遇到裸 LF 会显示成方块。
 * 返回新分配的缓冲区，调用方负责 xfree。 */
static WCHAR *normalize_newlines(const WCHAR *src)
{
    SIZE_T n = 0, i;
    WCHAR *out;

    for (i = 0; src[i]; i++) n++;
    out = (WCHAR *)xalloc((n * 2 + 1) * sizeof(WCHAR));
    if (!out) return NULL;

    for (i = 0, n = 0; src[i]; ) {
        if (src[i] == L'\r') {
            out[n++] = L'\r'; out[n++] = L'\n';
            i += (src[i + 1] == L'\n') ? 2 : 1;
        } else if (src[i] == L'\n') {
            out[n++] = L'\r'; out[n++] = L'\n';
            i += 1;
        } else {
            out[n++] = src[i++];
        }
    }
    out[n] = 0;
    return out;
}

/* UTF-8 字节 -> UTF-16。带 BOM 会被跳过；非法 UTF-8 回退到 ANSI 代码页。
 * 返回新分配的缓冲区，调用方负责 xfree。 */
static WCHAR *utf8_to_wide(const BYTE *bytes, DWORD len)
{
    const char *p = (const char *)bytes;
    int need;
    WCHAR *w;

    if (len >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        p += 3;
        len -= 3;
    }
    if (len == 0) {
        w = (WCHAR *)xalloc(sizeof(WCHAR));
        return w;
    }

    need = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, p, (int)len, NULL, 0);
    if (need > 0) {
        w = (WCHAR *)xalloc(((SIZE_T)need + 1) * sizeof(WCHAR));
        if (!w) return NULL;
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, p, (int)len, w, need);
        w[need] = 0;
        return w;
    }

    /* 不是合法 UTF-8：当成本地代码页（老记事本存的 ANSI） */
    need = MultiByteToWideChar(CP_ACP, 0, p, (int)len, NULL, 0);
    if (need <= 0) return NULL;
    w = (WCHAR *)xalloc(((SIZE_T)need + 1) * sizeof(WCHAR));
    if (!w) return NULL;
    MultiByteToWideChar(CP_ACP, 0, p, (int)len, w, need);
    w[need] = 0;
    return w;
}

/* 逐行遍历 CRLF 文本。返回逻辑行数（含结尾空行）。 */
static int count_lines(const WCHAR *t)
{
    int lines = 1;
    for (; *t; t++)
        if (*t == L'\n') lines++;
    return lines;
}

/* ------------------------------------------------------------ 文件读写 */

static WCHAR *read_text_file(const WCHAR *path, FILETIME *outTime)
{
    HANDLE h;
    DWORD size, got = 0;
    BYTE *buf;
    WCHAR *raw, *norm;

    h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                    NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return NULL;

    if (outTime) GetFileTime(h, NULL, NULL, outTime);

    size = GetFileSize(h, NULL);
    if (size == INVALID_FILE_SIZE || size > (16u << 20)) {
        CloseHandle(h);
        return NULL;
    }

    buf = (BYTE *)xalloc(size + 1);
    if (!buf) { CloseHandle(h); return NULL; }
    if (size && !ReadFile(h, buf, size, &got, NULL)) got = 0;
    CloseHandle(h);

    raw = utf8_to_wide(buf, got);
    xfree(buf);
    if (!raw) return NULL;

    norm = normalize_newlines(raw);
    xfree(raw);
    return norm;
}

/* 先写 .tmp 再原子替换，避免写一半掉电导致清单丢失。 */
static BOOL write_text_file(const WCHAR *path, const WCHAR *tmpPath, const WCHAR *text)
{
    static const BYTE bom[3] = { 0xEF, 0xBB, 0xBF };
    HANDLE h;
    int need;
    char *utf8 = NULL;
    DWORD written;
    BOOL ok = TRUE;

    need = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
    if (need <= 0) return FALSE;
    need -= 1; /* 不写结尾的 NUL */

    if (need > 0) {
        utf8 = (char *)xalloc((SIZE_T)need + 1);
        if (!utf8) return FALSE;
        WideCharToMultiByte(CP_UTF8, 0, text, -1, utf8, need + 1, NULL, NULL);
    }

    h = CreateFileW(tmpPath, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) { xfree(utf8); return FALSE; }

    if (!WriteFile(h, bom, sizeof(bom), &written, NULL)) ok = FALSE;
    if (ok && need > 0 && !WriteFile(h, utf8, (DWORD)need, &written, NULL)) ok = FALSE;
    CloseHandle(h);
    xfree(utf8);

    if (!ok) { DeleteFileW(tmpPath); return FALSE; }
    return MoveFileExW(tmpPath, path, MOVEFILE_REPLACE_EXISTING);
}

/* ---------------------------------------------------------------- 字号 */

static HFONT make_font(int px)
{
    LOGFONTW lf;
    ZeroMemory(&lf, sizeof(lf));
    lf.lfHeight  = -px;               /* 负值 = 字符高度，不含内部行距 */
    lf.lfWeight  = g_bold ? FW_SEMIBOLD : FW_NORMAL;
    lf.lfCharSet = DEFAULT_CHARSET;
    lf.lfQuality = CLEARTYPE_QUALITY;
    lstrcpynW(lf.lfFaceName, g_fontName, LF_FACESIZE);
    return CreateFontIndirectW(&lf);
}

/* 从 g_maxSize 起，反复按"高度约束 / 宽度约束"比例收缩，直到内容塞得进
 * 内容区。因为总是从上限起只缩不放，结果是确定的：能放下的最大字号。
 * 返回字号；*outFont 为对应字体（调用方接管），*outLineH 为实际行高。 */
static int calc_font_size(const WCHAR *text, int cw, int ch,
                          int *outLines, int *outLineH, HFONT *outFont)
{
    HDC   dc = CreateCompatibleDC(NULL);
    HFONT f  = NULL;
    int   size = g_maxSize;
    int   lines = count_lines(text);
    int   lineH = 1;
    int   fitW;
    int   attempt;

    if (cw < 1) cw = 1;
    if (ch < 1) ch = 1;

    /* 宽度留 5% 余量：这里用 GDI 的 GetTextExtentPoint32W 测量，而 EDIT 控件
     * 实际排版走 DirectWrite，同一字体的推进量差约 1%。按 100% 宽度收敛的话，
     * "算出来刚好塞得下"的行会被控件判定为超宽——关闭自动换行前是折行，
     * 关闭之后会直接横向滚出屏幕看不见，所以余量必须给足。
     * 高度一侧没有这个歧义，仍按 ch 收敛。 */
    fitW = cw - cw / 20;
    if (fitW < 1) fitW = 1;

    for (attempt = 0; attempt < FIT_ATTEMPTS; attempt++) {
        TEXTMETRICW tm;
        HGDIOBJ old;
        const WCHAR *p;
        int maxW = 0, need, sH, sW, ns;

        if (f) DeleteObject(f);
        f = make_font(size);
        old = SelectObject(dc, f);

        GetTextMetricsW(dc, &tm);
        lineH = tm.tmHeight + tm.tmExternalLeading;
        if (lineH < 1) lineH = 1;

        for (p = text; ; ) {
            const WCHAR *e = p;
            SIZE sz;
            while (*e && *e != L'\r' && *e != L'\n') e++;
            if (e > p && GetTextExtentPoint32W(dc, p, (int)(e - p), &sz)) {
                if (sz.cx > maxW) maxW = sz.cx;
            }
            if (!*e) break;
            p = (e[0] == L'\r' && e[1] == L'\n') ? e + 2 : e + 1;
        }

        SelectObject(dc, old);

        need = lines * lineH;
        if ((need <= ch && maxW <= fitW) || size <= g_minSize) break;

        sH = (need > ch)    ? MulDiv(size, ch, need)    : size;
        sW = (maxW > fitW)  ? MulDiv(size, fitW, maxW)  : size;
        ns = (sH < sW) ? sH : sW;
        if (ns >= size) ns = size - 1;
        ns = clampi(ns, g_minSize, g_maxSize);
        if (ns == size) break;
        size = ns;
    }

    DeleteDC(dc);
    *outFont  = f;
    *outLines = lines;
    *outLineH = lineH;
    return size;
}

/* 重算字号并把 EDIT 控件摆到内容区中间垂直居中的位置。
 * allowGrow=FALSE 时只缩不放，用于"打字时字号不乱跳"。 */
static void refit(BOOL allowGrow)
{
    int cw = g_content.right - g_content.left;
    int ch = g_content.bottom - g_content.top;
    int len, size, lines, lineH, totalH, y;
    WCHAR *buf;
    HFONT f = NULL;

    if (!g_edit || cw < 1 || ch < 1) return;

    len = GetWindowTextLengthW(g_edit);
    buf = (WCHAR *)xalloc(((SIZE_T)len + 2) * sizeof(WCHAR));
    if (!buf) return;
    GetWindowTextW(g_edit, buf, len + 1);

    size = calc_font_size(buf, cw, ch, &lines, &lineH, &f);
    xfree(buf);

    if (!allowGrow && g_font && size > g_fontSize) {
        if (f) DeleteObject(f);
        size  = g_fontSize;
        lineH = g_lineH;
    } else if (f) {
        HFONT old = g_font;
        g_font = f;
        g_fontSize = size;
        g_lineH = lineH;
        SendMessageW(g_edit, WM_SETFONT, (WPARAM)g_font, TRUE);
        if (old) DeleteObject(old);
    }

    /* 多给半行：g_lineH 来自内存 DC 的 GetTextMetricsW，和控件实际行高可能
     * 差几个像素。差一点点就会让最后一行装不下，EM_SCROLLCARET 随即把内容
     * 整体上滚，第一行被顶出屏幕——这正是之前"第一行不显示"的成因。
     * 多出来的高度只是控件底部的黑边。 */
    totalH = lines * g_lineH + g_lineH / 2;
    if (totalH > ch) totalH = ch;
    if (totalH < g_lineH) totalH = g_lineH;
    y = g_content.top + (ch - totalH) / 2;

    MoveWindow(g_edit, g_content.left, y, cw, totalH, TRUE);
    SendMessageW(g_edit, EM_SCROLLCARET, 0, 0);
}

/* ------------------------------------------------------------ 加载/保存 */

static void save_if_dirty(void)
{
    int len;
    WCHAR *buf;

    if (!g_dirty || !g_edit) return;

    len = GetWindowTextLengthW(g_edit);
    buf = (WCHAR *)xalloc(((SIZE_T)len + 2) * sizeof(WCHAR));
    if (!buf) return;
    GetWindowTextW(g_edit, buf, len + 1);

    if (write_text_file(g_pathTxt, g_pathTmp, buf)) {
        WIN32_FILE_ATTRIBUTE_DATA fad;
        g_dirty = FALSE;
        /* 记下自己写出去的时间戳，免得下次弹出时误判为"外部改动"而重载 */
        if (GetFileAttributesExW(g_pathTxt, GetFileExInfoStandard, &fad))
            g_fileTime = fad.ftLastWriteTime;
    }
    xfree(buf);
}

/* 文件被外部（比如记事本）改过才重新加载。 */
static void reload_if_changed(void)
{
    WIN32_FILE_ATTRIBUTE_DATA fad;
    WCHAR *text;

    if (!GetFileAttributesExW(g_pathTxt, GetFileExInfoStandard, &fad)) return;
    if (CompareFileTime(&fad.ftLastWriteTime, &g_fileTime) == 0) return;

    text = read_text_file(g_pathTxt, &g_fileTime);
    if (!text) return;

    SetWindowTextW(g_edit, text);
    xfree(text);
    g_dirty = FALSE;
    g_lastLines = -1;
}

/* --------------------------------------------------------- 显示 / 隐藏 */

static void layout_to_cursor_monitor(void)
{
    POINT pt;
    HMONITOR mon;
    MONITORINFO mi;
    int mw, mh;

    GetCursorPos(&pt);
    mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(mon, &mi)) return;

    /* 用 rcMonitor 而非 rcWork —— 连任务栏一起盖住 */
    mw = mi.rcMonitor.right - mi.rcMonitor.left;
    mh = mi.rcMonitor.bottom - mi.rcMonitor.top;

    SetWindowPos(g_wnd, HWND_TOPMOST, mi.rcMonitor.left, mi.rcMonitor.top,
                 mw, mh, SWP_NOACTIVATE);

    g_content.left   = mw * PAD_X_PCT / 100;
    g_content.top    = mh * PAD_Y_PCT / 100;
    g_content.right  = mw - g_content.left;
    g_content.bottom = mh - g_content.top;
}

static void show_overlay(void)
{
    int len;

    g_showTick = GetTickCount();
    reload_if_changed();
    layout_to_cursor_monitor();
    refit(TRUE);
    g_lastLines = -1;

    g_visible = TRUE;
    ShowWindow(g_wnd, SW_SHOW);
    SetForegroundWindow(g_wnd);
    SetFocus(g_edit);

    len = GetWindowTextLengthW(g_edit);
    SendMessageW(g_edit, EM_SETSEL, (WPARAM)len, (LPARAM)len);
    SendMessageW(g_edit, EM_SCROLLCARET, 0, 0);

    SetTimer(g_wnd, TIMER_AUTOSAVE, AUTOSAVE_MS, NULL);
    g_showTick = GetTickCount();
}

static void hide_overlay(void)
{
    if (!g_visible) return;
    g_visible = FALSE;
    save_if_dirty();
    KillTimer(g_wnd, TIMER_AUTOSAVE);
    ShowWindow(g_wnd, SW_HIDE);
    trim_working_set();
}

static void toggle_overlay(void)
{
    if (g_visible) hide_overlay();
    else           show_overlay();
}

/* ---------------------------------------------------------------- 托盘 */

static void tray_add(void)
{
    ZeroMemory(&g_nid, sizeof(g_nid));
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd   = g_wnd;
    g_nid.uID    = 1;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAY;
    g_nid.hIcon  = LoadIconW(g_inst, MAKEINTRESOURCEW(IDI_APPICON));
    if (!g_nid.hIcon) g_nid.hIcon = LoadIconW(NULL, IDI_APPLICATION);
    wsprintfW(g_nid.szTip, L"Blackout — %s", g_hkText);
    Shell_NotifyIconW(NIM_ADD, &g_nid);
}

static BOOL startup_enabled(void)
{
    HKEY k;
    BOOL on = FALSE;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUNKEY_PATH, 0, KEY_QUERY_VALUE, &k)
        == ERROR_SUCCESS) {
        on = (RegQueryValueExW(k, RUNKEY_VALUE, NULL, NULL, NULL, NULL)
              == ERROR_SUCCESS);
        RegCloseKey(k);
    }
    return on;
}

static void startup_set(BOOL on)
{
    HKEY k;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, RUNKEY_PATH, 0, NULL, 0,
                        KEY_SET_VALUE, NULL, &k, NULL) != ERROR_SUCCESS)
        return;
    if (on) {
        WCHAR quoted[MAX_PATH + 2];
        wsprintfW(quoted, L"\"%s\"", g_pathExe);
        RegSetValueExW(k, RUNKEY_VALUE, 0, REG_SZ, (const BYTE *)quoted,
                       (lstrlenW(quoted) + 1) * sizeof(WCHAR));
    } else {
        RegDeleteValueW(k, RUNKEY_VALUE);
    }
    RegCloseKey(k);
}

static void show_tray_menu(void)
{
    POINT pt;
    HMENU m;
    WCHAR item[128];

    GetCursorPos(&pt);
    m = CreatePopupMenu();
    if (!m) return;

    wsprintfW(item, L"显示  (%s)", g_hkText);
    AppendMenuW(m, MF_STRING, IDM_SHOW, item);
    AppendMenuW(m, MF_STRING, IDM_OPENTXT, L"打开 todo.txt");
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    AppendMenuW(m, MF_STRING | (startup_enabled() ? MF_CHECKED : 0),
                IDM_STARTUP, L"开机自动启动");
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    AppendMenuW(m, MF_STRING, IDM_EXIT, L"退出");

    /* 经典规避：不先 SetForegroundWindow、不后 PostMessage，菜单不会消失 */
    SetForegroundWindow(g_wnd);
    TrackPopupMenu(m, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, 0, g_wnd, NULL);
    PostMessageW(g_wnd, WM_NULL, 0, 0);
    DestroyMenu(m);
}

/* ------------------------------------------------------------ 路径 / 配置 */

static void dir_of(const WCHAR *file, WCHAR *out)
{
    int i, cut = 0;
    lstrcpynW(out, file, MAX_PATH);
    for (i = 0; out[i]; i++)
        if (out[i] == L'\\' || out[i] == L'/') cut = i;
    out[cut] = 0;
}

static void join(WCHAR *out, const WCHAR *dir, const WCHAR *name)
{
    lstrcpynW(out, dir, MAX_PATH);
    lstrcatW(out, L"\\");
    lstrcatW(out, name);
}

static BOOL dir_writable(const WCHAR *dir)
{
    WCHAR probe[MAX_PATH];
    HANDLE h;
    join(probe, dir, L".blackout_write_test");
    h = CreateFileW(probe, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                    FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, NULL);
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    CloseHandle(h);
    return TRUE;
}

static void init_paths(void)
{
    WCHAR dir[MAX_PATH];

    GetModuleFileNameW(NULL, g_pathExe, MAX_PATH);
    dir_of(g_pathExe, dir);

    /* 便携优先：数据放 exe 旁边。放进了 Program Files 之类只读位置就回退，
     * 免得静默丢数据。 */
    if (!dir_writable(dir)) {
        WCHAR local[MAX_PATH];
        if (GetEnvironmentVariableW(L"LOCALAPPDATA", local, MAX_PATH)) {
            join(dir, local, L"Blackout");
            CreateDirectoryW(dir, NULL);
        }
    }

    join(g_pathTxt, dir, L"todo.txt");
    join(g_pathIni, dir, L"todo.ini");
    join(g_pathTmp, dir, L"todo.txt.tmp");
}

static BOOL istr_has(const WCHAR *hay, const WCHAR *needle)
{
    int nl = lstrlenW(needle);
    int hl = lstrlenW(hay);
    int i;
    if (nl == 0) return TRUE;
    /* i + nl <= hl：显式长度比较不能越过结尾的 NUL */
    for (i = 0; i + nl <= hl; i++)
        if (CompareStringW(LOCALE_INVARIANT, NORM_IGNORECASE, hay + i, nl,
                           needle, nl) == CSTR_EQUAL)
            return TRUE;
    return FALSE;
}

static void build_hotkey_text(const WCHAR *keySpec)
{
    g_hkText[0] = 0;
    if (g_hkMods & MOD_CONTROL) lstrcatW(g_hkText, L"Ctrl+");
    if (g_hkMods & MOD_ALT)     lstrcatW(g_hkText, L"Alt+");
    if (g_hkMods & MOD_SHIFT)   lstrcatW(g_hkText, L"Shift+");
    if (g_hkMods & MOD_WIN)     lstrcatW(g_hkText, L"Win+");
    lstrcatW(g_hkText, keySpec);
}

static void write_default_ini(void)
{
    if (GetFileAttributesW(g_pathIni) != INVALID_FILE_ATTRIBUTES) return;
    WritePrivateProfileStringW(L"hotkey",  L"mods",    L"ctrl+shift",          g_pathIni);
    WritePrivateProfileStringW(L"hotkey",  L"key",     L"`",                   g_pathIni);
    WritePrivateProfileStringW(L"display", L"font",    L"Microsoft YaHei UI",  g_pathIni);
    WritePrivateProfileStringW(L"display", L"bold",    L"1",                   g_pathIni);
    WritePrivateProfileStringW(L"display", L"minsize", L"24",                  g_pathIni);
    WritePrivateProfileStringW(L"display", L"maxsize", L"400",                 g_pathIni);
}

static void load_config(void)
{
    WCHAR mods[64], key[16];

    GetPrivateProfileStringW(L"display", L"font", L"Microsoft YaHei UI",
                             g_fontName, LF_FACESIZE, g_pathIni);
    g_bold    = GetPrivateProfileIntW(L"display", L"bold",    1,   g_pathIni);
    g_minSize = clampi(GetPrivateProfileIntW(L"display", L"minsize", 24,  g_pathIni), 8, 1000);
    g_maxSize = clampi(GetPrivateProfileIntW(L"display", L"maxsize", 400, g_pathIni), 8, 1000);
    if (g_maxSize < g_minSize) g_maxSize = g_minSize;

    GetPrivateProfileStringW(L"hotkey", L"mods", L"ctrl+shift", mods, 64, g_pathIni);
    GetPrivateProfileStringW(L"hotkey", L"key",  L"`",        key,  16, g_pathIni);

    g_hkMods = 0;
    if (istr_has(mods, L"ctrl"))  g_hkMods |= MOD_CONTROL;
    if (istr_has(mods, L"alt"))   g_hkMods |= MOD_ALT;
    if (istr_has(mods, L"shift")) g_hkMods |= MOD_SHIFT;
    if (istr_has(mods, L"win"))   g_hkMods |= MOD_WIN;
    if (!g_hkMods) g_hkMods = MOD_CONTROL | MOD_SHIFT;

    if (key[0] == L'0' && (key[1] == L'x' || key[1] == L'X')) {
        int i, v = 0;
        for (i = 2; key[i]; i++) {
            WCHAR c = key[i];
            int d = (c >= L'0' && c <= L'9') ? c - L'0'
                  : (c >= L'a' && c <= L'f') ? c - L'a' + 10
                  : (c >= L'A' && c <= L'F') ? c - L'A' + 10 : -1;
            if (d < 0) break;
            v = v * 16 + d;
        }
        g_hkVk = (v > 0 && v < 256) ? (UINT)v : VK_OEM_3;
    } else if (key[0]) {
        SHORT s = VkKeyScanW(key[0]);
        g_hkVk = (s == -1) ? VK_OEM_3 : (UINT)(s & 0xFF);
    } else {
        g_hkVk = VK_OEM_3;
    }

    build_hotkey_text(key[0] ? key : L"`");
}

/* ---------------------------------------------------- EDIT 控件子类化 */

static LRESULT CALLBACK EditProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m) {
    case WM_KEYDOWN:
        if (w == VK_ESCAPE) { hide_overlay(); return 0; }
        /* 多行 EDIT 默认不处理 Ctrl+A，补上 */
        if (w == 'A' && (GetKeyState(VK_CONTROL) & 0x8000)) {
            SendMessageW(h, EM_SETSEL, 0, (LPARAM)-1);
            return 0;
        }
        break;
    case WM_CHAR:
        if (w == VK_ESCAPE) return 0;  /* 吞掉，否则系统会 "咚" 一声 */
        break;
    }
    return CallWindowProcW(g_editProc, h, m, w, l);
}

/* -------------------------------------------------------------- 窗口过程 */

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == g_msgTaskbarCreated && g_msgTaskbarCreated) {
        /* Explorer 重启过，托盘图标要重新挂 */
        Shell_NotifyIconW(NIM_ADD, &g_nid);
        return 0;
    }

    switch (msg) {
    case WM_CREATE: {
        /* ES_AUTOHSCROLL = 关闭自动换行。断句位置由用户按 Enter 决定，
         * 同时保证"视觉行数 == 逻辑行数"，refit() 的高度计算才是精确的。 */
        g_edit = CreateWindowExW(0, L"EDIT", NULL,
                    WS_CHILD | WS_VISIBLE | ES_MULTILINE | ES_LEFT |
                    ES_AUTOVSCROLL | ES_AUTOHSCROLL | ES_NOHIDESEL | ES_WANTRETURN,
                    0, 0, 10, 10, hwnd, (HMENU)(UINT_PTR)EDIT_ID, g_inst, NULL);
        if (!g_edit) return -1;
        SendMessageW(g_edit, EM_SETLIMITTEXT, 0x100000, 0);
        SendMessageW(g_edit, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, 0);
        g_editProc = (WNDPROC)(LONG_PTR)SetWindowLongPtrW(g_edit, GWLP_WNDPROC,
                                                          (LONG_PTR)EditProc);
        return 0;
    }

    case WM_ERASEBKGND: {
        RECT rc;
        GetClientRect(hwnd, &rc);
        FillRect((HDC)wp, &rc, g_black);
        return 1;
    }

    case WM_CTLCOLOREDIT:
        SetTextColor((HDC)wp, RGB(255, 255, 255));
        SetBkColor((HDC)wp, RGB(0, 0, 0));
        return (LRESULT)g_black;

    case WM_HOTKEY:
        if (wp == HOTKEY_ID) toggle_overlay();
        return 0;

    case WM_COMMAND:
        if (lp && HIWORD(wp) == EN_CHANGE) {
            int lines;
            g_dirty = TRUE;
            {
                int len = GetWindowTextLengthW(g_edit);
                WCHAR *buf = (WCHAR *)xalloc(((SIZE_T)len + 2) * sizeof(WCHAR));
                if (!buf) return 0;
                GetWindowTextW(g_edit, buf, len + 1);
                lines = count_lines(buf);
                xfree(buf);
            }
            /* 行数变了才允许放大，否则只缩不放 —— 打字时字号不乱跳 */
            if (lines != g_lastLines) { g_lastLines = lines; refit(TRUE); }
            else                      { refit(FALSE); }
            return 0;
        }
        switch (LOWORD(wp)) {
        case IDM_SHOW:    show_overlay(); return 0;
        case IDM_OPENTXT:
            save_if_dirty();
            ShellExecuteW(NULL, L"open", g_pathTxt, NULL, NULL, SW_SHOWNORMAL);
            return 0;
        case IDM_STARTUP: startup_set(!startup_enabled()); return 0;
        case IDM_EXIT:    DestroyWindow(hwnd); return 0;
        }
        return 0;

    case WM_TRAY:
        if (LOWORD(lp) == WM_LBUTTONUP)  { toggle_overlay(); return 0; }
        if (LOWORD(lp) == WM_RBUTTONUP)  { show_tray_menu(); return 0; }
        return 0;

    case WM_ACTIVATE:
        /* 切走了就自动收起，不留一块黑屏赖在最上层。
         * 但本进程自己的窗口（输入法候选框等）不算切走。 */
        if (LOWORD(wp) == WA_INACTIVE && g_visible &&
            GetTickCount() - g_showTick > 400) {
            HWND other = (HWND)lp;
            DWORD pid = 0;
            if (other) GetWindowThreadProcessId(other, &pid);
            if (pid != GetCurrentProcessId()) hide_overlay();
        }
        return 0;

    case WM_TIMER:
        if (wp == TIMER_AUTOSAVE) save_if_dirty();
        return 0;

    case WM_DPICHANGED:
        if (g_visible) { layout_to_cursor_monitor(); refit(TRUE); }
        return 0;

    case WM_QUERYENDSESSION:
        save_if_dirty();
        return TRUE;

    case WM_ENDSESSION:
        save_if_dirty();
        return 0;

    case WM_DESTROY:
        save_if_dirty();
        Shell_NotifyIconW(NIM_DELETE, &g_nid);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

/* ------------------------------------------------------------ 自测模式 */

#define T_OK(cond, name) do { \
        tests++; \
        if (cond) { pass++; } \
        else { failed++; selftest_log(L"FAIL: " name L"\n"); } \
    } while (0)

/* GUI 子系统的程序没有天然的 stdout，报告先攒进缓冲区，最后一次性
 * 写到 CONOUT$（如果是从终端启动的）和 selftest.log（保证可读）。 */
static WCHAR g_report[8192];

static void selftest_log(const WCHAR *s)
{
    int used = lstrlenW(g_report);
    int room = (int)(sizeof(g_report) / sizeof(WCHAR)) - used - 1;
    if (room > 0) lstrcpynW(g_report + used, s, room + 1);
}

static void selftest_flush(void)
{
    WCHAR path[MAX_PATH], dir[MAX_PATH];
    HANDLE h;
    DWORD n;

    h = CreateFileW(L"CONOUT$", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                    NULL, OPEN_EXISTING, 0, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        WriteConsoleW(h, g_report, lstrlenW(g_report), &n, NULL);
        CloseHandle(h);
    }

    dir_of(g_pathExe, dir);
    join(path, dir, L"selftest.log");
    h = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                    FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        static const BYTE bom[3] = { 0xEF, 0xBB, 0xBF };
        int need = WideCharToMultiByte(CP_UTF8, 0, g_report, -1, NULL, 0, NULL, NULL);
        char *utf8 = (char *)xalloc((SIZE_T)need + 1);
        WriteFile(h, bom, sizeof(bom), &n, NULL);
        if (utf8) {
            WideCharToMultiByte(CP_UTF8, 0, g_report, -1, utf8, need, NULL, NULL);
            WriteFile(h, utf8, (DWORD)(need - 1), &n, NULL);
            xfree(utf8);
        }
        CloseHandle(h);
    }
}

static BOOL wequal(const WCHAR *a, const WCHAR *b)
{
    return a && b && lstrcmpW(a, b) == 0;
}

static int run_selftest(void)
{
    int tests = 0, pass = 0, failed = 0;
    WCHAR msg[128];

    AttachConsole(ATTACH_PARENT_PROCESS);

    /* --- 换行规范化 --- */
    {
        WCHAR *r;
        r = normalize_newlines(L"a\nb");         T_OK(wequal(r, L"a\r\nb"),        L"LF -> CRLF");            xfree(r);
        r = normalize_newlines(L"a\r\nb");       T_OK(wequal(r, L"a\r\nb"),        L"CRLF 保持不变");         xfree(r);
        r = normalize_newlines(L"a\rb");         T_OK(wequal(r, L"a\r\nb"),        L"裸 CR -> CRLF");         xfree(r);
        r = normalize_newlines(L"a\r\nb\nc\rd"); T_OK(wequal(r, L"a\r\nb\r\nc\r\nd"), L"混合换行");           xfree(r);
        r = normalize_newlines(L"");             T_OK(wequal(r, L""),              L"空串");                  xfree(r);
        r = normalize_newlines(L"a\n");          T_OK(wequal(r, L"a\r\n"),         L"结尾换行");              xfree(r);
    }

    /* --- UTF-8 解码 --- */
    {
        BYTE bom_abc[] = { 0xEF, 0xBB, 0xBF, 'a', 'b', 'c' };
        BYTE plain[]   = { 'h', 'i' };
        BYTE cn[]      = { 0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD };            /* 你好 */
        BYTE emoji[]   = { 0xF0, 0x9F, 0x94, 0xA5 };                        /* 🔥 */
        BYTE bad[]     = { 0xC0, 0xC0 };                                    /* 非法 UTF-8 */
        WCHAR *w;

        w = utf8_to_wide(bom_abc, sizeof(bom_abc)); T_OK(wequal(w, L"abc"),  L"跳过 BOM");        xfree(w);
        w = utf8_to_wide(plain, sizeof(plain));     T_OK(wequal(w, L"hi"),   L"无 BOM UTF-8");    xfree(w);
        w = utf8_to_wide(cn, sizeof(cn));           T_OK(wequal(w, L"你好"), L"中文 UTF-8");      xfree(w);
        w = utf8_to_wide(emoji, sizeof(emoji));     T_OK(w && lstrlenW(w) == 2, L"emoji 代理对"); xfree(w);
        w = utf8_to_wide(plain, 0);                 T_OK(wequal(w, L""),     L"零长度");          xfree(w);
        w = utf8_to_wide(bad, sizeof(bad));         T_OK(w != NULL,          L"非法 UTF-8 回退 ANSI"); xfree(w);
    }

    /* --- 行数统计 --- */
    T_OK(count_lines(L"")           == 1, L"空串算 1 行");
    T_OK(count_lines(L"a")          == 1, L"单行");
    T_OK(count_lines(L"a\r\nb")     == 2, L"两行");
    T_OK(count_lines(L"a\r\nb\r\n") == 3, L"结尾换行算一个空行");

    /* --- 字号计算 --- */
    {
        int lines, lineH;
        HFONT f = NULL;
        int s;

        g_minSize = 24; g_maxSize = 160;

        s = calc_font_size(L"写代码", 1800, 1000, &lines, &lineH, &f);
        T_OK(s == g_maxSize, L"内容少时撞上限 maxsize");
        T_OK(lines == 1,     L"单行内容行数为 1");
        if (f) DeleteObject(f);

        {
            WCHAR many[64 * 3 + 1];
            int i;
            for (i = 0; i < 64; i++) {
                many[i * 3 + 0] = L'x';
                many[i * 3 + 1] = L'\r';
                many[i * 3 + 2] = L'\n';
            }
            many[64 * 3] = 0;
            f = NULL;
            s = calc_font_size(many, 1800, 1000, &lines, &lineH, &f);
            T_OK(s == g_minSize, L"内容多时撞下限 minsize");
            T_OK(lines == 65,    L"64 个换行算 65 行");
            if (f) DeleteObject(f);
        }

        /* 一行超长 -> 受宽度约束，不是高度约束 */
        {
            WCHAR longline[401];
            int i;
            for (i = 0; i < 400; i++) longline[i] = L'W';
            longline[400] = 0;
            f = NULL;
            s = calc_font_size(longline, 1800, 1000, &lines, &lineH, &f);
            T_OK(s < g_maxSize, L"超长单行受宽度约束而缩小");
            T_OK(lines == 1,    L"超长单行仍是 1 行");
            if (f) DeleteObject(f);
        }
    }

    wsprintfW(msg, L"\nselftest: %d passed, %d failed (%d total)\n", pass, failed, tests);
    selftest_log(msg);
    selftest_flush();
    FreeConsole();
    return failed ? 1 : 0;
}

/* ------------------------------------------------------------ WinMain */

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmdline, int show)
{
    WNDCLASSEXW wc;
    MSG msg;
    HANDLE mutex;
    WCHAR *initial;

    UNREFERENCED_PARAMETER(prev);
    UNREFERENCED_PARAMETER(show);

    g_inst = inst;
    enable_per_monitor_dpi();
    init_paths();

    if (cmdline && istr_has(cmdline, L"--selftest"))
        return run_selftest();

    mutex = CreateMutexW(NULL, TRUE, MUTEX_NAME);
    if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) {
        /* 已经有一个在跑了。再起一个只会让 RegisterHotKey 静默失败。 */
        return 0;
    }

    write_default_ini();
    load_config();

    g_black = CreateSolidBrush(RGB(0, 0, 0));
    g_msgTaskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");

    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = inst;
    wc.hCursor       = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = g_black;
    wc.lpszClassName = APP_CLASS;
    wc.hIcon         = LoadIconW(inst, MAKEINTRESOURCEW(IDI_APPICON));
    if (!RegisterClassExW(&wc)) return 1;

    /* 隐藏的普通顶层窗口（不是 message-only）：message-only 窗口收不到
     * TaskbarCreated 广播，Explorer 重启后托盘图标就永久消失了。 */
    g_wnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
                            APP_CLASS, APP_TITLE, WS_POPUP,
                            0, 0, 100, 100, NULL, NULL, inst, NULL);
    if (!g_wnd) return 1;

    initial = read_text_file(g_pathTxt, &g_fileTime);
    if (initial) {
        SetWindowTextW(g_edit, initial);
        xfree(initial);
    }
    g_dirty = FALSE;

    if (!RegisterHotKey(g_wnd, HOTKEY_ID, g_hkMods | MOD_NOREPEAT, g_hkVk)) {
        WCHAR err[256];
        wsprintfW(err, L"热键 %s 已被其他程序占用。\n\n"
                       L"请修改配置文件后重新启动：\n%s", g_hkText, g_pathIni);
        MessageBoxW(NULL, err, APP_TITLE, MB_ICONWARNING | MB_OK);
    }

    tray_add();
    trim_working_set();

    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (g_font)  DeleteObject(g_font);
    if (g_black) DeleteObject(g_black);
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    return 0;
}
