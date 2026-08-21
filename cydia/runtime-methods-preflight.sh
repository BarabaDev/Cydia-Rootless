#!/var/jb/bin/bash
set -euo pipefail
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

echo "== Cydia rootless / runtime APT + GPG preflight =="
required=(http https gpgv store copy file rred)

is_complete_methods_dir() {
    local dir="$1" m
    [[ -d "$dir" ]] || return 1
    for m in "${required[@]}"; do
        [[ -x "$dir/$m" ]] || return 1
    done
    return 0
}

METHODS=""
for candidate in \
    /var/jb/usr/libexec/apt/methods \
    /var/jb/usr/lib/apt/methods \
    /var/jb/libexec/apt/methods \
    /var/jb/lib/apt/methods; do
    if is_complete_methods_dir "$candidate"; then
        METHODS="$candidate"
        break
    fi
done

if [[ -z "$METHODS" ]] && command -v dpkg-query >/dev/null 2>&1; then
    while IFS= read -r entry; do
        [[ "${entry##*/}" == "http" ]] || continue
        candidate="${entry%/http}"
        if is_complete_methods_dir "$candidate"; then
            METHODS="$candidate"
            break
        fi
    done < <(dpkg-query -L apt 2>/dev/null || true)
fi

if [[ -z "$METHODS" ]]; then
    echo "[FAIL] could not locate a complete modern APT methods directory"
    dpkg-query -L apt 2>/dev/null | grep '/methods/' || true
    exit 1
fi

echo "[methods] $METHODS"
for m in "${required[@]}"; do
    printf '[ok]   %-8s %s\n' "$m" "$METHODS/$m"
done

GPGV=""
for candidate in /var/jb/usr/bin/gpgv /var/jb/bin/gpgv; do
    if [[ -x "$candidate" ]]; then
        GPGV="$candidate"
        break
    fi
done
if [[ -z "$GPGV" ]] && command -v gpgv >/dev/null 2>&1; then
    GPGV="$(command -v gpgv)"
fi
if [[ -z "$GPGV" ]] && command -v dpkg-query >/dev/null 2>&1; then
    while IFS= read -r candidate; do
        if [[ "${candidate##*/}" == "gpgv" && -x "$candidate" ]]; then
            GPGV="$candidate"
            break
        fi
    done < <(dpkg-query -L gpgv 2>/dev/null || true)
fi

if [[ -z "$GPGV" ]]; then
    echo "[FAIL] standalone gpgv verifier is missing"
    echo "[info] dpkg status:"
    dpkg-query -W -f='${Package}: ${Status} ${Version}\n' gpgv 2>/dev/null || true
    echo "[info] apt depends on gpgv; public Cydia also declares gpgv directly."
    exit 1
fi

echo "[gpgv] $GPGV"
if ! "$GPGV" --version >/tmp/cydia-rootless-gpgv-version.txt 2>&1; then
    cat /tmp/cydia-rootless-gpgv-version.txt || true
    echo "[FAIL] gpgv exists but cannot execute"
    exit 1
fi
head -n 2 /tmp/cydia-rootless-gpgv-version.txt | sed 's/^/[gpgv] /'
rm -f /tmp/cydia-rootless-gpgv-version.txt

if command -v apt-config >/dev/null 2>&1; then
    echo "[info] bootstrap APT method/gpg settings:"
    apt-config dump 2>/dev/null | grep -Ei 'Dir::Bin::(methods|Methods|gpg|apt-key)' || true
fi

echo "[ok] modern APT methods and standalone gpgv are executable"
