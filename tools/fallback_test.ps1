# 验证 init_paths() 的"exe 目录不可写 -> 退回 %LOCALAPPDATA%\Blackout"分支。
# 这条路径至今从未跑过，而便携版 zip 用户完全可能解压到 Program Files。
#
# 真实场景是 Program Files，但那需要管理员权限才能建目录。这里用 ACL 拒绝写入
# 制造同样的条件 —— 程序走的是同一个 dir_writable() 分支，判据完全一样。
$ErrorActionPreference = 'Stop'
Add-Type @'
using System; using System.Runtime.InteropServices;
public class F {
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, IntPtr w);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] i, int cb);
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
    public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT {
    public uint type; public KEYBDINPUT ki; public int pad1, pad2; }
}
'@
$KEYUP=0x0002; $UNICODE=0x0004; $CTRL=0x11; $SHIFT=0x10; $OEM3=0xC0; $ESC=0x1B
$SZ = [Runtime.InteropServices.Marshal]::SizeOf([type]'F+INPUT')
$fail = @()
function Check($n,$c){ if($c){Write-Host "  PASS  $n"} else {Write-Host "  FAIL  $n"; $script:fail+=$n} }
function Hotkey {
  [F]::keybd_event($CTRL,0,0,[IntPtr]::Zero); [F]::keybd_event($SHIFT,0,0,[IntPtr]::Zero)
  [F]::keybd_event($OEM3,0,0,[IntPtr]::Zero); Start-Sleep -Milliseconds 60
  [F]::keybd_event($OEM3,0,$KEYUP,[IntPtr]::Zero)
  [F]::keybd_event($SHIFT,0,$KEYUP,[IntPtr]::Zero); [F]::keybd_event($CTRL,0,$KEYUP,[IntPtr]::Zero)
  Start-Sleep -Milliseconds 900
}
function TypeUnicode([string]$s){
  foreach($ch in $s.ToCharArray()){
    $kd = New-Object F+KEYBDINPUT; $kd.wScan=[uint16]$ch; $kd.dwFlags=$UNICODE
    $ku = New-Object F+KEYBDINPUT; $ku.wScan=[uint16]$ch; $ku.dwFlags=$UNICODE -bor $KEYUP
    $d = New-Object F+INPUT; $d.type=1; $d.ki=$kd
    $u = New-Object F+INPUT; $u.type=1; $u.ki=$ku
    [F]::SendInput(2,[F+INPUT[]]@($d,$u),$SZ) | Out-Null
    Start-Sleep -Milliseconds 30
  }
}

$roDir   = Join-Path $env:TEMP 'BlackoutReadOnly'
$dataDir = Join-Path $env:LOCALAPPDATA 'Blackout'
$srcExe  = 'D:\Projects3\ToDo\bin\Blackout.exe'

Get-Process Blackout -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400
if (Test-Path $roDir) { icacls $roDir /remove:d "$env:USERNAME" | Out-Null }
Remove-Item $roDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $roDir | Out-Null
Copy-Item $srcExe (Join-Path $roDir 'Blackout.exe') -Force

# 先确认 exe 是 64 位：32 位无清单进程写 Program Files 会被 UAC 静默重定向到
# VirtualStore，dir_writable() 就会误判为可写，数据落进一个用户找不到的地方。
# 64 位进程不受文件虚拟化影响，这个陷阱不存在。
$fs = [IO.File]::OpenRead($srcExe)
$br = New-Object IO.BinaryReader $fs
$fs.Position = 0x3C; $peOff = $br.ReadInt32(); $fs.Position = $peOff + 4
$machine = $br.ReadUInt16(); $br.Close()
Check "exe is 64-bit (immune to UAC file virtualization)" ($machine -eq 0x8664)

# 拒绝当前用户在该目录建文件 —— 复刻 Program Files 的效果
icacls $roDir /deny "${env:USERNAME}:(WD,AD)" | Out-Null
$writable = $true
try { [IO.File]::WriteAllText((Join-Path $roDir 'probe.tmp'), 'x'); Remove-Item (Join-Path $roDir 'probe.tmp') -Force }
catch { $writable = $false }
Check "install dir really is non-writable now" (-not $writable)

$proc = Start-Process (Join-Path $roDir 'Blackout.exe') -PassThru
Start-Sleep -Milliseconds 1600
Check "runs from a non-writable directory" (-not $proc.HasExited)

$h = [F]::FindWindowW("BlackoutOverlayWnd", [IntPtr]::Zero)
Check "overlay window created" ($h -ne [IntPtr]::Zero)
Check "did NOT try to write into the non-writable dir" (-not (Test-Path (Join-Path $roDir 'todo.txt')))
Check "fell back to %LOCALAPPDATA%\Blackout" (Test-Path $dataDir)
Check "todo.ini created in the fallback dir" (Test-Path (Join-Path $dataDir 'todo.ini'))

# 真存得进去吗
Hotkey
Check "overlay shows" ([F]::IsWindowVisible($h))
TypeUnicode "survives a read-only install dir"
Start-Sleep -Milliseconds 500
[F]::keybd_event($ESC,0,0,[IntPtr]::Zero); [F]::keybd_event($ESC,0,$KEYUP,[IntPtr]::Zero)
Start-Sleep -Milliseconds 900

$saved = Join-Path $dataDir 'todo.txt'
$ok = (Test-Path $saved) -and ([IO.File]::ReadAllText($saved) -match 'survives a read-only install dir')
Check "task actually persisted to the fallback dir" $ok
if (Test-Path $saved) {
  Write-Host "  saved to: $saved"
  [IO.File]::ReadAllText($saved) -split "`r`n" | ForEach-Object { "    | $_" }
}

# 清理
if ($h -ne [IntPtr]::Zero) { [F]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
Start-Sleep -Milliseconds 900
if (Test-Path $roDir) { icacls $roDir /remove:d "$env:USERNAME" | Out-Null }
Remove-Item $roDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $dataDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($fail.Count -eq 0) { Write-Host "FALLBACK: ALL PASS" } else { Write-Host ("FALLBACK FAILURES: {0}" -f ($fail -join '; ')) }
