# Agent Lights, Windows side: the pill. From the repo folder (the Linux installer prints this line for you):
#   powershell -ExecutionPolicy Bypass -File .\windows\install.ps1 -Server <host> -Token <token> -SshHost <you@host>
# Re-run without arguments after an update: the saved settings are kept.
# Touches only: %LOCALAPPDATA%\AgentLights (the pill), %APPDATA%\AgentLights (settings, position) and a
# Startup-folder shortcut. No SSH keys, SSH config or Windows Terminal settings are changed.
param(
    [string]$Server = "",       # agent machine address(es): host, host:port or a full URL; comma-separated
    [string]$Token = "",        # contents of ~/.config/agent-lights/token on the agent machine
    [string]$SshHost = "",      # what you type after `ssh` to reach it, e.g. you@192.168.1.20
    [string]$OpenCmd = "",      # default ~/.local/bin/agent-lights-open
    [string]$TermProfile = ""   # a Windows Terminal profile name; empty = your default profile
)
$ErrorActionPreference = "Stop"
$src  = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $env:LOCALAPPDATA "AgentLights"
$cfgDir = Join-Path $env:APPDATA "AgentLights"
$cfgFile = Join-Path $cfgDir "config.json"

if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    Write-Host "Windows Terminal (wt.exe) was not found. Install it from the Microsoft Store, then run this again." -ForegroundColor Yellow
}

# 1) settings: keep what's saved, overwrite only what was passed
New-Item -ItemType Directory -Force $cfgDir | Out-Null
$cfg = [ordered]@{ server = ""; token = ""; sshHost = ""; openCmd = ""; termProfile = "" }
if (Test-Path $cfgFile) {
    try {
        $old = Get-Content -Raw $cfgFile | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) { if ($old.$k) { $cfg[$k] = [string]$old.$k } }
    } catch { Write-Host "  (couldn't read the old config.json, starting fresh)" }
}
if ($Server)      { $cfg.server = $Server }
if ($Token)       { $cfg.token = $Token.Trim() }
if ($SshHost)     { $cfg.sshHost = $SshHost }
if ($OpenCmd)     { $cfg.openCmd = $OpenCmd }
if ($TermProfile) { $cfg.termProfile = $TermProfile }
($cfg | ConvertTo-Json) | Set-Content -Encoding UTF8 $cfgFile
if (-not $cfg.server -or -not $cfg.token) {
    Write-Host "[1/4] settings saved, but -Server and -Token are still missing: the pill will say 'not set up'." -ForegroundColor Yellow
} else {
    Write-Host "[1/4] settings saved: $cfgFile (server $($cfg.server), ssh $($cfg.sshHost))"
}

# 2) copy the pill
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $src "AgentLights.ps1") $dest -Force
Write-Host "[2/4] pill copied to $dest"

# 3) start with Windows
$startup = [Environment]::GetFolderPath("Startup")
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $startup "Agent Lights.lnk"))
$lnk.TargetPath = "powershell.exe"
$lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dest\AgentLights.ps1`""
$lnk.WindowStyle = 7
$lnk.Save()
Write-Host "[3/4] starts automatically when you log in"

# 4) (re)launch now
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like "*AgentLights.ps1*" -and $_.ProcessId -ne $PID } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$dest\AgentLights.ps1`""
Write-Host "[4/4] pill running (top-right): one dot per agent session in a terminal tab. Hover it to see which is which."
Write-Host ""
Write-Host "Click the pill = your terminal on top; your game keeps the keyboard and its sound. Click into the terminal to type."
Write-Host "Click the pill again = tuck it away (the keyboard goes back to your game). Drag = move. Hover = which dot is which."
Write-Host "Right-click = each dot (C1, C2...) with Open (attach it in a new tab) or Close."
Write-Host "Games: use borderless / windowed fullscreen. Nothing can draw over exclusive fullscreen."
