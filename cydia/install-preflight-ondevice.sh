#!/var/jb/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH}"

fail() { echo "[FAIL] $*" >&2; exit 1; }
warn() { echo "[warn] $*" >&2; }

[[ -d /var/jb ]] || fail "/var/jb is missing; this package is rootless-only"
[[ -e Cydia.deb && -e Cydia_.deb ]] || fail "build Cydia.deb and Cydia_.deb first with ./package-ondevice.sh"

echo "== Cydia rootless / INSTALL PREFLIGHT =="
echo "[safe] This script does NOT install Cydia."
echo

echo "[device]"
echo "uid=$(id -u)"
echo "machine=$(uname -m)"
echo "ios=$(sw_vers -productVersion 2>/dev/null || true)"
echo "dpkg_arch=$(dpkg --print-architecture 2>/dev/null || true)"
echo "jbroot=/var/jb"

echo
echo "[installed package prerequisites]"
for pkg in firmware dpkg debianutils darwintools sed shell-cmds system-cmds uikittools; do
    if dpkg-query -W -f='${Status} ${Version}\n' "$pkg" 2>/dev/null | grep -q '^install ok installed '; then
        ver="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
        echo "[ok] $pkg $ver"
    else
        echo "[missing] $pkg"
    fi
done
if dpkg-query -W -f='${Status} ${Version}\n' xz-utils 2>/dev/null | grep -q '^install ok installed '; then
    echo "[ok] xz-utils $(dpkg-query -W -f='${Version}' xz-utils)"
elif dpkg-query -W -f='${Status} ${Version}\n' xz 2>/dev/null | grep -q '^install ok installed '; then
    echo "[ok] xz $(dpkg-query -W -f='${Version}' xz)"
else
    echo "[missing] xz-utils (or legacy xz provider)"
fi

echo
echo "[current APT source files - read only]"
if [[ -d /var/jb/etc/apt/sources.list.d ]]; then
    find /var/jb/etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print | sort
else
    warn "/var/jb/etc/apt/sources.list.d does not exist"
fi

echo
echo "[package control]"
dpkg-deb -f Cydia.deb Package Version Architecture Depends Pre-Depends

echo
echo "[maintainer-script audit]"
tmp="$(mktemp -d /tmp/cydia-rootless-preflight.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
dpkg-deb -e Cydia.deb "$tmp"
if grep -RInE 'apt\.bingner\.com|apt\.thebigboss\.org|cydia\.zodttd\.com|modmyi\.saurik\.com|repo\.dynastic\.co|repo\.chariz\.com' "$tmp"; then
    fail "hardcoded repository URL found in package maintainer scripts"
fi
echo "[ok] no hardcoded repository URL in maintainer scripts"

# Legacy stash code is retained for source fidelity but is guarded by old-iOS CFVersion checks.
if strings "$tmp/postinst" 2>/dev/null | grep -q '/var/stash'; then
    echo "[info] legacy /var/stash compatibility code is present in postinst binary; it is not expected to execute on iOS 15+"
fi

echo
echo "[dpkg simulation]"
echo "[info] Running: dpkg --no-act -i ./Cydia_.deb ./Cydia.deb"
set +e
dpkg --no-act -i ./Cydia_.deb ./Cydia.deb
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    warn "dpkg simulation returned $rc. Do NOT install yet; send this output back before installing."
    exit "$rc"
fi

echo
echo "[ok] dpkg --no-act unpack simulation passed"
echo "[note] The public rootless package removes the device-confirmed legacy BigBoss icon dependency before recovery."
echo "[safe] Nothing was installed."
echo "[next] Send this complete preflight result before real installation."
