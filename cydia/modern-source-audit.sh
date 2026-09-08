#!/var/jb/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$*"; }

expected="1.1.23"
pinned="e4718f05d049c1a09fb9662cc3db2d4c5122defe"

echo "== Cydia 1.1.23 clean rootless source audit =="

[[ "$(./version.sh)" == "$expected" ]] || fail "package version is not $expected"
grep -Fxq "#define CYDIA_VERSION \"$expected\"" Version.h || fail "compiled version header differs"
grep -A1 '<key>CFBundleShortVersionString</key>' MobileCydia.app/Info.plist | grep -Fq '<string>1.1.23</string>' || fail "app public version is not 1.1.23"
grep -A1 '<key>CFBundleVersion</key>' MobileCydia.app/Info.plist | grep -Fq '<string>1.1.23</string>' || fail "app build number is not the final release version 1.1.23"
! grep -E '^Depends:.*cydia-lproj' cydia.control >/dev/null || fail "obsolete separate translation dependency remains"
grep -Fq 'Replaces: cydia-lproj (<= 1.1.22)' cydia.control || fail "safe merged-translation replacement rule is missing"
grep -Fq 'Conflicts: cydia-lproj (<= 1.1.22)' cydia.control || fail "old translation package is not removed during migration"
[[ ! -e cydia-lproj.control ]] || fail "obsolete separate translation package control remains"
grep -Fq 'package: debs/cydia_$(version)_iphoneos-arm64.deb' makefile.ondevice || fail "single self-contained Cydia package target is missing"
! grep -Fq 'lproj_deb' makefile.ondevice || fail "obsolete separate translation build target remains"
locales=(ar de el en es fr he it ja ko nl pl pt-PT pt ru sv th tr vi zh-Hans zh-Hant)
localization_count="$(find MobileCydia.app -maxdepth 1 -type d -name '*.lproj' | wc -l | tr -d ' ')"
[[ "$localization_count" == "${#locales[@]}" ]] || fail "expected 21 retained localizations, found $localization_count"
for locale in "${locales[@]}"; do
    [[ -f "MobileCydia.app/$locale.lproj/Localizable.strings" ]] || fail "missing localization source: $locale"
    [[ -f "MobileCydia.app/$locale.lproj/InfoPlist.strings" ]] || fail "missing localized Face ID purpose: $locale"
    grep -Fq '"NSFaceIDUsageDescription"' "MobileCydia.app/$locale.lproj/InfoPlist.strings" || fail "missing Face ID purpose key: $locale"
done
for locale in ar de el es fr he it ja ko nl pl pt-PT pt ru sv th tr vi zh-Hans zh-Hant; do
    [[ -f "MobileCydia.app/$locale.lproj/Sections.strings" ]] || fail "missing section localization source: $locale"
done
[[ ! -e MobileCydia.app/en.lproj/Sections_.strings ]] || fail "unused English section template remains"
[[ ! -e MobileCydia.app/en.lproj/Sections.strings ]] || fail "redundant English identity section table remains"
localization_file_count="$(find MobileCydia.app -path '*.lproj/*.strings' -type f | wc -l | tr -d ' ')"
[[ "$localization_file_count" == 62 ]] || fail "expected 62 active translation tables, found $localization_file_count"
! grep -RIEq '1[.]1[.]21\+modern[.]3' Version.h version.sh cydia.control MobileCydia.app/Info.plist Cydia/ModernNativeViews.mm || fail "obsolete suffixed release metadata remains"
! grep -RIEq 'CydiaModern[0-9]' MobileCydia.mm Cydia/ModernNativeViews.h Cydia/ModernNativeViews.mm || fail "obsolete numbered UI class name remains"
grep -A1 '<key>CFBundleIconFile</key>' MobileCydia.app/Info.plist | grep -Fq '<string>Icon-60.png</string>' || fail "modern app icon is not the primary icon"
grep -A1 '<key>UILaunchStoryboardName</key>' MobileCydia.app/Info.plist | grep -Fq '<string>LaunchScreen</string>' || fail "modern native launch screen is not selected"
! grep -Fq '<key>UILaunchImages</key>' MobileCydia.app/Info.plist || fail "legacy fixed-size launch images still control startup"
[[ -f LaunchScreen.storyboard ]] || fail "editable modern launch storyboard is missing"
[[ -f MobileCydia.app/LaunchScreen.storyboardc/Info.plist ]] || fail "compiled modern launch storyboard is missing"
ok "version metadata is $expected"

retired_app_artwork=(
    iconClassic.png unknown.png chevron@2x.png compose.png configure.png
    folder.png folder@2x.png reload.png home-Selected.png home-Selected@2x.png
    home.png home@2x.png home7.png home7@2x.png home7@3x.png
    home7s.png home7s@2x.png home7s@3x.png
    install.png install@2x.png install7.png install7@2x.png install7@3x.png
    install7s.png install7s@2x.png install7s@3x.png
    changes.png changes@2x.png changes7.png changes7@2x.png changes7@3x.png
    changes7s.png changes7s@2x.png changes7s@3x.png
    manage.png manage@2x.png manage7.png manage7@2x.png manage7@3x.png
    manage7s.png manage7s@2x.png manage7s@3x.png
    search.png search@2x.png search7.png search7@2x.png search7@3x.png
    search7s.png search7s@2x.png search7s@3x.png
)
for artwork in "${retired_app_artwork[@]}"; do
    [[ ! -e "MobileCydia.app/$artwork" ]] || fail "unused pre-iOS-15 artwork remains: $artwork"
done
! grep -Fq 'imageNamed:legacy' CyteKit/TabBarController.mm || fail "tab bar still has a legacy PNG fallback"
! grep -Fq '.png"' < <(sed -n '/addViewControllers:nil,/,/nil];/p' MobileCydia.mm) || fail "tab definitions still reference legacy PNG artwork"
ok "tab bar uses only current SF Symbols and retired artwork is absent"

grep -Fq 'Architecture: iphoneos-arm64' cydia.control || fail "main package is not iphoneos-arm64"
grep -Fq 'firmware (>= 15.0)' cydia.control || fail "iOS 15 minimum is missing"
grep -Fq 'rootless_prefix := /var/jb' makefile.ondevice || fail "rootless prefix is missing"
grep -Fq 'flag64 += -miphoneos-version-min=15.0' makefile.ondevice || fail "arm64 iOS 15 target is missing"
! grep -Eq '^libapt64 \+= apt64/methods/rfc2553emu[.]cc$' makefile.ondevice || fail "iOS 15 build still archives the empty RFC 2553 fallback object"
grep -Fq 'dpkg := dpkg-deb --root-owner-group -Zxz' makefile.ondevice || fail "root-owner-group dpkg packaging is missing"
! grep -Fq 'fakeroot' makefile.ondevice || fail "makefile still requires fakeroot"
! grep -Eq 'for tool in .*fakeroot' prepare-ondevice.sh || fail "preflight still requires fakeroot"
grep -Fq 'prepare_status=$?' package-ondevice.sh || fail "package build does not capture preparation status"
grep -Fq '[stop] preparation failed; compilation and packaging were not started' package-ondevice.sh || fail "package build does not stop after failed preparation"
grep -Fq 'mkdir -p _/var/jb/Applications' makefile.ondevice || fail "standard rootless app package path is missing"
grep -Fq '#define CYDIA_APPLICATION_PATH "/var/jb/Applications/Cydia.app"' CyteKit/RootlessRuntimePaths.h || fail "standard runtime app path changed"
grep -Fq 'SameFile(path, CYDIA_APPLICATION_BINARY)' cydo.cpp || fail "cydo caller identity check is missing"
ok "standard rootless iOS 15+ package boundary"
grep -Fq './normalize-app-permissions.sh _' makefile.ondevice || fail "bundle resource permissions inherit source checkout modes"
grep -Fq 'application resource is not readable by iOS' verify-package-ondevice.sh || fail "package verifier does not reject unreadable app resources"

[[ "$(<apt64/.cydia-pinned-apt-commit)" == "$pinned" ]] || fail "pinned Bingner APT commit differs"
for path in \
    apt64/apt-pkg apt64/apt-pkg/deb apt64/apt-pkg/contrib \
    apt64/methods/aptmethod.h apt64/methods/http.cc apt64/methods/http.h \
    apt64/methods/basehttp.cc apt64/methods/connect.cc \
    apt64/methods/rfc2553emu.cc apt64/methods/store.cc \
    apt64/apt-pkg/tagfile-keys.list apt64/apt-pkg/tagfile-order.c \
    apt64/triehash/triehash.pl; do
    [[ -e "$path" ]] || fail "required pinned APT input is missing: $path"
done
grep -Fq '#include "tagfile-order.c"' apt64/apt-pkg/tagfile.cc || fail "tagfile.cc textual include changed"
read -r tagfile_order_hash _ < <(sha256sum apt64/apt-pkg/tagfile-order.c)
[[ "$tagfile_order_hash" == \
    "3844ffffff2ebd768de15613bf72659eb62eb4280ffbba1cd9f7bf6e84ed4b86" ]] || \
    fail "tagfile-order.c differs from the pinned APT source"

# Textually included implementation/data fragments are invisible to make's
# object list. Verify every such include kept in the clean tree resolves next
# to its including source file.
while IFS=: read -r source _ include_line; do
    [[ -n "$source" ]] || continue
    fragment="${include_line#*\"}"
    fragment="${fragment%%\"*}"
    [[ -f "$(dirname "$source")/$fragment" ]] || \
        fail "missing textual include $fragment required by $source"
done < <(grep -RInE '^[[:space:]]*#[[:space:]]*include[[:space:]]*"[^\"]+\.(c|cc|cpp|inc|inl|def|list|data)"' \
    --include='*.c' --include='*.cc' --include='*.cpp' --include='*.m' \
    --include='*.mm' --include='*.h' --include='*.hh' --include='*.hpp' \
    apt64 Menes CyteKit Cydia SDURLCache 2>/dev/null || true)
ok "minimal pinned Bingner APT inputs are complete"

# The complete FIX08 source applied these changes during Mac preparation.
# This clean on-device source has no Mac preparation stage, so the verified
# transport contract must already exist in the compiled http.cc itself.  Audit
# the implementation rather than trusting a diagnostic string in the app.
http_method="apt64/methods/http.cc"
[[ "$(grep -Fc 'CFSTR("Cydia/1.1.23")' "$http_method")" -eq 1 ]] || \
    fail "embedded HTTPS method does not contain exactly one Cydia/1.1.23 User-Agent"
! grep -Fq 'Telesphoreo APT-HTTP/1.0.592' "$http_method" || \
    fail "obsolete Telesphoreo package User-Agent remains in compiled source"
for header in \
    X-Firmware X-Machine X-Unique-ID User-Agent \
    Sec-CH-UA Sec-CH-UA-Platform Sec-CH-UA-Platform-Version \
    Sec-CH-UA-Arch Sec-CH-UA-Bitness Sec-CH-UA-Model; do
    grep -Fq "CFSTR(\"$header\")" "$http_method" || \
        fail "compiled embedded HTTPS method is missing header: $header"
done
grep -Fq '_config->Set("Dir::Bin::Methods::https", CydiaPackageHTTPSMethod_);' MobileCydia.mm || \
    fail "package archive transaction does not select the embedded HTTPS method"
grep -Fq '_config->Set("Dir::Bin::Methods::https", StandardHTTPSMethod_);' MobileCydia.mm || \
    fail "bootstrap HTTPS method restoration is missing"
grep -Fq 'scope=package-archives-only' MobileCydia.mm || \
    fail "package-only HTTPS scope diagnostic is missing"
grep -Fq 'error.compare(begin, 5, "HTTP/") == 0' MobileCydia.mm || \
    fail "HTTP/1.x acquire errors are not normalized for diagnostics"
grep -Fq 'sc == 303 || sc == 307 || sc == 308' "$http_method" || \
    fail "embedded package transport does not follow modern HTTP redirects"
grep -Fq 'redirectCount > 10' "$http_method" || \
    fail "embedded package transport has no redirect-chain limit"
grep -Fq 'Unsafe redirect blocked' "$http_method" || \
    fail "embedded package transport permits an unsafe protocol downgrade"
ok "compiled package HTTPS identity and iOS client-hint contract"

! grep -Fq 'system("/var/jb/usr/libexec/cydia/cydo --cleanup-legacy-source-link")' MobileCydia.mm || \
    fail "legacy source cleanup still depends on an unavailable rootful shell"
