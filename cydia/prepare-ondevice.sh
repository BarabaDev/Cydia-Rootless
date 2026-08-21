#!/var/jb/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH}"

BUILD_FLAVOR="PUBLIC"
PINNED_APT_COMMIT="e4718f05d049c1a09fb9662cc3db2d4c5122defe"
APT_HTTPS_URL="https://git.bingner.com/apt.git"
APT_MARKER=".cydia-pinned-apt-commit"

echo "== Cydia rootless ${BUILD_FLAVOR} / on-device preparation =="

missing=0
for tool in clang clang++ make ldid fakeroot dpkg-deb ar git perl sed find install_name_tool tar; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '[ok]   %-18s %s\n' "$tool" "$(command -v "$tool")"
    else
        printf '[miss] %s\n' "$tool"
        missing=1
    fi
done

if [[ $missing -ne 0 ]]; then
    echo
    echo "Missing required compiler/build tools. Install the missing Procursus development packages, then run this script again."
    exit 10
fi

# The pinned APT HTTP connection unit uses GnuTLS directly. Procursus keeps
# runtime libraries and development headers/symlinks in separate packages, so
# apt/libgnutls30 alone is not enough to compile and link this embedded method.
if [[ ! -f /var/jb/usr/include/gnutls/gnutls.h || ! -e /var/jb/usr/lib/libgnutls.dylib ]]; then
    echo
    echo "[miss] Procursus GnuTLS development files"
    echo "Required package: libgnutls30-dev"
    echo "Install it, then run ./run-build.sh again:"
    echo "  sudo apt-get install libgnutls30-dev"
    exit 10
fi
echo "[ok]   GnuTLS headers/linker library (libgnutls30-dev)"

is_cydia_apt_tree() {
    local src="$1"
    [[ -d "$src/apt-pkg" ]] || return 1
    [[ -d "$src/apt-pkg/deb" ]] || return 1
    [[ -d "$src/apt-pkg/contrib" ]] || return 1
    [[ -d "$src/methods" ]] || return 1
    [[ -f "$src/methods/aptmethod.h" ]] || return 1
    [[ -f "$src/methods/http.cc" ]] || return 1
    [[ -f "$src/methods/http.h" ]] || return 1
    [[ -f "$src/methods/basehttp.cc" ]] || return 1
    [[ -f "$src/methods/connect.cc" ]] || return 1
    [[ -f "$src/methods/rfc2553emu.cc" ]] || return 1
    [[ -f "$src/methods/store.cc" ]] || return 1
    [[ -f "$src/apt-pkg/tagfile-keys.list" ]] || return 1
    [[ -f "$src/triehash/triehash.pl" ]] || return 1
    return 0
}

is_pinned_import() {
    is_cydia_apt_tree apt64 || return 1
    [[ -f "apt64/$APT_MARKER" ]] || return 1
    [[ "$(cat "apt64/$APT_MARKER" 2>/dev/null || true)" == "$PINNED_APT_COMMIT" ]]
}

# Export exactly the gitlink revision pinned by the original Cydia repository.
# We intentionally do not copy the caller's current working tree: apt-bingner
# may be checked out at a newer APT revision whose method main() ABI differs.
export_pinned_from_repo() {
    local candidate="$1"
    local repo tmp head

    [[ -e "$candidate" ]] || return 1
    if ! repo="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)"; then
        return 1
    fi

    if ! git -C "$repo" cat-file -e "${PINNED_APT_COMMIT}^{commit}" 2>/dev/null; then
        echo "[apt64] repo found but pinned commit is missing locally: $repo"
        echo "[apt64] trying to fetch only the original pinned commit ..."
        GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --no-tags origin "$PINNED_APT_COMMIT" >/dev/null 2>&1 || true
    fi

    git -C "$repo" cat-file -e "${PINNED_APT_COMMIT}^{commit}" 2>/dev/null || return 1

    head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    echo "[apt64] repository: $repo"
    echo "[apt64] working-tree HEAD: ${head:-unknown}"
    echo "[apt64] exporting original Cydia pin: $PINNED_APT_COMMIT"

    tmp=".cydia-pinned-apt.$$"
    rm -rf "$tmp"
    mkdir -p "$tmp"

    if ! git -C "$repo" archive "$PINNED_APT_COMMIT" | tar -xf - -C "$tmp"; then
        rm -rf "$tmp"
        return 1
    fi

    if ! is_cydia_apt_tree "$tmp"; then
        echo "[apt64] pinned commit exported, but required Cydia APT files were not found."
        rm -rf "$tmp"
        return 1
    fi

    rm -rf apt64
    mv "$tmp" apt64
    printf '%s\n' "$PINNED_APT_COMMIT" > "apt64/$APT_MARKER"
    return 0
}

