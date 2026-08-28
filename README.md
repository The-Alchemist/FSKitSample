# FSKit ZIP sample

This project is a macOS FSKit module that mounts ZIP archives as a **read-only** filesystem. ZIP parsing, directory trees, and reads live in a signing-free Swift package so you can develop and test without a paid Apple Developer account. A live `mount` still needs a paid team.

## No Apple account: core, tests, CLI

The `ZipFSCore` package does not import FSKit and has no entitlements.

Run the checks (Command Line Tools is enough; this environment does not ship XCTest / Swift Testing):

```bash
swift run --package-path ZipFSCore ZipFSCoreCheck
```

Inspect a real archive with the same code path the volume uses:

```bash
swift run --package-path ZipFSCore zipfs ls /path/to/archive.zip
swift run --package-path ZipFSCore zipfs stat /path/to/archive.zip path/in/zip
swift run --package-path ZipFSCore zipfs cat /path/to/archive.zip path/in/zip
swift run --package-path ZipFSCore zipfs read /path/to/archive.zip path/in/zip --offset 10 --length 32
```

Supported ZIP features: stored (method 0) and deflate (method 8). Zip64, encryption, and other compression methods are rejected.

## Install vs enable (important)

ZipFSKitExp ships as a normal macOS app with the FSKit module **embedded** inside it (`FSKitExp.app/Contents/Extensions/FSKitExpExtension.appex`). There is no separate extension installer.

| Step | Who does it | What happens |
|------|-------------|--------------|
| **Install** | DMG, drag-to-Applications, or Xcode Run | Copies `FSKitExp.app` to `/Applications` |
| **Register** | First app launch (automatic) | macOS discovers the embedded `.appex` |
| **Enable** | **You, in System Settings** | Toggle **FSKitExpExtension** under File System Extensions |

macOS **does not allow** an installer, pkg, or the app itself to enable the File System Extension silently. That toggle is intentional and per-user.

On first launch, the app shows an onboarding screen with **Open System Settings** and polls until the extension is enabled. After that, double-clicking a `.zip` (default handler) or using **Mount** in the app works.

If you rebuild from Xcode during development, the extension UUID may change and you may need to enable it again in System Settings.

## Paid Apple Developer Program: mount a zip

`com.apple.developer.fskit.fsmodule` is a restricted entitlement. You need a paid Apple Developer Program team (not a free Personal Team).

1. Xcode → Settings → Accounts → add that Apple Account.
2. Signing & Capabilities on **both** `FSKitExp` and `FSKitExpExtension`: set Team to that team. Bundle IDs are `app.the-alchemist.ZipFSKitExp` and `app.the-alchemist.ZipFSKitExp.FSKitExpExtension`.
3. Build and run the host app once so the extension registers.
4. Use the in-app onboarding (**Open System Settings**) or go to **System Settings → General → Login Items & Extensions → File System Extensions** and enable **FSKitExpExtension**.

Then mount a zip (macOS 26 path URLs):

```bash
mkdir /tmp/TestVol
mount -F -t MyFS /path/to/archive.zip /tmp/TestVol
```

Unmount with:

```bash
umount /tmp/TestVol
```

Block-device fallback (attach the zip bytes as a raw disk image):

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

After installing from the DMG, open the app once and complete the File System Extension enable step in System Settings.

## Layout

- `ZipFSCore/` — ZIP reader, tree, read-only volume ops, `zipfs` CLI, `ZipFSCoreCheck`
- `FSKitExpExtension/` — thin FSKit adapter (`MyFS` / `MyFSVolume`) over `ZipFSCore`
- `FSKitExp/` — host app with onboarding, mount UI, and `.zip` default handler
- `scripts/` — Release archive, optional notarization, and DMG packaging

FSKit is Apple's user-space filesystem framework (macOS 15.4+). `UnaryFileSystemExtension` is the entry point; it returns an `FSUnaryFileSystem`. The volume implements `FSVolume.Operations` (and related protocols) and delegates lookup, enumerate, and read to `ZipFSCore`.
