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

function Normalize-BlockArray {
    param(
        [Parameter(Mandatory)]
        [object]$ConfigObject
    )

    if ($null -ne $ConfigObject.blocks) {
        return @($ConfigObject.blocks)
    }

    if ($null -ne $ConfigObject.steps) {
        $normalizedBlocks = New-Object System.Collections.Generic.List[object]

        if ($null -ne $ConfigObject.startupDelaySeconds -and [int]$ConfigObject.startupDelaySeconds -gt 0) {
            $normalizedBlocks.Add([pscustomobject]@{
                type = 'delay'
                seconds = [int]$ConfigObject.startupDelaySeconds
            })
        }

        foreach ($step in @($ConfigObject.steps)) {
            if ($null -ne $step.delaySeconds -and [int]$step.delaySeconds -gt 0) {
                $normalizedBlocks.Add([pscustomobject]@{
                    type = 'delay'
                    seconds = [int]$step.delaySeconds
                })
            }

            $normalizedBlocks.Add([pscustomobject]@{
                type = 'step'
                name = $step.name
                scripts = $step.scripts
            })
        }

        Write-LauncherLog -Level 'WARN' -Message 'Legacy-Config erkannt. Bitte auf das neue blocks-Format umstellen.'
        return @($normalizedBlocks)
    }

    return @()
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

function Invoke-DelayBlock {
    param(
        [object]$DelayBlock
    )

    $delaySeconds = 0
    if ($null -ne $DelayBlock.seconds) {
        $delaySeconds = [int]$DelayBlock.seconds
    }

    if ($delaySeconds -gt 0) {
        Write-LauncherLog -Message "Warte $delaySeconds Sekunden."
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
    $blocks = Normalize-BlockArray -ConfigObject $config

    if ($blocks.Count -eq 0) {
        throw "Die Config enthaelt keine Blocks."
    }

    foreach ($block in $blocks) {
        $blockType = [string]$block.type

        switch ($blockType) {
            'delay' {
                Invoke-DelayBlock -DelayBlock $block
            }

            'step' {
                $stepName = if ($block.name) { [string]$block.name } else { 'unnamed-step' }
                $scripts = @($block.scripts)

                if ($scripts.Count -eq 0) {
                    Write-LauncherLog -Level 'WARN' -Message "Step '$stepName' hat keine Scripts."
                    continue
                }

                foreach ($scriptEntry in $scripts) {
                    Start-ConfiguredScript -ScriptEntry $scriptEntry -StepName $stepName
                }
            }

            default {
                throw "Unbekannter Block-Typ: $blockType"
            }
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
