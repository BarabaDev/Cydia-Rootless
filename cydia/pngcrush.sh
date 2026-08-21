#!/var/jb/bin/bash
set -e
src="$1"
out="$2"
mkdir -p "$(dirname "$out")"
cp -af "$src" "$out"
