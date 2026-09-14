# Litebar

A macOS menu-bar manager being rewritten around a dependency-free Rust core and a bare AppKit interface.

**Work in progress.** The initial rewrite was merged in [PR #1](https://github.com/vincenthopf/Litebar/pull/1), but it is not production-ready. Native item movement is not passing end-to-end validation. Do not treat build success or the policy tests as proof of feature parity or a production-ready release.

## Source layout

`src/` contains the Rust state machine, geometry, item identity and restrictions, search, movement planning, recovery storage, and private macOS bridges. Cargo has no third-party dependencies.

`native/` contains seven new Swift files for AppKit windows and controls, settings, event delivery, application lifecycle, and platform integration. This is not a Swift-free implementation, and Swift is not limited to rendering the UI yet.

`tests/` contains Rust tests, native macOS tests, and the characterization harness for the original application. Native test code is excluded from the default application build.

The original `Ice/` application, Xcode project, Swift package resolution, appearance assets, media, and SwiftLint pipeline have been removed. [Legacy removal](docs/LEGACY_REMOVAL.md) records the scope and remaining Swift work. No original application source is copied into the replacement build.

## Build

Use macOS 14 or newer with Xcode Command Line Tools and the Rust toolchain pinned in `rust-toolchain.toml`.

```sh
rustup toolchain install 1.98.1 --profile minimal --component clippy,rustfmt
bash scripts/build-macos.sh
```

The build creates `dist/Litebar-arm64.app` or `dist/Litebar-x86_64.app` for the current machine. The Rust build is locked and offline. Apple frameworks are supplied by the macOS SDK. The app is ad-hoc signed, not notarized. A build refuses to overwrite an existing output. Set `LITEBAR_OUTPUT` to a new path for subsequent builds.

## Validate

```sh
python3 scripts/check_source.py
python3 -m unittest discover -s tests -p '*_test.py'
cargo test --all-targets --locked --offline
cargo clippy --all-targets --locked --offline -- -D warnings
```

For native runtime coverage, quit Ice and other Litebar processes first, then use a new output path:

```sh
LITEBAR_VALIDATION=1 LITEBAR_OUTPUT=.working/Litebar-validation.app bash scripts/build-macos.sh
uv run --python 3.13 python scripts/validate_native.py .working/Litebar-validation.app --output .working/native-results
```

The runner executes the UI suite and the full-input suite independently, with a 90-second deadline per suite. The full suite requires Accessibility access and never reports skipped movement as success. `--suite ui` is available for limited diagnostics only. The validation bundle has a separate identifier so tests do not share the production app's hosted menu-item identity. Reports and screenshots stay in the requested output directory.

The source guard requires Python 3.11 or newer. It rejects the legacy application and build system, Swift source outside the native adapter and test directories, unapproved native framework imports, and third-party Cargo dependencies.

GitHub Actions checks out original commit `11edd39115f3f43a83ae114b5348df6a0e1741cf` separately as `baseline/`. Its source is hash-checked before the characterization harness compiles and runs it. macOS differential tests compare the resulting 80 contract records with the Rust implementation. The baseline workflow also builds the original Release app. The baseline checkout is a test input, not a dependency of the replacement app.

The native workflow builds and tests on macOS 14, 15, and 26 on Apple Silicon and macOS 15 on Intel. Its live movement failures remain blocking failures. See [compatibility and validation limits](docs/COMPATIBILITY.md).

## License

Derived from Ice by Jordan Baird and contributors. The GPL-3.0 license and original attribution remain in [LICENSE](LICENSE) and [NOTICE](NOTICE). Original source and authorship remain in Git history.

## Ice feature parity

Compared with the [upstream feature list](https://github.com/jordanbaird/Ice#featuresroadmap) on 2026-09-14. Implemented code is not the same as verified runtime behavior.

| Ice capability | Litebar rewrite status |
| --- | --- |
| Hide and reveal items | Implemented. Real hosted fixture hide/show passed locally on macOS 26.3, with fixture-order instability across repeated runs. |
| Always-hidden section | Implemented in Rust policy and native controls. Needs live interaction coverage. |
| Hover, empty-space click, scroll, automatic rehide | Implemented. Policy tests pass. Native input paths need end-to-end coverage. |
| Hide overlapping application menus | Implemented. Needs fullscreen and multi-display validation. |
| Arrange and temporarily reveal individual items | Implemented, but live movement fails. Blocking. |
| Separate Ice Bar | A searchable text table, not Ice's icon bar. Not equivalent. |
| Item search | Rust matching and native table are implemented. Hosted identity lookup required a Tahoe fix. |
| Item spacing | System preference control exists. Intentionally does not restart other apps. Not validated locally. |
| Six shortcut actions | Implemented. Conflict and input-delivery coverage remains incomplete. |
| Launch at login | Implemented with ServiceManagement. Not enabled during tests. |
| Tint, shadow, border, custom menu-bar shapes | Removed. Not implemented in the rewrite. |
| Automatic updates | Not implemented. The app opens the releases page. |

Profiles, item groups, individual spacers, and conditional triggers are still unchecked in the upstream roadmap. They are not completed Ice features missing from Litebar.

## Completion criteria

1. Pass live movement, left/right click delivery, repeated launch and window-lifetime tests without skipping permission-dependent checks.
2. Verify temporary-item restoration after failure, cancellation, restart, and Space changes before using it on third-party items.
3. Cover notched and multiple displays, fullscreen, sleep/wake, and revoked permissions.
4. Measure CPU, physical memory, wakeups, and interaction latency against Ice under equivalent conditions. Repository size and Rust microbenchmarks do not establish application performance superiority.
5. Move remaining non-UI orchestration from Swift only behind regression coverage. AppKit in Swift is already native. Preserve the platform adapter unless measurements justify replacing it.
6. Decide whether the icon bar, appearance controls, and automatic updates are release requirements. The current rewrite does not have full Ice parity.
