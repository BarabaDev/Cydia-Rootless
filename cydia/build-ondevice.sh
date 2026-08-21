#!/var/jb/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH}"

./prepare-ondevice.sh
export SDKROOT="$(./ondevice-sdk.sh)"

echo
echo "== Building Cydia core for iOS 15+ rootless =="
echo "SDKROOT=$SDKROOT"
echo "ARCH=arm64"
echo

if [[ $# -eq 0 ]]; then
    set -- all
fi

LOG="Cydia_Rootless_Build.log"
rm -f "$LOG"

# Keep the complete compiler transcript on-device. NewTerm's visible scrollback
# can hide the first diagnostic when clang reports multiple errors.
set +e
make -f makefile.ondevice "$@" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
    echo
    echo "== Cydia build error summary (complete log: $PWD/$LOG) =="
    grep -nE '(^|: )[[:space:]]*(fatal )?error:|fatal error:' "$LOG" || true
    exit "$status"
fi

echo
echo "[ok] build completed"
echo "[log] $PWD/$LOG"
