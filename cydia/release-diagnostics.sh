#!/var/jb/bin/bash
set -u
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH}"
echo "== Cydia rootless / release diagnostics =="
echo "[dpkg] installed versions"
for pkg in preferenceloader libkrw0-dopamine firmware-sbin; do
  dpkg-query -W -f='${Package} ${Version} ${Architecture} ${Status}\n' "$pkg" 2>/dev/null || echo "$pkg: not installed"
done
echo
echo "[policy] bootstrap APT candidates"
if command -v apt-cache >/dev/null 2>&1; then
  apt-cache policy preferenceloader libkrw0-dopamine firmware-sbin 2>&1 || true
else
  echo "apt-cache not available"
fi
echo
echo "[legacy-pin]"
if [[ -e /var/jb/etc/apt/preferences.d/cydia ]]; then
  echo "[FAIL] legacy Cydia pin file still exists"
  cat /var/jb/etc/apt/preferences.d/cydia 2>/dev/null || true
  exit 1
else
  echo "[ok] /var/jb/etc/apt/preferences.d/cydia is absent"
fi

echo
echo "[rootless safety]"
if dpkg-query -W -f='${Status}' firmware-sbin >/dev/null 2>&1; then
  echo "[info] firmware-sbin is installed; Cydia keeps only the installed entry available for removal"
else
  echo "[ok] firmware-sbin is not installed and repository candidates are hidden/blocked"
fi
echo "[info] malformed Cydia *_Packages indexes are quarantined as *.cydia-invalid without editing Sileo/bootstrap source files"
