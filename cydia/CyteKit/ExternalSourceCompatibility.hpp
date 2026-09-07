#ifndef CYTEKIT_EXTERNAL_SOURCE_COMPATIBILITY_HPP
#define CYTEKIT_EXTERNAL_SOURCE_COMPATIBILITY_HPP

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <set>
#include <string>

#include "SourceIdentity.hpp"

namespace CYExternalSourceCompatibility {

inline std::string LowerASCII(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

inline std::string CanonicalSourceRoot(std::string uri) {
    return CYSourceIdentity::CanonicalURI(uri);
}

inline bool SameSourceRoot(const std::string &left, const std::string &right) {
    std::string lhs(CanonicalSourceRoot(left));
    std::string rhs(CanonicalSourceRoot(right));
    if (lhs == rhs)
        return true;
    if (lhs.size() < rhs.size() && rhs.compare(0, lhs.size(), lhs) == 0 && rhs[lhs.size()] == '/')
        return true;
    if (rhs.size() < lhs.size() && lhs.compare(0, rhs.size(), rhs) == 0 && lhs[rhs.size()] == '/')
        return true;
    return false;
}

inline bool IsAggregateIndexWarning(const std::string &message) {
    std::string lower(LowerASCII(message));
    return lower.find("some index files failed to download") != std::string::npos &&
        lower.find("old ones used instead") != std::string::npos;
}

inline bool CanIsolateOperation(size_t isolatedFailures, bool hasBlockingMessage) {
    return isolatedFailures != 0 && !hasBlockingMessage;
}

inline bool HasSecurityMarker(const std::string &lower) {
    static const char *markers[] = {
        "gpg error",
        "no_pubkey",
        "public key",
        "signature",
        "not signed",
        "release file",
        "inrelease",
        "clearsigned",
        NULL
    };
    for (size_t index(0); markers[index] != NULL; ++index)
        if (lower.find(markers[index]) != std::string::npos)
            return true;
    return false;
}

inline bool MessageMatchesSourceRoot(const std::string &message,
    const std::set<std::string> &sourceRoots, std::string *matchedRoot = NULL) {
    // APT messages retain the source URI spelling, so do not lowercase the
    // whole message (HTTP paths can be case-sensitive). Extract each HTTP(S)
    // token and canonicalize only scheme/host/path syntax before comparing.
    const std::string lower(LowerASCII(message));
    std::string::size_type cursor(0);
    while (cursor < message.size()) {
        std::string::size_type http(lower.find("http://", cursor));
        std::string::size_type https(lower.find("https://", cursor));
        std::string::size_type begin;
        if (http == std::string::npos)
            begin = https;
        else if (https == std::string::npos)
            begin = http;
        else
            begin = std::min(http, https);
        if (begin == std::string::npos)
            break;

        std::string::size_type end(begin);
        while (end < message.size() && !std::isspace(static_cast<unsigned char>(message[end])))
            ++end;
        std::string candidate(message.substr(begin, end - begin));
        while (!candidate.empty() &&
            (candidate[candidate.size() - 1] == ',' || candidate[candidate.size() - 1] == ';'))
            candidate.resize(candidate.size() - 1);

        for (std::set<std::string>::const_iterator root(sourceRoots.begin()); root != sourceRoots.end(); ++root) {
            if (SameSourceRoot(candidate, *root)) {
                if (matchedRoot != NULL)
                    *matchedRoot = *root;
                return true;
            }
        }
        cursor = end == begin ? begin + 1 : end;
    }
    return false;
}

// APT rejects these indexes before they can replace a trusted cached index.
// Treat the failure as source-local, but never weaken apt-secure or import the
// rejected data. This covers both missing keys and obsolete signatures such as
// BigBoss' legacy SHA1/DSA Release signature.
inline bool IsSourceSecurityRejection(const std::string &message,
    const std::set<std::string> &sourceRoots, std::string *matchedRoot = NULL) {
    std::string lower(LowerASCII(message));
    if (!HasSecurityMarker(lower))
        return false;
    if (lower.find("no_pubkey") == std::string::npos &&
        lower.find("not signed") == std::string::npos &&
        lower.find("couldn't be verified") == std::string::npos &&
        lower.find("could not be verified") == std::string::npos &&
        lower.find("signatures were invalid") == std::string::npos &&
        lower.find("signature verification") == std::string::npos &&
        lower.find("untrusted digest algorithm") == std::string::npos &&
        lower.find("untrusted public key algorithm") == std::string::npos)
        return false;
    return MessageMatchesSourceRoot(message, sourceRoots, matchedRoot);
}

// Store a small, stable reason code rather than the raw APT message. Raw
// messages can contain mirrors, paths or localized text and are unsuitable as
// persistent UI state. The code is resolved to user-facing copy by Cydia.
inline const char *SecurityIssueCode(const std::string &message) {
    const std::string lower(LowerASCII(message));
    if (lower.find("no_pubkey") != std::string::npos ||
        lower.find("public key is not available") != std::string::npos)
        return "missing-key";
    if (lower.find("untrusted digest algorithm") != std::string::npos ||
        lower.find("untrusted public key algorithm") != std::string::npos ||
        lower.find("signatures were invalid") != std::string::npos)
        return "obsolete-signature";
    if (lower.find("not signed") != std::string::npos ||
        lower.find("no release file") != std::string::npos)
        return "unsigned";
    return "invalid-signature";
}

inline bool IsSecurityAdvisory(const std::string &message) {
    std::string lower(LowerASCII(message));
    return lower.find("updating from such a repository can't be done securely") != std::string::npos ||
        (lower.find("apt-secure") != std::string::npos && lower.find("manpage") != std::string::npos);
}

// When unsigned-repository compatibility is enabled, the patched APT path
// deliberately continues after NO_PUBKEY and emits this shorter GPG warning.
// Keep it distinct from APT's longer "repository is not updated / previous
// index files will be used" rejection so the application does not report a
// successful legacy-key refresh as stale package data.
inline bool IsAcceptedMissingPublicKeyWarning(const std::string &message,
    const std::set<std::string> &sourceRoots, std::string *matchedRoot = NULL) {
    const std::string lower(LowerASCII(message));
    if (lower.find("gpg error") == std::string::npos ||
        lower.find("no_pubkey") == std::string::npos)
        return false;
    if (lower.find("repository is not updated") != std::string::npos ||
        lower.find("previous index files will be used") != std::string::npos)
        return false;
    return MessageMatchesSourceRoot(message, sourceRoots, matchedRoot);
}

inline bool IsSourcePackageIndex404(const std::string &message,
    const std::set<std::string> &sourceRoots, std::string *matchedRoot = NULL) {
    std::string lower(LowerASCII(message));
    if (lower.find("404") == std::string::npos || lower.find("/packages") == std::string::npos)
        return false;
    if (HasSecurityMarker(lower))
        return false;

    return MessageMatchesSourceRoot(message, sourceRoots, matchedRoot);
}

}

#endif
