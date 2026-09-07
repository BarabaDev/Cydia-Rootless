#!/bin/bash
set -euo pipefail

[[ $# -eq 3 && "$1" == "-b" ]] || {
    printf 'Usage: %s -b ROOT OUTPUT.deb\n' "$0" >&2
    exit 2
}

root="$2"
output="$3"
[[ -d "$root/DEBIAN" && -f "$root/DEBIAN/control" ]] || {
    printf 'Invalid DEB staging tree: %s\n' "$root" >&2
    exit 10
}

if [[ -L "$output" ]]; then
    link="$(readlink "$output")"
    if [[ "$link" == /* ]]; then
        output="$link"
    else
        output="$(dirname "$output")/$link"
    fi
fi
mkdir -p "$(dirname "$output")"

stage="$(mktemp -d "${TMPDIR:-/tmp}/cydia-deb.XXXXXX")"
cleanup() {
    rm -rf "$stage"
}
trap cleanup EXIT

export COPYFILE_DISABLE=1
printf '2.0\n' >"$stage/debian-binary"

gtar --format=gnu --no-xattrs --owner=0 --group=0 --numeric-owner \
    -cf "$stage/control.tar" -C "$root/DEBIAN" .
xz -9e -c "$stage/control.tar" >"$stage/control.tar.xz"

cydo="$root/var/jb/usr/libexec/cydia/cydo"
if [[ -f "$cydo" ]]; then
    gtar --format=gnu --no-xattrs --owner=0 --group=0 --numeric-owner \
        --exclude='./DEBIAN' --exclude='./DEBIAN/*' \
        --exclude='./var/jb/usr/libexec/cydia/cydo' \
        -cf "$stage/data.tar" -C "$root" .
    gtar --format=gnu --no-xattrs --owner=0 --group=0 --numeric-owner --mode=6755 \
        --append -f "$stage/data.tar" -C "$root" ./var/jb/usr/libexec/cydia/cydo
else
    gtar --format=gnu --no-xattrs --owner=0 --group=0 --numeric-owner \
        --exclude='./DEBIAN' --exclude='./DEBIAN/*' \
        -cf "$stage/data.tar" -C "$root" .
fi
xz -9e -c "$stage/data.tar" >"$stage/data.tar.xz"

rm -f "$output"
(
    cd "$stage"
    ar -rcS "$OLDPWD/$output" debian-binary control.tar.xz data.tar.xz
)
dpkg-deb --info "$output" >/dev/null
