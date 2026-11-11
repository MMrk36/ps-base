# PS Base Architecture

## Purpose

PS Base is the distribution, installation and update manager for Pedro Scripts. It is not a runtime resource and must not be required for a RedM server to run installed resources.

Every Pedro Scripts resource remains independently versioned and deployable. PS Base consumes published release artifacts; it does not use a developer's working directory or a moving Git branch as a production installation source.

## Three separate concerns

### 1. Development workspace

The Git submodules provide a convenient workspace for developing the resource repositories together. The parent repository pins exact submodule commits.

Submodule commits are development references, not production release versions. Updating a submodule must be deliberate and committed in PS Base.

### 2. Distribution catalog

The catalog describes resources that PS Base knows about. It records repository identity, display metadata, installation status and published release information.

The catalog must not invent versions, checksums or compatibility claims. A resource is installable only when a published release artifact and its SHA-256 checksum are recorded.

### 3. Installer

The installer is responsible for:

1. Reading and validating the catalog.
2. Resolving requested resources and dependencies.
3. Checking compatibility constraints.
4. Downloading official release artifacts over HTTPS.
5. Verifying SHA-256 checksums.
6. Validating archive paths and expected resource structure.
7. Staging files outside the live resource directory.
8. Preserving user configuration.
9. Backing up files that will be replaced.
10. Installing and verifying the result.
11. Recording installed versions in a lockfile.

The installer must fail safely. If an operation fails after backup, it should restore the previous files where possible and report exactly what happened.

## Distribution contract

Production installs use immutable, versioned GitHub Release assets. They do not download from `main`, `master`, a branch archive or an unpinned commit.

Each published catalog release should contain:

- Semantic version.
- Git tag and source commit.
- Release asset name and HTTPS download URL.
- SHA-256 checksum.
- Supported PS Core API range, if applicable.
- Required dependencies and version constraints.
- Optional dependencies.
- Minimum RedM artifact requirement, when relevant.
- Database migration notice, when relevant.
- Release notes and license/attribution information.

A release artifact should contain the resource directory itself, including its `fxmanifest.lua`, runtime files, editable configuration and documentation intended for distribution. It must not contain repository metadata, development secrets or local test data.

## Installation target

The user selects a RedM server root. PS Base resolves the `resources` directory under that root, but should also support an explicitly selected resources directory for non-standard layouts.

The installer must not assume a fixed server path or overwrite the server's `server.cfg` without explicit user approval. It may offer a clearly previewed snippet for the user to add.

## Configuration preservation

Resource configuration is user-owned data. On installation and update:

- Preserve existing configuration files by default.
- Install new default configuration files when they do not exist.
- Do not attempt automatic, heuristic Lua configuration merging.
- Report when an upstream configuration template changes.
- Let the user review and apply configuration changes manually.

## Version and compatibility model

Each resource has its own version. PS Base must not force all resources to share one version number.

Profiles pin exact versions for reproducible installations. A compatibility matrix records combinations that have actually been tested. Dependency constraints and PS Core API compatibility are checked before installation.

The lockfile records the exact installed resource version, release tag, artifact checksum, install path and installation timestamp. It contains no credentials or secrets.

## Dependency ownership

A resource declares required and optional dependencies. Required dependencies are installed before the dependent resource. Missing, incompatible, circular or conflicting dependencies stop the plan before files are changed.

The installer presents the complete installation plan and asks for confirmation before performing changes.

## Updates, backups and rollback

Updates are explicit and may target one resource or a selected profile. Before replacing files, PS Base creates a backup outside the resource directory.

Rollback restores resource files from a selected backup. It does not automatically reverse database migrations. Database migrations are a separate operation requiring clear user authorization and a database backup plan.

## Security boundaries

- Treat catalog data and downloaded archives as untrusted input.
- Use HTTPS and verify SHA-256 before extraction.
- Reject absolute paths, parent traversal and unsafe archive entries.
- Extract only into a temporary staging directory.
- Do not invoke arbitrary commands or scripts from downloaded artifacts.
- Do not delete unrelated files or directories.
- Never print access tokens or credentials in logs.
- Store authentication outside the repository and lockfile. On Windows, saved GitHub credentials are protected with the current user's DPAPI; an environment variable can be used for automation.
- Require explicit confirmation for destructive or irreversible operations.

## Extensibility

The installer should be divided into small components with stable interfaces:

- Catalog: load and validate resource metadata.
- GitHub release provider: retrieve release metadata and assets.
- Dependency resolver: build a deterministic install plan.
- Downloader: retrieve artifacts.
- Integrity verifier: verify checksums and archive safety.
- Installer: stage, back up and apply files.
- Lockfile: track installed state.
- Backup and restore: recover previous resource files.
- Validator: inspect server paths and installed resources.
- CLI: expose commands without owning business logic.

Future UI, Linux support, alternative release providers and third-party resource sources should be added as separate implementations rather than rewriting the installation engine.

## Initial platform

The first implementation targets Windows and PowerShell 7+. Platform-specific filesystem operations should be isolated so Linux support can be added later.
