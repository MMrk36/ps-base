# Pedro Scripts Base

PS Base is the installation and resource management tool for the Pedro Scripts ecosystem.

It is designed to install and manage independently maintained RedM resources. Each resource remains its own project, repository, release cycle and runtime resource. PS Base coordinates distribution; it does not replace ps-core or become a runtime dependency.

## Current status

PS Base is a Windows desktop installer with a PowerShell 7 GUI and CLI engine. Its small Windows x64 EXE is a GitHub bootstrapper: it checks for the latest published PS Base release, downloads the verified installer payload and portable PowerShell runtime when needed, then launches the GUI. The EXE does not embed the runtime or installer modules.

- Development workspace: Git submodules pinned by the PS Base repository.
- Distribution: a lightweight single-file Windows x64 bootstrapper; application files and portable PowerShell are downloaded from GitHub on first launch and reused.
- Installation target: a user-selected RedM server `resources` directory.
- Runtime: portable PowerShell 7 downloaded from its official GitHub release and verified against Microsoft's published SHA-256 checksum.

Resources are not installable through PS Base until an official release artifact and checksum have been published and added to the catalog.

## Repository layout

```text
ps-base/
├── .github/workflows/ Build, validation and catalog workflows
├── build/              Pinned desktop release toolchain
├── catalog/            Resource distribution catalog
├── docs/               Architecture and development documentation
├── scripts/            Development and validation scripts
├── src/PSBase/         PowerShell installer modules
├── cmd/psbase-bootstrap/ Lightweight Go GitHub downloader
├── tests/              PowerShell tests
├── ps-core/            Git submodule
├── ps-characters/      Git submodule
├── ps-database/        Git submodule
├── ps-inventory/       Git submodule
├── ps-notifications/   Git submodule
└── ps-permissions/     Git submodule
```

## Clone the development workspace

```powershell
git clone --recurse-submodules https://github.com/MMrk36/ps-base.git
cd ps-base
git submodule update --init --recursive
```

If the repository was cloned without submodules, run the second command from the repository root.

## Validate the workspace

Requires Git and PowerShell 7+.

```powershell
pwsh -File ./scripts/Test-Repository.ps1
```

## Start the desktop installer

For end users, download and run `PS-Base.exe` from a PS Base GitHub release. The bootstrapper downloads the latest installer payload and portable PowerShell runtime into the current user's Local AppData folder, verifies their SHA-256 checksums, and launches the GUI. No separate PowerShell installation is needed.

For contributors running from a source checkout, install PowerShell 7+ and run `Start-PSBase.cmd`. The interface selects a RedM server folder, browses resources and profiles, reviews dependency plans, installs and updates resources, and manages status, backups, restore, uninstall and interrupted transaction recovery.

For private resource repositories, provide a fine-grained GitHub token with read-only Contents access. The Windows interface stores it using current-user DPAPI; it is never written into the server directory or lockfile.

Maintainers can synchronize published releases with `pwsh -File ./PS-Base.ps1 sync-catalog`. The scheduled catalog workflow requires the `PSBASE_RELEASES_TOKEN` Actions secret with read-only access to all resource repositories.

## Installer workflow

PS Base resolves exact resource versions and dependencies from the catalog, downloads official HTTPS release artifacts, verifies SHA-256 checksums, inspects archives, and installs through a staged process. Fresh installs refuse to overwrite existing resource folders.

The CLI supports installation profiles, resource status, safe updates, journaled multi-resource update transactions, backup listing and restore, transaction recovery, and safe uninstall. File manifests protect local modifications, untracked files, local deletions and preserve-policy files. No automatic Lua merging is performed.

Updates are explicit. Database migrations never run automatically as a side effect of installing or updating resource files. See [docs/CLI.md](docs/CLI.md), [docs/INSTALLATION.md](docs/INSTALLATION.md), and [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for usage and metadata rules.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design principles, [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for contributor workflow, [docs/CLI.md](docs/CLI.md) for commands, and [docs/RELEASING.md](docs/RELEASING.md) for resource and desktop publishing.

## Security

- Never store GitHub tokens, server credentials or database credentials in the catalog or lockfile.
- Never execute scripts downloaded from a resource archive as part of installation.
- Verify artifact checksums before extraction.
- Reject archive entries that escape the selected installation directory.
- Do not delete unrelated server files.
- Never overwrite locally modified files automatically.
- Preserve untracked files, local deletions and catalog-marked preserve-policy files.
- Back up updates and retain resource, manifest and lockfile metadata for restore.
- Journal multi-resource update operations and provide interrupted-transaction recovery.
- The EXE downloads only published GitHub release assets, verifies their checksums, and extracts them under the current user's Local AppData directory.

## License

Licensing and redistribution terms must be documented before public installer releases. Each resource retains its own license and third-party attribution requirements. The downloaded PowerShell runtime retains its upstream license and notices.
