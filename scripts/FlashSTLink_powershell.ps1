param(
    [Parameter(Mandatory = $true)]
    [string]$FirmwarePath,

    [ValidateSet("ST-LINK")]
    [string]$ProgrammerType = "ST-LINK",

    [string]$ProgrammerCliPath = "STM32_Programmer_CLI.exe",

    [string]$ConnectPort = "SWD",

    [int]$FrequencyKHz = 1000,

    [ValidateSet("NORMAL", "UR", "HOTPLUG", "POWERDOWN")]
    [string]$ConnectMode = "UR",

    [ValidateSet("SWrst", "HWrst", "Crst")]
    [string]$ResetMode = "HWrst",

    [string]$FlashAddress = "0x08000000",

    [switch]$Verify,

    [switch]$ResetAfterFlash,

    [string]$LogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $resolved = Resolve-Path -LiteralPath $PathValue -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "$Name is not a file: $($item.FullName)"
    }

    return $item.FullName
}

function Quote-ProcessArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.Arguments = ($Arguments | ForEach-Object { Quote-ProcessArgument -Value $_ }) -join " "

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $combined = @()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $combined += $stdout -split "`r?`n"
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $combined += $stderr -split "`r?`n"
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Lines = @($combined | Where-Object { $_ -ne "" })
    }
}

function Get-FirstProblemLine {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -match "(?i)(error|failed|cannot|unable|no st-link|no debug probe|connection.*lost|verification.*failed)") {
            return $line
        }
    }

    return $null
}

$resolvedFirmwarePath = Resolve-ExistingFile -PathValue $FirmwarePath -Name "FirmwarePath"

if ([System.IO.Path]::IsPathRooted($ProgrammerCliPath)) {
    $resolvedProgrammerPath = Resolve-ExistingFile -PathValue $ProgrammerCliPath -Name "ProgrammerCliPath"
    $workingDir = Split-Path -Parent $resolvedProgrammerPath
}
else {
    $resolvedProgrammerPath = $ProgrammerCliPath
    $workingDir = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $resolvedLogPath = Join-Path (Get-Location).Path "rt-thread-stlink-flash-$timestamp.log"
}
elseif ([System.IO.Path]::IsPathRooted($LogPath)) {
    $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
}
else {
    $resolvedLogPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $LogPath))
}

$logDir = Split-Path -Parent $resolvedLogPath
if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$connectArg = "port=$ConnectPort"
$frequencyArg = "freq=$FrequencyKHz"
$modeArg = "mode=$ConnectMode"
$resetArg = "reset=$ResetMode"

$arguments = @(
    "-c", $connectArg, $frequencyArg, $modeArg, $resetArg,
    "-w", $resolvedFirmwarePath, $FlashAddress
)

if ($Verify) {
    $arguments += "-v"
}

if ($ResetAfterFlash) {
    $arguments += "-rst"
}

$invokeResult = Invoke-ExternalCommand -FilePath $resolvedProgrammerPath -Arguments $arguments -WorkingDirectory $workingDir
$outputLines = @($invokeResult.Lines)
$exitCode = [int]$invokeResult.ExitCode
$outputText = ($outputLines -join [Environment]::NewLine)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedLogPath, $outputText + [Environment]::NewLine, $utf8NoBom)

$success = ($exitCode -eq 0 -and $outputText -notmatch "(?i)(error|failed|verification.*failed)")
$noProbe = $outputText -match "(?i)(no st-link|no debug probe|st-link.*not.*detected|cannot connect)"

$commandLine = ($resolvedProgrammerPath + " " + (($arguments | ForEach-Object {
    if ($_ -match "\s") {
        '"' + $_ + '"'
    }
    else {
        $_
    }
}) -join " "))

$result = [ordered]@{
    firmwarePath = $resolvedFirmwarePath
    programmerType = $ProgrammerType
    programmerCliPath = $resolvedProgrammerPath
    command = $commandLine
    connectPort = $ConnectPort
    frequencyKHz = $FrequencyKHz
    connectMode = $ConnectMode
    resetMode = $ResetMode
    flashAddress = $FlashAddress
    verify = [bool]$Verify
    resetAfterFlash = [bool]$ResetAfterFlash
    success = [bool]$success
    exitCode = $exitCode
    noProbe = [bool]$noProbe
    firstProblemLine = Get-FirstProblemLine -Lines $outputLines
    logPath = $resolvedLogPath
}

$result | ConvertTo-Json -Depth 4

if (-not $success) {
    exit 1
}
