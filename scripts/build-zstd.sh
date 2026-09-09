#!/usr/bin/env bash
set -euo pipefail

# Build the exact zstd dylib that the macOS 14 arm64 app is allowed to ship.
# The source archive is pinned by both tag and SHA-256; the result is cached
# under .build so normal packaging does not rebuild or redownload it.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zstd_version="1.5.7"
zstd_tag="v${zstd_version}"
zstd_sha256="37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3"
cache_root="${ZSTD_BUILD_ROOT:-$repo_root/.build/dependencies/zstd}"
build_root="$cache_root/${zstd_version}-macos14-arm64"
source_root="$build_root/source"
archive="$build_root/zstd-${zstd_version}.tar.gz"
source_dir="$source_root/zstd-${zstd_version}"
output_dir="$build_root/output"
output_dylib="$output_dir/libzstd.1.dylib"
output_license="$output_dir/LICENSE"
output_source="$output_dir/SOURCE.txt"
force=0

usage() {
    cat <<'EOF'
Usage: scripts/build-zstd.sh [--force]

Download (once), verify, and build the pinned upstream zstd source as an
arm64 macOS 14-compatible dylib. The final output path is printed at the end.
Set ZSTD_BUILD_ROOT to relocate the cache.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) force=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "required command not found: $1" >&2
        exit 1
    }
}

for command_name in curl shasum tar make clang cp install_name_tool lipo vtool otool awk xcrun sysctl; do
    require_command "$command_name"
done

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "zstd release dependency build requires Darwin arm64" >&2
    exit 1
fi

mkdir -p "$source_root" "$output_dir"

verify_archive() {
    local actual
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [[ "$actual" == "$zstd_sha256" ]] || {
        echo "zstd source SHA-256 mismatch: expected $zstd_sha256, got $actual" >&2
        exit 1
    }
}

if [[ ! -f "$archive" ]]; then
    tmp_archive="$archive.download.$$"
    curl -fL --retry 3 --retry-delay 1 \
        "https://github.com/facebook/zstd/archive/refs/tags/${zstd_tag}.tar.gz" \
        -o "$tmp_archive"
    mv "$tmp_archive" "$archive"
fi
verify_archive

if [[ "$force" == 1 || ! -d "$source_dir/lib" ]]; then
    rm -rf "$source_dir"
    tar -xzf "$archive" -C "$source_root"
fi

is_compatible_dylib() {
    local dylib="$1"
    [[ -f "$dylib" ]] || return 1
    [[ "$(lipo -archs "$dylib")" == "arm64" ]] || return 1
    local min_os
    min_os="$(vtool -show-build "$dylib" 2>/dev/null | awk '$1 == "minos" { print $2; exit }')"
    [[ -n "$min_os" ]] || return 1
    awk -v min_os="$min_os" 'BEGIN { exit !(min_os + 0 <= 14.0) }'
}

if [[ "$force" == 1 || ! -f "$output_dylib" ]] || ! is_compatible_dylib "$output_dylib"; then
    make -C "$source_dir/lib" clean >/dev/null 2>&1 || true
    (
        cd "$source_dir/lib"
        export MACOSX_DEPLOYMENT_TARGET=14.0
        export SDKROOT
        SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
        make lib-release \
            CC=clang \
            CFLAGS="-O3 -arch arm64 -mmacosx-version-min=14.0" \
            LDFLAGS="-dynamiclib -arch arm64 -mmacosx-version-min=14.0" \
            UNAME_TARGET_SYSTEM=Darwin \
            -j"${ZSTD_JOBS:-$(sysctl -n hw.ncpu)}"
    )
    cp "$source_dir/lib/libzstd.${zstd_version}.dylib" "$output_dylib"
    chmod 755 "$output_dylib"
    install_name_tool -id "@rpath/libzstd.1.dylib" "$output_dylib"
    cp "$source_dir/LICENSE" "$output_license"
    cat > "$output_source" <<EOF
libzstd bundled by WeChatHUD

Source: https://github.com/facebook/zstd
Tag: ${zstd_tag}
Source archive SHA-256: ${zstd_sha256}
Build target: macOS 14.0 arm64
EOF
fi

is_compatible_dylib "$output_dylib" || {
    echo "built zstd dylib is not arm64 with macOS 14-or-earlier deployment target: $output_dylib" >&2
    exit 1
}
[[ -f "$output_license" ]] || cp "$source_dir/LICENSE" "$output_license"
output_dylib_sha256="$(shasum -a 256 "$output_dylib" | awk '{print $1}')"
cat > "$output_source" <<EOF
libzstd bundled by WeChatHUD
Source: https://github.com/facebook/zstd
Tag: ${zstd_tag}
Source archive SHA-256: ${zstd_sha256}
Build target: macOS 14.0 arm64
Built dylib SHA-256: ${output_dylib_sha256}
EOF

echo "zstd source: $zstd_tag (sha256 $zstd_sha256)" >&2
echo "zstd dylib: $output_dylib" >&2
printf '%s\n' "$output_dylib"
