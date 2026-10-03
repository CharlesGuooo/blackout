#!/bin/bash
# Blackout macOS 端到端回归测试（Windows 版 tools/e2e_test.ps1 的对应物）
#
# 驱动的是真程序：合成真实按键触发全局热键，看窗口有没有出来、焦点在不在、
# 文件有没有存对。有屏幕录制权限时，还会把覆盖层截下来做像素断言。
#
# 需要给运行本脚本的终端打开：
#   系统设置 → 隐私与安全性 → 辅助功能   （合成按键，必须）
#   系统设置 → 隐私与安全性 → 屏幕录制   （像素断言；没有就跳过那几项）
# 授权后要重启终端才生效。
#
# 数据隔离：用 --data-dir 指到临时目录，绝不碰你真实的 todo.txt。
# 但全局热键是全系统独占的：脚本开头会停掉所有 Blackout 进程，跑完请自己
# 把常用实例启回来。文字一律走剪贴板粘贴（中文输入法会截走合成的字母键），
# 剪贴板里原有的文字会在结束时还原。
#
# 用法：./build.sh && tools/e2e_test.sh

set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)
APP="$REPO/bin/Blackout.app"
BIN="$APP/Contents/MacOS/Blackout"
WORK="${TMPDIR:-/tmp}/BlackoutE2E"
TXT="$WORK/todo.txt"
SHOTS="$REPO/tools/shots"
BK="$WORK/bk"
PASS=0
FAIL=0
FAILED=()

[ -x "$BIN" ] || { echo "bin/Blackout.app not found - run ./build.sh first"; exit 1; }

# ---------- 测试辅助程序：合成按键、查窗口、截图数像素
# 和 Windows 版把像素分析放进 C# 一个道理：5K 屏 1400 万像素，脚本里逐点扫太慢。
rm -rf "$WORK"
mkdir -p "$WORK" "$SHOTS"
# CGWindowListCreateImage 在 macOS 14 标了弃用，但换 ScreenCaptureKit 要多写一大截异步代码
clang -fobjc-arc -Wno-deprecated-declarations -framework Cocoa -o "$BK" -x objective-c - <<'EOF' || { echo "cannot build test helper"; exit 1; }
#import <Cocoa/Cocoa.h>

static void post(CGKeyCode kc, CGEventFlags f, bool down)
{
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, kc, down);
    CGEventSetFlags(e, f);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

