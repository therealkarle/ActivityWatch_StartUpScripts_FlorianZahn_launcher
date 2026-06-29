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
$script:LauncherStartedAtUtc = [DateTimeOffset]::UtcNow
$script:LauncherTranscriptPath = $null
$script:LauncherTranscriptStarted = $false

function Start-LauncherTranscript {
    param(
        [Parameter(Mandatory)]
        [string]$TranscriptPath
    )

    if ($script:LauncherTranscriptStarted) {
        return
    }

    try {
        $transcriptDirectory = Split-Path -Parent $TranscriptPath
        if (-not (Test-Path -LiteralPath $transcriptDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $transcriptDirectory -Force | Out-Null
        }

        Start-Transcript -LiteralPath $TranscriptPath -Append | Out-Null
        $script:LauncherTranscriptPath = $TranscriptPath
        $script:LauncherTranscriptStarted = $true
        Write-LauncherLog -Message "Transcript wird nach $script:LauncherTranscriptPath geschrieben."
    }
    catch {
        Write-LauncherLog -Level 'WARN' -Message "Transcript konnte nicht gestartet werden: $($_.Exception.Message)"
    }
}

function Stop-LauncherTranscript {
    if (-not $script:LauncherTranscriptStarted) {
        return
    }

    try {
        Stop-Transcript | Out-Null
        $script:LauncherTranscriptStarted = $false
    }
    catch {
        # Transcript ist optional und darf den Launcher nicht blockieren.
    }
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

function Get-LoggingSettings {
    param(
        [Parameter(Mandatory)]
        [object]$ConfigObject
    )

    $saveTerminalOutputToLog = $false

    $loggingObject = Get-ConfigPropertyValue -InputObject $ConfigObject -PropertyName 'logging'
    if ($null -ne $loggingObject) {
        $configuredValue = Get-ConfigPropertyValue -InputObject $loggingObject -PropertyName 'saveTerminalOutputToLog'
        if ($null -ne $configuredValue) {
            $saveTerminalOutputToLog = [bool]$configuredValue
        }
    }
    else {
        $configuredValue = Get-ConfigPropertyValue -InputObject $ConfigObject -PropertyName 'saveTerminalOutputToLog'
        if ($null -ne $configuredValue) {
            $saveTerminalOutputToLog = [bool]$configuredValue
        }
    }

    return [pscustomobject]@{
        SaveTerminalOutputToLog = $saveTerminalOutputToLog
    }
}

function Get-ActivityWatchSettings {
    param(
        [Parameter(Mandatory)]
        [object]$ConfigObject,

        [Parameter(Mandatory)]
        [object]$BlockObject
    )

    $baseUrl = 'http://localhost:5600'
    $retryDelaySeconds = 30
    $maxRetries = 8

    $blockSettings = Get-ConfigPropertyValue -InputObject $BlockObject -PropertyName 'activityWatch'
    if ($null -eq $blockSettings) {
        $blockSettings = $BlockObject
    }

    $activityWatchSources = @(
        (Get-ConfigPropertyValue -InputObject $ConfigObject -PropertyName 'activityWatch'),
        $blockSettings
    )

    foreach ($source in $activityWatchSources) {
        if ($null -eq $source) {
            continue
        }

        $configuredUrl = Get-ConfigPropertyValue -InputObject $source -PropertyName 'url'
        if ($null -ne $configuredUrl -and [string]$configuredUrl -ne '') {
            $baseUrl = [string]$configuredUrl
        }

        $configuredRetryDelay = Get-ConfigPropertyValue -InputObject $source -PropertyName 'retryDelaySeconds'
        if ($null -ne $configuredRetryDelay) {
            $retryDelaySeconds = [int]$configuredRetryDelay
        }

        $configuredMaxRetries = Get-ConfigPropertyValue -InputObject $source -PropertyName 'maxRetries'
        if ($null -ne $configuredMaxRetries) {
            $maxRetries = [int]$configuredMaxRetries
        }
    }

    $baseUrl = $baseUrl.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        throw 'ActivityWatch URL darf nicht leer sein.'
    }

    if ($retryDelaySeconds -lt 1) {
        throw 'ActivityWatch retryDelaySeconds muss mindestens 1 sein.'
    }

    if ($maxRetries -lt 1) {
        throw 'ActivityWatch maxRetries muss mindestens 1 sein.'
    }

    return [pscustomobject]@{
        BaseUrl = $baseUrl
        RetryDelaySeconds = $retryDelaySeconds
        MaxRetries = $maxRetries
    }
}

function Get-StartupTimeMonitorSettings {
    param(
        [Parameter(Mandatory)]
        [object]$ConfigObject,

        [Parameter(Mandatory)]
        [object[]]$Blocks
    )

    $baseUrl = 'http://localhost:5600'

    foreach ($block in @($Blocks)) {
        if ($null -eq $block) {
            continue
        }

        if ([string]$block.type -ne 'activityWatchCheck') {
            continue
        }

        $activityWatchSettings = Get-ActivityWatchSettings -ConfigObject $ConfigObject -BlockObject $block
        if ($null -ne $activityWatchSettings -and -not [string]::IsNullOrWhiteSpace([string]$activityWatchSettings.BaseUrl)) {
            $baseUrl = [string]$activityWatchSettings.BaseUrl
        }

        break
    }

    if ([string]::IsNullOrWhiteSpace($baseUrl) -or $baseUrl -eq 'http://localhost:5600') {
        $hasActivityWatchBlock = $false
        foreach ($block in @($Blocks)) {
            if ($null -ne $block -and [string]$block.type -eq 'activityWatchCheck') {
                $hasActivityWatchBlock = $true
                break
            }
        }

        if (-not $hasActivityWatchBlock) {
            return $null
        }
    }

    return [pscustomobject]@{
        BaseUrl = $baseUrl
    }
}

function Start-StartupTimeMonitor {
    param(
        [Parameter(Mandatory)]
        [string]$LauncherStartTimeUtc,

        [Parameter(Mandatory)]
        [string]$BaseUrl
    )

    $monitorScriptPath = Join-Path $script:LauncherRoot 'startup-time-monitor.ps1'
    if (-not (Test-Path -LiteralPath $monitorScriptPath -PathType Leaf)) {
        Write-LauncherLog -Level 'WARN' -Message "StartupTime-Monitor fehlt: $monitorScriptPath"
        return
    }

    $powershellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $logRoot = Join-Path $script:LauncherRoot 'Logs'
    $argumentList = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-WindowStyle'
        'Hidden'
        '-File'
        $monitorScriptPath
        '-BaseUrl'
        $BaseUrl
        '-LogRoot'
        $logRoot
        '-LauncherStartTimeUtc'
        $LauncherStartTimeUtc
    )

    Start-Process -FilePath $powershellPath -ArgumentList $argumentList -WindowStyle Hidden | Out-Null
    Write-LauncherLog -Message "StartupTime-Monitor gestartet: $monitorScriptPath"
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

function ConvertTo-CommandLineArgumentString {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $quotedArguments = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') {
            '"' + ($argument -replace '"', '\"') + '"'
        }
        else {
            $argument
        }
    }

    return ($quotedArguments -join ' ')
}

