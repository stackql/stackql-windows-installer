# Project guidance

This is the shared guidance for all coding assistants working in this repository. Maintain project rules here; keep tool-specific entry points short.

## Working conventions

- Keep prose succinct and matter of fact. Use a plain hyphen instead of an em dash.
- Keep code comments terse and only add them where needed.
- Change only the files and functions needed for the task. Avoid unrelated changes.
- Do not rely on inference for coding tasks. Research the relevant code and documentation, verify behavior, and test all code changes. Prefer correctness over speed.

## Project context

This repository builds and publishes the StackQL Windows MSI, ZIP containing `stackql.exe`, and Chocolatey package. The MSI also installs the StackQL Workbench desktop app beside `stackql.exe`. See the [repository layout](README.md#repository-layout) for the source files and their roles.

- Follow the [prerequisites](README.md#prerequisites), including the build environment notes. The scripts target Windows with PowerShell 5.1 or later and WiX v4 or later.
- Run the root PowerShell scripts from the repository root.
- `downloaded/`, `bin/`, and `msi/` contain ignored build inputs and outputs. Keep generated packages out of source control. `build.ps1` clears the contents of `bin/` and `msi/`.
- `build.ps1` takes the StackQL release, the StackQL Workbench release and an optional `true` to sign. On every run it downloads into `downloaded/` the unsigned `stackql_windows_<architecture>` artifacts from the `stackql/stackql` `Build` run for that release, and the StackQL Workbench executables and their `.sha256` files from the given `stackql/stackql-workbench` release. Preserve its release, run, tag commit, digest, checksum, processor architecture and version checks.
- StackQL Workbench carries its own version and icon. Do not stamp it with `rcedit`, keep it out of the ZIPs, and keep the `release.ps1` version checks on `stackql.exe`.
- The MSI adds nothing for WebView2 and creates no data folder. The Workbench checks for WebView2 itself, writes nothing to the install folder, and keeps its state per user, with providers in `%USERPROFILE%\.stackql`. Keep `cd $HOME` in the command shell launcher so the `stackql` command uses the same folder.

## Build and release

Follow the [release flow](README.md#release-flow) for commands, signing token requirements, and publishing details.

- GitHub draft releases are not used. Package UAT gates moving the Cloudflare releases proxy semver pointer to the next release; uploading assets does not move that pointer.
- All published release/download links and script download URLs must use `releases.stackql.io`. The exceptions are the build inputs, which `build.ps1` downloads from GitHub: the StackQL build artifacts and StackQL Workbench.
- Preserve the version and signature checks and the skip-existing-assets behavior in `release.ps1`. Unsigned uploads require its explicit `-AllowUnsigned` option.
- Use `publish-prep.ps1` to update the Chocolatey version, release notes, and SHA256 checksum after the releases proxy serves the matching MSI. Preserve its version check.
- A push to `main` triggers the [Chocolatey publishing workflow](.github/workflows/chocolatey-publish.yml), which publishes when the package version is not already on Chocolatey.

## Validation

- For build changes, verify the affected behavior using the [build instructions](README.md#step-1-build-and-sign-the-msi-and-zip). An unsigned local build uses `.\build.ps1 <stackql release> <workbench release>`, for example `.\build.ps1 v1.1.959 v0.1.0`.
- For Chocolatey changes, follow the [local package testing instructions](README.md#building-and-testing-the-chocolatey-package-locally) in a test environment.
- Report what was checked and any checks that could not run. Do not claim unperformed validation.
- Documentation-only changes do not need build or package tests unless documentation checks are added. Verify file paths, links, and the diff. There are currently no documentation checks in this repository.
