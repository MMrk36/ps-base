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
- [ ] Register verified release artifacts for each resource.
- [ ] Test installation against a real RedM server directory.

## Resource management

- [x] Installed resource status and file integrity report.
- [x] Backup listing and restore with resource, manifest and lockfile metadata snapshots.
- [x] Individual resource update workflow with SHA-256 file baselines and local-change protection.
- [ ] Multi-resource operation recovery.
- [ ] Dependency and compatibility upgrade checks.
- [ ] Profile catalog with pinned resource versions.
- [x] Safe uninstall with backup, confirmation and preservation of local files.

## Distribution and platform expansion

- [ ] Release metadata refresh from GitHub.
- [ ] Private repository authentication.
- [ ] Linux support.
- [ ] Third-party resource sources.
- [ ] Optional graphical interface.

## Release readiness

- [ ] Security review of filesystem and archive handling.
- [ ] End-to-end installation and update tests.
- [ ] User documentation and troubleshooting guide.
- [ ] Versioned PS Base releases and changelog.
