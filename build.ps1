# .\build.ps1 <stackql release> <stackql-workbench release> [true]
# .\build.ps1 v1.1.959 v0.1.0 true
#
# Downloads the unsigned Windows builds for the stackql release from its Build
# workflow run and the StackQL Workbench executables from the stackql-workbench
# release, then builds the AMD64 and ARM64 MSIs and ZIPs. Pass true to sign.
#
# NOTES:
# 1. File versioning will not work if the directory for this repo is a Dropbox, OneDrive dir etc
# 2. McAfee AV must be temporarily disabled for version stamping
#

param(
    [Parameter(Position = 0)]
    [string]$EngineRelease,
    [Parameter(Position = 1)]
    [string]$WorkbenchRelease,
    [Parameter(Position = 2)]
    [string]$Sign
)

$ErrorActionPreference = 'Stop'
$architectures = @('amd64', 'arm64')

$Product = "StackQL - Query and Provision Cloud Services using SQL."
$FileDescription = "StackQL Executable"
$IconPath = ".\inc\stackql.ico"
$LegalCopyright = "Copyright (c) 2020-2025 StackQL Studios. All rights reserved."
$EngineRepo = "stackql/stackql"
$EngineWorkflow = "build.yml"
$EngineBranch = "main"
$RunLookupLimit = 500
$WorkbenchRepo = "stackql/stackql-workbench"
$Usage = "Usage: .\build.ps1 <stackql release> <stackql-workbench release> [true], for example .\build.ps1 v1.1.959 v0.1.0 true"

function Write-Banner([string]$Message) {
    Write-Output "*******************************************************************************"
    Write-Output $Message
    Write-Output "*******************************************************************************"
}

function Assert-PEMachine([string]$Path, [string]$Architecture) {
    $reader = New-Object System.IO.BinaryReader([System.IO.File]::OpenRead((Resolve-Path $Path).Path))
    try {
        $reader.BaseStream.Position = 0x3c
        $reader.BaseStream.Position = $reader.ReadInt32()
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Invalid PE header in $Path"
        }
        $machine = $reader.ReadUInt16()
        $expectedMachine = if ($Architecture -eq 'amd64') { 0x8664 } else { 0xaa64 }
        if ($machine -ne $expectedMachine) {
            throw "Unexpected processor architecture in $Path"
        }
    } finally {
        $reader.Dispose()
    }
}

function Get-GhJson([string[]]$Arguments) {
    # Returns $null when gh fails; gh prints the reason.
    $output = & $gh @Arguments
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($output -join "`n") | ConvertFrom-Json
}

