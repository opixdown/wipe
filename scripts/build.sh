#!/bin/sh
# Builds every binary into site/dist/, where the installers download them from.
#   macOS:   universal (arm64 + x86_64), ad-hoc signed   — needs Swift (Xcode CLT)
#   Windows: amd64 + arm64, cross-compiled                — needs Go
set -e
cd "$(dirname "$0")/.."
out=site/dist
mkdir -p "$out"

echo "● macOS"
for arch in arm64 x86_64; do
  swift build --package-path macos -c release --triple "$arch-apple-macosx12.0"
done
lipo -create macos/.build/arm64-apple-macosx/release/wipe macos/.build/x86_64-apple-macosx/release/wipe -output "$out/wipe-macos"
codesign -f -s - "$out/wipe-macos"

echo "● Windows"
for arch in amd64 arm64; do
  (cd windows && GOOS=windows GOARCH=$arch go build -ldflags="-s -w" -o "../$out/wipe-windows-$arch.exe" .)
done

echo "✓ built $("$out/wipe-macos" -v) into $out/"
ls -lh "$out"
