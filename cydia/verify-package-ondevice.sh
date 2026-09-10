#!/var/jb/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH}"

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

[[ -e Cydia.deb ]] || fail "Cydia.deb was not produced"

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
[[ "$(dpkg-deb -f Cydia.deb Icon)" == 'https://barabadev.com/assets/cydia.png' ]] || \
    fail "pre-install repository icon URL is missing"
echo "[ok] package advertises its HTTPS icon for display before installation"
depends="$(dpkg-deb -f Cydia.deb Depends)"
if grep -Eq '(^|,)[[:space:]]*cydia-lproj([[:space:]]|,|$)' <<<"$depends"; then
    fail "obsolete separate cydia-lproj dependency remains"
fi
echo "[ok] translations are self-contained in the main package"
replaces="$(dpkg-deb -f Cydia.deb Replaces)"
conflicts="$(dpkg-deb -f Cydia.deb Conflicts)"
grep -Fq 'cydia-lproj (<= 1.1.22)' <<<"$replaces" || \
    fail "merged package cannot replace an installed cydia-lproj 1.1.22"
grep -Fq 'cydia-lproj (<= 1.1.22)' <<<"$conflicts" || \
    fail "installed cydia-lproj 1.1.22 is not removed during migration"
echo "[ok] existing separate translation package migrates safely into Cydia"
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
for compressor in bzip2 gzip lz4 zstd; do
    if ! grep -Eq "(^|,)[[:space:]]*${compressor}([[:space:]]|,|$)" <<<"$depends"; then
        fail "required Packages index decompressor dependency is missing: $compressor"
    fi
done
echo "[ok] bz2, gzip, lz4, zstd and xz Packages index runtimes are declared"

echo
echo "[mach-o] checking rootless runtime library search path"
[[ -e MobileCydia ]] || fail "MobileCydia build output is missing"
for runtime_binary in MobileCydia cydo; do
    [[ -f "$runtime_binary" ]] || fail "runtime build output is missing: $runtime_binary"
    ! LC_ALL=C grep -aFq 'Cydia_Rootless_Diagnostics.log' "$runtime_binary" || \
        fail "removed diagnostic filename remains in runtime binary: $runtime_binary"
done
echo "[ok] application and privileged helper contain no runtime diagnostic filename"
if ! otool -l MobileCydia | grep -A3 'cmd LC_RPATH' | grep -Fq 'path /var/jb/usr/lib '; then
    fail "MobileCydia is missing LC_RPATH /var/jb/usr/lib"
fi
echo "[ok] LC_RPATH /var/jb/usr/lib is embedded for @rpath Procursus libraries"

echo "[ok] package uses the exact release version and rootless architecture"

echo
echo "[payload] checking required rootless files"
contents="$(dpkg-deb -c Cydia.deb)"
if grep -Eq '(^|/)([.]DS_Store|[.]AppleDouble|[.]_[^/[:space:]]+)([[:space:]]|$)' <<<"$contents"; then
    fail "macOS Finder metadata is packaged"
fi
echo "[ok] package contains no macOS Finder metadata"
while IFS= read -r entry; do
    mode="${entry%% *}"
    case "$mode" in
        d*) [[ "$mode" == drwxr-xr-x ]] || fail "application directory has invalid access permissions: $entry" ;;
        -*)
            if [[ "$entry" == *' ./var/jb/Applications/Cydia.app/Cydia' ]]; then
                [[ "$mode" == -rwxr-xr-x ]] || fail "Cydia executable has invalid access permissions: $entry"
            else
                [[ "$mode" == -rw-r--r-- ]] || fail "application resource is not readable by iOS: $entry"
            fi
            ;;
    esac
done < <(grep -F ' ./var/jb/Applications/Cydia.app/' <<<"$contents")
echo "[ok] Cydia executable, Info.plist and all bundle resources have public read/traverse permissions"
for required in \
    './var/jb/Applications/Cydia.app/Cydia' \
    './var/jb/Applications/Cydia.app/COPYING' \
    './var/jb/Applications/Cydia.app/Licenses/NOTICES.txt' \
    './var/jb/Applications/Cydia.app/Licenses/AGPL-3.0.txt' \
    './var/jb/Applications/Cydia.app/Licenses/GPL-2.0.txt' \
    './var/jb/usr/libexec/cydia/cydo' \
    './var/jb/usr/libexec/cydia/firmware.sh' \
    './var/jb/usr/share/doc/cydia/COPYING' \
    './var/jb/usr/share/doc/cydia/Licenses/NOTICES.txt' \
    './var/jb/usr/share/doc/cydia/Licenses/AGPL-3.0.txt' \
    './var/jb/usr/share/doc/cydia/Licenses/GPL-2.0.txt' \
    './var/jb/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist'
do
    grep -Fq "$required" <<<"$contents" || fail "missing payload: $required"
    echo "[ok] $required"
done
echo "[ok] full GPL, AGPL and component notices are included in the main package"

