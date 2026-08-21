# Cydia Rootless 1.1.49+rootless.3

Public rootless release for iOS 15+ jailbreak environments using the `/var/jb` bootstrap layout and `iphoneos-arm64` packaging.

## Release highlights

- Finalized rootless `/var/jb` application, helper and APT/dpkg paths.
- Sources refresh and source add/delete persistence confirmed.
- Repository display names come from Release/InRelease metadata.
- Rootless package selection filters incompatible rootful duplicates.
- BigBoss legacy SHA1/DSA compatibility remains supported without fatal refresh errors.
- Install, upgrade and removal transactions show live progress through the original Cydia progress interface.
- Package Settings → Ignore Upgrades persists dpkg hold/unhold state.
- Cydia and Sileo finish-control protocols are both exposed to maintainer scripts.
- `finish:usreboot` keeps the visible `Reboot Device` action while performing a userspace reboot.
- Explicit `finish:reboot` remains a full device reboot.
- Persistent diagnostics are available at `/var/mobile/Documents/Cydia_Rootless_Diagnostics.log`.

## Public-release cleanup

- Version raised to `1.1.49+rootless.3` for repository upgrades.
- Public trust store reduced to `bigboss.gpg` only.
- Unused legacy keys `saurik.gpg` and `sbingner.gpg` removed.
- Obsolete `zodttd.gpg`, `modmyi.gpg` and `hbang.gpg` remain excluded.
- Obsolete bundled default source list removed.
- Development Git metadata, build artifacts, caches and internal revision files are not included.
- Maintainer-script permissions are enforced during packaging to prevent archive/extraction mode-loss issues.
- The release diagnostics runner is executable in the public ZIP and verified before build.
- Release-marker checks use an explicit `grep` option terminator so markers beginning with `--` work on Procursus grep.
- The pinned APT triehash generator is invoked through rootless `perl` from PATH instead of its unavailable rootful shebang.
- The embedded pinned APT HTTP connection code now links explicitly with GnuTLS, checks for Procursus `libgnutls30-dev` before compilation and declares `libgnutls30` as a runtime dependency.
- The installer now resolves the concrete Procursus `xz-utils` package before local `dpkg -i`; package metadata retains `xz` as a legacy-provider fallback and safely recovers an unpacked/unconfigured same-version installation.
- The Cydia Mach-O now embeds `LC_RPATH /var/jb/usr/lib`, allowing SpringBoard/dyld to resolve Procursus libraries such as `@rpath/libgnutls.30.dylib` during app launch.
- Removed the duplicate legacy `cydia.list` publisher; Cydia now publishes managed repositories only through `cydia-added.list`.
- Legacy source cleanup removes only Cydia's exact old symlink and preserves regular or foreign-owned source files.
- Recovery verification now correctly requires the obsolete Cydia APT pin file to be absent.
- App and Debian minimum-version metadata are synchronized with the iOS 15.0 target.
- Added root-level GPLv3 licensing, `.gitignore` and `.gitattributes` for clean GitHub checkouts.
- Removed obsolete Fink/Xcode build wrappers, the unused Apple TV appliance and the inactive legacy APT pin template.

## Package names

- `cydia_1.1.49+rootless.3_iphoneos-arm64.deb`
- `cydia-lproj_1.1.49+rootless.3_iphoneos-arm64.deb`
