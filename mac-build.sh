#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")" && pwd)"
source_root="$project_root/cydia"
jobs="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || printf '4')}"

for tool in xcrun brew gsed ldid dpkg-deb gtar xz perl make ar strip install_name_tool sips; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Missing Mac build tool: %s\n' "$tool" >&2
        exit 10
    }
done
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid JOBS value: %s\n' "$jobs" >&2; exit 2; }

sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
gnutls_prefix="$(brew --prefix gnutls)"
[[ -f "$sdk_path/System/Library/Frameworks/UIKit.framework/UIKit.tbd" ]] || {
    printf 'Invalid iPhoneOS SDK: %s\n' "$sdk_path" >&2
    exit 11
}
[[ -f "$gnutls_prefix/include/gnutls/gnutls.h" ]] || {
    printf 'GnuTLS development headers are missing: %s\n' "$gnutls_prefix" >&2
    exit 11
}

log="${TMPDIR:-/tmp}/Cydia_1.1.24_mac-build.log"
: > "$log"

cleanup_build_products() {
    (cd "$source_root" && make -f makefile.ondevice HOST_BUILD=1 clean >/dev/null 2>&1) || true
    find "$project_root" -name '.DS_Store' -delete 2>/dev/null || true
}
trap cleanup_build_products EXIT

set +e
{
    set -e
    printf '%s\n' '== Cydia 1.1.24 rootless Mac build =='
    printf 'SDK: %s\nJobs: %s\n\n' "$sdk_path" "$jobs"

    cd "$source_root"
    make -f makefile.ondevice HOST_BUILD=1 clean
    find "$project_root" -name '.DS_Store' -delete
    cd "$project_root"
    "$project_root/mac-quality-audit.sh"

    cd "$source_root"
    cp -p apt64/apt-pkg/contrib/*.h apt64/apt-pkg/
    cp -p apt64/apt-pkg/deb/*.h apt64/apt-pkg/
    ln -sfn apt64/methods/aptmethod.h aptmethod.h
    ln -sfn apt64/methods/http.cc http.cc
    ln -sfn apt64/methods/http.h http.h

    mkdir -p debs
    rm -f debs/*.deb debs/*.zip debs/.DS_Store
    make -f makefile.ondevice HOST_BUILD=1 -j"$jobs" package
    /bin/bash ./verify-package-ondevice.sh

    printf '\n[architecture]\n'
    file MobileCydia cydo du setnsfpn cfversion postinst
    printf '\n[dynamic libraries]\n'
    otool -L MobileCydia
    make -f makefile.ondevice HOST_BUILD=1 clean
    find "$project_root" -name '.DS_Store' -delete
} 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e

if [[ "$status" -ne 0 ]]; then
    printf '\nMac build failed. Log: %s\n' "$log" >&2
    exit "$status"
fi

version="$(cd "$source_root" && ./version.sh)"
main="$source_root/debs/cydia_${version}_iphoneos-arm64.deb"
[[ -f "$main" ]] || { printf 'Expected Cydia DEB output is missing.\n' >&2; exit 12; }
trap - EXIT

printf '\nMAC BUILD PASSED\nCydia: %s\nTranslations: included in the main package\nLog: %s\n' "$main" "$log"