/* Blackout 的覆盖层 = 该进程在屏上、且不是菜单栏图标（第 25 层）的那个窗口 */
static NSDictionary *overlay(pid_t pid)
{
    NSArray *a = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    for (NSDictionary *w in a)
        if ([w[(id)kCGWindowOwnerPID] intValue] == pid && [w[(id)kCGWindowLayer] intValue] != 25)
            return w;
    return nil;
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *cmd = argc > 1 ? @(argv[1]) : @"";

    if ([cmd isEqual:@"perms"]) {
        printf("%d %d\n", AXIsProcessTrusted(), CGPreflightScreenCaptureAccess());
    } else if ([cmd isEqual:@"key"]) {            /* key <keycode> [ctrl,shift,cmd,opt] */
        NSString *m = argc > 3 ? @(argv[3]) : @"";
        CGEventFlags f = 0;
        if ([m containsString:@"ctrl"])  f |= kCGEventFlagMaskControl;
        if ([m containsString:@"shift"]) f |= kCGEventFlagMaskShift;
        if ([m containsString:@"cmd"])   f |= kCGEventFlagMaskCommand;
        if ([m containsString:@"opt"])   f |= kCGEventFlagMaskAlternate;
        post((CGKeyCode)atoi(argv[2]), f, true);
        usleep(30000);
        post((CGKeyCode)atoi(argv[2]), f, false);
    } else if ([cmd isEqual:@"win"]) {            /* win <pid> -> "x y w h layer" 或 hidden */
        NSDictionary *w = overlay(atoi(argv[2]));
        NSDictionary *b = w[(id)kCGWindowBounds];
        if (w) printf("%d %d %d %d %d\n", [b[@"X"] intValue], [b[@"Y"] intValue],
                      [b[@"Width"] intValue], [b[@"Height"] intValue], [w[(id)kCGWindowLayer] intValue]);
        else   printf("hidden\n");
    } else if ([cmd isEqual:@"screen"]) {         /* 鼠标所在屏幕 "x y w h"（点，和 win 一样是左上角原点） */
        NSPoint p = NSEvent.mouseLocation;
        CGFloat top = NSScreen.screens[0].frame.size.height;
        for (NSScreen *s in NSScreen.screens)
            if (NSMouseInRect(p, s.frame, NO))
                printf("%d %d %d %d\n", (int)s.frame.origin.x, (int)(top - NSMaxY(s.frame)),
                       (int)s.frame.size.width, (int)s.frame.size.height);
    } else if ([cmd isEqual:@"front"]) {
        printf("%d\n", NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
    } else if ([cmd isEqual:@"activate"]) {       /* activate <bundle id> */
        [[NSRunningApplication runningApplicationsWithBundleIdentifier:@(argv[2])].firstObject
            activateWithOptions:0];
    } else if ([cmd isEqual:@"quit"]) {           /* quit <pid>：正常退出，走 applicationWillTerminate */
        printf("%d\n", [[NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[2])] terminate]);
    } else if ([cmd isEqual:@"bands"]) {          /* bands <pid> <out.png> -> "bands minY maxY maxX W H" */
        NSDictionary *w = overlay(atoi(argv[2]));
        CGImageRef img;
        NSBitmapImageRep *rep;
        int bands = 0, minY = -1, maxY = -1, maxX = -1, start = 0, W, H, x, y;
        BOOL in = NO;
        if (!w) { printf("hidden\n"); return 0; }
        img = CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow,
                                      [w[(id)kCGWindowNumber] unsignedIntValue],
                                      kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
        if (!img) { printf("noimage\n"); return 0; }
        rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
        CGImageRelease(img);
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[3]) atomically:NO];
        W = (int)rep.pixelsWide; H = (int)rep.pixelsHigh;
        /* "文字带" = 连续若干行里存在亮像素，中间被全黑行隔开 */
        for (y = 0; y < H; y++) {
            BOOL bright = NO;
            const unsigned char *row = rep.bitmapData + (NSInteger)y * rep.bytesPerRow;
            int c0 = (rep.bitmapFormat & NSBitmapFormatAlphaFirst) ? 1 : 0;
            for (x = 0; x < W; x++) {
                const unsigned char *p = row + (NSInteger)x * rep.samplesPerPixel + c0;
                if (p[0] > 128 && p[1] > 128 && p[2] > 128) { bright = YES; if (x > maxX) maxX = x; }
            }
            if (bright) { if (minY < 0) minY = y; maxY = y; if (!in) { in = YES; start = y; } }
            else if (in) { in = NO; if (y - start >= 8) bands++; }
        }
        if (in && H - start >= 8) bands++;
        printf("%d %d %d %d %d %d\n", bands, minY, maxY, maxX, W, H);
    }
}}
EOF

read -r AX SCREENCAP <<< "$("$BK" perms)"
if [ "$AX" != 1 ]; then
    echo "这个终端没有「辅助功能」权限，没法合成按键。授权后重启终端再跑。"
    exit 1
fi
[ "$SCREENCAP" = 1 ] || echo "（没有「屏幕录制」权限：像素断言跳过，渲染由 --selftest 覆盖）"

