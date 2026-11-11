# Pedro Scripts Base

PS Base is the installation and resource management tool for the Pedro Scripts ecosystem.

It is designed to install and manage independently maintained RedM resources. Each resource remains its own project, repository, release cycle and runtime resource. PS Base coordinates distribution; it does not replace ps-core or become a runtime dependency.

## Current status

The repository is a development workspace and Windows PowerShell 7 desktop installer. It includes a graphical interface, command-line operations, safe installation and update workflows, protected GitHub authentication, and release-catalog synchronization. Actual resource installation becomes available as soon as the resource repositories publish tagged preview/stable releases and the catalog sync completes.

- Development workspace: Git submodules pinned by the PS Base repository.
- Distribution: versioned release artifacts described by the resource catalog.
- Installation target: a user-selected RedM server `resources` directory.
- Initial platform: Windows with PowerShell 7 or later.

Resources are not installable through PS Base until an official release artifact and checksum have been published and added to the catalog.

## Repository layout

```text
ps-base/
├── catalog/          Resource distribution catalog
├── docs/             Architecture and development documentation
├── scripts/          Development and validation scripts
├── src/PSBase/       PowerShell installer modules
├── tests/            PowerShell tests
├── ps-core/          Git submodule
├── ps-characters/    Git submodule
├── ps-database/      Git submodule
├── ps-inventory/     Git submodule
├── ps-notifications/ Git submodule
└── ps-permissions/   Git submodule
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

## Installer workflow

PS Base resolves exact resource versions and dependencies from the catalog, downloads official HTTPS release artifacts, verifies SHA-256 checksums, inspects archives, and installs through a staged process. Fresh installs refuse to overwrite existing resource folders.

The CLI supports installation profiles, resource status, safe updates, journaled multi-resource update transactions, backup listing and restore, transaction recovery, and safe uninstall. File manifests protect local modifications, untracked files, local deletions and preserve-policy files. No automatic Lua merging is performed.

Updates are explicit. Database migrations never run automatically as a side effect of installing or updating resource files. See [docs/CLI.md](docs/CLI.md), [docs/INSTALLATION.md](docs/INSTALLATION.md), and [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for usage and metadata rules.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design principles and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for contributor workflow.

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

## License

Licensing and redistribution terms will be documented before public installer releases. Each resource retains its own license and third-party attribution requirements.