function Write-CapturedProcessOutput {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Prefix,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $normalizedText = $Text -replace "`r`n", "`n"
    foreach ($line in ($normalizedText -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        Write-LauncherLog -Level $Level -Message "$Prefix $line"
    }
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string]$DisplayTarget
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        $argumentString = ConvertTo-CommandLineArgumentString -Arguments $ArgumentList
        $process = Start-Process -FilePath $FilePath -ArgumentList $argumentString -WorkingDirectory $WorkingDirectory -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        $stdoutText = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
        $stderrText = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }

        Write-CapturedProcessOutput -Text $stdoutText -Prefix "[stdout][$DisplayTarget]"
        Write-CapturedProcessOutput -Text $stderrText -Prefix "[stderr][$DisplayTarget]" -Level 'ERROR'

        $exitCode = [int]$process.ExitCode
        if ($exitCode -ne 0) {
            throw "Script '$DisplayTarget' wurde mit Exit-Code $exitCode beendet."
        }
    }
    finally {
        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) {
            Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        }

        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }
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
        [string]$StepName,

        [Parameter(Mandatory)]
        [int]$ScriptIndex,

        [Parameter(Mandatory)]
        [int]$TotalScripts
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
    Write-LauncherLog -Message "Starte Script $ScriptIndex/$TotalScripts in Step '$StepName': $scriptLabel"
    Write-LauncherLog -Message "Befehl: $($launchPlan.FilePath) $($launchPlan.ArgumentList -join ' ')"

    Push-Location -LiteralPath $launchPlan.WorkingDirectory
    try {
        Invoke-CapturedProcess -FilePath $launchPlan.FilePath -ArgumentList @($launchPlan.ArgumentList) -WorkingDirectory $launchPlan.WorkingDirectory -DisplayTarget $scriptLabel
        Write-LauncherLog -Message "Script abgeschlossen: $scriptLabel"
    }
    finally {
        Pop-Location
    }
}

