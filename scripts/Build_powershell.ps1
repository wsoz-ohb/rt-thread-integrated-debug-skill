param(
    [string]$ProjectRoot = ".",
    [string]$BuildDir = "Debug",
    [string]$BuildCommand = "make -j12 all",
    [string]$CleanCommand = "make clean",
    [bool]$CleanFirst = $true,
    [bool]$SafeCleanFallback = $true,
    [switch]$UseMakeClean,
    [switch]$NoClean,
    [string]$LogPath = "",
    [int]$KeepLogs = 10,
    [string[]]$ToolchainBinDir = @(),
    [string[]]$ToolchainSearchRoot = @(),
    [switch]$NoAutoDetectToolchain,
    [switch]$NoBuildDirFallback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$NotRecognizedPattern = "not recognized|is not recognized|\u4e0d\u662f\u5185\u90e8\u6216\u5916\u90e8\u547d\u4ee4"
$ProblemLinePattern = "(?i)(^|[:\s])(fatal error|error:|undefined reference|collect2: error|ld returned|No rule to make target|recipe for target .* failed|Error\s+[0-9]+\s+\(ignored\)|$NotRecognizedPattern)"
$ProblemLinePatternMultiline = "(?im)(^|[:\s])(fatal error|error:|undefined reference|collect2: error|ld returned|No rule to make target|recipe for target .* failed|Error\s+[0-9]+\s+\(ignored\)|$NotRecognizedPattern)"
$MissingArmToolPattern = "(?i)(arm-none-eabi-[a-z0-9_-]+.*($NotRecognizedPattern)|($NotRecognizedPattern).*arm-none-eabi-)"

function Resolve-ExistingDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $resolved = Resolve-Path -LiteralPath $PathValue -ErrorAction Stop
    $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "$Name is not a directory: $($item.FullName)"
    }

    return $item.FullName
}

function Resolve-OptionalExistingDirectories {
    param([string[]]$PathValues)

    $resolvedDirectories = @()
    foreach ($pathValue in @($PathValues)) {
        if ([string]::IsNullOrWhiteSpace($pathValue)) {
            continue
        }

        $resolved = Resolve-Path -LiteralPath $pathValue -ErrorAction Stop
        $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            throw "ToolchainBinDir is not a directory: $($item.FullName)"
        }

        $resolvedDirectories += $item.FullName
    }

    return @($resolvedDirectories)
}

function Test-ArmGccToolchainDirectory {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        return $false
    }

    return (
        (Test-Path -LiteralPath (Join-Path $Directory "arm-none-eabi-gcc.exe") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Directory "arm-none-eabi-objcopy.exe") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Directory "arm-none-eabi-size.exe") -PathType Leaf)
    )
}

