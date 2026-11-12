# Installation Engine

## Getting started on Windows

### Single-file release

1. Download `PS-Base.exe` from the official PS Base GitHub release.
2. Run the EXE. No separate PowerShell installation is required.
3. On first launch, the small bootstrapper checks GitHub, downloads the latest installer payload and portable PowerShell runtime, verifies both downloads, and stores them under the current Windows user's Local AppData directory. Later launches reuse the installed copy and download only when a new release or runtime version is required.
4. Select the RedM server root containing `server.cfg` and `resources`.
5. Add a GitHub fine-grained token with read-only Contents access to the private PS Base and resource repositories. Save it in the interface; Windows DPAPI protects it for the current user.
6. Check only the resources you want to install. PS Base automatically adds required dependencies, shows them separately in the plan, and installs dependencies before the resources that need them.

The EXE is a lightweight Windows x64 bootstrapper. It contains no PowerShell runtime or installer payload. Each application release is stored in its own versioned directory so an update does not overwrite files used by an already running version. The saved GitHub token remains in the shared current-user credential location and is not bundled into the EXE.

### Development workspace

For contributors running from a cloned source workspace:

1. Install PowerShell 7 or later.
2. Clone/download the PS Base workspace with its submodules.
3. Run `Start-PSBase.cmd`.
4. Follow the server selection and GitHub token steps above.

The catalog initially contains no published releases. The resource release-pipeline pull requests must be merged and preview tags published before any resource can be installed. Use **Sync catalog** in the interface after releases are published.

The installation engine applies an already verified and extracted resource to a selected RedM server.

## Installation boundaries

- The server root and resources directory must already exist.
- The resources directory must be inside the selected server root.
- Resource IDs are used as directory names and must be safe.
- The staged resource must contain a root-level fxmanifest.lua.
- A fresh install refuses to overwrite an existing resource directory. Use the update command for resources installed by PS Base; move or back up manually installed resources before installing them through PS Base.
- The installer does not modify server.cfg.
- The installer does not run SQL migrations or execute resource scripts.

## Configuration preservation

A catalog resource may define `filePolicies`:

- `managed`: an unchanged file can be updated; a locally modified file is always protected.
- `preserve`: never replace or delete automatically, even when unchanged.
- `replace`: update an unchanged file; a locally modified file still requires a future explicit conflict-resolution action.

Rules use relative path patterns and override the default policy. The legacy `preservePaths` list is treated as a preserve policy.

Each installation records a SHA-256 baseline for every release file in `.ps-base/manifests/<resource>.json`. Updates compare the previous release baseline, the current file and the new release. Untracked files and local deletions are preserved. A file removed upstream is deleted only when it still matches its previous baseline and is not protected by policy. No automatic Lua merge is attempted.

Updates are available through:

```powershell
pwsh -File ./PS-Base.ps1 update -Resource ps-core -ServerPath "D:/RedM/server"
```

The command displays a file-level plan before applying it. It downloads and verifies the selected release, creates a full resource backup, applies only safe changes, and records the new baseline and installed version. If an operation fails, it attempts to restore the prior resource, manifest and lockfile. Keep backups until the update has been verified in a running server.

## Backups and lockfile

Before replacing an existing resource, PS Base copies the previous resource directory to:

    <server-root>/.ps-base/backups/

Installed versions are recorded in:

    <server-root>/.ps-base/lock.json

The lockfile records resource version, release tag, checksum, repository, relative install path, installation time and backup location. It must never contain authentication tokens or server credentials. PS Base-managed backups also store a sidecar metadata snapshot under `.ps-base/backup-metadata/`, allowing the restore command to recover the matching resource files, file manifest and lockfile entry.

Use `pwsh -File ./PS-Base.ps1 backups -ServerPath <server>` to list restorable backups and `pwsh -File ./PS-Base.ps1 restore -BackupId <id> -ServerPath <server>` to restore one. Restore first creates a safety backup of the current resource. Multi-resource updates are journaled under `.ps-base/transactions/`. If an update fails partway through, PS Base restores previously updated resources in reverse order. If the process is interrupted, use the `transactions` and `recover` commands to inspect and roll back the incomplete operation. Declared PS Core API compatibility and minimum server artifact requirements are checked before updates. Compatibility metadata is only as reliable as the resource maintainer's published declarations.

## Private release access

Private GitHub release assets are downloaded through the GitHub Releases API. The token is attached only to requests sent to `api.github.com`; signed asset redirects are followed without forwarding the credential to the asset host. SHA-256 is verified before extraction.

The desktop interface stores the token as a DPAPI-protected value under the current Windows user's Local AppData. The lockfile, catalog, backups and selected server directory never receive the token. For unattended automation, use the `PSBASE_GITHUB_TOKEN` environment variable and keep it in the automation platform's secret store.

## Release and catalog publishing

Each resource repository has a tag-triggered workflow. A release tag must exactly match both `fxmanifest.lua` and `.ps-base-release.json`. The workflow publishes:

- A ZIP with `fxmanifest.lua` at its root.
- A SHA-256 sidecar for that ZIP.
- A `ps-base-release.json` metadata asset.

The PS Base catalog-sync workflow reads these release assets using the `PSBASE_RELEASES_TOKEN` Actions secret, validates metadata and checksums, and commits the updated catalog. It never creates tags or publishes resource releases by itself.
