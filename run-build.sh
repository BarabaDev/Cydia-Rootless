#!/var/jb/bin/bash
set -euo pipefail
cd "$(dirname "$0")/cydia"

echo "== Cydia iOS 15+ Rootless PUBLIC RELEASE =="
release_version="$(./version.sh)"
if [[ "$release_version" != "1.1.49+rootless.3" ]]; then
    echo "[FAIL] public release version mismatch: $release_version" >&2
    exit 1
fi
printf '%s\n' "[ok] public release version: $release_version"

./rootless-safety-preflight.sh
./rootless-architecture-preflight.sh

build_source="MobileCydia.mm"
for required in \
    '#include <apt-pkg/gpgv.h>' \
    'dindex->MetaIndexFile("InRelease")' \
    'OpenMaybeClearSignedFile(metadataPath, fd)' \
    'static bool CYSetPackageSelection(NSString *name, bool hold)' \
    '--cleanup-legacy-source-link' \
    'setenv("SILEO", [controlProtocol UTF8String], _not(int))' \
    'finish isEqualToString:@"usreboot"' \
    'static int RebootMode_' \
    'execution=userspace' \
    '"/var/jb/bin/launchctl"' \
    'const_cast<char *>("userspace")' \
    'refusing full-reboot fallback'; do
    if ! grep -Fq -- "$required" "$build_source"; then
        echo "[FAIL] required release marker missing: $required" >&2
        exit 1
    fi
done
if grep -Fq '/var/jb/bin/ln -sf %@ /var/jb/etc/apt/sources.list.d/cydia.list' "$build_source"; then
    echo "[FAIL] duplicate legacy cydia.list publisher is still active" >&2
    exit 1
fi
printf '%s\n' "[ok] Source Release/InRelease metadata naming retained"
printf '%s\n' "[ok] one managed source list retained; legacy duplicate symlink removed safely"
printf '%s\n' "[ok] Ignore Upgrades hold/unhold retained"
printf '%s\n' "[ok] CYDIA+SILEO finish-control bridge retained"
printf '%s\n' "[ok] Reboot Device finish priority retained"
printf '%s\n' "[ok] finish:usreboot executes launchctl reboot userspace via cydo"
printf '%s\n' "[ok] explicit finish:reboot remains a full reboot"

for key in bigboss.gpg; do
    [[ -f "Trusted.gpg/$key" ]] || { echo "[FAIL] required trusted key missing: $key" >&2; exit 1; }
done
for key in saurik.gpg sbingner.gpg zodttd.gpg modmyi.gpg hbang.gpg; do
    [[ ! -e "Trusted.gpg/$key" ]] || { echo "[FAIL] unused/obsolete trusted key still present: $key" >&2; exit 1; }
done
[[ ! -d Sources.list ]] || { echo "[FAIL] obsolete hardcoded Sources.list directory still present" >&2; exit 1; }
[[ ! -e cydia.preferences ]] || { echo "[FAIL] obsolete Cydia APT pin template still present" >&2; exit 1; }
[[ -x release-diagnostics.sh ]] || { echo "[FAIL] release-diagnostics.sh is not executable" >&2; exit 1; }
for public_file in ../README.md ../RELEASE_NOTES.md ../GITHUB-RELEASE.md ../START-HERE.txt ../LICENSE ../.gitignore; do
    [[ -f "$public_file" ]] || { echo "[FAIL] missing public GitHub file: $public_file" >&2; exit 1; }
done
grep -A1 '<key>MinimumOSVersion</key>' MobileCydia.app/Info.plist | grep -Fq '<string>15.0</string>' || {
    echo "[FAIL] MobileCydia.app MinimumOSVersion is not 15.0" >&2
    exit 1
}
grep -Fq 'firmware (>= 15.0)' cydia.control || { echo "[FAIL] Debian firmware minimum is not iOS 15.0" >&2; exit 1; }
grep -Fq 'perl ../apt64/triehash/triehash.pl' makefile.ondevice || {
    echo "[FAIL] triehash generator is not using rootless Perl from PATH" >&2
    exit 1
}
grep -Fq 'libs += -lgnutls' makefile.ondevice || {
    echo "[FAIL] embedded APT HTTP method is not linked with GnuTLS" >&2
    exit 1
}
grep -Fq 'libgnutls30' cydia.control || {
    echo "[FAIL] Cydia package is missing its GnuTLS runtime dependency" >&2
    exit 1
}
grep -Fq 'xz-utils | xz' cydia.control || {
    echo "[FAIL] Cydia package is missing its Procursus-compatible XZ dependency" >&2
    exit 1
}
grep -Fq 'link += -Wl,-rpath,$(rootless_prefix)/usr/lib' makefile.ondevice || {
    echo "[FAIL] rootless Mach-O runtime library path is missing" >&2
    exit 1
}
printf '%s\n' "[ok] minimal public trust store retained: BigBoss only"
printf '%s\n' "[ok] no bundled default repository list retained"
printf '%s\n' "[ok] GitHub public files, permissions and iOS 15 metadata verified"
printf '%s\n' "[ok] APT triehash generator uses rootless Perl explicitly"
printf '%s\n' "[ok] embedded APT HTTP method uses declared GnuTLS build/runtime dependencies"
printf '%s\n' "[ok] Procursus xz-utils dependency and legacy xz fallback verified"
printf '%s\n' "[ok] rootless Mach-O runtime path /var/jb/usr/lib retained"

./build-ondevice.sh
./package-ondevice.sh
./runtime-methods-preflight.sh
./runtime-update-ondevice.sh
./release-diagnostics.sh

printf '%s\n' "[diagnostics] Persistent log: /var/mobile/Documents/Cydia_Rootless_Diagnostics.log"
printf '%s\n' "[done] Public release build/package/install completed"
