/* Blackout — 全屏大字待办提醒（macOS 版）
 *
 * 按热键（默认 Ctrl+Shift+`）整屏变黑，白色巨大文字逐行显示待办；
 * 全屏本身就是编辑器，直接打字增删；Esc 保存并隐藏。常驻菜单栏。
 *
 * 和 Windows 版 src/main.c 一节对一节：行为相同，只是 Win32 换成了
 * AppKit + Carbon 热键。单个 .m 文件，clang 直接编，不需要 Xcode 工程。
 *
 * https://github.com/CharlesGuooo/blackout   MIT License
 */

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

/* ------------------------------------------------------------------ 常量 */

#define LOCK_NAME        @"io.github.charlesguooo.blackout.lock"
#define HOTKEY_SIG       0x424C4B4F  /* 'BLKO' */
#define HOTKEY_ID        1
#define AUTOSAVE_SEC     3.0

#define PAD_X_PCT        6   /* 内容区左右留白，占显示器宽度百分比 */
#define PAD_Y_PCT        4   /* 内容区上下留白，占显示器高度百分比 */
#define FIT_ATTEMPTS     8   /* 字号收敛的最大迭代次数 */

/* ------------------------------------------------------------------ 全局 */

@class App;
static App            *g_app;
static NSWindow       *g_wnd;
static NSScrollView   *g_scroll;
static NSTextView     *g_edit;
static NSTextStorage  *g_storage;    /* TextKit 1 里没有谁强引用它，得自己拿着 */
static NSStatusItem   *g_tray;
static NSTimer        *g_autosave;
static EventHotKeyRef  g_hotkey;
static NSFont         *g_font;
static int             g_fontSize;
static CGFloat         g_textH;      /* 当前字号下全部文字的排版高度 */
static int             g_lastLines = -1;
static BOOL            g_visible;
static BOOL            g_dirty;
static NSDate         *g_fileTime;
static NSRect          g_content;    /* 内容区，窗口内容视图坐标（左上角为原点） */

static NSLayoutManager *g_measureLM; /* 量字号用的另一套排版对象 */
static NSTextStorage   *g_measureTS;
static NSTextContainer *g_measureTC;

static NSString *g_pathTxt;
static NSString *g_pathIni;

static NSString *g_fontName = @"PingFang SC";
static int       g_bold     = 1;
static int       g_minSize  = 24;
static int       g_maxSize  = 400;  /* 上限放宽，实际大小基本由"最长一行的宽度"决定 */
static UInt32    g_hkMods   = controlKey | shiftKey;
static UInt32    g_hkKey    = kVK_ANSI_Grave;
static NSString *g_hkText   = @"Ctrl+Shift+`";

static void toggle_overlay(void);
static void show_overlay(void);

/* ------------------------------------------------------- 小工具 */

