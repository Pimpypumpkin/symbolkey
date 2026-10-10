# Adds (or removes with -Remove) a SymbolKey shortcut to the Windows Startup folder.
# Usage:  powershell -ExecutionPolicy Bypass -File install-startup.ps1 [-Remove]
param([switch]$Remove)

$startup = [Environment]::GetFolderPath('Startup')
$lnk = Join-Path $startup 'SymbolKey.lnk'

if ($Remove) {
    if (Test-Path $lnk) { Remove-Item $lnk; Write-Output "Removed: $lnk" }
    else { Write-Output "Nothing to remove." }
    exit 0
}

$script = Join-Path $PSScriptRoot 'SymbolKey.ahk'
if (-not (Test-Path $script)) { Write-Error "SymbolKey.ahk not found next to this script."; exit 1 }

$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut($lnk)
$s.TargetPath = $script
$s.WorkingDirectory = $PSScriptRoot
$s.Description = 'SymbolKey - Korean name to math symbol converter'
$s.Save()
Write-Output "Created: $lnk"
