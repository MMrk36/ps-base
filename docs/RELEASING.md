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

## Resource release assets

The workflow packages the resource with `fxmanifest.lua` at the ZIP root and excludes Git metadata, GitHub workflow files, test folders and the PS Base release metadata file. It publishes:

- `<resource-id>-v<version>.zip`
- `<resource-id>-v<version>.zip.sha256`
- `ps-base-release.json`

Preview metadata produces a GitHub prerelease. Stable metadata produces a non-prerelease release. A release is immutable from PS Base's perspective: publish a new version rather than replacing an existing version's contents.

## PS Base desktop release

The PS Base repository has a separate **Build PS Base Windows EXE** workflow. It runs for PS Base version tags matching `v*` and can also be run manually to build and smoke-test an artifact.

The workflow:

1. Checks out the PS Base installer source without initializing resource submodules.
2. Packages the GUI, CLI, catalog and installer modules into a versioned application ZIP.
3. Generates a bootstrap manifest containing the application ZIP checksum and pinned PowerShell version.
4. Builds a small Go Windows x64 bootstrapper with no embedded PowerShell runtime or installer payload.
5. Publishes `PS-Base.exe`, its checksum, the bootstrap manifest and the application ZIP as release assets.

The EXE checks GitHub Releases on launch, including preview releases, and downloads the matching application package only when that version is not already installed. It downloads the pinned portable PowerShell runtime only when missing and verifies it against the official PowerShell checksum asset. Both packages are stored under the current Windows user's Local AppData folder. The EXE itself does not require PowerShell or .NET to be installed.

Update `build/toolchain.json` deliberately when adopting a newer PowerShell runtime. Do not silently change the runtime used by an existing PS Base release.

Before publishing a public desktop release, confirm that PS Base's own licensing and all bundled third-party notices permit redistribution. The downloaded portable PowerShell runtime retains its upstream license and third-party notices.

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