grep -Fq 'posix_spawn(&cleanupPid, cleanupCydo' MobileCydia.mm || \
    fail "legacy source cleanup does not use direct rootless process spawning"
grep -Fq 'waitpid(cleanupPid, &cleanupStatus, 0)' MobileCydia.mm || \
    fail "legacy source cleanup does not verify its child result"
ok "legacy source cleanup uses direct rootless process execution"

grep -Fq 'cp -p apt64/apt-pkg/contrib/*.h apt64/apt-pkg/' prepare-ondevice.sh || fail "contrib header flattening is missing"
grep -Fq 'cp -p apt64/apt-pkg/deb/*.h apt64/apt-pkg/' prepare-ondevice.sh || fail "deb header flattening is missing"
grep -Fq 'apt64/apt-pkg/hashes.h && ! -L apt64/apt-pkg/hashes.h' prepare-ondevice.sh || fail "hashes.h regular-file validation is missing"
grep -Fq "printf '#include <apt-pkg/hashes.h>" prepare-ondevice.sh || fail "clang hashes.h preflight is missing"
! grep -Fq -- '-Iapt64-contrib' makefile.ondevice || fail "obsolete contrib overlay include path remains"
! grep -Fq -- '-Iapt64-deb' makefile.ondevice || fail "obsolete deb overlay include path remains"
! grep -Fq 'libapt32' makefile.ondevice || fail "obsolete unused apt32 makefile path remains"
ok "all pinned APT headers resolve through the canonical apt64 include tree"

for file in \
    CyteKit/ModernAppearance.h CyteKit/ModernAppearance.mm \
    Cydia/ModernNativeViews.h Cydia/ModernNativeViews.mm; do
    [[ -f "$file" ]] || fail "missing active modern UI file: $file"
done
grep -Fq 'CYApplyModernAppearance();' MobileCydia.mm || fail "modern appearance is not activated at launch"
grep -Fq 'systemImageNamed' CyteKit/ModernAppearance.mm || fail "SF Symbols tabs are missing"
grep -Fq 'UITableViewStyleInsetGrouped' CyteKit/ModernAppearance.mm || fail "inset grouped tables are missing"
grep -Fq 'systemGroupedBackgroundColor' CyteKit/ModernAppearance.mm || fail "dynamic grouped background is missing"
grep -Fq 'secondaryLabelColor' CyteKit/ModernAppearance.mm || fail "dynamic secondary labels are missing"
grep -Fq 'UIBlurEffectStyleSystemChromeMaterial' CyteKit/ModernAppearance.mm || fail "modern navigation material is missing"
grep -Fq 'UINavigationItemLargeTitleDisplayModeAlways' CyteKit/ViewController.mm || fail "large navigation titles are missing"
grep -Fq 'setScrollTabBarHidden:(BOOL)hidden animated:(BOOL)animated' CyteKit/TabBarController.mm || fail "scroll-responsive tab bar animation is missing"
grep -Fq 'launchTabs=%lu' MobileCydia.mm || fail "cold Home diagnostic does not verify the complete initial tab bar"
[[ "$(sed -n '/Paint the complete cached Home immediately/,/setRootViewController:emulated_/p' MobileCydia.mm | grep -Fc '[emulated_ addViewControllers:nil,')" -eq 1 ]] || fail "cold Home does not construct the complete five-item tab bar before presentation"
[[ "$(sed -n '/Paint the complete cached Home immediately/,/setRootViewController:emulated_/p' MobileCydia.mm | grep -Fc 'UCLocalize("SOURCES")')" -eq 1 ]] || fail "cold Home tab bar is missing Sources"
[[ "$(sed -n '/Paint the complete cached Home immediately/,/setRootViewController:emulated_/p' MobileCydia.mm | grep -Fc 'UCLocalize("CHANGES")')" -eq 1 ]] || fail "cold Home tab bar is missing Changes"
[[ "$(sed -n '/Paint the complete cached Home immediately/,/setRootViewController:emulated_/p' MobileCydia.mm | grep -Fc 'UCLocalize("INSTALLED")')" -eq 1 ]] || fail "cold Home tab bar is missing Installed"
[[ "$(sed -n '/Paint the complete cached Home immediately/,/setRootViewController:emulated_/p' MobileCydia.mm | grep -Fc 'UCLocalize("SEARCH")')" -eq 1 ]] || fail "cold Home tab bar is missing Search"
! sed -n '/Paint the complete cached Home immediately/,/setRootViewController:emulated_/p' MobileCydia.mm | grep -Fq 'concealTabBarSelection' || fail "cold Home still hides its initial selected tab"
load_data_body="$(sed -n '/- (void) loadData {/,/- (void) showActionSheet:/p' MobileCydia.mm)"
[[ "$(printf '%s\n' "$load_data_body" | grep -n '\[navigation setViewControllers:current\]' | cut -d: -f1)" -lt "$(printf '%s\n' "$load_data_body" | grep -n '\[self disemulate\]' | cut -d: -f1)" ]] || fail "live tab controller is still exposed before its navigation stacks are populated"
grep -Fq 'CATransform3DIdentity' CyteKit/TabBarController.mm || fail "scroll-responsive tab bar layer does not return to its canonical position"
grep -Fq '[bar setTransform:CGAffineTransformIdentity]' CyteKit/TabBarController.mm || fail "scroll-responsive tab bar does not preserve its UIKit-owned frame"
grep -Fq '[[bar layer] removeAllAnimations]' CyteKit/TabBarController.mm || fail "tab bar does not clear interrupted presentation-layer animations"
grep -Fq '[bar setUserInteractionEnabled:!hidden]' CyteKit/TabBarController.mm || fail "tab bar hit testing is not restored with visibility"
grep -Fq '[bar setHidden:NO]' CyteKit/TabBarController.mm || fail "tab bar visibility state can remain stuck after scrolling"
! grep -Fq 'CATransform3DMakeTranslation' CyteKit/TabBarController.mm || fail "tab bar still translates its layer while scrolling"
! grep -Fq 'CGAffineTransformMakeTranslation' CyteKit/TabBarController.mm || fail "tab bar still translates its view while scrolling"
grep -Fq 'if ([view isHidden])' CyteKit/ViewController.mm || fail "scroll discovery can still bind to hidden legacy content"
grep -Fq 'modernScrollPanChanged:' CyteKit/ViewController.mm || fail "scroll gesture is not connected to tab-bar visibility"
grep -Fq '[modernScrollView_ isDragging] || [modernScrollView_ isDecelerating]' CyteKit/ViewController.mm || fail "tab bar does not wait for scrolling to settle"
grep -Fq 'vertical >= 8.0f && vertical > horizontal' CyteKit/ViewController.mm || fail "tab bar lacks the vertical movement threshold"
grep -Fq 'BOOL pullingPastTop' CyteKit/ViewController.mm || fail "top-edge pull protection is missing"
! grep -Fq '<key>UIUserInterfaceStyle</key>' MobileCydia.app/Info.plist || fail "Info.plist forces a fixed appearance"
ok "automatic Light/Dark modern appearance"

