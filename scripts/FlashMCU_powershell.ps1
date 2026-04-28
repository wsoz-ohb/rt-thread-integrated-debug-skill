param(
    [Parameter(Mandatory = $true)]
    [string]$FirmwarePath,

    [ValidateSet("DAP", "DAPLink", "CMSIS-DAP")]
    [string]$ProgrammerType = "DAP",

    [Parameter(Mandatory = $true)]
    [string]$Target,

    [string]$PyOcdPath = "pyocd.exe",

    [string]$PyOcdWorkingDir = "",

    [ValidateSet("auto", "chip", "sector", "page", "none")]
    [string]$Erase = "auto",

    [int]$Frequency = 1000000,

    [string]$LogPath = "",

    [int]$KeepLogs = 10,

    [string[]]$ExtraPyOcdArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-DapProgrammerType {
    param([string]$Value)

    return $Value -in @("DAP", "DAPLink", "CMSIS-DAP")
}

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

function Resolve-OptionalDirectory {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    $resolved = Resolve-Path -LiteralPath $PathValue -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "PyOcdWorkingDir is not a directory: $($item.FullName)"
    }

    return $item.FullName
}

function Resolve-CommandPathOrOriginal {
    param([string]$CommandPath)

    $command = Get-Command $CommandPath -ErrorAction SilentlyContinue
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
        return $command.Source
    }

    return $CommandPath
}

function New-DefaultLogPath {
    param([string]$BaseDirectory)

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return Join-Path $BaseDirectory "rt-thread-flash-$timestamp.log"
}

function Remove-OldLogFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [int]$Keep
    )

    if ($Keep -lt 0 -or -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return 0
    }

    $files = @(Get-ChildItem -LiteralPath $Directory -Filter $Pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $removeCount = [Math]::Max(0, $files.Count - $Keep)
    $deletedCount = 0

    if ($removeCount -le 0) {
        return 0
    }

    foreach ($file in @($files | Select-Object -Last $removeCount)) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $deletedCount += 1
        }
        catch {
        }
    }

    return $deletedCount
}

function Get-FirstMatchValue {
    param(
        [string]$Text,
        [string]$Pattern,
        [int]$GroupIndex = 1
    )

    $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups[$GroupIndex].Value
}

function Get-FirstProblemLine {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -match "(?i)(CRITICAL|ERROR|TransferError|Unexpected ACK|No probe|not found|failed|Traceback)") {
            return $line
        }
    }

    return $null
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

if (-not (Test-DapProgrammerType -Value $ProgrammerType)) {
    throw "FlashMCU_powershell.ps1 uses PyOCD and is only valid for DAPLink/CMSIS-DAP/DAP. Confirm the programmer/debugger type and use the matching flashing tool."
}

$resolvedFirmwarePath = Resolve-ExistingFile -PathValue $FirmwarePath -Name "FirmwarePath"
$resolvedPyOcdPath = Resolve-CommandPathOrOriginal -CommandPath $PyOcdPath
$resolvedWorkingDir = Resolve-OptionalDirectory -PathValue $PyOcdWorkingDir

if ([string]::IsNullOrWhiteSpace($resolvedWorkingDir)) {
    if (Test-Path -LiteralPath $resolvedPyOcdPath -PathType Leaf) {
        $resolvedWorkingDir = Split-Path -Parent $resolvedPyOcdPath
    }
    else {
        $resolvedWorkingDir = (Get-Location).Path
    }
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $resolvedLogPath = New-DefaultLogPath -BaseDirectory (Split-Path -Parent $resolvedFirmwarePath)
}
else {
    if ([System.IO.Path]::IsPathRooted($LogPath)) {
        $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
    }
    else {
        $resolvedLogPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $resolvedFirmwarePath) $LogPath))
    }
}

$logDir = Split-Path -Parent $resolvedLogPath
if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$arguments = @(
    "flash",
    "--target=$Target",
    "--erase=$Erase",
    "--frequency=$Frequency",
    $resolvedFirmwarePath
)