function Find-ArmGccToolchainBin {
    param(
        [string]$ProjectRoot,
        [string[]]$SearchRoots = @()
    )

    $candidateRoots = New-Object 'System.Collections.Generic.List[string]'
    $candidateBins = New-Object 'System.Collections.Generic.List[string]'

    function Add-CandidateRoot {
        param([string]$PathValue)

        if ([string]::IsNullOrWhiteSpace($PathValue)) {
            return
        }

        $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
        if (-not (Test-Path -LiteralPath $expanded -PathType Container)) {
            return
        }

        $resolved = (Resolve-Path -LiteralPath $expanded -ErrorAction SilentlyContinue).Path
        if (-not [string]::IsNullOrWhiteSpace($resolved) -and -not $candidateRoots.Contains($resolved)) {
            [void]$candidateRoots.Add($resolved)
        }
    }

    function Add-CandidateBin {
        param([string]$PathValue)

        if ([string]::IsNullOrWhiteSpace($PathValue)) {
            return
        }

        $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
        if (Test-ArmGccToolchainDirectory -Directory $expanded) {
            $resolved = (Resolve-Path -LiteralPath $expanded -ErrorAction SilentlyContinue).Path
            if (-not [string]::IsNullOrWhiteSpace($resolved) -and -not $candidateBins.Contains($resolved)) {
                [void]$candidateBins.Add($resolved)
            }
        }
    }

    function Add-ToolchainHint {
        param([string]$PathValue)

        if ([string]::IsNullOrWhiteSpace($PathValue)) {
            return
        }

        $expanded = [Environment]::ExpandEnvironmentVariables($PathValue.Trim())
        $expanded = $expanded.Trim('"')

        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            $expanded = Split-Path -Parent $expanded
        }

        Add-CandidateBin -PathValue $expanded
        Add-CandidateBin -PathValue (Join-Path $expanded "bin")
        Add-CandidateRoot -PathValue $expanded
        Add-CandidateRoot -PathValue (Join-Path $expanded "repo\Extract\ToolChain_Support_Packages")
        Add-CandidateRoot -PathValue (Join-Path $expanded "Extract\ToolChain_Support_Packages")
        Add-CandidateRoot -PathValue (Join-Path $expanded "ToolChain_Support_Packages")
    }

    foreach ($envName in @(
        "RTT_EXEC_PATH",
        "RTTHREAD_TOOLCHAIN_BIN",
        "RTTHREAD_STUDIO_TOOLCHAIN_BIN",
        "ARM_GCC_TOOLCHAIN_BIN",
        "GNU_ARM_EMBEDDED_BIN",
        "GNU_ARM_TOOLCHAIN_BIN",
        "RTTHREAD_STUDIO_ROOT",
        "RTTHREAD_STUDIO_HOME",
        "RTTHREADSTUDIO_ROOT",
        "RTTHREADSTUDIO_HOME"
    )) {
        Add-ToolchainHint -PathValue ([Environment]::GetEnvironmentVariable($envName))
    }

    foreach ($root in @($SearchRoots)) {
        Add-ToolchainHint -PathValue $root
        Add-CandidateRoot -PathValue $root
    }

    $projectDirectory = Get-Item -LiteralPath $ProjectRoot -ErrorAction SilentlyContinue
    while ($null -ne $projectDirectory) {
        Add-CandidateRoot -PathValue (Join-Path $projectDirectory.FullName "repo\Extract\ToolChain_Support_Packages")
        Add-CandidateRoot -PathValue (Join-Path $projectDirectory.FullName "RT-ThreadStudio\repo\Extract\ToolChain_Support_Packages")

        $parent = $projectDirectory.Parent
        if ($null -eq $parent) {
            break
        }

        Add-CandidateRoot -PathValue (Join-Path $parent.FullName "RT-ThreadStudio\repo\Extract\ToolChain_Support_Packages")
        $projectDirectory = $parent
    }

    foreach ($base in @($env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($base)) {
            continue
        }

        Add-CandidateRoot -PathValue (Join-Path $base "RT-ThreadStudio\repo\Extract\ToolChain_Support_Packages")
        Add-CandidateRoot -PathValue (Join-Path $base ".rt-thread-studio\repo\Extract\ToolChain_Support_Packages")
    }

    foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($drive.Root)) {
            continue
        }

        Add-CandidateRoot -PathValue (Join-Path $drive.Root "RT-ThreadStudio\repo\Extract\ToolChain_Support_Packages")
    }

    $projectHintFiles = @(
        (Join-Path $ProjectRoot "rtconfig.py"),
        (Join-Path $ProjectRoot ".cproject"),
        (Join-Path $ProjectRoot ".project"),
        (Join-Path $ProjectRoot "Debug\makefile")
    )

    $settingsDir = Join-Path $ProjectRoot ".settings"
    if (Test-Path -LiteralPath $settingsDir -PathType Container) {
        $projectHintFiles += @(Get-ChildItem -LiteralPath $settingsDir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }

    foreach ($hintFile in ($projectHintFiles | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -Unique)) {
        $text = Get-Content -LiteralPath $hintFile -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $matches = [regex]::Matches($text, '(?i)[A-Z]:\\[^\r\n"<>|]*?(?:arm-none-eabi-gcc\.exe|ToolChain_Support_Packages|GNU_Tools_for_ARM_Embedded_Processors)[^\r\n"<>|]*')
        foreach ($match in $matches) {
            Add-ToolchainHint -PathValue $match.Value
        }
    }

    foreach ($root in @($candidateRoots.ToArray() | Select-Object -Unique)) {
        Add-CandidateBin -PathValue $root
        $gccFiles = Get-ChildItem -LiteralPath $root -Recurse -Filter "arm-none-eabi-gcc.exe" -File -ErrorAction SilentlyContinue
        foreach ($gccFile in $gccFiles) {
            $directory = $gccFile.Directory.FullName
            if (Test-ArmGccToolchainDirectory -Directory $directory) {
                Add-CandidateBin -PathValue $directory
            }
        }
    }

    return @($candidateBins.ToArray() | Select-Object -Unique | Sort-Object -Descending)
}