static int clampi(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* ------------------------------------------------------------ 文本处理 */

/* 把 CRLF / 裸 CR 统一成 LF。行数统计和存盘都按 LF 算，入口处统一掉最省事。 */
static NSString *normalize_newlines(NSString *s)
{
    s = [s stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    return [s stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
}

/* 字节 -> 字符串。带 BOM 会被跳过；不是合法 UTF-8 的（比如 Windows 记事本
 * 存的 GBK）交给系统猜编码，再猜不出就按 Latin-1——它永远不会失败。 */
static NSString *decode_text(NSData *data)
{
    const unsigned char *b = data.bytes;
    NSString *s = nil;

    if (data.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF)
        data = [data subdataWithRange:NSMakeRange(3, data.length - 3)];

    s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s) return s;

    [NSString stringEncodingForData:data
                    encodingOptions:@{ NSStringEncodingDetectionAllowLossyKey: @NO }
                    convertedString:&s
                usedLossyConversion:NULL];
    if (s) return s;
    return [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
}

/* 逻辑行数（含结尾空行）。换行按 TextKit 的认法：LF、裸 CR、CRLF 都算一个。
 * 文件读进来已经统一成 LF，但粘贴进来的文字不经过 normalize_newlines。 */
static int count_lines(NSString *t)
{
    NSUInteger i, n = t.length;
    int lines = 1;
    for (i = 0; i < n; i++) {
        unichar c = [t characterAtIndex:i];
        if (c == '\n' || c == 0x2028 || c == 0x2029 ||
            (c == '\r' && (i + 1 >= n || [t characterAtIndex:i + 1] != '\n')))
            lines++;
    }
    return lines;
}

/* ------------------------------------------------------------ 文件读写 */

static NSDate *file_mtime(NSString *path)
{
    return [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL]
               [NSFileModificationDate];
}

static NSString *read_text_file(NSString *path, NSDate *__strong *outTime)
{
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    NSData *data;

    if (!attr || [attr fileSize] > (16u << 20)) return nil;
    data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;

    if (outTime) *outTime = attr[NSFileModificationDate];
    return normalize_newlines(decode_text(data));
}

/* NSDataWritingAtomic = 先写临时文件再 rename，写一半掉电也不会丢清单。
 * 存成无 BOM 的 UTF-8 + LF：Mac 的习惯，Windows 10 起的记事本也认。 */
static BOOL write_text_file(NSString *path, NSString *text)
{
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    return d && [d writeToFile:path options:NSDataWritingAtomic error:NULL];
}

/* ---------------------------------------------------------------- 字号 */

static NSFont *make_font(int px)
{
    NSFontWeight w = g_bold ? NSFontWeightSemibold : NSFontWeightRegular;
    NSFont *f = [NSFont fontWithDescriptor:
                    [NSFontDescriptor fontDescriptorWithFontAttributes:@{
                        NSFontFamilyAttribute: g_fontName,
                        NSFontTraitsAttribute: @{ NSFontWeightTrait: @(w) } }]
                                      size:px];
    if (!f) f = [NSFont fontWithName:g_fontName size:px];  /* 写的是 PostScript 名 */
    if (!f) f = [NSFont systemFontOfSize:px weight:w];     /* 比如从 Windows 抄来的 YaHei */
    return f;
}

static void measure_init(void)
{
    if (g_measureLM) return;
    g_measureTS = [NSTextStorage new];
    g_measureLM = [NSLayoutManager new];
    g_measureTC = [[NSTextContainer alloc] initWithSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
    g_measureTC.lineFragmentPadding = 0;
    [g_measureLM addTextContainer:g_measureTC];
    [g_measureTS addLayoutManager:g_measureLM];
}

static CGFloat line_height(NSFont *f)
{
    measure_init();
    return [g_measureLM defaultLineHeightForFont:f];
}

/* 用和 NSTextView 同一套 TextKit 排版来量——量出来的就是画出来的，不存在
 * Windows 版 GDI 测量与 DirectWrite 排版之间那 1% 的差。返回总高度，
 * *outW 为最宽一行。空串时 usedRect 会退回成 12pt 系统字体的高度，
 * 所以高度至少取"行数 × 行高"。 */
static CGFloat measure_text(NSString *text, NSFont *f, CGFloat *outW)
{
    NSRect used;

    measure_init();
    [g_measureTS setAttributedString:
        [[NSAttributedString alloc] initWithString:text
                                        attributes:@{ NSFontAttributeName: f }]];
    [g_measureLM ensureLayoutForTextContainer:g_measureTC];
    used = [g_measureLM usedRectForTextContainer:g_measureTC];

    *outW = ceil(used.size.width);
    return MAX(ceil(used.size.height), count_lines(text) * line_height(f));
}

/* 从 g_maxSize 起，反复按"高度约束 / 宽度约束"比例收缩，直到内容塞得进
 * 内容区。因为总是从上限起只缩不放，结果是确定的：能放下的最大字号。
 * 返回字号；*outFont 为对应字体，*outTextH 为该字号下的排版总高度。 */
static int calc_font_size(NSString *text, CGFloat cw, CGFloat ch,
                          int *outLines, CGFloat *outTextH, NSFont **outFont)
{
    NSFont *f = nil;
    int size = g_maxSize, fsize = g_maxSize;
    int lines = count_lines(text);
    CGFloat textH = 1, fitW;
    int attempt;

    if (cw < 1) cw = 1;
    if (ch < 1) ch = 1;

    /* 测量和排版是同一套引擎，宽度只留 2% 给插入点和取整误差。
     * 超宽的行不会折行（关了），而是横向滚出屏幕，所以宁可略小。 */
    fitW = cw - cw / 50;

    for (attempt = 0; attempt < FIT_ATTEMPTS; attempt++) {
        CGFloat maxW;
        int sH, sW, ns;

        fsize = size;
        f = make_font(size);
        textH = measure_text(text, f, &maxW);

        if ((textH <= ch && maxW <= fitW) || size <= g_minSize) break;

        sH = (textH > ch)  ? (int)floor(size * ch / textH)  : size;
        sW = (maxW > fitW) ? (int)floor(size * fitW / maxW) : size;
        ns = (sH < sW) ? sH : sW;
        if (ns >= size) ns = size - 1;
        ns = clampi(ns, g_minSize, g_maxSize);
        if (ns == size) break;
        size = ns;
    }

    /* 迭代次数用完时 size 已经又往下走了一步，f 和 textH 却还是上一步的；
     * 返回 f 实际对应的字号，三者才对得上。 */
    *outFont  = f;
    *outLines = lines;
    *outTextH = textH;
    return fsize;
}

static void apply_font(NSFont *f)
{
    g_edit.font = f;
    g_edit.typingAttributes = @{ NSFontAttributeName: f,
                                 NSForegroundColorAttributeName: NSColor.whiteColor };
}

/* 重算字号并把文本框摆到内容区中间垂直居中的位置。
 * allowGrow=NO 时只缩不放，用于"打字时字号不乱跳"。 */
static void refit(BOOL allowGrow)
{
    CGFloat cw = NSWidth(g_content), ch = NSHeight(g_content);
    CGFloat textH, lineH, y, boxH, unused;
    int size, lines;
    NSString *text;
    NSFont *f = nil;

    if (!g_edit || cw < 1 || ch < 1) return;

    text = g_edit.string;
    size = calc_font_size(text, cw, ch, &lines, &textH, &f);

    if (!allowGrow && g_font && size > g_fontSize) {
        textH = measure_text(text, g_font, &unused);
    } else {
        g_font = f;
        g_fontSize = size;
        apply_font(f);
    }
    g_textH = textH;
    lineH = line_height(g_font);

    /* 按文字实际高度居中，框子再往下多给半行：插入点停在最后一个空行时，
     * 差一点点高度就会让 scrollRangeToVisible 把内容整体上滚，第一行被顶出
     * 屏幕——Windows 版踩过的坑。多出来的只是底部一条黑边。 */
    y = NSMinY(g_content) + (ch - MIN(textH, ch)) / 2;
    boxH = MIN(textH + lineH / 2, NSMaxY(g_content) - y);

    g_scroll.frame = NSMakeRect(NSMinX(g_content), y, cw, boxH);
    g_edit.minSize = g_scroll.contentSize;
    [g_edit sizeToFit];
    [g_edit scrollRangeToVisible:g_edit.selectedRange];
}

/* ------------------------------------------------------------ 加载/保存 */

static void save_if_dirty(void)
{
    if (!g_dirty || !g_edit) return;

    if (write_text_file(g_pathTxt, g_edit.string)) {
        g_dirty = NO;
        /* 记下自己写出去的时间戳，免得下次弹出时误判为"外部改动"而重载 */
        g_fileTime = file_mtime(g_pathTxt);
    }
}

/* 文件被外部（比如文本编辑）改过才重新加载。 */
static void reload_if_changed(void)
{
    NSDate *t = file_mtime(g_pathTxt);
    NSString *text;

    if (!t || [t isEqualToDate:g_fileTime]) return;
    /* 还有没存上的改动（上次保存失败了）：宁可下次保存时盖掉外部改动，
     * 也不能让用户亲手打的字凭空消失。 */
    if (g_dirty) return;

    text = read_text_file(g_pathTxt, &g_fileTime);
    if (!text) return;

    g_edit.string = text;
    [g_edit.undoManager removeAllActions];
    g_dirty = NO;
    g_lastLines = -1;
}

/* --------------------------------------------------------- 显示 / 隐藏 */

static void layout_content(NSSize sz)
{
    CGFloat px = floor(sz.width  * PAD_X_PCT / 100);
    CGFloat py = floor(sz.height * PAD_Y_PCT / 100);
    g_content = NSMakeRect(px, py, sz.width - 2 * px, sz.height - 2 * py);
}

static void layout_to_cursor_monitor(void)
{
    NSPoint pt = NSEvent.mouseLocation;
    NSScreen *scr = NSScreen.mainScreen;

    for (NSScreen *s in NSScreen.screens)
        if (NSMouseInRect(pt, s.frame, NO)) { scr = s; break; }

    /* 用 frame 而非 visibleFrame —— 连菜单栏和 Dock 一起盖住 */
    [g_wnd setFrame:scr.frame display:NO];
    layout_content(scr.frame.size);
}

static void show_overlay(void)
{
    NSUInteger len;

    reload_if_changed();
    layout_to_cursor_monitor();
    refit(YES);
    g_lastLines = -1;

    g_visible = YES;
    if (NSApp.isHidden) [NSApp unhideWithoutActivation];
    [NSApp activateIgnoringOtherApps:YES];
    [g_wnd makeKeyAndOrderFront:nil];
    [g_wnd makeFirstResponder:g_edit];

    len = g_edit.string.length;
    g_edit.selectedRange = NSMakeRange(len, 0);
    [g_edit scrollRangeToVisible:g_edit.selectedRange];

    [g_autosave invalidate];
    g_autosave = [NSTimer scheduledTimerWithTimeInterval:AUTOSAVE_SEC repeats:YES
                                                   block:^(NSTimer *t) {
        (void)t;
        if (!g_edit.hasMarkedText) save_if_dirty();  /* 输入法还没上屏的字不存 */
    }];
}

static void hide_overlay(void)
{
    if (!g_visible) return;
    g_visible = NO;
    save_if_dirty();
    [g_autosave invalidate];
    g_autosave = nil;
    [g_wnd orderOut:nil];
    /* Esc / 热键收起时本程序仍是前台，键盘焦点不会自己回去。hide: 会把焦点
     * 交还给弹出前的那个程序，就像什么都没发生过。因切走而收起时已经不是
     * 前台了，这时再 hide: 反而可能把焦点从用户刚切过去的程序那里抢走。 */
    if (NSApp.isActive) [NSApp hide:nil];
}

static void toggle_overlay(void)
{
    if (g_visible) hide_overlay();
    else           show_overlay();
}

/* -------------------------------------------------------------- 菜单栏 */

/* 和程序图标同一个样子：圆角方块 + 三条横线。模板图，深浅菜单栏自动反色。 */
static NSImage *tray_image(void)
{
    NSImage *img = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:YES
                           drawingHandler:^BOOL(NSRect r) {
        static const CGFloat bars[3][4] = {
            { 0.18, 0.24, 0.82, 0.36 },
            { 0.18, 0.44, 0.82, 0.56 },
            { 0.18, 0.64, 0.62, 0.76 },   /* 最后一条短一点，看着像没写完的清单 */
        };
        NSRect box = NSInsetRect(r, 1.5, 1.5);
        CGFloat w = NSWidth(box), h = NSHeight(box);
        int i;

        [NSColor.blackColor set];
        [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3.5 yRadius:3.5] fill];
        for (i = 0; i < 3; i++)
            NSRectFillUsingOperation(NSMakeRect(NSMinX(box) + bars[i][0] * w,
                                                NSMinY(box) + bars[i][1] * h,
                                                (bars[i][2] - bars[i][0]) * w,
                                                (bars[i][3] - bars[i][1]) * h),
                                     NSCompositingOperationClear);
        return YES;
    }];
    img.template = YES;
    return img;
}

static void tray_add(void)
{
    g_tray = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    g_tray.button.image   = tray_image();
    g_tray.button.toolTip = [NSString stringWithFormat:@"Blackout — %@", g_hkText];
    g_tray.button.target  = g_app;
    g_tray.button.action  = @selector(trayClicked:);
    [g_tray.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
}

static BOOL startup_enabled(void)
{
    return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
}

static void startup_set(BOOL on)
{
    SMAppService *s = SMAppService.mainAppService;
    NSError *err = nil;

    if (on ? ![s registerAndReturnError:&err] : ![s unregisterAndReturnError:&err])
        NSLog(@"Blackout: login item %@ failed: %@", on ? @"register" : @"unregister", err);
    /* 用户在系统设置里关过一次之后，再打开需要他自己去点允许 */
    if (on && s.status == SMAppServiceStatusRequiresApproval)
        [SMAppService openSystemSettingsLoginItems];
}

static void show_tray_menu(void)
{
    NSMenu *m = [NSMenu new];
    NSMenuItem *it;

    it = [m addItemWithTitle:[NSString stringWithFormat:@"显示  (%@)", g_hkText]
                      action:@selector(menuShow:) keyEquivalent:@""];
    it.target = g_app;
    it = [m addItemWithTitle:@"打开 todo.txt"
                      action:@selector(menuOpenTxt:) keyEquivalent:@""];
    it.target = g_app;
    [m addItem:NSMenuItem.separatorItem];
    it = [m addItemWithTitle:@"开机自动启动"
                      action:@selector(menuStartup:) keyEquivalent:@""];
    it.target = g_app;
    it.state = startup_enabled() ? NSControlStateValueOn : NSControlStateValueOff;
    [m addItem:NSMenuItem.separatorItem];
    [m addItemWithTitle:@"退出"
                      action:@selector(terminate:) keyEquivalent:@""];

    /* 菜单只在右键时临时挂上，弹完立刻摘掉：一直挂着的话左键也会弹菜单，
     * "左键开关"就没了。 */
    g_tray.menu = m;
    [g_tray.button performClick:nil];
    g_tray.menu = nil;
}

/* ------------------------------------------------------------ 路径 / 配置 */

/* 数据放 ~/Library/Application Support/Blackout/。不能像 Windows 版那样放在
 * 程序旁边：写进 .app 包里会破坏签名，/Applications 也未必可写。
 * --data-dir 给测试用，免得碰到真实清单。 */
static void init_paths(NSString *dir)
{
    if (!dir) {
        NSURL *u = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                          inDomain:NSUserDomainMask
                                                 appropriateForURL:nil create:YES error:NULL];
        dir = [u.path stringByAppendingPathComponent:@"Blackout"];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    g_pathTxt = [dir stringByAppendingPathComponent:@"todo.txt"];
    g_pathIni = [dir stringByAppendingPathComponent:@"todo.ini"];
}

/* Windows 版的首次教程清单由安装包放下；Mac 版没有安装包，自己放。
 * 只在 todo.txt 不存在时放——绝不覆盖用户攒下来的清单。 */
static BOOL seed_first_run(void)
{
    NSString *src, *text;

    if ([[NSFileManager defaultManager] fileExistsAtPath:g_pathTxt]) return NO;
    src = [NSBundle.mainBundle pathForResource:@"first-run-todo" ofType:@"txt"];
    text = src ? read_text_file(src, NULL) : nil;
    return text && write_text_file(g_pathTxt, text);
}

/* 极简 INI：[节]、键=值、; 或 # 开头的注释行。键名不分大小写，和
 * GetPrivateProfileString 一致。另外认"空白 + ;"开头的行尾注释，
 * 这样 README 里带注释的示例原样抄进来也能用。返回 "节.键" -> 值。 */
static NSDictionary<NSString *, NSString *> *parse_ini(NSString *text)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
    NSString *section = @"";

    for (NSString *raw in [normalize_newlines(text) componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:ws];
        NSString *k, *v;
        NSRange eq, c;

        if (!line.length || [line hasPrefix:@";"] || [line hasPrefix:@"#"]) continue;
        if ([line hasPrefix:@"["] && [line hasSuffix:@"]"]) {
            section = [[line substringWithRange:NSMakeRange(1, line.length - 2)]
                          stringByTrimmingCharactersInSet:ws].lowercaseString;
            continue;
        }
        eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;

        k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
        /* 先去空白再找注释：key = ; 的值就是 ;，不是一条注释 */
        v = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws];
        c = [v rangeOfString:@"\\s;" options:NSRegularExpressionSearch];
        if (c.location != NSNotFound)
            v = [[v substringToIndex:c.location] stringByTrimmingCharactersInSet:ws];

        d[[NSString stringWithFormat:@"%@.%@", section, k.lowercaseString]] = v;
    }
    return d;
}

/* ctrl / alt / shift / win 与 Windows 版同名；alt 也可写 option，
 * win 也可写 cmd —— Mac 键盘上它们就是这两个键。 */
static UInt32 parse_mods(NSString *s)
{
    UInt32 m = 0;
    s = s.lowercaseString;
    if ([s containsString:@"ctrl"] || [s containsString:@"control"]) m |= controlKey;
    if ([s containsString:@"alt"]  || [s containsString:@"opt"])     m |= optionKey;
    if ([s containsString:@"shift"])                                 m |= shiftKey;
    if ([s containsString:@"win"]  || [s containsString:@"cmd"] ||
        [s containsString:@"command"])                               m |= cmdKey;
    return m ? m : (controlKey | shiftKey);
}

/* 字符 -> 键码，按当前键盘布局反查（VkKeyScanW 的 Mac 版）。取"ASCII 布局"
 * 而不是当前输入法：中文输入法本身没有键位表。先试不带修饰键，再试 Shift，
 * 所以 ~ 也能找到 ` 那个键。跳过小键盘：否则 * 和 + 会先在小键盘上找到，
 * 没有小键盘的笔记本就按不出来了。找不到返回 -1。 */
static int keycode_for_char(unichar ch)
{
    TISInputSourceRef src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
    CFDataRef data;
    int found = -1, pass;
    UInt16 kc;

    if (!src) return -1;
    data = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData);
    if (data) {
        const UCKeyboardLayout *lay = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
        for (pass = 0; pass < 2 && found < 0; pass++) {
            UInt32 mods = pass ? (shiftKey >> 8) & 0xFF : 0;
            for (kc = 0; kc < 128 && found < 0; kc++) {
                UInt32 dead = 0;
                UniChar out[4];
                UniCharCount n = 0;
                if (kc >= kVK_ANSI_KeypadDecimal && kc <= kVK_ANSI_Keypad9) continue;
                if (UCKeyTranslate(lay, kc, kUCKeyActionDown, mods, LMGetKbdType(),
                                   kUCKeyTranslateNoDeadKeysMask, &dead, 4, &n, out) == noErr &&
                    n == 1 && out[0] == ch)
                    found = kc;
            }
        }
    }
    CFRelease(src);
    return found;
}

