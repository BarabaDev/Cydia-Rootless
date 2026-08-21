#!/var/jb/bin/bash
set -u
cd "$(dirname "$0")"
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH}"

LOG="$PWD/Cydia_Rootless_Diagnosis.log"
rm -f "$LOG"

status_line() {
    local pkg="$1"
    if dpkg-query -W -f='${db:Status-Abbrev} ${Status} ${Version}\n' "$pkg" 2>/dev/null; then
        return 0
    fi
    echo "--- package not present in dpkg database ---"
}

check_pkg() {
    local pkg="$1"
    local want_op="${2:-}"
    local want_ver="${3:-}"
    local status ver
    status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
    ver="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
    if [[ "$status" != "install ok installed" ]]; then
        echo "[NOT-SATISFIED] $pkg status='${status:-not installed}' version='${ver:-none}'"
        return 1
    fi
    if [[ -n "$want_op" && -n "$want_ver" ]]; then
        local ok=1
        case "$want_op" in
            '>=' ) dpkg --compare-versions "$ver" ge "$want_ver" || ok=0 ;;
            '<=' ) dpkg --compare-versions "$ver" le "$want_ver" || ok=0 ;;
            '>>'|'>' ) dpkg --compare-versions "$ver" gt "$want_ver" || ok=0 ;;
            '<<'|'<' ) dpkg --compare-versions "$ver" lt "$want_ver" || ok=0 ;;
            '=' ) dpkg --compare-versions "$ver" eq "$want_ver" || ok=0 ;;
        esac
        if [[ "$ok" -ne 1 ]]; then
            echo "[NOT-SATISFIED] $pkg installed=$ver requires '$want_op $want_ver'"
            return 1
        fi
    fi
    echo "[ok] $pkg $ver"
    return 0
}

{
    echo "== Cydia rootless / FAILED-INSTALL DEPENDENCY DIAGNOSIS =="
    echo "[safe] Read-only diagnosis. This script does not install, remove, configure, respring, or reboot."
    echo "[time] $(date)"
    echo "[uid] $(id -u)"
    echo "[arch] $(dpkg --print-architecture 2>/dev/null || true)"
    echo

    echo "[package state] cydia"
    status_line cydia
    echo "[package state] cydia-lproj"
    status_line cydia-lproj
    echo

    echo "[dpkg --audit]"
    dpkg --audit 2>&1 || true
    echo

    echo "[dependency candidates from package control]"
    # These are exactly the dependencies in the package that was attempted.
    check_pkg firmware '>=' '5.0' || true
    check_pkg dpkg '>=' '1.19.1' || true
    check_pkg debianutils || true
    check_pkg darwintools || true
    check_pkg sed || true
    check_pkg shell-cmds || true
    check_pkg system-cmds || true
    check_pkg uikittools '>=' '1.1.14' || true
    check_pkg xz-utils || check_pkg xz || true
    check_pkg org.thebigboss.repo.icons || true
    echo "[finding] This device does not provide org.thebigboss.repo.icons; the public rootless package removes that legacy metadata dependency."
    echo "[local-pair] cydia-lproj is supplied by Cydia_.deb; its status is shown above"
    echo

    echo "[exact dry-run configure: cydia]"
    dpkg --no-act --configure cydia 2>&1 || true
    echo
    echo "[exact dry-run configure: cydia-lproj]"
    dpkg --no-act --configure cydia-lproj 2>&1 || true
    echo

    echo "[installed stanzas]"
    dpkg-query -s cydia 2>/dev/null | sed -n '1,80p' || true
    echo "---"
    dpkg-query -s cydia-lproj 2>/dev/null | sed -n '1,80p' || true
    echo

    echo "[payload presence after failed install]"
    for p in \
        /var/jb/Applications/Cydia.app/Cydia \
        /var/jb/usr/libexec/cydia/cydo \
        /var/jb/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist \
        /var/jb/etc/apt/preferences.d/cydia; do
        if [[ -e "$p" || -L "$p" ]]; then
            echo "[present] $p"
        else
            echo "[absent]  $p"
        fi
    done
    echo

    echo "[recent Cydia backup]"
    ls -1dt /var/mobile/Documents/Cydia_Rootless_BACKUP_* 2>/dev/null | head -n 3 || true
    echo

    echo "[next] Send the final diagnosis screen. Do not run apt -f install and do not reboot/respring yet."
} 2>&1 | tee "$LOG"
