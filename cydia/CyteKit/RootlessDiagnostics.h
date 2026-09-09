#ifndef CyteKit_RootlessDiagnostics_H
#define CyteKit_RootlessDiagnostics_H

#import <Foundation/Foundation.h>

static inline NSString *CYRootlessDiagnosticsText(NSString *text) {
    if (text == nil)
        return @"";
    NSMutableString *safe([[text mutableCopy] autorelease]);
    NSRange mail([safe rangeOfString:@"mailto:" options:NSCaseInsensitiveSearch]);
    if (mail.location != NSNotFound)
        return @"<mailto redacted>";

    // Strip URL query strings from diagnostic text while keeping host/path and
    // error wording. This avoids leaking tokens or user-specific query data.
    NSUInteger pos = 0;
    while (pos < [safe length]) {
        NSRange q = [safe rangeOfString:@"?" options:0 range:NSMakeRange(pos, [safe length] - pos)];
        if (q.location == NSNotFound)
            break;
        NSUInteger end = q.location + 1;
        while (end < [safe length]) {
            unichar c = [safe characterAtIndex:end];
            if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c])
                break;
            ++end;
        }
        [safe replaceCharactersInRange:NSMakeRange(q.location, end - q.location) withString:@"?<redacted>"];
        pos = q.location + [@"?<redacted>" length];
    }

    // Keep every diagnostic record physically on one line so grep/filtering
    // and PID correlation remain reliable even when an APT/exception message
    // contains embedded line breaks.
    [safe replaceOccurrencesOfString:@"\r" withString:@"\\r" options:0 range:NSMakeRange(0, [safe length])];
    [safe replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, [safe length])];
    return safe;
}
static inline NSString *CYRootlessDiagnosticsURL(NSURL *url) {
    if (url == nil)
        return @"<nil>";

    NSString *scheme([[url scheme] lowercaseString]);
    if ([scheme isEqualToString:@"mailto"])
        return @"mailto:<redacted>";
    if ([scheme isEqualToString:@"file"])
        return @"file:<redacted>";

    NSString *host([url host]);
    NSString *path([url path]);
    if (scheme != nil && host != nil)
        return [NSString stringWithFormat:@"%@://%@%@", scheme, host, path ?: @""];

    // Never log query strings/fragments or opaque payloads.
    return scheme != nil ? [NSString stringWithFormat:@"%@:<redacted>", scheme] : @"<redacted-url>";
}

// Preserve existing call-site argument evaluation without producing a log or
// formatting records. The sanitizers above are also used by visible errors.
static inline void CYRootlessDiag(NSString *component, NSString *format, ...) {
    (void) component;
    (void) format;
}

#endif
