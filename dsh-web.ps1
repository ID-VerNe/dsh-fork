#!/usr/bin/env pwsh
<#
.SYNOPSIS
  GUI launcher for DeepSeek Harness Web UI — system tray + WinForms frontend
.NOTES
  Requires:  Windows, PowerShell 5.1+, pnpm on PATH
  Place in  the repository root and run directly.
#>
#Requires -Version 5.1

# Use the script directory as project root
Set-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ProjectDir = $PWD.Path

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Node resolution ─────────────────────────────────────────────────────────
$localNode = [System.IO.Path]::Combine($ProjectDir, ".dsh", "node", "node.exe")
$homeNode  = [System.IO.Path]::Combine($env:USERPROFILE, ".dsh", "node", "node.exe")
if (Test-Path $localNode) { $script:nodeExe = $localNode }
elseif (Test-Path $homeNode) { $script:nodeExe = $homeNode }
else { $script:nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source }
if (-not $script:nodeExe -or -not (Test-Path $script:nodeExe)) {
  $null = [System.Windows.Forms.MessageBox]::Show("node not found. Please install Node.js ^22.19 or >=24.", "dsh Web Launcher", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
  exit 1
}

# ── Config persistence ──────────────────────────────────────────────────────
$configPath = [System.IO.Path]::Combine($ProjectDir, ".dsh-web-launcher-config.json")
if (Test-Path $configPath) {
  try { $config = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable } catch { $config = @{} }
} else { $config = @{} }
function Save-Config { param($HostAddr, $Port, $TrustedHosts)
  @{host=$HostAddr; port=$Port; trustedHosts=$TrustedHosts} | ConvertTo-Json -Compress | Set-Content $configPath
}

# ── Process state ───────────────────────────────────────────────────────────
$script:procObj   = $null
$script:isRunning = $false
$script:url       = ""

function Start-dshService {
  param($HostAddr, $Port, $TrustedHosts)

  $dshEntry = [System.IO.Path]::Combine($ProjectDir, "apps", "cli", "src", "bin.ts")
  $pwDir = $ProjectDir
  $nodeExe = $script:nodeExe
  $formRef = $form

  # Build argument string: --import tsx/esm <entry> web --host <h> --port <p>
  $args = "--import tsx/esm `"$dshEntry`" web --host $HostAddr --port $Port"
  if ($TrustedHosts) {
    foreach ($h in ($TrustedHosts -split "\s+" | Where-Object { $_ })) {
      $args += " --trusted-host $h"
    }
  }
  Save-Config $HostAddr $Port $TrustedHosts

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $nodeExe
  $psi.Arguments              = $args
  $psi.WorkingDirectory       = $pwDir
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true

  try {
    $proc = [System.Diagnostics.Process]::Start($psi)
  } catch {
    $null = $formRef.Invoke([Action]{ Set-UIStatus "Failed to start: $($_.Exception.Message)" "Red" "Start" })
    return
  }

  $script:procObj   = $proc
  $script:isRunning = $true
  $script:url       = ""

  # Read stdout for URL
  $reader = $proc.StandardOutput
  $errRdr = $proc.StandardError
  $null = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
    try {
      while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { break }
        if ($line -match "(https?://\S+)") {
          $script:url = $matches[0]
          $null = $formRef.Invoke([Action]{ On-ProcessReady })
        }
      }
    } catch { }
  })
  $null = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
    $lastErr = ""
    try {
      while ($true) {
        $line = $errRdr.ReadLine()
        if ($null -eq $line) { break }
        if ($line) { $lastErr = $line }
      }
    } catch { }
    if ($lastErr -and -not $script:url) {
      $null = $formRef.Invoke([Action]{ $script:urlLabel.Text = "Error: $lastErr" })
    }
  })
  $null = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
    $proc.WaitForExit()
    $script:isRunning = $false
    if ($script:url) { $null = $formRef.Invoke([Action]{ On-ProcessExited }) }
    else { $null = $formRef.Invoke([Action]{ On-ProcessFailed }) }
  })

  Set-UIStatus "Starting..." "DarkOrange" "Stop"
}

function Stop-dshService {
  if ($script:procObj -and -not $script:procObj.HasExited) {
    $script:procObj.Kill($true)
    $null = $script:procObj.WaitForExit(5000)
  }
  $script:procObj = $null; $script:isRunning = $false; $script:url = ""
  Set-UIStatus "Stopped" "Gray" "Start"
}

function Set-UIStatus { param($Text, $Color, $ButtonText)
  $script:urlLabel.Text = $Text
  $script:urlLabel.ForeColor = [System.Drawing.Color]::$Color
  $script:startButton.Text = $ButtonText
  $script:startButton.Enabled = $true
  $script:trayIcon.Text = "dsh Web -- $Text"
}

function On-ProcessReady {
  Set-UIStatus "Running at $script:url" "Green" "Stop"
  $script:trayIcon.ShowBalloonTip(3000, "dsh Web", "Service started`n$script:url", [System.Windows.Forms.ToolTipIcon]::Info)
  Start-Process $script:url
}
function On-ProcessExited { Set-UIStatus "Stopped" "Gray" "Start" }
function On-ProcessFailed { Set-UIStatus "Start failed" "Red" "Start" }

# ── Tray icon ───────────────────────────────────────────────────────────────
function New-TrayIcon {
  $bmp = New-Object System.Drawing.Bitmap 16, 16
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 120, 215))
  $g.FillEllipse($brush, 2, 2, 12, 12); $g.Dispose(); $brush.Dispose()
  $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon()); $bmp.Dispose()
  return $icon
}

