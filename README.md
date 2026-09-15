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

## Loose-file cleanup (1.0.1)

The shared Windows/Mac manifest now supports these directives:

```text
mhdata.grf|mhdata.grf
DATA.INI|DATA.INI
#delete|data/luafiles514/lua files/skillinfoz/skillid.lub|mhdata.grf
#delete|data/luafiles514/lua files/skillinfoz/skillinfolist.lub|mhdata.grf
#delete|data/luafiles514/lua files/skillinfoz/skilldescript.lub|mhdata.grf
```

Keep only one download entry per destination and remove the obsolete loose-file
download entries. Do not include a backslash before `#delete`. The final field is
the replacement local path, which must also be a download in the same manifest.
Keep its current MD5 in checksums.txt. Cleanup removes loose files under the
selected client folder; it does not modify GRF contents. The replacement GRF must
contain the updated files, with the appropriate priority in DATA.INI.

All downloads must pass checksum verification before any deletion runs. Missing
targets are logged as already absent. Unsafe paths, symbolic links, directories,
duplicate destinations and download/delete conflicts are rejected. POSIX read-only
files can be unlinked when their parent permits it; Finder's Locked flag is cleared
only on validated deletion targets and restored if deletion fails. Other permission
failures stop the update. Files open in another process may still be unlinked on
macOS, so close the game before patching and restart it afterward.

Cleanup runs on every update. A failure never reports Update complete. The **Show
Log** button reveals the current diagnostic log in
`~/Library/Logs/ZenithCrownUpdater/`. Logs include the selected folder, manifest
fingerprint, directive count, and every deletion result. If a file is reported
absent but still appears elsewhere, verify the selected client folder and exact
path/case (some Mac disks are case-sensitive).

Run `swift test` on macOS. The existing GitHub Actions workflow now runs the tests
before building both architectures. Download and distribute the resulting 1.0.1
Mac app after CI passes. Existing Mac users must replace their app manually: this
change adds deletion support only and does not use Windows updater_version.txt or
add automatic app replacement.
