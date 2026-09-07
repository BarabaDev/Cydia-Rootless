#ifndef Cydia_LibraryPresentation_H
#define Cydia_LibraryPresentation_H

#import <Foundation/Foundation.h>

// Untagged bootstrap tools are common on current repositories. Keep their
// technical sections out of User without overriding an explicit end-user tag.
static inline BOOL CYInstalledSectionIsTechnical(NSString *section) {
    for (NSString *technical in @[@"Administration", @"Archiving", @"Development",
        @"Documentation", @"Keyrings", @"Libraries", @"Packaging", @"System",
        @"Terminal Support", @"Utilities"])
        if ([section length] != 0 && [section caseInsensitiveCompare:technical] == NSOrderedSame)
            return YES;
    return NO;
}

static inline BOOL CYInstalledUserVisible(BOOL installed, NSUInteger role,
    BOOL essential, BOOL automatic, NSString *section) {
    if (!installed) return NO;
    if (role == 1) return YES;
    return role == 0 && !essential && !automatic && !CYInstalledSectionIsTechnical(section);
}

// Calendar days follow the device's time zone, including daylight-saving days.
// Zero means no reliable installation date and must remain a visible group.
static inline NSDate *CYLibraryDay(time_t timestamp) {
    if (timestamp < 1168364520) return nil;
    return [[NSCalendar currentCalendar] startOfDayForDate:
        [NSDate dateWithTimeIntervalSince1970:timestamp]];
}

static inline BOOL CYPurchaseMatchesQuery(NSString *identifier, NSString *name, NSString *query) {
    if ([query length] == 0) return YES;
    return [identifier localizedStandardContainsString:query] ||
        ([name length] != 0 && [name localizedStandardContainsString:query]);
}

#endif
