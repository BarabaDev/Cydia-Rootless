#!/bin/bash
set -euo pipefail

[[ $# -eq 1 ]] || { printf 'Usage: %s STAGING_ROOT\n' "$0" >&2; exit 2; }
stage_root="$1"
app="$stage_root/var/jb/Applications/Cydia.app"
[[ -d "$stage_root/DEBIAN" && -f "$app/Info.plist" && -f "$app/Cydia" ]] || {
    printf '%s\n' 'Incomplete Cydia package staging tree' >&2
    exit 1
}

# Package resources are public application data. Do not inherit restrictive
# Mac source-file modes: LaunchServices and the mobile user must read them.
# Check the fixed ancestors, and do not follow bundle resource symlinks.
for directory in "$stage_root" "$stage_root/var" "$stage_root/var/jb" "$stage_root/var/jb/Applications" "$app"; do
    [[ -d "$directory" && ! -L "$directory" ]] || exit 1
done
[[ ! -L "$app/Info.plist" && ! -L "$app/Cydia" ]] || exit 1
chmod 0755 "$stage_root" "$stage_root/var" "$stage_root/var/jb" "$stage_root/var/jb/Applications"
find "$app" -type d -exec chmod 0755 {} +
find "$app" -type f -exec chmod 0644 {} +
chmod 0755 "$app/Cydia"