/* 单个字符，或 0x## 形式的 Mac 键码（kVK_*，不是 Windows 的虚拟键码）。
 * 认不出返回 -1。 */
static int parse_key(NSString *s)
{
    if (s.length > 2 && ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"])) {
        unsigned v = 0;
        [[NSScanner scannerWithString:s] scanHexInt:&v];
        return (v > 0 && v < 128) ? (int)v : -1;
    }
    if (s.length) {
        unichar c = [s characterAtIndex:0];
        int kc = keycode_for_char(c);
        if (kc < 0 && c >= 'A' && c <= 'Z') kc = keycode_for_char(c - 'A' + 'a');
        return kc;
    }
    return -1;
}

static NSString *hotkey_text(UInt32 mods, NSString *keySpec)
{
    NSMutableString *s = [NSMutableString string];
    if (mods & controlKey) [s appendString:@"Ctrl+"];
    if (mods & optionKey)  [s appendString:@"Option+"];
    if (mods & shiftKey)   [s appendString:@"Shift+"];
    if (mods & cmdKey)     [s appendString:@"Cmd+"];
    [s appendString:keySpec];
    return s;
}

static void write_default_ini(void)
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:g_pathIni]) return;
    write_text_file(g_pathIni,
        @"[hotkey]\n"
        @"mods=ctrl+shift\n"
        @"key=`\n"
        @"\n"
        @"[display]\n"
        @"font=PingFang SC\n"
        @"bold=1\n"
        @"minsize=24\n"
        @"maxsize=400\n");
}

