/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2013  Jay Freeman (saurik)
*/

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

#include "CyteKit/UCPlatform.h"
#include "CyteKit/RootlessDiagnostics.h"
#include "CyteKit/SourceIdentity.hpp"

#include <Foundation/Foundation.h>
#include <Menes/ObjectHandle.h>

#include <cstdio>
#include <dirent.h>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

extern char **environ;

#include "Sources.h"

NSString *Cache_;

NSString *Cache(const char *file) {
    return [NSString stringWithFormat:@"%@/%s", Cache_, file];
}

extern _H<NSMutableDictionary> Sources_;

static const char *CydiaManagedSourcesList_ = "/var/jb/etc/apt/sources.list.d/cydia-added.list";

static bool CydiaIsManagedSourcePath(const std::string &path) {
    if (path == CydiaManagedSourcesList_)
        return true;
    if (path != "/var/jb/etc/apt/sources.list.d/cydia.list")
        return false;

    // Mirror cydo's legacy cleanup ownership rule: a user/bootstrap file or
    // foreign symlink named cydia.list remains an external source.
    struct stat info;
    if (lstat(path.c_str(), &info) != 0 || !S_ISLNK(info.st_mode))
        return false;
    char target[4096];
    ssize_t size(readlink(path.c_str(), target, sizeof(target)));
    return size >= 0 && std::string(target, static_cast<size_t>(size)) ==
        "/var/mobile/Library/Caches/com.saurik.Cydia/sources.list";
}

static std::string CydiaReadSourceFile(const std::string &path) {
    std::ifstream input(path.c_str(), std::ios::in | std::ios::binary);
    if (!input)
        return std::string();
    std::ostringstream data;
    data << input.rdbuf();
    return data.str();
}

static std::vector<CYSourceIdentity::Entry> CydiaSharedSourceEntries() {
    std::vector<CYSourceIdentity::Entry> entries;
    const std::string main("/var/jb/etc/apt/sources.list");
    if (access(main.c_str(), R_OK) == 0) {
        std::vector<CYSourceIdentity::Entry> parsed(CYSourceIdentity::Parse(CydiaReadSourceFile(main), main));
        entries.insert(entries.end(), parsed.begin(), parsed.end());
    }

    const std::string directory("/var/jb/etc/apt/sources.list.d");
    if (DIR *sources = opendir(directory.c_str())) {
        while (dirent *source = readdir(sources)) {
            if (source->d_name[0] == '.')
                continue;
            std::string name(source->d_name);
            bool list(name.size() >= 5 && name.compare(name.size() - 5, 5, ".list") == 0);
            bool deb822(name.size() >= 8 && name.compare(name.size() - 8, 8, ".sources") == 0);
            if (!list && !deb822)
                continue;
            std::string path(directory + "/" + name);
            std::vector<CYSourceIdentity::Entry> parsed(CYSourceIdentity::Parse(CydiaReadSourceFile(path), path));
            entries.insert(entries.end(), parsed.begin(), parsed.end());
        }
        closedir(sources);
    }
    return entries;
}

static CYSourceIdentity::Entry CydiaSourceIdentity(NSDictionary *source) {
    CYSourceIdentity::Entry entry;
    NSString *type([source objectForKey:@"Type"] ?: @"deb");
    NSString *uri([source objectForKey:@"URI"] ?: @"");
    NSString *suite([source objectForKey:@"Distribution"] ?: @"./");
    NSArray *sections([source objectForKey:@"Sections"] ?: [NSArray array]);
    entry.type = type != nil ? [type UTF8String] : "deb";
    entry.uri = uri != nil ? [uri UTF8String] : "";
    entry.suite = suite != nil ? [suite UTF8String] : "./";
    for (NSString *section in sections)
        if ([section UTF8String] != NULL)
            entry.components.push_back([section UTF8String]);
    entry.uri = CYSourceIdentity::CanonicalURI(entry.uri);
    entry.suite = CYSourceIdentity::CanonicalSuite(entry.suite);
    entry.components = CYSourceIdentity::CanonicalComponents(entry.components);
    return entry;
}