localizations=(
    ar de el en es fr he it ja ko nl pl pt-PT pt ru sv th tr vi zh-Hans zh-Hant
)
for locale in "${localizations[@]}"; do
    grep -Fq "./var/jb/Applications/Cydia.app/$locale.lproj/Localizable.strings" <<<"$contents" || \
        fail "missing bundled localization: $locale"
    grep -Fq "./var/jb/Applications/Cydia.app/$locale.lproj/InfoPlist.strings" <<<"$contents" || \
        fail "missing localized Face ID description: $locale"
done
for locale in ar de el es fr he it ja ko nl pl pt-PT pt ru sv th tr vi zh-Hans zh-Hant; do
    grep -Fq "./var/jb/Applications/Cydia.app/$locale.lproj/Sections.strings" <<<"$contents" || \
        fail "missing packaged section localization: $locale"
done
packaged_localization_count="$(grep -Eo '\./var/jb/Applications/Cydia\.app/[^/[:space:]]+\.lproj/' \
    <<<"$contents" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
[[ "$packaged_localization_count" == "${#localizations[@]}" ]] || \
    fail "unexpected packaged localization count: $packaged_localization_count"
if grep -Eq '\./var/jb/Applications/Cydia\.app/en\.lproj/Sections_?\.strings' <<<"$contents"; then
    fail "redundant English section translation table is packaged"
fi
packaged_translation_table_count="$(grep -Eo '\./var/jb/Applications/Cydia\.app/[^/[:space:]]+\.lproj/[^/[:space:]]+\.strings' \
    <<<"$contents" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
[[ "$packaged_translation_table_count" == 62 ]] || \
    fail "unexpected packaged translation table count: $packaged_translation_table_count"
echo "[ok] all 21 retained localizations and exactly 62 active translation tables are bundled"

retired_app_artwork=(
    iconClassic.png unknown.png chevron@2x.png compose.png configure.png
    folder.png folder@2x.png reload.png home-Selected.png home-Selected@2x.png
    home.png home@2x.png home7.png home7@2x.png home7@3x.png
    home7s.png home7s@2x.png home7s@3x.png
    install.png install@2x.png install7.png install7@2x.png install7@3x.png
    install7s.png install7s@2x.png install7s@3x.png
    changes.png changes@2x.png changes7.png changes7@2x.png changes7@3x.png
    changes7s.png changes7s@2x.png changes7s@3x.png
    manage.png manage@2x.png manage7.png manage7@2x.png manage7@3x.png
    manage7s.png manage7s@2x.png manage7s@3x.png
    search.png search@2x.png search7.png search7@2x.png search7@3x.png
    search7s.png search7s@2x.png search7s@3x.png
)
for artwork in "${retired_app_artwork[@]}"; do
    if grep -Fq "./var/jb/Applications/Cydia.app/$artwork" <<<"$contents"; then
        fail "unused pre-iOS-15 artwork is packaged: $artwork"
    fi
done
echo "[ok] package contains no retired tab or fallback artwork"

for method in bzip2 gzip lzma xz zstd lz4 store; do
    grep -Fq "./var/jb/Applications/Cydia.app/$method" <<<"$contents" || \
        fail "missing compressed-index acquire method: $method"
done
echo "[ok] all compressed-index acquire method aliases are packaged"

if grep -Fq './var/jb/etc/apt/preferences.d/cydia' <<<"$contents"; then
    fail "legacy Cydia APT pin file is still packaged"
fi
echo "[ok] no legacy Cydia APT pin file is packaged"

echo
echo "[artwork] checking exact section icon payload"
section_icon_files=(
    Addons.png Administration.png Archiving.png Books.png Carrier_Bundles.png
    Data_Storage.png Development.png Dictionaries.png Education.png Entertainment.png
    Fonts.png Games.png Health_and_Fitness.png Java.png Keyboards.png Localization.png
    Messaging.png Multimedia.png Navigation.png Networking.png Packaging.png Productivity.png
    Repositories.png Ringtones.png Scripting.png Security.png Site-Specific_Apps.png
    Social.png Soundboards.png System.png Terminal_Support.png Text_Editors.png Themes.png
    Toys.png Tweaks.png Utilities.png Wallpaper.png Widgets.png X_Window.png
    Default.png
)
for icon in "${section_icon_files[@]}"; do
    grep -Fq "./var/jb/Applications/Cydia.app/Sections/$icon" <<<"$contents" || \
        fail "missing packaged section artwork: $icon"
done
expected_section_icons="$(printf '%s\n' "${section_icon_files[@]}" | LC_ALL=C sort)"
packaged_section_icons="$(grep -Eo '\./var/jb/Applications/Cydia\.app/Sections/[^/[:space:]]+\.png' \
    <<<"$contents" | sed 's#^.*/##' | LC_ALL=C sort -u)"
[[ "$packaged_section_icons" == "$expected_section_icons" ]] || \
    fail "packaged section artwork does not contain the exact 40-file icon set"
echo "[ok] exact 39 section icons and Default fallback are packaged"