function Add-DirectoriesToPath {
    param([string[]]$Directories)

    $added = @()
    foreach ($directory in @($Directories)) {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw "Toolchain directory does not exist: $directory"
        }

        $pathEntries = @($env:Path -split ";")
        if ($pathEntries -notcontains $directory) {
            $env:Path = "$directory;$env:Path"
            $added += $directory
        }
    }

    return @($added)
}

function Get-CommandPathOrNull {
    param([string]$CommandName)

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }

    return $command.Source
}

function ConvertTo-CommandString {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        throw "BuildCommand cannot be empty."
    }

    return $Command.Trim()
}

function Select-BuildDirectory {
    param(
        [string]$Root,
        [string]$RequestedBuildDir,
        [switch]$NoFallback
    )

    if ([string]::IsNullOrWhiteSpace($RequestedBuildDir) -or $RequestedBuildDir -eq ".") {
        return $Root
    }

    $candidate = Join-Path $Root $RequestedBuildDir
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }

    if ($NoFallback) {
        throw "Build directory does not exist: $candidate"
    }

    return $Root
}

function New-DefaultLogPath {
    param([string]$BuildDirectory)

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return Join-Path $BuildDirectory "rt-thread-build-$timestamp.log"
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
        if ($line -match $script:ProblemLinePattern) {
            return $line
        }
    }

    return $null
}

function ConvertTo-NullableInt {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return [int]$Value
}

function ConvertTo-NullableDouble {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    return [double]$Value
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

function Invoke-BuildCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.Arguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        (Quote-ProcessArgument -Value $Command)
    ) -join " "

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }

    $combined = @()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
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

function Get-BuildArtifactCounts {
    param([string]$BuildDirectory)

    $objectCount = (Get-ChildItem -LiteralPath $BuildDirectory -Recurse -Filter "*.o" -File -ErrorAction SilentlyContinue | Measure-Object).Count
    $dependencyCount = (Get-ChildItem -LiteralPath $BuildDirectory -Recurse -Filter "*.d" -File -ErrorAction SilentlyContinue | Measure-Object).Count
    $outputCount = 0
    foreach ($pattern in @("*.elf", "*.bin", "*.map", "*.siz", "*.hex")) {
        $outputCount += (Get-ChildItem -LiteralPath $BuildDirectory -Recurse -Filter $pattern -File -ErrorAction SilentlyContinue | Measure-Object).Count
    }

    return [pscustomobject]@{
        ObjectCount = [int]$objectCount
        DependencyCount = [int]$dependencyCount
        OutputCount = [int]$outputCount
    }
}