if ($ExtraPyOcdArgs.Count -gt 0) {
    $arguments = @($ExtraPyOcdArgs + $arguments)
}

$invokeResult = Invoke-ExternalCommand -FilePath $resolvedPyOcdPath -Arguments $arguments -WorkingDirectory $resolvedWorkingDir
$outputLines = @($invokeResult.Lines)
$exitCode = [int]$invokeResult.ExitCode

$outputText = ($outputLines -join [Environment]::NewLine)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedLogPath, $outputText + [Environment]::NewLine, $utf8NoBom)
$oldFlashLogDeletedCount = Remove-OldLogFiles -Directory $logDir -Pattern "rt-thread-flash-*.log" -Keep $KeepLogs

$programmedBytes = Get-FirstMatchValue -Text $outputText -Pattern "programmed\s+([0-9]+)\s+bytes"
$erasedBytes = Get-FirstMatchValue -Text $outputText -Pattern "Erased\s+([0-9]+)\s+bytes"
$speedKBps = Get-FirstMatchValue -Text $outputText -Pattern "at\s+([0-9.]+)\s+kB/s"

$unexpectedAck = $outputText -match "Unexpected ACK value"
$transferError = $outputText -match "(?i)TransferError"
$noProbe = $outputText -match "(?i)(No probe|No connected debug probe|probe.*not found|DAP.*not found)"
$pyocdRuntimeExtractError = $outputText -match "(?i)(could not be extracted|fopen:\s*Permission denied|_MEI.*denied|VCRUNTIME140\.dll)"
$success = ($exitCode -eq 0 -and $outputText -match "(?i)programmed\s+[0-9]+\s+bytes" -and -not $unexpectedAck -and -not $transferError)

$needsUserHardwareCheck = [bool]($unexpectedAck -or $transferError -or $noProbe)
$hardwareCheckHint = $null
$pyocdRuntimeHint = $null

if ($needsUserHardwareCheck) {
    $hardwareCheckHint = "Flash failed while communicating with the debug probe or target MCU. Ask the user to check SWDIO/SWCLK/GND/3V3 wiring, board power, reset/BOOT state, debugger USB connection, target selection, and try lowering the SWD frequency before retrying."
}

if ($pyocdRuntimeExtractError) {
    $pyocdRuntimeHint = "PyOCD failed before hardware communication while extracting runtime files. Check whether another pyocd.exe process or RT-Thread Studio instance is holding the temporary _MEI directory, whether antivirus or Controlled Folder Access is blocking extraction, and whether the PyOCD directory or TEMP directory has write permission."
}

$commandLine = ($resolvedPyOcdPath + " " + (($arguments | ForEach-Object {
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
    pyocdPath = $resolvedPyOcdPath
    pyocdWorkingDir = $resolvedWorkingDir
    command = $commandLine
    target = $Target
    erase = $Erase
    frequency = $Frequency
    success = [bool]$success
    exitCode = [int]$exitCode
    erasedBytes = if ($erasedBytes) { [int]$erasedBytes } else { $null }
    programmedBytes = if ($programmedBytes) { [int]$programmedBytes } else { $null }
    speedKBps = if ($speedKBps) { [double]$speedKBps } else { $null }
    firstProblemLine = Get-FirstProblemLine -Lines $outputLines
    unexpectedAck = [bool]$unexpectedAck
    transferError = [bool]$transferError
    noProbe = [bool]$noProbe
    pyocdRuntimeExtractError = [bool]$pyocdRuntimeExtractError
    needsUserHardwareCheck = $needsUserHardwareCheck
    hardwareCheckHint = $hardwareCheckHint
    pyocdRuntimeHint = $pyocdRuntimeHint
    keepLogs = [int]$KeepLogs
    oldLogDeletedCount = [int]$oldFlashLogDeletedCount
    logPath = $resolvedLogPath
}

$result | ConvertTo-Json -Depth 4

if (-not $success) {
    exit 1
}
