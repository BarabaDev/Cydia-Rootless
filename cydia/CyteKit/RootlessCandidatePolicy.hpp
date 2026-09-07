#ifndef CyteKit_RootlessCandidatePolicy_H
#define CyteKit_RootlessCandidatePolicy_H

#include <cstring>

namespace CYRootlessCandidatePolicy {

inline bool UsesNewestCompatiblePolicy(const char *package) {
    return package != NULL && std::strcmp(package, "preferenceloader") == 0;
}

// comparison is the Debian version comparison of candidate against best.
// Ordinary packages remain priority-first. The narrow shared-framework policy
// is version-first and uses priority only when the versions are identical.
inline bool IsBetter(bool newestCompatible, bool hasBest, int comparison,
                     signed priority, signed bestPriority) {
    if (!hasBest)
        return true;
    if (newestCompatible)
        return comparison > 0 || (comparison == 0 && priority > bestPriority);
    return priority > bestPriority ||
           (priority == bestPriority && comparison > 0);
}

} // namespace CYRootlessCandidatePolicy

#endif
