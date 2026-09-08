#!/var/jb/bin/bash

set -e

# Direct startup/maintenance callers enter the helper that holds Debian's
# frontend and database locks until this worker finishes. The internal worker
# argument grants no privileges; the script itself is never setuid.
if [[ $# != 1 || $1 != --under-dpkg-lock ]]; then
    exec /var/jb/usr/libexec/cydia/cydo --refresh-firmware
fi

shopt -s extglob
shopt -s nullglob

version=$(sw_vers -productVersion)
cpu=$(uname -p)

if [[ ${cpu} == arm || ${cpu} == arm64 ]]; then
    data=/var/jb/var/lib/dpkg
    model=hw.machine
    arch=iphoneos-arm64
else
    data=/Library/Cydia/dpkg
    model=hw.model
    arch=cydia
fi

model=$(sysctl -n "${model}")

status=${data}/status

# Capability services can be unavailable during startup. Bound their retries
# before creating any replacement metadata or package list files.
if [[ ${cpu} == arm || ${cpu} == arm64 ]]; then
    capabilities_ready=
    for attempt in {1..10}; do
        if gssc=$(gssc 2>&1) && [[ ${gssc} != *'(null)'* && -n ${gssc} ]]; then
            capabilities_ready=1
            break
        fi
        if [[ ${attempt} != 10 ]]; then
            sleep 1
        fi
    done
    if [[ -z ${capabilities_ready} ]]; then
        printf '%s\n' 'Cydia: device capabilities are unavailable; existing firmware metadata was preserved.' >&2
        exit 1
    fi
fi

function lower() {
    sed -e 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/'
}

# Generate New Package {{{
function pseudo() {
    local package=$1 version=$2 description=$3 name=$4
    echo "/." >"${data}"/info/"${package}".list

    cat <<EOF
Package: ${package}
Essential: yes
Status: install ok installed
Priority: required
Section: System
Installed-Size: 0
Architecture: ${arch}
Version: ${version}
Description: ${description}
Maintainer: Jay Freeman (saurik) <saurik@saurik.com>
Tag: role::cydia
EOF

    [[ -n ${name} ]] && echo "Name: ${name}"
    echo
}
# }}}

output=$(mktemp "${data}"/status-tmp.XXXXXX)
chmod 644 "${output}"
xxxxxx=${output##*/status-tmp.}
rm -f "${data}"/status-tmp.!("${xxxxxx}")

{

# Delete Old Packages {{{
    unset firmware
    unset blank

    while IFS= read -r line; do
        #echo "#${firmware+@}/${blank+@} ${line}" 1>&2

        if [[ ${line} == '' && "${blank+@}" ]]; then
            continue
        else
            unset blank
        fi

        if [[ ${line} == "Package: "@(firmware|gsc.*|cy+*) ]]; then
            firmware=
        elif [[ ${line} == '' ]]; then
            blank=
        fi

        if [[ "${firmware+@}" ]]; then
            if [[ "${blank+@}" ]]; then
                unset firmware
            fi
            continue
        fi

        #echo "${firmware+@}/${blank+@} ${line}" 1>&2
        echo "${line}"
    done <"${status}"

    #echo "#${firmware+@}/${blank+@} EOF" 1>&2
    if ! [[ "${blank+@}" || "${firmware+@}" ]]; then
        echo
    fi
# }}}

    if [[ ${cpu} == arm || ${cpu} == arm64 ]]; then
        pseudo "firmware" "${version}" "almost impressive Apple frameworks" "iOS Firmware"

        echo "${gssc}" | sed -re '
            /^    [^ ]* = [0-9.]*;$/ ! d;
            s/^    ([^ ]*) = ([0-9.]*);$/\1 \2/;
            s/([A-Z])/-\L\1/g;
            s/^"([^ ]*)"/\1/;
            s/^-//;
            / 0$/ d;
        ' | while read -r name value; do case "${name}" in
            (ipad) for name in ipad wildcat; do
                pseudo "gsc.${name}" "${value}" "this device has a very large screen" "iPad"
            done;;

            (*)
                pseudo "gsc.${name}" "${value}" "virtual GraphicsServices dependency"
            ;;
        esac; done
    fi

    if [[ ${cpu} == arm || ${cpu} == arm64 ]]; then
        os=ios
    else
        os=macosx
    fi

    pseudo "cy+os.${os}" "${version}" "virtual operating system dependency"
    pseudo "cy+cpu.${cpu}" "0" "virtual CPU dependency"

    name=${model%%*([0-9]),*([0-9])}
    version=${model#${name}}
    name=$(lower <<<${name})
    version=${version/,/.}
    pseudo "cy+model.${name}" "${version}" "virtual model dependency"

    pseudo "cy+kernel.$(lower <<<$(sysctl -n kern.ostype))" "$(sysctl -n kern.osrelease)" "virtual kernel dependency"

    pseudo "cy+lib.corefoundation" "$(/var/jb/usr/libexec/cydia/cfversion)" "virtual corefoundation dependency"

} >"${output}"

mv -f "${output}" "${status}"

if [[ ${cpu} == arm || ${cpu} == arm64 ]]; then
    # iOS 15+ rootless hardening: the root filesystem is not Cydia's domain.
    # Historical Cydia rewrote /User here for old rootful jailbreak layouts.
    # Modern iOS already owns that compatibility path, so preserve it exactly
    # as the OS/bootstrap provides it and only update Cydia's firmware marker.
    echo 6 >/var/jb/var/lib/cydia/firmware.ver
fi
