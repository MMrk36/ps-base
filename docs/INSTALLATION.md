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

A catalog resource may define preservePaths, a list of relative paths such as config/ and config.lua.

When updating an existing resource, those paths are copied from the current installation into the staged release before replacement. No automatic Lua merge is attempted.

## Backups and lockfile

Before replacing an existing resource, PS Base copies the previous resource directory to:

    <server-root>/.ps-base/backups/

Installed versions are recorded in:

    <server-root>/.ps-base/lock.json

The lockfile records resource version, release tag, checksum, repository, relative install path, installation time and backup location. It must never contain authentication tokens or server credentials.

The engine replaces one resource at a time. Multi-resource transaction orchestration, backup browsing and user-facing rollback commands are later milestones.
