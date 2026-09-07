#pragma once

namespace CYArchiveIdentity {
// An empty APT iterator is a sentinel, not a package record. Check each
// relationship before formatting a name or constructing an archive request.
template <typename Version>
inline bool IsUsable(Version const &version) {
    if (version.end())
        return false;
    auto const package(version.ParentPkg());
    if (package.end() || package.Group().end() || version->VerStr == 0)
        return false;
    char const *name(package.Name());
    char const *architecture(package.Arch());
    return name != nullptr && *name != '\0' && architecture != nullptr && *architecture != '\0';
}
}
