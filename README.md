# Zenith Crown Online Updater for macOS

A minimal SwiftUI updater compatible with the existing Windows updater protocol.

## Server files

The updater reads:

- `https://zenithcrown.net/files/manifest.txt`
- `https://zenithcrown.net/files/checksums.txt`
- Update files from `https://zenithcrown.net/files/`

Manifest format:

```text
SystemEN/LuaFiles514/itemInfo.lua|itemInfo.lua
zenith.grf|zenith.grf
DATA.INI|DATA.INI
```

Checksum format:

```text
md5hash  itemInfo.lua
md5hash  zenith.grf
md5hash  DATA.INI
```

## Build with GitHub Actions

1. Create a GitHub repository.
2. Upload this entire project, including `.github/workflows/build-macos.yml`.
3. Push to the `main` branch or run **Build macOS Updater** manually under Actions.
4. Download the generated artifact.

The workflow builds one universal application for Intel and Apple Silicon Macs.

## Gatekeeper

The workflow applies an ad-hoc signature. Without an Apple Developer certificate and notarization, users may need to right-click the app and choose **Open** the first time.

## Behavior

- The user selects the Ragnarok client folder.
- The updater downloads the manifest and checksums.
- Existing files are checked with MD5.
- Missing or changed files are downloaded and verified.
- Manifest paths are protected against writing outside the selected client folder.
- The updater opens the client folder when finished; it does not directly execute `ragexe.exe` because Windows executables require Wine, CrossOver, or another compatibility environment on macOS.
