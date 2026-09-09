# Cydia 1.1.27 Rootless

Cydia for rootless iOS 15 and later, based on the Cydia source supplied with this project. This unofficial edition was modified by BarabaDev on **9 September 2026**. It includes native package screens, repository accounts, adaptive layouts, dark appearance and 21 bundled localizations. It is not an official release or an endorsement by Jay Freeman (saurik), SaurikIT, LLC, or Sam Bingner.

Sources support individual Refresh actions and removal of Cydia-managed entries. Package rows provide quick actions while retaining the normal review and account flow. Manage Account shows the repository sign-in state separately from purchase ownership.

## Build on macOS

Install Xcode and the build dependencies: Homebrew, GNU sed (`gsed`), `ldid`, `dpkg`, GNU tar (`gtar`), `xz`, and GnuTLS. Apple’s command-line tools must point to the full Xcode installation with an iPhoneOS SDK.

From the repository root:

```sh
JOBS=4 ./mac-build.sh
```

The build audits the sources, compiles and signs the arm64 binaries, then creates and verifies:

```text
cydia/debs/cydia_1.1.27_iphoneos-arm64.deb
```

Temporary objects and staging directories are removed after the build. Build logs are written to the system temporary directory. Nothing is installed or published automatically. Generated DEBs are ignored by Git; distribute them separately as release assets.

## Build on a rootless device

Copy the source to the device and run from its root directory:

```sh
bash device-build.sh --clean --sdk /var/jb/var/mobile/theos/sdks/iPhoneOS16.5.sdk
```

Adjust the SDK path for your installed SDK. The script checks the environment, builds and verifies the package, then copies it to `/var/mobile/Documents`. It does not install it.

## Validation

```sh
./mac-quality-audit.sh
```

This runs source and resource audits, strict compilation and Clang static analysis. The build also verifies the generated package contents, localizations and resource permissions.

Actual APT/dpkg operations and restart behavior require validation on a rootless device; the build does not execute them.

The deployment target is iOS 15.0 on arm64 with a compatible rootless bootstrap. Building against a newer SDK does not establish support for every OS version or jailbreak. Simulator interface checks are separate from device validation of installation, purchases and restart behavior.

The app and helper do not create or automatically attach a Cydia Rootless diagnostics file. Upgrade cleanup removes only the previous app-owned diagnostic files; APT and dpkg operational logs remain available.

Use one package manager at a time for installation and removal. The helper locks individual dpkg invocations, but the app does not hold the frontend lock continuously across an entire multi-step transaction.

Repository compatibility currently permits unsigned, weakly signed and expired metadata. Package hash and size checks verify consistency with the repository metadata; they do not authenticate the publisher when that metadata is unauthenticated. Add only sources you trust.

## Repository publishing

Keep the metadata in `cydia/cydia.control` when generating the repository index. Upload the [repository icon](RepositoryAssets/README.md) so it is visible before installation. The version is **1.1.27**, so an installed 1.1.26 is eligible for a normal package update after the repository index is refreshed.

Publish the complete corresponding source for this exact build alongside the DEB, including resources, pinned APT sources, build scripts and licenses. Keep an immutable release tag or source archive and provide a clear source download link wherever the DEB is offered. A link to upstream Cydia or a changing development branch does not identify this build's corresponding source. Keep the source available for as long as the binary is offered. The app's source link is `https://github.com/BarabaDev/Cydia-Rootless`; upload the matching source there before distributing the DEB.

The copyright licenses do not establish permission to use trademarks or imply author endorsement. Any separate permission for the Cydia name or artwork must be assessed independently before publication.

## Languages

All 21 existing Cydia localizations are included in the main package. Each language has the complete 529-entry interface catalog, including 306 native-interface strings and a localized Face ID purpose. All 20 non-English languages also include the 54 category names; English uses the original category names. Counts and percentages follow the selected locale. English remains the fallback for unsupported languages and unknown strings. Package names, repository descriptions and original license texts retain their supplied content. The existing language set does not include Croatian.

## Source layout

- `cydia/`: app sources, resources, pinned APT inputs and rootless packaging.
- `RepositoryAssets/`: the public package icon and publishing instructions.
- Root build scripts: macOS and device build entry points and verification.

## License and credits

Original Cydia: Jay Freeman (saurik), SaurikIT, LLC. Modified Cydia base: Sam Bingner. Modern Rootless edition: BarabaDev.

Cydia source files retain GNU GPL version 3 or later terms. See [LICENSE](LICENSE). Cytore retains GNU AGPL version 3 or later terms; the combined work is subject to the applicable terms of both licenses, including section 13. APT retains GPL version 2 or later terms and its individual file notices. Original copyright and license headers remain in the sources.

The app includes the full GPL and AGPL texts and [component notices](cydia/MobileCydia.app/Licenses/NOTICES.txt), available offline from About. They are also installed under `/var/jb/usr/share/doc/cydia/`. These files are required release documentation. The license viewer does not require acceptance; the separate first-run privacy consent describes repository data handling.

See [CHANGELOG.md](CHANGELOG.md) for the changes in this edition.
