# Legacy removal

This cleanup is based on rewrite commit `0dcda2f5d6411e5c772a3af134bc4679de8080b8`.

## Removed from the rewrite tree

| Path | Removed content |
| --- | --- |
| `Ice/` | 152 files, including 116 Swift files with 18,156 lines, the SwiftUI/Combine app, updater, appearance code, icons, and localized resources |
| `Ice.xcodeproj/` | Five project/workspace files, including resolution for AXSwift, CompactSlider, Ifrit, LaunchAtLogin-Modern, and Sparkle |
| `Resources/` | Four old design and demo media files, totaling 16,353,402 bytes |
| `.swiftlint.yml`, `.github/workflows/lint.yml` | The original SwiftLint setup, which only checked `Ice/` and required source-header comments |
| `.github/workflows/development-toolchain.yml` | The temporary compiler-export workflow used during rewrite development |
| `.gitattributes`, `FREQUENT_ISSUES.md` | An obsolete RTF classification rule and troubleshooting advice for the old application |

The README now describes Litebar rather than advertising installation of the upstream Ice application. Issue templates now point at this fork. LICENSE, NOTICE, baseline fixtures, and all existing Rust and native tests are preserved.

## What remains in Swift

The production build still compiles seven new Swift files, totaling 2,005 lines at the cleanup base: `Controller.swift`, `EventDelivery.swift`, `Platform.swift`, `Settings.swift`, `Wireframe.swift`, `Benchmark.swift`, and `main.swift` under `native/`.

AppKit rendering and callbacks belong in the native adapter. Controller orchestration, event delivery, settings conversion, and inventory handling still contain non-UI logic. Deleting those files would remove working features. Any further move into Rust must preserve the existing native and characterization tests rather than leave empty adapters or remove test coverage.

Five Swift test files remain: two characterization harness files and three native validation files. They are not legacy application implementations. The real original implementations are loaded only from the pinned baseline checkout.

## Safety and validation

The replacement build script uses only `src/`, `native/`, LICENSE, and NOTICE, plus native tests when `LITEBAR_VALIDATION=1`. It does not use any of the deleted directories. The macOS baseline and differential workflows retain their separately pinned original checkout.

The source-validation workflow now checks that deleted legacy paths, old runtime dependencies, and Swift source outside the adapter/test boundaries do not return. Its regression tests cover those rejection rules.

This is repository cleanup, not a measured CPU or memory optimization. Native movement failures existed before this commit and are not fixed by removing unused source files. The PR remains a draft.
