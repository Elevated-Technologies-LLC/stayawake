# StayAwake

StayAwake is a small macOS menu bar app that keeps the display and system awake using `caffeinate`.

## Install

Install the latest release:

```bash
/bin/bash -c "$(curl -fsSL https://github.com/Elevated-Technologies-LLC/stayawake/releases/latest/download/install-stayawake.sh)"
```

By default the installer places the app in `~/Applications/StayAwake.app`, registers a user LaunchAgent, and starts the app.

## Build

```bash
./scripts/build.sh
```

When the Elevated Technologies Developer ID certificate is installed, the build signs `StayAwake.app` with:

```text
Developer ID Application: Elevated Technologies LLC (8HBASZNPZ4)
```

StayAwake is for internal company-owned Macs. Release builds are Developer ID signed, and notarization is intentionally skipped unless Michael explicitly requests it for a specific release.

## Package

```bash
./scripts/package.sh
```

Package output goes to `dist/`:

- `StayAwake-mac-arm64.zip`
- `StayAwake-mac-arm64.pkg`
- `stayawake-manifest.json`
- `install-stayawake.sh`

## Updates

The app checks this public GitHub release manifest at launch and every six hours:

```text
https://github.com/Elevated-Technologies-LLC/stayawake/releases/latest/download/stayawake-manifest.json
```

When a newer version is available, StayAwake downloads `StayAwake-mac-arm64.zip`, verifies its SHA-256 checksum from the manifest, replaces the installed app, and relaunches.