grep -Fq '@interface CydiaModernProgressView' Cydia/ModernNativeViews.h || fail "native Progress surface is missing"
grep -Fq '@interface CydiaModernHomeView' Cydia/ModernNativeViews.h || fail "native Home surface is missing"
grep -Fq '@interface CydiaModernEssentialView' Cydia/ModernNativeViews.h || fail "native essential-upgrade surface is missing"
grep -Fq '@interface CydiaModernPrivacyConsentView' Cydia/ModernNativeViews.h || fail "first-launch privacy surface is missing"
grep -Fq 'CydiaPrivacyConsentVersion' MobileCydia.mm || fail "first-launch privacy acceptance has no stable preference key"
grep -Fq 'CFPreferencesAppSynchronize' MobileCydia.mm || fail "privacy acceptance is not durably synchronized"
grep -Fq 'if (privacyConsent_ == nil)' MobileCydia.mm || fail "automatic repository refresh is not gated by first-launch acceptance"
grep -Fq 'if (!CydiaPrivacyConsentIsAccepted())' MobileCydia.mm || fail "featured repository discovery is not gated by first-launch acceptance"
banner_request_block="$(sed -n '/static void CYM3RequestFeaturedBanner/,/^}/p' Cydia/ModernNativeViews.mm)"
printf '%s\n' "$banner_request_block" | grep -Fq 'if (!download || !CydiaPrivacyConsentIsAccepted())' || fail "banner artwork can start a network request before first-launch acceptance"
printf '%s\n' "$banner_request_block" | grep -Fq 'if (allowNetwork)' || fail "shared banner requests ignore the cache-only caller gate"
grep -Fq 'This acceptance is stored only on this device' Cydia/ModernNativeViews.mm || fail "privacy surface does not explain local acceptance storage"
grep -Fq 'Repository requests can include your IP address' Cydia/ModernNativeViews.mm || fail "privacy surface does not disclose repository request data"
grep -Fq '[self setAccessibilityViewIsModal:YES]' Cydia/ModernNativeViews.mm || fail "privacy surface is not isolated for assistive technology"
grep -Fq 'contentLayoutGuide' Cydia/ModernNativeViews.mm || fail "privacy surface is not scroll-safe for large text"
! grep -Eq 'Canister Privacy Policy|Zebra Privacy' Cydia/ModernNativeViews.mm || fail "third-party privacy branding leaked into Cydia"
grep -Fq '@interface HomeController : CyteViewController' MobileCydia.mm || fail "Home still uses the legacy web surface"
grep -Fq 'CydiaModernHomeView' MobileCydia.mm || fail "native Home surface is not integrated"
grep -Fq '[[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever]' MobileCydia.mm || fail "Home still uses a duplicate large-title navigation row"
sed -n '/@implementation ChangesController/,/\/\* }}} \*\//p' MobileCydia.mm | grep -F 'UINavigationItemLargeTitleDisplayModeNever' >/dev/null || fail "Changes still uses a duplicate large-title navigation row"
grep -Fq 'return metadata->last_ != 0 ? metadata->last_ : metadata->first_;' MobileCydia.mm || fail "Changes still hides newly published versions of unsubscribed packages"
sed -n '/@implementation SearchController/,/\/\* }}} \*\//p' MobileCydia.mm | grep -F 'UINavigationItemLargeTitleDisplayModeNever' >/dev/null || fail "Search still uses a duplicate large-title navigation row"
sed -n '/@implementation InstalledController/,/\/\* }}} \*\//p' MobileCydia.mm | grep -F 'UINavigationItemLargeTitleDisplayModeNever' >/dev/null || fail "Installed still uses a duplicate large-title navigation row"
sed -n '/@implementation SourcesController/,/\/\* }}} \*\//p' MobileCydia.mm | grep -F 'UINavigationItemLargeTitleDisplayModeNever' >/dev/null || fail "Sources still uses a duplicate large-title navigation row"
! grep -Fq '/#!/home/' MobileCydia.mm || fail "legacy Cydia web Home endpoint remains active"
grep -Fq 'Quick Actions' Cydia/ModernNativeViews.mm || fail "native Home quick actions are missing"
! grep -Fq 'refreshState_' Cydia/ModernNativeViews.mm || fail "Home still duplicates repository activity under the welcome heading"
! grep -Fq 'secureCaption_' Cydia/ModernNativeViews.mm || fail "Home Library still duplicates repository verification state"
! grep -Fq '@"Library"' Cydia/ModernNativeViews.mm || fail "Home still contains the redundant Library card"
! grep -Fq 'setSourceCount:' Cydia/ModernNativeViews.h Cydia/ModernNativeViews.mm MobileCydia.mm || fail "Home still exposes obsolete source/package statistics"
grep -Fq 'setQuickActionSourceCount:' Cydia/ModernNativeViews.h Cydia/ModernNativeViews.mm MobileCydia.mm || fail "Home Quick Actions do not expose exact live metrics"
grep -Fq 'CYHomeQuickMetricsCacheKey' MobileCydia.mm || fail "cold Home preview does not retain the latest exact metrics"
grep -Fq 'CYInstalledPackageVisibleToUser(package)' MobileCydia.mm || fail "Installed Quick Action does not match the default User package filter"
grep -Fq 'strcmp(name + 6, "enduser") == 0 || strcmp(name + 6, "user") == 0' MobileCydia.mm || fail "modern role::user packages are not classified as end-user packages"
grep -Fq 'return (state.Flags & pkgCache::Flag::Auto) != 0;' MobileCydia.mm || fail "Installed/User does not distinguish automatic dependencies"
grep -Fq 'CYInstalledSectionIsTechnical' Cydia/LibraryPresentation.h || fail "untagged bootstrap components still appear as ordinary User packages"
installed_block="$(sed -n '/@implementation InstalledController/,/\/\* }}} \*\//p' MobileCydia.mm)"
[[ "$(printf '%s\n' "$installed_block" | grep -Fc 'return ![package uninstalled] && package->role_ < 7;')" -ge 2 ]] || fail "Installed Expert and Recent do not share Sileo's complete installed-package boundary"
grep -Fq '[package upgradableAndEssential:YES] && ![package ignored]' MobileCydia.mm || fail "Changes Quick Action does not match the real upgrade queue"
! grep -Fq '[discoverTitle_ setText:@"Discover"]' Cydia/ModernNativeViews.mm || fail "removed Discover heading is still visible above the banners"
grep -Fq 'setFeaturedPackages:(NSArray *)packages' Cydia/ModernNativeViews.mm || fail "Home package carousel is missing"
grep -Fq 'ceil(viewport / featuredCycleWidth_) + 2' Cydia/ModernNativeViews.mm || fail "Home carousel does not fill wide or resized screens"
grep -Fq 'featuredCycleWidth_' Cydia/ModernNativeViews.mm || fail "Home carousel lacks seamless cycle normalization"
grep -Fq 'CADisplayLink' Cydia/ModernNativeViews.mm || fail "Home carousel lacks idle auto-scroll timing"
grep -Fq 'UIAccessibilityIsReduceMotionEnabled()' Cydia/ModernNativeViews.mm || fail "Home carousel ignores Reduce Motion"
grep -Fq 'scrollViewWillBeginDragging:' Cydia/ModernNativeViews.mm || fail "Home carousel does not pause for direct touch interaction"
grep -Fq 'featured-iphoneos-arm64.json' MobileCydia.mm || fail "Home carousel does not consume the Sileo-compatible featured feed"
grep -Fq 'URLByAppendingPathComponent:@"sileo-featured.json"' MobileCydia.mm || fail "Home does not automatically discover banners from every installed Sileo-compatible source"
grep -Fq 'for (Source *source in [database_ sources])' MobileCydia.mm || fail "Home banner discovery does not enumerate the installed repositories"
grep -Fq 'CydiaSileoFeaturedBannersV3' MobileCydia.mm || fail "aggregated repository banner cache is missing"
grep -Fq '[seenPackages containsObject:identifier]' MobileCydia.mm || fail "duplicate package banners are not removed"
grep -Fq 'CYM3FeaturedBannerRequests' Cydia/ModernNativeViews.mm || fail "triplicated infinite banners can still download the same artwork repeatedly"
grep -Fq 'UIImage *cached([CYM3FeaturedBannerCache() objectForKey:imageURL_])' Cydia/ModernNativeViews.mm || fail "in-memory banner artwork is not restored immediately"
printf '%s\n' "$banner_request_block" | grep -Fq 'dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)' || fail "cold banner cache reads can block Home construction"
! sed -n '/@implementation CYM3FeaturedPackageButton/,/^@end/p' Cydia/ModernNativeViews.mm | grep -Fq 'CYM3CachedFeaturedBanner(' || fail "banner cards synchronously read the file cache"
grep -Fq 'width * height > 4.0f * 1024.0f * 1024.0f' Cydia/ModernNativeViews.mm || fail "banner preparation has no decoded pixel bound"
grep -Fq '!isfinite(width) || !isfinite(height)' Cydia/ModernNativeViews.mm || fail "nonfinite banner dimensions can reach image preparation"
grep -Fq 'snapshot = [[orderedResults copy] autorelease]' MobileCydia.mm || fail "partial banner metadata does not use an immutable response snapshot"
grep -Fq 'generation != featuredRequestGeneration_ || finalResultsApplied' MobileCydia.mm || fail "stale banner metadata can replace a newer result"
grep -Fq 'if (!complete && featuredPackagesLoaded_)' MobileCydia.mm || fail "partial metadata can shift a visible carousel"
grep -Fq 'storeCachedResponse:persisted forRequest:request' Cydia/ModernNativeViews.mm || fail "banner artwork is not persisted across a full process exit"
grep -Fq 'UIViewContentModeScaleAspectFill' Cydia/ModernNativeViews.mm || fail "Home banner artwork is not aspect-filled like Sileo"
grep -Fq 'featuredCardWidth_ = 263.0f' Cydia/ModernNativeViews.mm || fail "Home banners do not preserve Sileo's 263 x 148 presentation"
grep -Fq 'UIScrollViewDecelerationRateNormal' Cydia/ModernNativeViews.mm || fail "Home carousel does not preserve soft native finger inertia"
! grep -Fq 'featuredResumeTimestamp_' Cydia/ModernNativeViews.mm || fail "Home carousel still inserts an artificial pause after touch"
grep -Fq 'featuredTravelVelocity_' Cydia/ModernNativeViews.mm || fail "Home carousel does not retain the user's travel direction"
grep -Fq 'scrollViewWillEndDragging:' Cydia/ModernNativeViews.mm || fail "Home carousel does not hand finger momentum to continuous motion"
grep -Fq '*targetContentOffset = [scrollView contentOffset]' Cydia/ModernNativeViews.mm || fail "UIKit can still apply a separate braking animation to Home banners"
grep -Fq 'hideShadow' Cydia/ModernNativeViews.mm MobileCydia.mm || fail "Home banners ignore Sileo's shadow metadata"
grep -Fq '@NO, @"displayText"' MobileCydia.mm || fail "known artwork with embedded titles is not marked text-free"
grep -Fq 'arc4random_uniform' MobileCydia.mm || fail "Home carousel order is not randomized"
grep -Fq 'CYFeaturedProcessBannerRecords' MobileCydia.mm || fail "Home carousel order is not scoped to one Cydia process"
grep -Fq 'NSUInteger launchBannerCount(MIN((NSUInteger) 6, [processBanners count]))' MobileCydia.mm || fail "cold launch can still construct an unbounded banner carousel before its first frame"
grep -Fq 'initWithFeaturedPackages:launchBanners' MobileCydia.mm || fail "cold launch does not paint a bounded cached Home banner set immediately"
grep -Fq '[banner setObject:@YES forKey:@"launchCacheOnly"]' MobileCydia.mm || fail "launch banners can still initialize CFNetwork before the first Home frame"
grep -Fq 'BOOL allowNetwork(!launchCacheOnly_ && CydiaPrivacyConsentIsAccepted())' Cydia/ModernNativeViews.mm || fail "cache-only launch banners still permit network requests"
grep -Fq 'launchCacheOnly_ = [[package objectForKey:@"launchCacheOnly"] boolValue]' Cydia/ModernNativeViews.mm || fail "banner cards lose their launch cache-only policy"
grep -Fq '[home_ loadFeaturedArtwork]' MobileCydia.mm || fail "existing banner cards cannot resume artwork after privacy acceptance"
grep -Fq 'CYM3RequestFeaturedBanner(imageURL_, request, [[UIScreen mainScreen] scale], allowNetwork)' Cydia/ModernNativeViews.mm || fail "banner request does not receive its explicit network permission"
grep -Fq 'CYM3FeaturedBannerDiskPath' Cydia/ModernNativeViews.mm || fail "Home banner artwork has no lightweight process-independent cache"
grep -Fq 'NSDataReadingMappedIfSafe' Cydia/ModernNativeViews.mm || fail "cold-launch banner artwork is not read through the lightweight mapped cache"
! sed -n '/static UIImage \*CYM3CachedFeaturedBanner/,/^}/p' Cydia/ModernNativeViews.mm | grep -Fq 'sharedURLCache' || fail "cold Home synchronously initializes NSURLCache while reading banners"
grep -Fq 'CydiaModernHomeView' Cydia/LoadingViewController.mm || fail "cold launch still shows a spinner instead of the cached Home surface"
! grep -Fq 'CydiaLoadingView *indicator' Cydia/LoadingViewController.mm || fail "spinner-only cold launch remains active"
grep -Fq 'setRightBarButtonItems:' Cydia/LoadingViewController.mm || fail "cached Home does not paint both right-side controls in its first frame"
grep -Fq '@"arrow.clockwise"' Cydia/LoadingViewController.mm || fail "cached Home is missing the Reload control"
grep -Fq '@"arrow.up.left.and.arrow.down.right"' Cydia/LoadingViewController.mm || fail "cached Home is missing the full-screen control"
grep -Fq 'manualHomeReloadInProgress_' MobileCydia.mm || fail "live Home Reload has no deterministic in-progress state"
grep -Fq '[reloadButton_ setLoading:YES]' MobileCydia.mm || fail "live Home Reload gives no visible feedback"
grep -Fq 'initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium' CyteKit/ModernAppearance.mm || fail "Home Reload has no activity indicator"
grep -Fq '[window_ setBackgroundColor:[UIColor systemGroupedBackgroundColor]]' MobileCydia.mm || fail "launch window can expose an unmatched black background"
launch_block="$(sed -n '/- (void) applicationDidFinishLaunching:/,/- (NSArray \*) defaultStartPages/p' MobileCydia.mm)"
launch_root_line="$(printf '%s\n' "$launch_block" | grep -nF '[window_ setRootViewController:emulated_]' | head -1 | cut -d: -f1)"
launch_privacy_line="$(printf '%s\n' "$launch_block" | grep -nF '[self showPrivacyConsentIfNeeded]' | head -1 | cut -d: -f1)"
launch_show_line="$(printf '%s\n' "$launch_block" | grep -nF '[window_ setHidden:NO]' | tail -1 | cut -d: -f1)"
launch_database_line="$(printf '%s\n' "$launch_block" | grep -nF 'database_ = [Database sharedInstance]' | head -1 | cut -d: -f1)"
launch_deferred_line="$(printf '%s\n' "$launch_block" | grep -nF '[self performSelector:@selector(completeDeferredLaunch) withObject:nil afterDelay:0.05]' | head -1 | cut -d: -f1)"
[[ -n "$launch_root_line" && -n "$launch_show_line" && "$launch_root_line" -lt "$launch_show_line" ]] || fail "launch window is visible before cached Home becomes its root"
[[ -n "$launch_privacy_line" && "$launch_root_line" -lt "$launch_privacy_line" && "$launch_privacy_line" -lt "$launch_show_line" ]] || fail "first-launch privacy surface is not installed before the window becomes visible"
[[ -n "$launch_database_line" && "$launch_show_line" -lt "$launch_database_line" ]] || fail "cold launch blocks on APT before presenting cached Home"
[[ -n "$launch_deferred_line" && "$launch_show_line" -lt "$launch_deferred_line" ]] || fail "legacy runtime work is not scheduled behind the first Home frame"
printf '%s\n' "$launch_block" | grep -Fq '[[emulated_ view] layoutIfNeeded]' || fail "cached Home is not laid out before the launch window appears"
printf '%s\n' "$launch_block" | grep -Fq 'CYDeferredStartupWork_();' || fail "deferred APT/filesystem startup work is never completed"
grep -Fq '[window_ bringSubviewToFront:privacyConsent_]' MobileCydia.mm || fail "live root swap can cover the first-launch privacy surface"
grep -Fq 'startup prompts deferred reason=acknowledgement-pending' MobileCydia.mm || fail "startup alerts can still appear behind first-launch privacy"
grep -Fq 'CYDeferredStartupWork_ = [&, translation]' MobileCydia.mm || fail "APT and root-helper startup work still executes before UIApplicationMain"
launch_webkit_line="$(printf '%s\n' "$launch_block" | grep -nF '[CyteWebViewController _initialize]' | head -1 | cut -d: -f1)"
launch_webpreferences_line="$(printf '%s\n' "$launch_block" | grep -nF '[WebPreferences setWebKitLinkTimeVersion:' | head -1 | cut -d: -f1)"
launch_cache_line="$(printf '%s\n' "$launch_block" | grep -nF 'NSURLCache *launchCache' | head -1 | cut -d: -f1)"
[[ -n "$launch_webkit_line" && "$launch_show_line" -lt "$launch_webkit_line" ]] || fail "WebKit initializes before cached Home is visible"
[[ -n "$launch_webpreferences_line" && "$launch_show_line" -lt "$launch_webpreferences_line" ]] || fail "legacy WebPreferences initializes before cached Home is visible"
[[ -n "$launch_cache_line" && "$launch_show_line" -lt "$launch_cache_line" ]] || fail "disk cache setup delays the first visible Home frame"
ok "cached Home commits before deferred APT, helper and WebKit startup work"
if sed -n '/- (void) applicationWillEnterForeground:/,/- (void) setConfigurationData:/p' MobileCydia.mm | \
    grep -Fq 'refreshHomeStatus'; then
    fail "returning from the background still reshuffles or rebuilds Home banners"
