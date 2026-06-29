[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:5600',

    [string]$LogRoot = (Join-Path $PSScriptRoot 'Logs'),

    [Parameter(Mandatory)]
    [string]$LauncherStartTimeUtc,

    [int]$PollIntervalSeconds = 5,

    [int]$MaxWaitSeconds = 1800
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-PrettyJson {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    return $InputObject | ConvertTo-Json -Depth 8
}

function Initialize-StartupTimeLogging {
    param(
        [Parameter(Mandatory)]
        [string]$LogRoot
    )

    $startupTimeDirectory = Join-Path $LogRoot 'StartupTime'
    if (-not (Test-Path -LiteralPath $startupTimeDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $startupTimeDirectory -Force | Out-Null
    }

    $runStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $rawLogPath = Join-Path $startupTimeDirectory "startup-time-$runStamp.log"
    New-Item -ItemType File -Path $rawLogPath -Force | Out-Null

    return [pscustomobject]@{
        StartupTimeDirectory = $startupTimeDirectory
        RawLogPath = $rawLogPath
    }
}

function Write-StartupTimeLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $line = "[$timestamp][$Level] $Message"
    Add-Content -LiteralPath $script:StartupTimeRawLogPath -Value $line
}

function Get-SystemBootTime {
    try {
        return (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    }
    catch {
        return (Get-WmiObject -Class Win32_OperatingSystem).LastBootUpTime
    }
}

function Test-ActivityWatchOnline {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl
    )

    $infoUrl = "$BaseUrl/api/0/info"

    try {
        $response = Invoke-WebRequest -Uri $infoUrl -Method Get -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return ($null -ne $response -and [int]$response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
}

function Get-Percentile {
    param(
        [Parameter(Mandatory)]
        [double[]]$Values,

        [Parameter(Mandatory)]
        [double]$Percentile
    )

    if ($Values.Count -eq 0) {
        return $null
    }

    $sortedValues = @($Values | Sort-Object)
    if ($sortedValues.Count -eq 1) {
        return [double]::Round($sortedValues[0], 3)
    }

    $position = ($Percentile / 100.0) * ($sortedValues.Count - 1)
    $lowerIndex = [Math]::Floor($position)
    $upperIndex = [Math]::Ceiling($position)

    if ($lowerIndex -eq $upperIndex) {
        return [double]::Round($sortedValues[$lowerIndex], 3)
    }

    $weight = $position - $lowerIndex
    $interpolated = $sortedValues[$lowerIndex] + (($sortedValues[$upperIndex] - $sortedValues[$lowerIndex]) * $weight)
    return [double]::Round($interpolated, 3)
}

function Get-SampleStandardDeviation {
    param(
        [Parameter(Mandatory)]
        [double[]]$Values
    )

    if ($Values.Count -lt 2) {
        return $null
    }

    $mean = ($Values | Measure-Object -Average).Average
    $sumSquaredDifferences = 0.0
    foreach ($value in $Values) {
        $difference = $value - $mean
        $sumSquaredDifferences += ($difference * $difference)
    }

    $variance = $sumSquaredDifferences / ($Values.Count - 1)
    return [double]::Round([Math]::Sqrt($variance), 3)
}

function Get-StartupTimeStats {
    param(
        [Parameter(Mandatory)]
        [double[]]$Values
    )

    if ($Values.Count -eq 0) {
        return [pscustomobject]@{
            Count = 0
            Average = $null
            SampleStandardDeviation = $null
            Min = $null
            Max = $null
            P05 = $null
            P95 = $null
        }
    }

    $average = [double]::Round((($Values | Measure-Object -Average).Average), 3)
    $minimum = [double]::Round((($Values | Measure-Object -Minimum).Minimum), 3)
    $maximum = [double]::Round((($Values | Measure-Object -Maximum).Maximum), 3)

    return [pscustomobject]@{
        Count = $Values.Count
        Average = $average
        SampleStandardDeviation = Get-SampleStandardDeviation -Values $Values
        Min = $minimum
        Max = $maximum
        P05 = Get-Percentile -Values $Values -Percentile 5
        P95 = Get-Percentile -Values $Values -Percentile 95
    }
}

function Read-StartupTimeRecord {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $content = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($content, 'STARTUP_TIME_RESULT_JSON:\s*(\{.*\})')
    if (-not $match.Success) {
        return $null
    }

    try {
        return $match.Groups[1].Value | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Write-StartupTimeSummary {
    param(
        [Parameter(Mandatory)]
        [string]$StartupTimeDirectory
    )

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($path in Get-ChildItem -LiteralPath $StartupTimeDirectory -Filter 'startup-time-*.log' -File) {
        $record = Read-StartupTimeRecord -Path $path.FullName
        if ($null -ne $record -and [string]$record.status -eq 'success') {
            $records.Add($record)
        }
    }

    $launcherValues = @()
    $windowsValues = @()

    foreach ($record in $records) {
        if ($null -ne $record.launcherStartToApiReadySeconds) {
            $launcherValues += [double]$record.launcherStartToApiReadySeconds
        }

        if ($null -ne $record.windowsStartToApiReadySeconds) {
            $windowsValues += [double]$record.windowsStartToApiReadySeconds
        }
    }

    $summary = [pscustomobject]@{
        generatedAtUtc = ([DateTimeOffset]::UtcNow.ToString('o'))
        startupTimeDirectory = $StartupTimeDirectory
        successfulRuns = $records.Count
        metrics = [pscustomobject]@{
            launcherStartToApiReadySeconds = Get-StartupTimeStats -Values @($launcherValues)
            windowsStartToApiReadySeconds = Get-StartupTimeStats -Values @($windowsValues)
        }
    }

    $summaryPath = Join-Path $StartupTimeDirectory 'startup-time-summary.json'
    Set-Content -LiteralPath $summaryPath -Value (ConvertTo-PrettyJson -InputObject $summary)
}

function Measure-StartupTime {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,

        [Parameter(Mandatory)]
        [datetimeoffset]$LauncherStartTimeUtc,

        [Parameter(Mandatory)]
        [datetime]$BootTime,

        [Parameter(Mandatory)]
        [int]$PollIntervalSeconds,

        [Parameter(Mandatory)]
        [int]$MaxWaitSeconds
    )

    $monitorStartUtc = [DateTimeOffset]::UtcNow
    $deadlineUtc = $monitorStartUtc.AddSeconds($MaxWaitSeconds)
    $attempt = 0
    $readyAtUtc = $null

    Write-StartupTimeLog -Message "Monitor gestartet."
    Write-StartupTimeLog -Message "BaseUrl: $BaseUrl"
    Write-StartupTimeLog -Message "LauncherStartTimeUtc: $($LauncherStartTimeUtc.ToString('o'))"
    Write-StartupTimeLog -Message "MonitorStartTimeUtc: $($monitorStartUtc.ToString('o'))"
    Write-StartupTimeLog -Message "WindowsBootTime: $($BootTime.ToUniversalTime().ToString('o'))"

    while ($true) {
        $attempt++
        $probeTimeUtc = [DateTimeOffset]::UtcNow
        Write-StartupTimeLog -Message "Pruefe ActivityWatch ($attempt): $BaseUrl/api/0/info"

        if (Test-ActivityWatchOnline -BaseUrl $BaseUrl) {
            $readyAtUtc = [DateTimeOffset]::UtcNow
            Write-StartupTimeLog -Message "ActivityWatch ist online."
            break
        }

        if ($probeTimeUtc -ge $deadlineUtc) {
            break
        }

        $remainingSeconds = [Math]::Max(0, [int][Math]::Ceiling(($deadlineUtc - $probeTimeUtc).TotalSeconds))
        $sleepSeconds = [Math]::Min($PollIntervalSeconds, $remainingSeconds)
        if ($sleepSeconds -le 0) {
            break
        }

        Start-Sleep -Seconds $sleepSeconds
    }

    if ($null -eq $readyAtUtc) {
        Write-StartupTimeLog -Level 'ERROR' -Message "Timeout nach $MaxWaitSeconds Sekunden ohne ActivityWatch-API."

        $failure = [pscustomobject]@{
            status = 'failed'
            baseUrl = $BaseUrl
            launcherStartTimeUtc = $LauncherStartTimeUtc.ToString('o')
            monitorStartTimeUtc = $monitorStartUtc.ToString('o')
            bootTimeUtc = $BootTime.ToUniversalTime().ToString('o')
            attempts = $attempt
            timeoutSeconds = $MaxWaitSeconds
        }

        Write-StartupTimeLog -Message "STARTUP_TIME_RESULT_JSON: $(ConvertTo-Json -InputObject $failure -Depth 8 -Compress)"
        return
    }

    $windowsStartToApiReadySeconds = [double]::Round(($readyAtUtc - $BootTime.ToUniversalTime()).TotalSeconds, 3)
    $launcherStartToApiReadySeconds = [double]::Round(($readyAtUtc - $LauncherStartTimeUtc).TotalSeconds, 3)

    $result = [pscustomobject]@{
        status = 'success'
        baseUrl = $BaseUrl
        launcherStartTimeUtc = $LauncherStartTimeUtc.ToString('o')
        monitorStartTimeUtc = $monitorStartUtc.ToString('o')
        bootTimeUtc = $BootTime.ToUniversalTime().ToString('o')
        readyTimeUtc = $readyAtUtc.ToString('o')
        attempts = $attempt
        pollIntervalSeconds = $PollIntervalSeconds
        windowsStartToApiReadySeconds = $windowsStartToApiReadySeconds
        launcherStartToApiReadySeconds = $launcherStartToApiReadySeconds
    }

    Write-StartupTimeLog -Message "Windows start -> API ready: $windowsStartToApiReadySeconds seconds"
    Write-StartupTimeLog -Message "Launcher start -> API ready: $launcherStartToApiReadySeconds seconds"
    Write-StartupTimeLog -Message "STARTUP_TIME_RESULT_JSON: $(ConvertTo-Json -InputObject $result -Depth 8 -Compress)"
}

try {
    $normalizedLogRoot = if ([string]::IsNullOrWhiteSpace($LogRoot)) {
        Join-Path $PSScriptRoot 'Logs'
    }
    else {
        $LogRoot
    }

    $paths = Initialize-StartupTimeLogging -LogRoot $normalizedLogRoot
    $script:StartupTimeRawLogPath = $paths.RawLogPath

    $launcherStartTimeValue = [DateTimeOffset]::Parse($LauncherStartTimeUtc)
    $bootTime = Get-SystemBootTime

    Measure-StartupTime -BaseUrl $BaseUrl -LauncherStartTimeUtc $launcherStartTimeValue -BootTime $bootTime -PollIntervalSeconds $PollIntervalSeconds -MaxWaitSeconds $MaxWaitSeconds
    Write-StartupTimeSummary -StartupTimeDirectory $paths.StartupTimeDirectory
}
catch {
    $errorMessage = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($script:StartupTimeRawLogPath)) {
        Write-Error $errorMessage
    }
    else {
        try {
            Write-StartupTimeLog -Level 'ERROR' -Message $errorMessage
        }
        catch {
            # Nothing else to do if logging itself fails.
        }
    }

    exit 1
}
