$ErrorActionPreference = 'Stop';
$toolsDir = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
$urlAmd64 = 'https://releases.stackql.io/stackql/0.12.824/stackql_windows_amd64.msi'
$checksumAmd64 = '4456b40670020c2a9ae5ea62cc72f549fcdf59c13ffb3376c1e13bd531fea2b1'
# Populated by publish-prep.ps1 for the first ARM64 release.
$urlArm64 = 'https://releases.stackql.io/stackql/0.12.824/stackql_windows_arm64.msi'
$checksumArm64 = 'd4d167865fbc1d3e2fd41848bbcb372869c55445c269cf7b720bbe7e7263eb2c'

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'StackQL requires AMD64 or ARM64 Windows.'
}

# Query the platform architecture even when PowerShell runs under emulation.
$architecture = Get-CimInstance -ClassName Win32_Processor -Property Architecture |
    Select-Object -First 1 -ExpandProperty Architecture
switch ($architecture) {
    9  { $url = $urlAmd64; $checksum = $checksumAmd64 }
    12 { $url = $urlArm64; $checksum = $checksumArm64 }
    default { throw "Unsupported processor architecture: $architecture" }
}
if (-not $url -or $checksum -notmatch '^[a-fA-F0-9]{64}$') {
    throw 'This package has not been prepared for this architecture. Run publish-prep.ps1 before publishing.'
}

$packageArgs = @{
    packageName    = $env:ChocolateyPackageName
    unzipLocation  = $toolsDir
    fileType       = 'MSI'
    url            = $url
    softwareName   = 'stackql*'
    checksum       = $checksum
    checksumType   = 'sha256'
    silentArgs     = "/passive /l* stackql.log"
    validExitCodes = @(0, 3010, 1641)
}

Install-ChocolateyPackage @packageArgs