static NSString *CydiaSafeSourceURI(const std::string &uri) {
    NSString *text([NSString stringWithUTF8String:uri.c_str()]);
    if (text == nil)
        return @"<non-UTF8 URI>";
    NSURL *url([NSURL URLWithString:text]);
    return url != nil ? CYRootlessDiagnosticsURL(url) : CYRootlessDiagnosticsText(text);
}

static NSString *CydiaSourceComponents(const CYSourceIdentity::Entry &entry) {
    NSMutableArray *components([NSMutableArray arrayWithCapacity:entry.components.size()]);
    for (std::vector<std::string>::const_iterator component(entry.components.begin()); component != entry.components.end(); ++component) {
        NSString *value([NSString stringWithUTF8String:component->c_str()]);
        if (value != nil)
            [components addObject:value];
    }
    return [components componentsJoinedByString:@","];
}

static void CydiaAuditSharedSourceDuplicates() {
    static std::set<std::string> logged;
    std::vector<CYSourceIdentity::Entry> entries(CydiaSharedSourceEntries());
    for (size_t left = 0; left != entries.size(); ++left) {
        for (size_t right = left + 1; right != entries.size(); ++right) {
            if (entries[left].path == entries[right].path || !CYSourceIdentity::Equivalent(entries[left], entries[right]))
                continue;
            std::string first(entries[left].path + ":" + std::to_string(entries[left].line));
            std::string second(entries[right].path + ":" + std::to_string(entries[right].line));
            if (second < first)
                std::swap(first, second);
            std::string pair(first + "|" + second + "|" + CYSourceIdentity::Key(entries[left]));
            if (!logged.insert(pair).second)
                continue;

            bool leftManaged(CydiaIsManagedSourcePath(entries[left].path));
            bool rightManaged(CydiaIsManagedSourcePath(entries[right].path));
            CYRootlessDiag(@"SOURCE_DEDUP", @"level=WARN action=existing-duplicate canonicalURI=%@ suite=%s components=%@ first=%s:%zu firstOwner=%@ second=%s:%zu secondOwner=%@ autoModified=0",
                CydiaSafeSourceURI(entries[left].uri), entries[left].suite.c_str(), CydiaSourceComponents(entries[left]),
                entries[left].path.c_str(), entries[left].line, leftManaged ? @"Cydia" : @"external",
                entries[right].path.c_str(), entries[right].line, rightManaged ? @"Cydia" : @"external");
        }
    }
}

static bool CydiaExternalEquivalentExists(NSDictionary *source, CYSourceIdentity::Entry *match = NULL) {
    CYSourceIdentity::Entry wanted(CydiaSourceIdentity(source));
    std::vector<CYSourceIdentity::Entry> entries(CydiaSharedSourceEntries());
    for (std::vector<CYSourceIdentity::Entry>::const_iterator entry(entries.begin()); entry != entries.end(); ++entry) {
        if (CydiaIsManagedSourcePath(entry->path))
            continue;
        if (!CYSourceIdentity::Equivalent(wanted, *entry))
            continue;
        if (match != NULL)
            *match = *entry;
        return true;
    }
    return false;
}

static bool CydiaManagedEquivalentExists(NSDictionary *source, CYSourceIdentity::Entry *match = NULL) {
    CYSourceIdentity::Entry wanted(CydiaSourceIdentity(source));
    for (NSDictionary *existing in [Sources_ allValues]) {
        CYSourceIdentity::Entry entry(CydiaSourceIdentity(existing));
        if (!CYSourceIdentity::Equivalent(wanted, entry))
            continue;
        if (match != NULL)
            *match = entry;
        return true;
    }
    return false;
}