# ── Build form ──────────────────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.Text = "dsh Web Launcher"
$form.ClientSize = New-Object System.Drawing.Size(400, 240)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false; $form.ShowIcon = $false
$form.TopMost = $true
$form.Add_Shown({ $form.Activate(); $form.TopMost = $false })

# Host
$hostLabel = New-Object System.Windows.Forms.Label
$hostLabel.Text = "Host:"; $hostLabel.Location = New-Object System.Drawing.Point(15, 15)
$hostLabel.Size = New-Object System.Drawing.Size(55, 25)
$hostBox = New-Object System.Windows.Forms.TextBox
$hostBox.Text = if ($config.host) { $config.host } else { "127.0.0.1" }
$hostBox.Location = New-Object System.Drawing.Point(75, 13); $hostBox.Size = New-Object System.Drawing.Size(310, 23)

# Port
$portLabel = New-Object System.Windows.Forms.Label
$portLabel.Text = "Port:"; $portLabel.Location = New-Object System.Drawing.Point(15, 50)
$portLabel.Size = New-Object System.Drawing.Size(55, 25)
$portBox = New-Object System.Windows.Forms.TextBox
$portBox.Text = if ($config.port) { $config.port } else { "34567" }
$portBox.Location = New-Object System.Drawing.Point(75, 48); $portBox.Size = New-Object System.Drawing.Size(100, 23)

# Trusted Hosts
$thLabel = New-Object System.Windows.Forms.Label
$thLabel.Text = "Trusted:"; $thLabel.Location = New-Object System.Drawing.Point(15, 85)
$thLabel.Size = New-Object System.Drawing.Size(55, 25)
$thBox = New-Object System.Windows.Forms.TextBox
$thBox.Text = if ($config.trustedHosts) { $config.trustedHosts } else { "" }
$thBox.Location = New-Object System.Drawing.Point(75, 83); $thBox.Size = New-Object System.Drawing.Size(310, 23)

# Hint
$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Text = "0.0.0.0 = listen on all interfaces (LAN)  |  space-separate multiple Trusted Hosts"
$hintLabel.Location = New-Object System.Drawing.Point(75, 110); $hintLabel.Size = New-Object System.Drawing.Size(310, 20)
$hintLabel.ForeColor = [System.Drawing.Color]::Gray
$hintLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei", 8)

# Status label
$script:urlLabel = New-Object System.Windows.Forms.Label
$script:urlLabel.Text = "Ready"
$script:urlLabel.Location = New-Object System.Drawing.Point(15, 150)
$script:urlLabel.Size = New-Object System.Drawing.Size(370, 25)
$script:urlLabel.ForeColor = [System.Drawing.Color]::Gray

# Start button
$script:startButton = New-Object System.Windows.Forms.Button
$script:startButton.Text = "Start"
$script:startButton.Location = New-Object System.Drawing.Point(15, 185)
$script:startButton.Size = New-Object System.Drawing.Size(100, 30)
$script:startButton.Add_Click({
  $script:startButton.Enabled = $false
  if ($script:isRunning) { Stop-dshService; Start-Sleep 1 }
  Start-dshService -HostAddr $hostBox.Text.Trim() -Port $portBox.Text.Trim() -TrustedHosts $thBox.Text.Trim()
})

# ── Tray ────────────────────────────────────────────────────────────────────
$script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:trayIcon.Icon = New-TrayIcon
$script:trayIcon.Text = "dsh Web -- Stopped"
$script:trayIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $menu.Items.Add("Open in browser", $null, {
  if ($script:url) { Start-Process $script:url }
  else { Start-Process "http://localhost:$($portBox.Text)" }
})
$null = $menu.Items.Add("Show window", $null, {
  $form.Show(); $form.WindowState = "Normal"; $form.Activate()
})
$null = $menu.Items.Add("-")
$null = $menu.Items.Add("Exit", $null, {
  Stop-dshService; $script:trayIcon.Visible = $false; $script:trayIcon.Dispose(); $form.Close()
})
$script:trayIcon.ContextMenuStrip = $menu
$script:trayIcon.Add_MouseDoubleClick({ $form.Show(); $form.WindowState = "Normal"; $form.Activate() })

$form.Add_Resize({ if ($form.WindowState -eq "Minimized") { $form.Hide() } })
$form.Add_FormClosing({
  param($s, $e)
  if ($script:isRunning) {
    $r = [System.Windows.Forms.MessageBox]::Show("dsh is running. Exit will stop the service. Exit anyway?", "dsh Web Launcher", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -eq "No") { $e.Cancel = $true; $form.Hide(); return }
    Stop-dshService
  }
  $script:trayIcon.Visible = $false; $script:trayIcon.Dispose()
})

$form.Controls.AddRange(@($hostLabel, $hostBox, $portLabel, $portBox, $thLabel, $thBox, $hintLabel, $script:urlLabel, $script:startButton))

# ── Go ──────────────────────────────────────────────────────────────────────
$null = $form.ShowDialog()
$script:trayIcon.Dispose()