function Invoke-SafeCleanFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$BuildDirectory
    )

    $fullProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    $fullBuildDirectory = [System.IO.Path]::GetFullPath($BuildDirectory).TrimEnd('\', '/')
    $comparison = [System.StringComparison]::OrdinalIgnoreCase

    if ($fullBuildDirectory.Length -lt 4) {
        return [pscustomobject]@{
            Used = $false
            DeletedCount = 0
            FailedCount = 0
            Patterns = @()
            Lines = @("safe clean skipped: build directory is too broad: $fullBuildDirectory")
        }
    }

    if ($fullBuildDirectory.Equals($fullProjectRoot, $comparison)) {
        return [pscustomobject]@{
            Used = $false
            DeletedCount = 0
            FailedCount = 0
            Patterns = @()
            Lines = @("safe clean skipped: build directory is the project root: $fullBuildDirectory")
        }
    }

    if (-not $fullBuildDirectory.StartsWith($fullProjectRoot + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
        return [pscustomobject]@{
            Used = $false
            DeletedCount = 0
            FailedCount = 0
            Patterns = @()
            Lines = @("safe clean skipped: build directory is outside the project root: $fullBuildDirectory")
        }
    }

    $patterns = @("*.o", "*.d", "*.elf", "*.bin", "*.map", "*.siz", "*.hex")
    $deletedCount = 0
    $failedCount = 0
    $lines = @("safe clean: deleting generated build artifacts under $fullBuildDirectory")
    $lines += "safe clean patterns: $($patterns -join ', ')"

    foreach ($pattern in $patterns) {
        $files = @(Get-ChildItem -LiteralPath $fullBuildDirectory -Recurse -Filter $pattern -File -ErrorAction SilentlyContinue)
        foreach ($file in $files) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $deletedCount += 1
            }
            catch {
                $failedCount += 1
                $lines += "safe clean failed: $($file.FullName): $($_.Exception.Message)"
            }
        }
    }

    $lines += "safe clean deleted files: $deletedCount"
    $lines += "safe clean failed files: $failedCount"

    return [pscustomobject]@{
        Used = $true
        DeletedCount = [int]$deletedCount
        FailedCount = [int]$failedCount
        Patterns = @($patterns)
        Lines = @($lines)
    }
}

$resolvedProjectRoot = Resolve-ExistingDirectory -PathValue $ProjectRoot -Name "ProjectRoot"
$resolvedBuildDir = Select-BuildDirectory -Root $resolvedProjectRoot -RequestedBuildDir $BuildDir -NoFallback:$NoBuildDirFallback
$commandString = ConvertTo-CommandString -Command $BuildCommand
$isCleanCommand = $commandString -match "(?i)(^|\s)(clean|distclean|mrproper)(\s|$)"
$cleanCommandString = if ([string]::IsNullOrWhiteSpace($CleanCommand)) { "" } else { $CleanCommand.Trim() }
$runCleanFirst = [bool]($CleanFirst -and -not $NoClean -and -not $isCleanCommand)
$runMakeClean = [bool]($runCleanFirst -and $UseMakeClean)
$runSafeClean = [bool]($runCleanFirst -and -not $UseMakeClean -and $SafeCleanFallback)
if ($runMakeClean -and [string]::IsNullOrWhiteSpace($cleanCommandString)) {
    throw "CleanCommand cannot be empty when UseMakeClean is enabled."
}
$resolvedToolchainBinDirs = @(Resolve-OptionalExistingDirectories -PathValues $ToolchainBinDir)
$autoDetectedToolchainBinDir = $null

if ($resolvedToolchainBinDirs.Count -eq 0 -and -not $NoAutoDetectToolchain) {
    $missingArmTools = @(@("arm-none-eabi-gcc", "arm-none-eabi-objcopy", "arm-none-eabi-size") | Where-Object {
        $null -eq (Get-Command $_ -ErrorAction SilentlyContinue)
    })

    if ($missingArmTools.Count -gt 0) {
        $detectedToolchains = @(Find-ArmGccToolchainBin -ProjectRoot $resolvedProjectRoot -SearchRoots $ToolchainSearchRoot)
        if ($detectedToolchains.Count -gt 0) {
            $autoDetectedToolchainBinDir = $detectedToolchains[0]
            $resolvedToolchainBinDirs = @($autoDetectedToolchainBinDir)
        }
    }
}

$pathPrepended = @(Add-DirectoriesToPath -Directories $resolvedToolchainBinDirs)
$availableCompilerPath = Get-CommandPathOrNull -CommandName "arm-none-eabi-gcc"
$availableObjcopyPath = Get-CommandPathOrNull -CommandName "arm-none-eabi-objcopy"
$availableSizePath = Get-CommandPathOrNull -CommandName "arm-none-eabi-size"

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $resolvedLogPath = New-DefaultLogPath -BuildDirectory $resolvedBuildDir
}
else {
    if ([System.IO.Path]::IsPathRooted($LogPath)) {
        $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
    }
    else {
        $resolvedLogPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedBuildDir $LogPath))
    }
}

