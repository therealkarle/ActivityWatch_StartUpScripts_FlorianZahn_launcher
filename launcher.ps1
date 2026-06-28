[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-LauncherLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp][$Level] $Message"
}

function Resolve-ExistingConfigPath {
    param(
        [string]$PrimaryPath
    )

    if (Test-Path -LiteralPath $PrimaryPath -PathType Leaf) {
        return (Resolve-Path -LiteralPath $PrimaryPath).Path
    }

    $examplePath = Join-Path $PSScriptRoot 'config.example.json'
    if (Test-Path -LiteralPath $examplePath -PathType Leaf) {
        Write-LauncherLog -Level 'WARN' -Message "config.json nicht gefunden. Fallback auf config.example.json."
        return (Resolve-Path -LiteralPath $examplePath).Path
    }

    throw "Keine Config gefunden. Erwartet: $PrimaryPath oder $examplePath"
}

function Resolve-ScriptTarget {
    param(
        [Parameter(Mandatory)]
        [object]$ScriptEntry
    )

    if (-not $ScriptEntry.path) {
        throw "Ein Script-Eintrag ist unvollstaendig: 'path' fehlt."
    }

    $entryPath = [string]$ScriptEntry.path
    if (-not (Test-Path -LiteralPath $entryPath)) {
        throw "Script-Pfad existiert nicht: $entryPath"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $entryPath).Path

    if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
        return $resolvedPath
    }

    if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
        if ($ScriptEntry.scriptFile) {
            $candidate = Join-Path $resolvedPath ([string]$ScriptEntry.scriptFile)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }

            throw "scriptFile wurde angegeben, existiert aber nicht: $candidate"
        }

        $ps1Files = @(Get-ChildItem -LiteralPath $resolvedPath -Filter '*.ps1' -File -Recurse)
        if ($ps1Files.Count -eq 1) {
            return $ps1Files[0].FullName
        }

        if ($ps1Files.Count -eq 0) {
            throw "Im Ordner wurde keine .ps1-Datei gefunden: $resolvedPath"
        }

        $fileList = $ps1Files | Select-Object -ExpandProperty FullName
        throw "Im Ordner wurden mehrere .ps1-Dateien gefunden. Bitte 'scriptFile' setzen: $resolvedPath`n$($fileList -join [Environment]::NewLine)"
    }

    throw "Unerwarteter Pfadtyp: $resolvedPath"
}

function Start-ConfiguredScript {
    param(
        [Parameter(Mandatory)]
        [object]$ScriptEntry,

        [Parameter(Mandatory)]
        [string]$StepName
    )

    $isEnabled = $true
    if ($null -ne $ScriptEntry.enabled) {
        $isEnabled = [bool]$ScriptEntry.enabled
    }

    if (-not $isEnabled) {
        $scriptLabel = if ($ScriptEntry.name) { [string]$ScriptEntry.name } else { [string]$ScriptEntry.path }
        Write-LauncherLog -Message "Uebersprungen (deaktiviert): $scriptLabel"
        return
    }

    $scriptPath = Resolve-ScriptTarget -ScriptEntry $ScriptEntry
    $workingDirectory = Split-Path -Path $scriptPath -Parent

    if ($ScriptEntry.workingDirectory) {
        $workingDirectory = (Resolve-Path -LiteralPath ([string]$ScriptEntry.workingDirectory)).Path
    }

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', $scriptPath
    )

    if ($ScriptEntry.arguments) {
        if ($ScriptEntry.arguments -is [System.Collections.IEnumerable] -and -not ($ScriptEntry.arguments -is [string])) {
            $arguments += @($ScriptEntry.arguments)
        }
        else {
            $arguments += [string]$ScriptEntry.arguments
        }
    }

    $scriptLabel = if ($ScriptEntry.name) { [string]$ScriptEntry.name } else { $scriptPath }
    Write-LauncherLog -Message "Starte Script in Step '$StepName': $scriptLabel"

    Start-Process -FilePath $powershellExe -ArgumentList $arguments -WorkingDirectory $workingDirectory -WindowStyle Hidden | Out-Null
}

function Invoke-StepDelay {
    param(
        [object]$Step,
        [string]$StepName
    )

    $delaySeconds = 0
    if ($null -ne $Step.delaySeconds) {
        $delaySeconds = [int]$Step.delaySeconds
    }

    if ($delaySeconds -gt 0) {
        Write-LauncherLog -Message "Warte $delaySeconds Sekunden vor Step '$StepName'."
        Start-Sleep -Seconds $delaySeconds
    }
}

function Invoke-Launcher {
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedConfigPath
    )

    Write-LauncherLog -Message "Nutze Config: $ResolvedConfigPath"

    $config = Get-Content -LiteralPath $ResolvedConfigPath -Raw | ConvertFrom-Json

    $steps = @($config.steps)
    if ($steps.Count -eq 0) {
        throw "Die Config enthaelt keine Steps."
    }

    $startupDelaySeconds = 0
    if ($null -ne $config.startupDelaySeconds) {
        $startupDelaySeconds = [int]$config.startupDelaySeconds
    }

    if ($startupDelaySeconds -gt 0) {
        Write-LauncherLog -Message "Warte $startupDelaySeconds Sekunden nach Startup."
        Start-Sleep -Seconds $startupDelaySeconds
    }

    foreach ($step in $steps) {
        $stepName = if ($step.name) { [string]$step.name } else { 'unnamed-step' }
        Invoke-StepDelay -Step $step -StepName $stepName

        $scripts = @($step.scripts)
        if ($scripts.Count -eq 0) {
            Write-LauncherLog -Level 'WARN' -Message "Step '$stepName' hat keine Scripts."
            continue
        }

        foreach ($scriptEntry in $scripts) {
            Start-ConfiguredScript -ScriptEntry $scriptEntry -StepName $stepName
        }
    }
}

try {
    $resolvedConfigPath = Resolve-ExistingConfigPath -PrimaryPath $ConfigPath
    Invoke-Launcher -ResolvedConfigPath $resolvedConfigPath
    Write-LauncherLog -Message 'Alle konfigurierten Scripts wurden angestossen.'
}
catch {
    Write-LauncherLog -Level 'ERROR' -Message $_.Exception.Message
    exit 1
}
