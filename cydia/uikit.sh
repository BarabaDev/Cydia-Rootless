#!/var/jb/bin/bash
set -e
# Historical Cydia patched the UIKit load command after linking with Xcode 5.
# Modern clang/ld on iOS 15+ emit the correct load command; leave the binary intact.
exit 0