$logDir = Split-Path -Parent $resolvedLogPath
if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$cleanExitCode = $null
$cleanOutputLines = @()
$cleanHasIgnoredMakeError = $false
$cleanHasMissingToolError = $false
$cleanFirstProblemLine = $null
$cleanRemainingObjectCount = $null
$cleanRemainingDependencyCount = $null
$cleanRemainingOutputCount = $null
$cleanSuccess = $null
$safeCleanResult = $null
$cleanUsedSafeFallback = $false
$cleanUsedSafeClean = $false
$safeCleanDeletedCount = 0
$safeCleanFailedCount = 0
$safeCleanPatterns = @()

if ($runCleanFirst) {
    if ($runMakeClean) {
        $cleanInvokeResult = Invoke-BuildCommand -Command $cleanCommandString -WorkingDirectory $resolvedBuildDir
        $cleanOutputLines = @($cleanInvokeResult.Lines)
        $cleanExitCode = [int]$cleanInvokeResult.ExitCode
        $cleanOutputText = ($cleanOutputLines -join [Environment]::NewLine)
        $cleanHasIgnoredMakeError = $cleanOutputText -match "(?im)Error\s+[0-9]+\s+\(ignored\)"
        $cleanHasMissingToolError = $cleanOutputText -match $script:MissingArmToolPattern
        $cleanErrorLineCount = ([regex]::Matches($cleanOutputText, $script:ProblemLinePatternMultiline)).Count
        $cleanFirstProblemLine = Get-FirstProblemLine -Lines $cleanOutputLines
        $cleanArtifactCounts = Get-BuildArtifactCounts -BuildDirectory $resolvedBuildDir
        $cleanRemainingObjectCount = $cleanArtifactCounts.ObjectCount
        $cleanRemainingDependencyCount = $cleanArtifactCounts.DependencyCount
        $cleanRemainingOutputCount = $cleanArtifactCounts.OutputCount
        $cleanSuccess = [bool]($cleanExitCode -eq 0 -and $cleanErrorLineCount -eq 0 -and -not $cleanHasIgnoredMakeError -and -not $cleanHasMissingToolError -and $cleanRemainingObjectCount -eq 0 -and $cleanRemainingDependencyCount -eq 0 -and $cleanRemainingOutputCount -eq 0)
    }

    if ((-not $runMakeClean -or -not $cleanSuccess) -and $SafeCleanFallback) {
        $safeCleanResult = Invoke-SafeCleanFallback -ProjectRoot $resolvedProjectRoot -BuildDirectory $resolvedBuildDir
        $cleanUsedSafeFallback = [bool]($runMakeClean -and $safeCleanResult.Used)
        $cleanUsedSafeClean = [bool]$safeCleanResult.Used
        if (-not $runMakeClean) {
            $cleanExitCode = if ($safeCleanResult.FailedCount -eq 0) { 0 } else { 1 }
        }
        $safeCleanDeletedCount = [int]$safeCleanResult.DeletedCount
        $safeCleanFailedCount = [int]$safeCleanResult.FailedCount
        $safeCleanPatterns = @($safeCleanResult.Patterns)
        $cleanArtifactCounts = Get-BuildArtifactCounts -BuildDirectory $resolvedBuildDir
        $cleanRemainingObjectCount = $cleanArtifactCounts.ObjectCount
        $cleanRemainingDependencyCount = $cleanArtifactCounts.DependencyCount
        $cleanRemainingOutputCount = $cleanArtifactCounts.OutputCount
        $cleanSuccess = [bool]($cleanUsedSafeClean -and $safeCleanFailedCount -eq 0 -and $cleanRemainingObjectCount -eq 0 -and $cleanRemainingDependencyCount -eq 0 -and $cleanRemainingOutputCount -eq 0)
    }
}

if ($runCleanFirst -and -not $cleanSuccess) {
    $invokeResult = [pscustomobject]@{
        ExitCode = 1
        Lines = @("build skipped because the clean stage did not complete")
    }
}
else {
    $invokeResult = Invoke-BuildCommand -Command $commandString -WorkingDirectory $resolvedBuildDir
}