static void load_config(void)
{
    NSString *text = read_text_file(g_pathIni, NULL);
    NSDictionary<NSString *, NSString *> *ini = parse_ini(text ? text : @"");
    NSString *v, *key;
    int kc;

    if ((v = ini[@"display.font"]).length) g_fontName = v;
    g_bold    = (v = ini[@"display.bold"]) ? v.intValue : 1;
    g_minSize = clampi((v = ini[@"display.minsize"]) ? v.intValue : 24,  8, 1000);
    g_maxSize = clampi((v = ini[@"display.maxsize"]) ? v.intValue : 400, 8, 1000);
    if (g_maxSize < g_minSize) g_maxSize = g_minSize;

    g_hkMods = parse_mods(ini[@"hotkey.mods"] ? ini[@"hotkey.mods"] : @"ctrl+shift");
    key = ini[@"hotkey.key"];
    kc  = parse_key(key);
    /* 认不出就退回 `，显示出来的文字也跟着退回——菜单和冲突提示里写的
     * 必须是真正生效的那个键。 */
    if (kc < 0) { kc = kVK_ANSI_Grave; key = @"`"; }
    g_hkKey  = (UInt32)kc;
    g_hkText = hotkey_text(g_hkMods, key);
}

/* ---------------------------------------------------------------- 热键 */

