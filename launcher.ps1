[CmdletBinding()]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:LauncherRoot = if ($PSScriptRoot) {
    $PSScriptRoot
}
elseif ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
}
else {
    (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $script:LauncherRoot 'config.json'
}

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

    $examplePath = Join-Path $script:LauncherRoot 'config.example.json'
    if (Test-Path -LiteralPath $examplePath -PathType Leaf) {
        Write-LauncherLog -Level 'WARN' -Message "config.json nicht gefunden. Fallback auf config.example.json."
        return (Resolve-Path -LiteralPath $examplePath).Path
    }

    throw "Keine Config gefunden. Erwartet: $PrimaryPath oder $examplePath"
}

function Get-NormalizedBlockArray {
    param(
        [Parameter(Mandatory)]
        [object]$ConfigObject
    )

    $blocksValue = Get-ConfigPropertyValue -InputObject $ConfigObject -PropertyName 'blocks'
    if ($null -ne $blocksValue) {
        return @($blocksValue)
    }

    $stepsValue = Get-ConfigPropertyValue -InputObject $ConfigObject -PropertyName 'steps'
    if ($null -ne $stepsValue) {
        $normalizedBlocks = New-Object System.Collections.Generic.List[object]

        $startupDelaySeconds = Get-ConfigPropertyValue -InputObject $ConfigObject -PropertyName 'startupDelaySeconds'
        if ($null -ne $startupDelaySeconds -and [int]$startupDelaySeconds -gt 0) {
            $normalizedBlocks.Add([pscustomobject]@{
                type = 'delay'
                seconds = [int]$startupDelaySeconds
            })
        }

        foreach ($step in @($stepsValue)) {
            $stepDelaySeconds = Get-ConfigPropertyValue -InputObject $step -PropertyName 'delaySeconds'
            if ($null -ne $stepDelaySeconds -and [int]$stepDelaySeconds -gt 0) {
                $normalizedBlocks.Add([pscustomobject]@{
                    type = 'delay'
                    seconds = [int]$stepDelaySeconds
                })
            }

            $stepName = Get-ConfigPropertyValue -InputObject $step -PropertyName 'name'
            $stepScripts = Get-ConfigPropertyValue -InputObject $step -PropertyName 'scripts'
            $normalizedBlocks.Add([pscustomobject]@{
                type = 'step'
                name = $stepName
                scripts = $stepScripts
            })
        }

        Write-LauncherLog -Level 'WARN' -Message 'Legacy-Config erkannt. Bitte auf das neue blocks-Format umstellen.'
        return @($normalizedBlocks)
    }

    return @()
}

