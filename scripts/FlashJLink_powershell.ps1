param(
    [Parameter(Mandatory = $true)]
    [string]$FirmwarePath,

    [ValidateSet("J-Link", "JLink")]
    [string]$ProgrammerType = "J-Link",

    [string]$JLinkPath = "JLink.exe",

    [Parameter(Mandatory = $true)]
    [string]$Device,

    [ValidateSet("SWD", "JTAG")]
    [string]$Interface = "SWD",

    [int]$Speed = 1000,

    [string]$FlashAddress = "0x08000000",

    [string]$CommandFilePath = "",

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
        if ($line -match "(?i)(error|failed|cannot|unable|could not|no j-link|connection.*failed|verification.*failed)") {
            return $line
        }
    }

    return $null
}

$resolvedFirmwarePath = Resolve-ExistingFile -PathValue $FirmwarePath -Name "FirmwarePath"

if ([System.IO.Path]::IsPathRooted($JLinkPath)) {
    $resolvedJLinkPath = Resolve-ExistingFile -PathValue $JLinkPath -Name "JLinkPath"
    $workingDir = Split-Path -Parent $resolvedJLinkPath
}
else {
    $resolvedJLinkPath = $JLinkPath
    $workingDir = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($CommandFilePath)) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $resolvedCommandFilePath = Join-Path ([System.IO.Path]::GetTempPath()) "rt-thread-jlink-flash-$timestamp.jlink"
}
elseif ([System.IO.Path]::IsPathRooted($CommandFilePath)) {
    $resolvedCommandFilePath = [System.IO.Path]::GetFullPath($CommandFilePath)
}
else {
    $resolvedCommandFilePath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $CommandFilePath))
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $resolvedLogPath = Join-Path (Get-Location).Path "rt-thread-jlink-flash-$timestamp.log"
}
elseif ([System.IO.Path]::IsPathRooted($LogPath)) {
    $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
}
else {
    $resolvedLogPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $LogPath))
}

foreach ($path in @($resolvedCommandFilePath, $resolvedLogPath)) {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$commandFileContent = @(
    "r",
    "h",
    "loadfile $resolvedFirmwarePath $FlashAddress",
    "r",
    "g",
    "q"
) -join [Environment]::NewLine

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedCommandFilePath, $commandFileContent + [Environment]::NewLine, $utf8NoBom)

$arguments = @(
    "-device", $Device,
    "-if", $Interface,
    "-speed", "$Speed",
    "-autoconnect", "1",
    "-ExitOnError", "1",
    "-NoGui", "1",
    "-CommandFile", $resolvedCommandFilePath
)

$invokeResult = Invoke-ExternalCommand -FilePath $resolvedJLinkPath -Arguments $arguments -WorkingDirectory $workingDir
$outputLines = @($invokeResult.Lines)
$exitCode = [int]$invokeResult.ExitCode
$outputText = ($outputLines -join [Environment]::NewLine)
[System.IO.File]::WriteAllText($resolvedLogPath, $outputText + [Environment]::NewLine, $utf8NoBom)

$success = ($exitCode -eq 0 -and $outputText -notmatch "(?i)(error|failed|verification.*failed)")
$noProbe = $outputText -match "(?i)(no j-link|cannot connect|could not connect|failed to connect)"

$commandLine = ($resolvedJLinkPath + " " + (($arguments | ForEach-Object {
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
    jlinkPath = $resolvedJLinkPath
    command = $commandLine
    commandFilePath = $resolvedCommandFilePath
    device = $Device
    interface = $Interface
    speed = $Speed
    flashAddress = $FlashAddress
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
