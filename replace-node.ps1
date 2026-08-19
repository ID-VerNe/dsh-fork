# Replace global node.exe with 22.19.0 — requires elevation. Place this in the
# project dir and run from an ADMIN PowerShell:  pwsh -File replace-node.ps1
$oldExe = "C:\Program Files\nodejs\node.exe"
$newExe = "C:\Users\VerNe\.dsh\node\node.exe"
if (-not (Test-Path $newExe)) { Write-Error "source node 22.19 missing at $newExe"; exit 1 }

# Kill user-scope node processes (only those we own), then replace
Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Copy-Item $newExe $oldExe -Force
if (-not $?) { Write-Error "copy failed — is the shell elevated?"; exit 1 }

$v = & $oldExe --version
Write-Output "global node: $v"
$z = & $oldExe -e "const z = require('node:zlib'); console.log('zstd:', typeof z.createZstdDecompress);"
Write-Output $z
Write-Output "DONE — restart any open terminals."