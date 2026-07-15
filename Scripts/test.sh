#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORKS_DIR="$DEVELOPER_DIR/Library/Developer/Frameworks"
USR_LIB_DIR="$DEVELOPER_DIR/Library/Developer/usr/lib"

swift_test_arguments=()

if [[ -d "$FRAMEWORKS_DIR/Testing.framework" ]]; then
    swift_test_arguments+=(
        -Xswiftc -F
        -Xswiftc "$FRAMEWORKS_DIR"
        -Xlinker -F
        -Xlinker "$FRAMEWORKS_DIR"
        -Xlinker -rpath
        -Xlinker "$FRAMEWORKS_DIR"
        -Xlinker -rpath
        -Xlinker "$USR_LIB_DIR"
    )
fi

if [[ "${CODEX_CI:-0}" == "1" ]]; then
    BUILD_DIR="$REPOSITORY_ROOT/.build"
    CACHE_DIR="$BUILD_DIR/cache"
    CONFIG_DIR="$BUILD_DIR/config"
    SECURITY_DIR="$BUILD_DIR/security"
    MODULE_CACHE_DIR="$BUILD_DIR/clang-module-cache"

    mkdir -p "$CACHE_DIR" "$CONFIG_DIR" "$SECURITY_DIR" "$MODULE_CACHE_DIR"

    export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
    export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

    swift_test_arguments+=(
        --disable-sandbox
        --cache-path "$CACHE_DIR"
        --config-path "$CONFIG_DIR"
        --security-path "$SECURITY_DIR"
        --manifest-cache local
    )
fi

cd "$REPOSITORY_ROOT"
exec swift test "${swift_test_arguments[@]}" "$@"
