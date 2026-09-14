set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
  printf '%s\n' 'This build requires macOS and Xcode Command Line Tools.' >&2
  exit 1
fi
arch=$(uname -m)
case "$arch" in
  arm64) target=aarch64-apple-darwin ;;
  x86_64) target=x86_64-apple-darwin ;;
  *) printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 1 ;;
esac
out=${LITEBAR_OUTPUT:-"dist/Litebar-$arch.app"}
if [ -e "$out" ]; then
  printf 'Output already exists: %s. Set LITEBAR_OUTPUT to a new path.\n' "$out" >&2
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo build --release --lib --locked --offline --target "$target"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
sources=(native/Platform.swift native/Settings.swift native/EventDelivery.swift native/Wireframe.swift native/Controller.swift native/Benchmark.swift native/main.swift)
flags=(-swift-version 5)
if [ "${LITEBAR_VALIDATION:-0}" = 1 ]; then
  sources+=(tests/native/Validation.swift tests/native/Runtime.swift)
  flags+=(-D LITEBAR_VALIDATION)
fi
xcrun swiftc "${flags[@]}" -O -whole-module-optimization -target "$arch-apple-macosx14.0" \
  -import-objc-header native/LitebarCore.h \
  "${sources[@]}" \
  "target/$target/release/liblitebar_core.a" \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation -framework Foundation \
  -framework Carbon -framework ScreenCaptureKit -framework ServiceManagement -framework Security -liconv \
  -Xlinker -dead_strip -o "$out/Contents/MacOS/Litebar"
cp native/Info.plist "$out/Contents/Info.plist"
cp LICENSE "$out/Contents/Resources/LICENSE"
if [ -f NOTICE ]; then cp NOTICE "$out/Contents/Resources/NOTICE"; fi
plutil -lint "$out/Contents/Info.plist"
codesign --sign - "$out"
codesign --verify --strict "$out"
printf '%s\n' "$out"
