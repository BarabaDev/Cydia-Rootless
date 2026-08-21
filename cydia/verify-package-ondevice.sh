#!/var/jb/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH}"

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

[[ -e Cydia.deb ]] || fail "Cydia.deb was not produced"
[[ -e Cydia_.deb ]] || fail "Cydia_.deb was not produced"

echo "== Cydia rootless package verification =="

expected_version="$(./version.sh)"

echo "[control] main package"
dpkg-deb -f Cydia.deb Package Version Architecture Depends

package="$(dpkg-deb -f Cydia.deb Package)"
version="$(dpkg-deb -f Cydia.deb Version)"
arch="$(dpkg-deb -f Cydia.deb Architecture)"
[[ "$package" == "cydia" ]] || fail "unexpected main Package: $package"
[[ "$version" == "$expected_version" ]] || fail "unexpected main Version: $version (expected $expected_version)"
[[ "$arch" == "iphoneos-arm64" ]] || fail "unexpected Architecture: $arch"
depends="$(dpkg-deb -f Cydia.deb Depends)"
if grep -Fq "org.thebigboss.repo.icons" <<<"$depends"; then
    fail "legacy org.thebigboss.repo.icons dependency is still present"
fi
echo "[ok] legacy BigBoss icon dependency is absent"
if ! grep -Eq '(^|,)[[:space:]]*libgnutls30([[:space:]]|,|$)' <<<"$depends"; then
    fail "required libgnutls30 runtime dependency is missing"
fi
echo "[ok] embedded APT HTTP GnuTLS runtime dependency is declared"
if ! grep -Eq '(^|,)[[:space:]]*xz-utils[[:space:]]*\|[[:space:]]*xz([[:space:]]|,|$)' <<<"$depends"; then
    fail "Procursus-compatible XZ dependency alternative is missing"
fi
echo "[ok] Procursus xz-utils dependency is declared with legacy xz fallback"

echo
echo "[mach-o] checking rootless runtime library search path"
[[ -e MobileCydia ]] || fail "MobileCydia build output is missing"
if ! otool -l MobileCydia | grep -A3 'cmd LC_RPATH' | grep -Fq 'path /var/jb/usr/lib '; then
    fail "MobileCydia is missing LC_RPATH /var/jb/usr/lib"
fi
echo "[ok] LC_RPATH /var/jb/usr/lib is embedded for @rpath Procursus libraries"

echo
echo "[control] translation package"
dpkg-deb -f Cydia_.deb Package Version Architecture Depends
lproj_package="$(dpkg-deb -f Cydia_.deb Package)"
lproj_version="$(dpkg-deb -f Cydia_.deb Version)"
lproj_arch="$(dpkg-deb -f Cydia_.deb Architecture)"
[[ "$lproj_package" == "cydia-lproj" ]] || fail "unexpected translation Package: $lproj_package"
[[ "$lproj_version" == "$expected_version" ]] || fail "unexpected translation Version: $lproj_version (expected $expected_version)"
[[ "$lproj_arch" == "iphoneos-arm64" ]] || fail "unexpected translation Architecture: $lproj_arch"
echo "[ok] both packages use exact release version and rootless architecture"

echo
echo "[payload] checking required rootless files"
contents="$(dpkg-deb -c Cydia.deb)"
lproj_contents="$(dpkg-deb -c Cydia_.deb)"
for required in \
    './var/jb/Applications/Cydia.app/Cydia' \
    './var/jb/usr/libexec/cydia/cydo' \
    './var/jb/usr/libexec/cydia/firmware.sh' \
    './var/jb/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist'
do
    grep -Fq "$required" <<<"$contents" || fail "missing payload: $required"
    echo "[ok] $required"
done

if grep -Fq './var/jb/etc/apt/preferences.d/cydia' <<<"$contents"; then
    fail "legacy Cydia APT pin file is still packaged"
fi
echo "[ok] no legacy Cydia APT pin file is packaged"


echo
echo "[trust] verifying minimal public Cydia trust store"
for required_key in bigboss.gpg; do
    grep -Fq "./var/jb/etc/apt/trusted.gpg.d/${required_key}" <<<"$contents" || \
        fail "missing required trusted key: ${required_key}"
    echo "[ok] ${required_key}"
done
for removed_key in saurik.gpg sbingner.gpg zodttd.gpg modmyi.gpg hbang.gpg; do
    if grep -Fq "${removed_key}" <<<"$contents"; then
        fail "unused/obsolete trusted key is still packaged: ${removed_key}"
    fi
done
echo "[ok] unused and obsolete trusted keys are absent"

echo
echo "[payload] checking for accidental rootful jailbreak install paths"
if grep -Eq ' \./(Applications|Library|usr|etc|bin|sbin)(/|$)| \./var/(lib|cache|log)(/|$)' <<<"$contents"; then
    echo "$contents" | grep -E ' \./(Applications|Library|usr|etc|bin|sbin)(/|$)| \./var/(lib|cache|log)(/|$)' || true
    fail "rootful payload path detected"
fi
echo "[ok] package payload is rooted under /var/jb where required"
if grep -Eq ' \./(Applications|Library|usr|etc|bin|sbin)(/|$)| \./var/(lib|cache|log)(/|$)' <<<"$lproj_contents"; then
    echo "$lproj_contents" | grep -E ' \./(Applications|Library|usr|etc|bin|sbin)(/|$)| \./var/(lib|cache|log)(/|$)' || true
    fail "rootful translation payload path detected"
fi
echo "[ok] translation payload is rooted under /var/jb"

if ! grep -Eq '^-rwsr-sr-x .* \./var/jb/usr/libexec/cydia/cydo$' <<<"$contents"; then
    echo "$contents" | grep '/var/jb/usr/libexec/cydia/cydo$' || true
    fail "cydo is not packaged root:root mode 6755"
fi
echo "[ok] cydo mode 6755 retained"

echo
echo "[sources] verifying package does not install/overwrite a default cydia.list"
if grep -Fq './var/jb/etc/apt/sources.list.d/cydia.list' <<<"$contents"; then
    fail "package still contains a hardcoded cydia.list payload"
fi
tmpctl="$(mktemp -d /tmp/cydia-rootless-control.XXXXXX)"
trap 'rm -rf "$tmpctl"' EXIT
dpkg-deb -e Cydia.deb "$tmpctl"
[[ -x "$tmpctl/preinst" ]] || fail "DEBIAN/preinst is not executable"
[[ -x "$tmpctl/postinst" ]] || fail "DEBIAN/postinst is not executable"
echo "[ok] maintainer scripts are executable"
if grep -RIEq 'apt\.bingner\.com|apt\.thebigboss\.org|cydia\.zodttd\.com|modmyi\.saurik\.com|repo\.dynastic\.co|repo\.chariz\.com' "$tmpctl"; then
    grep -RInE 'apt\.bingner\.com|apt\.thebigboss\.org|cydia\.zodttd\.com|modmyi\.saurik\.com|repo\.dynastic\.co|repo\.chariz\.com' "$tmpctl" || true
    fail "maintainer scripts still hardcode repository URLs"
fi
echo "[ok] existing bootstrap/Sileo APT sources will be preserved"

echo
echo "[size]"
ls -lh Cydia.deb Cydia_.deb

echo
echo "[ok] package structure verification passed"