fi
grep -Fq '[self refreshHomeStatus]' MobileCydia.mm || fail "source refresh does not cache newly discovered repository banners"
if sed -n '/@implementation HomeController/,/\/\* }}} \*\//p' MobileCydia.mm | \
    sed -n '/- (void) reloadData {/,/^}/p' | grep -Fq 'refreshFeaturedPackages'; then
    fail "database reload still restarts the independent Home banner strip"
fi
if sed -n '/- (void) stopUpdateWithSelector:/,/- (void) restoreSelectedTabAfterUpdate:/p' MobileCydia.mm | \
    grep -Fq 'refreshHomeStatus'; then
    fail "source refresh completion still restarts the independent Home banner strip"
fi
grep -Fq -- '- (NSURL *) remoteIconURL' MobileCydia.mm || fail "package metadata does not expose modern HTTPS icons"
grep -Fq 'CYModernPackageIconCache' MobileCydia.mm || fail "package list icons have no bounded memory cache"
grep -Fq 'representedPackageIdentifier_' MobileCydia.mm || fail "reused package rows can display an icon from the wrong package"
grep -Fq 'NSURLRequestReturnCacheDataElseLoad' MobileCydia.mm || fail "remote package and banner artwork bypasses the URL cache"
grep -Fq '_H<UIView> refreshBar_' MobileCydia.mm || fail "Sources top refresh progress bar is missing"
grep -Fq 'setSourceRefreshActive:' MobileCydia.mm || fail "Sources refresh no longer drives the modern top progress bar"
grep -Fq 'synchronizeSourceRefreshUI' MobileCydia.mm || fail "Sources controls do not share one authoritative refresh state"
grep -Fq 'sourceRefreshStateDidChange' MobileCydia.mm || fail "Sources completion cannot synchronize Cancel, pull-to-refresh and the top bar"
changes_block="$(sed -n '/@implementation ChangesController/,/\/\* }}} \*\//p' MobileCydia.mm)"
printf '%s\n' "$changes_block" | grep -Fq -- '- (void) sourceRefreshStateDidChange' || fail "Changes controls do not receive the final repository-refresh state"
printf '%s\n' "$changes_block" | grep -Fq '[[[self navigationItem] leftBarButtonItem] setEnabled:NO]' || fail "Changes Cancel can be tapped repeatedly while APT is unwinding"
sync_block="$(sed -n '/- (void) synchronizeSourceRefreshUI {/,/^}/p' MobileCydia.mm)"
printf '%s\n' "$sync_block" | grep -Fq 'for (UIViewController *container in [self viewControllers])' || fail "repository refresh state is synchronized only to one tab"
grep -Fq '[refreshBar_ setRefreshing:active]' MobileCydia.mm || fail "Sources refresh is not wired to the lifecycle-owned indicator"
grep -Fq 'manual ignored reason=refresh-already-active' MobileCydia.mm || fail "duplicate manual source refresh requests are not rejected"
grep -Fq 'CydiaSourceSpectrum' CyteKit/ModernAppearance.mm || fail "Sources top refresh bar lost its coordinated palette"
grep -Fq 'CydiaSourceSweep' CyteKit/ModernAppearance.mm || fail "Sources top refresh bar lost its sweeping animation"
grep -Fq 'single, non-redundant indicator' MobileCydia.mm || fail "redundant tab-bar refresh spinner was reintroduced"
grep -Fq 'const CGFloat centerX(itemWidth * 1.5f)' MobileCydia.mm || fail "Sources spinner is not deterministically centered on the Sources tab"
grep -Fq '@"checkmark.circle.fill"' MobileCydia.mm || fail "successful source refresh does not transition to a green checkmark"
grep -Fq 'showSourceCompletionWithVerification:' MobileCydia.mm || fail "Sources completion status is not connected"
grep -Fq 'reloadDataAfterSourceRefresh' MobileCydia.mm || fail "source refresh still uses the flashing full-screen reload path"
grep -Fq 'fullScreenHUD=0' MobileCydia.mm || fail "source refresh in-place reload contract is missing"
grep -Fq '_updateDataPreservingVisibleController' MobileCydia.mm || fail "source refresh still tears down the selected screen"
grep -Fq 'restoreSelectedTabAfterUpdate:' MobileCydia.mm || fail "repository refresh can still change the selected tab"
grep -Fq 'queueUpdateAfterCurrent' MobileCydia.mm || fail "source changes can still start a parallel repository refresh"
grep -Fq 'BOOL cancelled(cancelRequested_)' MobileCydia.mm || fail "source cancellation is not finalized by the refresh worker"
grep -Fq '[database_ resetFetch]' MobileCydia.mm || fail "source row activity can remain spinning after refresh completion"
grep -Fq '[updatedelegate_ performSelector:selector];' MobileCydia.mm || fail "source refresh is marked complete before its final model rebuild"
grep -Fq 'BOOL restarting(selector == @selector(reloadDataAndRestartSourceRefresh))' MobileCydia.mm || fail "queued source refresh handoff is not serialized"
grep -Fq '_config->Set("Acquire::http::Timeout", 25)' MobileCydia.mm || fail "HTTP source refresh has no bounded timeout"
grep -Fq '_config->Set("Acquire::https::Timeout", 25)' MobileCydia.mm || fail "HTTPS source refresh has no bounded timeout"
grep -Fq 'imageNamed:@"Icon-60"' Cydia/ModernNativeViews.mm || fail "Home still uses the classic Cydia icon"
grep -Fq '[heroTitle setText:CYLocalize(@"Welcome to Cydia™")]' Cydia/ModernNativeViews.mm || fail "flat welcome heading is missing"
grep -Fq 'by Jay Freeman (saurik)' Cydia/ModernNativeViews.mm || fail "original author attribution is missing"
! grep -Fq 'heroSubtitle' Cydia/ModernNativeViews.mm || fail "removed Modern Rootless hero label remains"
! grep -Fq 'heroDetail' Cydia/ModernNativeViews.mm || fail "removed upper version label remains"
grep -Fq '[footer setText:@"Cydia 1.1.23"]' Cydia/ModernNativeViews.mm || fail "Home footer version is missing"
! grep -Fq 'Rootless edition by BarabaDev' Cydia/ModernNativeViews.mm || fail "removed footer credit remains"
grep -Fq 'CYM3DestinationButton(@"Cydia", @"f"' Cydia/ModernNativeViews.mm || fail "Facebook destination is missing"
grep -Fq 'CYM3DestinationButton(@"saurik", @"𝕏"' Cydia/ModernNativeViews.mm || fail "saurik social destination is missing"
grep -Fq 'CYM3DestinationButton(CYLocalize(@"Manage Account")' Cydia/ModernNativeViews.mm || fail "Manage Account destination is missing"
! grep -Eq 'CYM3DestinationButton\(@"(Featured|Themes)"' Cydia/ModernNativeViews.mm || fail "removed Featured/Themes Home rows remain"
grep -Fq '@interface CydiaRepositoryAccountsViewController' Cydia/RepositoryAccounts.h || fail "repository account manager is missing"
grep -Fq 'kSecAttrAccessibleWhenUnlockedThisDeviceOnly' Cydia/RepositoryAccounts.mm || fail "repository token is not device-only Keychain protected"
! grep -Fq 'hasPrefix:@"BEARER "' Cydia/RepositoryAccounts.mm || fail "repository login still rejects raw Sileo payment tokens"
grep -Fq 'deviceIdentifier, @"udid"' Cydia/RepositoryAccounts.mm || fail "repository account requests do not include the device identifier"
grep -Fq 'deviceModel, @"device"' Cydia/RepositoryAccounts.mm || fail "repository account requests do not include the device model"
grep -Fq 'architecture ?: @"iphoneos-arm64", @"architecture"' Cydia/RepositoryAccounts.mm || fail "paid download authorization omits package architecture"
grep -Fq '[queue setMaxConcurrentOperationCount:4]' Cydia/RepositoryAccounts.mm || fail "repository payment providers are still discovered serially"
grep -Fq 'CYRepositoryAccountSecretKeychainService' Cydia/RepositoryAccounts.mm || fail "payment secret is not device-only Keychain protected"
grep -Fq 'CYRepositoryAuthorizedDownloadURL' MobileCydia.mm || fail "paid-package download authorization is not integrated"
grep -Fq 'NSInteger CYRepositoryPurchase(' Cydia/RepositoryAccounts.mm || fail "in-app purchase entry point is missing"
grep -Fq 'CYRepositoryPackageInfo(' Cydia/RepositoryAccounts.mm || fail "commercial package price/ownership lookup is missing"
grep -Fq 'LAPolicyDeviceOwnerAuthentication' Cydia/RepositoryAccounts.mm || fail "purchase does not require device authentication"
grep -Fq 'forKey:@"payment_secret"' Cydia/RepositoryAccounts.mm || fail "purchase request omits the Sileo payment secret"
grep -Fq 'CYRepositoryPurchaseActionRequired' Cydia/RepositoryAccounts.mm || fail "purchase action-required status handling is missing"
grep -Fq 'buyButtonClicked' MobileCydia.mm || fail "native Buy action is not wired into Package Details"
grep -Fq 'CYRepositoryPurchase(' MobileCydia.mm || fail "in-app purchase is not integrated into Package Details"
grep -Fq 'ASWebAuthenticationPresentationContextProviding' MobileCydia.mm || fail "purchase action web-authentication presentation is missing"
grep -Fq 'completePurchaseAndInstall' MobileCydia.mm || fail "a completed purchase does not continue to installation"
grep -Fq 'CYStoreSourceDisplayName' MobileCydia.mm || fail "repository display-name persistence (Sileo parity) is missing"
grep -Fq 'CYRememberedSourceDisplayName' MobileCydia.mm || fail "Sources list can regress to a bare hostname after refresh"
# Sources list must not flicker: repository icons come from the shared
# memory/disk icon cache (shown instantly on re-entry, no placeholder flash),
# and a refreshing source shows a modern sweeping shimmer bar instead of a
# per-cell spinner (the tab-bar spinner is kept separately).
grep -Fq 'CYModernPackageIconFromDisk(iconAddress)' MobileCydia.mm || fail "Sources list no longer caches repository icons (would flash placeholders on entry)"
# Review Changes package queue shows each package's own icon when it has one
# (shared icon cache, with a one-time fetch + coalesced reload for uncached
# remote icons), instead of only the generic section glyph.
grep -Fq 'CYModernPackageIconDidLoadNotification' MobileCydia.mm || fail "package queue never refreshes to show real package icons"
grep -Fq 'the queue shows real icons immediately' MobileCydia.mm || fail "package queue no longer prefers the package's own cached icon"
# Applying screen: a real progress ring hugs the state icon and tracks the same
# real percentage the bar shows (App Store style).
grep -Fq 'App Store-style progress ring' Cydia/ModernNativeViews.mm || fail "progress ring around the state icon is missing"
grep -Fq 'setRingStrokeEnd:' Cydia/ModernNativeViews.mm || fail "progress ring is not driven by the real progress value"
# Home: an expand glyph beside Reload toggles an immersive full-screen Home
# (both bars hide, a tap restores); Home's Reload refreshes the Home dashboard,
# not the repositories.
grep -Fq 'toggleFullScreenClicked' MobileCydia.mm || fail "Home full-screen toggle button is missing"
grep -Fq 'setNavigationBarHidden:immersive_' MobileCydia.mm || fail "Home full-screen mode does not hide the navigation bar"
# The dpkg reader threads and the download-status callbacks must not message a
# freed progress/database delegate (background-thread crash at the end of an
# install, which also stopped the completion screen — and its respring/reboot
# button — from ever appearing).
grep -Fq 'safeProgressDelegate' MobileCydia.mm || fail "reader threads no longer fetch the delegate through a retained safe accessor"
grep -Fq 'CYFinishIndexForName' MobileCydia.mm || fail "maintainer-script finish actions no longer use the lifetime-safe enum-style parser"
! grep -Fq 'Finishes_' MobileCydia.mm || fail "autoreleased global finish-action array can still crash the control reader"
grep -Fq 'command=/var/jb/usr/bin/sbreload' MobileCydia.mm || fail "respring completion no longer uses the modern rootless sbreload path"
grep -Fq 'finishActionStarted_' MobileCydia.mm || fail "finish button no longer rejects duplicate respring/reboot requests"
grep -Fq '[modernProgressView_ setRestartingKind:CydiaRestartSpringBoard]' MobileCydia.mm || fail "SpringBoard restart has no explicit presentation state"
! grep -Fq 'finishHUD_' MobileCydia.mm || fail "restart still overlays the completed screen with a generic loading HUD"
grep -Fq 'CYArchiveIdentity::IsUsable(version)' apt64/apt-pkg/packagemanager.cc || fail "archive plan accepts an empty selected version"
grep -Fq 'CYArchiveIdentity::IsUsable(Version)' apt64/apt-pkg/acquire-item.cc || fail "archive constructor formats incomplete package metadata"
grep -Fq 'prepare reviewOnly=1 reason=unresolved-dependencies' MobileCydia.mm || fail "broken dependency review still constructs archive requests"
# RegEx must own the text it matches: ICU uregex_setText keeps the pointer and
# reads it during capture extraction, so a temporary UTF-16 buffer would be
# freed underneath it and yield a corrupt capture string (intermittent crash
# when that string is later formatted/messaged, e.g. the finish/status readers).
grep -Fq 'std::vector<UChar> text_;' CyteKit/RegEx.hpp || fail "RegEx does not own a private copy of the matched text (dangling ICU text pointer)"
grep -Fq 'text_.assign(data, data + size);' CyteKit/RegEx.hpp || fail "RegEx no longer copies the matched text before uregex_setText"
grep -Fq '[progress performSelectorOnMainThread:@selector(addProgressEvent:)' MobileCydia.mm || fail "dpkg status reader still messages the transient progress delegate directly"
grep -Fq 'not the repositories' MobileCydia.mm || fail "Home reload no longer refreshes the Home dashboard instead of the repositories"
grep -Fq 'cySourceShimmer' MobileCydia.mm || fail "Sources refresh lost its modern shimmer indicator"
grep -Fq 'refreshShimmer_ = [CAGradientLayer layer]' MobileCydia.mm || fail "Sources refresh shimmer gradient is missing"
grep -Fq 'CYPruneModernPackageIconDiskCacheOnce' MobileCydia.mm || fail "on-disk icon cache is unbounded (no prune)"
grep -Fq 'CYModernPackageIconFromDisk' MobileCydia.mm || fail "package icons lack a persistent on-disk cache (lag on tab entry)"
grep -Fq 'CYPersistModernPackageIcon' MobileCydia.mm || fail "downloaded package icons are not persisted to disk"
grep -Fq 'throttleSeconds=900' MobileCydia.mm || fail "launch source-refresh throttle is missing (unclean open)"
grep -Fq 'BOOL databaseReady(' MobileCydia.mm || fail "Home banner strip can flicker on launch before the database is ready"
grep -Fq 'updateHeroIcon' MobileCydia.mm || fail "Package Details does not load the repository package icon"
grep -Fq 'UISceneActivationStateForegroundActive' MobileCydia.mm || fail "purchase web-auth session lacks a robust presentation anchor"
grep -Fq 'Complete the purchase in the browser' MobileCydia.mm || fail "paid purchase has no browser fallback when the in-app session cannot start"
grep -Fq 'framework LocalAuthentication' makefile.ondevice || fail "LocalAuthentication framework is not linked for purchase biometrics"
grep -Fq '@interface CydiaPurchasedPackagesViewController' Cydia/RepositoryAccounts.mm || fail "repository purchases still expand into an unbounded account screen"
grep -Fq '@"Purchased Packages"' Cydia/RepositoryAccounts.mm || fail "repository account purchase summary is missing"
grep -Fq 'Search purchases' Cydia/RepositoryAccounts.mm || fail "repository purchase search is missing"
grep -Fq 'CYRepositoryPackageResolver' Cydia/RepositoryAccounts.h || fail "purchased packages have no metadata resolver for real names and icons"
grep -Fq 'setPackageResolver:' MobileCydia.mm || fail "Manage Account does not supply the purchased-package resolver"
grep -Fq 'UIListContentConfiguration' Cydia/RepositoryAccounts.mm || fail "purchased packages list is not built with a modern content configuration"
grep -Fq 'checkmark.circle.fill' Cydia/RepositoryAccounts.mm || fail "purchased packages do not mark installed items with a checkmark"
grep -Fq 'CYRepositoryPurchasedIconDidLoadNotification' MobileCydia.mm || fail "purchased-package icons never refresh after an async download"
grep -Fq 'verification=APT-hash-and-size-unchanged' MobileCydia.mm || fail "paid-package flow does not document retained APT verification"
! grep -Fq '•  iOS %@  •  /var/jb' Cydia/ModernNativeViews.mm || fail "Home still exposes the runtime iOS/path diagnostic line"
grep -Fq '@interface CydiaModernAboutViewController' Cydia/ModernNativeViews.h || fail "modern About sheet is missing"
grep -Fq 'CydiaModernAboutViewController *about' MobileCydia.mm || fail "modern About sheet is not integrated"
! grep -Eq 'mediumDetent|IdentifierMedium|prefersCompactReview' MobileCydia.mm || fail "a Cydia panel can still collapse to half height"
grep -Fq '[legalText_ setAttributedText:CYM3LegalText(legalCopy_)]' Cydia/ModernNativeViews.mm || fail "About license is not immediately visible"
grep -Fq '@selector(openLicense)' Cydia/ModernNativeViews.mm || fail "About cannot open the full license"
grep -Fq 'scroll.contentLayoutGuide.bottomAnchor' Cydia/ModernNativeViews.mm || fail "About content cannot scroll with larger text"
cmp -s ../LICENSE MobileCydia.app/COPYING || fail "Bundled license does not match the source license"
cmp -s apt64/COPYING.GPL MobileCydia.app/Licenses/GPL-2.0.txt || fail "APT GPL text is not bundled intact"
grep -Fq 'GNU AFFERO GENERAL PUBLIC LICENSE' MobileCydia.app/Licenses/AGPL-3.0.txt || fail "Cytore AGPL text is missing"
grep -Fq 'Nicolai M. Josuttis 2001' MobileCydia.app/Licenses/NOTICES.txt || fail "Component attribution notices are missing"
! grep -Fq 'legalRevealTimer_' Cydia/ModernNativeViews.mm || fail "About still delays license visibility"
grep -Fq 'legalCopy_ = [@"Modern Rootless • BarabaDev • 7 September 2026' Cydia/ModernNativeViews.mm || fail "About license card does not identify the modified release"
! grep -Fq 'legalCopy_ = [@"Cydia by Jay Freeman' Cydia/ModernNativeViews.mm || fail "About license animation duplicates the original Cydia attribution"
grep -Fq 'NSLinkAttributeName' Cydia/ModernNativeViews.mm || fail "About source address is not an interactive link"
grep -Fq 'https://github.com/BarabaDev/Cydia-Rootless' Cydia/ModernNativeViews.mm || fail "About source link has no safe HTTPS destination"
grep -Fq 'shouldInteractWithURL:' Cydia/ModernNativeViews.mm || fail "About source link is not routed to the browser"
grep -Fq 'CYLocalize(@"Modified Cydia"), @"Sam Bingner"' Cydia/ModernNativeViews.mm || fail "Bingner attribution is not identified as modified Cydia"
! grep -Fq '@"Modified Cydia base"' Cydia/ModernNativeViews.mm || fail "obsolete technical base label remains in About"
! grep -Fq '@"Rootless foundation"' Cydia/ModernNativeViews.mm || fail "Bingner is incorrectly attributed as the rootless foundation"
! grep -Eq 'Modern[.]3' Cydia/ModernNativeViews.mm || fail "obsolete suffixed user-facing label remains"
grep -Fq 'presentEssentialUpgradeSheet' MobileCydia.mm || fail "native essential-upgrade sheet is not integrated"
! grep -Fq '[alert setContext:@"upgrade"]' MobileCydia.mm || fail "legacy essential-upgrade alert remains active"
grep -Fq 'setTransferCurrent:' Cydia/ModernNativeViews.mm || fail "native transfer metrics are missing"
grep -Fq 'appendLogMessage:' Cydia/ModernNativeViews.mm || fail "collapsible native live log is missing"
grep -Fq 'setFinishTitle:' Cydia/ModernNativeViews.mm || fail "sticky finish action is missing"
grep -Fq 'CydiaModernProgressView' MobileCydia.mm || fail "native Progress is not integrated"
grep -Fq 'UINotificationFeedbackGenerator' MobileCydia.mm || fail "transaction completion feedback is missing"
grep -Fq '@interface CydiaModernConfirmationView' Cydia/ModernNativeViews.h || fail "native confirmation surface is missing"
grep -Fq 'CydiaModernConfirmationView' MobileCydia.mm || fail "native confirmation is not integrated"
grep -Fq '@interface CydiaModernPackageDetailView' Cydia/ModernNativeViews.h || fail "native package Details surface is missing"
grep -Fq 'modernDetail_' MobileCydia.mm || fail "native package Details surface is not integrated"
grep -Fq 'CYModernNativeControllerRoot(@"package-details")' MobileCydia.mm || fail "Package Details does not use its native root surface"
! grep -Fq '[legacyScroll setHidden:YES]' MobileCydia.mm || fail "Package Details still keeps obsolete HTML content underneath"
! grep -Fq '[[self webView] bringSubviewToFront:modernDetail_]' MobileCydia.mm || fail "Package Details still depends on legacy WebView load completion"
grep -Fq '[action_ setContentHorizontalAlignment:UIControlContentHorizontalAlignmentCenter]' Cydia/ModernNativeViews.mm || fail "package action title is not horizontally centred"
grep -Fq '[action_ setContentVerticalAlignment:UIControlContentVerticalAlignmentCenter]' Cydia/ModernNativeViews.mm || fail "package action title is not vertically centred"
grep -Fq '[action_ setImage:nil forState:UIControlStateNormal]' Cydia/ModernNativeViews.mm || fail "package action still reserves space for a leading symbol"
grep -Fq '[button setContentHorizontalAlignment:UIControlContentHorizontalAlignmentCenter]' Cydia/ModernNativeViews.mm || fail "shared primary actions are not horizontally centred"
grep -Fq '[button setContentVerticalAlignment:UIControlContentVerticalAlignmentCenter]' Cydia/ModernNativeViews.mm || fail "shared primary actions are not vertically centred"
grep -Fq '[confirm_ setImage:nil forState:UIControlStateNormal]' Cydia/ModernNativeViews.mm || fail "confirmation action still has off-centre icon spacing"
grep -Fq '[[self navigationItem] setRightBarButtonItem:nil animated:NO]' MobileCydia.mm || fail "duplicate package action remains in navigation"
grep -Fq 'return nil;' MobileCydia.mm || fail "package Details right-button suppression is missing"
grep -Fq '[[action_ widthAnchor] constraintEqualToConstant:144.0f]' Cydia/ModernNativeViews.mm || fail "package action does not keep a stable centred width"
! grep -Fq '[[action_ leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]]' Cydia/ModernNativeViews.mm || fail "legacy full-width package action remains"
grep -Fq '@"PACKAGE INFORMATION"' Cydia/ModernNativeViews.mm || fail "modern package metadata card is missing"
grep -Fq '@"MANAGE PACKAGE"' Cydia/ModernNativeViews.mm || fail "modern package management card is missing"
grep -Fq 'setNavigationTarget:' Cydia/ModernNativeViews.h || fail "package settings/files actions are not connected"
grep -Fq 'setUnavailableIdentifier:' Cydia/ModernNativeViews.h || fail "unavailable package state is missing"
grep -Fq 'selection deferred reason=stale-row' MobileCydia.mm || fail "stale package selection can still open empty Details"
grep -Fq '[self refreshUpgradeButton]' MobileCydia.mm || fail "Changes cannot synchronously refresh its Upgrade action"
! sed -n '/- (void) upgradeButtonClicked {/,/^}/p' MobileCydia.mm | grep -Fq 'setRightBarButtonItem:nil' || fail "Upgrade still disappears before APT confirms the action"
grep -Fq 'CYSectionIconFilename' MobileCydia.mm || fail "audited section-icon mapping is missing"
grep -Fq 'CYNoSectionIcon' MobileCydia.mm || fail "no-section package fallback is missing"
grep -Fq 'Default.png' MobileCydia.mm || fail "default no-section artwork is not integrated"
! grep -Fq 'Folder_No_Section.png' MobileCydia.mm || fail "retired no-section artwork name remains referenced"
! grep -Fq 'Unknown_Package.png' MobileCydia.mm || fail "retired Unknown Package artwork remains referenced"
! grep -Fq 'imageNamed:@"unknown.png"' MobileCydia.mm || fail "legacy question-mark fallback artwork remains"
! grep -Fq 'CydiaModernPackageHeaderView' Cydia/ModernNativeViews.h || fail "obsolete package-only header remains"
grep -Fq 'UIRefreshControl' CyteKit/ListController.mm || fail "package-list pull to refresh is missing"
grep -Fq 'UIRefreshControl' MobileCydia.mm || fail "Sources pull to refresh is missing"
grep -Fq 'initWithFrame:CGRectMake(0.0f, 0.0f, 1.0f, 14.0f)' MobileCydia.mm || fail "Sources top card spacing is missing"
grep -Fq '[list_ setTableHeaderView:topSpacing]' MobileCydia.mm || fail "Sources top card spacing is not integrated"
grep -Fq 'UISheetPresentationControllerDetent largeDetent' MobileCydia.mm || fail "iOS 15 confirmation sheet is missing"
grep -Fq 'cache->MarkInstall(iterator_, true);' MobileCydia.mm || fail "package installation does not include the full dependency closure"
grep -Fq 'beginPackageTransaction' MobileCydia.mm || fail "package transactions are not serialized against source refresh"
grep -Fq 'reason=source-refresh-active aptSerialization=1 queueMutated=0' MobileCydia.mm || fail "package actions can still mutate APT during source refresh"
grep -Fq 'sourceRefreshPendingAfterTransaction_' MobileCydia.mm || fail "source changes made during a package transaction can be lost"
! sed -n '/- (bool) perform {/,/^}/p' MobileCydia.mm | grep -Fq '[tabbar_ cancelUpdate]' || fail "package preparation still races a cancelled source refresh"
grep -Fq 'transactionReloadPending_ = true' MobileCydia.mm || fail "successful installs do not schedule a final package-state reload"
grep -Fq 'final visible package state reloaded after modal dismissal' MobileCydia.mm || fail "package Details can still show Install after a successful transaction"
grep -Fq 'CYExternalSourceFromCydiaURL' MobileCydia.mm || fail "external repository buttons are not decoded natively"
grep -Fq 'showAddSourcePromptWithURL:' MobileCydia.mm || fail "external repository URL is not prefilled in the Add Source confirmation"
grep -Fq 'CydiaManagedEquivalentExists' Sources.mm || fail "Cydia-managed equivalent sources can still be duplicated"
grep -Fq 'reason=equivalent-managed-source' Sources.mm || fail "managed source deduplication is not diagnosable"
# Sileo <-> Cydia source interoperability and duplicate protection. A source
# added in Sileo/Zebra must be seen by Cydia (shared APT read of both .list and
# DEB822 .sources), a source added in Cydia must be seen by them (atomic publish
# to the shared cydia-added.list), and adding a repo one manager already owns
# must never create a duplicate.
grep -Fq 'ReadMainList()' MobileCydia.mm || fail "Cydia no longer reads the shared APT source list (Sileo/Zebra sources would be invisible)"
grep -Fq 'bool deb822(name.size() >= 8' Sources.mm || fail "Cydia stops recognizing DEB822 .sources files written by Sileo"
grep -Fq 'CydiaSharedSourceEntries' Sources.mm || fail "shared cross-manager source scan is missing"
grep -Fq 'CydiaExternalEquivalentExists' Sources.mm || fail "a repo already present in an external (Sileo) list can be duplicated by Cydia"
grep -Fq 'reason=equivalent-external-source' Sources.mm || fail "external source deduplication is not diagnosable"
grep -Fq 'rename(CYDIA_SOURCES_TEMP, CYDIA_SOURCES_DEST)' cydo.cpp || fail "Cydia-managed sources are not atomically published to the shared APT directory"
grep -Fq 'sources.list.d/cydia-added.list' postrm || fail "purge leaves the Cydia-managed shared source file behind"
! grep -Fq 'sileo.sources' postrm || fail "uninstall must never touch Sileo-owned source files"
grep -Fq 'UIActivityIndicatorViewStyleMedium' CyteKit/WebViewController.mm || fail "navigation spinner is missing"
! grep -Fq 'MSHookIvar<UIView *>([item view], "_badge")' MobileCydia.mm || fail "private tab badge spinner hack remains"
grep -Fq '[item setBadgeValue:nil]' MobileCydia.mm || fail "Sources refresh state is not cleared from the tab badge"
! grep -Fq '[item setBadgeValue:@""]' MobileCydia.mm || fail "ambiguous empty Sources activity badge remains"
grep -Fq 'style:CYModernGroupedTableStyle()' MobileCydia.mm || fail "inset grouped native lists are missing"
sections_controller="$(sed -n '/@implementation SectionsController/,/@end/p' MobileCydia.mm)"
grep -Fq 'UINavigationItemLargeTitleDisplayModeNever' <<<"$sections_controller" || fail "Sections still renders a duplicate oversized title"
grep -Fq 'return [self isEditing] ? 1 : 2;' MobileCydia.mm || fail "Sections does not separate All Packages from categories"
grep -Fq 'return @"CATEGORIES";' MobileCydia.mm || fail "Sections category group label is missing"
! grep -Fq 'CYSectionSymbolName' MobileCydia.mm || fail "Sections still use generic SF Symbol category artwork"
grep -Fq 'UIImageRenderingModeAlwaysOriginal' MobileCydia.mm || fail "Sections do not preserve full-color PNG artwork"
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
    [[ -f "MobileCydia.app/Sections/$icon" ]] || fail "canonical section artwork is missing: $icon"
