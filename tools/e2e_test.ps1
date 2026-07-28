# Blackout Overlay 端到端回归测试
#
# 数据隔离：把 bin\Blackout.exe 复制到 %TEMP%\BlackoutE2E 再跑。程序是便携式的
# （数据文件跟着 exe 走，见 init_paths()），所以测试用的是自己的
# todo.txt / todo.ini，绝不碰 bin\todo.txt 里的真实待办。
#
# 但全局热键是全系统独占的：要用合成按键触发它，就必须让运行中的实例让开。
# 所以脚本开头会停掉所有 Blackout 进程，跑完请自己把常用实例启回来。
#
# 注意：本文件必须存成【带 BOM 的 UTF-8】。Windows PowerShell 5.1 对无 BOM
# 的脚本按 ANSI 代码页解码，里面的中文会把引号吃掉导致语法错误。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class N {
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, IntPtr w);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, IntPtr w);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] i, int cb);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
    public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT {
    public uint type; public KEYBDINPUT ki; public int pad1, pad2; }
}
'@

# 像素分析放在 C# 里做：2560x1600 有 410 万像素，用 PowerShell 逐点
# GetPixel 要跑几十秒。LockBits 一次性拷出来在 C# 里扫，毫秒级。
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public class PX {
  // 返回 [文字带数, 最顶亮像素y, 最右亮像素x, 最底亮像素y]
  // "文字带" = 连续若干行里存在亮像素，中间被全黑行隔开。
  // 第一行被滚出屏幕时带数会少一条；长行被自动折行时带数会多一条。
  public static int[] Analyze(string path, int thresh, int minBandPx) {
    using (Bitmap b = new Bitmap(path)) {
      int w = b.Width, h = b.Height;
      BitmapData d = b.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      int stride = d.Stride;
      byte[] buf = new byte[stride * h];
      Marshal.Copy(d.Scan0, buf, 0, buf.Length);
      b.UnlockBits(d);

      int bands = 0, minY = -1, maxX = -1, maxY = -1;
      bool inBand = false; int bandStart = 0;
      for (int y = 0; y < h; y++) {
        bool bright = false;
        int rowBase = y * stride;
        for (int x = 0; x < w; x++) {
          int i = rowBase + x * 4;
          if (buf[i] > thresh && buf[i+1] > thresh && buf[i+2] > thresh) {
            bright = true;
            if (x > maxX) maxX = x;
          }
        }
        if (bright) {
          if (minY < 0) minY = y;
          maxY = y;
          if (!inBand) { inBand = true; bandStart = y; }
        } else if (inBand) {
          inBand = false;
          if (y - bandStart >= minBandPx) bands++;
        }
      }
      if (inBand && h - bandStart >= minBandPx) bands++;
      return new int[] { bands, minY, maxX, maxY };
    }
  }
}
'@

# PS 5.1 只是 system-DPI-aware；不设这个的话屏幕尺寸和 CopyFromScreen
# 对不上，截图会被裁掉一角。
[N]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

$KEYUP = 0x0002; $UNICODE = 0x0004
$VK_CTRL = 0x11; $VK_SHIFT = 0x10; $VK_OEM3 = 0xC0; $VK_ESC = 0x1B
$repo  = Split-Path $PSScriptRoot -Parent
$work  = Join-Path $env:TEMP 'BlackoutE2E'
$exe   = Join-Path $work 'Blackout.exe'
$txt   = Join-Path $work 'todo.txt'
$ini   = Join-Path $work 'todo.ini'
$shots = Join-Path $PSScriptRoot 'shots'
$fail  = @()
$INPUT_SIZE = [Runtime.InteropServices.Marshal]::SizeOf([type]'N+INPUT')

function Check($name, $cond) {
  if ($cond) { Write-Host "  PASS  $name" } else { Write-Host "  FAIL  $name"; $script:fail += $name }
}