function Save-EngineArtifact([string]$Id, [string]$Path) {
    # gh writes the zip to stdout. Start-Process redirects it to the file byte for byte,
    # which PowerShell 5.1 pipeline redirection does not.
    $errorPath = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath $gh -ArgumentList @('api', "repos/$EngineRepo/actions/artifacts/$Id/zip") `
            -RedirectStandardOutput $Path -RedirectStandardError $errorPath -NoNewWindow -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Downloading artifact $Id failed (exit $($process.ExitCode)): $(Get-Content -LiteralPath $errorPath -Raw)"
        }
    } finally {
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-WorkbenchFile([string]$Name) {
    # The progress bar slows Invoke-WebRequest on Windows PowerShell.
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri "$WorkbenchBaseUrl/$Name" -OutFile ".\downloaded\$Name" -UseBasicParsing
}

if ($EngineRelease -notmatch '^v?(\d+\.\d+\.(\d+))$') {
    throw "Invalid stackql release '$EngineRelease'. $Usage"
}
$ReleaseVersion = $Matches[1]
$BuildNumber = [int]$Matches[2]
$EngineTag = "v$ReleaseVersion"

if ($WorkbenchRelease -notmatch '^v?(\d+\.\d+\.\d+)$') {
    throw "Invalid stackql-workbench release '$WorkbenchRelease'. $Usage"
}
$WorkbenchVersion = $Matches[1]
$WorkbenchTag = "v$WorkbenchVersion"

if ($Sign -notin @('', 'true', 'false')) {
    throw "Invalid signing flag '$Sign', pass true to sign or leave it out. $Usage"
}
$signing = $Sign -eq 'true'

$gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $gh) {
    throw "gh CLI not found. Install it from https://cli.github.com/ and run 'gh auth login'."
}
$gh = $gh.Source

# stackql: the release tag must point at the commit its Build run built.
Write-Banner "Checking stackql release $EngineTag and build $BuildNumber"
if ($null -eq (Get-GhJson @('api', "repos/$EngineRepo/releases/tags/$EngineTag"))) {
    throw "Release $EngineTag could not be read from $EngineRepo. Create the release from the tag first."
}
$runs = Get-GhJson @('run', 'list', '-R', $EngineRepo, '-w', $EngineWorkflow, '-b', $EngineBranch,
    '-L', "$RunLookupLimit", '--json', 'databaseId,number,headSha,conclusion')
if ($null -eq $runs) {
    throw "Listing the $EngineWorkflow runs on $EngineBranch in $EngineRepo failed"
}
$run = $runs | Where-Object { $_.number -eq $BuildNumber } | Select-Object -First 1
if ($null -eq $run) {
    throw "Build $BuildNumber not found in the last $RunLookupLimit runs of $EngineWorkflow on $EngineBranch in $EngineRepo"
}
Write-Output "Build $BuildNumber is run $($run.databaseId) (commit $($run.headSha), conclusion $($run.conclusion))"
if ($run.conclusion -ne 'success') {
    throw "Run $($run.databaseId) concluded '$($run.conclusion)', not success"
}
$tagCommit = & $gh api "repos/$EngineRepo/commits/$EngineTag" --jq '.sha'
if ($LASTEXITCODE -ne 0) {
    throw "Reading the commit of tag $EngineTag failed"
}
$tagCommit = ($tagCommit | Out-String).Trim()
if ($tagCommit -ne $run.headSha) {
    throw "Tag $EngineTag points at $tagCommit but build $BuildNumber built $($run.headSha)"
}

$engineArtifacts = @{}
foreach ($architecture in $architectures) {
    $name = "stackql_windows_$architecture"
    $listing = Get-GhJson @('api', "repos/$EngineRepo/actions/runs/$($run.databaseId)/artifacts?name=$name")
    $artifact = if ($null -ne $listing) { $listing.artifacts | Select-Object -First 1 }
    if ($null -eq $artifact) {
        throw "Artifact $name not found in run $($run.databaseId)"
    }
    if ($artifact.expired) {
        throw "Artifact $name of run $($run.databaseId) has expired, re-run the build workflow"
    }
    if ([string]::IsNullOrEmpty($artifact.digest)) {
        throw "GitHub reports no digest for artifact $name of run $($run.databaseId), so its download cannot be verified"
    }
    $engineArtifacts[$architecture] = $artifact
}

Write-Banner "Checking stackql-workbench release $WorkbenchTag"
$workbenchReleaseInfo = Get-GhJson @('api', "repos/$WorkbenchRepo/releases/tags/$WorkbenchTag")
if ($null -eq $workbenchReleaseInfo) {
    throw "Release $WorkbenchTag could not be read from $WorkbenchRepo"
}
$workbenchAssets = @($workbenchReleaseInfo.assets | ForEach-Object { $_.name })
foreach ($architecture in $architectures) {
    foreach ($name in @("stackql-workbench_windows_${architecture}.exe", "stackql-workbench_windows_${architecture}.exe.sha256")) {
        if ($workbenchAssets -notcontains $name) {
            throw "$name is not on release $WorkbenchTag of $WorkbenchRepo"
        }
    }
}
$WorkbenchBaseUrl = "https://github.com/$WorkbenchRepo/releases/download/$WorkbenchTag"

# stackql: the zips exactly as GitHub stores them, checked against the recorded size and digest.
foreach ($architecture in $architectures) {
    $artifact = $engineArtifacts[$architecture]
    $zipPath = ".\downloaded\stackql_windows_${architecture}.zip"
    Write-Banner "Downloading $architecture stackql build $BuildNumber"
    Save-EngineArtifact $artifact.id $zipPath

    $size = (Get-Item -LiteralPath $zipPath).Length
    if ($size -ne $artifact.size_in_bytes) {
        throw "$zipPath is $size bytes but GitHub reports $($artifact.size_in_bytes) bytes for artifact $($artifact.name)"
    }
    $digest = "sha256:$((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant())"
    if ($digest -ne $artifact.digest) {
        throw "Digest mismatch for ${zipPath}: GitHub recorded $($artifact.digest) but got $digest"
    }
    Write-Output "$($artifact.name) from run $($run.databaseId), $digest"
}

# StackQL Workbench: checked against its published SHA-256.
foreach ($architecture in $architectures) {
    Write-Banner "Downloading $architecture StackQL Workbench $WorkbenchTag"
    $workbenchName = "stackql-workbench_windows_${architecture}.exe"
    $workbenchDownload = ".\downloaded\$workbenchName"
    Get-WorkbenchFile $workbenchName
    Get-WorkbenchFile "$workbenchName.sha256"

    $expectedHash = ((Get-Content -LiteralPath "$workbenchDownload.sha256" -TotalCount 1) -split '\s+')[0]
    if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw "No SHA-256 checksum found in $workbenchDownload.sha256"
    }
    $actualHash = (Get-FileHash -LiteralPath $workbenchDownload -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
        throw "Checksum mismatch for ${workbenchDownload}: expected $expectedHash but got $actualHash"
    }
    Assert-PEMachine $workbenchDownload $architecture
    $workbenchFileVersion = ([string](Get-Item -LiteralPath $workbenchDownload).VersionInfo.FileVersion).Trim()
    if ($workbenchFileVersion -notmatch "^$([regex]::Escape($WorkbenchVersion))(\.0)?$") {
        throw "$workbenchName is version $workbenchFileVersion, expected $WorkbenchVersion for release $WorkbenchTag"
    }
    Write-Output "$workbenchName version $workbenchFileVersion, SHA-256 $($actualHash.ToLowerInvariant())"
}

if ($signing) {
    Write-Output "Binaries and packages will be signed. Ensure smart token is installed before pressing enter..."
    pause
}

Write-Banner "Clearing msi and bin directories"
foreach ($directory in @('msi', 'bin')) {
    if (Test-Path -LiteralPath ".\$directory") {
        Get-ChildItem -LiteralPath ".\$directory" -Force | Remove-Item -Force -Recurse
    } else {
        New-Item -ItemType Directory -Path ".\$directory" | Out-Null
    }
}

foreach ($architecture in $architectures) {
    Write-Banner "Extracting $architecture build"
    $exePath = ".\bin\$architecture\stackql.exe"
    Expand-Archive -Path ".\downloaded\stackql_windows_${architecture}.zip" -DestinationPath ".\bin\$architecture"
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw "stackql.exe not found in the $architecture archive"
    }
    Assert-PEMachine $exePath $architecture

    # Not stamped with rcedit: the Workbench carries its own version and icon.
    Copy-Item -LiteralPath ".\downloaded\stackql-workbench_windows_${architecture}.exe" -Destination ".\bin\$architecture\stackql-workbench.exe"
}

# Read the shared version from a copy so resource editing never touches a just-run EXE.
Write-Banner "Reading shared StackQL version"
Copy-Item -LiteralPath .\bin\amd64\stackql.exe -Destination .\bin\stackql-version.exe
$VersionOutput = & .\bin\stackql-version.exe --version
if ($LASTEXITCODE -ne 0) { throw "Reading StackQL version failed (exit $LASTEXITCODE)" }
Write-Output $VersionOutput
if (($VersionOutput | Out-String) -notmatch '\bv(\d+\.\d+\.\d+)\b') {
    throw "Could not read the StackQL version"
}
$Version = $Matches[1]
if ($Version -ne $ReleaseVersion) {
    throw "stackql.exe reports version $Version but the release is $EngineTag"
}
$env:StackQLBuildVersion = $Version

foreach ($architecture in $architectures) {
    $exePath = ".\bin\$architecture\stackql.exe"

    Write-Banner "Versioning $architecture EXE: $Version"
    .\lib\rcedit-x86.exe $exePath `
        --set-product-version $Version `
        --set-file-version $Version `
        --set-version-string "ProductName" $Product `
        --set-version-string "FileDescription" $FileDescription `
        --set-version-string "LegalCopyright" $LegalCopyright `
        --set-icon $IconPath
    if ($LASTEXITCODE -ne 0) { throw "Versioning $architecture EXE failed (exit $LASTEXITCODE)" }
}

if ($signing) {
    foreach ($architecture in $architectures) {
        $exePath = ".\bin\$architecture\stackql.exe"
        $workbenchPath = ".\bin\$architecture\stackql-workbench.exe"
        Write-Banner "Signing $architecture EXEs"
        .\lib\signtool sign /tr http://timestamp.comodoca.com /td sha256 /fd sha256 /n StackQL $exePath $workbenchPath
        if ($LASTEXITCODE -ne 0) { throw "Signing $architecture EXEs failed (exit $LASTEXITCODE)" }
    }
}

foreach ($architecture in $architectures) {
    $exePath = ".\bin\$architecture\stackql.exe"
    $workbenchPath = ".\bin\$architecture\stackql-workbench.exe"
    $msiPath = ".\msi\stackql_${Version}_windows_${architecture}.msi"
    $zipPath = ".\msi\stackql_${Version}_windows_${architecture}.zip"
    $wixArchitecture = if ($architecture -eq 'amd64') { 'x64' } else { 'arm64' }

    Write-Banner "Building $architecture MSI"
    wix.exe build .\stackql.wxs -arch $wixArchitecture -d "BinaryPath=$exePath" -d "WorkbenchPath=$workbenchPath" -ext WixToolset.UI.wixext -o $msiPath
    if ($LASTEXITCODE -ne 0) { throw "Building $architecture MSI failed (exit $LASTEXITCODE)" }

    if ($signing) {
        Write-Banner "Signing $architecture MSI"
        .\lib\signtool sign /tr http://timestamp.comodoca.com /td sha256 /fd sha256 /n StackQL $msiPath
        if ($LASTEXITCODE -ne 0) { throw "Signing $architecture MSI failed (exit $LASTEXITCODE)" }
    }

    Copy-Item -LiteralPath $msiPath -Destination ".\msi\stackql_windows_${architecture}.msi"

    Write-Banner "Creating $architecture ZIP"
    Compress-Archive -Path $exePath -DestinationPath $zipPath
    Copy-Item -LiteralPath $zipPath -Destination ".\msi\stackql_windows_${architecture}.zip"
}