done
expected_section_icons="$(printf '%s\n' "${section_icon_files[@]}" | LC_ALL=C sort)"
actual_section_icons="$(find MobileCydia.app/Sections -maxdepth 1 -type f -name '*.png' \
    -exec basename {} \; | LC_ALL=C sort)"
[[ "$actual_section_icons" == "$expected_section_icons" ]] || \
    fail "section artwork directory does not contain the exact 40-file icon set"
[[ ! -e MobileCydia.app/Sections/Folder_No_Section.png ]] || \
    fail "retired Folder_No_Section artwork remains in the application resources"
grep -Fq '[countLabel_ setBackgroundColor:[UIColor clearColor]]' MobileCydia.mm || fail "Sections still uses oversized count pills"
grep -Fq 'return CYModernSectionRowHeight();' MobileCydia.mm || fail "Sections rows do not adapt to Dynamic Type"
grep -Fq 'UISearchController' MobileCydia.mm || fail "modern native Search controller is missing"
grep -Fq 'CYPackageMatchesSileoSearch' MobileCydia.mm || fail "Search does not use the Sileo-compatible local fields"
grep -Fq 'sortUsingFunction:CYSearchPackageCompare' MobileCydia.mm || fail "Search does not use stable Sileo-style ranking"
! grep -Fq 'usePrefix' MobileCydia.mm || fail "Search still swaps result modes after keyboard submit"
grep -Fq 'return [self rowHeight];' MobileCydia.mm || fail "explicit modern package row height is missing"
grep -Fq 'if ([candidate count] == 0)' MobileCydia.mm || fail "empty alphabet sections are not compacted"
grep -Fq '[table setTableHeaderView:modeHeader_]' MobileCydia.mm || fail "Installed mode control is not separated from the compact navigation row"
grep -Fq '[title setText:CYLocalize(@"Search Packages")]' MobileCydia.mm || fail "native Search empty state is missing"
grep -Fq 'CYModernPackageRowHeight' MobileCydia.mm || fail "package rows do not adapt to Dynamic Type"
grep -Fq 'CYModernSourceRowHeight' MobileCydia.mm || fail "source rows do not adapt to Dynamic Type"
grep -Fq 'updateModeHeaderForCurrentContentSize' MobileCydia.mm || fail "Installed mode header does not adapt to Dynamic Type"
grep -Fq '[finish_ heightAnchor] constraintGreaterThanOrEqualToConstant:54.0f' Cydia/ModernNativeViews.mm || fail "Progress completion action can clip Dynamic Type"
grep -Fq 'setRowHeight:UITableViewAutomaticDimension' Cydia/RepositoryAccounts.mm || fail "repository account rows do not support Dynamic Type"
grep -Fq '@interface CydiaModernProgressTrack' Cydia/ModernNativeViews.mm || fail "compact native Progress track is missing"
grep -Fq 'CydiaCompactProgressSweep' Cydia/ModernNativeViews.mm || fail "compact Progress indeterminate sweep is missing"
grep -Fq '[fillLayer_ setColors:' Cydia/ModernNativeViews.mm || fail "compact Progress gradient is missing"
grep -Fq 'NSLayoutConstraint *logHeight_' Cydia/ModernNativeViews.mm || fail "Progress details do not use one stable height constraint"
grep -Fq '[logHeight_ setConstant:expanded_ ? 150.0f : 0.0f]' Cydia/ModernNativeViews.mm || fail "Progress details do not expand through their stable constraint"
! grep -Fq 'compactLogHeight_' Cydia/ModernNativeViews.mm || fail "obsolete collapsible-log constraint remains"
! grep -Fq 'expandedLogBottom_' Cydia/ModernNativeViews.mm || fail "obsolete expanded-log constraint remains"
! sed -n '/- (void) toggleDetails {/,/^}/p' Cydia/ModernNativeViews.mm | grep -Fq 'setActive:' || fail "Progress details still toggles Auto Layout constraints unsafely"
! grep -Fq 'CydiaLegacyProgressView' Cydia/ModernNativeViews.mm || fail "obsolete card-based Progress implementation remains"
! grep -Fq 'progressCard' Cydia/ModernNativeViews.mm || fail "Progress still uses the old primary card"
! grep -Fq 'stageCard' Cydia/ModernNativeViews.mm || fail "Progress still shows the old four-stage card"
! grep -Fq 'Activity Log' Cydia/ModernNativeViews.mm || fail "Progress still exposes the oversized Activity Log card"
grep -Fq '[log_ setHidden:YES]' Cydia/ModernNativeViews.mm || fail "technical Progress log is visible by default"
grep -Fq '[details_ setHidden:NO]' Cydia/ModernNativeViews.mm || fail "Progress activity details are inaccessible"
grep -Fq '[percent_ setText:error_ || cancelled_ ? CYLocalize(@"Stopped") : CYLocalizedPercent(1.0)]' Cydia/ModernNativeViews.mm || fail "failed Progress can still present a misleading 100 percent label"
grep -Fq '@"Some sources may still show older package data"' Cydia/ModernNativeViews.mm || fail "failed refresh does not explain its cached-data fallback"
grep -Fq 'LastUpdateWarnings' MobileCydia.mm || fail "partial refresh warnings are not persisted"
! grep -Fq '@"Ready with source warnings"' Cydia/ModernNativeViews.mm || fail "Home still duplicates repository warning state"
grep -Fq 'return verified;' MobileCydia.mm || fail "partial source refresh can still be returned as fully verified"
grep -Fq 'background refresh event routedTo=home' MobileCydia.mm || fail "late background warnings can still create an already-completed Progress sheet"
grep -Fq 'IsSourceSecurityRejection' CyteKit/ExternalSourceCompatibility.hpp || fail "source signature failures are not isolated safely"
grep -Fq 'IsSecurityAdvisory' CyteKit/ExternalSourceCompatibility.hpp || fail "APT security companion messages are not classified"
grep -Fq 'IsAcceptedMissingPublicKeyWarning' CyteKit/ExternalSourceCompatibility.hpp || fail "accepted legacy missing-key warnings are not distinguished from rejected indexes"
grep -Fq 'action=accepted-legacy-missing-key' MobileCydia.mm || fail "accepted legacy signing-key compatibility is not diagnosable"
grep -Fq '![lastDate isEqualToString:date]' MobileCydia.mm || fail "Changes still repeats identical date-only sections after same-day refreshes"
grep -Fq 'IsSourcePackageIndex404' CyteKit/ExternalSourceCompatibility.hpp || fail "source-local Packages failures are not classified"
# Refresh resilience runtime: a single broken/offline/404/unsigned source must
# stay isolated so the refresh remains usable and the package list is not wiped;
# a malformed Packages index is quarantined rather than aborting the refresh.
grep -Fq 'isolated:&sourceIsolated failures:&isolatedFailures' MobileCydia.mm || fail "refresh does not classify source-local failures for isolation"
grep -Fq 'bool usable(!cancelled && !fatal && quarantined == 0 && (success || sourceIsolated))' MobileCydia.mm || fail "an isolated broken source no longer keeps the refresh usable (list could be wiped)"
grep -Fq 'CanIsolateOperation' MobileCydia.mm || fail "source-local failure isolation gate is missing from the refresh path"
grep -Fq 'CYQuarantineMalformedPackageLists' MobileCydia.mm || fail "malformed Packages indexes are not quarantined during refresh"
grep -Fq 'refreshFailure ? @"Refresh Failed" : @"Transaction Failed"' MobileCydia.mm || fail "failed operation title is not explicit"
! grep -Fq '[finish_ setTitle:@"…"' Cydia/ModernNativeViews.mm || fail "running transaction still shows the obsolete ellipsis action"
grep -Fq 'navigationTitle = CYLocalize(@"Applying")' MobileCydia.mm || fail "transaction navigation title still exposes the raw RUNNING token"
grep -Fq 'setConfirmTitle:actionTitle destructive:destructive enabled:enabled' MobileCydia.mm || fail "confirmation integrity state is not connected"
! grep -Fq 'publisherVerified' MobileCydia.mm Cydia/ModernNativeViews.h Cydia/ModernNativeViews.mm || fail "confirmation still exposes source Trust state"
! grep -Fq '@"Review Source"' MobileCydia.mm || fail "obsolete source-review action remains"
! grep -Fq 'reviewPackageSourcesButtonClicked' MobileCydia.mm || fail "obsolete source-review callback remains"
grep -Fq 'activeActions == 1 ? primaryAction : CYLocalize(@"Apply Changes")' MobileCydia.mm || fail "confirmation button is not operation-aware"
grep -Fq 'initWithDatabase:database_ requestedIdentifiers:effectiveIdentifiers' MobileCydia.mm || fail "confirmation loses the complete explicit user selection"
grep -Fq '_H<NSMutableSet> queuedRequestedIdentifiers_' MobileCydia.mm || fail "continued package queues do not retain explicit user selections"
grep -Fq '[self recordRequestedPackage:package]' MobileCydia.mm || fail "direct installs/removals are not separated from automatic dependencies"
grep -Fq '@"dependencies"' MobileCydia.mm || fail "APT-added dependencies are not separated from direct upgrades"
grep -Fq 'CYLocalizedMetric(CYLocalize(@"Upgrades"), requestedUpgradeCount)' MobileCydia.mm || fail "upgrade confirmation omits the localized direct-upgrade count"
grep -Fq 'CYLocalizedMetric(CYLocalize(@"Dependencies"), dependencyCount)' MobileCydia.mm || fail "upgrade confirmation omits the separate localized dependency count"
grep -Fq 'classification=sileo-style' MobileCydia.mm || fail "transaction classification is not diagnosable"
grep -Fq '[[self navigationItem] setTitle:CYLocalize(@"Review Changes")]' MobileCydia.mm || fail "confirmation still uses the oversized generic title"
grep -Fq '@"Downloads checked before installation"' Cydia/ModernNativeViews.mm || fail "confirmation integrity status is missing"
grep -Fq 'CYConfirmationIssueSections(issues_' MobileCydia.mm || fail "APT dependency issues are not connected to native confirmation"
grep -Fq '@"PACKAGE ISSUES"' Cydia/ConfirmationIssues.h || fail "confirmation hides unresolved requirement details"
grep -Fq '[progressLabels_ setHidden:!running_]' Cydia/ModernNativeViews.mm || fail "completed transaction status still risks stale transfer text"
grep -Fq 'UIActivityIndicatorViewStyleLarge' Cydia/LoadingView.mm || fail "large modern blocking-operation spinner is missing"
grep -Fq '[container_ setBackgroundColor:[UIColor clearColor]]' Cydia/LoadingView.mm || fail "blocking loading content is not cardless"
grep -Fq '[self setBackgroundColor:[[UIColor systemGroupedBackgroundColor] colorWithAlphaComponent:0.88f]]' Cydia/LoadingView.mm || fail "modern blocking loading overlay is missing"
grep -Fq 'CydiaLoadingView *hud' MobileCydia.mm || fail "modern blocking loading surface is not integrated"
grep -Fq 'posix_spawn(&Process, Method.c_str()' apt64/apt-pkg/acquire-worker.cc || fail "APT methods still use unsafe cold-launch fork on modern iOS"
if sed -n '/bool pkgAcquire::Worker::Start()/,/Worker::ReadMessages/p' apt64/apt-pkg/acquire-worker.cc | \
    grep -Fq 'ExecFork'; then
    fail "APT method startup still enters a fork child"
