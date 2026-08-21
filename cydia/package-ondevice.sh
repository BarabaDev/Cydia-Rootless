#!/var/jb/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH}"

LOG="$PWD/Cydia_Rootless_Package.log"
rm -f "$LOG"

set +e
{
    echo "== Cydia rootless / package build =="
    echo "[info] This script only BUILDS and VERIFIES the .deb files."
    echo "[info] It does NOT install Cydia."
    echo

    ./prepare-ondevice.sh
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
    grep -nE '(^|: )[[:space:]]*(fatal )?error:|fatal error:|ld: |make: \*\*\*|dpkg-deb: error|fakeroot:|not found|No such file' "$LOG" || true
    exit "$status"
fi

echo
./verify-package-ondevice.sh

echo
echo "[ok] package build completed"
echo "[log] $LOG"
echo "[deb] $PWD/Cydia.deb"
echo "[lproj] $PWD/Cydia_.deb"
echo "[safe] Nothing was installed automatically."