/* Carbon 的 RegisterEventHotKey：不需要"辅助功能"权限，也不用键盘钩子，
 * 空闲时零开销。NSEvent 的全局监听要权限，而且只能看、不能拦。 */
/* 按住不放也只触发一次（实测：自动重复的按键事件不会再发 HotKeyPressed），
 * 所以不需要 Windows 版 MOD_NOREPEAT 那样的处理。 */
static OSStatus hotkey_handler(EventHandlerCallRef next, EventRef ev, void *ud)
{
    EventHotKeyID hk;
    (void)next; (void)ud;
    if (GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof(hk), NULL, &hk) == noErr &&
        hk.signature == HOTKEY_SIG && hk.id == HOTKEY_ID)
        toggle_overlay();
    return noErr;
}

static OSStatus register_hotkey(void)
{
    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    EventHotKeyID hk = { HOTKEY_SIG, HOTKEY_ID };

    InstallApplicationEventHandler(hotkey_handler, 1, &spec, NULL, NULL);
    return RegisterEventHotKey(g_hkKey, g_hkMods, hk, GetApplicationEventTarget(), 0, &g_hotkey);
}

/* ---------------------------------------------------------------- 窗口 */

/* 无边框窗口默认不能成为键盘窗口，打不了字；也不许系统把它往菜单栏下面挪。 */
@interface OverlayWindow : NSWindow
@end

@implementation OverlayWindow
- (BOOL)canBecomeKeyWindow  { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (NSRect)constrainFrameRect:(NSRect)r toScreen:(NSScreen *)s { (void)s; return r; }
@end

/* 左上角为原点，布局算式和 Windows 版逐行对得上 */
@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

static void create_overlay(id<NSTextViewDelegate> delegate)
{
    NSLayoutManager *lm;
    NSTextContainer *tc;

    g_wnd = [[OverlayWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100)
                                             styleMask:NSWindowStyleMaskBorderless
                                               backing:NSBackingStoreBuffered
                                                 defer:YES];
    g_wnd.releasedWhenClosed = NO;
    g_wnd.backgroundColor    = NSColor.blackColor;
    g_wnd.opaque             = YES;
    g_wnd.hasShadow          = NO;
    g_wnd.animationBehavior  = NSWindowAnimationBehaviorNone;
    /* 压过菜单栏(24)和 Dock(20)，但低于弹出菜单(101)——输入法的候选框
     * 在那一层，盖住它就没法打中文了。 */
    g_wnd.level = NSStatusWindowLevel + 1;
    g_wnd.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorIgnoresCycle;
    g_wnd.contentView = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];

    /* 显式搭 TextKit 1：保证排版和 measure_text 是同一套引擎。
     * 容器宽度无限 = 关闭自动换行。断句位置由用户按回车决定，同时保证
     * "视觉行数 == 逻辑行数"，refit() 的高度计算才是精确的。 */
    g_storage = [NSTextStorage new];
    lm = [NSLayoutManager new];
    tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
    tc.widthTracksTextView  = NO;
    tc.heightTracksTextView = NO;
    tc.lineFragmentPadding  = 0;
    [lm addTextContainer:tc];
    [g_storage addLayoutManager:lm];

    g_edit = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10) textContainer:tc];
    g_edit.delegate                = delegate;
    g_edit.richText                = NO;
    g_edit.importsGraphics         = NO;
    g_edit.allowsUndo              = YES;
    g_edit.usesFindBar             = NO;
    g_edit.usesFontPanel           = NO;
    g_edit.drawsBackground         = YES;
    g_edit.backgroundColor         = NSColor.blackColor;
    g_edit.textColor               = NSColor.whiteColor;
    g_edit.insertionPointColor     = NSColor.whiteColor;
    g_edit.textContainerInset      = NSZeroSize;
    g_edit.horizontallyResizable   = YES;
    g_edit.verticallyResizable     = YES;
    g_edit.maxSize                 = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    /* 这些"智能"功能会悄悄改写清单：` 和 ' 变弯引号、-- 变破折号，
     * 400pt 的字下面再画一条红色波浪线。全关。 */
    g_edit.automaticQuoteSubstitutionEnabled  = NO;
    g_edit.automaticDashSubstitutionEnabled   = NO;
    g_edit.automaticTextReplacementEnabled    = NO;
    g_edit.automaticSpellingCorrectionEnabled = NO;
    g_edit.automaticTextCompletionEnabled     = NO;
    g_edit.automaticLinkDetectionEnabled      = NO;
    g_edit.automaticDataDetectionEnabled      = NO;
    g_edit.continuousSpellCheckingEnabled     = NO;
    g_edit.grammarCheckingEnabled             = NO;
    g_edit.smartInsertDeleteEnabled           = NO;
    if (@available(macOS 14.0, *))
        g_edit.inlinePredictionType = NSTextInputTraitTypeNo;  /* 灰色的预测补全 */

    g_scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    g_scroll.hasVerticalScroller        = NO;
    g_scroll.hasHorizontalScroller      = NO;
    g_scroll.drawsBackground            = NO;
    g_scroll.borderType                 = NSNoBorder;
    g_scroll.verticalScrollElasticity   = NSScrollElasticityNone;
    g_scroll.horizontalScrollElasticity = NSScrollElasticityNone;
    g_scroll.documentView               = g_edit;
    [g_wnd.contentView addSubview:g_scroll];

    apply_font(make_font(g_maxSize));
}

/* 无菜单栏的程序没有主菜单，而 ⌘C / ⌘V / ⌘A / ⌘Z 是靠主菜单分发的——
 * 不补一个隐形的"编辑"菜单，这几个键在文本框里全都没反应。 */