function Invoke-DelayBlock {
    param(
        [object]$DelayBlock,

        [int]$BlockIndex,

        [int]$TotalBlocks
    )

    $delaySeconds = 0
    $secondsValue = Get-ConfigPropertyValue -InputObject $DelayBlock -PropertyName 'seconds'
    if ($null -ne $secondsValue) {
        $delaySeconds = [int]$secondsValue
    }

    if ($delaySeconds -gt 0) {
        Write-LauncherLog -Message "Block ${BlockIndex}/${TotalBlocks}: Warte $delaySeconds Sekunden."

        $remainingSeconds = $delaySeconds
        $heartbeatInterval = 60

        while ($remainingSeconds -gt 0) {
            $sleepSeconds = [Math]::Min($heartbeatInterval, $remainingSeconds)
            Start-Sleep -Seconds $sleepSeconds
            $remainingSeconds -= $sleepSeconds

            if ($remainingSeconds -gt 0) {
                Write-LauncherLog -Message "Block ${BlockIndex}/${TotalBlocks}: noch $remainingSeconds Sekunden bis zum naechsten Schritt."
            }
        }

        Write-LauncherLog -Message "Block ${BlockIndex}/${TotalBlocks}: Delay beendet."
    }
}

function Test-ActivityWatchOnline {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl
    )

    $infoUrl = "$BaseUrl/api/0/info"
    $handler = $null
    $client = $null

    try {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(5)

        $response = $client.GetAsync($infoUrl).GetAwaiter().GetResult()
        if ($null -ne $response -and $response.IsSuccessStatusCode) {
            return $true
        }
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $client) {
            $client.Dispose()
        }

        if ($null -ne $handler) {
            $handler.Dispose()
        }
    }

    return $false
}

function Wait-ForActivityWatchOnline {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [int]$RetryDelaySeconds,

        [Parameter(Mandatory)]
        [int]$MaxRetries
    )

    $infoUrl = "$BaseUrl/api/0/info"

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-LauncherLog -Message "Pruefe ActivityWatch ($attempt/$MaxRetries): $infoUrl"
        if (Test-ActivityWatchOnline -BaseUrl $BaseUrl) {
            Write-LauncherLog -Message "ActivityWatch ist online: $infoUrl"
            return
        }

        if ($attempt -lt $MaxRetries) {
            Write-LauncherLog -Level 'WARN' -Message "ActivityWatch ist noch nicht online: $infoUrl (Versuch $attempt von $MaxRetries)"
            Write-LauncherLog -Message "Erneuter Versuch in $RetryDelaySeconds Sekunden."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    throw "ActivityWatch ist nach $MaxRetries Versuchen noch nicht online: $infoUrl"
}