fi
! grep -Fq 'UIProgressHUD' MobileCydia.mm || fail "legacy black square UIProgressHUD remains active"
! grep -Fq '@interface UIProgressHUD' iPhonePrivate.h || fail "unused legacy UIProgressHUD declaration remains"
grep -Fq '_H<CydiaModernProgressView> modernProgressView_' MobileCydia.mm || fail "native full-screen Progress surface is not retained by its controller"
grep -Fq '_H<CydiaModernConfirmationView> modernConfirmationView_' MobileCydia.mm || fail "native confirmation surface is not retained by its controller"
grep -Fq 'cancellationRequested_' MobileCydia.mm || fail "package cancellation is lost when the acquire phase stops"
grep -Fq '[modernProgressView_ setCancelledState:YES]' MobileCydia.mm || fail "cancelled downloads can appear successful"
grep -Fq 'confirmationStarted_' MobileCydia.mm || fail "duplicate confirmation can start another transaction"
grep -Fq 'CYRepositoryRedirectIsAllowed([task originalRequest], request)' Cydia/RepositoryAccounts.mm || fail "account redirects do not retain their credential boundary"
grep -Fq 'setTimeoutIntervalForResource:30.0' Cydia/RepositoryAccounts.mm || fail "account request has no total timeout"
grep -Fq 'generation != authenticationGeneration_' Cydia/RepositoryAccounts.mm || fail "stale sign-in completion can alter a newer session"
grep -Fq 'includePaymentSecret = YES' Cydia/RepositoryAccounts.mm || fail "payment secret lacks an authenticated-use gate"
ok "native modern Home, layout-safe lists, Search, Progress, confirmation and package surfaces"