grep -Fq "./var/jb/Applications/Cydia.app/LaunchScreen.storyboardc/Info.plist" <<<"$contents" || \
    fail "compiled modern launch screen is missing from the package"
echo "[ok] adaptive native launch screen is packaged"


echo
echo "[sources] verifying keyless repository packaging"
if grep -Fq "./var/jb/etc/apt/trusted.gpg" <<<"$contents"; then
    fail "obsolete Cydia-managed repository signing key is still packaged"
fi
echo "[ok] no Cydia-managed repository signing keys are packaged"

echo
echo "[payload] checking for accidental rootful jailbreak install paths"
if grep -Eq ' \./(Applications|Library|usr|etc|bin|sbin)(/|$)| \./var/(lib|cache|log)(/|$)' <<<"$contents"; then
    echo "$contents" | grep -E ' \./(Applications|Library|usr|etc|bin|sbin)(/|$)| \./var/(lib|cache|log)(/|$)' || true
    fail "rootful payload path detected"
fi
echo "[ok] package payload is rooted under /var/jb where required"

echo
echo "[appearance] checking packaged Cydia.app Info.plist"
tmppayload="$(mktemp -d /tmp/cydia-rootless-payload.XXXXXX)"
tmpctl=""
cleanup() {
    rm -rf "$tmppayload"
    [[ -z "$tmpctl" ]] || rm -rf "$tmpctl"
}
trap cleanup EXIT
packaged_plist="$tmppayload/var/jb/Applications/Cydia.app/Info.plist"
if [[ "$(uname -s)" == "Darwin" ]]; then
    mkdir -p "$(dirname "$packaged_plist")"
    dpkg-deb --fsys-tarfile Cydia.deb | gtar -xOf - ./var/jb/Applications/Cydia.app/Info.plist >"$packaged_plist"
else
    dpkg-deb -x Cydia.deb "$tmppayload"
fi
[[ -f "$packaged_plist" ]] || fail "packaged Cydia.app Info.plist is missing"
grep -A1 '<key>CFBundleShortVersionString</key>' "$packaged_plist" | grep -Fq '<string>1.1.30</string>' || \
    fail "packaged Cydia.app public version is not 1.1.30"
grep -A1 '<key>CFBundleVersion</key>' "$packaged_plist" | grep -Fq '<string>1.1.30</string>' || \
    fail "packaged Cydia.app does not select final bundle version 1.1.30"
! grep -Fq '<key>UIUserInterfaceStyle</key>' "$packaged_plist" || \
    fail "packaged Cydia.app still forces a fixed interface style"
grep -A1 '<key>UILaunchStoryboardName</key>' "$packaged_plist" | grep -Fq '<string>LaunchScreen</string>' || \
    fail "packaged Cydia.app does not select the adaptive native launch screen"
! grep -Fq '<key>UILaunchImages</key>' "$packaged_plist" || \
    fail "packaged Cydia.app still selects legacy fixed-size launch images"
echo "[ok] packaged Cydia.app is public version 1.1.30, final bundle version 1.1.30, with automatic Light/Dark appearance"

if ! grep -Eq '^-rwsr-sr-x .* \./var/jb/usr/libexec/cydia/cydo$' <<<"$contents"; then
    echo "$contents" | grep '/var/jb/usr/libexec/cydia/cydo$' || true
    fail "cydo is not packaged root:root mode 6755"
fi
echo "[ok] cydo mode 6755 retained"

echo
echo "[hardening] checking runtime scripts and package symlinks"
if grep -Eq 'rm[[:space:]]+-rf[[:space:]]+/User|ln[[:space:]].*[[:space:]]/User([[:space:]]|$)' Library/firmware.sh; then
    fail "legacy /User rootfs mutation is present in firmware.sh"
fi
echo "[ok] firmware metadata refresh does not mutate legacy /User/rootfs"
for runtime_script in firmware.sh startup finish.sh asuser; do
    grep -Fq "./var/jb/usr/libexec/cydia/${runtime_script}" <<<"$contents" || fail "missing runtime helper: ${runtime_script}"
done
echo "[ok] expected Cydia runtime helper scripts are packaged"
for retired_script in free.sh move.sh; do
    ! grep -Fq "./var/jb/usr/libexec/cydia/${retired_script}" <<<"$contents" || fail "retired rootful stashing helper is packaged: ${retired_script}"
done
echo "[ok] retired rootful stashing helpers are absent"
if grep -E ' -> /(Applications|Library|usr|etc|bin|sbin)(/|$)' <<<"$contents"; then
    fail "package contains a symlink targeting a rootful jailbreak path"
fi
echo "[ok] package contains no rootful jailbreak symlink targets"

echo
echo "[sources] verifying package does not install/overwrite a default cydia.list"
if grep -Fq './var/jb/etc/apt/sources.list.d/cydia.list' <<<"$contents"; then
    fail "package still contains a hardcoded cydia.list payload"
fi
tmpctl="$(mktemp -d /tmp/cydia-rootless-control.XXXXXX)"
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
ls -lh Cydia.deb

echo
echo "[ok] package structure verification passed"
