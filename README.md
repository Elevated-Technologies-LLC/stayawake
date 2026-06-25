# StayAwake

StayAwake is a small macOS menu bar app that keeps the display and system awake using `caffeinate`.

## Install

Install the latest release:

```bash
/bin/bash -c "$(curl -fsSL https://github.com/Elevated-Technologies-LLC/stayawake/releases/latest/download/install-stayawake.sh)"
```

When that command is run in a normal local Terminal session, it launches the graphical `Install StayAwake` app. The installer shows download progress, verifies the GitHub checksum, installs the app, sets up the menu bar launch agent, and walks the user through Screen Recording and Accessibility if macOS still needs them.

When the same command is run over SSH or in automation, it falls back to the direct non-interactive install flow and places the app in `/Applications/StayAwake.app`, registers a user LaunchAgent, and starts the app.

Force the direct automation path:

```bash
STAYAWAKE_INSTALL_MODE=direct /bin/bash -c "$(curl -fsSL https://github.com/Elevated-Technologies-LLC/stayawake/releases/latest/download/install-stayawake.sh)"
```

Uninstall and clean up the launch agent plus StayAwake privacy permission records:

```bash
STAYAWAKE_INSTALL_MODE=uninstall /bin/bash -c "$(curl -fsSL https://github.com/Elevated-Technologies-LLC/stayawake/releases/latest/download/install-stayawake.sh)"
```

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
- `Install-StayAwake-mac-arm64.zip`
- `Install-StayAwake.dmg`
- `stayawake-installer-manifest.json`

## Updates

The app checks this public GitHub release manifest at launch and every six hours:

```text
https://github.com/Elevated-Technologies-LLC/stayawake-updates/releases/latest/download/stayawake-manifest.json
```

StayAwake now follows the same GitHub update layout as ELVRDP:

- Source repo: `Elevated-Technologies-LLC/stayawake`
- Public update repo: `Elevated-Technologies-LLC/stayawake-updates`
- Internal installer mirror: `192.168.53.240:/data/applications/stayawake`

Release publishing uploads the same signed assets to both GitHub repos so older StayAwake builds that still check the source repo can bridge forward to the public updater feed. When a newer version is available, StayAwake downloads `StayAwake-mac-arm64.zip`, verifies its SHA-256 checksum from the manifest, replaces the installed app, and relaunches.
