# Installation Engine

The installation engine applies an already verified and extracted resource to a selected RedM server.

## Installation boundaries

- The server root and resources directory must already exist.
- The resources directory must be inside the selected server root.
- Resource IDs are used as directory names and must be safe.
- The staged resource must contain a root-level fxmanifest.lua.
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

The lockfile records resource version, release tag, checksum, repository, relative install path, installation time and backup location. It must never contain authentication tokens or server credentials.

The engine replaces one resource at a time. Multi-resource transaction orchestration, backup browsing and user-facing rollback commands are later milestones.
