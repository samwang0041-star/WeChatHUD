#!/usr/bin/env bash
set -euo pipefail

# Build a self-contained release app. The pinned zstd dependency is built and
# cached by build-zstd.sh; notarization remains a separate, explicit manual
# step.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$repo_root/.build/WeChatHUD.app"
sign_identity="${SIGN_IDENTITY:--}"
make_archive=0

usage() {
    cat <<'EOF'
Usage: scripts/package-app.sh [--archive] [--app PATH] [--sign IDENTITY]

Packages an already-built release binary into a portable macOS app.
    The default signature is ad hoc (-); dependency source download is pinned
    and SHA-256 verified, while notarization remains manual. Use --archive to
    create a zip and SHA-256 manifest.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --archive) make_archive=1; shift ;;
        --app) app_path="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
        --sign) sign_identity="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$app_path" in
    "$repo_root/.build/"*) ;;
    *) echo "--app must point inside $repo_root/.build" >&2; exit 2 ;;
esac

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "required command not found: $1" >&2
        exit 1
    }
}

for command_name in swift cp codesign install_name_tool otool lipo vtool ditto shasum; do
    require_command "$command_name"
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "portable app packaging requires macOS" >&2
    exit 1
fi

if [[ -n "${RELEASE_BIN_PATH:-}" ]]; then
    bin_dir="$RELEASE_BIN_PATH"
else
    bin_dir="$(swift build -c release --show-bin-path)"
fi
executable="$bin_dir/WeChatHUD"
resource_bundle="$bin_dir/WeChatHUD_WeChatHUD.bundle"
[[ -f "$executable" ]] || { echo "release executable not found: $executable; run swift build -c release first" >&2; exit 1; }
[[ -d "$resource_bundle" ]] || { echo "resource bundle not found: $resource_bundle; run swift build -c release first" >&2; exit 1; }
app_icon="$repo_root/Resources/AppIcon.icns"
[[ -f "$app_icon" ]] || {
    echo "app icon not found: $app_icon; run make icon first" >&2
    exit 1
}

architectures="$(lipo -archs "$executable")"
[[ "$architectures" == "arm64" ]] || {
    echo "release executable architecture must be arm64; found: $architectures" >&2
    exit 1
}

zstd_build_root="${ZSTD_BUILD_ROOT:-$repo_root/.build/dependencies/zstd}"
zstd_build_dir="$zstd_build_root/1.5.7-macos14-arm64/output"
 # Bundled one-time key scanner, copied unmodified into Resources/keytools.
 key_tool="${WECHATHUD_KEY_TOOL:-$repo_root/../repo/wechat_cli/bin/find_all_keys_macos.arm64}"
 [[ -f "$key_tool" ]] || { echo "key tool missing: $key_tool" >&2; exit 1; }
if [[ -n "${ZSTD_DYLIB:-}" ]]; then
    zstd_dylib="$ZSTD_DYLIB"
    zstd_license="${ZSTD_LICENSE:-$(dirname "$zstd_dylib")/LICENSE}"
else
    "$repo_root/scripts/build-zstd.sh"
    zstd_dylib="$zstd_build_dir/libzstd.1.dylib"
    zstd_license="$zstd_build_dir/LICENSE"
fi
[[ -f "$zstd_dylib" ]] || { echo "zstd dylib not found: $zstd_dylib" >&2; exit 1; }
[[ -f "$zstd_license" ]] || { echo "zstd license not found: $zstd_license" >&2; exit 1; }

validate_macos14_arm64() {
    local binary="$1"
    local min_os
    [[ "$(lipo -archs "$binary")" == "arm64" ]] || {
        echo "Mach-O must be arm64: $binary" >&2
        exit 1
    }
    min_os="$(vtool -show-build "$binary" 2>/dev/null | awk '$1 == "minos" { print $2; exit }')"
    [[ -n "$min_os" ]] || {
        echo "Mach-O has no macOS deployment target: $binary" >&2
        exit 1
    }
    awk -v min_os="$min_os" 'BEGIN { exit !(min_os + 0 <= 14.0) }' || {
        echo "Mach-O deployment target exceeds macOS 14: $binary (minos $min_os)" >&2
        exit 1
    }
}

validate_macos14_arm64 "$executable"
validate_macos14_arm64 "$zstd_dylib"

bundle_contents="$app_path/Contents"
frameworks_dir="$bundle_contents/Frameworks"
resources_dir="$bundle_contents/Resources"
third_party_dir="$resources_dir/THIRD_PARTY_LICENSES"
rm -rf "$app_path"
mkdir -p "$bundle_contents/MacOS" "$frameworks_dir" "$resources_dir" "$third_party_dir"

