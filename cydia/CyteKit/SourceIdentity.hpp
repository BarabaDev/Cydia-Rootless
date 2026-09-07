#ifndef CYTEKIT_SOURCE_IDENTITY_HPP
#define CYTEKIT_SOURCE_IDENTITY_HPP

#include <algorithm>
#include <cctype>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace CYSourceIdentity {

inline std::string Trim(const std::string &value) {
    std::string::size_type first = 0;
    while (first < value.size() && std::isspace(static_cast<unsigned char>(value[first])))
        ++first;
    std::string::size_type last = value.size();
    while (last > first && std::isspace(static_cast<unsigned char>(value[last - 1])))
        --last;
    return value.substr(first, last - first);
}

inline std::string LowerASCII(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

inline std::vector<std::string> Words(const std::string &value) {
    std::vector<std::string> words;
    std::istringstream stream(value);
    std::string word;
    while (stream >> word)
        words.push_back(word);
    return words;
}

inline std::string CanonicalURI(std::string uri) {
    uri = Trim(uri);
    if (uri.empty())
        return uri;

    std::string::size_type schemeEnd(uri.find("://"));
    if (schemeEnd != std::string::npos) {
        std::string scheme(LowerASCII(uri.substr(0, schemeEnd)));
        std::string::size_type authorityBegin(schemeEnd + 3);
        std::string::size_type authorityEnd(uri.find_first_of("/?#", authorityBegin));
        if (authorityEnd == std::string::npos)
            authorityEnd = uri.size();

        std::string authority(uri.substr(authorityBegin, authorityEnd - authorityBegin));
        std::string userinfo;
        std::string hostport(authority);
        std::string::size_type at(authority.rfind('@'));
        if (at != std::string::npos) {
            userinfo = authority.substr(0, at + 1);
            hostport = authority.substr(at + 1);
        }

        std::string host(hostport);
        std::string port;
        if (!hostport.empty() && hostport[0] == '[') {
            std::string::size_type close(hostport.find(']'));
            if (close != std::string::npos) {
                host = hostport.substr(0, close + 1);
                port = hostport.substr(close + 1);
            }
        } else {
            std::string::size_type colon(hostport.rfind(':'));
            if (colon != std::string::npos && hostport.find(':') == colon) {
                host = hostport.substr(0, colon);
                port = hostport.substr(colon);
            }
        }
        host = LowerASCII(host);
        if ((scheme == "https" && port == ":443") || (scheme == "http" && port == ":80"))
            port.clear();

        uri = scheme + "://" + userinfo + host + port + uri.substr(authorityEnd);
    }

    // Normalize only the path portion. Query/fragment data is semantically
    // significant and can contain case-sensitive or private values; source
    // identity must neither lowercase nor rewrite it.
    std::string::size_type suffixStart(uri.find_first_of("?#", schemeEnd == std::string::npos ? 0 : schemeEnd + 3));
    std::string pathPart(suffixStart == std::string::npos ? uri : uri.substr(0, suffixStart));
    const std::string suffix(suffixStart == std::string::npos ? std::string() : uri.substr(suffixStart));

    // Flat Debian sources are commonly written as base/, base/./ or base/.
    // Normalize dot path segments without lowercasing the HTTP path: paths can
    // be case-sensitive even though scheme and host are not.
    for (;;) {
        std::string::size_type position(pathPart.find("/./"));
        if (position == std::string::npos)
            break;
        pathPart.replace(position, 3, "/");
    }
    while (pathPart.size() > 1 && pathPart[pathPart.size() - 1] == '/')
        pathPart.resize(pathPart.size() - 1);
    if (pathPart.size() > 2 && pathPart.compare(pathPart.size() - 2, 2, "/.") == 0)
        pathPart.resize(pathPart.size() - 2);
    return pathPart + suffix;
}

inline std::string CanonicalSuite(std::string suite) {
    suite = Trim(suite);
    if (suite == "." || suite == "./")
        return "./";
    return suite;
}

inline std::vector<std::string> CanonicalComponents(std::vector<std::string> components) {
    for (std::vector<std::string>::iterator it(components.begin()); it != components.end(); ++it)
        *it = Trim(*it);
    components.erase(std::remove(components.begin(), components.end(), std::string()), components.end());
    std::sort(components.begin(), components.end());
    components.erase(std::unique(components.begin(), components.end()), components.end());
    return components;
}

struct Entry {
    std::string type;
    std::string uri;
    std::string suite;
    std::vector<std::string> components;
    std::string path;
    size_t line;

    Entry() : line(0) {}
};

inline std::string Key(const Entry &entry) {
    std::ostringstream out;
    out << LowerASCII(Trim(entry.type)) << '\n'
        << CanonicalURI(entry.uri) << '\n'
        << CanonicalSuite(entry.suite) << '\n';
    std::vector<std::string> components(CanonicalComponents(entry.components));
    for (size_t index(0); index != components.size(); ++index) {
        if (index != 0)
            out << ' ';
        out << components[index];
    }
    return out.str();
}

inline bool Equivalent(const Entry &left, const Entry &right) {
    return Key(left) == Key(right);
}

inline void AddEntry(std::vector<Entry> &entries, const std::string &type,
    const std::string &uri, const std::string &suite,
    const std::vector<std::string> &components, const std::string &path, size_t line) {
    if (LowerASCII(Trim(type)) != "deb" || Trim(uri).empty() || Trim(suite).empty())
        return;
    Entry entry;
    entry.type = LowerASCII(Trim(type));
    entry.uri = CanonicalURI(uri);
    entry.suite = CanonicalSuite(suite);
    entry.components = CanonicalComponents(components);
    entry.path = path;
    entry.line = line;
    entries.push_back(entry);
}

inline std::vector<Entry> ParseList(const std::string &text, const std::string &path = std::string()) {
    std::vector<Entry> entries;
    std::istringstream input(text);
    std::string line;
    size_t lineNumber = 0;
    while (std::getline(input, line)) {
        ++lineNumber;
        std::string trimmed(Trim(line));
        if (trimmed.empty() || trimmed[0] == '#')
            continue;

        std::vector<std::string> words(Words(trimmed));
        if (words.size() < 3 || LowerASCII(words[0]) != "deb")
            continue;

        size_t cursor = 1;
        if (cursor < words.size() && !words[cursor].empty() && words[cursor][0] == '[') {
            while (cursor < words.size()) {
                bool end = !words[cursor].empty() && words[cursor][words[cursor].size() - 1] == ']';
                ++cursor;
                if (end)
                    break;
            }
        }
        if (cursor + 1 >= words.size())
            continue;

        std::string uri(words[cursor++]);
        std::string suite(words[cursor++]);
        std::vector<std::string> components;
        while (cursor < words.size()) {
            if (!words[cursor].empty() && words[cursor][0] == '#')
                break;
            components.push_back(words[cursor++]);
        }
        AddEntry(entries, "deb", uri, suite, components, path, lineNumber);
    }
    return entries;
}

inline void FlushDeb822(std::vector<Entry> &entries,
    const std::map<std::string, std::string> &fields, const std::string &path, size_t line) {
    std::map<std::string, std::string>::const_iterator enabledIt(fields.find("enabled"));
    if (enabledIt != fields.end()) {
        std::string enabled(LowerASCII(Trim(enabledIt->second)));
        if (enabled == "no" || enabled == "false" || enabled == "0")
            return;
    }
    std::map<std::string, std::string>::const_iterator typesIt(fields.find("types"));
    std::map<std::string, std::string>::const_iterator urisIt(fields.find("uris"));
    std::map<std::string, std::string>::const_iterator suitesIt(fields.find("suites"));
    if (typesIt == fields.end() || urisIt == fields.end() || suitesIt == fields.end())
        return;

    std::vector<std::string> types(Words(typesIt->second));
    std::vector<std::string> uris(Words(urisIt->second));
    std::vector<std::string> suites(Words(suitesIt->second));
    std::vector<std::string> components;
    std::map<std::string, std::string>::const_iterator componentsIt(fields.find("components"));
    if (componentsIt != fields.end())
        components = Words(componentsIt->second);

    for (size_t type = 0; type != types.size(); ++type)
        for (size_t uri = 0; uri != uris.size(); ++uri)
            for (size_t suite = 0; suite != suites.size(); ++suite)
                AddEntry(entries, types[type], uris[uri], suites[suite], components, path, line);
}

inline std::vector<Entry> ParseSources(const std::string &text, const std::string &path = std::string()) {
    std::vector<Entry> entries;
    std::istringstream input(text);
    std::map<std::string, std::string> fields;
    std::string currentField;
    std::string line;
    size_t lineNumber = 0;
    size_t stanzaLine = 1;

    while (std::getline(input, line)) {
        ++lineNumber;
        if (Trim(line).empty()) {
            FlushDeb822(entries, fields, path, stanzaLine);
            fields.clear();
            currentField.clear();
            stanzaLine = lineNumber + 1;
            continue;
        }
        // Comments never continue the preceding DEB822 field, even when indented.
        if (Trim(line)[0] == '#')
            continue;
        if (!line.empty() && std::isspace(static_cast<unsigned char>(line[0]))) {
            if (!currentField.empty())
                fields[currentField] += " " + Trim(line);
            continue;
        }
        std::string::size_type colon(line.find(':'));
        if (colon == std::string::npos)
            continue;
        currentField = LowerASCII(Trim(line.substr(0, colon)));
        fields[currentField] = Trim(line.substr(colon + 1));
    }
    FlushDeb822(entries, fields, path, stanzaLine);
    return entries;
}

inline std::vector<Entry> Parse(const std::string &text, const std::string &path) {
    if (path.size() >= 8 && path.compare(path.size() - 8, 8, ".sources") == 0)
        return ParseSources(text, path);
    return ParseList(text, path);
}

} // namespace CYSourceIdentity

#endif
