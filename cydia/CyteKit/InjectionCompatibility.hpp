#ifndef CYTEKIT_INJECTION_COMPATIBILITY_HPP
#define CYTEKIT_INJECTION_COMPATIBILITY_HPP

#include <cstring>

namespace CYInjectionCompatibility {

inline bool IsInjectionDependency(const char *name) {
    if (name == NULL)
        return false;
    return std::strcmp(name, "mobilesubstrate") == 0 ||
        std::strcmp(name, "com.ex.substitute") == 0 ||
        std::strcmp(name, "ellekit") == 0 ||
        std::strcmp(name, "org.coolstar.libhooker") == 0;
}

inline const char *ProviderLabelForDependency(const char *name) {
    if (name == NULL)
        return "unknown";
    if (std::strcmp(name, "ellekit") == 0)
        return "ElleKit";
    if (std::strcmp(name, "org.coolstar.libhooker") == 0)
        return "libhooker-compatible";
    if (std::strcmp(name, "com.ex.substitute") == 0)
        return "Substitute";
    if (std::strcmp(name, "mobilesubstrate") == 0)
        return "MobileSubstrate-compatible";
    return "unknown";
}

}

#endif