function Invoke-Launcher {
    param(
        [Parameter(Mandatory)]
        [string]$ResolvedConfigPath,

        [Parameter(Mandatory)]
        [object]$ConfigObject,

        [object[]]$Blocks
    )

    Write-LauncherLog -Message "Nutze Config: $ResolvedConfigPath"

    if ($null -eq $Blocks) {
        $blocks = Get-NormalizedBlockArray -ConfigObject $ConfigObject
    }
    else {
        $blocks = @($Blocks)
    }

    if ((Get-CollectionCount -Value $blocks) -eq 0) {
        throw "Die Config enthaelt keine Blocks."
    }

    $startupTimeMonitorSettings = Get-StartupTimeMonitorSettings -ConfigObject $ConfigObject -Blocks $blocks
    if ($null -ne $startupTimeMonitorSettings) {
        Start-StartupTimeMonitor -LauncherStartTimeUtc $script:LauncherStartedAtUtc.ToString('o') -BaseUrl $startupTimeMonitorSettings.BaseUrl
    }

    $totalBlocks = Get-CollectionCount -Value $blocks
    $blockIndex = 0

    foreach ($block in $blocks) {
        $blockIndex++
        $blockType = [string]$block.type
        Write-LauncherLog -Message "Block ${blockIndex}/${totalBlocks} startet: $blockType"

        switch ($blockType) {
            'delay' {
                Invoke-DelayBlock -DelayBlock $block -BlockIndex $blockIndex -TotalBlocks $totalBlocks
            }

            'activityWatchCheck' {
                $activityWatchSettings = Get-ActivityWatchSettings -ConfigObject $ConfigObject -BlockObject $block
                Wait-ForActivityWatchOnline -BaseUrl $activityWatchSettings.BaseUrl -RetryDelaySeconds $activityWatchSettings.RetryDelaySeconds -MaxRetries $activityWatchSettings.MaxRetries
            }

            'step' {
                $blockName = Get-ConfigPropertyValue -InputObject $block -PropertyName 'name'
                $stepName = if ($null -ne $blockName -and [string]$blockName -ne '') { [string]$blockName } else { 'unnamed-step' }
                $scriptsValue = Get-ConfigPropertyValue -InputObject $block -PropertyName 'scripts'
                $scripts = if ($null -ne $scriptsValue) { @($scriptsValue) } else { @() }
                $totalScripts = Get-CollectionCount -Value $scripts

                if ($totalScripts -eq 0) {
                    Write-LauncherLog -Level 'WARN' -Message "Step '$stepName' hat keine Scripts."
                    break
                }

                $scriptIndex = 0
                foreach ($scriptEntry in $scripts) {
                    $scriptIndex++
                    Start-ConfiguredScript -ScriptEntry $scriptEntry -StepName $stepName -ScriptIndex $scriptIndex -TotalScripts $totalScripts
                }
            }

            default {
                throw "Unbekannter Block-Typ: $blockType"
            }
        }

        Write-LauncherLog -Message "Block ${blockIndex}/${totalBlocks} abgeschlossen: $blockType"
    }
}

$script:LauncherExitCode = 0

try {
    $resolvedConfigPath = Resolve-ExistingConfigPath -PrimaryPath $ConfigPath
    $config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
    $loggingSettings = Get-LoggingSettings -ConfigObject $config
    $blocks = Get-NormalizedBlockArray -ConfigObject $config

    if ($loggingSettings.SaveTerminalOutputToLog) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $logDirectory = Join-Path $script:LauncherRoot 'Logs'
        $transcriptPath = Join-Path $logDirectory "launcher-$timestamp.log"
        Start-LauncherTranscript -TranscriptPath $transcriptPath
    }

    Invoke-Launcher -ResolvedConfigPath $resolvedConfigPath -ConfigObject $config -Blocks $blocks
    Write-LauncherLog -Message 'Alle konfigurierten Scripts wurden angestossen.'
}
catch {
    $errorMessage = $_.Exception.Message
    if ($null -ne $_.ScriptStackTrace -and [string]$_.ScriptStackTrace -ne '') {
        Write-LauncherLog -Level 'ERROR' -Message $errorMessage
        if ($null -ne $_.InvocationInfo -and $null -ne $_.InvocationInfo.PositionMessage -and [string]$_.InvocationInfo.PositionMessage -ne '') {
            Write-LauncherLog -Level 'ERROR' -Message $_.InvocationInfo.PositionMessage
        }
        Write-LauncherLog -Level 'ERROR' -Message $_.ScriptStackTrace
    }
    else {
        Write-LauncherLog -Level 'ERROR' -Message $errorMessage
    }
    $script:LauncherExitCode = 1
}
finally {
    Stop-LauncherTranscript
}

if ($script:LauncherExitCode -ne 0) {
    exit $script:LauncherExitCode
}