! grep -Eq 'BridgedHosts_|InsecureHosts_|AppCacheController|addBridgedHost:|addInsecureHost:' MobileCydia.mm || fail "remote WebView privilege bridge remains active"
grep -Fq 'if ([scheme isEqualToString:@"file"])' MobileCydia.mm || fail "native WebView bridge is not restricted to local files"
! grep -Eq 'forKey:@"cydia(Confirm|Progress)"|/#!/(confirm|progress|package)/' MobileCydia.mm || fail "native transaction surface still loads or bridges remote UI"
grep -Fq '[table_ setRowHeight:UITableViewAutomaticDimension]' Cydia/ModernNativeViews.mm || fail "confirmation rows do not support Dynamic Type"
! grep -Eq '\[\[(row|details_|finishDock_|actionDock_?|firstRow|secondRow|statistics) heightAnchor\] constraintEqualToConstant:' Cydia/ModernNativeViews.mm || fail "fixed text-container height blocks Dynamic Type"
ok "remote content isolation and Dynamic Type safety"

grep -Fq '_config->Set("Acquire::AllowInsecureRepositories", true)' MobileCydia.mm || fail "unsigned repository compatibility is missing"
grep -Fq '_config->Set("Acquire::AllowWeakRepositories", true)' MobileCydia.mm || fail "legacy-signature compatibility is missing"
grep -Fq '_config->Set("Acquire::AllowDowngradeToInsecureRepositories", true)' MobileCydia.mm || fail "legacy repository downgrade compatibility is missing"
grep -Fq '_config->Set("Acquire::Check-Valid-Until", false)' MobileCydia.mm || fail "expired legacy repository compatibility is missing"
grep -Fq '_config->Set("APT::Get::AllowUnauthenticated", true)' MobileCydia.mm || fail "packages from unsigned metadata cannot be acquired"
grep -Fq 'bool const AllowMissingPublicKey = MissingPublicKey' apt64/apt-pkg/acquire-item.cc || fail "missing legacy repository keys still force stale package indexes"
grep -Fq 'FileExists(Final) && AllowMissingPublicKey == false' apt64/apt-pkg/acquire-item.cc || fail "keyless compatibility does not preserve strict handling for other signature failures"
! grep -Fq 'cp -a Trusted.gpg' makefile.ondevice || fail "obsolete repository keys are still installed by Cydia"
grep -Fq 'no Cydia-managed repository signing keys are packaged' verify-package-ondevice.sh || fail "package verification does not reject bundled repository keys"
! grep -Fq 'Cydia::TrustedRepositories::' MobileCydia.mm apt64/apt-pkg/deb/debmetaindex.cc || fail "obsolete per-source Trust override remains"
! grep -Eq 'CY(SetRepositoryExplicitTrust|ApplyExplicitRepositoryTrust|RepositoryIsExplicitlyTrusted|RepositoryTrustWarning)' MobileCydia.mm || fail "obsolete Trust implementation remains"
grep -Fq '[Values_ removeObjectForKey:@"ExplicitlyTrustedRepositoryURIs"]' MobileCydia.mm || fail "stored legacy Trust preferences are not migrated away"
! grep -Eq '@"(Review Source|Source Approval Required|Allow This Source|Allow & Refresh|Trust This Source|Trust & Refresh)' MobileCydia.mm || fail "obsolete Trust UI remains"
! grep -Fq 'not approved' MobileCydia.mm Cydia/ModernNativeViews.mm || fail "package confirmation still blocks on source approval"
grep -Fq 'expectedSize=%llu verification=APT-hash-and-size-unchanged' MobileCydia.mm || fail "package download plan no longer records hash/size verification"
grep -Fq '_error->Error("Unsafe redirect blocked")' apt64/methods/http.cc || fail "HTTPS downgrade protection is missing"
grep -Fq '@"LastUpdateSourceIssues"' MobileCydia.mm || fail "exact source failure reasons are not persisted"
grep -Fq '@"LastUpdateUsable"' MobileCydia.mm || fail "source completion cannot distinguish usable data from a failed refresh"
grep -Fq 'CYRepositoryRefreshReadyForUse()' MobileCydia.mm || fail "usable source data cannot transition to the green completion state"
grep -Fq 'reason=stale-source-snapshot' MobileCydia.mm || fail "stale source rows can still open All Sources"
grep -Fq 'return [key length] == 0 ? nil : [database_ sourceWithKey:key];' MobileCydia.mm || fail "source selection does not resolve through a stable APT key"
grep -Fq 'setUnavailableSource' MobileCydia.mm || fail "temporarily unavailable source rows still masquerade as All Sources"
grep -Fq 'BOOL preserveIcon(sameSource && icon_ != nil' MobileCydia.mm || fail "source rows still discard their artwork during refresh completion"
grep -Fq 'if (sameStructure)' MobileCydia.mm || fail "source refresh still rebuilds unchanged rows"
grep -Fq '[UIView performWithoutAnimation:^' MobileCydia.mm || fail "source completion list update can still flash UIKit transitions"
grep -Fq 'SecurityIssueCode' CyteKit/ExternalSourceCompatibility.hpp || fail "source signature failure reasons are not classified"
grep -Fq 'Acquire::CompressionTypes::Order", "zst,xz,bz2,gz,lzma,lz4"' MobileCydia.mm || fail "modern compressed Packages fallback order is incomplete"
# Rootless package reading + empty/invalid source detection. Packages must be
# read for the rootless architecture (iphoneos-arm64) at the APT layer. Source
# entry follows Sileo's single Release probe with an explicit Add Anyway path;
# the serialized APT refresh is authoritative and supports every configured
# compression instead of waiting on seven parallel legacy HEAD requests.
grep -Fq '_config->Set("APT::Architecture", "iphoneos-arm64")' MobileCydia.mm || fail "APT does not read packages for the rootless architecture"
grep -Fq '_config->Set("APT::Architectures", "iphoneos-arm64")' MobileCydia.mm || fail "rootless architecture list is not enforced for package reading"
grep -Fq 'stringByAppendingString:@"Release"' MobileCydia.mm || fail "add-source does not perform Sileo-compatible Release validation"
grep -Fq 'addAnywayAvailable=1' MobileCydia.mm || fail "temporarily offline or HEAD-rejecting repositories cannot be added explicitly"
[[ "$(grep -Fc '_requestHRef:' MobileCydia.mm)" -eq 2 ]] || fail "add-source still starts redundant parallel validation requests"
# Bottom tab bar behavior: Home and Sources keep a fixed tab bar (no auto-hide
# on scroll); the other three tabs still hide on scroll and ease the bar back
# in over a dim-to-full two-stage fade instead of snapping on at once.
grep -Fq 'modernScrollTabBarHidingEnabled' CyteKit/ViewController.mm || fail "scroll tab-bar hiding hook is missing"
[[ "$(grep -Fc 'modernScrollTabBarHidingEnabled' MobileCydia.mm)" -ge 2 ]] || fail "Home and Sources do not both keep a fixed tab bar"
grep -Fq 'animateKeyframesWithDuration' CyteKit/TabBarController.mm || fail "tab bar no longer eases back in over two stages"
grep -Fq 'setAlpha:0.35f' CyteKit/TabBarController.mm || fail "tab bar reappearance lost its dim-to-full stage"
ok "keyless repository compatibility and package integrity boundary retained"

