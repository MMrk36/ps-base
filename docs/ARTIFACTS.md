# Release Artifacts

PS Base installs published release assets, not repository checkouts or source branch archives.

## Artifact requirements

A resource release asset must:

- Be a ZIP archive.
- Contain `fxmanifest.lua` at the archive root.
- Contain the distributable resource files, not a nested repository checkout.
- Be referenced by an HTTPS URL in the catalog.
- Have a SHA-256 checksum recorded in the catalog.

The installer verifies the checksum before inspecting or extracting an archive. A checksum mismatch stops the operation and removes the downloaded file.

## Archive extraction safeguards

The extractor validates every ZIP entry before writing any files. It rejects:

- Absolute paths and drive-qualified paths.
- Parent-directory traversal and dot path segments.
- Backslash paths and alternate data stream syntax.
- Duplicate paths.
- Symbolic links.
- Archives without a root-level `fxmanifest.lua`.
- Archives exceeding the configured entry-count or expanded-size limits.

Extraction is only allowed into a new or empty staging directory. The installer must not extract directly into the live server resource directory.

## Current scope

The artifact module currently supports HTTPS download, SHA-256 verification and safe extraction into staging. It does not yet install files into a server, preserve existing configuration, create backups or modify server configuration.


## PS Base desktop release

A PS Base desktop release publishes four assets:

- `PS-Base.exe`: a small Windows x64 bootstrapper.
- `PS-Base.exe.sha256`: checksum for the bootstrapper.
- `psbase-bootstrap.json`: versioned manifest naming the application archive, its SHA-256 checksum and the pinned portable PowerShell version.
- `psbase-app-v<version>.zip`: the PowerShell GUI, CLI, catalog and installer modules.

The bootstrapper checks published PS Base releases, including preview releases, verifies the application archive against the manifest, downloads the pinned portable PowerShell release and verifies it against the official `hashes.sha256` asset. It rejects unsafe ZIP paths and symbolic links before extraction. Application and runtime files are stored separately under the current user's Local AppData directory. The bootstrapper itself contains neither archive, keeping the downloadable EXE small.
