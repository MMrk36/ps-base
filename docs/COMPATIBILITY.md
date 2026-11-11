# Release compatibility metadata

PS Base uses release metadata to reject updates that would leave installed resources incompatible with PS Core or the target RedM server artifact.

## PS Core API

The PS Core release publishes its API version:

```json
{
  "apiVersion": "1.4.0"
}
```

A resource that depends on that API declares a supported range:

```json
{
  "psCoreApi": {
    "minVersion": "1.2.0",
    "maxVersion": "2.0.0"
  }
}
```

- `minVersion` is inclusive.
- `maxVersion` is exclusive.
- At least one boundary is required.
- Versions use numeric major/minor/patch components. Prerelease/build suffixes are ignored for range comparison.

When a PS Core upgrade is planned, PS Base checks installed resources that are not part of the update plan as well as resources being installed or updated. It reads compatibility metadata from the installed lockfile first, then from the catalog release matching the installed version. If metadata is unavailable, it reports a warning rather than claiming compatibility.

## Server artifact

A resource may declare a minimum RedM server artifact:

```json
{
  "minimumArtifact": "1491"
}
```

PS Base does not guess the server's artifact version. Supply it explicitly:

```powershell
pwsh -File ./PS-Base.ps1 plan -Resource ps-example -ArtifactVersion 1491
pwsh -File ./PS-Base.ps1 install -Resource ps-example -ServerPath "D:/RedM/server" -ArtifactVersion 1491
```

If a selected release declares `minimumArtifact` and no artifact version is supplied, installation/update planning stops with an actionable error.

Compatibility checks are metadata-based. They do not execute resource code, run SQL migrations, or guarantee compatibility beyond the declared constraints.
