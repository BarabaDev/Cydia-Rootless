#!/var/jb/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH}"

fail() { echo "[FAIL] $*" >&2; exit 1; }

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

ensure_xz_runtime() {
    if package_installed xz-utils || package_installed xz; then
        echo "[ok] XZ runtime dependency is installed"
        return 0
    fi
    command -v apt-get >/dev/null 2>&1 || fail "apt-get is required to install xz-utils"
    echo "[dependency] installing Procursus xz-utils before local Cydia packages"
    DEBIAN_FRONTEND=noninteractive apt-get install -y xz-utils
    package_installed xz-utils || package_installed xz || fail "xz-utils installation did not complete"
    echo "[ok] xz-utils installed"
}

if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "[root] Re-running Cydia rootless runtime update with sudo ..."
        exec sudo -E "$0" "$@"
    fi
    fail "root privileges are required"
fi

[[ -e Cydia.deb && -e Cydia_.deb ]] || fail "run ./package-ondevice.sh first"
./runtime-methods-preflight.sh

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/var/mobile/Documents/Cydia_Rootless_BACKUP_${STAMP}"
mkdir -p "$BACKUP"

source_manifest() {
    local out="$1"
    : >"$out"
    [[ -f /var/jb/etc/apt/sources.list ]] && cksum /var/jb/etc/apt/sources.list >>"$out" 2>/dev/null || true
    if [[ -d /var/jb/etc/apt/sources.list.d ]]; then
        find /var/jb/etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print 2>/dev/null | sort | while IFS= read -r f; do
            cksum "$f" 2>/dev/null || true
        done >>"$out"
    fi
}

source_manifest "$BACKUP/apt-sources.before"
[[ -f /var/jb/etc/apt/preferences.d/cydia ]] && cp -a /var/jb/etc/apt/preferences.d/cydia "$BACKUP/cydia.preferences.before"
[[ -d /var/jb/Applications/Cydia.app ]] && cp -a /var/jb/Applications/Cydia.app "$BACKUP/Cydia.app.before"
dpkg-query -s cydia >"$BACKUP/cydia.before.txt" 2>&1 || true

echo "== Cydia rootless / runtime update =="
echo "[backup] $BACKUP"
ensure_xz_runtime
echo "[install] dpkg -i ./Cydia_.deb ./Cydia.deb"
dpkg -i ./Cydia_.deb ./Cydia.deb

status_cydia="$(dpkg-query -W -f='${Status}' cydia 2>/dev/null || true)"
status_lproj="$(dpkg-query -W -f='${Status}' cydia-lproj 2>/dev/null || true)"
echo "cydia: $status_cydia"
echo "cydia-lproj: $status_lproj"
[[ "$status_cydia" == "install ok installed" ]] || fail "cydia is not fully configured"
[[ "$status_lproj" == "install ok installed" ]] || fail "cydia-lproj is not fully configured"

if [[ -e /var/jb/etc/apt/preferences.d/cydia ]]; then
    fail "legacy /var/jb/etc/apt/preferences.d/cydia still exists after update"
fi
echo "[ok] legacy Cydia APT pin file is absent"

source_manifest "$BACKUP/apt-sources.after"
if ! diff -u "$BACKUP/apt-sources.before" "$BACKUP/apt-sources.after" >"$BACKUP/apt-sources.diff"; then
    cat "$BACKUP/apt-sources.diff"
    fail "APT source files changed during update"
fi
echo "[ok] existing APT source files were preserved exactly"

scoped="$(dpkg --audit cydia cydia-lproj 2>&1 || true)"
if [[ -n "$scoped" ]]; then
    echo "$scoped"
    fail "Cydia-scoped dpkg audit is not clean"
fi
echo "[ok] Cydia-scoped dpkg audit is clean"

# Rootless architecture migration: cached package metadata created while
# iphoneos-arm was visible can keep duplicate rootful/rootless package
# objects around even after the runtime policy is corrected. Purge only
# Cydia's disposable APT cache/list state; user source configuration and
# the bootstrap's /var/jb APT state are not modified.
CYDIA_CACHE="/var/mobile/Library/Caches/com.saurik.Cydia"
if [[ -d "$CYDIA_CACHE" ]]; then
    echo "[cache] resetting Cydia package indexes for rootless-only architecture policy"
    rm -f "$CYDIA_CACHE/pkgcache.bin" "$CYDIA_CACHE/srcpkgcache.bin"
    rm -rf "$CYDIA_CACHE/lists"
    mkdir -p "$CYDIA_CACHE/lists/partial"
    chown -R 501:501 "$CYDIA_CACHE" 2>/dev/null || true
    echo "[ok] Cydia package cache reset; next launch will rebuild from rootless indexes"
fi

if command -v uicache >/dev/null 2>&1; then
    uicache -p /var/jb/Applications/Cydia.app
    echo "[ok] uicache completed"
fi
chown -R 501:501 "$BACKUP" 2>/dev/null || true

echo "[ok] runtime update installed"
echo "[safe] No reboot or respring was forced."
echo "[next] Force-close Cydia if open, reopen it, then Refresh; duplicate rootful package entries should be gone."

echo "[cydo] post-install smoke tests"
CYDO=/var/jb/usr/libexec/cydia/cydo
if [ ! -x "$CYDO" ]; then
    echo "[FATAL] installed cydo is missing or not executable: $CYDO"
    exit 1
fi
ls -l "$CYDO"
"$CYDO" /var/jb/usr/bin/true
"$CYDO" --version >/dev/null
"$CYDO" --set-selections </dev/null
printf '[ok] cydo + dpkg + dpkg --set-selections smoke tests passed\n'

echo "[ok] runtime update completed"
