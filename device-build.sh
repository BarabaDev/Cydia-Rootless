#!/var/jb/bin/bash
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage: bash device-build.sh [--clean] [--sdk PATH] [--jobs N] [--output PATH]' \
        '' \
        'Builds and verifies clean Cydia 1.1.24 on a rootless iOS 15+ device.' \
        'Nothing is installed automatically.'
}

sdk=""
jobs=2
output="/var/mobile/Documents"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) shift ;;
        --sdk)
            [[ $# -ge 2 && -n "$2" ]] || { printf '%s\n' 'Missing value for --sdk' >&2; usage >&2; exit 2; }
            sdk="$2"; shift 2 ;;
        --jobs)
            [[ $# -ge 2 && -n "$2" ]] || { printf '%s\n' 'Missing value for --jobs' >&2; usage >&2; exit 2; }
            jobs="$2"; shift 2 ;;
        --output)
            [[ $# -ge 2 && -n "$2" ]] || { printf '%s\n' 'Missing value for --output' >&2; usage >&2; exit 2; }
            output="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid jobs value: %s\n' "$jobs" >&2; exit 2; }

root="$(cd "$(dirname "$0")" && pwd)"
cd "$root/cydia"
export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:${PATH:-}"

if [[ -n "$sdk" ]]; then
    [[ -d "$sdk/System/Library/Frameworks" ]] || { printf 'Invalid iPhoneOS SDK: %s\n' "$sdk" >&2; exit 1; }
    export SDKROOT="$sdk"
else
    export SDKROOT="$(./ondevice-sdk.sh)"
fi

log="${TMPDIR:-/tmp}/Cydia_1.1.24_device-build.log"
: > "$log"

set +e
{
    printf 'Cydia 1.1.24 Rootless clean device build\n'
    printf 'source: %s\n' "$root"
    printf 'SDKROOT: %s\n' "$SDKROOT"
    printf 'jobs: %s\n\n' "$jobs"

    # Every package run starts from the same clean state. --clean remains an
    # accepted compatibility option for existing device-side instructions.
    make -f makefile.ondevice clean
    find "$root" -name '.DS_Store' -delete
    clean_status=$?
    if [[ $clean_status -ne 0 ]]; then
        printf '\nClean failed; source audit and packaging were not started.\n' >&2
        exit "$clean_status"
    fi

    bash ./modern-source-audit.sh
    audit_status=$?
    if [[ $audit_status -ne 0 ]]; then
        printf '\nSource audit failed; clean, compilation and packaging were not started.\n' >&2
        exit "$audit_status"
    fi

    export MAKEFLAGS="-j$jobs"
    ./package-ondevice.sh
} 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e

if [[ "$status" -ne 0 ]]; then
    printf '\nBuild failed. Log: %s\n' "$log" >&2
    exit "$status"
fi

version="$(./version.sh)"
main="debs/cydia_${version}_iphoneos-arm64.deb"
mkdir -p "$output"

copy_result() {
    local source="$1"
    local destination="$output/${source##*/}"
    if [[ -e "$destination" ]]; then
        destination="${destination%.deb}_rebuild_$(date +%Y%m%d-%H%M%S).deb"
    fi
    cp -p "$source" "$destination"
    printf 'Copied: %s\n' "$destination"
}

copy_result "$main"

printf '\nBuild and audit succeeded. Nothing was installed.\nLog: %s\n' "$log"
