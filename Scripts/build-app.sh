#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIST="$ROOT/dist"
APP="$DIST/AudioToolbox.app"
ENTITLEMENTS="$ROOT/Packaging/AudioToolbox.entitlements"
INFO_PLIST="$ROOT/Packaging/Info.plist"
NOTICES="$ROOT/THIRD_PARTY_NOTICES.md"
SWIFT_BUILD_ARGUMENTS=()

if [[ -z "$ROOT" || "$ROOT" == "/" ]]; then
    echo "Refusing to package from unsafe repository root: $ROOT" >&2
    exit 1
fi

EXPECTED_APP="$ROOT/dist/AudioToolbox.app"
if [[ "$APP" != "$EXPECTED_APP" ]]; then
    echo "Refusing to clean unexpected app path: $APP" >&2
    exit 1
fi

if [[ -L "$DIST" ]]; then
    echo "Refusing to use symlinked dist directory: $DIST" >&2
    exit 1
fi

for required_file in "$ENTITLEMENTS" "$INFO_PLIST" "$NOTICES"; do
    if [[ ! -f "$required_file" ]]; then
        echo "Missing packaging input: $required_file" >&2
        exit 1
    fi
done

if [[ "${CODEX_CI:-0}" == "1" ]]; then
    CACHE_DIR="$ROOT/.build/cache"
    CONFIG_DIR="$ROOT/.build/config"
    SECURITY_DIR="$ROOT/.build/security"
    MODULE_CACHE_DIR="$ROOT/.build/clang-module-cache"
    mkdir -p "$CACHE_DIR" "$CONFIG_DIR" "$SECURITY_DIR" "$MODULE_CACHE_DIR"
    export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
    export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"
    SWIFT_BUILD_ARGUMENTS+=(
        --disable-sandbox
        --cache-path "$CACHE_DIR"
        --config-path "$CONFIG_DIR"
        --security-path "$SECURITY_DIR"
        --manifest-cache local
    )
fi

cd "$ROOT"
swift build "${SWIFT_BUILD_ARGUMENTS[@]}" -c release --product AudioToolbox
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGUMENTS[@]}" -c release --show-bin-path)"
BINARY="$BIN_DIR/AudioToolbox"

if [[ ! -x "$BINARY" ]]; then
    echo "Release executable not found: $BINARY" >&2
    exit 1
fi

mkdir -p "$DIST"
if [[ -e "$APP" || -L "$APP" ]]; then
    rm -rf -- "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/AudioToolbox"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
cp "$NOTICES" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

codesign \
    --force \
    --deep \
    --sign - \
    --entitlements "$ENTITLEMENTS" \
    "$APP"

codesign --verify --deep --strict "$APP"

SIGNED_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/audio-toolbox-entitlements.XXXXXX")"
cleanup() {
    rm -f -- "$SIGNED_ENTITLEMENTS"
}
trap cleanup EXIT

codesign -d --entitlements :- "$APP" >"$SIGNED_ENTITLEMENTS" 2>/dev/null
for entitlement in \
    com.apple.security.app-sandbox \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope
do
    if [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$SIGNED_ENTITLEMENTS")" != "true" ]]; then
        echo "Signed app is missing required entitlement: $entitlement" >&2
        exit 1
    fi
done

echo "$APP"
