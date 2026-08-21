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

#include <Foundation/Foundation.h>
#include <Menes/ObjectHandle.h>

#include <cstdio>
#include <spawn.h>
#include <sys/wait.h>
#include <errno.h>

extern char **environ;

#include "Sources.h"

NSString *Cache_;

NSString *Cache(const char *file) {
    return [NSString stringWithFormat:@"%@/%s", Cache_, file];
}

extern _H<NSMutableDictionary> Sources_;

static const char *CydiaManagedSourcesList_ = "/var/jb/etc/apt/sources.list.d/cydia-added.list";

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

    pid_t waited = waitpid(pid, &status, 0);
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
    CYRootlessDiag(@"SOURCES", @"write managed list begin count=%lu path=%@",
        (unsigned long) [Sources_ count], CYRootlessDiagnosticsText(SOURCES_LIST));
    auto sources([SOURCES_LIST UTF8String]);
    unlink(sources);
    FILE *file(fopen(sources, "w"));
    if (file == NULL)
        CYRootlessDiag(@"SOURCES", @"level=ERROR fopen managed list failed errno=%d", errno);
    _assert(file != NULL);

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

    int closeStatus(fclose(file));
    if (closeStatus != 0)
        CYRootlessDiag(@"SOURCES", @"level=ERROR fclose managed list failed errno=%d", errno);
    else
        CYRootlessDiag(@"SOURCES", @"write managed list complete count=%lu", (unsigned long) [Sources_ count]);

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
