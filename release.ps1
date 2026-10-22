# .\release.ps1
#
# Step 2 of the Windows release flow (run after build.ps1, from the root of this repo).
#
# Checks versions and signatures in the AMD64 and ARM64 MSI/ZIP pairs,
# computes a SHA-256 sidecar (<asset>.sha256, sha256sum format) for each
# signed package, then uploads all four assets and their sidecars to the
# existing v<version> release and verifies the digest GitHub recorded for
# the attached bytes against the local one.
# Nothing is installed, and the releases proxy semver pointer is not moved.
#
# Existing release assets are never overwritten. If an asset with the same name
# is already on the release it is skipped. To replace it, delete it from the
# release manually and run this script again. A sidecar is only published when
# the attached asset is verified to be byte-identical to the local package, so
# a sidecar never describes bytes other than the ones on the release.
#
# Requirements:
#   - build.ps1 has been run (AMD64 and ARM64 MSI/ZIP pairs exist in msi\)
#   - the GitHub release v<version> already exists in stackql/stackql
#   - gh CLI installed and authenticated (gh auth login)
#
# Usage:
#   .\release.ps1
#   .\release.ps1 -AllowUnsigned    # upload even if the Authenticode signatures are not valid

param(
    [switch]$AllowUnsigned
)

$ErrorActionPreference = 'Stop'

$org = "stackql"
$repo = "stackql"
$packages = foreach ($architecture in @('amd64', 'arm64')) {
    [pscustomobject]@{
        Architecture = $architecture
        MsiPath = Join-Path $PSScriptRoot "msi\stackql_windows_${architecture}.msi"
        ZipPath = Join-Path $PSScriptRoot "msi\stackql_windows_${architecture}.zip"
    }
}
$files = foreach ($package in $packages) { $package.MsiPath; $package.ZipPath }

function Write-Banner([string]$Message) {
    Write-Host "*******************************************************************************"
    Write-Host $Message
    Write-Host "*******************************************************************************"
}

function Get-MsiProductVersion([string]$Path) {
    # Opens the MSI database read-only (mode 0) and reads the ProductVersion
    # property from the Property table. Nothing is installed or registered.
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $null
    $view = $null
    $record = $null
    try {
        $db = $installer.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $installer, @($Path, 0))
        $sql = "SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = 'ProductVersion'"
        $view = $db.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $db, @($sql))
        $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, $null) | Out-Null
        $record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $view, $null)
        if ($null -eq $record) {
            throw "ProductVersion property not found in $Path"
        }
        return [string]$record.GetType().InvokeMember("StringData", "GetProperty", $null, $record, 1)
    } finally {
        if ($null -ne $view) {
            $view.GetType().InvokeMember("Close", "InvokeMethod", $null, $view, $null) | Out-Null
        }
        foreach ($obj in @($record, $view, $db, $installer)) {
            if ($null -ne $obj) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) | Out-Null
            }
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