check() {   # check "名称" 命令...
    local name=$1; shift
    if "$@"; then PASS=$((PASS + 1)); echo "  ok    $name"
    else FAIL=$((FAIL + 1)); FAILED+=("$name"); echo "  FAIL  $name"; fi
}
visible()  { [ "$("$BK" win "$PID")" != hidden ]; }
hidden()   { [ "$("$BK" win "$PID")" = hidden ]; }
is_front() { [ "$("$BK" front)" = "$PID" ]; }
not_front(){ [ "$("$BK" front)" != "$PID" ]; }
has()      { grep -qF -- "$1" "$TXT"; }
lacks()    { ! grep -qF -- "$1" "$TXT"; }
no_cr()    { ! grep -q $'\r' "$TXT"; }
dead()     { ! kill -0 "$1" 2>/dev/null; }
hotkey()   { "$BK" key 50 ctrl,shift; sleep 0.8; }
esc()      { "$BK" key 53; sleep 0.6; }
paste()    { printf '%s' "$1" | pbcopy; "$BK" key 9 cmd; sleep 0.3; }
enter()    { "$BK" key 36; sleep 0.1; }
rss_kb()   { ps -o rss= -p "$PID" | tr -d ' '; }
footprint_of() { footprint "$PID" 2>/dev/null | sed -n 's/.*Footprint: *\([0-9.]* [KMG]B\).*/\1/p' | head -1; }

# 换一份清单内容，重新弹出，做像素断言
check_render() {   # 名称 内容 期望行数
    local name=$1 content=$2 expect=$3 out
    printf '%s' "$content" > "$TXT"
    hotkey
    if ! visible; then check "$name : overlay visible" false; return; fi
    if [ "$SCREENCAP" = 1 ]; then
        read -r bands minY maxY maxX W H <<< "$("$BK" bands "$PID" "$SHOTS/$name.png")"
        out=$((W - W * 6 / 100))
        echo "  [$name] bands=$bands topY=$minY bottomY=$maxY rightX=$maxX (content right edge $out)"
        # 带数少了 = 第一行被滚出屏幕；带数多了 = 长行被自动折行
        check "$name : 文字带数 == $expect 行（不折行、不丢行）" [ "$bands" = "$expect" ]
        check "$name : 顶部未被裁切" [ "$minY" -gt 0 ]
        # 文本被右边界硬裁时，最右亮像素会紧贴边界
        check "$name : 最长行未被右边界裁掉" [ "$maxX" -lt $((out - 8)) ]
    fi
    hotkey
}

# ---------- 隔离环境
echo "stopping every Blackout instance (a global hotkey can only belong to one process)"
pkill -x Blackout 2>/dev/null
sleep 0.5
CLIP_SAVED="$WORK/clipboard.txt"
pbpaste > "$CLIP_SAVED" 2>/dev/null
trap 'pbcopy < "$CLIP_SAVED"; [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null' EXIT

cat > "$WORK/todo.ini" <<'INI'
[hotkey]
mods=ctrl+shift
key=`
[display]
font=PingFang SC
bold=1
minsize=24
maxsize=400
INI
echo "sandbox = $WORK  (your real todo.txt is never touched)"
echo "screen  = $("$BK" screen) points"

# 种子数据：Windows 版存出来的格式（BOM + CRLF + 中文），压读入时的兼容路径
printf '\xEF\xBB\xBF写完 Blackout 的验收测试\r\n给爸妈打电话\r\n交房租' > "$TXT"

# ---------- 启动
"$BIN" --data-dir "$WORK" >/dev/null 2>&1 &
PID=$!
sleep 1.5
check "process alive after launch" kill -0 "$PID"
check "overlay hidden at startup (not a first run)" hidden
echo "  idle: rss $(rss_kb) KB, footprint $(footprint_of)"

# ---------- 热键 Ctrl+Shift+`
hotkey
check "overlay visible after Ctrl+Shift+backtick" visible
check "Blackout is the active app" is_front
read -r WX WY WW WH WL <<< "$("$BK" win "$PID")"
check "overlay covers the whole screen, menu bar included" [ "$WX $WY $WW $WH" = "$("$BK" screen)" ]
check "overlay sits above the menu bar (layer > 24)" [ "$WL" -gt 24 ]
echo "  shown: rss $(rss_kb) KB, footprint $(footprint_of)"