static NSMenu *build_main_menu(void)
{
    NSMenu *bar = [NSMenu new], *edit = [[NSMenu alloc] initWithTitle:@"Edit"];

    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = [NSMenu new];
    [bar addItemWithTitle:@"Edit" action:nil keyEquivalent:@""].submenu = edit;
    [edit addItemWithTitle:@"Undo"       action:@selector(undo:)      keyEquivalent:@"z"];
    [edit addItemWithTitle:@"Redo"       action:@selector(redo:)      keyEquivalent:@"Z"];
    [edit addItemWithTitle:@"Cut"        action:@selector(cut:)       keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy"       action:@selector(copy:)      keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste"      action:@selector(paste:)     keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    return bar;
}

/* -------------------------------------------------------------- 程序委托 */

@interface App : NSObject <NSApplicationDelegate, NSTextViewDelegate>
@property BOOL seeded;   /* 本次启动刚放下首次教程清单 */
@end

@implementation App

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    NSString *initial;
    OSStatus st;
    (void)n;

    create_overlay(self);

    initial = read_text_file(g_pathTxt, &g_fileTime);
    if (initial) g_edit.string = initial;
    g_dirty = NO;

    st = register_hotkey();
    if (st != noErr) {
        NSAlert *a = [NSAlert new];
        a.alertStyle  = NSAlertStyleWarning;
        a.messageText = @"Blackout";
        a.informativeText = (st == eventHotKeyExistsErr)
            ? [NSString stringWithFormat:@"热键 %@ 已被其他程序占用。\n\n"
                                         @"请修改配置文件后重新启动：\n%@", g_hkText, g_pathIni]
            : [NSString stringWithFormat:@"热键 %@ 注册失败（错误 %d）。macOS 15 起，"
                                         @"只用 Option 或 Option+Shift 作修饰键的热键会被系统拒绝。\n\n"
                                         @"请修改配置文件后重新启动：\n%@", g_hkText, (int)st, g_pathIni];
        [NSApp activateIgnoringOtherApps:YES];
        [a runModal];
    }

    tray_add();

    /* 菜单栏图标可能被刘海挡住，第一次启动什么都看不见就像程序坏了。
     * 所以第一次直接弹出来——上面写的就是怎么用。 */
    if (self.seeded) show_overlay();
}

/* 已经在跑的时候又从启动台 / Finder 打开一次：别装死，弹出来。 */
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible
{
    (void)app; (void)visible;
    show_overlay();
    return NO;
}

/* 切走了就自动收起，不留一块黑屏赖在最上层。输入法候选框不会让本程序
 * 失去激活，所以不用像 Windows 版那样比对是不是自己进程的窗口；
 * 也不需要 Windows 版"刚弹出 400ms 内的失焦不算"那段宽限——这里没有
 * 弹出时误报失焦的问题，宽限期内真被切走反而会让黑屏卡在最上层。 */
- (void)applicationDidResignActive:(NSNotification *)n
{
    (void)n;
    if (g_visible) hide_overlay();
}

- (void)applicationDidChangeScreenParameters:(NSNotification *)n
{
    (void)n;
    if (g_visible) { layout_to_cursor_monitor(); refit(YES); }
}

/* 菜单"退出"、注销、关机都走这里 */
- (void)applicationWillTerminate:(NSNotification *)n
{
    (void)n;
    save_if_dirty();
}

- (void)textDidChange:(NSNotification *)n
{
    int lines;
    (void)n;
    g_dirty = YES;
    lines = count_lines(g_edit.string);
    /* 行数变了才允许放大，否则只缩不放 —— 打字时字号不乱跳 */
    if (lines != g_lastLines) { g_lastLines = lines; refit(YES); }
    else                      { refit(NO); }
}

/* Esc 在 NSTextView 里默认是"自动补全"。在这里拦下来改成保存并隐藏；
 * 输入法正在组字时 Esc 先被输入法拿去取消组字，到不了这里——正是想要的。 */
- (BOOL)textView:(NSTextView *)tv doCommandBySelector:(SEL)sel
{
    (void)tv;
    if (sel == @selector(cancelOperation:)) { hide_overlay(); return YES; }
    return NO;
}

- (void)trayClicked:(id)sender
{
    NSEvent *e = NSApp.currentEvent;
    (void)sender;
    if (e.type == NSEventTypeRightMouseUp || (e.modifierFlags & NSEventModifierFlagControl))
        show_tray_menu();
    else
        toggle_overlay();
}

- (void)menuShow:(id)sender    { (void)sender; show_overlay(); }
- (void)menuStartup:(id)sender { (void)sender; startup_set(!startup_enabled()); }
- (void)menuOpenTxt:(id)sender
{
    (void)sender;
    save_if_dirty();
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:g_pathTxt]];
}

@end

/* ------------------------------------------------------------ 自测模式 */

static int g_tests, g_pass, g_failed;

static void T_OK(BOOL cond, NSString *name)
{
    g_tests++;
    if (cond) g_pass++;
    else { g_failed++; printf("FAIL: %s\n", name.UTF8String); }
}

static NSString *decode_bytes(const void *b, NSUInteger n)
{
    return decode_text([NSData dataWithBytes:b length:n]);
}

/* 把覆盖层画进位图，数"文字带"——和 tools/e2e_test.ps1 同一个算法：
 * 连续若干行有亮像素算一条带，中间被全黑行隔开。带数少了 = 有行被滚出
 * 去，多了 = 发生了自动折行。几何断言抓不到这两种：两种情况下控件矩形
 * 都是对的，错的是控件里面的内容。不需要屏幕录制权限，CI 上也能跑。 */
