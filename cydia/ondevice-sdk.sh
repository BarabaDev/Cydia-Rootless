#!/var/jb/bin/bash
set -e
shopt -s nullglob

if [[ -n "${SDKROOT:-}" && -d "${SDKROOT}" ]]; then
    printf '%s\n' "${SDKROOT}"
    exit 0
fi

candidates=(
    /var/jb/opt/theos/sdks/iPhoneOS*.sdk
    /var/mobile/theos/sdks/iPhoneOS*.sdk
    /var/mobile/Theos/sdks/iPhoneOS*.sdk
    /var/jb/usr/share/SDKs/iPhoneOS*.sdk
    /var/jb/usr/share/SDKs/iPhoneOS.sdk
    /usr/share/SDKs/iPhoneOS*.sdk
)

for sdk in "${candidates[@]}"; do
    if [[ -d "${sdk}" && -d "${sdk}/System/Library/Frameworks" ]]; then
        printf '%s\n' "${sdk}"
        exit 0
    fi
done

exit 1
