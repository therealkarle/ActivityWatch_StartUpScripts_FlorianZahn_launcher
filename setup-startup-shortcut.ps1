[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = $PSScriptRoot
$startupFolder = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupFolder 'ActivityWatch Startup Launcher.lnk'
$wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
$launcherVbs = Join-Path $repoRoot 'launcher.vbs'

if (-not (Test-Path -LiteralPath $launcherVbs -PathType Leaf)) {
    throw "launcher.vbs nicht gefunden: $launcherVbs"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $wscriptExe
$shortcut.Arguments = "`"$launcherVbs`""
$shortcut.WorkingDirectory = $repoRoot
$shortcut.Description = 'ActivityWatch Startup Launcher'
$shortcut.WindowStyle = 7
$shortcut.Save()

Write-Host "Startup-Shortcut erstellt: $shortcutPath"