$outputLines = @($invokeResult.Lines)
$exitCode = [int]$invokeResult.ExitCode
$outputText = ($outputLines -join [Environment]::NewLine)

$logLines = @()
if ($runCleanFirst) {
    if ($runMakeClean) {
        $logLines += "===== make clean command ====="
        $logLines += $cleanCommandString
        $logLines += "===== make clean output ====="
        $logLines += @($cleanOutputLines)
    }
    else {
        $logLines += "===== clean command ====="
        $logLines += "internal safe clean"
    }
    if ($null -ne $safeCleanResult) {
        $logLines += "===== safe clean ====="
        $logLines += @($safeCleanResult.Lines)
    }
}
$logLines += "===== build command ====="
$logLines += $commandString
$logLines += "===== build output ====="
$logLines += @($outputLines)
$combinedLogText = ($logLines | Where-Object { $null -ne $_ }) -join [Environment]::NewLine
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($resolvedLogPath, $combinedLogText + [Environment]::NewLine, $utf8NoBom)
$oldBuildLogDeletedCount = Remove-OldLogFiles -Directory $logDir -Pattern "rt-thread-build-*.log" -Keep $KeepLogs

$summaryErrors = Get-FirstMatchValue -Text $outputText -Pattern "Build Finished\.\s*(\d+)\s+errors?"
$summaryWarnings = Get-FirstMatchValue -Text $outputText -Pattern "Build Finished\.\s*\d+\s+errors?,\s*(\d+)\s+warnings?"

$errorLineCount = ([regex]::Matches($outputText, $script:ProblemLinePatternMultiline)).Count
$warningLineCount = ([regex]::Matches($outputText, "(?im)(^|[:\s])warning:")).Count

$errorCount = ConvertTo-NullableInt -Value $summaryErrors
if ($null -eq $errorCount) {
    $errorCount = $errorLineCount
}

$warningCount = ConvertTo-NullableInt -Value $summaryWarnings
if ($null -eq $warningCount) {
    $warningCount = $warningLineCount
}

$firstProblemLine = Get-FirstProblemLine -Lines $outputLines

$generatedElf = $null
$generatedBin = $null
if (-not $isCleanCommand) {
    $generatedElf = Get-FirstMatchValue -Text $outputText -Pattern 'arm-none-eabi-size\s+--format=berkeley\s+"?([^"\r\n]+\.elf)"?'
    if ($null -eq $generatedElf) {
        $generatedElf = Get-FirstMatchValue -Text $outputText -Pattern '\s-o\s+"?([^"\s]+\.elf)"?'
    }

    $generatedBin = Get-FirstMatchValue -Text $outputText -Pattern 'arm-none-eabi-objcopy[^\r\n]*\s+"?([^"\s]+\.bin)"?'
}

$flashBytes = Get-FirstMatchValue -Text $outputText -Pattern "Flash:\s*([0-9]+)\s+B"
$flashKB = Get-FirstMatchValue -Text $outputText -Pattern "Flash:\s*[0-9]+\s+B\s+([0-9.]+)\s+KB"
$ramBytes = Get-FirstMatchValue -Text $outputText -Pattern "RAM:\s*([0-9]+)\s+B"
$ramKB = Get-FirstMatchValue -Text $outputText -Pattern "RAM:\s*[0-9]+\s+B\s+([0-9.]+)\s+KB"

$usedCompiler = $null
if ($outputText -match "arm-none-eabi-gcc") {
    $usedCompiler = "arm-none-eabi-gcc"
}

$usedObjcopy = $outputText -match "arm-none-eabi-objcopy"
$usedSize = $outputText -match "arm-none-eabi-size"
$hasIgnoredMakeError = $outputText -match "(?im)Error\s+[0-9]+\s+\(ignored\)"
$hasMissingToolError = $outputText -match $script:MissingArmToolPattern
$singleCleanRemainingObjectCount = $null
$singleCleanRemainingDependencyCount = $null
if ($isCleanCommand) {
    $singleCleanArtifactCounts = Get-BuildArtifactCounts -BuildDirectory $resolvedBuildDir
    $singleCleanRemainingObjectCount = $singleCleanArtifactCounts.ObjectCount
    $singleCleanRemainingDependencyCount = $singleCleanArtifactCounts.DependencyCount
}