static bool CydiaSyncManagedSources() {
    const char *cydo = "/var/jb/usr/libexec/cydia/cydo";
    const char *source = [SOURCES_LIST fileSystemRepresentation];
    CYRootlessDiag(@"SOURCES", @"persist spawn begin cache=%@ destination=%s",
        CYRootlessDiagnosticsText(SOURCES_LIST), CydiaManagedSourcesList_);

    char *const argv[] = {
        const_cast<char *>(cydo),
        const_cast<char *>("--sync-sources"),
        const_cast<char *>(source),
        NULL
    };

    pid_t pid = -1;
    int status = posix_spawn(&pid, cydo, NULL, NULL, argv, environ);
    if (status != 0) {
        CYRootlessDiag(@"SOURCES", @"level=ERROR persist spawn failed status=%d", status);
        NSLog(@"Cydia: unable to start cydo source sync: %d", status);
        return false;
    }
    CYRootlessDiag(@"SOURCES", @"persist child pid=%d", pid);

    pid_t waited;
    do {
        waited = waitpid(pid, &status, 0);
    } while (waited == -1 && errno == EINTR);
    if (waited != pid) {
        CYRootlessDiag(@"SOURCES", @"level=ERROR persist waitpid failed child=%d waited=%d errno=%d", pid, waited, errno);
        NSLog(@"Cydia: waitpid failed while syncing sources");
        return false;
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        CYRootlessDiag(@"SOURCES", @"level=ERROR persist child failed child=%d rawStatus=%d exited=%d exitCode=%d signaled=%d signal=%d",
            pid, status, WIFEXITED(status), WIFEXITED(status) ? WEXITSTATUS(status) : -1,
            WIFSIGNALED(status), WIFSIGNALED(status) ? WTERMSIG(status) : 0);
        NSLog(@"Cydia: cydo source sync failed (status=%d)", status);
        return false;
    }

    CYRootlessDiag(@"SOURCES", @"persist child complete child=%d exitCode=0", pid);
    return true;
}

void CydiaWriteSources() {
    CydiaAuditSharedSourceDuplicates();
    CYRootlessDiag(@"SOURCES", @"write managed list begin count=%lu path=%@",
        (unsigned long) [Sources_ count], CYRootlessDiagnosticsText(SOURCES_LIST));
    NSString *temporary([SOURCES_LIST stringByAppendingString:@".tmp"]);
    const char *sources([SOURCES_LIST fileSystemRepresentation]);
    const char *temporaryPath([temporary fileSystemRepresentation]);
    unlink(temporaryPath);
    int descriptor(open(temporaryPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0644));
    FILE *file(descriptor == -1 ? NULL : fdopen(descriptor, "w"));
    if (file == NULL) {
        int saved(errno);
        if (descriptor != -1)
            close(descriptor);
        // Fail gracefully like Sileo/Zebra instead of aborting the app: the
        // in-memory source list is unchanged and simply is not persisted this
        // cycle (for example on a full disk or a missing cache directory).
        CYRootlessDiag(@"SOURCES", @"level=ERROR open managed list temp failed errno=%d", saved);
        NSLog(@"Cydia: unable to open managed sources cache for writing (errno=%d)", saved);
        return;
    }

    // Rootless public build: do not inject a mandatory/default repository.
    // Cydia writes only repositories explicitly managed by Cydia here;
    // the bootstrap's existing /var/jb/etc/apt source files remain untouched
    // and are still read by APT alongside this generated list.
    for (NSString *key in [Sources_ allKeys]) {
        if ([key hasPrefix:@"deb:http:"] && [Sources_ objectForKey:[NSString stringWithFormat:@"deb:https:%s", [key UTF8String] + 9]])
            continue;

        NSDictionary *source([Sources_ objectForKey:key]);
        NSArray *sections([source objectForKey:@"Sections"] ?: [NSArray array]);
        CYRootlessDiag(@"SOURCECFG", @"write type=%@ uri=%@ distribution=%@ sections=%@",
            [source objectForKey:@"Type"] ?: @"<nil>",
            CYRootlessDiagnosticsText([source objectForKey:@"URI"]),
            [source objectForKey:@"Distribution"] ?: @"<nil>",
            [sections componentsJoinedByString:@","]);

        fprintf(file, "%s %s %s%s%s\n",
            [[source objectForKey:@"Type"] UTF8String],
            [[source objectForKey:@"URI"] UTF8String],
            [[source objectForKey:@"Distribution"] UTF8String],
            [sections count] == 0 ? "" : " ",
            [[sections componentsJoinedByString:@" "] UTF8String]
        );
    }

    bool persisted(fflush(file) == 0 && fsync(fileno(file)) == 0);
    int saved(persisted ? 0 : errno);
    if (fclose(file) != 0 && persisted) {
        persisted = false;
        saved = errno;
    }
    if (persisted && rename(temporaryPath, sources) != 0) {
        persisted = false;
        saved = errno;
    }
    if (!persisted) {
        unlink(temporaryPath);
        CYRootlessDiag(@"SOURCES", @"level=ERROR atomic managed list write failed errno=%d", saved);
        NSLog(@"Cydia: unable to atomically save managed sources (errno=%d)", saved);
        return;
    }
    CYRootlessDiag(@"SOURCES", @"write managed list complete count=%lu atomic=1", (unsigned long) [Sources_ count]);

    // Cydia-managed repositories must survive relaunch and must be
    // visible to the shared rootless APT stack (and therefore Sileo).  Keep
    // the user's generated list in Cydia's writable cache, then ask the
    // already-audited setuid cydo helper to atomically publish only that file
    // as /var/jb/etc/apt/sources.list.d/cydia-added.list.  No bootstrap or
    // Sileo-owned source file is modified.
    if (!CydiaSyncManagedSources()) {
        CYRootlessDiag(@"SOURCES", @"level=ERROR persist managed list failed destination=%s", CydiaManagedSourcesList_);
        NSLog(@"Cydia: failed to persist managed sources to %s", CydiaManagedSourcesList_);
    } else
        CYRootlessDiag(@"SOURCES", @"persist managed list complete destination=%s", CydiaManagedSourcesList_);
}