grep -Fq 'stringByAppendingString:@".tmp"' Sources.mm || fail "managed source list is not staged before replacement"
grep -Fq 'fsync(fileno(file))' Sources.mm || fail "managed source list is not durably flushed"
grep -Fq 'rename(temporaryPath, sources)' Sources.mm || fail "managed source list replacement is not atomic"
grep -Fq 'AcquireDpkgLock("/var/jb/var/lib/dpkg/lock-frontend", 45)' cydo.cpp || fail "dpkg frontend lock is not serialized with other package managers"
grep -Fq 'AcquireDpkgLock("/var/jb/var/lib/dpkg/lock", 45)' cydo.cpp || fail "dpkg database lock is not serialized with other package managers"
grep -Fq 'rebuildTransactionForRequestedIdentifiers' MobileCydia.mm || fail "status drift cannot safely rebuild the explicit transaction"
grep -Fq 'automatic retry start attempt=1 maxAttempts=1' MobileCydia.mm || fail "status-drift recovery is not bounded"
grep -Fq 'const auto failPrepare = [&]() -> bool' MobileCydia.mm || fail "failed preparation cannot centrally release transaction resources"
grep -Fq 'if (manager_ == NULL)' MobileCydia.mm || fail "package preparation can dereference a missing APT package manager"
grep -Fq 'prepare cleanup archiveLockReleased=1 packageManagerReleased=1' MobileCydia.mm || fail "failed preparation lock cleanup is not diagnosable"
grep -Fq 'transactionOperationsForRequestedIdentifiers' MobileCydia.mm || fail "explicit package operations cannot be snapshotted across an APT reload"
grep -Fq 'restoreTransactionOperations:queuedOperations title:@"Package Queue"' MobileCydia.mm || fail "source refresh can still discard a continued package queue"
grep -Fq 'Queuing_ = queueRestored;' MobileCydia.mm || fail "queue UI state is not derived from successfully restored operations"
grep -Fq 'Queuing_ = [effectiveIdentifiers count] != 0;' MobileCydia.mm || fail "failed preparation still leaves an invisible half-queue"
ok "atomic source persistence, queue preservation and serialized recoverable dpkg commit"

grep -Fq 'Cache("dpkg-transaction.incomplete")' MobileCydia.mm || fail "persistent dpkg crash marker is missing"
grep -Fq '@"transaction marker armed"' MobileCydia.mm || fail "dpkg marker is not armed before execution"
grep -Fq '@"interrupted transaction detected cachesInvalidated=1"' MobileCydia.mm || fail "interrupted transaction is not recovered at launch"
grep -Fq 'unlink([Cache("pkgcache.bin") UTF8String]);' MobileCydia.mm || fail "interrupted transaction does not invalidate generated package state"
grep -Fq 'IsAlreadyConfiguredStatusError' apt64/apt-pkg/deb/dpkgpm.cc || fail "idempotent configure result is not classified"
grep -Fq 'Op == Item::Configure && explicitPackageArguments == 1' apt64/apt-pkg/deb/dpkgpm.cc || fail "configure recovery is not restricted to one explicit package"
grep -Fq 'WIFEXITED(Status) != 0 && WEXITSTATUS(Status) == 1' apt64/apt-pkg/deb/dpkgpm.cc || fail "configure recovery is not restricted to dpkg exit code 1"
grep -Fq 'd->current_status_had_fatal_error == false' apt64/apt-pkg/deb/dpkgpm.cc || fail "configure recovery can mask a companion fatal dpkg error"
grep -Fq 'd->progress->Error(d->deferred_status_error_package' apt64/apt-pkg/deb/dpkgpm.cc || fail "unaccepted deferred dpkg errors are not restored to the fatal path"
ok "interrupted and idempotent dpkg transaction recovery is narrowly bounded"

grep -Fq 'RetiredLegacyWebViews_' CyteKit/WebViewController.mm || fail "iOS 17 WebKitLegacy retirement pool is missing"
grep -Fq 'CYRetireLegacyWebView(webview_)' CyteKit/WebViewController.mm || fail "legacy web views bypass safe retirement"
grep -Fq 'if ([self isViewLoaded])' CyteKit/WebViewController.mm || fail "controller deallocation can bypass web view retirement"
grep -Fq '[self setView:nil]' CyteKit/WebViewController.mm || fail "controller does not route teardown through releaseSubviews"
grep -Fq 'reason=ios17-webkitlegacy-timer-teardown' CyteKit/WebViewController.mm || fail "WebKitLegacy crash workaround is not diagnosable"
grep -Fq 'action=skipped surface=%@ reason=native-surface-ios17-timer-safety' MobileCydia.mm || fail "native WebKit-skip diagnostic is missing"
for surface in confirmation progress package-details; do
    grep -Fq "CYModernNativeControllerRoot(@\"$surface\")" MobileCydia.mm || \
        fail "$surface still constructs a hidden WebKitLegacy page"
done
! grep -Fq '[[self webView] addSubview:modernConfirmationView_]' MobileCydia.mm || fail "native confirmation still sits on a UIWebView"
! grep -Fq '[[self webView] addSubview:modernProgressView_]' MobileCydia.mm || fail "native progress still sits on a UIWebView"
! grep -Fq 'UIScrollView *legacyScroll([[self webView] scrollView]);' MobileCydia.mm || fail "native Package Details still constructs a hidden UIWebView"
dispatch_body="$(sed -n '/- (void) dispatchEvent:(NSString \*)event {/,/^}/p' CyteKit/WebViewController.mm)"
printf '%s\n' "$dispatch_body" | grep -Fq 'if (webview_ == nil)' || fail "native controllers can still dispatch lifecycle events without a WebView"
printf '%s\n' "$dispatch_body" | grep -Fq '[webview_ dispatchEvent:event]' || fail "legacy WebView lifecycle dispatch no longer reaches the retained WebView"
! printf '%s\n' "$dispatch_body" | grep -Fq '[[self webView] dispatchEvent:event]' || fail "native root UIView can still receive the legacy dispatchEvent selector"
ok "iOS 17 WebKitLegacy teardown guard and WebKit-free package transaction path"

unused=(
    makefile.mac prepare-mac.sh source-preflight-mac.sh verify-package-mac.sh
    build-ondevice.sh build-trollstore-r2-mac.sh verify-trollstore-r2-mac.sh
    trollstore-r2-source-audit.sh TrollStoreR2 tests final-release-audit.sh
    ORIGINAL_UI_SHA256.txt diagnose-after-failed-install.sh install-ondevice.sh
    install-preflight-ondevice.sh recover-install-ondevice.sh release-diagnostics.sh
    rootless-architecture-preflight.sh rootless-safety-preflight.sh
    runtime-methods-preflight.sh runtime-update-ondevice.sh
    generate-gnutls-tbd.sh Cydia/ModernTransactionViews.h
    Cydia/ModernTransactionViews.mm apt64/doc apt64/po apt64/test apt64/debian
    apt64/CMake apt64/apt-inst apt64/apt-private apt64/cmdline
    apt64/completions apt64/dselect apt64/ftparchive apt64/vendor apt64/abicheck
    apt64/apt-pkg/CMakeLists.txt apt64/apt-pkg/edsp
    apt64/methods/CMakeLists.txt apt64/methods/cdrom.cc
    apt64/methods/ftp.cc apt64/methods/ftp.h apt64/methods/mirror.cc
    apt64/methods/rsh.cc apt64/methods/rsh.h apt64/triehash/.travis.yml
    apt64/triehash/README.md apt64/triehash/tests
    Compat/memrchr.h SDURLCache/SDURLCacheTests.m uikit.sh COPYING
    cydia-lproj.control ../Version.h
)
for path in "${unused[@]}"; do
    [[ ! -e "$path" ]] || fail "unused build content remains: $path"
done
ok "obsolete build, legacy UI and unused APT trees are absent"

generated=(
    MobileCydia postinst cydo du setnsfpn cfversion
    aptmethod.h http.cc http.h Cydia.deb
    Objects Images _ __ bins Cydia_Rootless_Package.log
    postinst.dSYM cydo.dSYM du.dSYM setnsfpn.dSYM cfversion.dSYM
    MobileCydia.dSYM
)
for path in "${generated[@]}"; do
    [[ ! -e "$path" && ! -L "$path" ]] || fail "generated build residue remains: $path"
done
[[ ! -e ../_backups ]] || fail "obsolete source backup directory remains"
[[ ! -e ../build-logs ]] || fail "build logs are still being stored inside the source project"
grep -Fq -- '-Xanalyzer -analyzer-output=text' ../mac-quality-audit.sh || \
    fail "Mac static analysis can still emit plist files into the source tree"
# Finder can recreate .DS_Store at any moment while a Desktop folder is open.
# Both build entry points remove it before/after the build, and the package
# verifier below rejects any Finder metadata in the actual release payload.
if find . -maxdepth 1 \( -type f -o -type l \) -name '* [0-9]*' -print -quit | grep -q .; then
    fail "numbered Finder duplicate remains in the Cydia source root"
fi
if find . -maxdepth 1 -type f -name '*.plist' -print -quit | grep -q .; then
    fail "generated Clang analyzer plist remains in the Cydia source root"
fi
ok "source tree contains no backups, numbered copies or generated build residue"

scripts=(
    modern-source-audit.sh ondevice-sdk.sh package-ondevice.sh prepare-ondevice.sh
    verify-package-ondevice.sh normalize-app-permissions.sh control.sh pngcrush.sh version.sh
    preinst prerm postrm Library/asuser Library/finish.sh Library/firmware.sh
    Library/free.sh Library/move.sh Library/startup
    ../device-build.sh ../mac-quality-audit.sh ../mac-build.sh ../mac-dpkg-deb.sh
)
for script in "${scripts[@]}"; do
    bash -O extglob -n "$script" || fail "shell syntax failed: $script"
done
ok "all retained shell entry points pass Bash syntax"

! grep -Eq 'caption_|displayText_|CYM3FeaturedCaptionHeight' Cydia/ModernNativeViews.mm || fail "Home artwork still has app-added captions"
grep -Fq 'return [CYLocalize(@"PACKAGE QUEUE") localizedCapitalizedString];' Cydia/ModernNativeViews.mm || fail "readable queue heading is missing"
grep -Fq '[actionContent_ setAlignment:UIStackViewAlignmentFill]' Cydia/ModernNativeViews.mm || fail "confirmation action does not use the available width"
grep -Fq 'CYTransactionCanConfirm(changes_, issues_, confirmationStarted_)' MobileCydia.mm || fail "empty or repeated transactions are not guarded"
grep -Fq 'if (image == nil) image = [UIImage systemImageNamed:name];' CyteKit/ModernAppearance.mm || fail "new symbols lack older OS fallbacks"
grep -Fq 'if (![[self image] isSymbolImage])' CyteKit/ModernAppearance.mm || fail "symbol rendering can modify package artwork"

! grep -Eq 'mediumDetent|DetentIdentifierMedium' MobileCydia.mm || fail "Cydia-owned panels can still collapse to medium height"
grep -Fq 'Icon: https://barabadev.com/assets/cydia.png' cydia.control || fail "pre-install package icon URL missing"
cmp -s ../RepositoryAssets/assets/cydia.png MobileCydia.app/Icon-60@3x.png || fail "repository icon differs from app icon"
echo "MINIMAL SOURCE AUDIT PASSED"