static void render_check(NSString *name, NSString *text, int expectBands)
{
    NSView *v = g_wnd.contentView;
    NSBitmapImageRep *rep;
    const unsigned char *px;
    NSInteger w, h, bpr, spp, x, y, c0;
    CGFloat scale;
    int bands = 0, minY = -1, maxY = -1, maxX = -1, bandStart = 0, minBand;
    BOOL inBand = NO;
    NSRect box;
    CGFloat above, below;

    g_edit.string = text;
    g_lastLines = -1;
    refit(YES);

    rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    if (rep.bitsPerSample != 8) { T_OK(NO, [name stringByAppendingString:@" : 位图是 8 位"]); return; }

    px = rep.bitmapData;
    w = rep.pixelsWide; h = rep.pixelsHigh;
    bpr = rep.bytesPerRow; spp = rep.samplesPerPixel;
    c0 = (rep.hasAlpha && (rep.bitmapFormat & NSBitmapFormatAlphaFirst)) ? 1 : 0;
    scale = w / NSWidth(v.bounds);
    minBand = (int)(4 * scale);

    for (y = 0; y < h; y++) {
        BOOL bright = NO;
        for (x = 0; x < w; x++) {
            const unsigned char *p = px + y * bpr + x * spp + c0;
            if (p[0] > 128 && p[1] > 128 && p[2] > 128) {
                bright = YES;
                if (x > maxX) maxX = (int)x;
            }
        }
        if (bright) {
            if (minY < 0) minY = (int)y;
            maxY = (int)y;
            if (!inBand) { inBand = YES; bandStart = (int)y; }
        } else if (inBand) {
            inBand = NO;
            if (y - bandStart >= minBand) bands++;
        }
    }
    if (inBand && h - bandStart >= minBand) bands++;

    box = g_scroll.frame;
    above = NSMinY(box) - NSMinY(g_content);
    below = NSMaxY(g_content) - (NSMinY(box) + MIN(g_textH, NSHeight(g_content)));
    printf("  [%s] size=%d bands=%d topY=%d bottomY=%d rightX=%d (content right edge %d)\n",
           name.UTF8String, g_fontSize, bands, minY, maxY, maxX,
           (int)(NSMaxX(g_content) * scale));

    T_OK(bands == expectBands,
         [NSString stringWithFormat:@"%@ : 文字带数 == %d 行（不折行、不丢行）", name, expectBands]);
    T_OK(minY > NSMinY(box) * scale + 1,  [name stringByAppendingString:@" : 顶部未被裁切"]);
    T_OK(maxY < NSMaxY(box) * scale - 1,  [name stringByAppendingString:@" : 底部未被裁切"]);
    T_OK(maxX < NSMaxX(g_content) * scale - 8,
         [name stringByAppendingString:@" : 最长行未被右边界裁掉"]);
    T_OK(fabs(above - below) <= 1, [name stringByAppendingString:@" : 垂直居中"]);
}

