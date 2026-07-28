# 生成 README 用的宣传截图。
#
# 用的是中性英文内容，不是任何人的真实清单 —— 这些图会进公开仓库。
# 在临时目录跑 exe 副本，不碰任何现有数据。
#
# 注意：本文件必须存成【带 BOM 的 UTF-8】。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System; using System.Runtime.InteropServices;
public class S {
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, IntPtr w);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr c);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
'@
[S]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

$KEYUP=0x0002; $CTRL=0x11; $SHIFT=0x10; $OEM3=0xC0
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path $env:TEMP 'BlackoutShots'
$out  = Join-Path $repo 'docs'
$exe  = Join-Path $work 'Blackout.exe'
$txt  = Join-Path $work 'todo.txt'

function Hotkey {
  [S]::keybd_event($CTRL,0,0,[IntPtr]::Zero); [S]::keybd_event($SHIFT,0,0,[IntPtr]::Zero)
  [S]::keybd_event($OEM3,0,0,[IntPtr]::Zero); Start-Sleep -Milliseconds 60
  [S]::keybd_event($OEM3,0,$KEYUP,[IntPtr]::Zero)
  [S]::keybd_event($SHIFT,0,$KEYUP,[IntPtr]::Zero); [S]::keybd_event($CTRL,0,$KEYUP,[IntPtr]::Zero)
  Start-Sleep -Milliseconds 1000
}

# 截图后横向缩到 1280 宽：README 里没人需要 2560px 的原图，仓库也不该背这个体积
function Shot($hwnd, $name, $targetW) {
  $r = New-Object S+RECT
  [S]::GetWindowRect($hwnd, [ref]$r) | Out-Null
  $w = $r.R - $r.L; $h = $r.B - $r.T
  $full = New-Object Drawing.Bitmap $w, $h
  $g = [Drawing.Graphics]::FromImage($full)
  $g.CopyFromScreen($r.L, $r.T, 0, 0, $full.Size)
  $g.Dispose()

  $sh = [int]([double]$h * $targetW / $w)
  $small = New-Object Drawing.Bitmap $targetW, $sh
  $g2 = [Drawing.Graphics]::FromImage($small)
  $g2.InterpolationMode = 'HighQualityBicubic'
  $g2.DrawImage($full, 0, 0, $targetW, $sh)
  $g2.Dispose()

  $path = Join-Path $out "$name.png"
  $small.Save($path, [Drawing.Imaging.ImageFormat]::Png)
  $full.Dispose(); $small.Dispose()
  Write-Host ("  {0}  ({1}x{2}, {3:N0} KB)" -f "$name.png", $targetW, $sh, ((Get-Item $path).Length/1KB))
}

Get-Process Blackout -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
New-Item -ItemType Directory -Force $out  | Out-Null
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
"@ | Set-Content (Join-Path $work 'todo.ini') -Encoding UTF8

$proc = Start-Process $exe -PassThru
Start-Sleep -Milliseconds 1500
$hwnd = [S]::FindWindowW("BlackoutOverlayWnd", [IntPtr]::Zero)
if ($hwnd -eq [IntPtr]::Zero) { throw "overlay window not found" }

# 主图：少量任务，字最大，最能说明这软件是干嘛的
[IO.File]::WriteAllText($txt, "Ship the release notes`r`nCall the dentist`r`nStop opening new tabs", (New-Object Text.UTF8Encoding $true))
Hotkey
Shot $hwnd 'screenshot-hero' 1280
Hotkey

# 副图：清单长了字自动缩小，说明自适应
Start-Sleep -Milliseconds 1100
[IO.File]::WriteAllText($txt, (@(
  "Ship the release notes",
  "Call the dentist",
  "Review the pull request",
  "Renew the domain",
  "Book the flight home",
  "Write the weekly update",
  "Cancel the unused subscription",
  "Stop opening new tabs") -join "`r`n"), (New-Object Text.UTF8Encoding $true))
Hotkey
Shot $hwnd 'screenshot-longer-list' 1280
Hotkey

[S]::PostMessageW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
Start-Sleep -Milliseconds 800
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "done -> $out"