cp "$executable" "$bundle_contents/MacOS/WeChatHUD"
cp "$repo_root/Resources/Info.plist" "$bundle_contents/Info.plist"
cp -R "$resource_bundle" "$resources_dir/"
cp "$app_icon" "$resources_dir/AppIcon.icns"
 mkdir -p "$resources_dir/keytools"
 cp "$key_tool" "$resources_dir/keytools/find_all_keys_macos.arm64"
 chmod +x "$resources_dir/keytools/find_all_keys_macos.arm64"

bundled_dylib="$frameworks_dir/libzstd.1.dylib"
cp -L "$zstd_dylib" "$bundled_dylib"
chmod 755 "$bundled_dylib"

old_zstd_path="$(otool -L "$bundle_contents/MacOS/WeChatHUD" | awk '$1 ~ /libzstd/ { print $1; exit }')"
[[ -n "$old_zstd_path" ]] || { echo "release executable has no libzstd dependency" >&2; exit 1; }
new_zstd_path='@executable_path/../Frameworks/libzstd.1.dylib'
install_name_tool -change "$old_zstd_path" "$new_zstd_path" "$bundle_contents/MacOS/WeChatHUD"
install_name_tool -id "$new_zstd_path" "$bundled_dylib"

# Preserve the upstream license and record provenance without embedding the
# build host's absolute dependency path in the distributed app.
cp "$zstd_license" "$third_party_dir/zstd-LICENSE.txt"
if [[ -n "${ZSTD_DYLIB:-}" ]]; then
    zstd_dylib_sha256="$(shasum -a 256 "$zstd_dylib" | awk '{print $1}')"
    cat > "$third_party_dir/zstd-SOURCE.txt" <<EOF
libzstd bundled by WeChatHUD

Source: external override supplied through ZSTD_DYLIB
Build target validated: macOS 14.0 arm64
Dylib SHA-256: ${zstd_dylib_sha256}
EOF
else
    cp "$zstd_build_dir/SOURCE.txt" "$third_party_dir/zstd-SOURCE.txt"
fi

if otool -L "$bundle_contents/MacOS/WeChatHUD" "$bundled_dylib" | grep -E '/opt/homebrew|/usr/local/opt/zstd' >/dev/null; then
    echo "development zstd path leaked into packaged Mach-O" >&2
    exit 1
fi

sign_nested() {
    local keychain_args=()
    if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
        keychain_args=(--keychain "$SIGN_KEYCHAIN")
    fi
    local key_tool_bin="$resources_dir/keytools/find_all_keys_macos.arm64"
    if [[ "$sign_identity" == "-" ]]; then
        codesign --force --sign - "$key_tool_bin"
        codesign --force --sign - "$bundled_dylib"
        codesign --force --sign - "$app_path"
    elif [[ "$sign_identity" == "Developer ID Application:"* ]]; then
        codesign --force --timestamp --options runtime "${keychain_args[@]}" --sign "$sign_identity" "$key_tool_bin"
        codesign --force --timestamp --options runtime "${keychain_args[@]}" --sign "$sign_identity" "$bundled_dylib"
        codesign --force --timestamp --options runtime "${keychain_args[@]}" --sign "$sign_identity" "$app_path"
    else
        # Local self-signed identities may not have a Team ID. Keep both
        # nested dylib and app outside hardened runtime and avoid timestamps;
        # mixing runtime-signed containers with a no-Team-ID dylib fails at
        # dyld load time.
        codesign --force --sign "$sign_identity" "$key_tool_bin"
        codesign --force --sign "$sign_identity" "$bundled_dylib"
        codesign --force --sign "$sign_identity" "$app_path"
    fi
}
sign_nested
codesign --verify --deep --strict --verbose=2 "$app_path"
# Run the actual signed executable before emitting a releasable archive.
# This checks dyld and bundled prompts without reading accounts or settings.
"$bundle_contents/MacOS/WeChatHUD" bundle-check

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle_contents/Info.plist")"
if [[ "$make_archive" == 1 ]]; then
    distribution_dir="$repo_root/.build/distribution"
    archive="$distribution_dir/WeChatHUD-${version}-macOS14-arm64.zip"
    mkdir -p "$distribution_dir"
    rm -f "$archive" "$archive.sha256"
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive"
    (cd "$distribution_dir" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
    echo "Archive: $archive"
    echo "SHA-256: $archive.sha256"
fi

echo "Portable app: $app_path"
echo "Signature: $sign_identity"
echo "Bundled dependency: $new_zstd_path"