# ---------- 编辑：回车 + 粘贴中英文（⌘V 能用 = 隐形"编辑"菜单生效了）
enter
paste "买咖啡豆 buy coffee"
check "overlay still visible after editing" visible

# ---------- Esc 保存并隐藏
esc
check "overlay hidden after Esc" hidden
check "focus handed back to the previous app" not_front
check "saved without BOM" [ "$(head -c 3 "$TXT" | xxd -p)" != efbbbf ]
check "saved with LF only (no CR)" no_cr
check "typed text persisted"  has "买咖啡豆 buy coffee"
check "seeded text preserved" has "给爸妈打电话"
check "line break typed with Enter persisted" [ "$(wc -l < "$TXT" | tr -d ' ')" = 3 ]

# ---------- 撤销：⌘Z 撤掉刚粘贴的内容
hotkey
paste "要被撤销的一行"
"$BK" key 6 cmd
sleep 0.3
esc
check "Cmd+Z undoes a paste" lacks "要被撤销的一行"

# ---------- 自动保存：弹着不动，3 秒后也该落盘
hotkey
paste " autosaved"
sleep 3.5
check "autosave writes while the overlay stays open" has "autosaved"
esc

# ---------- 切到别的程序 = 保存并收起
hotkey
paste " switched away"
"$BK" activate com.apple.finder
sleep 0.8
check "overlay hides itself when another app is activated" hidden
check "the app switched to keeps the focus" [ "$("$BK" front)" = "$(pgrep -x Finder)" ]
check "switching away saves" has "switched away"

# ---------- 像素级渲染回归（清单内容和 e2e_test.ps1 一致）
check_render 01-user-list-3-lines $'答辩准备\nCoding题复习\nAI Engineer Agentic Track' 3
check_render 02-one-very-long-line '把这条写得非常非常长 an extremely long single task that used to wrap' 1
check_render 03-twelve-lines "$(for i in $(seq 1 12); do echo "第 $i 件事 task $i"; done)" 12
check_render 04-four-long-lines $'AI Engineer Agentic Track 复习\nCoding 题复习 leetcode hard\n答辩准备 slides and demo script\n买咖啡豆 buy coffee beans today' 4
echo "  after many cycles: rss $(rss_kb) KB, footprint $(footprint_of)"

# ---------- 外部改动会被重新加载
printf '外部改动 external edit' > "$TXT"
hotkey
paste "!"
esc
check "external edit is reloaded on next show" [ "$(cat "$TXT")" = "外部改动 external edit!" ]

hotkey
check "overlay visible on hotkey" visible
hotkey
check "hotkey toggles overlay back off" hidden

# ---------- 单实例
"$BIN" --data-dir "$WORK" >/dev/null 2>&1 &
P2=$!
sleep 1
check "second instance exits immediately" dead "$P2"
check "first instance still running" kill -0 "$PID"

# ---------- 正常退出：弹着、有没存的改动，也要先存再走
hotkey
paste " saved on quit"
"$BK" quit "$PID" >/dev/null
sleep 1
check "exits cleanly on a quit request" dead "$PID"
check "unsaved edits are saved on quit" has "saved on quit"
PID=

# ---------- 首次运行：没有 todo.txt 时放下教程清单，并直接弹出来
FIRST="$WORK/first-run"
mkdir -p "$FIRST"
"$BIN" --data-dir "$FIRST" >/dev/null 2>&1 &
PID=$!
sleep 1.5
check "first run writes the tutorial list" grep -qF "Esc saves and hides" "$FIRST/todo.txt"
check "first run writes a default todo.ini" grep -qF "mods=ctrl+shift" "$FIRST/todo.ini"
check "first run shows the overlay by itself" visible
esc
check "Esc hides it" hidden
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
PID=

echo
echo "e2e: $PASS passed, $FAIL failed ($((PASS + FAIL)) total)"
for f in "${FAILED[@]+"${FAILED[@]}"}"; do echo "  FAIL: $f"; done
[ "$FAIL" = 0 ]
