# Cydia 1.1.24

Banner visibility update by BarabaDev on **8 September 2026**.

- High-resolution repository artwork is decoded directly into a display-sized image, fixing blank banners including Bohemic, Peek and other valid large images.
- Banner downloads share bounded retries for temporary connection failures. Missing artwork is retried when Home becomes visible again, and a cached invalid response can be refreshed once.
- Finished artwork is delivered directly to its cards, and memory-cache accounting uses decoded image size.
- Banner layout, artwork-only presentation, ordering and carousel motion are unchanged.
- Removed the unused pre-iOS-15 stashing path and its `free.sh` and `move.sh` scripts. Other compatibility helpers are retained.

The package version is `1.1.24` and the architecture is `iphoneos-arm64`.

# Cydia 1.1.23

Unofficial Modern Rootless edition modified by BarabaDev on **8 September 2026**. Original Cydia and Sam Bingner's contributions retain their original credits and license terms.

- Native package details, action menus, review, progress and installed-file browsing.
- A compact Modify menu with centered action names, SF Symbols beside available package actions and a separate Cancel button. Version selection, review and progress use a large sheet; transaction completion refreshes package data without replacing the visible sheet.
- Original Cydia color roles: UIKit blue navigation and actions, neutral adaptive surfaces, deep-blue paid package names, and original light-mode installation/removal row colors. Dark appearance and increased contrast use adaptive colors; destructive actions, warnings and success retain their distinct colors.
- Filled primary buttons preserve the normal system appearance and select a legible foreground when Increase Contrast is enabled.
- Essential upgrades continue into Review in the same sheet, with consistent first-run prompt ordering and retry behavior.
- Stable review rows while package icons load, and compact Installed Files rows with expandable folders and complete paths.
- Version selection uses an already cached package icon before falling back to category artwork.
- Portrait-only presentation on iPhone and iPad, including package and information sheets.
- About shows license information immediately; complete GPL, AGPL and component notices are available offline without license acceptance.
- Original repository banner artwork without additional captions, a five-point Cydia tab symbol and refreshed section icons.
- Home can show the first usable banner source without waiting for slower repositories. Cached image reads and decoding run in the background, duplicate image requests are shared, and existing cards resume missing artwork after privacy consent without rebuilding the carousel. A failed manual refresh retains visible banners.
- Repository accounts and purchased packages, accurate library metrics, and working User, Expert and Recent filters.
- Unused pull-to-refresh controls removed from Installed, Search, All Packages and category package lists, including individual repositories. Sources retains its refresh progress indicator.
- Complete interface catalogs for all 21 existing languages, translated categories and Face ID prompts, with locale-aware counts and percentages. Dynamic text and dark appearance remain supported.
- Rootless package verification, explicit dependency issues and serialized package operations; unresolved plans remain blocked.
- Repository credential updates are synchronized; stale requests cannot invalidate renewed credentials or restore an outdated account view.
- Repository purchase authentication includes the required localized Face ID usage description. Utility navigation controls use modern system symbols with localized accessibility labels.
- Web-view loading timers stop when their view is released and do not retain the controller.
- Web-view delegate initialization and request-copy ownership are balanced during reloads.
- Large-text confirmation summaries remain scrollable, including download size and package issues; package-information rows expose their current values to VoiceOver.
- Cancel requests remain effective through download completion, failed database reloads retain queued requests for retry, and changed transaction plans require a new review. Debian Essential flags remain authoritative.
- Firmware metadata maintenance uses the package database locks and defers while another package manager is active. Failed AutoInstall archives are retained for retry.
- The macOS package helper handles absolute and relative output paths consistently.

The package version is `1.1.23` and the architecture is `iphoneos-arm64`. Publication is a separate step from building and testing.