$buildSuccess = ($exitCode -eq 0 -and $errorCount -eq 0 -and -not $hasIgnoredMakeError -and -not $hasMissingToolError)
$success = [bool]($buildSuccess -and ($null -eq $cleanSuccess -or $cleanSuccess))
$overallExitCode = if ($success) { 0 } elseif ($exitCode -ne 0) { $exitCode } else { 1 }

$result = [ordered]@{
    projectRoot = $resolvedProjectRoot
    buildDir = $resolvedBuildDir
    buildCommand = $commandString
    cleanFirst = [bool]$runCleanFirst
    cleanMethod = if (-not $runCleanFirst) { "none" } elseif ($runMakeClean) { "make-clean-with-safe-fallback" } else { "safe-clean" }
    cleanCommand = if ($runCleanFirst -and $runMakeClean) { $cleanCommandString } elseif ($runCleanFirst) { "internal safe clean" } else { $null }
    useMakeClean = [bool]$runMakeClean
    isCleanCommand = [bool]$isCleanCommand
    fullRebuild = [bool]($runCleanFirst -and $cleanSuccess -and -not $isCleanCommand)
    toolchainBinDirs = @($resolvedToolchainBinDirs)
    autoDetectedToolchainBinDir = $autoDetectedToolchainBinDir
    pathPrepended = @($pathPrepended)
    availableCompilerPath = $availableCompilerPath
    availableObjcopyPath = $availableObjcopyPath
    availableSizePath = $availableSizePath
    success = [bool]$success
    exitCode = [int]$overallExitCode
    buildSuccess = [bool]$buildSuccess
    buildExitCode = [int]$exitCode
    cleanSuccess = $cleanSuccess
    cleanExitCode = $cleanExitCode
    cleanHasIgnoredMakeError = [bool]$cleanHasIgnoredMakeError
    cleanHasMissingToolError = [bool]$cleanHasMissingToolError
    cleanFirstProblemLine = $cleanFirstProblemLine
    cleanRemainingObjectCount = $cleanRemainingObjectCount
    cleanRemainingDependencyCount = $cleanRemainingDependencyCount
    cleanRemainingOutputCount = $cleanRemainingOutputCount
    safeCleanFallbackEnabled = [bool]$SafeCleanFallback
    cleanUsedSafeClean = [bool]$cleanUsedSafeClean
    cleanUsedSafeFallback = [bool]$cleanUsedSafeFallback
    safeCleanDeletedCount = [int]$safeCleanDeletedCount
    safeCleanFailedCount = [int]$safeCleanFailedCount
    safeCleanPatterns = @($safeCleanPatterns)
    usedCompiler = $usedCompiler
    usedObjcopy = [bool]$usedObjcopy
    usedSize = [bool]$usedSize
    hasIgnoredMakeError = [bool]$hasIgnoredMakeError
    hasMissingToolError = [bool]$hasMissingToolError
    singleCleanRemainingObjectCount = $singleCleanRemainingObjectCount
    singleCleanRemainingDependencyCount = $singleCleanRemainingDependencyCount
    generatedElf = $generatedElf
    generatedBin = $generatedBin
    errors = [int]$errorCount
    warnings = [int]$warningCount
    firstProblemLine = $firstProblemLine
    flashBytes = ConvertTo-NullableInt -Value $flashBytes
    flashKB = ConvertTo-NullableDouble -Value $flashKB
    ramBytes = ConvertTo-NullableInt -Value $ramBytes
    ramKB = ConvertTo-NullableDouble -Value $ramKB
    keepLogs = [int]$KeepLogs
    oldLogDeletedCount = [int]$oldBuildLogDeletedCount
    logPath = $resolvedLogPath
}

$result | ConvertTo-Json -Depth 4

if (-not $success) {
    exit $overallExitCode
}

