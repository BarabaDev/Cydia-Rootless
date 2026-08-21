# Cydia for iOS 15+ Rootless

A public rootless port of Cydia for modern jailbreak environments using the `/var/jb` bootstrap layout.

**Release:** `1.1.49+rootless.3`  
**Architecture:** `iphoneos-arm64`  
**Minimum target:** iOS 15.0  
**Rootless prefix:** `/var/jb`

This project preserves the original Cydia interface and behavior wherever possible while adapting the package manager, APT/dpkg integration and runtime helpers for modern rootless jailbreaks.

## Highlights

- Rootless `/var/jb` application and package layout
- `iphoneos-arm64` Debian packaging
- On-device build support from a terminal
- Sources refresh, add and delete persistence
- Repository names from Release/InRelease metadata
- Rootless package filtering without rootful duplicates
- BigBoss legacy signature compatibility
- Live install, upgrade and removal progress
- Package Settings → Ignore Upgrades support
- Cydia + Sileo finish-control protocol compatibility
- Userspace reboot handling for `finish:usreboot`
- Persistent diagnostics at `/var/mobile/Documents/Cydia_Rootless_Diagnostics.log`

## Build on device

Clone the current public source directly from GitHub, then run the release builder:

```sh
cd /var/mobile/Documents && rm -rf Cydia_Rootless && git clone https://github.com/BarabaDev/Cydia-Rootless.git Cydia_Rootless && cd Cydia_Rootless && chmod +x run-build.sh && ./run-build.sh
```

For a tagged release archive, download the ZIP from GitHub Releases, place it in `/var/mobile/Documents`, extract it as `Cydia_Rootless`, then run `./run-build.sh`.

The release runner performs rootless safety checks, builds Cydia, packages and verifies the Debian files, applies the confirmed on-device runtime update workflow, and runs release diagnostics/preflight checks.

The final verifier checks both package names, the exact release version, `iphoneos-arm64` architecture, rootless payload paths, maintainer-script permissions and the privileged `cydo` mode before installation.

Before the local package pair is installed, the runtime updater verifies the XZ dependency and installs Procursus `xz-utils` through APT when neither it nor a legacy `xz` provider is already installed. This also repairs the dependency state left by an interrupted same-version `dpkg` installation.

The linked application embeds `/var/jb/usr/lib` as a Mach-O runtime search path so SpringBoard can resolve Procursus `@rpath` libraries without relying on terminal environment variables.

## Build requirements

The on-device preparation checks for the required toolchain, including `clang`, `clang++`, `make`, `ldid`, `fakeroot`, `dpkg-deb`, `ar`, `git`, `perl`, `sed`, `find`, `install_name_tool` and `tar`. The embedded pinned APT HTTP method also requires the Procursus `libgnutls30-dev` package (headers and linker symlink); install it with `sudo apt-get install libgnutls30-dev` if the preflight reports it missing. The build uses the iPhoneOS SDK available under the rootless bootstrap and a pinned APT source revision. Network access to `https://git.bingner.com/apt.git` is required when the pinned APT commit is not already available locally.

Only the supported on-device `makefile.ondevice` workflow is included. Obsolete Fink/Xcode wrapper scripts and the unused Apple TV appliance source are excluded from this public release.

## Packages

The build produces:

- `cydia_1.1.49+rootless.3_iphoneos-arm64.deb`
- `cydia-lproj_1.1.49+rootless.3_iphoneos-arm64.deb`

Compatibility symlinks `Cydia.deb` and `Cydia_.deb` are also created by the build system.

## Trust store

The public package intentionally retains only:

- `bigboss.gpg`

No hardcoded default repository list is bundled by the active package recipe.

## Diagnostics

Runtime diagnostics are written to:

```text
/var/mobile/Documents/Cydia_Rootless_Diagnostics.log
```

The log covers Sources/Refresh, APT, package transactions, `cydo`/dpkg, dependency failures, finish actions, URL/Support handling and other release-critical operations.

## Credits

Cydia was originally created by **Jay Freeman (saurik)**. This rootless edition adapts the project for modern rootless jailbreak environments.

Rootless Edition © 2026  
**BarabaDev**  
X: `@barabadev`  
https://barabadev.com/

## License

See [`LICENSE`](LICENSE) for the GNU GPLv3 license text.

## Disclaimer

This is an unofficial community rootless port and is not presented as an official release from the original Cydia author. Use only on compatible jailbroken devices and keep a recovery path available before modifying package-management components.