function Get-ConfigPropertyValue {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Resolve-ApplicationPath {
    param(
        [Parameter(Mandatory)]
        [string]$CommandName
    )

    $candidates = @(Get-Command -Name $CommandName -CommandType Application -ErrorAction SilentlyContinue)
    if ((Get-CollectionCount -Value $candidates) -eq 0) {
        return $null
    }

    $preferred = $candidates | Where-Object { $_.Source -and $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
    if ($null -eq $preferred) {
        $preferred = $candidates | Select-Object -First 1
    }

    if ($null -eq $preferred -or $null -eq $preferred.Source -or [string]$preferred.Source -eq '') {
        return $null
    }

    return [string]$preferred.Source
}

function Get-CollectionCount {
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    if ($null -eq $Value) {
        return 0
    }

    if ($Value -is [string]) {
        return 1
    }

    $countProperty = $Value.PSObject.Properties['Count']
    if ($null -ne $countProperty -and $null -ne $countProperty.Value) {
        return [int]$countProperty.Value
    }

    $enumerable = $Value -as [System.Collections.IEnumerable]
    if ($null -ne $enumerable) {
        $count = 0
        foreach ($item in $enumerable) {
            $count++
        }

        return $count
    }

    return 1
}

function Resolve-PythonExecutable {
    $pythonPath = Resolve-ApplicationPath -CommandName 'python'
    if ($null -ne $pythonPath) {
        return $pythonPath
    }

    $pyPath = Resolve-ApplicationPath -CommandName 'py'
    if ($null -ne $pyPath) {
        return $pyPath
    }

    throw "Weder 'python' noch 'py' wurde gefunden."
}

function Resolve-LaunchTarget {
    param(
        [Parameter(Mandatory)]
        [object]$ScriptEntry
    )

    $entryPath = Get-ConfigPropertyValue -InputObject $ScriptEntry -PropertyName 'path'
    if ($null -eq $entryPath -or [string]$entryPath -eq '') {
        throw "Ein Script-Eintrag ist unvollstaendig: 'path' fehlt."
    }

    $entryPath = [string]$entryPath
    if (-not (Test-Path -LiteralPath $entryPath)) {
        throw "Script-Pfad existiert nicht: $entryPath"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $entryPath).Path
    $workingDirectory = $resolvedPath
    $targetPath = $resolvedPath
    if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
        $scriptFile = Get-ConfigPropertyValue -InputObject $ScriptEntry -PropertyName 'scriptFile'
        if ($null -ne $scriptFile -and [string]$scriptFile -ne '') {
            $candidate = Join-Path $resolvedPath ([string]$scriptFile)
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
            if ((Get-CollectionCount -Value $pyFiles) -eq 1) {
                $targetPath = $pyFiles[0].FullName
            }
            else {
                $ps1Files = @(Get-ChildItem -LiteralPath $resolvedPath -Filter '*.ps1' -File)
                if ((Get-CollectionCount -Value $ps1Files) -eq 1) {
                    $targetPath = $ps1Files[0].FullName
                }
                elseif ((Get-CollectionCount -Value $ps1Files) -gt 1) {
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
    $workingDirectory = if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
        $resolvedPath
    }
    else {
        Split-Path -Parent $targetPath
    }
    $arguments = New-Object System.Collections.Generic.List[string]
    $scriptArguments = Get-ConfigPropertyValue -InputObject $ScriptEntry -PropertyName 'arguments'

    if ($null -ne $scriptArguments) {
        if ($scriptArguments -is [System.Collections.IEnumerable] -and -not ($scriptArguments -is [string])) {
            foreach ($arg in @($scriptArguments)) {
                if ($null -ne $arg -and [string]$arg -ne '') {
                    $arguments.Add([string]$arg)
                }
            }
        }
        else {
            $arguments.Add([string]$scriptArguments)
        }
    }

    switch ($extension) {
        '.py' {
            $pythonExecutable = Get-ConfigPropertyValue -InputObject $ScriptEntry -PropertyName 'pythonExecutable'
            $pythonExe = if ($null -ne $pythonExecutable -and [string]$pythonExecutable -ne '') {
                [string]$pythonExecutable
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
    $enabledValue = Get-ConfigPropertyValue -InputObject $ScriptEntry -PropertyName 'enabled'
    if ($null -ne $enabledValue) {
        $isEnabled = [bool]$enabledValue
    }

    if (-not $isEnabled) {
        $scriptName = Get-ConfigPropertyValue -InputObject $ScriptEntry -PropertyName 'name'
        $scriptPath = Get-ConfigPropertyValue -InputObject $ScriptEntry -PropertyName 'path'
        $scriptLabel = if ($null -ne $scriptName -and [string]$scriptName -ne '') { [string]$scriptName } else { [string]$scriptPath }
        Write-LauncherLog -Message "Uebersprungen (deaktiviert): $scriptLabel"
        return
    }

    $launchPlan = Resolve-LaunchTarget -ScriptEntry $ScriptEntry
    $scriptName = Get-ConfigPropertyValue -InputObject $ScriptEntry -PropertyName 'name'
    $scriptLabel = if ($null -ne $scriptName -and [string]$scriptName -ne '') { [string]$scriptName } else { $launchPlan.DisplayTarget }
    Write-LauncherLog -Message "Starte Script in Step '$StepName': $scriptLabel"

    Start-Process -FilePath $launchPlan.FilePath -ArgumentList $launchPlan.ArgumentList -WorkingDirectory $launchPlan.WorkingDirectory -WindowStyle Hidden | Out-Null
}

function Invoke-DelayBlock {
    param(
        [object]$DelayBlock
    )

    $delaySeconds = 0
    $secondsValue = Get-ConfigPropertyValue -InputObject $DelayBlock -PropertyName 'seconds'
    if ($null -ne $secondsValue) {
        $delaySeconds = [int]$secondsValue
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
    $blocks = Get-NormalizedBlockArray -ConfigObject $config

    if ((Get-CollectionCount -Value $blocks) -eq 0) {
        throw "Die Config enthaelt keine Blocks."
    }

    foreach ($block in $blocks) {
        $blockType = [string]$block.type

        switch ($blockType) {
            'delay' {
                Invoke-DelayBlock -DelayBlock $block
            }

            'step' {
                $blockName = Get-ConfigPropertyValue -InputObject $block -PropertyName 'name'
                $stepName = if ($null -ne $blockName -and [string]$blockName -ne '') { [string]$blockName } else { 'unnamed-step' }
                $scriptsValue = Get-ConfigPropertyValue -InputObject $block -PropertyName 'scripts'
                $scripts = if ($null -ne $scriptsValue) { @($scriptsValue) } else { @() }

                if ((Get-CollectionCount -Value $scripts) -eq 0) {
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
