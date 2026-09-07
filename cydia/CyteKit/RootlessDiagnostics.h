#ifndef CyteKit_RootlessDiagnostics_H
#define CyteKit_RootlessDiagnostics_H

#import <Foundation/Foundation.h>

#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <stdio.h>

static const char *CYRootlessDiagnosticsPath = "/var/mobile/Documents/Cydia_Rootless_Diagnostics.log";
static const char *CYRootlessDiagnosticsOldPath = "/var/mobile/Documents/Cydia_Rootless_Diagnostics.log.1";
static const off_t CYRootlessDiagnosticsMaxSize = 2 * 1024 * 1024;


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
static inline void CYRootlessDiagnosticsRotate(void) {
    struct stat info;
    if (stat(CYRootlessDiagnosticsPath, &info) == 0 && info.st_size >= CYRootlessDiagnosticsMaxSize) {
        unlink(CYRootlessDiagnosticsOldPath);
        rename(CYRootlessDiagnosticsPath, CYRootlessDiagnosticsOldPath);
    }
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

static inline NSString *CYRootlessDiagnosticsTimestamp(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);

    struct tm tm;
    gmtime_r(&tv.tv_sec, &tm);

    char date[48];
    strftime(date, sizeof(date), "%Y-%m-%d %H:%M:%S", &tm);

    char stamp[64];
    snprintf(stamp, sizeof(stamp), "%s.%03d +0000", date, (int) (tv.tv_usec / 1000));
    return [NSString stringWithUTF8String:stamp];
}

static inline void CYRootlessDiag(NSString *component, NSString *format, ...) {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    va_list args;
    va_start(args, format);
    NSString *message([[[NSString alloc] initWithFormat:format arguments:args] autorelease]);
    va_end(args);
    message = CYRootlessDiagnosticsText(message);

    // Keep a bounded public diagnostic file. Individual writes are one line
    // and use O_APPEND so Cydia/cydo can safely contribute to the same log.
    // Millisecond timestamps and PID correlation keep interleaved
    // Cydia/cydo activity can be reconstructed precisely after a failure.
    CYRootlessDiagnosticsRotate();
    int fd = open(CYRootlessDiagnosticsPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        // cydo can be the first process to create the shared log and
        // runs as root. A root:wheel 0644 file prevents the Cydia UI process
        // (mobile/501) from appending SESSION/SOURCE/APT diagnostics. Keep the
        // shared public log owned by mobile even when a root writer opens it.
        if (geteuid() == 0) {
            (void) fchown(fd, 501, 501);
            (void) fchmod(fd, 0644);
        }
        NSString *line([NSString stringWithFormat:@"%@ [%@] pid=%d %@\n", CYRootlessDiagnosticsTimestamp(), component ?: @"GENERAL", getpid(), message ?: @""]);
        NSData *data([line dataUsingEncoding:NSUTF8StringEncoding]);
        if (data != nil)
            (void) write(fd, [data bytes], [data length]);
        close(fd);
    }

    [pool drain];
}

#endif