static int run_selftest(void)
{
    /* --- 换行规范化 --- */
    T_OK([normalize_newlines(@"a\nb")         isEqualToString:@"a\nb"],       @"LF 保持不变");
    T_OK([normalize_newlines(@"a\r\nb")       isEqualToString:@"a\nb"],       @"CRLF -> LF");
    T_OK([normalize_newlines(@"a\rb")         isEqualToString:@"a\nb"],       @"裸 CR -> LF");
    T_OK([normalize_newlines(@"a\r\nb\nc\rd") isEqualToString:@"a\nb\nc\nd"], @"混合换行");
    T_OK([normalize_newlines(@"")             isEqualToString:@""],           @"空串");
    T_OK([normalize_newlines(@"a\r\n")        isEqualToString:@"a\n"],        @"结尾换行");

    /* --- UTF-8 解码 --- */
    {
        static const unsigned char bom_abc[] = { 0xEF, 0xBB, 0xBF, 'a', 'b', 'c' };
        static const unsigned char plain[]   = { 'h', 'i' };
        static const unsigned char cn[]      = { 0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD };  /* 你好 */
        static const unsigned char emoji[]   = { 0xF0, 0x9F, 0x94, 0xA5 };              /* 🔥 */
        static const unsigned char bad[]     = { 0xC0, 0xC0 };                          /* 非法 UTF-8 */

        T_OK([decode_bytes(bom_abc, sizeof(bom_abc)) isEqualToString:@"abc"], @"跳过 BOM");
        T_OK([decode_bytes(plain, sizeof(plain))     isEqualToString:@"hi"],  @"无 BOM UTF-8");
        T_OK([decode_bytes(cn, sizeof(cn))           isEqualToString:@"你好"], @"中文 UTF-8");
        T_OK(decode_bytes(emoji, sizeof(emoji)).length == 2,                   @"emoji 代理对");
        T_OK([decode_bytes(plain, 0)                 isEqualToString:@""],    @"零长度");
        T_OK(decode_bytes(bad, sizeof(bad)) != nil,                            @"非法 UTF-8 回退");
    }

    /* --- 行数统计 --- */
    T_OK(count_lines(@"")           == 1, @"空串算 1 行");
    T_OK(count_lines(@"a")          == 1, @"单行");
    T_OK(count_lines(@"a\nb")       == 2, @"两行");
    T_OK(count_lines(@"a\nb\n")     == 3, @"结尾换行算一个空行");
    T_OK(count_lines(@"a\r\nb\rc")  == 3, @"粘贴进来的 CRLF / 裸 CR 也算换行");

    /* --- 文件读写 --- */
    {
        NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"blackout-selftest-%d.txt", getpid()]];
        static const unsigned char winfile[] = { 0xEF, 0xBB, 0xBF, 'a', '\r', '\n', 'b' };
        NSDate *t = nil;
        NSData *raw;

        [[NSData dataWithBytes:winfile length:sizeof(winfile)] writeToFile:p atomically:NO];
        T_OK([read_text_file(p, &t) isEqualToString:@"a\nb"], @"读 Windows 版存的文件（BOM + CRLF）");
        T_OK(t != nil, @"读文件时取到修改时间");
        T_OK(write_text_file(p, @"买咖啡豆\nbuy coffee"), @"原子写入成功");
        raw = [NSData dataWithContentsOfFile:p];
        T_OK(raw.length > 0 && ((const unsigned char *)raw.bytes)[0] != 0xEF, @"存盘不带 BOM");
        T_OK([decode_text(raw) isEqualToString:@"买咖啡豆\nbuy coffee"], @"写入后读回一致");
        [[NSFileManager defaultManager] removeItemAtPath:p error:NULL];
    }

    /* --- 配置 --- */
    {
        NSDictionary *d = parse_ini(@"; 注释\r\n[hotkey]\r\nmods=ctrl+alt   ; 行尾注释\r\n"
                                    @"key=`\r\n[Display]\r\nFont = Menlo \r\nkey=;\r\nkey2 = ;\r\n");
        T_OK([d[@"hotkey.mods"] isEqualToString:@"ctrl+alt"], @"去掉行尾注释");
        T_OK([d[@"hotkey.key"] isEqualToString:@"`"],         @"读到 key=`");
        T_OK([d[@"display.font"] isEqualToString:@"Menlo"],   @"节名 / 键名不分大小写，值去空白");
        T_OK([d[@"display.key"] isEqualToString:@";"],        @"值本身是 ; 时不当注释");
        T_OK([d[@"display.key2"] isEqualToString:@";"],       @"key = ; 两边有空格也不当注释");

        T_OK(parse_mods(@"ctrl+shift")  == (controlKey | shiftKey), @"mods ctrl+shift");
        T_OK(parse_mods(@"cmd+option")  == (cmdKey | optionKey),    @"mods cmd+option");
        T_OK(parse_mods(@"Win+Alt")     == (cmdKey | optionKey),    @"mods 沿用 Windows 写法 win+alt");
        T_OK(parse_mods(@"")            == (controlKey | shiftKey), @"mods 为空时用默认");

        T_OK(parse_key(@"0x32") == kVK_ANSI_Grave, @"key 0x32 = Mac 键码");
        T_OK(parse_key(@"0xC0") == -1,             @"key 超出范围（比如 Windows 的 VK 码）视为无效");
        T_OK(parse_key(@"")     == -1,             @"key 为空视为无效");
        T_OK(parse_key(@"☃")    == -1,             @"key 键盘上打不出来的字符视为无效");
        /* 下面几条按键盘布局反查，只在 US 类布局上成立（CI 就是） */
        if (keycode_for_char('a') == kVK_ANSI_A && keycode_for_char('`') == kVK_ANSI_Grave) {
            T_OK(parse_key(@"`") == kVK_ANSI_Grave, @"key ` 按键盘布局反查");
            T_OK(parse_key(@"~") == kVK_ANSI_Grave, @"key ~ 反查到同一个键（Shift 层）");
            T_OK(parse_key(@"A") == kVK_ANSI_A,     @"key 大写字母");
            T_OK(parse_key(@"*") == kVK_ANSI_8,     @"key * 是主键盘的 Shift+8，不是小键盘");
        } else {
            printf("  （非 US 类键盘布局，跳过按布局反查的 4 项）\n");
        }
        T_OK([hotkey_text(controlKey | shiftKey, @"`") isEqualToString:@"Ctrl+Shift+`"], @"热键文字");

        /* 整条读配置的路径：认不出的键退回 `，显示的文字也要跟着退回 */
        g_pathIni = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"blackout-selftest-%d.ini", getpid()]];
        write_text_file(g_pathIni, @"[hotkey]\nmods=cmd+option\nkey=☃\n[display]\nminsize=500\nmaxsize=100\n");
        load_config();
        T_OK(g_hkKey == kVK_ANSI_Grave,                        @"配置：认不出的键退回 `");
        T_OK([g_hkText isEqualToString:@"Option+Cmd+`"],       @"配置：显示的是真正生效的热键");
        T_OK(g_minSize == 500 && g_maxSize == 500,             @"配置：maxsize 小于 minsize 时抬到 minsize");
        [[NSFileManager defaultManager] removeItemAtPath:g_pathIni error:NULL];
        g_minSize = 24; g_maxSize = 400;
    }

    /* --- 字号计算 --- */
    {
        int lines, s;
        CGFloat textH;
        NSFont *f = nil;
        NSMutableString *many = [NSMutableString string];
        NSString *longline = [@"" stringByPaddingToLength:400 withString:@"W" startingAtIndex:0];
        int i;

        g_minSize = 24; g_maxSize = 160;

        s = calc_font_size(@"写代码", 1800, 1000, &lines, &textH, &f);
        T_OK(s == g_maxSize, @"内容少时撞上限 maxsize");
        T_OK(lines == 1,     @"单行内容行数为 1");

        for (i = 0; i < 64; i++) [many appendString:@"x\n"];
        s = calc_font_size(many, 1800, 1000, &lines, &textH, &f);
        T_OK(s == g_minSize, @"内容多时撞下限 minsize");
        T_OK(lines == 65,    @"64 个换行算 65 行");

        /* 一行超长 -> 受宽度约束，不是高度约束 */
        s = calc_font_size(longline, 1800, 1000, &lines, &textH, &f);
        T_OK(s < g_maxSize, @"超长单行受宽度约束而缩小");
        T_OK(lines == 1,    @"超长单行仍是 1 行");

        g_minSize = 24; g_maxSize = 400;
    }

    /* --- 像素级渲染回归（清单内容和 tools/e2e_test.ps1 一致） --- */
    {
        NSMutableArray *twelve = [NSMutableArray array];
        int i;
        for (i = 1; i <= 12; i++)
            [twelve addObject:[NSString stringWithFormat:@"第 %d 件事 task %d", i, i]];

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        create_overlay(nil);
        [g_wnd setFrame:NSMakeRect(0, 0, 1440, 900) display:NO];
        layout_content(NSMakeSize(1440, 900));

        render_check(@"01-user-list-3-lines", @"答辩准备\nCoding题复习\nAI Engineer Agentic Track", 3);
        render_check(@"02-one-very-long-line",
                     @"把这条写得非常非常长 an extremely long single task that used to wrap", 1);
        render_check(@"03-twelve-lines", [twelve componentsJoinedByString:@"\n"], 12);
        render_check(@"04-four-long-lines",
                     @"AI Engineer Agentic Track 复习\n"
                     @"Coding 题复习 leetcode hard\n"
                     @"答辩准备 slides and demo script\n"
                     @"买咖啡豆 buy coffee beans today", 4);
        render_check(@"05-trailing-empty-line", @"写代码\n", 1);
    }

    printf("\nselftest: %d passed, %d failed (%d total)\n", g_pass, g_failed, g_tests);
    return g_failed ? 1 : 0;
}

/* ------------------------------------------------------------------ main */

/* 单实例：全局热键只能属于一个进程，再起一个只会注册失败。用 flock 而不是
 * 查进程列表——它是原子的，进程退出锁自动释放，也不依赖 .app 包。 */
static BOOL acquire_single_instance(void)
{
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:LOCK_NAME];
    int fd = open(p.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    /* fd 故意不关：进程活多久，锁就持有多久 */
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0;
}

int main(int argc, const char *argv[])
{
    (void)argc; (void)argv;

    @autoreleasepool {
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        NSUInteger i = [args indexOfObject:@"--data-dir"];
        BOOL seeded;

        if ([args containsObject:@"--selftest"])
            return run_selftest();

        /* 已经有一个在跑了。从 Finder 再打开时系统根本不会起第二个进程，
         * 而是发 reopen 给已有的那个；走到这里的只会是命令行直接启动。 */
        if (!acquire_single_instance())
            return 0;

        init_paths(i != NSNotFound && i + 1 < args.count ? args[i + 1] : nil);
        seeded = seed_first_run();
        write_default_ini();
        load_config();

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_app = [App new];
        g_app.seeded = seeded;
        NSApp.delegate = g_app;
        NSApp.mainMenu = build_main_menu();
        [NSApp run];
    }
    return 0;
}
