# Litebar

A macOS menu-bar manager being rewritten around a dependency-free Rust core and a bare AppKit interface.

**Work in progress.** [PR #1](https://github.com/vincenthopf/Litebar/pull/1) remains a draft. Native item movement is not passing end-to-end validation. Do not treat build success or the policy tests as proof of feature parity or a production-ready release.

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

The source guard requires Python 3.11 or newer. It rejects the legacy application and build system, Swift source outside the native adapter and test directories, unapproved native framework imports, and third-party Cargo dependencies.

GitHub Actions checks out original commit `11edd39115f3f43a83ae114b5348df6a0e1741cf` separately as `baseline/`. Its source is hash-checked before the characterization harness compiles and runs it. macOS differential tests compare the resulting 80 contract records with the Rust implementation. The baseline workflow also builds the original Release app. The baseline checkout is a test input, not a dependency of the replacement app.

The native workflow builds and tests on macOS 14, 15, and 26 on Apple Silicon and macOS 15 on Intel. Its live movement failures remain blocking failures. See [compatibility and validation limits](docs/COMPATIBILITY.md).

## License

Derived from Ice by Jordan Baird and contributors. The GPL-3.0 license and original attribution remain in [LICENSE](LICENSE) and [NOTICE](NOTICE). Original source and authorship remain in Git history.
