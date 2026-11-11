# PS Base CLI

The command-line interface targets PowerShell 7 or later. Running `Start-PSBase.cmd` opens the Windows desktop installer; the CLI remains available for automation and diagnostics.

Run commands from the repository directory:

```powershell
pwsh -File ./PS-Base.ps1 list
pwsh -File ./PS-Base.ps1 plan -Resource ps-core
pwsh -File ./PS-Base.ps1 plan -Resource ps-core -Version 1.0.0
```

## Commands

### List resources

`list` displays the resources known to the catalog, their development status, whether they can be installed, and the number of published versions.

### Resolve an installation plan

`plan` resolves the selected resource and its required dependencies in dependency-first order.

The resolver accepts exact dependency pins in the form `resource-id@1.2.3`. An unpinned dependency selects the highest published stable semantic version. Cycles and conflicting version requests stop resolution.

The plan command is read-only. It does not download, extract, install or modify server files.

### Update installed resources

```powershell
pwsh -File ./PS-Base.ps1 update -Resource ps-core -ServerPath "D:/RedM/server"
```

The update command resolves the selected resources and dependencies, downloads and verifies every artifact, and prints a file-level change plan before making changes. Updates run as a journaled transaction: PS Base records a backup before applying each resource, and if a later resource fails it restores earlier resources in reverse order. Interrupted transactions can be recovered explicitly. It requires an existing PS Base manifest; older/manual installations without a baseline are rejected rather than updated destructively. Local modifications, untracked files, local deletions and preserve-policy files are retained. A full resource backup is created before changes are applied.

Use `-WhatIf` to skip applying the prepared update. Database migrations and server.cfg changes are never performed.

### Inspect installed resources

```powershell
pwsh -File ./PS-Base.ps1 status -ServerPath "D:/RedM/server"
```

The status report compares installed files with the recorded release manifest and reports modified, missing and untracked files.

### Safely uninstall a resource

```powershell
pwsh -File ./PS-Base.ps1 uninstall -Resource ps-core -ServerPath "D:/RedM/server"
```

Uninstall creates a full backup and removes only unchanged files managed by PS Base. Locally modified, untracked and preserve-policy files are retained. If any files remain, the resource is marked as partially uninstalled rather than deleting user data.

### List backups and restore a resource

```powershell
pwsh -File ./PS-Base.ps1 backups -ServerPath "D:/RedM/server"
pwsh -File ./PS-Base.ps1 restore -BackupId "ps-core-update-20261111-120000-123-<guid>" -ServerPath "D:/RedM/server"
```

Backups created by PS Base include the resource files and the matching manifest/lockfile metadata. Restore creates a safety backup of the current resource before replacing it. Use the exact backup identifier from the listing; restore never accepts an arbitrary filesystem path.

### Inspect and recover update transactions

```powershell
pwsh -File ./PS-Base.ps1 transactions -ServerPath "D:/RedM/server"
pwsh -File ./PS-Base.ps1 recover -TransactionId "<transaction-id>" -ServerPath "D:/RedM/server"
```

Transaction journals are stored under `.ps-base/transactions/`. Recovery restores resources that were prepared or updated before an interrupted transaction. Completed and already rolled-back transactions cannot be recovered again.

### Use pinned installation profiles

```powershell
pwsh -File ./PS-Base.ps1 profiles
pwsh -File ./PS-Base.ps1 plan -Profile standard
pwsh -File ./PS-Base.ps1 install -Profile standard -ServerPath "D:/RedM/server" -ArtifactVersion 1491
pwsh -File ./PS-Base.ps1 update -Profile standard -ServerPath "D:/RedM/server" -ArtifactVersion 1491
```

Profiles are defined in the catalog and pin an exact version for every top-level resource. Dependencies are resolved dependency-first; a profile pin is also used when a dependency does not specify its own version. An explicit dependency version that conflicts with a profile pin is rejected. Profiles cannot be combined with `-Version`. Compatibility metadata is checked before installation or updates. If a release declares a minimum server artifact, supply `-ArtifactVersion` so PS Base can verify the target server.

### Desktop installer

On Windows, double-click `Start-PSBase.cmd` or run:

```powershell
pwsh -NoProfile -STA -File ./PS-Base-GUI.ps1
```

Running `PS-Base.ps1` without a command also launches the desktop interface. It provides resource selection, installation profiles, server-folder selection, compatibility input, plan/install/update actions, status, backups, restore, uninstall and transaction recovery. Long-running operations execute outside the UI thread; output and errors are shown in the activity log.

The interface currently uses the same tested CLI and PowerShell modules as automation. It does not implement a separate installer engine.

### Synchronize published releases

```powershell
pwsh -File ./PS-Base.ps1 sync-catalog
```

Catalog synchronization reads versioned GitHub Releases from each private resource repository, checks the tag against the release metadata, requires the ZIP/checksum/metadata assets, validates the SHA-256 sidecar and updates the catalog atomically. It never reads a moving branch or creates release versions.

### Private GitHub access

The six resource repositories are private. Create a fine-grained GitHub token with read-only Contents access to the PS Base repository and the resource repositories you need to install. Metadata read access is included by GitHub. In the desktop interface, paste it into the masked GitHub token field and choose **Save securely**. Windows DPAPI protects the token for the current Windows user under `%LOCALAPPDATA%\PedroScripts\PSBase`; it is not stored in the server directory, repository, lockfile or logs.

For automation, set `PSBASE_GITHUB_TOKEN` in the process environment. Environment credentials take precedence over the saved Windows credential. Do not put tokens in command-line arguments, scripts, catalog files or source control.

Maintainers who use the scheduled catalog-sync workflow must add a repository Actions secret named `PSBASE_RELEASES_TOKEN`. It needs read-only access to Contents in all six private resource repositories. The workflow only commits changes to `catalog/resources.json` in PS Base.

## Current limitation

The initial catalog intentionally contains no published releases. All current resources are development-only and cannot be installed. This is expected until each resource has a verified GitHub Release asset and SHA-256 checksum.

## Install a published resource

The install command requires an explicit server root:

    pwsh -File ./PS-Base.ps1 install -Resource ps-core -ServerPath "D:/RedM/server"

An alternate resources directory can be supplied with ResourcesPath. Use -WhatIf to preview the command without changing files.

The command downloads the exact catalog release, verifies its checksum, extracts into a temporary staging directory and installs dependencies before dependent resources. Existing configuration paths listed in the resource's preservePaths field are retained.

No resources in the initial catalog are installable yet. The command will reject them until verified release assets and checksums are published and registered.
