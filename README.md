# FSKit ZIP / 7z sample

This project is a macOS FSKit module that mounts ZIP and 7z archives as a **read-only** filesystem. Archive parsing, directory trees, and reads live in a signing-free Swift package so you can develop and test without a paid Apple Developer account. A live `mount` still needs a paid team.

## No Apple account: core, tests, CLI

The `ZipFSCore` package does not import FSKit and has no entitlements.

Run the checks (Command Line Tools is enough; this environment does not ship XCTest / Swift Testing):

```bash
swift run --package-path ZipFSCore ZipFSCoreCheck
```

Inspect a real archive with the same code path the volume uses:

```bash
swift run --package-path ZipFSCore zipfs ls /path/to/archive.zip
swift run --package-path ZipFSCore zipfs ls /path/to/archive.7z
swift run --package-path ZipFSCore zipfs stat /path/to/archive.zip path/in/zip
swift run --package-path ZipFSCore zipfs cat /path/to/archive.7z path/in/7z
swift run --package-path ZipFSCore zipfs read /path/to/archive.zip path/in/zip --offset 10 --length 32
```

Supported ZIP features: stored (method 0) and deflate (method 8). Zip64, encryption, and other compression methods are rejected.

Supported 7z features: read-only listing and extraction via [PLzmaSDK](https://github.com/OlehKulykov/PLzmaSDK) (vendored under `ZipFSCore/Vendor/PLzmaSDK` because the remote package uses unsafe C++ flags). Encrypted 7z archives are rejected. **Non-solid** archives extract only the requested file into memory. **Solid** archives spill the full tree under `FileManager.default.temporaryDirectory` (`ZipFS-7z-<uuid>/`) on first read so later files do not re-decompress the solid block; the temp tree is removed when the archive is closed or deallocated.

## Install vs enable (important)

ZipFSKitExp ships as a menu bar extra (no Dock icon or app window) with the FSKit module **embedded** inside it (`FSKitExp.app/Contents/Extensions/FSKitExpExtension.appex`). There is no separate extension installer. Launch the app once so it stays in the menu bar; it does not start at login.

| Step | Who does it | What happens |
|------|-------------|--------------|
| **Install** | DMG, drag-to-Applications, or Xcode Run | Copies `FSKitExp.app` to `/Applications` |
| **Register** | First app launch (automatic) | macOS discovers the embedded `.appex` |
| **Enable** | **You, in System Settings** | Toggle **FSKitExpExtension** under File System Extensions |

macOS **does not allow** an installer, pkg, or the app itself to enable the File System Extension silently. That toggle is intentional and per-user.

On first launch, click the ZipFS menu bar icon. The extra shows onboarding with **Open System Settings** and polls until the extension is enabled. After that, double-clicking a `.zip` / `.7z` (default handler) or using **Mount** in the extra works — as long as ZipFS is still running.

The archive mounts in a folder next to the archive (`Photos.zip` → `Photos/`, `Photos.7z` → `Photos/`). macOS blocks FSKit mounts in Desktop, Documents, and Downloads, so those archives mount under Application Support and a symlink with the archive name is placed next to the file.

If you rebuild from Xcode during development, the extension UUID may change and you may need to enable it again in System Settings.

## Paid Apple Developer Program: mount an archive

`com.apple.developer.fskit.fsmodule` is a restricted entitlement. You need a paid Apple Developer Program team (not a free Personal Team).

1. Xcode → Settings → Accounts → add that Apple Account.
2. Signing & Capabilities on **both** `FSKitExp` and `FSKitExpExtension`: set Team to that team. Bundle IDs are `app.the-alchemist.ZipFSKitExp` and `app.the-alchemist.ZipFSKitExp.FSKitExpExtension`.
3. Build and run the host app once so the extension registers and the menu bar extra appears.
4. Click the ZipFS icon, use onboarding (**Open System Settings**), or go to **System Settings → General → Login Items & Extensions → File System Extensions** and enable **FSKitExpExtension**.

Then mount an archive (macOS 26 path URLs):

```bash
mkdir /tmp/TestVol
mount -F -t MyFS /path/to/archive.zip /tmp/TestVol
# or
mount -F -t MyFS /path/to/archive.7z /tmp/TestVol
```

Unmount with:

```bash
umount /tmp/TestVol
```

Block-device fallback (attach the archive bytes as a raw disk image):

```bash
hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount archive.zip
mount -F -t MyFS diskN /tmp/TestVol
```

## Release build and DMG

To produce a Developer ID–signed Release app and DMG:

```bash
./scripts/release.sh
```

Outputs land in `build/release/`:

- `export/FSKitExp.app` — signed app ready to copy to `/Applications`
- `ZipFSKitExp.dmg` — drag-to-Applications disk image

Optional notarization (for distribution outside the Mac App Store):

1. Copy `scripts/notarize.env.example` to `scripts/notarize.env`
2. Fill in your Apple ID and app-specific password
3. Run `./scripts/release.sh` again — it submits to Apple, staples the ticket, then rebuilds the DMG

After installing from the DMG, open the app once (it appears in the menu bar), click the ZipFS icon, and complete the File System Extension enable step in System Settings. Leave it running if you want double-clicked `.zip` / `.7z` files to mount.

## Layout

- `ZipFSCore/` — ZIP + 7z readers, tree, read-only volume ops, `zipfs` CLI, `ZipFSCoreCheck`
- `ZipFSCore/Vendor/PLzmaSDK/` — vendored [PLzmaSDK](https://github.com/OlehKulykov/PLzmaSDK) (local path dependency; remote SPM rejects its unsafe C++ flags)
- `FSKitExpExtension/` — thin FSKit adapter (`MyFS` / `MyFSVolume`) over `ZipFSCore`
- `FSKitExp/` — menu bar host app with onboarding, mount UI, and `.zip` / `.7z` default handler
- `scripts/` — Release archive, optional notarization, and DMG packaging

FSKit is Apple's user-space filesystem framework (macOS 15.4+). `UnaryFileSystemExtension` is the entry point; it returns an `FSUnaryFileSystem`. The volume implements `FSVolume.Operations` (and related protocols) and delegates lookup, enumerate, and read to `ZipFSCore`.
