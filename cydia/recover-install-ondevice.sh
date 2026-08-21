#!/var/jb/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH}"

fail() { echo "[FAIL] $*" >&2; exit 1; }
warn() { echo "[warn] $*" >&2; }

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
        echo "[root] Re-running Cydia recovery with sudo ..."
        exec sudo -E "$0" "$@"
    fi
    fail "root privileges are required. Re-run with: sudo ./recover-install-ondevice.sh"
fi

[[ -d /var/jb ]] || fail "/var/jb is missing; this recovery is rootless-only"
[[ -e Cydia.deb && -e Cydia_.deb ]] || fail "build Cydia.deb and Cydia_.deb first with ./package-ondevice.sh"

LOG="$PWD/Cydia_Rootless_Recovery.log"
rm -f "$LOG"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/var/mobile/Documents/Cydia_Rootless_RECOVERY_BACKUP_${STAMP}"

source_manifest() {
    local out="$1"
    : >"$out"
    if [[ -f /var/jb/etc/apt/sources.list ]]; then
        cksum /var/jb/etc/apt/sources.list >>"$out" 2>/dev/null || true
    fi
    if [[ -d /var/jb/etc/apt/sources.list.d ]]; then
        find /var/jb/etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print 2>/dev/null | sort | while IFS= read -r f; do
            cksum "$f" 2>/dev/null || true
        done >>"$out"
    fi
}

backup_path() {
    local src="$1"
    local rel="${src#/}"
    if [[ -e "$src" || -L "$src" ]]; then
        mkdir -p "$BACKUP/$(dirname "$rel")"
        cp -a "$src" "$BACKUP/$rel"
        echo "[backup] $src"
    fi
}

set +e
{
    echo "== Cydia rootless / DEPENDENCY RECOVERY =="
    echo "[info] Repairs the current unpacked Cydia state with corrected package metadata."
    echo "[info] No apt -f install, reboot, or respring is used."
    echo

    echo "[before] package state"
    dpkg-query -W -f='cydia: ${Status} ${Version}\n' cydia 2>/dev/null || echo "cydia: not installed"
    dpkg-query -W -f='cydia-lproj: ${Status} ${Version}\n' cydia-lproj 2>/dev/null || echo "cydia-lproj: not installed"

    echo
    echo "[package metadata]"
    dpkg-deb -f Cydia.deb Package Version Architecture Depends Pre-Depends
    depends="$(dpkg-deb -f Cydia.deb Depends)"
    if grep -Fq 'org.thebigboss.repo.icons' <<<"$depends"; then
        fail "corrected Cydia.deb still depends on org.thebigboss.repo.icons"
    fi
    echo "[ok] legacy BigBoss icon dependency is absent"

    echo
    echo "[backup] creating: $BACKUP"
    mkdir -p "$BACKUP"
    source_manifest "$BACKUP/apt-sources.before"
    backup_path /var/jb/etc/apt
    backup_path /var/jb/var/lib/dpkg/status
    backup_path /var/jb/Applications/Cydia.app
    backup_path /var/jb/usr/libexec/cydia
    backup_path /var/jb/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist
    backup_path /var/jb/var/lib/cydia
    backup_path /var/mobile/Library/Cydia/metadata.cb0
    dpkg-query -s cydia >"$BACKUP/cydia.before.txt" 2>&1 || true
    dpkg-query -s cydia-lproj >"$BACKUP/cydia-lproj.before.txt" 2>&1 || true

    echo
    ensure_xz_runtime

    echo
    echo "[preflight]"
    ./install-preflight-ondevice.sh

    echo
    echo "[recover] re-install corrected same-version package pair"
    echo "[recover] dpkg -i ./Cydia_.deb ./Cydia.deb"
    dpkg -i ./Cydia_.deb ./Cydia.deb
    dpkg_rc=$?
    if [[ $dpkg_rc -ne 0 ]]; then
        echo "[FAIL] dpkg returned $dpkg_rc"
        echo "[audit] dpkg --audit"
        dpkg --audit || true
        echo "[backup] $BACKUP"
        exit "$dpkg_rc"
    fi

    echo
    echo "[after] package state"
    status_cydia="$(dpkg-query -W -f='${Status}' cydia 2>/dev/null || true)"
    status_lproj="$(dpkg-query -W -f='${Status}' cydia-lproj 2>/dev/null || true)"
    echo "cydia: $status_cydia"
    echo "cydia-lproj: $status_lproj"
    [[ "$status_cydia" == "install ok installed" ]] || fail "cydia is not fully configured"
    [[ "$status_lproj" == "install ok installed" ]] || fail "cydia-lproj is not fully configured"

    echo
    echo "[verify] installed rootless payload"
    for p in \
        /var/jb/Applications/Cydia.app/Cydia \
        /var/jb/usr/libexec/cydia/cydo \
        /var/jb/usr/libexec/cydia/firmware.sh \
        /var/jb/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist; do
        [[ -e "$p" || -L "$p" ]] || fail "missing installed file: $p"
        echo "[ok] $p"
    done
    if [[ -e /var/jb/etc/apt/preferences.d/cydia ]]; then
        fail "obsolete /var/jb/etc/apt/preferences.d/cydia still exists"
    fi
    echo "[ok] obsolete Cydia APT pin file is absent"

    echo
    echo "[verify] APT source preservation"
    source_manifest "$BACKUP/apt-sources.after"
    if ! diff -u "$BACKUP/apt-sources.before" "$BACKUP/apt-sources.after" >"$BACKUP/apt-sources.diff"; then
        echo "[FAIL] APT source files changed during recovery"
        cat "$BACKUP/apt-sources.diff"
        echo "[backup] $BACKUP"
        exit 1
    fi
    echo "[ok] existing APT source files were preserved exactly"

    echo
    echo "[uicache] registering Cydia.app"
    if command -v uicache >/dev/null 2>&1; then
        uicache -p /var/jb/Applications/Cydia.app
        echo "[ok] uicache completed"
    else
        warn "uicache command not found; app registration was not refreshed"
    fi

    echo
    echo "[audit] dpkg --audit"
    audit="$(dpkg --audit 2>&1)"
    if [[ -n "$audit" ]]; then
        echo "$audit"
        warn "dpkg still reports an audit finding; do not reboot/respring"
        exit 1
    fi
    echo "[ok] dpkg database has no audit findings"

    chown -R 501:501 "$BACKUP" 2>/dev/null || true
    echo
    echo "[ok] dependency recovery completed"
    echo "[backup] $BACKUP"
    echo "[log] $LOG"
    echo "[safe] No reboot or respring was forced."
    echo "[next] Return to the Home Screen and open Cydia manually."
} 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
    echo
    echo "== Cydia recovery error summary (complete log: $LOG) =="
    grep -nE '\[FAIL\]|(^|: )[[:space:]]*(fatal )?error:|dpkg: error|dependency problems|not configured|No such file|Permission denied' "$LOG" || true
    exit "$status"
fi
