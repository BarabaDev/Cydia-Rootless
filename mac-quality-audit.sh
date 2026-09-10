#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")" && pwd)"
source_root="$project_root/cydia"
sdk_path="$(xcrun --sdk iphoneos --show-sdk-path)"
target="arm64-apple-ios15.0"

printf '%s\n' '== Cydia 1.1.30 Mac quality audit =='

(
    cd "$source_root"
    /bin/bash ./modern-source-audit.sh
)

plutil -lint "$source_root/MobileCydia.app/Info.plist" >/dev/null

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
    artwork="$source_root/MobileCydia.app/Sections/$icon"
    [[ -f "$artwork" ]] || { printf 'Missing section artwork: %s\n' "$artwork" >&2; exit 1; }
    dimensions="$(sips -g pixelWidth -g pixelHeight "$artwork" 2>/dev/null | \
        awk '/pixelWidth:/{width=$2}/pixelHeight:/{height=$2}END{print width "x" height}')"
    [[ "$dimensions" == "120x120" ]] || {
        printf 'Invalid section artwork dimensions: %s (%s)\n' "$artwork" "$dimensions" >&2
        exit 1
    }
done
expected_section_icons="$(printf '%s\n' "${section_icon_files[@]}" | LC_ALL=C sort)"
actual_section_icons="$(find "$source_root/MobileCydia.app/Sections" -maxdepth 1 -type f -name '*.png' \
    -exec basename {} \; | LC_ALL=C sort)"
[[ "$actual_section_icons" == "$expected_section_icons" ]] || {
    printf '%s\n' 'Section artwork directory does not contain the exact 40-file icon set' >&2
    exit 1
}
printf '%s\n' 'OK: exact 39 section icons and Default fallback are 120x120 PNG assets'

common_flags=(
    -fsyntax-only -target "$target" -isysroot "$sdk_path"
    -include system.h -I. -ICompat -Iapt64 -Iapt64/methods -Iapt-extra -IObjects/apt64
    -DAPT_PKG_EXPOSE_STRING_VIEW -Dsighandler_t=sig_t
    -Wall -Werror -Wvla
    -Wno-deprecated-declarations -Wno-unknown-pragmas -Wno-unknown-warning-option
    -Wno-objc-protocol-method-implementation -Wno-logical-op-parentheses -Wno-shift-op-parentheses
)

compile_source() {
    local source_file="$1"
    local extension="${source_file##*.}"
    if [[ "$extension" == mm || "$extension" == cpp || "$extension" == cc ]]; then
        xcrun --sdk iphoneos clang++ -std=c++11 -fobjc-call-cxx-cdtors -fvisibility-inlines-hidden \
            "${common_flags[@]}" "$source_file"
    else
        xcrun --sdk iphoneos clang "${common_flags[@]}" "$source_file"
    fi
}

cd "$source_root"
module_count=0
while IFS= read -r source_file; do
    compile_source "$source_file"
    module_count=$((module_count + 1))
done < <(find Menes CyteKit Cydia SDURLCache -type f \
    \( -name '*.m' -o -name '*.mm' -o -name '*.c' -o -name '*.cpp' -o -name '*.cc' \) | LC_ALL=C sort)

for source_file in DiskUsage.cpp Sources.mm cydo.cpp du-helper.cpp postinst.mm setnsfpn.cpp Version.mm lookup3.c; do
    compile_source "$source_file"
done

audit_stage="$(mktemp -d "${TMPDIR:-/tmp}/cydia-mac-audit.XXXXXX")"
cleanup() {
    rm -rf "$audit_stage"
}
trap cleanup EXIT
cp -R "$source_root/." "$audit_stage/"
cd "$audit_stage"
cp -p apt64/apt-pkg/contrib/*.h apt64/apt-pkg/
cp -p apt64/apt-pkg/deb/*.h apt64/apt-pkg/
ln -sf apt64/methods/aptmethod.h aptmethod.h
ln -sf apt64/methods/http.cc http.cc
ln -sf apt64/methods/http.h http.h
xcrun --sdk iphoneos clang++ -std=c++11 -fobjc-call-cxx-cdtors -fvisibility-inlines-hidden \
    "${common_flags[@]}" -include apt.h -D'VERSION="0.7.25.3"' \
    -Wno-macro-redefined -Wno-vla-cxx-extension -Wno-misleading-indentation MobileCydia.mm

if ! analyzer_output="$(xcrun --sdk iphoneos clang++ --analyze -std=c++11 \
    -fobjc-call-cxx-cdtors -fvisibility-inlines-hidden \
    -target "$target" -isysroot "$sdk_path" -include system.h -include apt.h \
    -I. -ICompat -Iapt64 -Iapt64/methods -Iapt-extra -IObjects/apt64 \
    -DAPT_PKG_EXPOSE_STRING_VIEW -Dsighandler_t=sig_t -D'VERSION="0.7.25.3"' \
    -Wno-deprecated-declarations -Wno-unknown-pragmas -Wno-unknown-warning-option \
    -Wno-macro-redefined -Wno-vla-cxx-extension -Wno-misleading-indentation \
    -Xanalyzer -analyzer-output=text MobileCydia.mm 2>&1)"; then
    printf '%s\n' "$analyzer_output" >&2
    printf '%s\n' 'Static analysis failed: MobileCydia.mm' >&2
    exit 1
fi
if grep -Eq 'warning:|error:' <<<"$analyzer_output"; then
    printf '%s\n' "$analyzer_output" >&2
    printf '%s\n' 'Static analysis failed: MobileCydia.mm' >&2
    exit 1
fi

cd "$source_root"
for source_file in \
    Cydia/ModernNativeViews.mm Cydia/InstalledFileTree.mm Cydia/InstalledFilesView.mm Cydia/PackageActionsController.mm Cydia/RepositoryAccounts.mm CyteKit/ModernAppearance.mm CyteKit/WebView.mm CyteKit/WebViewController.mm CyteKit/CyteObject.mm \
    CyteKit/ListController.mm Sources.mm cydo.cpp postinst.mm DiskUsage.cpp setnsfpn.cpp; do
    analyzer_output="$(xcrun --sdk iphoneos clang++ --analyze -std=c++11 \
        -fobjc-call-cxx-cdtors -fvisibility-inlines-hidden \
        -target "$target" -isysroot "$sdk_path" -include system.h \
        -I. -ICompat -Iapt64 -Iapt64/methods -Iapt-extra -IObjects/apt64 \
        -DAPT_PKG_EXPOSE_STRING_VIEW -Dsighandler_t=sig_t \
        -Wno-deprecated-declarations -Wno-unknown-pragmas -Wno-unknown-warning-option \
        -Xanalyzer -analyzer-output=text \
        "$source_file" 2>&1)"
    if grep -Eq 'warning:|error:' <<<"$analyzer_output"; then
        printf '%s\n' "$analyzer_output" >&2
        printf 'Static analysis failed: %s\n' "$source_file" >&2
        exit 1
    fi
done

printf 'OK: %d application modules, helper sources and MobileCydia syntax\n' "$module_count"
printf '%s\n' 'OK: full app and critical modules pass Clang static analysis'
printf '%s\n' 'MAC QUALITY AUDIT PASSED'