void CydiaAddSource(NSDictionary *source) {
    CydiaAuditSharedSourceDuplicates();
    CYSourceIdentity::Entry managed;
    if (CydiaManagedEquivalentExists(source, &managed)) {
        CYSourceIdentity::Entry wanted(CydiaSourceIdentity(source));
        CYRootlessDiag(@"SOURCE_DEDUP", @"action=skip-add reason=equivalent-managed-source canonicalURI=%@ suite=%s components=%@ ownershipTaken=0 externalModified=0",
            CydiaSafeSourceURI(wanted.uri), wanted.suite.c_str(), CydiaSourceComponents(wanted));
        return;
    }

    CYSourceIdentity::Entry external;
    if (CydiaExternalEquivalentExists(source, &external)) {
        CYSourceIdentity::Entry wanted(CydiaSourceIdentity(source));
        CYRootlessDiag(@"SOURCE_DEDUP", @"action=skip-add reason=equivalent-external-source canonicalURI=%@ suite=%s components=%@ existing=%s:%zu existingOwner=external ownershipTaken=0 externalModified=0",
            CydiaSafeSourceURI(wanted.uri), wanted.suite.c_str(), CydiaSourceComponents(wanted),
            external.path.c_str(), external.line);
        return;
    }

    CYRootlessDiag(@"SOURCES", @"dictionary add type=%@ uri=%@ distribution=%@",
        [source objectForKey:@"Type"] ?: @"<nil>",
        CYRootlessDiagnosticsText([source objectForKey:@"URI"]),
        [source objectForKey:@"Distribution"] ?: @"<nil>");
    [Sources_ setObject:source forKey:[NSString stringWithFormat:@"%@:%@:%@", [source objectForKey:@"Type"], [source objectForKey:@"URI"], [source objectForKey:@"Distribution"]]];
}

void CydiaAddSource(NSString *href, NSString *distribution, NSArray *sections) {
    if (href == nil || distribution == nil)
        return;

    CydiaAddSource([NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"deb", @"Type",
        href, @"URI",
        distribution, @"Distribution",
        sections ?: [NSMutableArray array], @"Sections",
    nil]);
}
