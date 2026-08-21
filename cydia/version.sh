#!/var/jb/bin/bash
set -euo pipefail

# Public rootless release version. Keep this fixed so Cydia Installer and
# Cydia Translations are built with exactly the same dpkg version and the
# compiled CYDIA_VERSION string matches the repository package version.
version="1.1.49+rootless.3"

define="#define CYDIA_VERSION \"${version}\""
before=$(cat Version.h 2>/dev/null || true)

if [[ ${before} != ${define} ]]; then
    echo "${define}" >Version.h
fi

echo "${version}"
