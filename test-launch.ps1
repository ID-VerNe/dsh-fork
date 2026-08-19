$ProjectDir = "C:\Users\VerNe\Downloads\Documents\deepseek-harness"

# Mirror dsh-web.ps1 resolution exactly
$localNode = [System.IO.Path]::Combine($ProjectDir, ".dsh", "node", "node.exe")
$homeNode  = [System.IO.Path]::Combine($env:USERPROFILE, ".dsh", "node", "node.exe")
if (Test-Path $localNode) { $nodeExe = $localNode }
elseif (Test-Path $homeNode) { $nodeExe = $homeNode }
else { $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source }
Write-Output "nodeExe: $nodeExe"

$dshEntry = Join-Path $ProjectDir "apps/cli/src/bin.ts"

$argList = [System.Collections.ArrayList]@(
  "--import", "tsx/esm",
  $dshEntry,
  "web",
  "--host", "127.0.0.1",
  "--port", "34567"
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = $nodeExe
$psi.Arguments              = $argList -join " "
$psi.WorkingDirectory       = $ProjectDir
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true

Write-Output "Launching: $nodeExe $($psi.Arguments)"
try {
  $proc = [System.Diagnostics.Process]::Start($psi)
  Write-Output "Started PID: $($proc.Id)"
} catch {
  Write-Output "LAUNCH FAILED: $($_.Exception.Message)"
  exit 1
}

Start-Sleep -Seconds 10

# Probe the port
$r = Test-NetConnection -ComputerName 127.0.0.1 -Port 34567 -WarningAction SilentlyContinue
Write-Output "Port 34567 open: $($r.TcpTestSucceeded)"

# Dump captured output
Write-Output "=== STDOUT ==="
$out = $proc.StandardOutput.ReadToEnd()
Write-Output $out
Write-Output "=== STDERR ==="
$err = $proc.StandardError.ReadToEnd()
Write-Output $err
Write-Output "=== process alive: $(-not $proc.HasExited) ==="

if (-not $proc.HasExited) {
  $proc.Kill($true)
  $proc.WaitForExit(3000)
}
Write-Output "DONE"