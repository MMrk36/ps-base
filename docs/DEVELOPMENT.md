# Development Workflow

## Requirements

- Git.
- PowerShell 7 or later for repository scripts and the planned installer.
- Network access to the public Pedro Scripts GitHub repositories.

## Clone

```powershell
git clone --recurse-submodules https://github.com/MMrk36/ps-base.git
cd ps-base
```

For an existing clone:

```powershell
git submodule update --init --recursive
```

## Submodule policy

The parent PS Base repository records exact commits for every submodule. This is intentional: a checkout of PS Base must reproduce the same development workspace.

To update one resource deliberately:

```powershell
git -C ./ps-core fetch --tags
git -C ./ps-core checkout <tag-or-commit>
git add ./ps-core
git commit -m "Update ps-core submodule"
```

Replace the placeholder with a real tag or commit. Do not automatically move all submodules to their latest branch commits.

Check submodule state:

```powershell
git submodule status --recursive
git status --short
```

A leading `-` in submodule status means it is not initialized. A leading `+` means its checked-out commit differs from the commit recorded by the parent repository. A leading `U` indicates a merge conflict.

## Validation

Run the repository validation script before committing:

```powershell
pwsh -File ./scripts/Test-Repository.ps1
```

The script checks catalog structure, duplicate resource IDs and submodule path consistency. It does not claim that a resource release is installable or that a server installation has been tested.

## Branch and commit conventions

Use short feature branches, for example:

- `feat/catalog-schema`
- `feat/release-downloader`
- `feat/install-command`
- `fix/archive-path-validation`

Keep commits focused and use descriptive messages. Do not commit generated archives, credentials, local server data, test databases or temporary download files.

## Adding a resource

1. Add its repository as a Git submodule if it belongs in the development workspace.
2. Add a catalog entry with a unique stable ID.
3. Keep it marked as not installable until a real release artifact and checksum exist.
4. Declare dependencies and compatibility only when supported by the resource's actual release metadata and tests.
5. Add or update tests for catalog validation and dependency resolution.

## Release discipline

Resource releases are independent. Publish and test a resource release in its own repository first. Then update the PS Base catalog to reference that exact release asset and checksum.

Do not point production installs at a branch or a submodule working tree.