function TypeUnicode([string]$s) {
  foreach ($ch in $s.ToCharArray()) {
    # 必须单独构造 KEYBDINPUT：对装箱结构体做 $x.ki.wScan = v 改的是临时副本，
    # 静默无效。
    $kd = New-Object N+KEYBDINPUT; $kd.wScan = [uint16]$ch; $kd.dwFlags = $UNICODE
    $ku = New-Object N+KEYBDINPUT; $ku.wScan = [uint16]$ch; $ku.dwFlags = $UNICODE -bor $KEYUP
    $d = New-Object N+INPUT; $d.type = 1; $d.ki = $kd
    $u = New-Object N+INPUT; $u.type = 1; $u.ki = $ku
    [N]::SendInput(2, [N+INPUT[]]@($d, $u), $INPUT_SIZE) | Out-Null
    Start-Sleep -Milliseconds 30
  }
}

function Key([int]$vk) {
  [N]::keybd_event($vk,0,0,[IntPtr]::Zero)
  Start-Sleep -Milliseconds 40
  [N]::keybd_event($vk,0,$KEYUP,[IntPtr]::Zero)
}

function Hotkey {
  [N]::keybd_event($VK_CTRL,0,0,[IntPtr]::Zero)
  [N]::keybd_event($VK_SHIFT,0,0,[IntPtr]::Zero)
  [N]::keybd_event($VK_OEM3,0,0,[IntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [N]::keybd_event($VK_OEM3,0,$KEYUP,[IntPtr]::Zero)
  [N]::keybd_event($VK_SHIFT,0,$KEYUP,[IntPtr]::Zero)
  [N]::keybd_event($VK_CTRL,0,$KEYUP,[IntPtr]::Zero)
  Start-Sleep -Milliseconds 900
}

# 只截覆盖层窗口那块矩形，像素坐标就直接是窗口内坐标，便于判断边距
function ShotWindow($hwnd, $name) {
  $r = New-Object N+RECT
  [N]::GetWindowRect($hwnd, [ref]$r) | Out-Null
  $w = $r.R - $r.L; $h = $r.B - $r.T
  $bmp = New-Object Drawing.Bitmap $w, $h
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
  $path = Join-Path $shots "$name.png"
  $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  return @{ Path = $path; W = $w; H = $h }
}

# 换一份清单内容，重新弹出，做像素断言
function CheckRender($hwnd, $name, $content, $expectBands) {
  Start-Sleep -Milliseconds 1100    # 让文件 mtime 确实变化
  [IO.File]::WriteAllText($txt, $content, (New-Object Text.UTF8Encoding $true))
  Hotkey
  if (-not [N]::IsWindowVisible($hwnd)) { Check "$name : overlay visible" $false; return }
  $shot = ShotWindow $hwnd $name
  $a = [PX]::Analyze($shot.Path, 128, 8)
  $bands = $a[0]; $minY = $a[1]; $maxX = $a[2]; $maxY = $a[3]
  $contentRight = $shot.W - [int]($shot.W * 6 / 100)
  Write-Host ("  [$name] bands=$bands  topY=$minY  bottomY=$maxY  rightX=$maxX  (content right edge $contentRight)")
  # 带数少了 = 第一行被滚出屏幕；带数多了 = 长行被自动折行
  Check "$name : 文字带数 == $expectBands 行（不折行、不丢行）" ($bands -eq $expectBands)
  Check "$name : 顶部未被裁切" ($minY -gt 0)
  # 文本被控件右边界硬裁时，最右亮像素会紧贴边界
  Check "$name : 最长行未被右边界裁掉" ($maxX -lt ($contentRight - 8))
  Hotkey
}

# ---------- 隔离环境
Write-Host "stopping every Blackout instance (a global hotkey can only belong to one process)"
Get-Process Blackout -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work  | Out-Null
New-Item -ItemType Directory -Force $shots | Out-Null
Copy-Item (Join-Path $repo 'bin\Blackout.exe') $exe -Force
@"
[hotkey]
mods=ctrl+shift
key=``
[display]
font=Microsoft YaHei UI
bold=1
minsize=24
maxsize=400
"@ | Set-Content $ini -Encoding UTF8
Write-Host "sandbox = $work  (bin\todo.txt is never touched)"
Write-Host ("screen = {0}x{1}" -f [N]::GetSystemMetrics(78), [N]::GetSystemMetrics(79))

# 种子数据：裸 LF + 中文 + 无 BOM，同时压两条回退路径
$seed = "写完 Blackout 的验收测试`n给爸妈打电话`n交房租"
[IO.File]::WriteAllBytes($txt, [Text.Encoding]::UTF8.GetBytes($seed))

# ---------- 启动
$proc = Start-Process $exe -PassThru
Start-Sleep -Milliseconds 1500
Check "process alive after launch" (-not $proc.HasExited)

$hwnd = [N]::FindWindowW("BlackoutOverlayWnd", [IntPtr]::Zero)
Check "overlay window created" ($hwnd -ne [IntPtr]::Zero)
if ($hwnd -eq [IntPtr]::Zero) { Write-Host "cannot continue without hwnd"; exit 1 }
$hedit = [N]::FindWindowExW($hwnd, [IntPtr]::Zero, "EDIT", [IntPtr]::Zero)
Check "EDIT child created" ($hedit -ne [IntPtr]::Zero)
Check "overlay hidden at startup" (-not [N]::IsWindowVisible($hwnd))

$proc.Refresh()
$idleWs = $proc.WorkingSet64
Write-Host ("  idle: working set {0:N0} KB / private {1:N0} KB" -f ($idleWs/1KB), ($proc.PrivateMemorySize64/1KB))
Check "idle working set under 1 MB (never shown yet)" ($idleWs -lt 1MB)

# ---------- 热键 Ctrl+Shift+`
Hotkey
Check "overlay visible after Ctrl+Shift+backtick" ([N]::IsWindowVisible($hwnd))
Check "overlay is foreground" ([N]::GetForegroundWindow() -eq $hwnd)

$rw = New-Object N+RECT; [N]::GetWindowRect($hwnd,  [ref]$rw) | Out-Null
$re = New-Object N+RECT; [N]::GetWindowRect($hedit, [ref]$re) | Out-Null
$sw = [N]::GetSystemMetrics(0); $sh = [N]::GetSystemMetrics(1)
Write-Host ("  window rect {0},{1} {2}x{3}" -f $rw.L,$rw.T,($rw.R-$rw.L),($rw.B-$rw.T))
Write-Host ("  edit   rect {0},{1} {2}x{3}" -f $re.L,$re.T,($re.R-$re.L),($re.B-$re.T))
Check "overlay covers a full monitor" ((($rw.R-$rw.L) -ge $sw) -and (($rw.B-$rw.T) -ge $sh))
Check "edit stays inside overlay horizontally" (($re.L -ge $rw.L) -and ($re.R -le $rw.R))
Check "edit stays inside overlay vertically"   (($re.T -ge $rw.T) -and ($re.B -le $rw.B))
Check "edit is vertically centred" ([Math]::Abs(($re.T - $rw.T) - ($rw.B - $re.B)) -le 4)

# ---------- 打字（走 EDIT 控件的 unicode 路径）
Key 0x23   # End
TypeUnicode "`r`n买咖啡豆 buy coffee"
Start-Sleep -Milliseconds 800
$re2 = New-Object N+RECT; [N]::GetWindowRect($hedit, [ref]$re2) | Out-Null
Check "edit grew after typing" (($re2.B-$re2.T) -gt ($re.B-$re.T))
Check "edit still vertically centred" ([Math]::Abs(($re2.T - $rw.T) - ($rw.B - $re2.B)) -le 4)

# ---------- Esc 保存并隐藏
Key $VK_ESC
Start-Sleep -Milliseconds 800
Check "overlay hidden after Esc" (-not [N]::IsWindowVisible($hwnd))

$bytes = [IO.File]::ReadAllBytes($txt)
$text  = [IO.File]::ReadAllText($txt)
Check "saved with UTF-8 BOM" ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Check "saved with CRLF"       ($text -match "`r`n")
Check "no bare LF left"       (-not ($text -match "(?<!`r)`n"))
Check "typed text persisted"  ($text -match "买咖啡豆 buy coffee")
Check "seeded text preserved" ($text -match "给爸妈打电话")

$proc.Refresh()
$pv1 = $proc.PrivateMemorySize64
Write-Host ("  after 1st hide: working set {0:N0} KB / private {1:N0} KB" -f ($proc.WorkingSet64/1KB), ($pv1/1KB))
# 首次显示会一次性加载 DirectWrite / TSF 输入法栈（~25 个 DLL），不可回收。
# 有意义的指标是"用过之后还稳不稳"，不是绝对值。
Check "working set under 8 MB after hiding" ($proc.WorkingSet64 -lt 8MB)

# ---------- 像素级渲染回归（本次修的 bug 就靠这几条）
# 1. 用户真实清单：第三行长到曾经会被自动折行，没有尾部空行
CheckRender $hwnd '01-user-list-3-lines' "答辩准备`r`nCoding题复习`r`nAI Engineer Agentic Track" 3
# 2. 单行超长：不许折行，也不许被右边界裁掉
CheckRender $hwnd '02-one-very-long-line' "把这条写得非常非常长 an extremely long single task that used to wrap" 1
# 3. 12 行：验证另一端，高度约束生效
CheckRender $hwnd '03-twelve-lines' ((1..12 | ForEach-Object { "第 $_ 件事 task $_" }) -join "`r`n") 12
# 4. 每行都很长的多行清单
CheckRender $hwnd '04-four-long-lines' (@(
  "AI Engineer Agentic Track 复习",
  "Coding 题复习 leetcode hard",
  "答辩准备 slides and demo script",
  "买咖啡豆 buy coffee beans today") -join "`r`n") 4

$proc.Refresh()
Write-Host ("  after many cycles: working set {0:N0} KB / private {1:N0} KB" -f ($proc.WorkingSet64/1KB), ($proc.PrivateMemorySize64/1KB))
Check "no commit growth across cycles" ($proc.PrivateMemorySize64 -lt ($pv1 + 2MB))

# ---------- 外部改动会被重新加载
Start-Sleep -Milliseconds 1100
[IO.File]::WriteAllText($txt, "外部改的内容`r`n第二行", (New-Object Text.UTF8Encoding $true))
Hotkey
Check "overlay visible on hotkey" ([N]::IsWindowVisible($hwnd))
Hotkey
Check "hotkey toggles overlay back off" (-not [N]::IsWindowVisible($hwnd))

# ---------- 托盘菜单命令（菜单外观仍需人眼确认）
$WM_COMMAND = 0x0111
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runVal = 'Blackout'
Remove-ItemProperty $runKey -Name $runVal -ErrorAction SilentlyContinue

[N]::PostMessageW($hwnd, $WM_COMMAND, [IntPtr]100, [IntPtr]::Zero) | Out-Null   # IDM_SHOW
Start-Sleep -Milliseconds 700
Check "tray menu 'show' command works" ([N]::IsWindowVisible($hwnd))
Key $VK_ESC
Start-Sleep -Milliseconds 600

[N]::PostMessageW($hwnd, $WM_COMMAND, [IntPtr]102, [IntPtr]::Zero) | Out-Null   # IDM_STARTUP on
Start-Sleep -Milliseconds 500
$regOn = (Get-ItemProperty $runKey -Name $runVal -ErrorAction SilentlyContinue).$runVal
Check "startup toggle writes Run key" ($regOn -and $regOn -match 'Blackout\.exe')
[N]::PostMessageW($hwnd, $WM_COMMAND, [IntPtr]102, [IntPtr]::Zero) | Out-Null   # IDM_STARTUP off
Start-Sleep -Milliseconds 500
Check "startup toggle removes Run key" ($null -eq (Get-ItemProperty $runKey -Name $runVal -ErrorAction SilentlyContinue))

# ---------- 单实例
$p2 = Start-Process $exe -PassThru
Start-Sleep -Milliseconds 900
Check "second instance exits immediately" ($p2.HasExited)
Check "still exactly one Blackout process" (@(Get-Process Blackout -ErrorAction SilentlyContinue).Count -eq 1)

# ---------- 干净退出
[N]::PostMessageW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
Start-Sleep -Milliseconds 900
$proc.Refresh()
Check "exits cleanly on WM_CLOSE" ($proc.HasExited)

Write-Host ""
Write-Host "screenshots -> $shots"
Write-Host "NOTE: every Blackout instance was stopped for this run; restart yours if you want it back."
if ($fail.Count -eq 0) { Write-Host "E2E: ALL PASS" }
else { Write-Host ("E2E FAILURES ({0}): {1}" -f $fail.Count, ($fail -join '; ')) }
