# Cydia for iOS 15+ Rootless — 1.1.49+rootless.3

Public rootless release of Cydia for modern jailbreak environments using the `/var/jb` bootstrap layout.

This release includes rootless `iphoneos-arm64` packaging, Release/InRelease repository metadata handling, rootless package filtering, live APT/dpkg progress, Ignore Upgrades support, Cydia/Sileo finish-action compatibility, userspace reboot handling, BigBoss legacy signature compatibility and persistent diagnostics.

The public Cydia trust store is intentionally minimal and retains `bigboss.gpg` only.

This final audited package also removes the duplicate legacy `cydia.list` publisher, corrects recovery validation, synchronizes iOS 15.0 metadata, preserves executable script modes and includes clean GitHub ignore/license files.

The on-device build preflight checks for Procursus `libgnutls30-dev`, required by the embedded pinned APT HTTP method, and the produced Cydia package declares the matching `libgnutls30` runtime dependency.

The runtime updater resolves Procursus `xz-utils` before installing the local package pair, while the Debian dependency keeps a legacy `xz` provider fallback.

The application embeds the rootless `/var/jb/usr/lib` Mach-O runtime search path required to resolve Procursus `@rpath` libraries when launched from the Home Screen.

### Build

```sh
cd /var/mobile/Documents && rm -rf Cydia_Rootless && unzip Cydia_Rootless_GitHub_1.1.49+rootless.3_FINAL.zip && cd Cydia_Rootless && ./run-build.sh
```

### Output

- `cydia_1.1.49+rootless.3_iphoneos-arm64.deb`
- `cydia-lproj_1.1.49+rootless.3_iphoneos-arm64.deb`

Rootless Edition © 2026 — BarabaDev  
https://barabadev.com/
