# Publishing Pedro Scripts releases

Each resource remains independently versioned and released from its own repository. PS Base consumes immutable GitHub Release assets only.

## Resource maintainer workflow

1. Review and merge the resource repository's **Add PS Base release publishing pipeline** pull request.
2. Test the resource on a disposable RedM server, including its framework/provider adapter and dependencies.
3. Update `fxmanifest.lua` and `.ps-base-release.json` to the same semantic version.
4. Set metadata status to `preview` for a test release or `stable` only after the compatibility and runtime tests are complete.
5. Commit and push the version change to `main`.
6. Create and push the matching tag, for example `v0.1.0`.

The tag, fxmanifest version and metadata version must match exactly. The release workflow rejects mismatches and unsupported statuses.

## Release assets

The workflow packages the resource with `fxmanifest.lua` at the ZIP root and excludes Git metadata, GitHub workflow files, test folders and the PS Base release metadata file. It publishes:

- `<resource-id>-v<version>.zip`
- `<resource-id>-v<version>.zip.sha256`
- `ps-base-release.json`

Preview metadata produces a GitHub prerelease. Stable metadata produces a non-prerelease release. A release is immutable from PS Base's perspective: publish a new version rather than replacing an existing version's contents.

## Catalog synchronization

The PS Base repository's **Sync resource catalog** workflow runs weekly and can also be started manually. Configure the repository Actions secret:

- Name: `PSBASE_RELEASES_TOKEN`
- Type: fine-grained GitHub token
- Repository access: all six private resource repositories
- Permission: Contents — read-only

The workflow reads release metadata and checksum sidecars, validates their names, versions, status and SHA-256 format, then atomically updates `catalog/resources.json`. The installer independently verifies the downloaded ZIP against the recorded SHA-256 before extraction.

For a local/manual sync, save a read-only token in the PS Base desktop interface and run:

```powershell
pwsh -File ./PS-Base.ps1 sync-catalog
```

## Current preview status

The initial resource metadata is intentionally marked `preview`. The source READMEs still document RedM runtime behavior that has not been verified in a live server. Do not mark a resource stable until its provider integrations, migration behavior, restart handling and exports have been tested on a disposable server.

A release artifact being installable does not mean it is production-certified. PS Base reports the declared channel and compatibility metadata; server-side testing remains the maintainer's responsibility.