function Get-ZipExeInfo([string]$Path) {
    # Extracts the zip to a temp directory and reads the file version and
    # Authenticode signature of the stackql.exe inside it.
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("stackql-release-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        Expand-Archive -Path $Path -DestinationPath $tempDir -Force
        $exe = Join-Path $tempDir "stackql.exe"
        if (-not (Test-Path $exe)) {
            throw "stackql.exe not found in $Path"
        }
        $version = ([string](Get-Item $exe).VersionInfo.FileVersion).Trim()
        # build.ps1 stamps a 3 part version; tolerate a trailing .0 if it is ever reported as 4 parts
        if ($version -match '^(\d+\.\d+\.\d+)\.0$') {
            $version = $Matches[1]
        }
        return [pscustomobject]@{
            Version   = $version
            Signature = Get-AuthenticodeSignature $exe
        }
    } finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-Signature([string]$Label, $Signature) {
    if ($Signature.Status -eq 'Valid') {
        Write-Host "${Label}: signed by $($Signature.SignerCertificate.Subject)"
        return $true
    }
    Write-Warning "${Label}: Authenticode signature status is '$($Signature.Status)' ($($Signature.StatusMessage))"
    return $false
}

function Get-Sha256Hex([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Sha256Sidecar([string]$Path, [string]$Hash) {
    # sha256sum format: lowercase hex, two spaces, bare filename, LF line ending,
    # UTF-8 without BOM, so 'sha256sum -c' and 'shasum -c' accept it and it
    # matches the .mcpb.sha256 sidecars published by the mcp-packaging workflow.
    $sidecar = "$Path.sha256"
    $name = Split-Path $Path -Leaf
    [System.IO.File]::WriteAllText($sidecar, "$Hash  $name`n", (New-Object System.Text.UTF8Encoding $false))
    return $sidecar
}

function Get-ReleaseAssets([string]$Tag) {
    # name -> asset, including the sha256 digest GitHub recorded for the attached bytes
    $json = gh api "repos/${org}/${repo}/releases/tags/$Tag"
    if ($LASTEXITCODE -ne 0) {
        throw "Release $Tag was not found in ${org}/${repo}. Create the release first, then re-run this script."
    }
    $assets = @{}
    foreach ($asset in (($json -join "") | ConvertFrom-Json).assets) {
        $assets[$asset.name] = $asset
    }
    return $assets
}

Write-Banner "Checking build outputs"

foreach ($file in $files) {
    if (-not (Test-Path $file)) {
        throw "Not found: $file (run build.ps1 first)"
    }
    Write-Host "Found $file"
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "gh CLI not found. Install it from https://cli.github.com/ and run 'gh auth login'."
}

Write-Banner "Checking versions and signatures (nothing is installed)"

$version = $null
$allSigned = $true
foreach ($package in $packages) {
    $architecture = $package.Architecture
    $msiVersion = Get-MsiProductVersion $package.MsiPath
    $zipInfo = Get-ZipExeInfo $package.ZipPath
    Write-Host "$architecture MSI ProductVersion      : $msiVersion"
    Write-Host "$architecture ZIP stackql.exe version : $($zipInfo.Version)"

    if ($msiVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Unexpected $architecture MSI ProductVersion '$msiVersion' (expected major.minor.patch)"
    }
    if ($msiVersion -ne $zipInfo.Version) {
        throw "Version mismatch: the $architecture MSI is $msiVersion but the ZIP contains stackql.exe $($zipInfo.Version). Re-run build.ps1."
    }
    if ($null -ne $version -and $msiVersion -ne $version) {
        throw "Version mismatch between architectures: expected $version but $architecture is $msiVersion. Re-run build.ps1."
    }
    $version = $msiVersion

    $msiSigned = Test-Signature "$architecture MSI" (Get-AuthenticodeSignature $package.MsiPath)
    $exeSigned = Test-Signature "$architecture ZIP stackql.exe" $zipInfo.Signature
    if (-not ($msiSigned -and $exeSigned)) { $allSigned = $false }
}
$tag = "v$version"
Write-Host "Release tag             : $tag"

if (-not $allSigned) {
    if ($AllowUnsigned) {
        Write-Warning "Continuing with unsigned files because -AllowUnsigned was specified"
    } else {
        throw "Signature check failed. Re-run '.\build.ps1 true' to produce signed packages, or pass -AllowUnsigned to override."
    }
}

Write-Banner "Computing SHA-256 digests of the signed packages"

$digests = @{}
foreach ($file in $files) {
    $name = Split-Path $file -Leaf
    $hash = Get-Sha256Hex $file
    $digests[$name] = $hash
    $sidecar = Write-Sha256Sidecar $file $hash
    Write-Host "$hash  $name  -> $(Split-Path $sidecar -Leaf)"
}

Write-Banner "Checking release $tag in ${org}/${repo}"

$existing = Get-ReleaseAssets $tag
Write-Host "Release tag     : $tag"
Write-Host "Existing assets : $(if ($existing.Count -gt 0) { ($existing.Keys | Sort-Object) -join ', ' } else { '(none)' })"

Write-Banner "Uploading assets"

$uploaded = @()
$skipped = @()
foreach ($file in $files) {
    $name = Split-Path $file -Leaf
    $hash = $digests[$name]
    $sidecarFile = "$file.sha256"
    $sidecarName = "$name.sha256"

    # The package: upload it, or verify that the attached bytes are the local bytes.
    $publishSidecar = $false
    if ($existing.ContainsKey($name)) {
        $remoteDigest = [string]$existing[$name].digest
        if ($remoteDigest -eq "sha256:$hash") {
            Write-Warning "$name already exists on release $tag and will not be overwritten (its digest matches the local package)."
            $publishSidecar = $true
        } elseif ([string]::IsNullOrEmpty($remoteDigest)) {
            Write-Warning "$name already exists on release $tag but GitHub reports no digest for it, so it cannot be verified against the local package. Not publishing $sidecarName. Delete the asset from the release and re-run to replace it."
        } else {
            throw "$name already exists on release $tag with digest $remoteDigest but the local package is sha256:$hash. The release holds different bytes than this build. Delete the asset (and any $sidecarName) from the release manually if it needs to be replaced."
        }
        $skipped += $name
    } else {
        Write-Host "Uploading $name ..."
        gh release upload $tag $file --repo "${org}/${repo}"
        if ($LASTEXITCODE -ne 0) {
            throw "Upload of $name to release $tag failed"
        }
        $uploaded += $name
        $publishSidecar = $true
    }

    # The sidecar: only ever published for bytes verified to be on the release.
    if ($existing.ContainsKey($sidecarName)) {
        Write-Host "$sidecarName already exists on release $tag, skipping."
        $skipped += $sidecarName
    } elseif ($publishSidecar) {
        Write-Host "Uploading $sidecarName ..."
        gh release upload $tag $sidecarFile --repo "${org}/${repo}"
        if ($LASTEXITCODE -ne 0) {
            throw "Upload of $sidecarName to release $tag failed"
        }
        $uploaded += $sidecarName
    }
}

Write-Banner "Verifying the attached bytes against the local digests"

$attached = Get-ReleaseAssets $tag
$verified = @()
foreach ($name in ($digests.Keys | Sort-Object)) {
    $hash = $digests[$name]
    if (-not $attached.ContainsKey($name)) {
        throw "$name is not on release $tag after upload"
    }
    $remoteDigest = [string]$attached[$name].digest
    if ([string]::IsNullOrEmpty($remoteDigest)) {
        Write-Warning "$name is on release $tag but GitHub reports no digest for it, so it could not be verified."
        continue
    }
    if ($remoteDigest -ne "sha256:$hash") {
        throw "Digest mismatch for ${name}: release $tag holds '$remoteDigest', the local package is sha256:$hash"
    }
    if (-not $attached.ContainsKey("$name.sha256")) {
        Write-Warning "$name.sha256 is not on release $tag"
    }
    Write-Host "OK  $hash  $name"
    $verified += $name
}

Write-Banner "Summary"

Write-Host "Release  : $tag"
Write-Host "Uploaded : $(if ($uploaded.Count -gt 0) { $uploaded -join ', ' } else { '(none)' })"
Write-Host "Skipped  : $(if ($skipped.Count -gt 0) { $skipped -join ', ' } else { '(none)' })"
Write-Host "Verified : $(if ($verified.Count -gt 0) { $verified -join ', ' } else { '(none)' })"
