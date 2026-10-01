# Vendored PLzmaSDK

Copy of [PLzmaSDK 1.6.2](https://github.com/OlehKulykov/PLzmaSDK/releases/tag/1.6.2).

SwiftPM refuses remote packages that set `unsafeFlags` on C/C++ targets. ZipFSCore therefore depends on this local tree via `.package(path: "Vendor/PLzmaSDK")`.
