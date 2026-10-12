#!/usr/bin/env bash
# Builds build/Eyelid.app without an Xcode project: SwiftPM for the app, CMake for mediaremote-adapter.
#
# Usage: scripts/build-app.sh [debug|release]   (default: release)
#
# Environment:
#   VERSION=1.2.3   Version to stamp into the app. Defaults to the latest vX.Y.Z tag, or 0.0.0.
#   UNIVERSAL=1     Build for both arm64 and x86_64 instead of the current architecture only.
#   CODESIGN_IDENTITY=…  Signing identity. Defaults to the first Apple Development certificate in the
#                   keychain, or ad hoc without one; "-" forces ad hoc. A real identity makes macOS keep
#                   the Accessibility permission across rebuilds, since it no longer ties it to one build.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER_SRC="$ROOT/Vendor/mediaremote-adapter"
ADAPTER_BUILD="$ROOT/.build/adapter"
APP="$ROOT/build/Eyelid.app"

cd "$ROOT"

if [[ ! -f "$ADAPTER_SRC/CMakeLists.txt" ]]; then
  echo "==> Fetching submodules"
  git submodule update --init --recursive
fi

command -v cmake >/dev/null || { echo "error: cmake not found, install it with 'brew install cmake'" >&2; exit 1; }

# Without an explicit target, CMake builds for the macOS it runs on, and older systems can't load the framework.
DEPLOYMENT_TARGET="$(plutil -extract LSMinimumSystemVersion raw "$ROOT/Resources/Info.plist")"

echo "==> Building mediaremote-adapter"
cmake -S "$ADAPTER_SRC" -B "$ADAPTER_BUILD" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" >/dev/null
cmake --build "$ADAPTER_BUILD" --target MediaRemoteAdapter >/dev/null

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

# The ${a[@]+...} form keeps macOS's bash 3.2 from failing on an empty array under `set -u`.
echo "==> Building Eyelid ($CONFIGURATION${ARCH_FLAGS[@]+, universal})"
swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

# Git is the single source of truth for versions: the tag being released, or the latest tag otherwise.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN_DIR/Eyelid" "$APP/Contents/MacOS/Eyelid"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ADAPTER_SRC/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp -R "$ADAPTER_BUILD/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/"
cp "$ADAPTER_SRC/LICENSE" "$APP/Contents/Resources/Licenses/mediaremote-adapter.txt"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
echo "    Version $VERSION ($BUILD_NUMBER)"

if [[ "$CONFIGURATION" == release ]]; then
  # Debug symbols point at object files on the build machine, by their full paths, and aren't needed to run.
  strip -S -x "$APP/Contents/MacOS/Eyelid"
fi

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Apple Development/ { print $2; exit }')"
fi
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
echo "==> Signing (${SIGN_IDENTITY/#-/ad hoc})"
# The hardened runtime protects the process that holds Accessibility access. Signed with a real
# identity, it also only lets Apple's libraries and the identity's own into the process.
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"

echo "==> Done: $APP"
