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

function Resolve-PythonExecutable {
    $pythonCommand = Get-Command -Name 'python' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $pythonCommand) {
        return $pythonCommand.Source
    }

    $pyCommand = Get-Command -Name 'py' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $pyCommand) {
        return $pyCommand.Source
    }

    throw "Weder 'python' noch 'py' wurde gefunden."
}

function Resolve-LaunchTarget {
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
    $workingDirectory = $resolvedPath
    $targetPath = $resolvedPath
    $targetKind = $null

    if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
        if ($ScriptEntry.scriptFile) {
            $candidate = Join-Path $resolvedPath ([string]$ScriptEntry.scriptFile)
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                throw "scriptFile wurde angegeben, existiert aber nicht: $candidate"
            }

            $targetPath = (Resolve-Path -LiteralPath $candidate).Path
        }
        elseif (Test-Path -LiteralPath (Join-Path $resolvedPath 'main.py') -PathType Leaf) {
            $targetPath = (Resolve-Path -LiteralPath (Join-Path $resolvedPath 'main.py')).Path
        }
        else {
            $pyFiles = @(Get-ChildItem -LiteralPath $resolvedPath -Filter '*.py' -File)
            if ($pyFiles.Count -eq 1) {
                $targetPath = $pyFiles[0].FullName
            }
            else {
                $ps1Files = @(Get-ChildItem -LiteralPath $resolvedPath -Filter '*.ps1' -File)
                if ($ps1Files.Count -eq 1) {
                    $targetPath = $ps1Files[0].FullName
                }
                elseif ($ps1Files.Count -gt 1) {
                    $fileList = $ps1Files | Select-Object -ExpandProperty FullName
                    throw "Im Ordner wurden mehrere .ps1-Dateien gefunden. Bitte 'scriptFile' setzen: $resolvedPath`n$($fileList -join [Environment]::NewLine)"
                }
                else {
                    throw "Kein eindeutiger Einstiegspunkt gefunden in: $resolvedPath"
                }
            }
        }
    }
    elseif (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
        $targetPath = $resolvedPath
    }
    else {
        throw "Unerwarteter Pfadtyp: $resolvedPath"
    }

    $extension = [System.IO.Path]::GetExtension($targetPath).ToLowerInvariant()
    $arguments = New-Object System.Collections.Generic.List[string]

    if ($ScriptEntry.arguments) {
        if ($ScriptEntry.arguments -is [System.Collections.IEnumerable] -and -not ($ScriptEntry.arguments -is [string])) {
            foreach ($arg in @($ScriptEntry.arguments)) {
                if ($null -ne $arg -and [string]$arg -ne '') {
                    $arguments.Add([string]$arg)
                }
            }
        }
        else {
            $arguments.Add([string]$ScriptEntry.arguments)
        }
    }

    switch ($extension) {
        '.py' {
            $pythonExe = if ($ScriptEntry.pythonExecutable) {
                [string]$ScriptEntry.pythonExecutable
            }
            else {
                Resolve-PythonExecutable
            }

            if ($pythonExe -ieq 'py') {
                $launchArgs = @('-3', $targetPath) + @($arguments)
                return [pscustomobject]@{
                    FilePath = $pythonExe
                    ArgumentList = $launchArgs
                    WorkingDirectory = $workingDirectory
                    DisplayTarget = $targetPath
                }
            }

            return [pscustomobject]@{
                FilePath = $pythonExe
                ArgumentList = @($targetPath) + @($arguments)
                WorkingDirectory = $workingDirectory
                DisplayTarget = $targetPath
            }
        }

        '.ps1' {
            $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            return [pscustomobject]@{
                FilePath = $powershellExe
                ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $targetPath) + @($arguments)
                WorkingDirectory = $workingDirectory
                DisplayTarget = $targetPath
            }
        }

        '.bat' {
            return [pscustomobject]@{
                FilePath = Join-Path $env:SystemRoot 'System32\cmd.exe'
                ArgumentList = @('/c', $targetPath) + @($arguments)
                WorkingDirectory = $workingDirectory
                DisplayTarget = $targetPath
            }
        }

        '.cmd' {
            return [pscustomobject]@{
                FilePath = Join-Path $env:SystemRoot 'System32\cmd.exe'
                ArgumentList = @('/c', $targetPath) + @($arguments)
                WorkingDirectory = $workingDirectory
                DisplayTarget = $targetPath
            }
        }

        default {
            throw "Nicht unterstuetzter Einstiegspunkt: $targetPath"
        }
    }
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

    $launchPlan = Resolve-LaunchTarget -ScriptEntry $ScriptEntry
    $scriptLabel = if ($ScriptEntry.name) { [string]$ScriptEntry.name } else { $launchPlan.DisplayTarget }
    Write-LauncherLog -Message "Starte Script in Step '$StepName': $scriptLabel"

    Start-Process -FilePath $launchPlan.FilePath -ArgumentList $launchPlan.ArgumentList -WorkingDirectory $launchPlan.WorkingDirectory -WindowStyle Hidden | Out-Null
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
