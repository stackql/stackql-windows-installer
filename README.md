# stackql-windows-installer

Builds, releases and publishes the StackQL packages for Windows:

- `stackql_windows_amd64.msi` and `stackql_windows_arm64.msi` - Authenticode signed MSI installers
- `stackql_windows_amd64.zip` and `stackql_windows_arm64.zip` - ZIPs containing the signed `stackql.exe`
- the `stackql` Chocolatey package, which selects the native AMD64 or ARM64 MSI from the releases proxy

This repo replaces the former `stackql-msi` and `chocolatey-install` repos.

## Prerequisites

- Windows with PowerShell 5.1 or later
- [WiX Toolset](https://wixtoolset.org/) v4 or later (`wix.exe` on the PATH) with the UI extension installed: `wix extension add -g WixToolset.UI.wixext`
- [GitHub CLI](https://cli.github.com/) authenticated with access to the `stackql` org (`gh auth login`)
- The hardware token holding the StackQL Studios code signing certificate, and the token client software (for example Thales SafeNet Authentication Client)
- Chocolatey, only if you want to build or test the Chocolatey package locally

Two things to be aware of when building:

- File versioning does not work if this repo lives in a synced folder (Dropbox, OneDrive and similar)
- McAfee AV must be temporarily disabled for version stamping

## Release flow

The overall StackQL release is driven from the [stackql](https://github.com/stackql/stackql) repo: a tag is pushed, a GitHub release is created, and the signed platform packages are added to that release as assets. After package UAT, release availability is gated by moving the Cloudflare releases proxy semver pointer to the next release. GitHub draft releases are not used. All published release/download links and script download URLs use `releases.stackql.io`.

The Windows part of that flow is the steps below. Run each script from the root of this repo.

### Before you start

Save both unsigned Windows builds for the release as `downloaded\stackql_windows_amd64.zip` and `downloaded\stackql_windows_arm64.zip`. Both must be from the same release build. The `downloaded`, `bin` and `msi` directories are gitignored.

### Step 1: build and sign the MSI and ZIP

```powershell
.\build.ps1 true
```

Insert the hardware token before running. The script pauses so you can confirm the token is inserted, then makes four separate signing calls in this order: AMD64 EXE, ARM64 EXE, AMD64 MSI, ARM64 MSI. Expect one token password prompt per call when password caching or single logon is disabled in the token client; the client controls the prompts. See [SafeNet single logon settings](https://www.sectigo.com/knowledge-base/detail/enable-safenet-single-log-on-for-document-or-code-signing). Enter the password carefully: the token is locked out after more than 3 incorrect attempts.

The script extracts both ZIPs into `bin\<architecture>\`, reads the shared version from the AMD64 executable, and stamps both executables before signing either. It then signs both EXEs, builds and signs the AMD64 MSI, creates the AMD64 ZIP, builds and signs the ARM64 MSI, and creates the ARM64 ZIP. It writes the outputs to `msi\`:

- `stackql_<version>_windows_amd64.msi` and `stackql_windows_amd64.msi`
- `stackql_<version>_windows_amd64.zip` and `stackql_windows_amd64.zip`
- `stackql_<version>_windows_arm64.msi` and `stackql_windows_arm64.msi`
- `stackql_<version>_windows_arm64.zip` and `stackql_windows_arm64.zip`

Running `.\build.ps1` without `true` produces unsigned packages. These are fine for local testing but `release.ps1` will refuse to upload them.

### Step 2: upload the release assets

```powershell
.\release.ps1
```

The script reads each MSI's `ProductVersion` and the file version of `stackql.exe` inside each ZIP (nothing is installed), checks that all versions match and all signatures are valid, writes a `<asset>.sha256` sidecar (sha256sum format) for each package, then uploads the four unversioned filenames and their sidecars as assets to the `stackql/stackql` release tagged `v<version>` and verifies the SHA-256 digest GitHub recorded for each attached package against the local one. The release must already exist. Uploading does not move the releases proxy semver pointer; promotion follows the separate package UAT process.

Existing assets are never overwritten. If an asset with the same name is already on the release it is skipped with a warning, and the script fails if the attached bytes differ from the local package. A sidecar is only uploaded when the attached package is byte-identical to the local one. To replace an asset, delete it and its sidecar from the release on GitHub first and run the script again. Pass `-AllowUnsigned` to upload unsigned packages.

### Step 3: prepare the Chocolatey package

After moving the releases proxy semver pointer to the approved release, wait until the proxy serves both MSIs at `https://releases.stackql.io/stackql/<version>/stackql_windows_<architecture>.msi` (`amd64` and `arm64`), then run:

```powershell
.\publish-prep.ps1 0.12.824
```

The version can be given with or without the leading `v`. The script downloads both MSIs from version-specific proxy URLs and confirms that each `ProductVersion` matches the version given (nothing is installed). If either download or version check fails, package files remain unchanged. It then updates:

- `chocolatey\tools\chocolateyinstall.ps1` - AMD64 and ARM64 URLs and SHA256 checksums
- `chocolatey\stackql.nuspec` - `version` and `releaseNotes` are set for the release

Users run `choco install stackql` on either architecture. The install script detects the native platform even when PowerShell runs under emulation, then downloads the matching MSI with its SHA256 checksum. Unsupported architectures are rejected. Downloads stay pinned to the package version.

Run `publish-prep.ps1` for the first release containing both architectures before publishing the updated Chocolatey package; it fills the ARM64 URL and checksum.

### Step 4: publish to Chocolatey

Review the changes, then commit and push to `main`:

```powershell
git add chocolatey
git commit -m "v0.11.669"
git push origin main
```

The push triggers the [chocolatey-publish](.github/workflows/chocolatey-publish.yml) workflow, which:

1. reads the version from `chocolatey\stackql.nuspec`
2. checks whether that version already exists on chocolatey.org and stops if it does, so a push that does not bump the version is a no-op
3. runs `choco pack`, test installs the package on the runner, then pushes it to chocolatey.org using the `CHOCOLATEY_API_KEY` repository secret

The workflow can also be started by hand from the Actions tab.

## Smoke testing the published Chocolatey package

In GitHub Actions, select [chocolatey-smoke](.github/workflows/chocolatey-smoke.yml) and choose **Run workflow**. It installs the latest stable `stackql` package from the Chocolatey community feed on x64 (`windows-latest`) and ARM64 (`windows-11-arm`) runners. Each job requires a valid Authenticode signature on the installed `stackql.exe`, prints its signer and `stackql --version`, and checks that its Windows file version matches the CLI version (allowing a trailing `.0`). It then runs `SELECT 1 as test` and checks that the result is one row with `test = 1`.

Chocolatey's install helper verifies the configured MSI SHA256 checksum but does not enforce Authenticode signature validity. `release.ps1` checks both MSI and EXE signatures before upload unless `-AllowUnsigned` is passed; the smoke test checks the installed EXE signature explicitly.

## Building and testing the Chocolatey package locally

From an elevated PowerShell prompt:

```powershell
cd chocolatey
choco pack
choco install stackql -dv -s "'.;https://chocolatey.org/api/v2/'"
choco uninstall stackql
```

## Repository layout

| Path | Purpose |
| --- | --- |
| `build.ps1` | Step 1: builds and signs the MSI and ZIP |
| `release.ps1` | Step 2: uploads the MSI and ZIP assets and their `.sha256` sidecars to the GitHub release |
| `publish-prep.ps1` | Step 3: updates the Chocolatey package for a release |
| `stackql.wxs`, `en-us.wxl` | WiX source for the MSI |
| `inc\` | Files bundled into the MSI: EULA, icon, installer images, command shell launcher |
| `lib\` | Build tools: `rcedit` (version stamping) and `signtool` (Authenticode signing) |
| `chocolatey\` | Chocolatey package source: `stackql.nuspec` and `tools\` |
| `.github\workflows\chocolatey-publish.yml` | Publishes the Chocolatey package on push to `main` |
| `.github\workflows\chocolatey-smoke.yml` | Manually smoke tests the latest Chocolatey package on x64 and ARM64 |
| `downloaded\`, `bin\`, `msi\` | Gitignored build input and outputs |
