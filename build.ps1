# Builds dist\SymbolKey.exe with Ahk2Exe (symbols.txt is embedded via FileInstall).
# Requires AutoHotkey v2 + Ahk2Exe. If the compiler is missing, run:
#   "<AutoHotkey>\UX\AutoHotkeyUX.exe" "<AutoHotkey>\UX\install-ahk2exe.ahk"
$ErrorActionPreference = 'Stop'

$roots = @("$env:LOCALAPPDATA\Programs\AutoHotkey", "$env:ProgramFiles\AutoHotkey")
$ahk = $roots | Where-Object { Test-Path "$_\v2\AutoHotkey64.exe" } | Select-Object -First 1
if (-not $ahk) { Write-Error "AutoHotkey v2 not found. Install: winget install -e --id AutoHotkey.AutoHotkey"; exit 1 }
$compiler = "$ahk\Compiler\Ahk2Exe.exe"
if (-not (Test-Path $compiler)) { Write-Error "Ahk2Exe not found at $compiler (see comment at top of this script)"; exit 1 }

$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$out = Join-Path $dist 'SymbolKey.exe'
if (Test-Path $out) { Remove-Item $out }

$args = @(
    '/in',   "`"$PSScriptRoot\SymbolKey.ahk`"",
    '/out',  "`"$out`"",
    '/base', "`"$ahk\v2\AutoHotkey64.exe`"",
    '/compress', '0',
    '/silent', 'verbose'
)
$p = Start-Process -FilePath $compiler -ArgumentList $args -WorkingDirectory $PSScriptRoot -PassThru -Wait
if ($p.ExitCode -ne 0 -or -not (Test-Path $out)) { Write-Error "Ahk2Exe failed (exit $($p.ExitCode))"; exit 1 }
Write-Output "Built: $out ($([math]::Round((Get-Item $out).Length / 1KB)) KB)"
