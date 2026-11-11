# PS Base Roadmap

This roadmap tracks implementation status. A feature is marked complete only when its implementation and automated checks are present.

## Foundation

- [x] Repository architecture and development workflow.
- [x] Resource catalog and JSON Schema.
- [x] Catalog validation and unique resource ID checks.
- [x] Dependency-first installation planning.
- [x] Exact dependency version pins.
- [x] Dependency cycle detection.
- [x] Windows PowerShell 7 CLI foundation.

## Distribution and installation

- [x] HTTPS artifact download.
- [x] SHA-256 verification.
- [x] ZIP path and symbolic-link safety checks.
- [x] Archive entry-count and expanded-size limits.
- [x] Root fxmanifest validation.
- [x] Staged installation.
- [x] Explicit configuration preservation paths.
- [x] Per-resource backup before replacement.
- [x] Installed resource lockfile.
- [ ] Publish and register the first verified preview release artifacts for each resource.
- [ ] Test installation against a real RedM server directory.

## Resource management

- [x] Installed resource status and file integrity report.
- [x] Backup listing and restore with resource, manifest and lockfile metadata snapshots.
- [x] Individual resource update workflow with SHA-256 file baselines and local-change protection.
- [x] Journaled multi-resource update transactions with reverse-order rollback and interrupted-operation recovery.
- [x] PS Core API range and minimum server artifact compatibility checks, including installed dependents during core upgrades.
- [x] Profile catalog with exact resource-version pins and dependency-aware resolution.
- [x] Safe uninstall with backup, confirmation and preservation of local files.

## Distribution and platform expansion

- [x] Authenticated release metadata refresh from private GitHub repositories with checksum sidecar validation.
- [x] Private GitHub release downloads with current-user DPAPI credential storage and environment-token support.
- [ ] Linux support.
- [ ] Third-party resource sources.
- [x] Windows desktop interface for catalog browsing, planning, install/update, status, backups, restore, uninstall and recovery.

## Release readiness

- [ ] Security review of filesystem and archive handling.
- [ ] End-to-end installation and update tests.
- [x] User documentation for installation, authentication, catalog synchronization and resource release publishing.
- [ ] Versioned PS Base releases and changelog.
