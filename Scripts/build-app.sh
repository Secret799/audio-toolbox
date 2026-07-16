#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIST="$ROOT/dist"
APP="$DIST/AudioToolbox.app"
ENTITLEMENTS="$ROOT/Packaging/AudioToolbox.entitlements"
INFO_PLIST="$ROOT/Packaging/Info.plist"
NOTICES="$ROOT/THIRD_PARTY_NOTICES.md"
PACKAGE_RESOLVED="$ROOT/Package.resolved"
SOURCE_OFFER="$ROOT/Packaging/SOURCE_OFFER.md"
CXXTAGLIB_LICENSE="$ROOT/Packaging/Licenses/CXXTagLib-LICENSE.txt"
MPL_LICENSE="$ROOT/Packaging/Licenses/Mozilla-Public-License-1.1.txt"
CXXTAGLIB_CHECKOUT="$ROOT/.build/checkouts/CXXTagLib"
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

for required_file in \
    "$ENTITLEMENTS" \
    "$INFO_PLIST" \
    "$NOTICES" \
    "$PACKAGE_RESOLVED" \
    "$SOURCE_OFFER" \
    "$CXXTAGLIB_LICENSE" \
    "$MPL_LICENSE"
do
    if [[ ! -f "$required_file" ]]; then
        echo "Missing packaging input: $required_file" >&2
        exit 1
    fi
done

PIN_COUNT="$(plutil -extract pins raw "$PACKAGE_RESOLVED")"
LOCKED_CXXTAGLIB_REVISION=""
CXXTAGLIB_PIN_MATCHES=0
for ((pin_index = 0; pin_index < PIN_COUNT; pin_index++)); do
    pin_identity="$(plutil -extract "pins.$pin_index.identity" raw "$PACKAGE_RESOLVED")"
    if [[ "$pin_identity" == "cxxtaglib" ]]; then
        CXXTAGLIB_PIN_MATCHES=$((CXXTAGLIB_PIN_MATCHES + 1))
        LOCKED_CXXTAGLIB_REVISION="$(
            plutil -extract "pins.$pin_index.state.revision" raw "$PACKAGE_RESOLVED"
        )"
    fi
done
if [[ "$CXXTAGLIB_PIN_MATCHES" -ne 1       || ! "$LOCKED_CXXTAGLIB_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Package.resolved must contain exactly one valid cxxtaglib pin" >&2
    exit 1
fi
for revision_document in "$NOTICES" "$SOURCE_OFFER"; do
    if ! grep -Fq "$LOCKED_CXXTAGLIB_REVISION" "$revision_document"; then
        echo "Locked CXXTagLib revision is missing from: $revision_document" >&2
        exit 1
    fi
done

verify_cxxtaglib_checkout() {
    if [[ ! -d "$CXXTAGLIB_CHECKOUT/.git" ]]; then
        echo "Resolved CXXTagLib checkout not found: $CXXTAGLIB_CHECKOUT" >&2
        exit 1
    fi
    local actual_revision
    actual_revision="$(git -C "$CXXTAGLIB_CHECKOUT" rev-parse HEAD)"
    if [[ "$actual_revision" != "$LOCKED_CXXTAGLIB_REVISION" ]]; then
        echo "CXXTagLib checkout revision mismatch: $actual_revision" >&2
        exit 1
    fi
    if [[ -n "$(git -C "$CXXTAGLIB_CHECKOUT" status --porcelain --untracked-files=all)" ]]; then
        echo "CXXTagLib checkout has local changes; refusing a non-reproducible package" >&2
        exit 1
    fi
}

if [[ -e "$CXXTAGLIB_CHECKOUT" ]]; then
    verify_cxxtaglib_checkout
fi

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

verify_cxxtaglib_checkout
SOURCE_ARCHIVE_NAME="CXXTagLib-$LOCKED_CXXTAGLIB_REVISION.tar.gz"

mkdir -p "$DIST"
if [[ -e "$APP" || -L "$APP" ]]; then
    rm -rf -- "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/AudioToolbox"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
cp "$NOTICES" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$PACKAGE_RESOLVED" "$APP/Contents/Resources/Package.resolved"
cp "$SOURCE_OFFER" "$APP/Contents/Resources/THIRD_PARTY_SOURCE.md"
cp "$CXXTAGLIB_LICENSE" "$APP/Contents/Resources/CXXTagLib-LICENSE.txt"
cp "$MPL_LICENSE" "$APP/Contents/Resources/Mozilla-Public-License-1.1.txt"
git -C "$CXXTAGLIB_CHECKOUT" archive \
    --format=tar.gz \
    --prefix="CXXTagLib-$LOCKED_CXXTAGLIB_REVISION/" \
    --output="$APP/Contents/Resources/$SOURCE_ARCHIVE_NAME" \
    "$LOCKED_CXXTAGLIB_REVISION"

for bundled_resource in \
    THIRD_PARTY_NOTICES.md \
    Package.resolved \
    THIRD_PARTY_SOURCE.md \
    CXXTagLib-LICENSE.txt \
    Mozilla-Public-License-1.1.txt \
    "$SOURCE_ARCHIVE_NAME"
do
    if [[ ! -s "$APP/Contents/Resources/$bundled_resource" ]]; then
        echo "Missing or empty bundled resource: $bundled_resource" >&2
        exit 1
    fi
done

if ! tar -tzf \
    "$APP/Contents/Resources/$SOURCE_ARCHIVE_NAME" \
    "CXXTagLib-$LOCKED_CXXTAGLIB_REVISION/LICENSE.txt" \
    >/dev/null
then
    echo "Bundled CXXTagLib source archive is incomplete" >&2
    exit 1
fi

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