try_root_or_nested_repos() {
    local root="$1"
    local d repo
    [[ -e "$root" ]] || return 1

    if export_pinned_from_repo "$root"; then
        return 0
    fi

    # If the supplied path is an extracted wrapper directory, inspect a small
    # number of nested git repositories without accepting unversioned trees.
    while IFS= read -r d; do
        repo="${d%/.git}"
        if export_pinned_from_repo "$repo"; then
            return 0
        fi
    done < <(find "$root" -maxdepth 6 -type d -name .git 2>/dev/null)

    return 1
}

if ! is_pinned_import; then
    rm -rf apt64
    imported=0

    if [[ -n "${APT64_SOURCE:-}" ]]; then
        if try_root_or_nested_repos "$APT64_SOURCE"; then
            imported=1
        else
            echo "[apt64] APT64_SOURCE does not contain the original pinned commit: $APT64_SOURCE"
        fi
    fi

    if [[ $imported -eq 0 ]]; then
        candidates=(
            "../../apt-bingner"
            "../apt-bingner"
            "/var/mobile/Documents/apt-bingner"
        )
        for root in "${candidates[@]}"; do
            if try_root_or_nested_repos "$root"; then
                imported=1
                break
            fi
        done
    fi

    if [[ $imported -eq 0 ]]; then
        echo "[apt64] scanning Documents for a git repo containing the original pin ..."
        while IFS= read -r gitdir; do
            repo="${gitdir%/.git}"
            if export_pinned_from_repo "$repo"; then
                imported=1
                break
            fi
        done < <(find /var/mobile/Documents -maxdepth 6 -type d -name .git 2>/dev/null)
    fi

    if [[ $imported -eq 0 ]]; then
        tmp=".cydia-apt-clone.$$"
        rm -rf "$tmp"
        echo "[apt64] original pin not found locally; trying official Bingner HTTPS source ..."
        if GIT_TERMINAL_PROMPT=0 git clone "$APT_HTTPS_URL" "$tmp"; then
            if export_pinned_from_repo "$tmp"; then
                imported=1
            fi
        fi
        rm -rf "$tmp"
    fi

    if [[ $imported -eq 0 ]]; then
        echo
        echo "Could not obtain Cydia's exact apt64 revision."
        echo "Required commit: $PINNED_APT_COMMIT"
        echo "The build intentionally refuses to substitute a newer APT tree, because that changes the embedded method ABI."
        echo
        echo "If apt-bingner is elsewhere, rerun with:"
        echo "  APT64_SOURCE=/full/path/to/apt-bingner ./build-ondevice.sh"
        exit 11
    fi
fi

echo "[apt64] verified pin: $(cat "apt64/$APT_MARKER")"

# The original apt32/apt-legacy remote is no longer reliably
# obtainable on-device.  Keep Cydia on its exact pinned apt64 revision and
# use that revision's iOS-patched HTTP method.  MobileCydia's legacy no-arg
# dispatcher ABI is adapted at the call site to the APT 1.8 iOS signature
# (argc, const char **); no HTTP implementation code is rewritten here.
rm -f aptmethod.h http.cc http.h
ln -s apt64/methods/aptmethod.h aptmethod.h
ln -s apt64/methods/http.cc http.cc
ln -s apt64/methods/http.h http.h

http_entry="$(grep -nE '^[[:space:]]*int[[:space:]]+main[[:space:]]*\(' apt64/methods/http.cc | tail -1 || true)"
if [[ -n "$http_entry" ]]; then
    echo "[apt64/http] entrypoint: $http_entry"
else
    echo "[apt64/http] warning: no main() entrypoint found in pinned http.cc"
fi

rm -rf apt64-contrib apt64-deb
mkdir -p apt64-contrib apt64-deb
ln -s ../apt64/apt-pkg/contrib apt64-contrib/apt-pkg
ln -s ../apt64/apt-pkg/deb apt64-deb/apt-pkg

if SDK="$(./ondevice-sdk.sh)"; then
    echo "[sdk]  $SDK"
else
    echo
    echo "No iPhoneOS SDK was found. xcrun/xcodebuild are not expected on iPhone; the on-device build uses an SDK directly."
    echo "Checked common Theos/Procursus SDK locations. If yours is elsewhere run:"
    echo '  export SDKROOT=/full/path/to/iPhoneOS.sdk'
    echo "then rerun ./build-ondevice.sh"
    exit 12
fi

echo "[ok] preparation complete"
