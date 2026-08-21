#!/var/jb/bin/bash
set -euo pipefail
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

CYDIA_CACHE="/var/mobile/Library/Caches/com.saurik.Cydia"

echo "== Cydia rootless / repository + transaction safety preflight =="
echo "[policy] blocked legacy rootful package: firmware-sbin"
echo "[policy] reason: Architecture: all does not make it rootless; its maintainer script writes to /sbin"
echo "[policy] Cydia source configuration is preserved; malformed package indexes are quarantined only in Cydia's private cache"

echo
if [[ -d "$CYDIA_CACHE/lists" ]]; then
    echo "[Cydia cached malformed/quarantined indexes]"
    found=0
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        found=1
        echo "  $f"
    done < <(find "$CYDIA_CACHE/lists" -maxdepth 1 -type f -name '*_Packages.cydia-invalid' -print 2>/dev/null | sort || true)
    [[ $found -eq 1 ]] || echo "  none"
else
    echo "[Cydia cache] lists directory does not exist yet; next Refresh will create it"
fi

echo
if grep -RniE 'tools4cydia|diatr\.us' /var/jb/etc/apt/sources.list /var/jb/etc/apt/sources.list.d 2>/dev/null; then
    echo "[info] matching bootstrap/Sileo sources shown above are NOT modified by Cydia"
else
    echo "[info] no tools4cydia/diatr source entry found in bootstrap source files"
fi

echo
if dpkg-query -W -f='${Status} ${Version} ${Architecture}\n' firmware-sbin >/tmp/cydia-rootless-firmware-sbin.txt 2>/dev/null; then
    echo -n "[installed firmware-sbin] "
    cat /tmp/cydia-rootless-firmware-sbin.txt
    echo "[warn] already-installed firmware-sbin remains visible so it can be removed; Cydia will never queue a rootful repository candidate"
else
    echo "[ok] firmware-sbin is not installed"
fi
rm -f /tmp/cydia-rootless-firmware-sbin.txt

echo "[ok] rootless safety preflight completed"
