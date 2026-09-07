#!/var/jb/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH}"

LOG="${TMPDIR:-/tmp}/Cydia_Rootless_Package.log"
rm -f "$LOG"

cleanup_build_products() {
    make -f makefile.ondevice clean >/dev/null 2>&1 || true
}
trap cleanup_build_products EXIT

set +e
{
    echo "== Cydia rootless / package build =="
    echo "[info] This script only BUILDS and VERIFIES the .deb files."
    echo "[info] It does NOT install Cydia."
    echo

    make -f makefile.ondevice clean
    find .. -name '.DS_Store' -delete
    mkdir -p debs
    rm -f debs/*.deb debs/*.zip debs/.DS_Store

    bash ./prepare-ondevice.sh
    prepare_status=$?
    if [[ $prepare_status -ne 0 ]]; then
        echo
        echo "[stop] preparation failed; compilation and packaging were not started"
        exit "$prepare_status"
    fi
    export SDKROOT="$(./ondevice-sdk.sh)"

    echo
    echo "SDKROOT=$SDKROOT"
    echo "ARCH=arm64"
    echo "PREFIX=/var/jb"
    echo

    make -f makefile.ondevice package
} 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
    echo
    echo "== Cydia package error summary (complete log: $LOG) =="
    grep -nE '(^|: )[[:space:]]*(fatal )?error:|fatal error:|ld: |make: \*\*\*|dpkg-deb: error|not found|No such file|\[miss\]|\[stop\]' "$LOG" || true
    exit "$status"
fi

echo
./verify-package-ondevice.sh

version="$(./version.sh)"
main="$PWD/debs/cydia_${version}_iphoneos-arm64.deb"
make -f makefile.ondevice clean
trap - EXIT

echo
echo "[ok] package build completed"
echo "[log] $LOG"
echo "[deb] $main"
echo "[translations] included in the main package"
echo "[safe] Nothing was installed automatically."
