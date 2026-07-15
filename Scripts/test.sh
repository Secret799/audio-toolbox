#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORKS_DIR="$DEVELOPER_DIR/Library/Developer/Frameworks"
USR_LIB_DIR="$DEVELOPER_DIR/Library/Developer/usr/lib"
TESTING_FRAMEWORK="$FRAMEWORKS_DIR/Testing.framework"
TESTING_INTEROP_LIBRARY="$USR_LIB_DIR/lib_TestingInterop.dylib"

common_arguments=()
testing_build_arguments=()

if [[ "${CODEX_CI:-0}" == "1" ]]; then
    BUILD_DIR="$REPOSITORY_ROOT/.build"
    CACHE_DIR="$BUILD_DIR/cache"
    CONFIG_DIR="$BUILD_DIR/config"
    SECURITY_DIR="$BUILD_DIR/security"
    MODULE_CACHE_DIR="$BUILD_DIR/clang-module-cache"

    mkdir -p "$CACHE_DIR" "$CONFIG_DIR" "$SECURITY_DIR" "$MODULE_CACHE_DIR"

    export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
    export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

    common_arguments+=(
        --disable-sandbox
        --cache-path "$CACHE_DIR"
        --config-path "$CONFIG_DIR"
        --security-path "$SECURITY_DIR"
        --manifest-cache local
    )
fi

run_swift_build() {
    if [[ "${#common_arguments[@]}" -gt 0 ]]; then
        swift build "${common_arguments[@]}" "$@"
    else
        swift build "$@"
    fi
}

run_swift_test() {
    if [[ "${#common_arguments[@]}" -gt 0 ]]; then
        swift test "${common_arguments[@]}" "$@"
    else
        swift test "$@"
    fi
}

if [[ ! -d "$TESTING_FRAMEWORK" || ! -f "$TESTING_INTEROP_LIBRARY" ]]; then
    echo "Swift Testing runtime not found under $DEVELOPER_DIR" >&2
    exit 1
fi

testing_build_arguments+=(
    -Xswiftc -F
    -Xswiftc "$FRAMEWORKS_DIR"
    -Xlinker -F
    -Xlinker "$FRAMEWORKS_DIR"
)

cd "$REPOSITORY_ROOT"
run_swift_build "${testing_build_arguments[@]}" --build-tests
BIN_DIR="$(run_swift_build --show-bin-path)"

COPIED_TESTING_FRAMEWORK="$BIN_DIR/Testing.framework"
COPIED_TESTING_INTEROP_LIBRARY="$BIN_DIR/lib_TestingInterop.dylib"
created_testing_framework=0
created_testing_interop_library=0

cleanup() {
    local exit_code=$?
    trap - EXIT

    if [[ "$created_testing_framework" == "1" ]]; then
        rm -rf -- "$COPIED_TESTING_FRAMEWORK"
    fi
    if [[ "$created_testing_interop_library" == "1" ]]; then
        rm -f -- "$COPIED_TESTING_INTEROP_LIBRARY"
    fi

    exit "$exit_code"
}
trap cleanup EXIT

if [[ -e "$COPIED_TESTING_FRAMEWORK" || -L "$COPIED_TESTING_FRAMEWORK" ]]; then
    echo "Refusing to replace existing $COPIED_TESTING_FRAMEWORK" >&2
    exit 1
fi
if [[ -e "$COPIED_TESTING_INTEROP_LIBRARY" || -L "$COPIED_TESTING_INTEROP_LIBRARY" ]]; then
    echo "Refusing to replace existing $COPIED_TESTING_INTEROP_LIBRARY" >&2
    exit 1
fi

created_testing_framework=1
cp -R "$TESTING_FRAMEWORK" "$COPIED_TESTING_FRAMEWORK"
created_testing_interop_library=1
cp "$TESTING_INTEROP_LIBRARY" "$COPIED_TESTING_INTEROP_LIBRARY"

run_swift_test --skip-build "$@"
