#!/var/jb/bin/bash
set -euo pipefail
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

echo "== Cydia rootless / architecture preflight =="

native="$(dpkg --print-architecture 2>/dev/null || true)"
foreign="$(dpkg --print-foreign-architectures 2>/dev/null || true)"

echo "[dpkg] native architecture: ${native:-unknown}"
if [[ -n "$foreign" ]]; then
    echo "[dpkg] foreign architectures:"
    while IFS= read -r arch; do
        [[ -n "$arch" ]] && echo "        $arch"
    done <<<"$foreign"
else
    echo "[dpkg] foreign architectures: none"
fi

if [[ "$native" != "iphoneos-arm64" ]]; then
    echo "[warn] bootstrap native architecture is '$native'; public Cydia intentionally indexes only iphoneos-arm64/rootless packages"
else
    echo "[ok] bootstrap native architecture is iphoneos-arm64"
fi

if grep -qx 'iphoneos-arm' <<<"$foreign"; then
    echo "[info] iphoneos-arm is registered as a foreign/rootful compatibility architecture"
    echo "[info] Cydia excludes it so rootful and rootless variants are not shown together"
fi

if command -v apt-config >/dev/null 2>&1; then
    echo
    echo "[bootstrap apt architecture config]"
    apt-config dump 2>/dev/null | grep -E '^APT::Architecture(s)?' || true
fi

echo
cat <<'MSG'
[Cydia policy]
  native: iphoneos-arm64
  indexed package variants: iphoneos-arm64 + Architecture: all
  excluded from Cydia: iphoneos-arm (rootful)
  blocked legacy Architecture: all rootful transition package: firmware-sbin
MSG

echo "[ok] architecture preflight completed"
