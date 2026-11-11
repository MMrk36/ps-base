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
