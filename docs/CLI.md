# PS Base CLI

The initial command-line interface targets PowerShell 7 or later.

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

The update command resolves the selected release and dependencies, downloads and verifies every artifact, and prints a file-level change plan before making changes. It requires an existing PS Base manifest; older/manual installations without a baseline are rejected rather than updated destructively. Local modifications, untracked files, local deletions and preserve-policy files are retained. A full resource backup is created before changes are applied.

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

### Interactive entry point

Running the script without a command opens the initial menu. The menu currently exposes catalog listing and the planning command guidance. A full interactive installation flow will be added after the release and installation engine is implemented.

## Current limitation

The initial catalog intentionally contains no published releases. All current resources are development-only and cannot be installed. This is expected until each resource has a verified GitHub Release asset and SHA-256 checksum.

## Install a published resource

The install command requires an explicit server root:

    pwsh -File ./PS-Base.ps1 install -Resource ps-core -ServerPath "D:/RedM/server"

An alternate resources directory can be supplied with ResourcesPath. Use -WhatIf to preview the command without changing files.

The command downloads the exact catalog release, verifies its checksum, extracts into a temporary staging directory and installs dependencies before dependent resources. Existing configuration paths listed in the resource's preservePaths field are retained.

No resources in the initial catalog are installable yet. The command will reject them until verified release assets and checksums are published and registered.
