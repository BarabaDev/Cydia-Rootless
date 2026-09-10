/* Cydia - iPhone UIKit Front-End for Debian APT
 * Original work Copyright (C) 2008-2017  Jay Freeman (saurik)
 * Modified work Copyright (C) 2018       Sam Bingner (sbingner)
 * Unofficial Modern Rootless modifications by BarabaDev, 7 September 2026.
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

// XXX: wtf/FastMalloc.h... wtf?
#define USE_SYSTEM_MALLOC 1

/* #include Directives {{{ */
#include "Cydia/ModernLocalization.h"
#include "CyteKit/UCPlatform.h"
#include "CyteKit/Localize.h"
#include "CyteKit/RootlessDiagnostics.h"
#include "CyteKit/RootlessCandidatePolicy.hpp"
#include "CyteKit/ExternalSourceCompatibility.hpp"
#include "CyteKit/InjectionCompatibility.hpp"
#include "CyteKit/SourceIdentity.hpp"
#include "CyteKit/RootlessRuntimePaths.h"
#include "CyteKit/ModernAppearance.h"
#include "Cydia/ModernNativeViews.h"
#include "Cydia/ConfirmationIssues.h"
#include "Cydia/TransactionPresentation.h"
#include <apt-pkg/version.h>
#include "Cydia/RepositoryAccounts.h"
#include "Cydia/LibraryPresentation.h"

#include <unicode/ustring.h>
#include <unicode/utrans.h>

#include <objc/objc.h>
#include <objc/runtime.h>

#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <Foundation/Foundation.h>

#if 0
#define DEPLOYMENT_TARGET_MACOSX 1
#define CF_BUILDING_CF 1
#include <CoreFoundation/CFInternal.h>
#endif

#include <SystemConfiguration/SystemConfiguration.h>

#include <UIKit/UIKit.h>
#include "iPhonePrivate.h"

#include <QuartzCore/CALayer.h>
#include <QuartzCore/CAGradientLayer.h>
#include <QuartzCore/CAAnimation.h>
#include <QuartzCore/CATransaction.h>
#include <QuartzCore/CAMediaTimingFunction.h>

#include <WebCore/WebCoreThread.h>

static NSMutableSet *CYSensitiveDownloadURLs_ = nil;

static void CYRegisterSensitiveDownloadURL(NSString *url) {
    if ([url length] == 0)
        return;
    @synchronized ([NSURL class]) {
        if (CYSensitiveDownloadURLs_ == nil)
            CYSensitiveDownloadURLs_ = [[NSMutableSet alloc] init];
        [CYSensitiveDownloadURLs_ addObject:url];
    }
}

static BOOL CYIsSensitiveDownloadURL(NSString *url) {
    if ([url length] == 0)
        return NO;
    @synchronized ([NSURL class]) {
        return [CYSensitiveDownloadURLs_ containsObject:url];
    }
}

static void CYClearSensitiveDownloadURLs(void) {
    @synchronized ([NSURL class]) {
        [CYSensitiveDownloadURLs_ removeAllObjects];
    }
}

static NSString *CYSanitizeDownloadText(NSString *text) {
    if (text == nil)
        return @"";
    NSMutableString *safe([[text mutableCopy] autorelease]);
    @synchronized ([NSURL class]) {
        for (NSString *sensitive in CYSensitiveDownloadURLs_) {
            NSURL *url([NSURL URLWithString:sensitive]);
            NSString *replacement([NSString stringWithFormat:@"%@://%@/<authorized-download-redacted>", [url scheme] ?: @"https", [url host] ?: @"repository"]);
            [safe replaceOccurrencesOfString:sensitive withString:replacement options:0 range:NSMakeRange(0, [safe length])];
        }
    }
    return CYRootlessDiagnosticsText(safe);
}

#include <algorithm>
#include <fstream>
#include <functional>
#include <iomanip>
#include <map>
#include <set>
#include <sstream>
#include <string>

// The legacy startup path performs APT and filesystem maintenance before
// UIApplicationMain.  Keep that work alive on main's stack, but execute it
// only after UIKit has committed Cydia's first Home frame.
static std::function<void()> CYDeferredStartupWork_;

static NSString *const CYPrivacyConsentPreferenceKey_ = @"CydiaPrivacyConsentVersion";
static NSString *const CYPrivacyConsentApplicationID_ = @"com.saurik.Cydia";
static const NSInteger CYPrivacyConsentCurrentVersion_ = 1;

static BOOL CYPrivacyConsentAccepted(void) {
    CFPropertyListRef stored(CFPreferencesCopyAppValue(
        (CFStringRef) CYPrivacyConsentPreferenceKey_,
        (CFStringRef) CYPrivacyConsentApplicationID_));
    BOOL accepted(NO);
    if (stored != NULL && [(id) stored respondsToSelector:@selector(integerValue)])
        accepted = [(id) stored integerValue] >= CYPrivacyConsentCurrentVersion_;
    if (stored != NULL)
        CFRelease(stored);
    return accepted;
}

BOOL CydiaPrivacyConsentIsAccepted(void) {
    return CYPrivacyConsentAccepted();
}

static BOOL CYStorePrivacyConsent(void) {
    NSNumber *version([NSNumber numberWithInteger:CYPrivacyConsentCurrentVersion_]);
    CFPreferencesSetAppValue(
        (CFStringRef) CYPrivacyConsentPreferenceKey_,
        (CFPropertyListRef) version,
        (CFStringRef) CYPrivacyConsentApplicationID_);
    return CFPreferencesAppSynchronize((CFStringRef) CYPrivacyConsentApplicationID_);
}

#include "fdstream.hpp"

static NSString *CYDiagnosticURLString(const std::string &value) {
    NSString *text([NSString stringWithUTF8String:value.c_str()]);
    if (text == nil)
        return @"<non-UTF8 URI>";
    NSURL *url([NSURL URLWithString:text]);
    if (CYIsSensitiveDownloadURL(text))
        return [NSString stringWithFormat:@"%@://%@/<authorized-download-redacted>", [url scheme] ?: @"https", [url host] ?: @"repository"];
    return url != nil ? CYRootlessDiagnosticsURL(url) : CYRootlessDiagnosticsText(text);
}

static bool CYHTTPURLString(const std::string &value) {
    return value.compare(0, 7, "http://") == 0 || value.compare(0, 8, "https://") == 0;
}

static int CYHTTPStatusFromAcquireError(const std::string &error) {
    std::string::size_type begin(0);
    while (begin < error.size() && std::isspace(static_cast<unsigned char>(error[begin])))
        ++begin;

    // Embedded CFNetwork reports status errors as "HTTP/1.1 403 Forbidden",
    // while other APT methods may begin directly with "403".  Normalize both
    // forms so diagnostics never record httpStatus=0 for a known server code.
    if (error.compare(begin, 5, "HTTP/") == 0) {
        std::string::size_type separator(error.find(' ', begin + 5));
        if (separator == std::string::npos)
            return 0;
        begin = separator + 1;
        while (begin < error.size() && std::isspace(static_cast<unsigned char>(error[begin])))
            ++begin;
    }

    if (begin + 3 > error.size())
        return 0;
    if (!std::isdigit(static_cast<unsigned char>(error[begin])) ||
        !std::isdigit(static_cast<unsigned char>(error[begin + 1])) ||
        !std::isdigit(static_cast<unsigned char>(error[begin + 2])))
        return 0;
    int status((error[begin] - '0') * 100 + (error[begin + 1] - '0') * 10 + (error[begin + 2] - '0'));
    return status >= 100 && status <= 599 ? status : 0;
}

/* iOS 15+ SDKs no longer expose the private CFUniChar header used by
 * historical Cydia. Preserve the original letter/non-letter sorting logic
 * through Foundation's public NSCharacterSet API. */
static inline bool CYCharacterIsLetter(UniChar character) {
    return [[NSCharacterSet letterCharacterSet] characterIsMember:character];
}

#undef ABS

#include "apt.h"
#include <apt-pkg/acquire.h>
#include <apt-pkg/acquire-item.h>
#include <apt-pkg/algorithms.h>
#include <apt-pkg/cachefile.h>
#include <apt-pkg/clean.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/debindexfile.h>
#include <apt-pkg/debmetaindex.h>
#include <apt-pkg/error.h>
#include <apt-pkg/fileutl.h>
#include <apt-pkg/gpgv.h>
#include <apt-pkg/init.h>
#include <apt-pkg/mmap.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/sha1.h>
#include <apt-pkg/sourcelist.h>
#include <apt-pkg/sptr.h>
#include <apt-pkg/strutl.h>
#include <apt-pkg/tagfile.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/reboot.h>

#include <dirent.h>
#include <fcntl.h>
#include <notify.h>
#include <dlfcn.h>
#include <spawn.h>
#include <sys/wait.h>

extern "C" {
#include <mach-o/nlist.h>
}

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <errno.h>

#include <Cytore.hpp>
#include "Sources.h"

#include "Substrate.hpp"
#include "Menes/Menes.h"

#include "CyteKit/CyteKit.h"
#include "CyteKit/RegEx.hpp"

#include "Cydia/MIMEAddress.h"
#include "Cydia/LoadingView.h"
#include "Cydia/LoadingViewController.h"
#include "Cydia/ProgressEvent.h"
/* }}} */

extern char **environ;

const char *common_arch=NULL;

/* Profiler {{{ */
struct timeval _ltv;
bool _itv;

#define _timestamp ({ \
    struct timeval tv; \
    gettimeofday(&tv, NULL); \
    tv.tv_sec * 1000000 + tv.tv_usec; \
})

typedef std::vector<class ProfileTime *> TimeList;
TimeList times_;

class ProfileTime {
  private:
    const char *name_;
    uint64_t total_;
    uint64_t count_;

  public:
    ProfileTime(const char *name) :
        name_(name),
        total_(0)
    {
        times_.push_back(this);
    }

    void AddTime(uint64_t time) {
        total_ += time;
        ++count_;
    }

    void Print() {
        if (total_ != 0)
            std::cerr << std::setw(7) << count_ << ", " << std::setw(8) << total_ << " : " << name_ << std::endl;
        total_ = 0;
        count_ = 0;
    }
};

class ProfileTimer {
  private:
    ProfileTime &time_;
    uint64_t start_;

  public:
    ProfileTimer(ProfileTime &time) :
        time_(time),
        start_(_timestamp)
    {
    }

    ~ProfileTimer() {
        time_.AddTime(_timestamp - start_);
    }
};

void PrintTimes() {
    for (TimeList::const_iterator i(times_.begin()); i != times_.end(); ++i)
        (*i)->Print();
    std::cerr << "========" << std::endl;
}

#define _profile(name) { \
    static ProfileTime name(#name); \
    ProfileTimer _ ## name(name);

#define _end }
/* }}} */

extern NSString *Cydia_;

#define lprintf(args...) fprintf(stderr, args)

#define ForRelease 1
#define TraceLogging (1 && !ForRelease)
#define HistogramInsertionSort (0 && !ForRelease)
#define ProfileTimes (0 && !ForRelease)
#define ForSaurik (0 && !ForRelease)
#define LogBrowser (0 && !ForRelease)
#define TrackResize (0 && !ForRelease)
#define ManualRefresh (1 && !ForRelease)
#define ShowInternals (0 && !ForRelease)
#define AlwaysReload (0 && !ForRelease)

#if !TraceLogging
#undef _trace
#define _trace(args...)
#endif

#if !ProfileTimes
#undef _profile
#define _profile(name) {
#undef _end
#define _end }
#define PrintTimes() do {} while (false)
#endif

// Hash Functions/Structures {{{
extern "C" uint32_t hashlittle(const void *key, size_t length, uint32_t initval = 0);

union SplitHash {
    uint32_t u32;
    uint16_t u16[2];
};
// }}}

static NSString *Colon_;
NSString *Elision_;
static NSString *Error_;
static NSString *Warning_;

static void (*$SBSSetInterceptsMenuButtonForever)(bool);
static NSData *(*$SBSCopyIconImagePNGDataForDisplayIdentifier)(NSString *);

static CFStringRef (*$MGCopyAnswer)(CFStringRef);

static NSString *UniqueIdentifier(UIDevice *device = nil) {
    if (kCFCoreFoundationVersionNumber < 800) // iOS 7.x
        return [device ?: [UIDevice currentDevice] uniqueIdentifier];
    else
        return [(id)$MGCopyAnswer(CFSTR("UniqueDeviceID")) autorelease];
}

static const NSUInteger UIViewAutoresizingFlexibleBoth(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);

static _finline NSString *CydiaURL(NSString *path) {
    char page[26];
    page[0] = 'h'; page[1] = 't'; page[2] = 't'; page[3] = 'p'; page[4] = 's';
    page[5] = ':'; page[6] = '/'; page[7] = '/'; page[8] = 'c'; page[9] = 'y';
    page[10] = 'd'; page[11] = 'i'; page[12] = 'a'; page[13] = '.'; page[14] = 's';
    page[15] = 'a'; page[16] = 'u'; page[17] = 'r'; page[18] = 'i'; page[19] = 'k';
    page[20] = '.'; page[21] = 'c'; page[22] = 'o'; page[23] = 'm'; page[24] = '/';
    page[25] = '\0';
    return [[NSString stringWithUTF8String:page] stringByAppendingString:path];
}

static NSString *ShellEscape(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static _finline void UpdateExternalStatus(uint64_t newStatus) {
    int notify_token;
    if (notify_register_check("com.saurik.Cydia.status", &notify_token) == NOTIFY_STATUS_OK) {
        notify_set_state(notify_token, newStatus);
        notify_cancel(notify_token);
    }
    notify_post("com.saurik.Cydia.status");
}

/* NSForcedOrderingSearch doesn't work on the iPhone */
static const NSStringCompareOptions MatchCompareOptions_ = NSLiteralSearch | NSCaseInsensitiveSearch;
static const NSStringCompareOptions LaxCompareOptions_ = NSNumericSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch | NSCaseInsensitiveSearch;
static const CFStringCompareFlags LaxCompareFlags_ = kCFCompareNumerically | kCFCompareWidthInsensitive | kCFCompareForcedOrdering;

/* Insertion Sort {{{ */

template <typename Type_>
size_t CFBSearch_(const Type_ &element, const void *list, size_t count, CFComparisonResult (*comparator)(Type_, Type_, void *), void *context) {
    const char *ptr = (const char *)list;
    while (0 < count) {
        size_t half = count / 2;
        const char *probe = ptr + sizeof(Type_) * half;
        CFComparisonResult cr = comparator(element, * (const Type_ *) probe, context);
        if (0 == cr) return (probe - (const char *)list) / sizeof(Type_);
        ptr = (cr < 0) ? ptr : probe + sizeof(Type_);
        count = (cr < 0) ? half : (half + (count & 1) - 1);
    }
    return (ptr - (const char *)list) / sizeof(Type_);
}

template <typename Type_>
void CYArrayInsertionSortValues(Type_ *values, size_t length, CFComparisonResult (*comparator)(Type_, Type_, void *), void *context) {
    if (length == 0)
        return;

#if HistogramInsertionSort > 0
    uint32_t total(0), *offsets(new uint32_t[length]);
#endif

    for (size_t index(1); index != length; ++index) {
        Type_ value(values[index]);
#if 0
        size_t correct(CFBSearch_(value, values, index, comparator, context));
#else
        size_t correct(index);
        while (comparator(value, values[correct - 1], context) == kCFCompareLessThan) {
#if HistogramInsertionSort > 1
            NSLog(@"%@ < %@", value, values[correct - 1]);
#endif
            if (--correct == 0)
                break;
            if (index - correct >= 8) {
                correct = CFBSearch_(value, values, correct, comparator, context);
                break;
            }
        }
#endif
        if (correct != index) {
            size_t offset(index - correct);
#if HistogramInsertionSort
            total += offset;
            ++offsets[offset];
            if (offset > 10)
                NSLog(@"Heavy Insertion Displacement: %u = %@", offset, value);
#endif
            memmove(values + correct + 1, values + correct, sizeof(const void *) * offset);
            values[correct] = value;
        }
    }

#if HistogramInsertionSort > 0
    for (size_t index(0); index != range.length; ++index)
        if (offsets[index] != 0)
            NSLog(@"Insertion Displacement [%u]: %u", index, offsets[index]);
    NSLog(@"Average Insertion Displacement: %f", double(total) / range.length);
    delete [] offsets;
#endif
}

/* }}} */

/* Cydia NSString Additions {{{ */
@interface NSString (Cydia)
- (NSComparisonResult) compareByPath:(NSString *)other;
- (NSString *) stringByAddingPercentEscapesIncludingReserved;
@end

@implementation NSString (Cydia)

- (NSComparisonResult) compareByPath:(NSString *)other {
    NSString *prefix = [self commonPrefixWithString:other options:0];
    size_t length = [prefix length];

    NSRange lrange = NSMakeRange(length, [self length] - length);
    NSRange rrange = NSMakeRange(length, [other length] - length);

    lrange = [self rangeOfString:@"/" options:0 range:lrange];
    rrange = [other rangeOfString:@"/" options:0 range:rrange];

    NSComparisonResult value;

    if (lrange.location == NSNotFound && rrange.location == NSNotFound)
        value = NSOrderedSame;
    else if (lrange.location == NSNotFound)
        value = NSOrderedAscending;
    else if (rrange.location == NSNotFound)
        value = NSOrderedDescending;
    else
        value = NSOrderedSame;

    NSString *lpath = lrange.location == NSNotFound ? [self substringFromIndex:length] :
        [self substringWithRange:NSMakeRange(length, lrange.location - length)];
    NSString *rpath = rrange.location == NSNotFound ? [other substringFromIndex:length] :
        [other substringWithRange:NSMakeRange(length, rrange.location - length)];

    NSComparisonResult result = [lpath compare:rpath];
    return result == NSOrderedSame ? value : result;
}

- (NSString *) stringByAddingPercentEscapesIncludingReserved {
    return [(id)CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault,
        (CFStringRef) self,
        NULL,
        CFSTR(";/?:@&=+$,"),
        kCFStringEncodingUTF8
    ) autorelease];
}

@end
/* }}} */

@interface FBSSystemService
+(id)sharedService;
-(void)sendActions:(NSSet*)actions withResult:(id)result;
@end

typedef enum {
    None                   = 0,
    RestartRenderServer    = (1 << 0), // also relaunch backboardd
    SnapshotTransition     = (1 << 1),
    FadeToBlackTransition  = (1 << 2),
} SBSRelaunchActionStyle;

@interface SBSRelaunchAction
+(id)actionWithReason:(id)reason options:(int64_t)options targetURL:(NSURL*)url;
@end

/* C++ NSString Wrapper Cache {{{ */
static _finline CFStringRef CYStringCreate(const char *data, size_t size) {
    if (size == 0)
        return NULL;

    // CYString can point at storage owned by a pool or a std::string. Copy the
    // bytes into the cached CFString so the cache cannot outlive that storage.
    CFStringRef value(CFStringCreateWithBytes(kCFAllocatorDefault,
        reinterpret_cast<const uint8_t *>(data), size, kCFStringEncodingUTF8, NO));
    if (value == NULL)
        value = CFStringCreateWithBytes(kCFAllocatorDefault,
            reinterpret_cast<const uint8_t *>(data), size, kCFStringEncodingISOLatin1, NO);
    return value;
}

static _finline CFStringRef CYStringCreate(const std::string &data) {
    return CYStringCreate(data.data(), data.size());
}

static _finline CFStringRef CYStringCreate(const char *data) {
    return CYStringCreate(data, strlen(data));
}

class CYString {
  private:
    char *data_;
    size_t size_;
    CFStringRef cache_;

    _finline void clear_() {
        if (cache_ != NULL) {
            CFRelease(cache_);
            cache_ = NULL;
        }
    }

  public:
    _finline bool empty() const {
        return size_ == 0;
    }

    _finline size_t size() const {
        return size_;
    }

    _finline char *data() const {
        return data_;
    }

    _finline void clear() {
        size_ = 0;
        clear_();
    }

    _finline CYString() :
        data_(0),
        size_(0),
        cache_(NULL)
    {
    }

    _finline ~CYString() {
        clear_();
    }

    void operator =(const CYString &rhs) {
        data_ = rhs.data_;
        size_ = rhs.size_;

        if (rhs.cache_ == nil)
            cache_ = NULL;
        else
            cache_ = reinterpret_cast<CFStringRef>(CFRetain(rhs.cache_));
    }

    void copy(CYPool *pool) {
        char *temp(pool->malloc<char>(size_ + 1));
        memcpy(temp, data_, size_);
        temp[size_] = '\0';
        data_ = temp;
    }

    void set(CYPool *pool, const char *data, size_t size) {
        if (size == 0)
            clear();
        else {
            clear_();

            data_ = const_cast<char *>(data);
            size_ = size;

            if (pool != NULL)
                copy(pool);
        }
    }

    _finline void set(CYPool *pool, const char *data) {
        set(pool, data, data == NULL ? 0 : strlen(data));
    }

    _finline void set(CYPool *pool, const std::string &rhs) {
        // A std::string overload must never retain rhs.data(): callers often
        // pass a temporary returned by APT. These source-model strings require
        // a pool-backed copy; fail closed if that ownership is unavailable.
        if (pool == NULL) {
            clear();
            return;
        }
        set(pool, rhs.data(), rhs.size());
    }

    bool operator ==(const CYString &rhs) const {
        return size_ == rhs.size_ && memcmp(data_, rhs.data_, size_) == 0;
    }

    _finline operator CFStringRef() {
        if (cache_ == NULL)
            cache_ = CYStringCreate(data_, size_);
        return cache_;
    }

    _finline operator id() {
        return (NSString *) static_cast<CFStringRef>(*this);
    }

    _finline operator const char *() {
        return reinterpret_cast<const char *>(data_);
    }
};
/* }}} */
/* C++ NSString Algorithm Adapters {{{ */
extern "C" {
    CF_EXPORT CFHashCode CFStringHashNSString(CFStringRef str);
}

struct NSStringMapHash :
    std::unary_function<NSString *, size_t>
{
    _finline size_t operator ()(NSString *value) const {
        return CFStringHashNSString((CFStringRef) value);
    }
};

struct NSStringMapLess :
    std::binary_function<NSString *, NSString *, bool>
{
    _finline bool operator ()(NSString *lhs, NSString *rhs) const {
        return [lhs compare:rhs] == NSOrderedAscending;
    }
};

struct NSStringMapEqual :
    std::binary_function<NSString *, NSString *, bool>
{
    _finline bool operator ()(NSString *lhs, NSString *rhs) const {
        return CFStringCompare((CFStringRef) lhs, (CFStringRef) rhs, 0) == kCFCompareEqualTo;
        //CFEqual((CFTypeRef) lhs, (CFTypeRef) rhs);
        //[lhs isEqualToString:rhs];
    }
};
/* }}} */

/* CoreGraphics Primitives {{{ */
class CYColor {
  private:
    CGColorRef color_;

    static CGColorRef Create_(CGColorSpaceRef space, float red, float green, float blue, float alpha) {
        CGFloat color[] = {red, green, blue, alpha};
        return CGColorCreate(space, color);
    }

  public:
    CYColor() :
        color_(NULL)
    {
    }

    CYColor(CGColorSpaceRef space, float red, float green, float blue, float alpha) :
        color_(Create_(space, red, green, blue, alpha))
    {
        Set(space, red, green, blue, alpha);
    }

    void Clear() {
        if (color_ != NULL)
            CGColorRelease(color_);
    }

    ~CYColor() {
        Clear();
    }

    void Set(CGColorSpaceRef space, float red, float green, float blue, float alpha) {
        Clear();
        color_ = Create_(space, red, green, blue, alpha);
    }

    operator CGColorRef() {
        return color_;
    }
};
/* }}} */

/* Random Global Variables {{{ */
static int PulseInterval_ = 500000;

static const NSString *UI_;

static int Finish_;
// Distinguish Sileo userspace reboot from a true full device reboot.
// Both keep the historical Cydia "Reboot Device" finish label/index, but the
// close action must execute the requested reboot type. 0=legacy/full-by-index,
// 1=userspace reboot requested, 2=explicit full reboot requested.
static int RebootMode_;
static bool UICache_ = false;
static bool RestartSubstrate_;

// Sileo keeps post-install actions as enum values. Do the same conversion
// directly instead of storing an autoreleased NSArray for the lifetime of the
// process. The old global array became a dangling pointer after launch and
// crashed _readCydia: in objc_msgSend as soon as a maintainer script emitted
// finish:restart, finish:reload or finish:reboot.
static int CYFinishIndexForName(NSString *name) {
    if ([name isEqualToString:@"return"])
        return 0;
    if ([name isEqualToString:@"reopen"])
        return 1;
    if ([name isEqualToString:@"restart"])
        return 2;
    if ([name isEqualToString:@"reload"])
        return 3;
    if ([name isEqualToString:@"reboot"])
        return 4;
    return INT_MAX;
}

#define SpringBoard_ "/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"
#define NotifyConfig_ "/etc/notify.conf"

static bool Queuing_;

static CYColor Blue_;
static CYColor Blueish_;
static CYColor Black_;
static CYColor Folder_;
static CYColor Off_;
static CYColor White_;
static CYColor Gray_;
static CYColor Green_;
static CYColor Purple_;
static CYColor Purplish_;

static UIColor *InstallingColor_;
static UIColor *RemovingColor_;

static NSString *App_;

static BOOL Advanced_;
static BOOL Ignored_;

static _H<UIFont> Font12_;
static _H<UIFont> Font12Bold_;
static _H<UIFont> Font14_;
static _H<UIFont> Font18_;
static _H<UIFont> Font18Bold_;
static _H<UIFont> Font22Bold_;

static _H<NSString> UniqueID_;

// FIX08 keeps source metadata on the bootstrap's modern HTTPS method and
// switches to the iOS-aware method only while downloading package archives.
static std::string StandardHTTPSMethod_;
// Standard-build audit anchors (the R2 target resolves the same method names
// below through CYDIA_APPLICATION_PATH):
// /var/jb/Applications/Cydia.app/bzip2
// /var/jb/Applications/Cydia.app/gzip
// /var/jb/Applications/Cydia.app/lzma
static const char *CydiaPackageHTTPSMethod_ = CYDIA_APPLICATION_PATH "/https";

static _H<NSLocale> CollationLocale_;
static _H<NSArray> CollationThumbs_;
static std::vector<NSInteger> CollationOffset_;
static _H<NSArray> CollationTitles_;
static _H<NSArray> CollationStarts_;
static UTransliterator *CollationTransl_;
//static Function<NSString *, NSString *> CollationModify_;

typedef std::basic_string<UChar> ustring;
static ustring CollationString_;

#define CUC const ustring &str(*reinterpret_cast<const ustring *>(rep))
#define UC ustring &str(*reinterpret_cast<ustring *>(rep))
static struct UReplaceableCallbacks CollationUCalls_ = {
    .length = [](const UReplaceable *rep) -> int32_t { CUC;
        return str.size();
    },

    .charAt = [](const UReplaceable *rep, int32_t offset) -> UChar { CUC;
        //fprintf(stderr, "charAt(%d) : %d\n", offset, str.size());
        if (offset >= str.size())
            return 0xffff;
        return str[offset];
    },

    .char32At = [](const UReplaceable *rep, int32_t offset) -> UChar32 { CUC;
        //fprintf(stderr, "char32At(%d) : %d\n", offset, str.size());
        if (offset >= str.size())
            return 0xffff;
        UChar32 c;
        U16_GET(str.data(), 0, offset, str.size(), c);
        return c;
    },

    .replace = [](UReplaceable *rep, int32_t start, int32_t limit, const UChar *text, int32_t length) -> void { UC;
        //fprintf(stderr, "replace(%d, %d, %d) : %d\n", start, limit, length, str.size());
        str.replace(start, limit - start, text, length);
    },

    .extract = [](UReplaceable *rep, int32_t start, int32_t limit, UChar *dst) -> void { UC;
        //fprintf(stderr, "extract(%d, %d) : %d\n", start, limit, str.size());
        str.copy(dst, limit - start, start);
    },

    .copy = [](UReplaceable *rep, int32_t start, int32_t limit, int32_t dest) -> void { UC;
        //fprintf(stderr, "copy(%d, %d, %d) : %d\n", start, limit, dest, str.size());
        str.replace(dest, 0, str, start, limit - start);
    },
};

static CFLocaleRef Locale_;
static NSArray *Languages_;
static CGColorSpaceRef space_;

#define CacheState_ Cache("CacheState.plist")
#define SavedState_ Cache("SavedState.plist")

static void CYStoreRepositoryVerificationState(bool verified, bool refreshed,
    size_t warnings = 0, NSDictionary *sourceIssues = nil) {
    NSMutableDictionary *state([NSMutableDictionary dictionaryWithContentsOfFile:CacheState_]);
    if (state == nil)
        state = [NSMutableDictionary dictionaryWithCapacity:3];
    [state setObject:[NSNumber numberWithBool:verified] forKey:@"LastUpdateVerified"];
    [state setObject:[NSNumber numberWithBool:refreshed] forKey:@"LastUpdateUsable"];
    [state setObject:[NSNumber numberWithUnsignedLongLong:warnings] forKey:@"LastUpdateWarnings"];
    if (sourceIssues != nil) {
        if ([sourceIssues count] == 0)
            [state removeObjectForKey:@"LastUpdateSourceIssues"];
        else
            [state setObject:sourceIssues forKey:@"LastUpdateSourceIssues"];
    }
    if (refreshed)
        [state setObject:[NSDate date] forKey:@"LastUpdate"];
    [state writeToFile:CacheState_ atomically:YES];
}

static NSDictionary *SectionMap_;
static _H<NSDate> Backgrounded_;
static _transient NSMutableDictionary *Values_;
static _transient NSMutableDictionary *Sections_;
_H<NSMutableDictionary> Sources_;
static _transient NSNumber *Version_;
static time_t now_;

static _H<NSMutableDictionary> SessionData_;

static NSString *CYCanonicalRepositoryURI(NSString *uri) {
    if ([uri length] == 0)
        return nil;
    const char *text([uri UTF8String]);
    if (text == NULL)
        return nil;
    const std::string canonical(CYSourceIdentity::CanonicalURI(text));
    return canonical.empty() ? nil : [NSString stringWithUTF8String:canonical.c_str()];
}

static void CYStoreSingleRepositoryRefreshState(NSString *uri, bool verified, bool usable,
    bool exclusiveURI, NSDictionary *newIssues) {
    NSString *canonical(CYCanonicalRepositoryURI(uri));
    if (canonical == nil)
        return;
    NSMutableDictionary *state([NSMutableDictionary dictionaryWithContentsOfFile:CacheState_]);
    if (state == nil)
        state = [NSMutableDictionary dictionary];
    id stored([state objectForKey:@"LastUpdateSourceIssues"]);
    NSMutableDictionary *issues([stored isKindOfClass:[NSDictionary class]] ?
        [NSMutableDictionary dictionaryWithDictionary:stored] : [NSMutableDictionary dictionary]);
    // Issue storage is URI-based. A different suite at the same URI may still
    // have a problem, so only a full refresh may clear that shared warning.
    if (verified && exclusiveURI)
        [issues removeObjectForKey:canonical];
    id issue([newIssues objectForKey:canonical]);
    if (issue != nil)
        [issues setObject:issue forKey:canonical];
    [state setObject:issues forKey:@"LastUpdateSourceIssues"];
    if (!verified)
        [state setObject:@NO forKey:@"LastUpdateVerified"];
    if (!usable)
        [state setObject:@NO forKey:@"LastUpdateUsable"];
    NSUInteger warnings(MAX([[state objectForKey:@"LastUpdateWarnings"] unsignedIntegerValue], [issues count]));
    [state setObject:@(warnings) forKey:@"LastUpdateWarnings"];
    [state writeToFile:CacheState_ atomically:YES];
}

static NSString *CYRepositoryIssueCode(NSString *uri) {
    NSString *canonical(CYCanonicalRepositoryURI(uri));
    if (canonical == nil)
        return nil;
    NSDictionary *state([NSDictionary dictionaryWithContentsOfFile:CacheState_]);
    id storedIssues([state objectForKey:@"LastUpdateSourceIssues"]);
    if (![storedIssues isKindOfClass:[NSDictionary class]])
        return nil;
    NSDictionary *issues((NSDictionary *) storedIssues);
    id code([issues objectForKey:canonical]);
    return [code isKindOfClass:[NSString class]] ? code : nil;
}

static BOOL CYRepositoryIssueIsSecurity(NSString *code) {
    return [code isEqualToString:@"unsigned"] ||
        [code isEqualToString:@"missing-key"] ||
        [code isEqualToString:@"obsolete-signature"] ||
        [code isEqualToString:@"invalid-signature"];
}

// The Sources checkmark answers whether the package data is usable. Modern
// repository compatibility does not ask the user to approve signing keys;
// metadata-signature advisories are therefore informational, while actual
// network/index failures still keep the warning state visible.
static BOOL CYRepositoryRefreshReadyForUse(void) {
    NSDictionary *state([NSDictionary dictionaryWithContentsOfFile:CacheState_]);
    if (![[state objectForKey:@"LastUpdateUsable"] boolValue])
        return NO;

    id storedIssues([state objectForKey:@"LastUpdateSourceIssues"]);
    if (![storedIssues isKindOfClass:[NSDictionary class]])
        return YES;

    NSDictionary *issues((NSDictionary *) storedIssues);
    for (NSString *uri in issues) {
        id value([issues objectForKey:uri]);
        NSString *code([value isKindOfClass:[NSString class]] ? (NSString *) value : nil);
        if (!CYRepositoryIssueIsSecurity(code))
            return NO;
    }
    return YES;
}

static NSString *CYRepositoryIssueSummary(NSString *code) {
    if ([code isEqualToString:@"unsigned"])
        return CYLocalize(@"Unsigned repository — no Release signature");
    if ([code isEqualToString:@"missing-key"])
        return CYLocalize(@"Signing key is missing");
    if ([code isEqualToString:@"obsolete-signature"])
        return CYLocalize(@"Obsolete repository signature");
    if ([code isEqualToString:@"invalid-signature"])
        return CYLocalize(@"Repository signature is invalid");
    if ([code isEqualToString:@"packages-missing"])
        return CYLocalize(@"Packages index was not found");
    return CYLocalize(@"Repository metadata is not authenticated");
}

static NSString *CYRepositoryIssueExplanation(NSString *code) {
    if ([code isEqualToString:@"unsigned"])
        return CYLocalize(@"This source does not publish a signed Release file, so its publisher identity cannot be verified.");
    if ([code isEqualToString:@"missing-key"])
        return CYLocalize(@"This source is signed, but its public signing key is not installed or was not supplied correctly.");
    if ([code isEqualToString:@"obsolete-signature"])
        return CYLocalize(@"This source uses an obsolete SHA-1 digest or legacy signing key that modern APT rejects.");
    if ([code isEqualToString:@"invalid-signature"])
        return CYLocalize(@"APT could not validate this source's repository signature.");
    if ([code isEqualToString:@"packages-missing"])
        return CYLocalize(@"The repository answered, but no supported Packages index was available at the configured path. Allowing it cannot repair a missing index.");
    return CYLocalize(@"APT could not authenticate this repository's metadata.");
}

static NSString *kCydiaProgressEventTypeError = @"Error";
static NSString *kCydiaProgressEventTypeInformation = @"Information";
static NSString *kCydiaProgressEventTypeStatus = @"Status";
static NSString *kCydiaProgressEventTypeWarning = @"Warning";
/* }}} */

/* Display Helpers {{{ */
static _finline const char *StripVersion_(const char *version) {
    const char *colon(strchr(version, ':'));
    return colon == NULL ? version : colon + 1;
}

NSString *LocalizeSection(NSString *section) {
    static RegEx title_r("(.*?) \\((.*)\\)");
    if (title_r(section)) {
        NSString *parent(title_r[1]);
        NSString *child(title_r[2]);

        return [NSString stringWithFormat:UCLocalize("PARENTHETICAL"),
            LocalizeSection(parent),
            LocalizeSection(child)
        ];
    }

    return [[NSBundle mainBundle] localizedStringForKey:section value:nil table:@"Sections"];
}

NSString *Simplify(NSString *title) {
    const char *data = [title UTF8String];
    size_t size = [title lengthOfBytesUsingEncoding:NSUTF8StringEncoding];

    static RegEx square_r("\\[(.*)\\]");
    if (square_r(data, size))
        return Simplify(square_r[1]);

    static RegEx paren_r("\\((.*)\\)");
    if (paren_r(data, size))
        return Simplify(paren_r[1]);

    static RegEx title_r("(.*?) \\((.*)\\)");
    if (title_r(data, size))
        return Simplify(title_r[1]);

    return title;
}

// Section artwork is data-driven and intentionally strict: every supported
// Cydia/APT section maps to one audited PNG filename. Common historical aliases
// are normalized first; anything else uses the supplied Unknown Package art.
static NSString *CYSectionIconFilename(NSString *section) {
    if ([section length] == 0)
        return nil;

    NSString *value([SectionMap_ objectForKey:section] ?: section);
    NSRange parenthetical([value rangeOfString:@" ("]);
    if (parenthetical.location != NSNotFound)
        value = [value substringToIndex:parenthetical.location];
    if ([value hasPrefix:@"["] && [value hasSuffix:@"]"] && [value length] > 2)
        value = [value substringWithRange:NSMakeRange(1, [value length] - 2)];
    value = [[value stringByReplacingOccurrencesOfString:@"_" withString:@" "]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *key([value lowercaseString]);

    static NSDictionary *aliases(nil);
    static NSDictionary *filenames(nil);
    @synchronized ([UIImage class]) {
        if (aliases == nil)
            aliases = [[NSDictionary alloc] initWithObjectsAndKeys:
                @"addons", @"app addons",
                @"addons", @"application addons",
                @"themes", @"battery",
                @"carrier bundles", @"carrier",
                @"carrier bundles", @"carriers",
                @"development", @"developer",
                @"themes", @"dialer",
                @"themes", @"dock",
                @"games", @"emulation",
                @"books", @"ebooks",
                @"health and fitness", @"health & fitness",
                @"repositories", @"icy",
                @"themes", @"lockscreen",
                @"tweaks", @"notifications",
                @"ringtones", @"ringtone",
                @"site-specific apps", @"site-specific",
                @"themes", @"sliders",
                @"messaging", @"sms",
                @"terminal support", @"terminal",
                @"tweaks", @"tweak",
                @"utilities", @"utilites",
                @"utilities", @"utility",
                @"wallpaper", @"wallpapers",
                @"themes", @"weather",
                @"site-specific apps", @"webclips",
                @"x window", @"x-window",
                @"x window", @"x11",
            nil];
        if (filenames == nil)
            filenames = [[NSDictionary alloc] initWithObjectsAndKeys:
                @"Addons.png", @"addons",
                @"Administration.png", @"administration",
                @"Archiving.png", @"archiving",
                @"Books.png", @"books",
                @"Carrier_Bundles.png", @"carrier bundles",
                @"Data_Storage.png", @"data storage",
                @"Development.png", @"development",
                @"Dictionaries.png", @"dictionaries",
                @"Education.png", @"education",
                @"Entertainment.png", @"entertainment",
                @"Fonts.png", @"fonts",
                @"Games.png", @"games",
                @"Health_and_Fitness.png", @"health and fitness",
                @"Java.png", @"java",
                @"Keyboards.png", @"keyboards",
                @"Localization.png", @"localization",
                @"Messaging.png", @"messaging",
                @"Multimedia.png", @"multimedia",
                @"Navigation.png", @"navigation",
                @"Networking.png", @"networking",
                @"Packaging.png", @"packaging",
                @"Productivity.png", @"productivity",
                @"Repositories.png", @"repositories",
                @"Ringtones.png", @"ringtones",
                @"Scripting.png", @"scripting",
                @"Security.png", @"security",
                @"Site-Specific_Apps.png", @"site-specific apps",
                @"Social.png", @"social",
                @"Soundboards.png", @"soundboards",
                @"System.png", @"system",
                @"Terminal_Support.png", @"terminal support",
                @"Text_Editors.png", @"text editors",
                @"Themes.png", @"themes",
                @"Toys.png", @"toys",
                @"Tweaks.png", @"tweaks",
                @"Utilities.png", @"utilities",
                @"Wallpaper.png", @"wallpaper",
                @"Widgets.png", @"widgets",
                @"X_Window.png", @"x window",
            nil];
    }

    NSString *alias([aliases objectForKey:key]);
    return [filenames objectForKey:(alias ?: key)];
}

static UIImage *CYSectionIconImage(NSString *section) {
    NSString *filename(CYSectionIconFilename(section));
    if (filename == nil)
        return nil;
    return [UIImage imageAtPath:[NSString stringWithFormat:@"%@/Sections/%@", App_, filename]];
}

static UIImage *CYNoSectionIcon(void) {
    return [UIImage imageAtPath:[NSString stringWithFormat:@"%@/Sections/Default.png", App_]];
}
/* }}} */

bool isSectionVisible(NSString *section) {
    NSDictionary *metadata([Sections_ objectForKey:(section ?: @"")]);
    NSNumber *hidden(metadata == nil ? nil : [metadata objectForKey:@"Hidden"]);
    return hidden == nil || ![hidden boolValue];
}

static NSString *VerifySource(NSString *href) {
    static RegEx href_r("(http(s?)://|file:///)[^# ]*");
    if (!href_r(href)) {
        [[[[UIAlertView alloc]
            initWithTitle:[NSString stringWithFormat:Colon_, Error_, UCLocalize("INVALID_URL")]
            message:UCLocalize("INVALID_URL_EX")
            delegate:nil
            cancelButtonTitle:UCLocalize("OK")
            otherButtonTitles:nil
        ] autorelease] show];

        return nil;
    }

    if (![href hasSuffix:@"/"])
        href = [href stringByAppendingString:@"/"];
    return href;
}

static NSString *CYExternalSourceQueryValue(NSString *query) {
    if ([query hasPrefix:@"?"])
        query = [query substringFromIndex:1];
    for (NSString *component in [query componentsSeparatedByString:@"&"]) {
        NSRange separator([component rangeOfString:@"="]);
        if (separator.location == NSNotFound)
            continue;
        NSString *key([[component substringToIndex:separator.location]
            stringByRemovingPercentEncoding]);
        if (![[key lowercaseString] isEqualToString:@"source"] &&
            ![[key lowercaseString] isEqualToString:@"url"])
            continue;
        NSString *value([[component substringFromIndex:separator.location + 1]
            stringByRemovingPercentEncoding]);
        return VerifySource(value);
    }
    return nil;
}

// Historical repository buttons use
// cydia://url/https://cydia.saurik.com/api/share#?source=<repo>.  That web
// bridge is no longer dependable and can redirect users away from the source
// flow.  Decode it locally, along with the direct add-source forms used by
// current repository sites, and hand the URL to the native Sources screen.
static NSString *CYExternalSourceFromCydiaURL(NSURL *url) {
    if (![[[url scheme] lowercaseString] isEqualToString:@"cydia"])
        return nil;
    NSString *absolute([url absoluteString]);
    NSString *prefix(@"cydia://");
    if (![absolute hasPrefix:prefix])
        return nil;
    NSString *route([absolute substringFromIndex:[prefix length]]);

    if ([route hasPrefix:@"url/"]) {
        NSString *destinationText([[route substringFromIndex:4]
            stringByRemovingPercentEncoding]);
        NSURL *destination([NSURL URLWithString:destinationText]);
        if (![[[[destination host] lowercaseString] stringByTrimmingCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"."]]
            isEqualToString:@"cydia.saurik.com"] ||
            ![[[destination path] lowercaseString] hasPrefix:@"/api/share"])
            return nil;
        NSString *source(CYExternalSourceQueryValue([destination query]));
        if (source == nil)
            source = CYExternalSourceQueryValue([destination fragment]);
        return source;
    }

    NSArray *directPrefixes([NSArray arrayWithObjects:
        @"sources/add/", @"source/add/", @"addsource/", nil]);
    for (NSString *directPrefix in directPrefixes)
        if ([[route lowercaseString] hasPrefix:directPrefix]) {
            NSString *encoded([route substringFromIndex:[directPrefix length]]);
            return VerifySource([encoded stringByRemovingPercentEncoding]);
        }
    return nil;
}

@class Cydia;

/* Delegate Prototypes {{{ */
@class Package;
@class Source;
@class CydiaProgressEvent;

@protocol DatabaseDelegate
- (void) repairWithSelector:(SEL)selector;
- (void) setConfigurationData:(NSString *)data;
- (void) addProgressEventOnMainThread:(CydiaProgressEvent *)event forTask:(NSString *)task;
@end

@class CYPackageController;

@protocol SourceDelegate
- (void) setSourceFetch:(NSArray *)state;
@end

@protocol FetchDelegate
- (bool) isSourceCancelled;
- (void) startSourceFetch:(NSString *)uri;
- (void) stopSourceFetch:(NSString *)uri;
@end

@protocol CydiaDelegate
- (void) returnToCydia;
- (void) setHomePresentationActive:(BOOL)active;
- (void) saveState;
- (void) retainNetworkActivityIndicator;
- (void) releaseNetworkActivityIndicator;
- (void) clearPackage:(Package *)package;
- (void) installPackage:(Package *)package;
- (void) installPackages:(NSArray *)packages;
- (void) removePackage:(Package *)package;
- (void) beginUpdate;
- (BOOL) updating;
- (BOOL) hasRepositoryVerificationResult;
- (BOOL) repositoriesVerified;
- (bool) requestUpdate;
- (bool) requestUpdateForSourceKey:(NSString *)sourceKey;
- (void) distUpgrade;
- (void) loadData;
- (void) updateData;
- (void) _saveConfig;
- (void) syncData;
- (void) addSource:(NSDictionary *)source;
- (BOOL) addTrivialSource:(NSString *)href;
- (CydiaLoadingView *) addProgressHUD;
- (void) removeProgressHUD:(CydiaLoadingView *)hud;
- (void) showActionSheet:(UIActionSheet *)sheet fromItem:(UIBarButtonItem *)item;
- (CyteViewController *) pageForURL:(NSURL *)url forExternal:(BOOL)external withReferrer:(NSString *)referrer;
- (void) reloadDataWithInvocation:(NSInvocation *)invocation;
@end
/* }}} */

/* CancelStatus {{{ */
class CancelStatus :
    public pkgAcquireStatus
{
  private:
    bool cancelled_;

  public:
    CancelStatus() :
        cancelled_(false)
    {
    }

    virtual bool MediaChange(std::string media, std::string drive) {
        return false;
    }

    virtual void IMSHit(pkgAcquire::ItemDesc &desc) {
        Done(desc);
    }

    virtual void Start() {
        cancelled_ = false;
        pkgAcquireStatus::Start();
    }

    virtual bool Pulse_(pkgAcquire *Owner) = 0;

    virtual bool Pulse(pkgAcquire *Owner) {
        if (pkgAcquireStatus::Pulse(Owner) && Pulse_(Owner))
            return true;
        else {
            cancelled_ = true;
            return false;
        }
    }

    _finline bool WasCancelled() const {
        return cancelled_;
    }
};
/* }}} */
/* DelegateStatus {{{ */
class CydiaStatus :
    public CancelStatus
{
  private:
    _transient NSObject<ProgressDelegate> *delegate_;
    std::map<pkgAcquire::Item *, std::string> initialUris_;

  public:
    CydiaStatus() :
        delegate_(nil)
    {
    }

    void setDelegate(NSObject<ProgressDelegate> *delegate) {
        delegate_ = delegate;
    }

    virtual void Fetch(pkgAcquire::ItemDesc &desc) {
        initialUris_[desc.Owner] = desc.URI;
        NSString *name([NSString stringWithUTF8String:desc.ShortDesc.c_str()]);
        CYRootlessDiag(@"DOWNLOAD", @"phase=request package=%@ originalURL=%@",
            name ?: @"<unknown>", CYDiagnosticURLString(desc.URI));
        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithFormat:UCLocalize("DOWNLOADING_"), name] ofType:kCydiaProgressEventTypeStatus forItemDesc:desc]);
        [[[delegate_ retain] autorelease] performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
    }

    virtual void Done(pkgAcquire::ItemDesc &desc) {
        NSString *name([NSString stringWithUTF8String:desc.ShortDesc.c_str()]);
        std::map<pkgAcquire::Item *, std::string>::iterator initial(initialUris_.find(desc.Owner));
        std::string original(initial == initialUris_.end() ? desc.URI : initial->second);
        bool httpRedirect(CYHTTPURLString(original) && CYHTTPURLString(desc.URI) && original != desc.URI);
        CYRootlessDiag(@"DOWNLOAD", @"phase=done package=%@ originalURL=%@ finalURL=%@ uriChanged=%d redirectObserved=%d httpStatus=%d",
            name ?: @"<unknown>", CYDiagnosticURLString(original), CYDiagnosticURLString(desc.URI), original != desc.URI,
            httpRedirect, CYHTTPURLString(desc.URI) ? 200 : 0);
        if (initial != initialUris_.end())
            initialUris_.erase(initial);
        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithFormat:Colon_, UCLocalize("DONE"), name] ofType:kCydiaProgressEventTypeStatus forItemDesc:desc]);
        [[[delegate_ retain] autorelease] performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
    }

    virtual void Fail(pkgAcquire::ItemDesc &desc) {
        if (
            desc.Owner->Status == pkgAcquire::Item::StatIdle ||
            desc.Owner->Status == pkgAcquire::Item::StatDone
        )
            return;

        std::string &error(desc.Owner->ErrorText);
        if (error.empty())
            return;

        std::map<pkgAcquire::Item *, std::string>::iterator initial(initialUris_.find(desc.Owner));
        std::string original(initial == initialUris_.end() ? desc.URI : initial->second);
        int httpStatus(CYHTTPStatusFromAcquireError(error));
        NSString *name([NSString stringWithUTF8String:desc.ShortDesc.c_str()]);
        NSString *reason(CYSanitizeDownloadText([NSString stringWithUTF8String:error.c_str()]));
        bool httpRedirect(CYHTTPURLString(original) && CYHTTPURLString(desc.URI) && original != desc.URI);
        CYRootlessDiag(@"DOWNLOAD", @"phase=fail package=%@ originalURL=%@ finalURL=%@ uriChanged=%d redirectObserved=%d httpStatus=%d reason=%@",
            name ?: @"<unknown>", CYDiagnosticURLString(original), CYDiagnosticURLString(desc.URI), original != desc.URI,
            httpRedirect, httpStatus, reason ?: @"<non-UTF8 error>");
        if (initial != initialUris_.end())
            initialUris_.erase(initial);

        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:reason ofType:kCydiaProgressEventTypeError forItemDesc:desc]);
        [[[delegate_ retain] autorelease] performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
    }

    virtual bool Pulse_(pkgAcquire *Owner) {
        double total(double(TotalBytes) + double(TotalItems));
        double percent(total > 0.0 ? (double(CurrentBytes) + double(CurrentItems)) / total : 0.0);

        [[[delegate_ retain] autorelease] performSelectorOnMainThread:@selector(setProgressStatus:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithDouble:percent], @"Percent",

            [NSNumber numberWithDouble:CurrentBytes], @"Current",
            [NSNumber numberWithDouble:TotalBytes], @"Total",
            [NSNumber numberWithDouble:CurrentCPS], @"Speed",
        nil] waitUntilDone:YES];

        return ![delegate_ isProgressCancelled];
    }

    virtual void Start() {
        CancelStatus::Start();
        [[[delegate_ retain] autorelease] performSelectorOnMainThread:@selector(setProgressCancellable:) withObject:[NSNumber numberWithBool:YES] waitUntilDone:YES];
    }

    virtual void Stop() {
        pkgAcquireStatus::Stop();
        [[[delegate_ retain] autorelease] performSelectorOnMainThread:@selector(setProgressCancellable:) withObject:[NSNumber numberWithBool:NO] waitUntilDone:YES];
        [[[delegate_ retain] autorelease] performSelectorOnMainThread:@selector(setProgressStatus:) withObject:nil waitUntilDone:YES];
    }
};
/* }}} */
/* Database Interface {{{ */
typedef std::map< unsigned long, _H<Source> > SourceMap;

// Distinguish an untouched queue from a dpkg attempt, which may have applied
// only some operations before failing and must always be read back from disk.
enum CYPackageTransactionResult {
    CYPackageTransactionNotStarted,
    CYPackageTransactionAttempted,
    CYPackageTransactionCompleted
};

@interface Database : NSObject {
    NSZone *zone_;
    CYPool pool_;

    unsigned era_;
    bool ready_;
    bool configurationSucceeded_;
    _H<NSDate> delock_;

    pkgCacheFile cache_;
    pkgDepCache::Policy *policy_;
    pkgRecords *records_;
    pkgProblemResolver *resolver_;
    pkgAcquire *fetcher_;
    FileFd *lock_;
    SPtr<pkgPackageManager> manager_;
    pkgSourceList *list_;

    SourceMap sourceMap_;
    _H<NSMutableArray> sourceList_;

    _H<NSArray> packages_;

    _transient NSObject<DatabaseDelegate> *delegate_;
    _transient NSObject<ProgressDelegate> *progress_;

    CydiaStatus status_;

    int cydiafd_;
    int statusfd_;
    FILE *input_;

    std::map<const char *, _H<NSString> > sections_;
}

+ (Database *) sharedInstance;
- (unsigned) era;
- (bool) hasPackages;
- (bool) ready;

- (void) _readCydia:(NSNumber *)fd;
- (void) _readStatus:(NSNumber *)fd;
- (void) _readOutput:(NSNumber *)fd;

- (FILE *) input;

- (Package *) packageWithName:(NSString *)name;

- (pkgCacheFile &) cache;
- (pkgDepCache::Policy *) policy;
- (pkgRecords *) records;
- (pkgProblemResolver *) resolver;
- (pkgAcquire &) fetcher;
- (pkgSourceList &) list;
- (NSArray *) packages;
- (NSArray *) sources;
- (Source *) sourceWithKey:(NSString *)key;
- (void) reloadDataWithInvocation:(NSInvocation *)invocation;

- (void) configure;
- (bool) prepare;
- (void) perform;
- (CYPackageTransactionResult) performWithRequestedIdentifiers:(NSSet *)requestedIdentifiers;
- (CYPackageTransactionResult) performWithRequestedIdentifiers:(NSSet *)requestedIdentifiers retryCount:(NSUInteger)retryCount;
- (NSArray *) transactionOperationsForRequestedIdentifiers:(NSSet *)requestedIdentifiers;
- (NSSet *) transactionPlan;
- (bool) restoreTransactionOperations:(NSArray *)operations title:(NSString *)title;
- (bool) rebuildTransactionForRequestedIdentifiers:(NSSet *)requestedIdentifiers title:(NSString *)title;
- (bool) upgrade;
- (void) update;

- (bool) updateWithStatus:(CancelStatus &)status;
- (bool) updateWithStatus:(CancelStatus &)status sourceKey:(NSString *)sourceKey;

- (void) setDelegate:(NSObject<DatabaseDelegate> *)delegate;

- (void) setProgressDelegate:(NSObject<ProgressDelegate> *)delegate;
- (NSObject<ProgressDelegate> *) progressDelegate;
- (NSObject<ProgressDelegate> *) safeProgressDelegate;
- (NSObject<DatabaseDelegate> *) safeDatabaseDelegate;

- (Source *) getSource:(pkgCache::PkgFileIterator)file;
- (void) setFetch:(bool)fetch forURI:(const char *)uri;
- (void) resetFetch;

- (NSString *) mappedSectionForPointer:(const char *)pointer;

@end
/* }}} */
/* SourceStatus {{{ */
class SourceStatus :
    public CancelStatus
{
  private:
    _transient NSObject<FetchDelegate> *delegate_;
    _transient Database *database_;
    std::set<std::string> fetches_;

  public:
    SourceStatus(NSObject<FetchDelegate> *delegate, Database *database) :
        delegate_(delegate),
        database_(database)
    {
    }

    void Set(bool fetch, const std::string &uri) {
        if (fetch) {
            if (!fetches_.insert(uri).second)
                return;
        } else {
            if (fetches_.erase(uri) == 0)
                return;
        }

        //printf("Set(%s, %s)\n", fetch ? "true" : "false", uri.c_str());

        auto slash(uri.rfind('/'));
        if (slash == std::string::npos)
            return;
        const std::string directory(uri.substr(0, slash));
        // Several index transfers can share one directory. Publish only its
        // first start and last finish, so completing one file cannot hide the
        // source's indicator while another transfer is still active.
        for (const std::string &active : fetches_) {
            auto activeSlash(active.rfind('/'));
            if (active != uri && activeSlash != std::string::npos &&
                active.substr(0, activeSlash) == directory)
                return;
        }
        [database_ setFetch:fetch forURI:directory.c_str()];
    }

    _finline void Set(bool fetch, pkgAcquire::Item *item) {
        /*unsigned long ID(fetch ? 1 : 0);
        if (item->ID == ID)
            return;
        item->ID = ID;*/
        Set(fetch, item->DescURI());
    }

    void Log(const char *tag, pkgAcquire::Item *item) {
        //printf("%s(%s) S:%u Q:%u\n", tag, item->DescURI().c_str(), item->Status, item->QueueCounter);
    }

    virtual void Fetch(pkgAcquire::ItemDesc &desc) {
        Log("Fetch", desc.Owner);
        Set(true, desc.Owner);
    }

    virtual void Done(pkgAcquire::ItemDesc &desc) {
        Log("Done", desc.Owner);
        Set(false, desc.Owner);
    }

    virtual void Fail(pkgAcquire::ItemDesc &desc) {
        Log("Fail", desc.Owner);
        Set(false, desc.Owner);
    }

    virtual bool Pulse_(pkgAcquire *Owner) {
        std::set<std::string> fetches;
        for (pkgAcquire::ItemCIterator item(Owner->ItemsBegin()); item != Owner->ItemsEnd(); ++item) {
            bool fetch;
            if ((*item)->QueueCounter == 0)
                fetch = false;
            else switch ((*item)->Status) {
                case pkgAcquire::Item::StatFetching:
                    fetches.insert((*item)->DescURI());
                    fetch = true;
                break;

                default:
                    fetch = false;
                break;
            }

            Log(fetch ? "Pulse<true>" : "Pulse<false>", *item);
            Set(fetch, *item);
        }

        std::vector<std::string> stops;
        std::set_difference(fetches_.begin(), fetches_.end(), fetches.begin(), fetches.end(), std::back_insert_iterator<std::vector<std::string>>(stops));
        for (std::vector<std::string>::const_iterator stop(stops.begin()); stop != stops.end(); ++stop) {
            //printf("Stop(%s)\n", stop->c_str());
            Set(false, *stop);
        }

        return ![delegate_ isSourceCancelled];
    }

    virtual void Stop() {
        pkgAcquireStatus::Stop();
        [database_ resetFetch];
    }
};
/* }}} */
/* ProgressEvent Implementation {{{ */
@implementation CydiaProgressEvent

+ (CydiaProgressEvent *) eventWithMessage:(NSString *)message ofType:(NSString *)type {
    return [[[CydiaProgressEvent alloc] initWithMessage:message ofType:type] autorelease];
}

+ (CydiaProgressEvent *) eventWithMessage:(NSString *)message ofType:(NSString *)type forPackage:(NSString *)package {
    CydiaProgressEvent *event([self eventWithMessage:message ofType:type]);
    [event setPackage:package];
    return event;
}

+ (CydiaProgressEvent *) eventWithMessage:(NSString *)message ofType:(NSString *)type forItemDesc:(pkgAcquire::ItemDesc &)desc {
    CydiaProgressEvent *event([self eventWithMessage:message ofType:type]);

    NSString *description([NSString stringWithUTF8String:desc.Description.c_str()]);
    NSArray *fields([description componentsSeparatedByString:@" "]);
    [event setItem:fields];

    if ([fields count] > 3) {
        [event setPackage:[fields objectAtIndex:2]];
        [event setVersion:[fields objectAtIndex:3]];
    }

    [event setURL:[NSString stringWithUTF8String:desc.URI.c_str()]];

    return event;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"item",
        @"message",
        @"package",
        @"type",
        @"url",
        @"version",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (id) initWithMessage:(NSString *)message ofType:(NSString *)type {
    if ((self = [super init]) != nil) {
        message_ = message;
        type_ = type;
    } return self;
}

- (NSString *) message {
    return message_;
}

- (NSString *) type {
    return type_;
}

- (NSArray *) item {
    return (id) item_ ?: [NSNull null];
}

- (void) setItem:(NSArray *)item {
    item_ = item;
}

- (NSString *) package {
    return (id) package_ ?: [NSNull null];
}

- (void) setPackage:(NSString *)package {
    package_ = package;
}

- (NSString *) url {
    return (id) url_ ?: [NSNull null];
}

- (void) setURL:(NSString *)url {
    url_ = url;
}

- (void) setVersion:(NSString *)version {
    version_ = version;
}

- (NSString *) version {
    return (id) version_ ?: [NSNull null];
}

- (NSString *) compound:(NSString *)value {
    if (value != nil) {
        NSString *mode(nil); {
            NSString *type([self type]);
            if ([type isEqualToString:kCydiaProgressEventTypeError])
                mode = UCLocalize("ERROR");
            else if ([type isEqualToString:kCydiaProgressEventTypeWarning])
                mode = UCLocalize("WARNING");
        }

        if (mode != nil)
            value = [NSString stringWithFormat:UCLocalize("COLON_DELIMITED"), mode, value];
    }

    return value;
}

- (NSString *) compoundMessage {
    return [self compound:[self message]];
}

- (NSString *) compoundTitle {
    NSString *title;

    if (package_ == nil)
        title = nil;
    else if (Package *package = [[Database sharedInstance] packageWithName:package_])
        title = [(id) package name];
    else
        title = package_;

    return [self compound:title];
}

@end
/* }}} */

// Cytore Definitions {{{
struct PackageValue :
    Cytore::Block
{
    Cytore::Offset<PackageValue> next_;

    uint32_t index_ : 23;
    uint32_t subscribed_ : 1;
    uint32_t : 8;

    int32_t first_;
    int32_t last_;

    uint16_t vhash_;
    uint16_t nhash_;

    char version_[8];
    char name_[];
} _packed;

struct MetaValue :
    Cytore::Block
{
    uint32_t active_;
    Cytore::Offset<PackageValue> packages_[1 << 16];
} _packed;

static Cytore::File<MetaValue> MetaFile_;
// }}}
// Cytore Helper Functions {{{
static PackageValue *PackageFind(const char *name, size_t length, bool *fail = NULL) {
    SplitHash nhash = { hashlittle(name, length) };

    PackageValue *metadata;

    Cytore::Offset<PackageValue> *offset(&MetaFile_->packages_[nhash.u16[0]]);
    for (;; offset = &metadata->next_) { if (offset->IsNull()) {
        Cytore::Offset<PackageValue> allocated(MetaFile_.New<PackageValue>(length + 1));
        if (allocated.IsNull()) {
            if (fail != NULL)
                *fail = true;
            metadata = new PackageValue();
            memset(metadata, 0, sizeof(*metadata));
        } else {
            *offset = allocated;
            metadata = &MetaFile_.Get(*offset);
        }

        memcpy(metadata->name_, name, length);
        metadata->name_[length] = '\0';
        metadata->nhash_ = nhash.u16[1];
    } else {
        metadata = &MetaFile_.Get(*offset);
        if (metadata->nhash_ != nhash.u16[1])
            continue;
        if (strncmp(metadata->name_, name, length) != 0)
            continue;
        if (metadata->name_[length] != '\0')
            continue;
    } break; }

    return metadata;
}

static void PackageImport(const void *key, const void *value, void *context) {
    bool &fail(*reinterpret_cast<bool *>(context));

    char buffer[1024];
    if (!CFStringGetCString((CFStringRef) key, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        NSLog(@"failed to import package %@", key);
        return;
    }

    PackageValue *metadata(PackageFind(buffer, strlen(buffer), &fail));
    NSDictionary *package((NSDictionary *) value);

    if (NSNumber *subscribed = [package objectForKey:@"IsSubscribed"])
        if ([subscribed boolValue] && !metadata->subscribed_)
            metadata->subscribed_ = true;

    if (NSDate *date = [package objectForKey:@"FirstSeen"]) {
        time_t time([date timeIntervalSince1970]);
        if (metadata->first_ > time || metadata->first_ == 0)
            metadata->first_ = time;
    }

    NSDate *date([package objectForKey:@"LastSeen"]);
    NSString *version([package objectForKey:@"LastVersion"]);

    if (date != nil && version != nil) {
        time_t time([date timeIntervalSince1970]);
        if (metadata->last_ < time || metadata->last_ == 0)
            if (CFStringGetCString((CFStringRef) version, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
                size_t length(strlen(buffer));
                uint16_t vhash(hashlittle(buffer, length));

                size_t capped(std::min<size_t>(8, length));
                char *latest(buffer + length - capped);

                strncpy(metadata->version_, latest, sizeof(metadata->version_));
                metadata->vhash_ = vhash;

                metadata->last_ = time;
            }
    }
}
// }}}

static NSDate *GetStatusDate() {
    return [[[NSFileManager defaultManager] attributesOfItemAtPath:@"/var/jb/var/lib/dpkg/status" error:NULL] fileModificationDate];
}

static void SaveConfig(NSObject *lock) {
    NSObject *synchronizationLock(lock);
    if (synchronizationLock == nil)
        synchronizationLock = (NSObject *) [NSObject class];

    @synchronized (synchronizationLock) {
        _trace();
        MetaFile_.Sync();
        _trace();
    }

    CFPreferencesSetMultiple((CFDictionaryRef) [NSDictionary dictionaryWithObjectsAndKeys:
        Values_, @"CydiaValues",
        Sections_, @"CydiaSections",
        (id) Sources_, @"CydiaSources",
        Version_, @"CydiaVersion",
    nil], NULL, CFSTR("com.saurik.Cydia"), kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);

    if (!CFPreferencesAppSynchronize(CFSTR("com.saurik.Cydia")))
        NSLog(@"CFPreferencesAppSynchronize(com.saurik.Cydia) == false");

    CydiaWriteSources();
}

/* Source Class {{{ */
@interface Source : NSObject {
    unsigned era_;
    Database *database_;
    metaIndex *index_;

    CYString depiction_;
    CYString description_;
    CYString label_;
    CYString origin_;
    CYString support_;

    CYString uri_;
    CYString distribution_;
    CYString type_;
    CYString base_;
    CYString version_;

    _H<NSString> host_;
    _H<NSString> authority_;

    CYString defaultIcon_;

    _H<NSMutableDictionary> record_;
    BOOL trusted_;

    std::set<std::string> fetches_;
    std::set<std::string> files_;
    _transient NSObject<SourceDelegate> *delegate_;
}

- (Source *) initWithMetaIndex:(metaIndex *)index forDatabase:(Database *)database inPool:(CYPool *)pool withAcquire:(pkgAcquire *)acquire;

- (NSComparisonResult) compareByName:(Source *)source;

- (NSString *) depictionForPackage:(NSString *)package;
- (NSString *) supportForPackage:(NSString *)package;

- (metaIndex *) metaIndex;
- (NSDictionary *) record;
- (BOOL) trusted;

- (NSString *) rooturi;
- (NSString *) distribution;
- (NSString *) type;

- (NSString *) key;
- (NSString *) host;

- (NSString *) name;
- (NSString *) shortDescription;
- (NSString *) label;
- (NSString *) origin;
- (NSString *) version;

- (NSString *) defaultIcon;
- (NSURL *) iconURL;

- (void) setFetch:(bool)fetch forURI:(const char *)uri;
- (void) resetFetch;

@end

// Persistent repository display-name cache. Like Sileo's stored repoName, a
// name resolved once from Origin/Label is remembered so a later refresh whose
// fresh metadata parse momentarily yields neither field never regresses the
// Sources list to a bare hostname.
static NSMutableDictionary *CYSourceDisplayNameCache(void) {
    static NSMutableDictionary *cache(nil);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *stored([[NSUserDefaults standardUserDefaults] dictionaryForKey:@"CydiaSourceDisplayNamesV1"]);
        cache = [stored isKindOfClass:[NSDictionary class]] ? [stored mutableCopy] : [[NSMutableDictionary alloc] init];
    });
    return cache;
}

static void CYStoreSourceDisplayName(NSString *key, NSString *name) {
    if ([key length] == 0 || [name length] == 0)
        return;
    @synchronized (CYSourceDisplayNameCache()) {
        if ([[CYSourceDisplayNameCache() objectForKey:key] isEqualToString:name])
            return;
        [CYSourceDisplayNameCache() setObject:name forKey:key];
        [[NSUserDefaults standardUserDefaults] setObject:CYSourceDisplayNameCache() forKey:@"CydiaSourceDisplayNamesV1"];
    }
}

static NSString *CYRememberedSourceDisplayName(NSString *key) {
    if ([key length] == 0)
        return nil;
    @synchronized (CYSourceDisplayNameCache()) {
        return [[[CYSourceDisplayNameCache() objectForKey:key] retain] autorelease];
    }
}

@implementation Source

+ (NSString *) webScriptNameForSelector:(SEL)selector {
    if (false);
    else if (selector == @selector(addSection:))
        return @"addSection";
    else if (selector == @selector(getField:))
        return @"getField";
    else if (selector == @selector(removeSection:))
        return @"removeSection";
    else if (selector == @selector(remove))
        return @"remove";
    else
        return nil;
}

+ (BOOL) isSelectorExcludedFromWebScript:(SEL)selector {
    return [self webScriptNameForSelector:selector] == nil;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"baseuri",
        @"distribution",
        @"host",
        @"key",
        @"iconuri",
        @"label",
        @"name",
        @"origin",
        @"rooturi",
        @"sections",
        @"shortDescription",
        @"trusted",
        @"type",
        @"version",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (metaIndex *) metaIndex {
    return index_;
}

- (void) setMetaIndex:(metaIndex *)index inPool:(CYPool *)pool withAcquire:(pkgAcquire *)acquire {
    trusted_ = index->IsTrusted();

    uri_.set(pool, index->GetURI());
    distribution_.set(pool, index->GetDist());
    type_.set(pool, index->GetType());

    // APT already parses Origin/Label/Version from whichever
    // authenticated metadata form the repository uses (Release or InRelease).
    // Reading only debReleaseIndex::MetaIndexFile("Release") loses these
    // fields for modern InRelease-only repositories and makes Source::name
    // fall back to the hostname.  Seed the Cydia Source model from APT's
    // parsed metaIndex first; the legacy Release parser below remains only
    // for Cydia-specific fields such as Depiction/Support/Default-Icon.
    std::string aptOrigin(index->GetOrigin());
    std::string aptLabel(index->GetLabel());
    std::string aptVersion(index->GetVersion());
    if (!aptOrigin.empty())
        origin_.set(pool, aptOrigin);
    if (!aptLabel.empty())
        label_.set(pool, aptLabel);
    if (!aptVersion.empty())
        version_.set(pool, aptVersion);

    debReleaseIndex *dindex(dynamic_cast<debReleaseIndex *>(index));
    if (dindex != NULL) {
        std::string file(dindex->MetaIndexURI(""));
        base_.set(pool, file);

        // All Source models share this acquire queue. GetIndexes appends this
        // repository's items; earlier items belong to other repositories.
        // Keep an offset rather than an iterator, since appending can move the
        // underlying vector. Only this source's targets may drive its row.
        size_t firstSourceItem(acquire->ItemsEnd() - acquire->ItemsBegin());
        _profile(Source$setMetaIndex$GetIndexes)
        dindex->GetIndexes(acquire, true);
        _end
        _profile(Source$setMetaIndex$DescURI)
        for (pkgAcquire::ItemIterator item(acquire->ItemsBegin() + firstSourceItem); item != acquire->ItemsEnd(); item++) {
            std::string file((*item)->DescURI());
            auto slash(file.rfind('/'));
            if (slash == std::string::npos)
                continue;
            files_.insert(file.substr(0, slash));
        }
        _end

        // Mirror APT's own ReleaseFileName/OpenMaybeClearSignedFile
        // behavior. Modern repositories commonly keep the authenticated
        // metadata as a clear-signed InRelease file; opening only the
        // detached-signature Release path makes Origin disappear and leaves
        // Cydia showing a hostname such as ellekit.space/tigisoftware.com.
        // Sileo also derives the visible repository title from the Release
        // Origin field. We keep using APT's already-downloaded, verified
        // metadata instead of introducing a second network fetch.
        std::string metadataPath(dindex->MetaIndexFile("InRelease"));
        const char *metadataKind("InRelease");
        if (!FileExists(metadataPath)) {
            metadataPath = dindex->MetaIndexFile("Release");
            metadataKind = "Release";
        }

        FileFd fd;
        if (!FileExists(metadataPath) || !OpenMaybeClearSignedFile(metadataPath, fd)) {
            CYRootlessDiag(@"SOURCE", @"metadata parse status=missing-or-open-failed kind=%s path=%s uri=%@",
                metadataKind, metadataPath.c_str(), CYRootlessDiagnosticsText((NSString *) uri_));
            _error->Discard();
        } else {
            pkgTagFile tags(&fd);
            pkgTagSection section;
            if (!tags.Step(section)) {
                CYRootlessDiag(@"SOURCE", @"metadata parse status=tag-failed kind=%s path=%s uri=%@",
                    metadataKind, metadataPath.c_str(), CYRootlessDiagnosticsText((NSString *) uri_));
                _error->Discard();
            } else {
                struct {
                    const char *name_;
                    CYString *value_;
                } names[] = {
                    {"default-icon", &defaultIcon_},
                    {"depiction", &depiction_},
                    {"description", &description_},
                    {"label", &label_},
                    {"origin", &origin_},
                    {"support", &support_},
                    {"version", &version_},
                };

                for (size_t i(0); i != sizeof(names) / sizeof(names[0]); ++i) {
                    const char *start, *end;

                    if (section.Find(names[i].name_, start, end)) {
                        CYString &value(*names[i].value_);
                        value.set(pool, start, end - start);
                    }
                }

                CYRootlessDiag(@"SOURCE", @"metadata parse status=ok kind=%s origin=%@ label=%@ uri=%@",
                    metadataKind,
                    origin_.empty() ? @"<nil>" : (NSString *) origin_,
                    label_.empty() ? @"<nil>" : (NSString *) label_,
                    CYRootlessDiagnosticsText((NSString *) uri_));
            }
        }
    }

    record_ = [Sources_ objectForKey:[self key]];

    NSURL *url([NSURL URLWithString:uri_]);

    host_ = [url host];
    if (host_ != nil)
        host_ = [host_ lowercaseString];

    if (host_ != nil)
        authority_ = host_;
    else
        authority_ = [url path];

    if (!origin_.empty())
        CYStoreSourceDisplayName([self key], (NSString *) origin_);
    else if (!label_.empty())
        CYStoreSourceDisplayName([self key], (NSString *) label_);
}

- (Source *) initWithMetaIndex:(metaIndex *)index forDatabase:(Database *)database inPool:(CYPool *)pool withAcquire:(pkgAcquire *)acquire {
    if ((self = [super init]) != nil) {
        era_ = [database era];
        database_ = database;
        index_ = index;

        _profile(Source$initWithMetaIndex$setMetaIndex)
        [self setMetaIndex:index inPool:pool withAcquire:acquire];
        _end
    } return self;
}

- (NSString *) getField:(NSString *)name {
@synchronized (database_) {
    if ([database_ era] != era_ || index_ == NULL)
        return nil;

    debReleaseIndex *dindex(dynamic_cast<debReleaseIndex *>(index_));
    if (dindex == NULL)
        return nil;

    std::string metadataPath(dindex->MetaIndexFile("InRelease"));
    if (!FileExists(metadataPath))
        metadataPath = dindex->MetaIndexFile("Release");

    FileFd fd;
    if (!FileExists(metadataPath) || !OpenMaybeClearSignedFile(metadataPath, fd)) {
         _error->Discard();
         return nil;
    }

    pkgTagFile tags(&fd);

    pkgTagSection section;
    if (!tags.Step(section)) {
        _error->Discard();
        return nil;
    }

    const char *start, *end;
    if (!section.Find([name UTF8String], start, end))
        return (NSString *) [NSNull null];

    return [NSString stringWithString:[(NSString *) CYStringCreate(start, end - start) autorelease]];
} }

- (NSComparisonResult) compareByName:(Source *)source {
    NSString *lhs = [self name];
    NSString *rhs = [source name];

    if ([lhs length] != 0 && [rhs length] != 0) {
        unichar lhc = [lhs characterAtIndex:0];
        unichar rhc = [rhs characterAtIndex:0];

        if (isalpha(lhc) && !isalpha(rhc))
            return NSOrderedAscending;
        else if (!isalpha(lhc) && isalpha(rhc))
            return NSOrderedDescending;
    }

    return [lhs compare:rhs options:LaxCompareOptions_];
}

- (NSString *) depictionForPackage:(NSString *)package {
    return depiction_.empty() ? nil : [static_cast<id>(depiction_) stringByReplacingOccurrencesOfString:@"*" withString:package];
}

- (NSString *) supportForPackage:(NSString *)package {
    return support_.empty() ? nil : [static_cast<id>(support_) stringByReplacingOccurrencesOfString:@"*" withString:package];
}

- (NSArray *) sections {
    return record_ == nil ? (id) [NSNull null] : [record_ objectForKey:@"Sections"] ?: [NSArray array];
}

- (void) _addSection:(NSString *)section {
    if (record_ == nil)
        return;
    else if (NSMutableArray *sections = [record_ objectForKey:@"Sections"]) {
        if (![sections containsObject:section])
            [sections addObject:section];
    } else
        [record_ setObject:[NSMutableArray arrayWithObject:section] forKey:@"Sections"];
}

- (bool) addSection:(NSString *)section {
    if (record_ == nil)
        return false;

    [self performSelectorOnMainThread:@selector(_addSection:) withObject:section waitUntilDone:NO];
    return true;
}

- (void) _removeSection:(NSString *)section {
    if (record_ == nil)
        return;

    if (NSMutableArray *sections = [record_ objectForKey:@"Sections"])
        if ([sections containsObject:section])
            [sections removeObject:section];
}

- (bool) removeSection:(NSString *)section {
    if (record_ == nil)
        return false;

    [self performSelectorOnMainThread:@selector(_removeSection:) withObject:section waitUntilDone:NO];
    return true;
}

- (void) _remove {
@synchronized (database_) {
    NSString *key([self key]);
    Source *current([database_ sourceWithKey:key]);
    if (record_ == nil || [current record] != (NSMutableDictionary *) record_ || [Sources_ objectForKey:key] != (NSMutableDictionary *) record_)
        return;
    [Sources_ removeObjectForKey:key];
}
}

- (bool) remove {
    if (record_ == nil)
        return false;
    [self performSelectorOnMainThread:@selector(_remove) withObject:nil waitUntilDone:NO];
    return true;
}

- (NSDictionary *) record {
    return record_;
}

- (BOOL) trusted {
    return trusted_;
}

- (NSString *) rooturi {
    return uri_;
}

- (NSString *) distribution {
    return distribution_;
}

- (NSString *) type {
    return type_;
}

- (NSString *) baseuri {
    return base_.empty() ? nil : (id) base_;
}

- (NSString *) iconuri {
    if (NSString *base = [self baseuri])
        return [base stringByAppendingString:@"CydiaIcon.png"];

    return nil;
}

- (NSURL *) iconURL {
    if (NSString *uri = [self iconuri])
        return [NSURL URLWithString:uri];
    return nil;
}

- (NSString *) key {
    return [NSString stringWithFormat:@"%@:%@:%@", (NSString *) type_, (NSString *) uri_, (NSString *) distribution_];
}

- (NSString *) host {
    return host_;
}

- (NSString *) name {
    // Not every modern rootless repository publishes an Origin
    // field.  Sileo still shows the repository's human-readable Release
    // Label in that case, while original Cydia fell back immediately to the
    // URL authority (for example ellekit.space or tigisoftware.com).  Keep
    // Origin as the first choice for original-Cydia compatibility, then use
    // Label, and only use the host/path when neither metadata field exists.
    if (!origin_.empty())
        return origin_;
    if (!label_.empty())
        return label_;
    NSString *remembered(CYRememberedSourceDisplayName([self key]));
    if ([remembered length] != 0)
        return remembered;
    return authority_;
}

- (NSString *) shortDescription {
    return description_;
}

- (NSString *) label {
    return label_.empty() ? (id) authority_ : label_;
}

- (NSString *) origin {
    return origin_;
}

- (NSString *) version {
    return version_;
}

- (NSString *) defaultIcon {
    return defaultIcon_;
}

- (void) setDelegate:(NSObject<SourceDelegate> *)delegate {
    delegate_ = delegate;
}

- (bool) fetch {
    return !fetches_.empty();
}

- (void) setFetch:(bool)fetch forURI:(const char *)uri {
    if (!fetch) {
        if (fetches_.erase(uri) == 0)
            return;
    } else if (files_.find(uri) == files_.end())
        return;
    else if (!fetches_.insert(uri).second)
        return;

    [delegate_ performSelectorOnMainThread:@selector(setSourceFetch:)
        withObject:@[self, @([self fetch])] waitUntilDone:NO];
}

- (void) resetFetch {
    fetches_.clear();
    [delegate_ performSelectorOnMainThread:@selector(setSourceFetch:)
        withObject:@[self, @NO] waitUntilDone:NO];
}

@end
/* }}} */
/* CydiaOperation Class {{{ */
@interface CydiaOperation : NSObject {
    _H<NSString> operator_;
    _H<NSString> value_;
}

- (NSString *) operator;
- (NSString *) value;

@end

@implementation CydiaOperation

- (id) initWithOperator:(const char *)_operator value:(const char *)value {
    if ((self = [super init]) != nil) {
        operator_ = [NSString stringWithUTF8String:_operator];
        value_ = [NSString stringWithUTF8String:value];
    } return self;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"operator",
        @"value",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (NSString *) operator {
    return operator_;
}

- (NSString *) value {
    return value_;
}

@end
/* }}} */
/* CydiaClause Class {{{ */
@interface CydiaClause : NSObject {
    _H<NSString> package_;
    _H<CydiaOperation> version_;
}

- (NSString *) package;
- (CydiaOperation *) version;

@end

@implementation CydiaClause

- (id) initWithIterator:(pkgCache::DepIterator &)dep {
    if ((self = [super init]) != nil) {
        package_ = [NSString stringWithUTF8String:dep.TargetPkg().Name()];

        if (const char *version = dep.TargetVer())
            version_ = [[[CydiaOperation alloc] initWithOperator:dep.CompType() value:version] autorelease];
        else
            version_ = (id) [NSNull null];
    } return self;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"package",
        @"version",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (NSString *) package {
    return package_;
}

- (CydiaOperation *) version {
    return version_;
}

@end
/* }}} */
/* CydiaRelation Class {{{ */
@interface CydiaRelation : NSObject {
    _H<NSString> relationship_;
    _H<NSMutableArray> clauses_;
}

- (NSString *) relationship;
- (NSArray *) clauses;

@end

@implementation CydiaRelation

- (id) initWithIterator:(pkgCache::DepIterator &)dep {
    if ((self = [super init]) != nil) {
        relationship_ = [NSString stringWithUTF8String:dep.DepType()];
        clauses_ = [NSMutableArray arrayWithCapacity:8];

        pkgCache::DepIterator start;
        pkgCache::DepIterator end;
        dep.GlobOr(start, end); // ++dep

        _forever {
            [clauses_ addObject:[[[CydiaClause alloc] initWithIterator:start] autorelease]];

            // yes, seriously. (wtf?)
            if (start == end)
                break;
            ++start;
        }
    } return self;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"clauses",
        @"relationship",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (NSString *) relationship {
    return relationship_;
}

- (NSArray *) clauses {
    return clauses_;
}

- (void) addClause:(CydiaClause *)clause {
    [clauses_ addObject:clause];
}

@end
/* }}} */
/* Package Class {{{ */
struct ParsedPackage {
    CYString md5sum_;
    CYString tagline_;

    CYString architecture_;
    CYString icon_;

    CYString depiction_;
    CYString homepage_;
    CYString author_;

    CYString support_;
};

@interface Package : NSObject {
    uint32_t era_ : 25;
    @public uint32_t role_ : 3;
    uint32_t essential_ : 1;
    uint32_t obsolete_ : 1;
    uint32_t ignored_ : 1;
    uint32_t pooled_ : 1;

    CYPool *pool_;

    uint32_t rank_;

    _transient Database *database_;

    pkgCache::VerIterator version_;
    pkgCache::PkgIterator iterator_;
    pkgCache::VerFileIterator file_;

    CYString id_;
    CYString name_;
    CYString transform_;

    CYString latest_;
    CYString installed_;
    time_t upgraded_;

    const char *section_;
    _transient NSString *section$_;

    _H<Source> source_;

    PackageValue *metadata_;
    ParsedPackage *parsed_;

    _H<NSMutableArray> tags_;
}

- (Package *) initWithVersion:(pkgCache::VerIterator)version withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database recordChanges:(BOOL)recordChanges;
+ (Package *) newPackageWithIterator:(pkgCache::PkgIterator)iterator withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database;

+ (Package *) packageWithIterator:(pkgCache::PkgIterator)iterator withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database;

- (pkgCache::PkgIterator) iterator;
- (void) parse;

- (NSString *) section;
- (NSString *) simpleSection;

- (NSString *) longSection;
- (NSString *) shortSection;

- (NSString *) uri;

- (MIMEAddress *) maintainer;
- (size_t) size;
- (NSString *) longDescription;
- (NSString *) shortDescription;
- (unichar) index;

- (PackageValue *) metadata;
- (time_t) seen;

- (bool) subscribed;
- (bool) setSubscribed:(bool)subscribed;

- (BOOL) ignored;

- (NSString *) latest;
- (NSString *) installed;
- (BOOL) uninstalled;
- (BOOL) automaticallyInstalled;

- (BOOL) upgradableAndEssential:(BOOL)essential;
- (BOOL) essential;
- (BOOL) broken;
- (BOOL) unfiltered;
- (BOOL) visible;

- (BOOL) half;
- (BOOL) halfConfigured;
- (BOOL) halfInstalled;
- (BOOL) hasMode;
- (NSString *) mode;

- (NSString *) id;
- (NSString *) name;
- (UIImage *) icon;
- (NSURL *) remoteIconURL;
- (NSString *) homepage;
- (NSString *) depiction;
- (MIMEAddress *) author;

- (NSString *) support;

- (NSArray *) files;
- (NSArray *) warnings;
- (NSArray *) applications;
- (BOOL) availableFromSource:(Source *)source;

- (Source *) source;

- (uint32_t) rank;
- (BOOL) matches:(NSArray *)query;

- (BOOL) hasTag:(NSString *)tag;
- (NSString *) primaryPurpose;
- (NSArray *) purposes;
- (bool) isCommercial;

- (void) setIndex:(size_t)index;

- (CYString &) cyname;

- (uint32_t) compareBySection:(NSArray *)sections;

- (void) install;
- (void) remove;

@end

uint32_t PackageChangesRadix(Package *self, void *) {
    union {
        uint32_t key;

        struct {
            uint32_t timestamp : 30;
            uint32_t ignored : 1;
            uint32_t upgradable : 1;
        } bits;
    } value;

    bool upgradable([self upgradableAndEssential:YES]);

    if (upgradable) {
        value.bits.timestamp = 0;
        value.bits.ignored = [self ignored] ? 0 : 1;
        value.bits.upgradable = 1;
    } else {
        value.bits.timestamp = [self seen] >> 2;
        value.bits.ignored = 0;
        value.bits.upgradable = 0;
    }

    return _not(uint32_t) - value.key;
}

CYString &(*PackageName)(Package *self, SEL sel);

uint32_t PackagePrefixRadix(Package *self, void *context) {
    size_t offset(reinterpret_cast<size_t>(context));
    CYString &name(PackageName(self, @selector(cyname)));

    size_t size(name.size());
    if (size == 0)
        return 0;
    char *text(name.data());

    size_t zeros;
    if (!isdigit(text[0]))
        zeros = 0;
    else {
        size_t digits(1);
        while (size != digits && isdigit(text[digits]))
            if (++digits == 4)
                break;
        zeros = 4 - digits;
    }

    uint8_t data[4];

    if (offset == 0 && zeros != 0) {
        memset(data, '0', zeros);
        memcpy(data + zeros, text, 4 - zeros);
    } else {
        /* XXX: there's some danger here if you request a non-zero offset < 4 and it gets zero padded */
        if (size <= offset - zeros)
            return 0;

        text += offset - zeros;
        size -= offset - zeros;

        if (size >= 4)
            memcpy(data, text, 4);
        else {
            memcpy(data, text, size);
            memset(data + size, 0, 4 - size);
        }

        for (size_t i(0); i != 4; ++i)
            if (isalpha(data[i]))
                data[i] |= 0x20;
    }

    if (offset == 0) {
        if (data[0] == '@')
            data[0] = 0x7f;
        else
            data[0] = (data[0] & 0x1f) | "\x80\x00\xc0\x40"[data[0] >> 6];
    }

    /* XXX: ntohl may be more honest */
    return OSSwapInt32(*reinterpret_cast<uint32_t *>(data));
}

CFComparisonResult StringNameCompare(CFStringRef lhn, CFStringRef rhn, size_t length) {
    _profile(PackageNameCompare)
        if (lhn == NULL)
            return rhn == NULL ? kCFCompareEqualTo : kCFCompareLessThan;
        else if (rhn == NULL)
            return kCFCompareGreaterThan;

        CFIndex length(CFStringGetLength(lhn));

        _profile(PackageNameCompare$NumbersLast)
            if (length != 0 && CFStringGetLength(rhn) != 0) {
                UniChar lhc(CFStringGetCharacterAtIndex(lhn, 0));
                UniChar rhc(CFStringGetCharacterAtIndex(rhn, 0));
                bool lha(CYCharacterIsLetter(lhc));
                if (lha != CYCharacterIsLetter(rhc))
                    return lha ? kCFCompareLessThan : kCFCompareGreaterThan;
            }
        _end

        _profile(PackageNameCompare$Compare)
            return CFStringCompareWithOptionsAndLocale(lhn, rhn, CFRangeMake(0, length), LaxCompareFlags_, (CFLocaleRef) (id) CollationLocale_);
        _end
    _end
}

_finline CFComparisonResult StringNameCompare(NSString *lhn, NSString*rhn, size_t length) {
    return StringNameCompare((CFStringRef) lhn, (CFStringRef) rhn, length);
}

CFComparisonResult PackageNameCompare(Package *lhs, Package *rhs, void *arg) {
    CYString &lhn(PackageName(lhs, @selector(cyname)));
    NSString *rhn(PackageName(rhs, @selector(cyname)));
    return StringNameCompare(lhn, rhn, lhn.size());
}

CFComparisonResult PackageNameCompare_(Package **lhs, Package **rhs, void *arg) {
    return PackageNameCompare(*lhs, *rhs, arg);
}

struct PackageNameOrdering :
    std::binary_function<Package *, Package *, bool>
{
    _finline bool operator ()(Package *lhs, Package *rhs) const {
        return PackageNameCompare(lhs, rhs, NULL) == kCFCompareLessThan;
    }
};

static inline bool CYRootlessPackageArchitecture(const char *architecture) {
    if (architecture == NULL)
        return false;
    return strcmp(architecture, "iphoneos-arm64") == 0 ||
           strcmp(architecture, "all") == 0;
}

// Rootless iOS 15+ safety policy: some historical bootstrap
// transition packages are Architecture: all even though their maintainer
// scripts explicitly write to the sealed root filesystem.  Architecture
// filtering therefore cannot identify them.  firmware-sbin is the known
// Telesphoreo/rootful transition package whose preinst writes to /sbin; it
// must never be selected for install/upgrade on a /var/jb rootless system.
// If it is already installed, keep the current version visible so the user
// can remove it, but never expose a repository candidate for installation.
static inline bool CYRootlessBlockedLegacyPackage(const char *name) {
    return name != NULL && strcmp(name, "firmware-sbin") == 0;
}

// Validate only plain Debian Packages indexes in Cydia's private list cache.
// A valid non-empty Packages file is a sequence of RFC822 paragraphs and each
// paragraph must contain a Package: field.  Broken repositories occasionally
// return HTML/custom text under a Packages URL; old APT then poisons the whole
// MergeList.  Quarantine only Cydia's disposable cached copy.  Source files
// under /var/jb/etc/apt are deliberately untouched so Sileo/bootstrap state
// is preserved.
static bool CYValidPackagesIndex(const char *path) {
    std::ifstream file(path);
    if (!file.is_open())
        return true;

    bool paragraph = false;
    bool package = false;
    std::string line;

    while (std::getline(file, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n'))
            line.pop_back();

        bool blank = true;
        for (std::string::const_iterator character = line.begin(); character != line.end(); ++character)
            if (*character != ' ' && *character != '\t') {
                blank = false;
                break;
            }

        if (blank) {
            if (paragraph && !package)
                return false;
            paragraph = false;
            package = false;
            continue;
        }

        paragraph = true;
        if (line.compare(0, 8, "Package:") == 0)
            package = true;
    }

    return !paragraph || package;
}

static size_t CYQuarantineMalformedPackageLists() {
    NSString *directory = Cache("lists");
    const char *base = [directory UTF8String];
    DIR *lists = opendir(base);
    if (lists == NULL)
        return 0;

    size_t quarantined = 0;
    while (dirent *entry = readdir(lists)) {
        const char *name = entry->d_name;
        if (name[0] == '.')
            continue;

        size_t length = strlen(name);
        static const char suffix[] = "_Packages";
        static const size_t suffixLength = sizeof(suffix) - 1;
        if (length < suffixLength || strcmp(name + length - suffixLength, suffix) != 0)
            continue;

        char path[PATH_MAX];
        if (snprintf(path, sizeof(path), "%s/%s", base, name) >= (int) sizeof(path))
            continue;

        struct stat info;
        if (stat(path, &info) == -1 || (info.st_mode & S_IFMT) != S_IFREG)
            continue;
        if (CYValidPackagesIndex(path))
            continue;

        char quarantine[PATH_MAX];
        if (snprintf(quarantine, sizeof(quarantine), "%s.cydia-invalid", path) >= (int) sizeof(quarantine))
            continue;

        unlink(quarantine);
        if (rename(path, quarantine) == -1) {
            lprintf("E:[rootless list safety: cannot quarantine malformed index %s: %s]\n", path, strerror(errno));
            continue;
        }

        ++quarantined;
        lprintf("W:[rootless list safety: quarantined malformed Packages index %s]\n", name);
    }
    closedir(lists);

    if (quarantined != 0) {
        unlink([Cache("pkgcache.bin") UTF8String]);
        unlink([Cache("srcpkgcache.bin") UTF8String]);
    }

    return quarantined;
}

// Choose one policy-respecting rootless candidate per package ID.
// Historical Cydia was written before repositories commonly carried
// rootful and rootless variants side-by-side. Prefer the highest-priority
// iphoneos-arm64/all version, then the newest version at equal priority.
//
// PreferenceLoader is a shared UI framework rather than a bootstrap-owned
// system component. Multiple rootless repositories publish it and bootstrap
// pinning can otherwise keep Cydia on an older compatible build even when a
// newer iphoneos-arm64/all version is available. Match modern package-manager
// behavior for this package only: choose its newest compatible positive-pin
// version, using APT priority only to break an equal-version tie. Do not relax
// candidate policy globally for core bootstrap packages.
// Never turn an ordinary lower repository version into an "upgrade" over
// a newer installed version unless APT policy explicitly pins it above 1000.
static pkgCache::VerIterator CYRootlessCandidateVersion(pkgCacheFile &cache, pkgCache::PkgIterator package) {
    pkgCache::VerIterator current(package.CurrentVer());

    if (CYRootlessBlockedLegacyPackage(package.Name()))
        return current;

    pkgCache::VerIterator best;
    signed bestPriority = -1;
    bool newestCompatible(CYRootlessCandidatePolicy::UsesNewestCompatiblePolicy(package.Name()));

    for (pkgCache::VerIterator version(package.VersionList()); !version.end(); ++version) {
        if (!CYRootlessPackageArchitecture(version.Arch()))
            continue;

        signed priority(cache.Policy->GetPriority(version, true));
        if (priority <= 0)
            continue;

        int comparison(best.end() ? 1 : version.CompareVer(best));
        bool better(CYRootlessCandidatePolicy::IsBetter(newestCompatible,
            !best.end(), comparison, priority, bestPriority));
        if (better) {
            best = version;
            bestPriority = priority;
        }
    }

    if (best.end())
        // Keep an already-installed non-rootless package visible for removal,
        // but do not expose repository-only rootful variants.
        return current;

    if (!current.end() && CYRootlessPackageArchitecture(current.Arch()) &&
        best.CompareVer(current) < 0 && bestPriority <= 1000)
        return current;

    if (newestCompatible) {
        pkgCache::VerIterator policyCandidate(cache.Policy->GetCandidateVer(package));
        CYRootlessDiag(@"CANDIDATE", @"package=preferenceloader strategy=newest-compatible selectedVersion=%s selectedArchitecture=%s selectedPriority=%d policyVersion=%s pinningScope=package-only",
            best.VerStr(), best.Arch(), bestPriority,
            policyCandidate.end() ? "<none>" : policyCandidate.VerStr());
    }

    return best;
}

static UIImage *CYModernPackageFallbackIcon(NSString *section, NSString *identifier) {
    (void) identifier;
    return CYSectionIconImage(section) ?: CYNoSectionIcon();
}

@implementation Package

- (NSString *) description {
    return [NSString stringWithFormat:@"<Package:%@>", static_cast<NSString *>(name_)];
}

- (void) dealloc {
    if (!pooled_)
        delete pool_;
    if (parsed_ != NULL)
        delete parsed_;
    [super dealloc];
}

+ (NSString *) webScriptNameForSelector:(SEL)selector {
    if (false);
    else if (selector == @selector(clear))
        return @"clear";
    else if (selector == @selector(getField:))
        return @"getField";
    else if (selector == @selector(getRecord))
        return @"getRecord";
    else if (selector == @selector(hasTag:))
        return @"hasTag";
    else if (selector == @selector(install))
        return @"install";
    else if (selector == @selector(remove))
        return @"remove";
    else
        return nil;
}

+ (BOOL) isSelectorExcludedFromWebScript:(SEL)selector {
    return [self webScriptNameForSelector:selector] == nil;
}

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"applications",
        @"architecture",
        @"author",
        @"depiction",
        @"essential",
        @"homepage",
        @"icon",
        @"id",
        @"installed",
        @"latest",
        @"longDescription",
        @"longSection",
        @"maintainer",
        @"md5sum",
        @"mode",
        @"name",
        @"purposes",
        @"relations",
        @"section",
        @"selection",
        @"shortDescription",
        @"shortSection",
        @"simpleSection",
        @"size",
        @"source",
        @"state",
        @"support",
        @"tags",
        @"upgraded",
        @"warnings",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (NSArray *) relations {
@synchronized (database_) {
    NSMutableArray *relations([NSMutableArray arrayWithCapacity:16]);
    for (pkgCache::DepIterator dep(version_.DependsList()); !dep.end(); ++dep)
        [relations addObject:[[[CydiaRelation alloc] initWithIterator:dep] autorelease]];
    return relations;
} }

- (NSString *) architecture {
    [self parse];
@synchronized (database_) {
    return parsed_->architecture_.empty() ? [NSNull null] : (id) parsed_->architecture_;
} }

- (NSString *) getField:(NSString *)name {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return nil;

    pkgRecords::Parser &parser([database_ records]->Lookup(file_));

    const char *start, *end;
    if (!parser.Find([name UTF8String], start, end))
        return (NSString *) [NSNull null];

    return [NSString stringWithString:[(NSString *) CYStringCreate(start, end - start) autorelease]];
} }

- (NSString *) getRecord {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return nil;

    pkgRecords::Parser &parser([database_ records]->Lookup(file_));

    const char *start, *end;
    parser.GetRec(start, end);

    return [NSString stringWithString:[(NSString *) CYStringCreate(start, end - start) autorelease]];
} }

- (void) parse {
    if (parsed_ != NULL)
        return;
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return;

    ParsedPackage *parsed(new ParsedPackage);
    parsed_ = parsed;

    _profile(Package$parse)
        pkgRecords::Parser *parser;

        _profile(Package$parse$Lookup)
            parser = &[database_ records]->Lookup(file_);
        _end

        CYString bugs;
        CYString website;

        _profile(Package$parse$Find)
            struct {
                const char *name_;
                CYString *value_;
            } names[] = {
                {"architecture", &parsed->architecture_},
                {"icon", &parsed->icon_},
                {"depiction", &parsed->depiction_},
                {"homepage", &parsed->homepage_},
                {"website", &website},
                {"bugs", &bugs},
                {"support", &parsed->support_},
                {"author", &parsed->author_},
                {"md5sum", &parsed->md5sum_},
            };

            for (size_t i(0); i != sizeof(names) / sizeof(names[0]); ++i) {
                const char *start, *end;

                if (parser->Find(names[i].name_, start, end)) {
                    CYString &value(*names[i].value_);
                    _profile(Package$parse$Value)
                        value.set(pool_, start, end - start);
                    _end
                }
            }
        _end

        _profile(Package$parse$Tagline)
            parsed->tagline_.set(pool_, parser->ShortDesc());
        _end

        _profile(Package$parse$Retain)
            if (parsed->homepage_.empty())
                parsed->homepage_ = website;
            if (parsed->homepage_ == parsed->depiction_)
                parsed->homepage_.clear();
            if (parsed->support_.empty())
                parsed->support_ = bugs;
        _end
    _end
} }

- (Package *) initWithVersion:(pkgCache::VerIterator)version withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database recordChanges:(BOOL)recordChanges {
    if ((self = [super init]) != nil) {
    _profile(Package$initWithVersion)
        if (pool == NULL)
            pool_ = new CYPool();
        else {
            pool_ = pool;
            pooled_ = true;
        }

        database_ = database;
        era_ = [database era];

        version_ = version;

        pkgCache::PkgIterator iterator(version_.ParentPkg());
        iterator_ = iterator;

        _profile(Package$initWithVersion$Version)
            file_ = version_.FileList();
        _end

        _profile(Package$initWithVersion$Cache)
            name_.set(NULL, version_.Display());

            latest_.set(NULL, StripVersion_(version_.VerStr()));

            pkgCache::VerIterator current(iterator.CurrentVer());
            if (!current.end())
                installed_.set(NULL, StripVersion_(current.VerStr()));
        _end

        _profile(Package$initWithVersion$Transliterate) do {
            if (CollationTransl_ == NULL)
                break;
            if (name_.empty())
                break;

            _profile(Package$initWithVersion$Transliterate$utf8)
            const uint8_t *data(reinterpret_cast<const uint8_t *>(name_.data()));
            for (size_t i(0), e(name_.size()); i != e; ++i)
                if (data[i] >= 0x80)
                    goto extended;
            break; extended:;
            _end

            UErrorCode code(U_ZERO_ERROR);
            int32_t length;

            _profile(Package$initWithVersion$Transliterate$u_strFromUTF8WithSub)
            CollationString_.resize(name_.size());
            u_strFromUTF8WithSub(&CollationString_[0], CollationString_.size(), &length, name_.data(), name_.size(), 0xfffd, NULL, &code);
            if (!U_SUCCESS(code))
                break;
            CollationString_.resize(length);
            _end

            _profile(Package$initWithVersion$Transliterate$utrans_trans)
            length = CollationString_.size();
            utrans_trans(CollationTransl_, reinterpret_cast<UReplaceable *>(&CollationString_), &CollationUCalls_, 0, &length, &code);
            if (!U_SUCCESS(code))
                break;
            _assert(CollationString_.size() == length);
            _end

            _profile(Package$initWithVersion$Transliterate$u_strToUTF8WithSub$preflight)
            u_strToUTF8WithSub(NULL, 0, &length, CollationString_.data(), CollationString_.size(), 0xfffd, NULL, &code);
            if (code == U_BUFFER_OVERFLOW_ERROR)
                code = U_ZERO_ERROR;
            else if (!U_SUCCESS(code))
                break;
            _end

            char *transform;
            _profile(Package$initWithVersion$Transliterate$apr_palloc)
            transform = pool_->malloc<char>(length);
            _end
            _profile(Package$initWithVersion$Transliterate$u_strToUTF8WithSub$transform)
            u_strToUTF8WithSub(transform, length, NULL, CollationString_.data(), CollationString_.size(), 0xfffd, NULL, &code);
            if (!U_SUCCESS(code))
                break;
            _end

            transform_.set(NULL, transform, length);
        } while (false); _end

        _profile(Package$initWithVersion$Tags)
#ifndef __arm__
            pkgCache::TagIterator tag(version_.TagList());
#else
            pkgCache::TagIterator tag(iterator.TagList());
#endif
            if (!tag.end()) {
                tags_ = [NSMutableArray arrayWithCapacity:8];

                goto tag; for (; !tag.end(); ++tag) tag: {
                    const char *name(tag.Name());
                    NSString *string((NSString *) CYStringCreate(name));
                    if (string == nil)
                        continue;

                    [tags_ addObject:[string autorelease]];

                    if (role_ == 0 && strncmp(name, "role::", 6) == 0 /*&& strcmp(name, "role::leaper") != 0*/) {
                        if (strcmp(name + 6, "enduser") == 0 || strcmp(name + 6, "user") == 0)
                            role_ = 1;
                        else if (strcmp(name + 6, "hacker") == 0)
                            role_ = 2;
                        else if (strcmp(name + 6, "developer") == 0)
                            role_ = 3;
                        else if (strcmp(name + 6, "cydia") == 0)
                            role_ = 7;
                        else
                            role_ = 4;
                    }

                    if (strncmp(name, "cydia::", 7) == 0) {
                        if (strcmp(name + 7, "essential") == 0)
                            essential_ = true;
                        else if (strcmp(name + 7, "obsolete") == 0)
                            obsolete_ = true;
                    }
                }
            }
        _end

        _profile(Package$initWithVersion$Metadata)
            const char *mixed(iterator.Name());
            size_t size(strlen(mixed));
            static const size_t prefix(sizeof("/var/jb/var/lib/dpkg/info/") - 1);
            std::vector<char> lower(prefix + size + 5 + 1, '\0');

            for (size_t i(0); i != size; ++i)
                lower[prefix + i] = mixed[i] | 0x20;

            if (!installed_.empty()) {
                memcpy(lower.data(), "/var/jb/var/lib/dpkg/info/", prefix);
                memcpy(lower.data() + prefix + size, ".list", 6);
                struct stat info;
                if (stat(lower.data(), &info) != -1)
                    upgraded_ = info.st_mtime > 0 ? info.st_mtime : info.st_birthtime;
            }

            PackageValue *metadata(PackageFind(lower.data() + prefix, size));
            metadata_ = metadata;

            id_.set(NULL, metadata->name_, size);

            // Inspecting an older version must not turn it into a new item
            // in Changes or overwrite the recorded current version.
            if (recordChanges) {
            const char *latest(version_.VerStr());
            size_t length(strlen(latest));

            uint16_t vhash(hashlittle(latest, length));

            size_t capped(std::min<size_t>(8, length));
            latest = latest + length - capped;

            if (metadata->first_ == 0)
                metadata->first_ = now_;

            if (metadata->vhash_ != vhash || strncmp(metadata->version_, latest, sizeof(metadata->version_)) != 0) {
                strncpy(metadata->version_, latest, sizeof(metadata->version_));
                metadata->vhash_ = vhash;
                metadata->last_ = now_;
            } else if (metadata->last_ == 0)
                metadata->last_ = metadata->first_;
            }
        _end

        _profile(Package$initWithVersion$Section)
            section_ = version_.Section();
        _end

        _profile(Package$initWithVersion$Flags)
            ignored_ = iterator->SelectedState == pkgCache::State::Hold;
        _end

#ifndef __arm__
        _profile(Package$initWithVersion$Priority)
            // ignore "essential" tags from non-pinned repos
            if (essential_ && [database cache].Policy->GetPriority(version, true) == 500) {
                essential_ = NO;
            }
        _end
#endif
        // Repository priority may suppress a cydia::essential tag, but must
        // never erase Debian's Essential flag used by upgrade/removal safety.
        essential_ |= (iterator->Flags & pkgCache::Flag::Essential) != 0;

    _end } return self;
}

+ (Package *) newPackageWithIterator:(pkgCache::PkgIterator)iterator withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database {
    pkgCache::VerIterator version;

    _profile(Package$packageWithIterator$GetCandidateVer)
        pkgCacheFile &cache([database cache]);
        version = CYRootlessCandidateVersion(cache, iterator);
        if (!version.end()) {
            pkgCache::VerIterator selected(cache->GetCandidateVersion(iterator));
            if (selected.end() || selected != version)
                cache->SetCandidateVersion(version);
        }
    _end

    if (version.end())
        return nil;

    pkgCache::VerIterator current(iterator.CurrentVer());
    if (CYRootlessBlockedLegacyPackage(iterator.Name()) && current.end())
        return nil;

    // Never expose a repository-only rootful package variant in this public
    // rootless Cydia build. Repositories such as ElleKit intentionally ship
    // iphoneos-arm and iphoneos-arm64 variants side-by-side; without this
    // guard historical Cydia can show duplicate rows for one package ID.
    if (!CYRootlessPackageArchitecture(version.Arch()) && current.end())
        return nil;

    Package *package;

    _profile(Package$packageWithIterator$Allocate)
        package = [Package allocWithZone:zone];
    _end

    _profile(Package$packageWithIterator$Initialize)
        package = [package
            initWithVersion:version
            withZone:zone
            inPool:pool
            database:database
            recordChanges:YES
        ];
    _end

    return package;
}

// XXX: just in case a Cydia extension is using this (I bet this is unlikely, though, due to CYPool?)
+ (Package *) packageWithIterator:(pkgCache::PkgIterator)iterator withZone:(NSZone *)zone inPool:(CYPool *)pool database:(Database *)database {
    return [[self newPackageWithIterator:iterator withZone:zone inPool:pool database:database] autorelease];
}

- (pkgCache::PkgIterator) iterator {
    return iterator_;
}

- (NSArray *) downgrades {
    NSMutableArray *versions([NSMutableArray arrayWithCapacity:4]);

    for (auto version(iterator_.VersionList()); !version.end(); ++version) {
        if (version == version_)
            continue;
        if (!CYRootlessPackageArchitecture(version.Arch()))
            continue;
        Package *package([[[Package allocWithZone:NULL] initWithVersion:version withZone:NULL inPool:NULL database:database_ recordChanges:NO] autorelease]);
        if ([package source] == nil)
            continue;
        [versions addObject:package];
    }

    return versions;
}

- (NSString *) section {
    if (section$_ == nil) {
        if (section_ == NULL)
            return nil;

        _profile(Package$section$mappedSectionForPointer)
            section$_ = [database_ mappedSectionForPointer:section_];
        _end
    } return section$_;
}

- (NSString *) simpleSection {
    if (NSString *section = [self section])
        return Simplify(section);
    else
        return nil;
}

- (NSString *) longSection {
    if (NSString *section = [self section])
        return LocalizeSection(section);
    else
        return nil;
}

- (NSString *) shortSection {
    return [[NSBundle mainBundle] localizedStringForKey:[self simpleSection] value:nil table:@"Sections"];
}

- (NSString *) uri {
    return nil;
#if 0
    pkgIndexFile *index;
    pkgCache::PkgFileIterator file(file_.File());
    if (![database_ list].FindIndex(file, index))
        return nil;
    return [NSString stringWithUTF8String:iterator_->Path];
    //return [NSString stringWithUTF8String:file.Site()];
    //return [NSString stringWithUTF8String:index->ArchiveURI(file.FileName()).c_str()];
#endif
}

- (MIMEAddress *) maintainer {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return nil;

    pkgRecords::Parser *parser = &[database_ records]->Lookup(file_);
    const std::string &maintainer(parser->Maintainer());
    return maintainer.empty() ? nil : [MIMEAddress addressWithString:[NSString stringWithUTF8String:maintainer.c_str()]];
} }

- (NSString *) md5sum {
    return parsed_ == NULL ? nil : (id) parsed_->md5sum_;
}

- (size_t) size {
@synchronized (database_) {
    if ([database_ era] != era_ || version_.end())
        return 0;

    return version_->InstalledSize;
} }

- (NSString *) longDescription {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return nil;

    pkgRecords::Parser *parser = &[database_ records]->Lookup(file_);
    NSString *description([NSString stringWithUTF8String:parser->LongDesc().c_str()]);

    NSArray *lines = [description componentsSeparatedByString:@"\n"];
    NSMutableArray *trimmed = [NSMutableArray arrayWithCapacity:([lines count] - 1)];
    if ([lines count] < 2)
        return nil;

    NSCharacterSet *whitespace = [NSCharacterSet whitespaceCharacterSet];
    for (size_t i(1), e([lines count]); i != e; ++i) {
        NSString *trim = [[lines objectAtIndex:i] stringByTrimmingCharactersInSet:whitespace];
        [trimmed addObject:trim];
    }

    return [trimmed componentsJoinedByString:@"\n"];
} }

- (NSString *) shortDescription {
    if (parsed_ != NULL)
        return static_cast<NSString *>(parsed_->tagline_);

@synchronized (database_) {
    pkgRecords::Parser &parser([database_ records]->Lookup(file_));
    std::string value(parser.ShortDesc());
    if (value.empty())
        return nil;
    if (value.size() > 200)
        value.resize(200);
    return [(id) CYStringCreate(value) autorelease];
} }

- (unichar) index {
    _profile(Package$index)
        CFStringRef name((CFStringRef) [self name]);
        if (CFStringGetLength(name) == 0)
            return '#';
        UniChar character(CFStringGetCharacterAtIndex(name, 0));
        if (!CYCharacterIsLetter(character))
            return '#';
        return toupper(character);
    _end
}

- (PackageValue *) metadata {
    return metadata_;
}

- (time_t) seen {
    PackageValue *metadata([self metadata]);
    // Sileo's News database stores one record per package version, so a newly
    // published version appears even when the user never subscribed to that
    // package. Cydia historically returned first_ for unsubscribed packages,
    // which permanently anchored them to the day their repository was added.
    // last_ advances only when the selected version changes and is therefore
    // the matching, stable signal for both a new package and a new version.
    return metadata->last_ != 0 ? metadata->last_ : metadata->first_;
}

- (bool) subscribed {
    return [self metadata]->subscribed_;
}

- (bool) setSubscribed:(bool)subscribed {
    PackageValue *metadata([self metadata]);
    if (metadata->subscribed_ == subscribed)
        return false;
    metadata->subscribed_ = subscribed;
    return true;
}

- (BOOL) ignored {
    return ignored_;
}

- (NSString *) latest {
    return latest_;
}

- (NSString *) installed {
    return installed_;
}

- (BOOL) uninstalled {
    return installed_.empty();
}

- (BOOL) automaticallyInstalled {
@synchronized (database_) {
    if ([database_ era] != era_ || iterator_.end())
        return NO;

    pkgDepCache::StateCache &state([database_ cache][iterator_]);
    return (state.Flags & pkgCache::Flag::Auto) != 0;
} }

- (BOOL) upgradableAndEssential:(BOOL)essential {
    _profile(Package$upgradableAndEssential)
        pkgCache::VerIterator current(iterator_.CurrentVer());
        if (current.end()) {
            if (essential && essential_) {
                return (strcmp(version_.Arch(), common_arch)==0);
            } else {
                return false;
            }
        } else {
            pkgDepCache::StateCache &state([database_ cache][iterator_]);
            return state.Upgradable() && version_.CompareVer(current) > 0;
        }
    _end
}

- (BOOL) essential {
    return essential_;
}

- (BOOL) broken {
    return [database_ cache][iterator_].InstBroken();
}

- (BOOL) unfiltered {
    _profile(Package$unfiltered$obsolete)
        if (_unlikely(obsolete_))
            return false;
    _end

    _profile(Package$unfiltered$role)
        if (_unlikely(role_ > 3))
            return false;
    _end

    return true;
}

- (BOOL) visible {
    if (![self unfiltered])
        return false;

    NSString *section;

    _profile(Package$visible$section)
        section = [self section];
    _end

    _profile(Package$visible$isSectionVisible)
        if (!isSectionVisible(section))
            return false;
    _end

    return true;
}

- (BOOL) half {
    unsigned char current(iterator_->CurrentState);
    return current == pkgCache::State::HalfConfigured || current == pkgCache::State::HalfInstalled;
}

- (BOOL) halfConfigured {
    return iterator_->CurrentState == pkgCache::State::HalfConfigured;
}

- (BOOL) halfInstalled {
    return iterator_->CurrentState == pkgCache::State::HalfInstalled;
}

- (BOOL) hasMode {
@synchronized (database_) {
    if ([database_ era] != era_ || iterator_.end())
        return NO;

    pkgDepCache::StateCache &state([database_ cache][iterator_]);
    return state.Mode != pkgDepCache::ModeKeep;
} }

- (NSString *) mode {
@synchronized (database_) {
    if ([database_ era] != era_ || iterator_.end())
        return nil;

    pkgDepCache::StateCache &state([database_ cache][iterator_]);

    switch (state.Mode) {
        case pkgDepCache::ModeDelete:
            if ((state.iFlags & pkgDepCache::Purge) != 0)
                return @"PURGE";
            else
                return @"REMOVE";
        case pkgDepCache::ModeKeep:
            if ((state.iFlags & pkgDepCache::ReInstall) != 0)
                return @"REINSTALL";
            /*else if ((state.iFlags & pkgDepCache::AutoKept) != 0)
                return nil;*/
            else
                return nil;
        case pkgDepCache::ModeInstall:
            /*if ((state.iFlags & pkgDepCache::ReInstall) != 0)
                return @"REINSTALL";
            else*/ switch (state.Status) {
                case -1:
#ifndef __arm__
                    return [database_ cache].Policy->GetCandidateVer(iterator_)==state.CandidateVerIter([database_ cache])?@"UPGRADE":@"DOWNGRADE";
#else
                    return @"DOWNGRADE";
#endif
                case 0:
                    return @"INSTALL";
                case 1:
                    return @"UPGRADE";
                case 2:
                    return @"NEW_INSTALL";
                _nodefault
            }
        _nodefault
    }
} }

- (NSString *) id {
    return id_;
}

- (NSString *) name {
    return name_.empty() ? id_ : name_;
}

- (UIImage *) icon {
    NSString *section = [self simpleSection];

    UIImage *icon(nil);
    if (parsed_ != NULL)
        if (NSString *href = parsed_->icon_)
            if ([href hasPrefix:@"file:///"])
                icon = [UIImage imageAtPath:[[href substringFromIndex:7] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    if (icon == nil && section != nil)
        icon = CYSectionIconImage(section);
    if (icon == nil) if (Source *source = [self source]) if (NSString *dicon = [source defaultIcon])
        if ([dicon hasPrefix:@"file:///"])
            icon = [UIImage imageAtPath:[[dicon substringFromIndex:7] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
    if (icon == nil)
        icon = CYModernPackageFallbackIcon(section, [self id]);
    return icon;
}

- (NSURL *) remoteIconURL {
    [self parse];
    if (parsed_ == NULL)
        return nil;
    NSString *href(parsed_->icon_);
    if (![href isKindOfClass:[NSString class]] || [href length] == 0)
        return nil;
    NSURL *url([NSURL URLWithString:href]);
    if (![[[[url scheme] lowercaseString] description] isEqualToString:@"https"] || [[url host] length] == 0)
        return nil;
    return url;
}

- (NSString *) homepage {
    return parsed_ == NULL ? nil : static_cast<NSString *>(parsed_->homepage_);
}

- (NSString *) depiction {
    return parsed_ != NULL && !parsed_->depiction_.empty() ? parsed_->depiction_ : [[self source] depictionForPackage:id_];
}

- (MIMEAddress *) author {
    return parsed_ == NULL || parsed_->author_.empty() ? nil : [MIMEAddress addressWithString:parsed_->author_];
}

- (NSString *) support {
    return parsed_ != NULL && !parsed_->support_.empty() ? parsed_->support_ : [[self source] supportForPackage:id_];
}

- (NSArray *) files {
    NSString *path = [NSString stringWithFormat:@"/var/jb/var/lib/dpkg/info/%@.list", static_cast<NSString *>(id_)];
    NSMutableArray *files = [NSMutableArray arrayWithCapacity:128];

    std::ifstream fin;
    fin.open([path UTF8String]);
    if (!fin.is_open())
        return nil;

    std::string line;
    while (std::getline(fin, line))
        [files addObject:[NSString stringWithUTF8String:line.c_str()]];

    return files;
}

- (NSString *) state {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return nil;

    switch (iterator_->CurrentState) {
        case pkgCache::State::NotInstalled:
            return @"NotInstalled";
        case pkgCache::State::UnPacked:
            return @"UnPacked";
        case pkgCache::State::HalfConfigured:
            return @"HalfConfigured";
        case pkgCache::State::HalfInstalled:
            return @"HalfInstalled";
        case pkgCache::State::ConfigFiles:
            return @"ConfigFiles";
        case pkgCache::State::Installed:
            return @"Installed";
        case pkgCache::State::TriggersAwaited:
            return @"TriggersAwaited";
        case pkgCache::State::TriggersPending:
            return @"TriggersPending";
    }

    return (NSString *) [NSNull null];
} }

- (NSString *) selection {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return nil;

    switch (iterator_->SelectedState) {
        case pkgCache::State::Unknown:
            return @"Unknown";
        case pkgCache::State::Install:
            return @"Install";
        case pkgCache::State::Hold:
            return @"Hold";
        case pkgCache::State::DeInstall:
            return @"DeInstall";
        case pkgCache::State::Purge:
            return @"Purge";
    }

    return (NSString *) [NSNull null];
} }

- (NSArray *) warnings {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return nil;

    NSMutableArray *warnings([NSMutableArray arrayWithCapacity:4]);
    const char *name(iterator_.Name());

    size_t length(strlen(name));
    if (length < 2) invalid:
        [warnings addObject:UCLocalize("ILLEGAL_PACKAGE_IDENTIFIER")];
    else for (size_t i(0); i != length; ++i)
        if (
            /* XXX: technically this is not allowed */
            (name[i] < 'A' || name[i] > 'Z') &&
            (name[i] < 'a' || name[i] > 'z') &&
            (name[i] < '0' || name[i] > '9') &&
            (i == 0 || name[i] != '+' && name[i] != '-' && name[i] != '.')
        ) goto invalid;

    if (strcmp(name, "cydia") != 0) {
        bool cydia = false;
        bool user = false;
        bool _private = false;
        bool stash = false;
        bool dbstash = false;
        bool dsstore = false;

        bool repository = [[self section] isEqualToString:@"Repositories"];

        if (NSArray *files = [self files]) {
            for (NSString *file in files) {
                if (!cydia && [file isEqualToString:@"/var/jb/Applications/Cydia.app"])
                    cydia = true;
                else if (!user && [file isEqualToString:@"/User"])
                    user = true;
                else if (!_private && [file isEqualToString:@"/private"])
                    _private = true;
                else if (!stash && [file isEqualToString:@"/var/stash"])
                    stash = true;
                else if (!dbstash && [file isEqualToString:@"/var/db/stash"])
                    dbstash = true;
                else if (!dsstore && [file hasSuffix:@"/.DS_Store"])
                    dsstore = true;
            }
        }

        /* XXX: this is not sensitive enough. only some folders are valid. */
        if (cydia && !repository)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @"Cydia.app"]];
        if (user)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @"/User"]];
        if (_private)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @"/private"]];
        if (stash)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @"/var/stash"]];
        if (dbstash)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @"/var/db/stash"]];
        if (dsstore)
            [warnings addObject:[NSString stringWithFormat:UCLocalize("FILES_INSTALLED_TO"), @".DS_Store"]];
    }

    return [warnings count] == 0 ? nil : warnings;
} }

- (NSArray *) applications {
    NSString *me([[NSBundle mainBundle] bundleIdentifier]);

    NSMutableArray *applications([NSMutableArray arrayWithCapacity:2]);

    static RegEx application_r("/var/jb/Applications/(.*)\\.app/Info.plist");
    if (NSArray *files = [self files])
        for (NSString *file in files)
            if (application_r(file)) {
                NSDictionary *info([NSDictionary dictionaryWithContentsOfFile:file]);
                if (info == nil)
                    continue;
                NSString *id([info objectForKey:@"CFBundleIdentifier"]);
                if (id == nil || [id isEqualToString:me])
                    continue;

                NSString *display([info objectForKey:@"CFBundleDisplayName"]);
                if (display == nil)
                    display = application_r[1];

                NSString *bundle([file stringByDeletingLastPathComponent]);
                NSString *icon([info objectForKey:@"CFBundleIconFile"]);
                // XXX: maybe this should check if this is really a string, not just for length
                if (icon == nil || ![icon respondsToSelector:@selector(length)] || [icon length] == 0)
                    icon = @"icon.png";
                NSURL *url([NSURL fileURLWithPath:[bundle stringByAppendingPathComponent:icon]]);

                NSMutableArray *application([NSMutableArray arrayWithCapacity:2]);
                [applications addObject:application];

                [application addObject:id];
                [application addObject:display];
                [application addObject:url];
            }

    return [applications count] == 0 ? nil : applications;
}

- (Source *) source {
    if (source_ == nil) {
        @synchronized (database_) {
            if ([database_ era] != era_ || file_.end())
                source_ = (Source *) [NSNull null];
            else
                source_ = [database_ getSource:file_.File()] ?: (Source *) [NSNull null];
        }
    }

    return source_ == (Source *) [NSNull null] ? nil : source_;
}

// A package can legitimately be present in more than one repository,
// and modern jailbreak repositories can publish rootful + rootless variants
// of the same package ID.  Historical Cydia associated the Package object
// only with the file backing its globally selected candidate version.  Source
// pages then compared [package source] to the selected Source, which can hide
// valid rootless packages from a repository whenever the global candidate is
// installed/status-backed or comes from another source.
//
// For source browsing, inspect every rootless-compatible version/file record
// and report whether this package ID is actually offered by that source.  This
// changes source-list coverage only; global candidate selection and install
// policy remain unchanged.
- (BOOL) availableFromSource:(Source *)source {
    if (source == nil)
        return YES;

@synchronized (database_) {
    if ([database_ era] != era_)
        return NO;

    if (CYRootlessBlockedLegacyPackage(iterator_.Name()))
        return NO;

    for (pkgCache::VerIterator version(iterator_.VersionList()); !version.end(); ++version) {
        if (!CYRootlessPackageArchitecture(version.Arch()))
            continue;

        for (pkgCache::VerFileIterator file(version.FileList()); !file.end(); ++file)
            if ([database_ getSource:file.File()] == source)
                return YES;
    }

    return NO;
} }

- (time_t) upgraded {
    return upgraded_;
}

- (uint32_t) recent {
    return std::numeric_limits<uint32_t>::max() - upgraded_;
}

- (uint32_t) rank {
    return rank_;
}

- (BOOL) matches:(NSArray *)query {
    if (query == nil || [query count] == 0)
        return NO;

    rank_ = 0;

    NSString *string;
    NSRange range;
    NSUInteger length;

    string = [self name];
    length = [string length];

    if (length != 0)
    for (NSString *term in query) {
        range = [string rangeOfString:term options:MatchCompareOptions_];
        if (range.location != NSNotFound)
            rank_ -= 6 * 1000000 / length;
    }

    if (rank_ == 0) {
        string = [self id];
        length = [string length];

        if (length != 0)
        for (NSString *term in query) {
            range = [string rangeOfString:term options:MatchCompareOptions_];
            if (range.location != NSNotFound)
                rank_ -= 6 * 1000000 / length;
        }
    }

    string = [self shortDescription];
    length = [string length];
    NSUInteger stop(std::min<NSUInteger>(length, 200));

    if (length != 0)
    for (NSString *term in query) {
        range = [string rangeOfString:term options:MatchCompareOptions_ range:NSMakeRange(0, stop)];
        if (range.location != NSNotFound)
            rank_ -= 2 * 100000;
    }

    return rank_ != 0;
}

- (NSArray *) tags {
    return tags_;
}

- (BOOL) hasTag:(NSString *)tag {
    return tags_ == nil ? NO : [tags_ containsObject:tag];
}

- (NSString *) primaryPurpose {
    for (NSString *tag in (NSArray *) tags_)
        if ([tag hasPrefix:@"purpose::"])
            return [tag substringFromIndex:9];
    return nil;
}

- (NSArray *) purposes {
    NSMutableArray *purposes([NSMutableArray arrayWithCapacity:2]);
    for (NSString *tag in (NSArray *) tags_)
        if ([tag hasPrefix:@"purpose::"])
            [purposes addObject:[tag substringFromIndex:9]];
    return [purposes count] == 0 ? nil : purposes;
}

- (bool) isCommercial {
    return [self hasTag:@"cydia::commercial"];
}

- (void) setIndex:(size_t)index {
    if (metadata_->index_ != index + 1)
        metadata_->index_ = index + 1;
}

- (CYString &) cyname {
    return !transform_.empty() ? transform_ : !name_.empty() ? name_ : id_;
}

- (uint32_t) compareBySection:(NSArray *)sections {
    NSString *section([self section]);
    for (size_t i(0), e([sections count]); i != e; ++i) {
        if ([section isEqualToString:[[sections objectAtIndex:i] name]])
            return i;
    }

    return _not(uint32_t);
}

- (void) clear {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return;

    pkgProblemResolver *resolver = [database_ resolver];
    resolver->Clear(iterator_);

    pkgCacheFile &cache([database_ cache]);
    cache->SetReInstall(iterator_, false);
    cache->MarkKeep(iterator_, false);
} }

- (void) install {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return;

    pkgProblemResolver *resolver = [database_ resolver];
    resolver->Clear(iterator_);
    resolver->Protect(iterator_);

    pkgCacheFile &cache([database_ cache]);
    cache->SetCandidateVersion(version_);
    cache->SetReInstall(iterator_, false);
    // Auto-install the complete dependency closure.  Passing false here made
    // the resolver add only the first visible dependency for some modern
    // packages (for example AniTime -> Comet) while omitting Comet's Orion
    // runtime dependency from both the confirmation sheet and transaction.
    cache->MarkInstall(iterator_, true);

    pkgDepCache::StateCache &state((*cache)[iterator_]);
    if (!state.Install())
        cache->SetReInstall(iterator_, true);
} }

- (void) remove {
@synchronized (database_) {
    if ([database_ era] != era_ || file_.end())
        return;

    pkgProblemResolver *resolver = [database_ resolver];
    resolver->Clear(iterator_);
    resolver->Remove(iterator_);
    resolver->Protect(iterator_);

    pkgCacheFile &cache([database_ cache]);
    cache->SetReInstall(iterator_, false);
    cache->MarkDelete(iterator_, true);
} }

@end
/* }}} */

// The classic role:: tags remain authoritative when a repository publishes
// them. Modern bootstrap repositories often omit those old tags, however, so
// treating every untagged library and command-line dependency as an end-user
// package made Installed/User identical to Installed/Expert. For untagged
// packages only, combine APT's persisted Auto-Installed bit with conservative
// expert-only Debian sections. Explicit role::user/enduser packages always
// remain visible, including user-facing apps placed in a technical section.
static BOOL CYInstalledPackageVisibleToUser(Package *package) {
    return CYInstalledUserVisible(![package uninstalled], package->role_,
        [package essential], [package automaticallyInstalled], [package section]);
}

// Match the local-package search fields used by Sileo. A single query is
// evaluated continuously while the user types and remains authoritative when
// the keyboard Search button is pressed, so submitting a query never swaps in
// a second, unexpectedly broader result set.
static BOOL CYSearchFieldContainsQuery(NSString *field, NSString *query) {
    return [field length] != 0 && [query length] != 0 &&
        [field localizedStandardContainsString:query];
}

static BOOL CYPackageMatchesSileoSearch(Package *package, NSString *query) {
    if ([query length] == 0)
        return NO;

    MIMEAddress *author([package author]);
    MIMEAddress *maintainer([package maintainer]);
    return CYSearchFieldContainsQuery([package id], query) ||
        CYSearchFieldContainsQuery([package name], query) ||
        CYSearchFieldContainsQuery([author name], query) ||
        CYSearchFieldContainsQuery([maintainer name], query);
}

static BOOL CYSearchNameHasPrefix(NSString *name, NSString *query) {
    return [query length] != 0 && [name length] >= [query length] &&
        [name compare:query options:MatchCompareOptions_
            range:NSMakeRange(0, [query length])] == NSOrderedSame;
}

static NSInteger CYSearchPackageCompare(id left, id right, void *context) {
    Package *lhs((Package *) left);
    Package *rhs((Package *) right);
    NSString *query((NSString *) context);
    NSString *lhsName([lhs name] ?: [lhs id] ?: @"");
    NSString *rhsName([rhs name] ?: [rhs id] ?: @"");

    BOOL lhsPrefix(CYSearchNameHasPrefix(lhsName, query));
    BOOL rhsPrefix(CYSearchNameHasPrefix(rhsName, query));
    if (lhsPrefix != rhsPrefix)
        return lhsPrefix ? NSOrderedAscending : NSOrderedDescending;

    // Sileo keeps the closest-length names first after the prefix priority.
    NSInteger lhsDifference(labs((long) [lhsName length] - (long) [query length]));
    NSInteger rhsDifference(labs((long) [rhsName length] - (long) [query length]));
    if (lhsDifference != rhsDifference)
        return lhsDifference < rhsDifference ? NSOrderedAscending : NSOrderedDescending;

    NSComparisonResult result([lhsName localizedStandardCompare:rhsName]);
    if (result != NSOrderedSame)
        return result;
    return [([lhs id] ?: @"") localizedStandardCompare:([rhs id] ?: @"")];
}

// Preserve the current compact layout at the default text size, then grow the
// reusable list rows from the preferred Dynamic Type metrics. The native
// labels remain single-line where the list design requires truncation, while
// their full line height is always available at accessibility text sizes.
static CGFloat CYModernPackageRowHeight(BOOL summarized) {
    static _H<NSString> category;
    static CGFloat summaryHeight(0.0f), fullHeight(0.0f);
    NSString *current([[UIApplication sharedApplication] preferredContentSizeCategory]);
    if (fullHeight == 0.0f || ![category isEqualToString:current]) {
        category = current;
        CGFloat headline([[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline] lineHeight]);
        CGFloat detail(headline + [[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1] lineHeight] +
            [[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline] lineHeight] + 4.0f);
        summaryHeight = ceil(MAX(66.0f, MAX(46.0f, headline) + 20.0f));
        fullHeight = ceil(MAX(86.0f, MAX(46.0f, detail) + 20.0f));
    }
    return summarized ? summaryHeight : fullHeight;
}

static CGFloat CYModernSectionRowHeight(void) {
    CGFloat textHeight(MAX([[UIFont preferredFontForTextStyle:UIFontTextStyleBody] lineHeight],
        [[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1] lineHeight]));
    return ceil(MAX(56.0f, MAX(42.0f, textHeight) + 14.0f));
}

static CGFloat CYModernSourceRowHeight(void) {
    CGFloat textHeight([[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline] lineHeight] +
        3.0f + 2.0f * [[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1] lineHeight]);
    return ceil(MAX(70.0f, MAX(42.0f, textHeight) + 18.0f));
}

/* Section Class {{{ */
@interface Section : NSObject {
    _H<NSString> name_;
    size_t row_;
    size_t count_;
    _H<NSString> localized_;
}

- (NSComparisonResult) compareByLocalized:(Section *)section;
- (Section *) initWithName:(NSString *)name localized:(NSString *)localized;
- (Section *) initWithName:(NSString *)name localize:(BOOL)localize;
- (Section *) initWithName:(NSString *)name row:(size_t)row localize:(BOOL)localize;

- (NSString *) name;
- (void) setName:(NSString *)name;

- (size_t) row;
- (size_t) count;

- (void) addToRow;
- (void) addToCount;

- (void) setCount:(size_t)count;
- (NSString *) localized;

@end

@implementation Section

- (NSComparisonResult) compareByLocalized:(Section *)section {
    NSString *lhs(localized_);
    NSString *rhs([section localized]);

    /*if ([lhs length] != 0 && [rhs length] != 0) {
        unichar lhc = [lhs characterAtIndex:0];
        unichar rhc = [rhs characterAtIndex:0];

        if (isalpha(lhc) && !isalpha(rhc))
            return NSOrderedAscending;
        else if (!isalpha(lhc) && isalpha(rhc))
            return NSOrderedDescending;
    }*/

    return [lhs compare:rhs options:LaxCompareOptions_];
}

- (Section *) initWithName:(NSString *)name localized:(NSString *)localized {
    if ((self = [self initWithName:name localize:NO]) != nil) {
        if (localized != nil)
            localized_ = localized;
    } return self;
}

- (Section *) initWithName:(NSString *)name localize:(BOOL)localize {
    return [self initWithName:name row:0 localize:localize];
}

- (Section *) initWithName:(NSString *)name row:(size_t)row localize:(BOOL)localize {
    if ((self = [super init]) != nil) {
        name_ = name;
        row_ = row;
        if (localize)
            localized_ = LocalizeSection(name_);
    } return self;
}

- (NSString *) name {
    return name_;
}

- (void) setName:(NSString *)name {
    name_ = name;
}

- (size_t) row {
    return row_;
}

- (size_t) count {
    return count_;
}

- (void) addToRow {
    ++row_;
}

- (void) addToCount {
    ++count_;
}

- (void) setCount:(size_t)count {
    count_ = count;
}

- (NSString *) localized {
    return localized_;
}

@end
/* }}} */

class CydiaLogCleaner :
    public pkgArchiveCleaner
{
  protected:
    virtual void Erase(const char *File, std::string Pkg, std::string Ver, struct stat &St) {
        unlink(File);
    }
};

/* Database Implementation {{{ */
@implementation Database

+ (Database *) sharedInstance {
    static _H<Database> instance;
    if (instance == nil)
        instance = [[[Database alloc] init] autorelease];
    return instance;
}

- (unsigned) era {
    return era_;
}

- (void) releasePackages {
    packages_ = nil;
}

- (bool) hasPackages {
    return [packages_ count] != 0;
}

- (void) dealloc {
    // XXX: actually implement this thing
    _assert(false);
    [self releasePackages];
    NSRecycleZone(zone_);
    [super dealloc];
}

- (void) _readCydia:(NSNumber *)fd {
    boost::fdistream is([fd intValue]);
    std::string line;

    static RegEx finish_r("finish:([^:]*)");
    static RegEx uicache_r("uicache:(1|[Yy][Ee][Ss])");

    while (std::getline(is, line)) {
        NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

        const char *data(line.c_str());
        size_t size = line.size();
        lprintf("C:%s\n", data);

        if (finish_r(data, size)) {
            NSString *finish = finish_r[1];
            CYRootlessDiag(@"FINISH", @"maintainerScriptAction=%@ transport=CYDIA-control-fd protocolVersion=1", finish);
            // Sileo v1 uses finish:uicache as a control request.  Historical
            // Cydia used a separate uicache:1 line, so normalize both here.
            if ([finish isEqualToString:@"uicache"]) {
                UICache_ = true;
                CYRootlessDiag(@"FINISH", @"control request action=uicache source=finish-line");
            } else {
                // Modern Sileo uses finish:usreboot for a userspace reboot.
                // Cydia has no separate userspace-reboot finish slot; treat it
                // as the stronger reboot finish so a later restart request
                // cannot downgrade the required final action.
                NSString *requested(finish);
                if ([finish isEqualToString:@"usreboot"]) {
                    requested = @"reboot";
                    if (RebootMode_ < 1)
                        RebootMode_ = 1;
                    CYRootlessDiag(@"FINISH", @"control request action=usreboot normalized=reboot execution=userspace");
                } else if ([finish isEqualToString:@"reboot"]) {
                    // An explicit full reboot is stronger than a prior userspace
                    // request, while retaining the same visible Cydia finish label.
                    RebootMode_ = 2;
                    CYRootlessDiag(@"FINISH", @"control request action=reboot execution=full");
                }
                int index = CYFinishIndexForName(requested);
                if (index != INT_MAX && index > Finish_) {
                    int previous = Finish_;
                    Finish_ = index;
                    CYRootlessDiag(@"FINISH", @"control request action=%@ previousIndex=%d newIndex=%d", finish, previous, Finish_);
                } else {
                    CYRootlessDiag(@"FINISH", @"control request action=%@ ignored currentIndex=%d", finish, Finish_);
                }
            }
        } else if (uicache_r(data, size)) {
            UICache_ = true;
            CYRootlessDiag(@"FINISH", @"control request action=uicache source=legacy-line");
        }

        [pool release];
    }

    _assume(false);
}

- (void) _readStatus:(NSNumber *)fd {
    boost::fdistream is([fd intValue]);
    std::string line;

    static RegEx conffile_r("status: [^ ]* : conffile-prompt : (.*?) *");
    static RegEx pmstatus_r("([^:]*):([^:]*):([^:]*):(.*)");

    while (std::getline(is, line)) {
        NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

        NSObject<ProgressDelegate> *progress([self safeProgressDelegate]);
        NSObject<DatabaseDelegate> *delegate([self safeDatabaseDelegate]);

        const char *data(line.c_str());
        size_t size(line.size());
        lprintf("S:%s\n", data);

        if (conffile_r(data, size)) {
            // status: /fail : conffile-prompt : '/fail' '/fail.dpkg-new' 1 1
            [delegate performSelectorOnMainThread:@selector(setConfigurationData:) withObject:conffile_r[1] waitUntilDone:YES];
        } else if (strncmp(data, "status: ", 8) == 0) {
            // status: <package>: {unpacked,half-configured,installed}
            CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:(data + 8)] ofType:kCydiaProgressEventTypeStatus]);
            [progress performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
        } else if (strncmp(data, "processing: ", 12) == 0) {
            // processing: configure: config-test
            CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:(data + 12)] ofType:kCydiaProgressEventTypeStatus]);
            [progress performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
        } else if (pmstatus_r(data, size)) {
            std::string type([pmstatus_r[1] UTF8String]);

            NSString *package = pmstatus_r[2];
            if ([package isEqualToString:@"dpkg-exec"])
                package = nil;

            float percent([pmstatus_r[3] floatValue]);
            [progress performSelectorOnMainThread:@selector(setProgressPercent:) withObject:[NSNumber numberWithFloat:(percent / 100)] waitUntilDone:YES];

            NSString *string = pmstatus_r[4];

            if (type == "pmerror") {
                CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:string ofType:kCydiaProgressEventTypeError forPackage:package]);
                [progress performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
            } else if (type == "pmstatus") {
                CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:string ofType:kCydiaProgressEventTypeStatus forPackage:package]);
                [progress performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];
            } else if (type == "pmconffile")
                [delegate performSelectorOnMainThread:@selector(setConfigurationData:) withObject:string waitUntilDone:YES];
            else
                lprintf("E:unknown pmstatus\n");
        } else
            lprintf("E:unknown status\n");

        [pool release];
    }

    _assume(false);
}

- (void) _readOutput:(NSNumber *)fd {
    boost::fdistream is([fd intValue]);
    std::string line;

    while (std::getline(is, line)) {
        NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

        NSObject<ProgressDelegate> *progress([self safeProgressDelegate]);

        lprintf("O:%s\n", line.c_str());

        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:line.c_str()] ofType:kCydiaProgressEventTypeInformation]);
        [progress performSelectorOnMainThread:@selector(addProgressEvent:) withObject:event waitUntilDone:YES];

        [pool release];
    }

    _assume(false);
}

- (FILE *) input {
    return input_;
}

- (Package *) packageWithName:(NSString *)name {
    if (name == nil)
        return nil;
@synchronized (self) {
    if (static_cast<pkgDepCache *>(cache_) == NULL)
        return nil;
    pkgCache::PkgIterator iterator;
#ifndef __arm__
    // try common arch first
    iterator = cache_->FindPkg([name UTF8String], common_arch);
    if (iterator.end())
        iterator = cache_->FindPkg([name UTF8String], "any");
#else
    iterator = cache_->FindPkg([name UTF8String]);
#endif
    return iterator.end() ? nil : [[Package newPackageWithIterator:iterator withZone:NULL inPool:NULL database:self] autorelease];
} }

- (id) init {
    if ((self = [super init]) != nil) {
        policy_ = NULL;
        records_ = NULL;
        resolver_ = NULL;
        fetcher_ = NULL;
        lock_ = NULL;

        zone_ = NSCreateZone(1024 * 1024, 256 * 1024, NO);

        sourceList_ = [NSMutableArray arrayWithCapacity:16];

        int fds[2];

        _assert(pipe(fds) != -1);
        cydiafd_ = fds[1];

        _config->Set("APT::Keep-Fds::", cydiafd_);
        NSString *controlProtocol([[[NSNumber numberWithInt:cydiafd_] stringValue] stringByAppendingString:@" 1"]);
        setenv("CYDIA", [controlProtocol UTF8String], _not(int));
        // Modern rootless packages increasingly emit their requested
        // post-transaction action through Sileo's control-fd protocol rather
        // than the historical CYDIA variable.  Both protocols are the same
        // "<fd> <version>" transport and both write finish:<action> lines.
        // Advertise the already-existing Cydia control pipe as SILEO v1 too,
        // so maintainer scripts can report restart/reboot/uicache generically.
        setenv("SILEO", [controlProtocol UTF8String], _not(int));
        CYRootlessDiag(@"FINISH", @"control protocol fd=%d version=1 env=CYDIA,SILEO", cydiafd_);

        [NSThread
            detachNewThreadSelector:@selector(_readCydia:)
            toTarget:self
            withObject:[NSNumber numberWithInt:fds[0]]
        ];

        _assert(pipe(fds) != -1);
        statusfd_ = fds[1];

        [NSThread
            detachNewThreadSelector:@selector(_readStatus:)
            toTarget:self
            withObject:[NSNumber numberWithInt:fds[0]]
        ];

        _assert(pipe(fds) != -1);
        _assert(dup2(fds[0], 0) != -1);
        _assert(close(fds[0]) != -1);

        input_ = fdopen(fds[1], "a");

        _assert(pipe(fds) != -1);
        _assert(dup2(fds[1], 1) != -1);
        _assert(close(fds[1]) != -1);

        [NSThread
            detachNewThreadSelector:@selector(_readOutput:)
            toTarget:self
            withObject:[NSNumber numberWithInt:fds[0]]
        ];
    } return self;
}

- (pkgCacheFile &) cache {
    return cache_;
}

- (pkgDepCache::Policy *) policy {
    return policy_;
}

- (pkgRecords *) records {
    return records_;
}

- (pkgProblemResolver *) resolver {
    return resolver_;
}

- (pkgAcquire &) fetcher {
    return *fetcher_;
}

- (pkgSourceList &) list {
    return *list_;
}

- (NSArray *) packages {
    return packages_;
}

- (NSArray *) sources {
    return sourceList_;
}

- (Source *) sourceWithKey:(NSString *)key {
    for (Source *source in [self sources]) {
        if ([[source key] isEqualToString:key])
            return source;
    } return nil;
}

static bool CYIsCydiaManagedSourceURI(const std::string &uri) {
    const std::string canonical(CYSourceIdentity::CanonicalURI(uri));
    for (NSDictionary *source in [Sources_ allValues]) {
        NSString *managed([source objectForKey:@"URI"]);
        if (managed == nil)
            continue;
        const char *managedUTF8([managed UTF8String]);
        if (managedUTF8 != NULL && canonical == CYSourceIdentity::CanonicalURI(managedUTF8))
            return true;
    }
    return false;
}

- (bool) popErrorWithTitle:(NSString *)title {
    bool fatal(false);

    while (!_error->empty()) {
        std::string error;
        bool warning(!_error->PopMessage(error));
        if (!warning)
            fatal = true;

        for (;;) {
            size_t size(error.size());
            if (size == 0 || error[size - 1] != '\n')
                break;
            error.resize(size - 1);
        }

        NSString *diagnosticMessage([NSString stringWithUTF8String:error.c_str()]);
        if (diagnosticMessage == nil)
            diagnosticMessage = @"<non-UTF8 APT message>";
        CYRootlessDiag(@"APT", @"level=%@ task=%@ message=%@",
            warning ? @"WARN" : @"ERROR",
            title ?: @"<nil>",
            CYRootlessDiagnosticsText(diagnosticMessage));

        lprintf("%c:[%s]\n", warning ? 'W' : 'E', error.c_str());

        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:error.c_str()] ofType:(warning ? kCydiaProgressEventTypeWarning : kCydiaProgressEventTypeError)] forTask:title];
    }

    return fatal;
}

- (bool) popErrorWithTitle:(NSString *)title forOperation:(bool)success {
    return [self popErrorWithTitle:title] || !success;
}

- (bool) popRefreshErrorsWithTitle:(NSString *)title forOperation:(bool)success
    sourceRoots:(const std::set<std::string> *)sourceRoots
    isolated:(bool *)isolated failures:(size_t *)failures
    sourceIssues:(NSMutableDictionary *)sourceIssues {
    struct Message {
        bool warning;
        std::string text;
    };

    std::vector<Message> messages;
    while (!_error->empty()) {
        std::string text;
        bool warning(!_error->PopMessage(text));
        while (!text.empty() && text[text.size() - 1] == '\n')
            text.resize(text.size() - 1);
        Message message = {warning, text};
        messages.push_back(message);
    }

    std::vector<bool> sourcePackageFailure(messages.size(), false);
    std::vector<bool> acceptedLegacyKeyWarning(messages.size(), false);
    std::vector<bool> sourceSecurityFailure(messages.size(), false);
    std::set<std::string> rejectedSecurityRoots;
    std::set<std::string> isolatedRoots;
    size_t isolatedCount(0);
    size_t rejectedUntrustedCount(0);
    bool blockingMessage(false);

    // First identify every source-bound signature rejection. Companion APT
    // advisory lines do not repeat the URL, so they are classified only after
    // at least one concrete source rejection has been found.
    if (sourceRoots != NULL) {
        for (size_t index(0); index != messages.size(); ++index) {
            std::string matchedRoot;
            if (messages[index].warning &&
                CYExternalSourceCompatibility::IsAcceptedMissingPublicKeyWarning(
                    messages[index].text, *sourceRoots, &matchedRoot)) {
                acceptedLegacyKeyWarning[index] = true;
                continue;
            }
            if (CYExternalSourceCompatibility::IsSourceSecurityRejection(
                messages[index].text, *sourceRoots, &matchedRoot)) {
                sourceSecurityFailure[index] = true;
                rejectedSecurityRoots.insert(matchedRoot);
                const std::string canonical(CYSourceIdentity::CanonicalURI(matchedRoot));
                NSString *root([NSString stringWithUTF8String:canonical.c_str()]);
                if (root != nil && [sourceIssues objectForKey:root] == nil) {
                    NSString *code([NSString stringWithUTF8String:
                        CYExternalSourceCompatibility::SecurityIssueCode(messages[index].text)]);
                    if (code != nil)
                        [sourceIssues setObject:code forKey:root];
                }
            }
        }
    }
    bool hasSourceSecurityFailure(!rejectedSecurityRoots.empty());

    for (size_t index(0); index != messages.size(); ++index) {
        const Message &message(messages[index]);
        if (acceptedLegacyKeyWarning[index])
            continue;
        std::string matchedPackageRoot;
        if (sourceRoots != NULL && CYExternalSourceCompatibility::IsSourcePackageIndex404(
            message.text, *sourceRoots, &matchedPackageRoot)) {
            sourcePackageFailure[index] = true;
            isolatedRoots.insert(matchedPackageRoot);
            const std::string canonical(CYSourceIdentity::CanonicalURI(matchedPackageRoot));
            NSString *root([NSString stringWithUTF8String:canonical.c_str()]);
            if (root != nil && [sourceIssues objectForKey:root] == nil)
                [sourceIssues setObject:@"packages-missing" forKey:root];
            ++isolatedCount;
            continue;
        }
        if (sourceSecurityFailure[index] || (hasSourceSecurityFailure &&
            CYExternalSourceCompatibility::IsSecurityAdvisory(message.text))) {
            // APT has rejected this source's new index. Treat the refresh
            // result as source-local so unrelated repositories can finish,
            // while retaining the previous usable package data.
            sourceSecurityFailure[index] = true;
            isolatedRoots.insert(rejectedSecurityRoots.begin(), rejectedSecurityRoots.end());
            ++isolatedCount;
            ++rejectedUntrustedCount;
            continue;
        }
        if (CYExternalSourceCompatibility::IsAggregateIndexWarning(message.text))
            continue;

        // Every unmatched message remains a blocker. A source-local rejection
        // can be isolated only when APT retained the previous package data.
        blockingMessage = true;
    }

    bool isolateOperation(CYExternalSourceCompatibility::CanIsolateOperation(isolatedCount, blockingMessage));
    bool fatal(false);

    for (size_t index(0); index != messages.size(); ++index) {
        const Message &message(messages[index]);
        NSString *diagnosticMessage([NSString stringWithUTF8String:message.text.c_str()]);
        if (diagnosticMessage == nil)
            diagnosticMessage = @"<non-UTF8 APT message>";
        CYRootlessDiag(@"APT", @"level=%@ task=%@ message=%@",
            message.warning ? @"WARN" : @"ERROR",
            title ?: @"<nil>",
            CYRootlessDiagnosticsText(diagnosticMessage));

        if (acceptedLegacyKeyWarning[index] && sourceRoots != NULL) {
            std::string matchedRoot;
            CYExternalSourceCompatibility::IsAcceptedMissingPublicKeyWarning(
                message.text, *sourceRoots, &matchedRoot);
            NSString *root([NSString stringWithUTF8String:matchedRoot.c_str()]);
            CYRootlessDiag(@"SOURCE_COMPAT", @"level=INFO action=accepted-legacy-missing-key source=%@ packageHashAndSizeVerification=required",
                CYRootlessDiagnosticsText([root length] == 0 ? @"<unknown-source>" : root));
            lprintf("W:[legacy repository key unavailable; metadata accepted by configured compatibility policy: %s]\n", message.text.c_str());
            continue;
        }

        if (sourcePackageFailure[index] && sourceRoots != NULL) {
            std::string matchedRoot;
            CYExternalSourceCompatibility::IsSourcePackageIndex404(message.text, *sourceRoots, &matchedRoot);
            NSString *root([NSString stringWithUTF8String:matchedRoot.c_str()]);
            CYRootlessDiag(@"SOURCE_SECURITY", @"level=WARN action=isolated-packages-404 source=%@ message=%@",
                CYRootlessDiagnosticsText(root ?: @"<non-UTF8 URI>"),
                CYRootlessDiagnosticsText(diagnosticMessage));
            lprintf("W:[source-local Packages index failure: %s]\n", message.text.c_str());
            continue;
        }

        if (sourceSecurityFailure[index] && sourceRoots != NULL) {
            std::string matchedRoot;
            CYExternalSourceCompatibility::IsSourceSecurityRejection(message.text, *sourceRoots, &matchedRoot);
            NSString *root([NSString stringWithUTF8String:matchedRoot.c_str()]);
            CYRootlessDiag(@"SOURCE_COMPAT", @"level=WARN action=rejected-index reason=signature-verification source=%@ message=%@",
                CYRootlessDiagnosticsText([root length] == 0 ? @"<companion-advisory>" : root),
                CYRootlessDiagnosticsText(diagnosticMessage));
            lprintf("W:[source index rejected by APT, previous package data retained: %s]\n", message.text.c_str());
            if (isolateOperation)
                continue;
        }

        if (isolateOperation && CYExternalSourceCompatibility::IsAggregateIndexWarning(message.text)) {
            CYRootlessDiag(@"REFRESH", @"level=INFO suppressedFromUI=1 reason=source-local-failures-isolated isolatedFailures=%zu rejectedUntrusted=%zu", isolatedCount, rejectedUntrustedCount);
            lprintf("W:[APT aggregate index warning hidden after source-local isolation]\n");
            continue;
        }

        lprintf("%c:[%s]\n", message.warning ? 'W' : 'E', message.text.c_str());

        if (!message.warning)
            fatal = true;
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:diagnosticMessage ofType:(message.warning ? kCydiaProgressEventTypeWarning : kCydiaProgressEventTypeError)] forTask:title];
    }

    if (isolateOperation) {
        size_t sourceFailureCount(isolatedRoots.empty() ? 1 : isolatedRoots.size());
        NSString *summary(sourceFailureCount == 1 ?
            @"One repository kept its previous package data." :
            [NSString stringWithFormat:@"%zu repositories kept their previous package data.", sourceFailureCount]);
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:summary ofType:kCydiaProgressEventTypeWarning] forTask:title];
    }

    if (isolated != NULL)
        *isolated = isolateOperation;
    if (failures != NULL)
        *failures = isolatedRoots.empty() ? isolatedCount : isolatedRoots.size();

    return fatal || (!success && !isolateOperation);
}

- (bool) popErrorWithTitle:(NSString *)title forReadList:(pkgSourceList &)list {
    if ([self popErrorWithTitle:title forOperation:list.ReadMainList()])
        return true;
    return false;

    list.Reset();

    bool error(false);

    if (access("/var/jb/etc/apt/sources.list", F_OK) == 0)
        error |= [self popErrorWithTitle:title forOperation:list.ReadAppend("/var/jb/etc/apt/sources.list")];

    std::string base("/var/jb/etc/apt/sources.list.d");
    if (DIR *sources = opendir(base.c_str())) {
        while (dirent *source = readdir(sources))
            if (source->d_name[0] != '.' && source->d_namlen > 5 && strcmp(source->d_name + source->d_namlen - 5, ".list") == 0 && strcmp(source->d_name, "cydia.list") != 0)
                error |= [self popErrorWithTitle:title forOperation:list.ReadAppend((base + "/" + source->d_name).c_str())];
        closedir(sources);
    }

    error |= [self popErrorWithTitle:title forOperation:list.ReadAppend([SOURCES_LIST UTF8String])];

    return error;
}

- (bool) ready {
    return ready_ && cache_.IsDepCacheBuilt() && resolver_ != NULL && records_ != NULL && fetcher_ != NULL;
}

- (void) reloadDataWithInvocation:(NSInvocation *)invocation {
@synchronized (self) {
    ready_ = false;
    bool attemptedRepair(false);
    uint64_t diagnosticsStart(_timestamp);
    CYRootlessDiag(@"DATABASE", @"reload begin hasInvocation=%d eraNext=%u", invocation != nil, era_ + 1);
    ++era_;

    [self releasePackages];

    sourceMap_.clear();
    [sourceList_ removeAllObjects];

    _error->Discard();

    delete list_;
    list_ = NULL;
    manager_ = NULL;
    delete lock_;
    lock_ = NULL;
    delete fetcher_;
    fetcher_ = NULL;
    delete resolver_;
    resolver_ = NULL;
    delete records_;
    records_ = NULL;
    delete policy_;
    policy_ = NULL;

    cache_.Close();

    pool_.~CYPool();
    new (&pool_) CYPool();

    NSRecycleZone(zone_);
    zone_ = NSCreateZone(1024 * 1024, 256 * 1024, NO);

    int chk(creat("/tmp/cydia.chk", 0644));
    if (chk != -1)
        close(chk);

    if (invocation != nil)
        [invocation invoke];

    // Sanitize Cydia's private list cache before APT opens the
    // MergeList. This repairs already-cached malformed repositories and also
    // catches a bad index downloaded by the Refresh invocation above.
    size_t quarantined(CYQuarantineMalformedPackageLists());
    if (quarantined != 0) {
        CYRootlessDiag(@"DATABASE", @"level=WARN quarantinedMalformedLists=%zu phase=reload", quarantined);
        lprintf("W:[rootless list safety: ignored %zu malformed Packages index(es)]\n", quarantined);
    }

    NSString *title(UCLocalize("DATABASE"));

    list_ = new pkgSourceList();
    _profile(reloadDataWithInvocation$ReadMainList)
    if ([self popErrorWithTitle:title forReadList:*list_]) {
        CYRootlessDiag(@"DATABASE", @"reload end status=failed phase=read-sources durationMs=%llu", (unsigned long long) ((_timestamp - diagnosticsStart) / 1000));
        return;
    }
    _end

    fetcher_ = new pkgAcquire(&status_);

    _profile(reloadDataWithInvocation$Source$initWithMetaIndex)
    for (pkgSourceList::const_iterator source = list_->begin(); source != list_->end(); ++source) {
        Source *object([[[Source alloc] initWithMetaIndex:*source forDatabase:self inPool:&pool_ withAcquire:fetcher_] autorelease]);
        [sourceList_ addObject:object];
        CYRootlessDiag(@"SOURCE", @"model name=%@ origin=%@ label=%@ uri=%@ distribution=%@ trusted=%d",
            [object name] ?: @"<nil>",
            [object origin] ?: @"<nil>",
            [object label] ?: @"<nil>",
            CYRootlessDiagnosticsText([object rooturi]),
            [object distribution] ?: @"<nil>",
            [object trusted]);
    }
    CYRootlessDiag(@"DATABASE", @"source model count=%lu", (unsigned long) [sourceList_ count]);
    _end

    _trace();
    OpProgress progress;
    bool opened;
  open:
    delock_ = GetStatusDate();
    _profile(reloadDataWithInvocation$pkgCacheFile)
        opened = cache_.Open(progress, false);
    _end
    if (!opened) {
        // XXX: this block should probably be merged with popError: in some way
        while (!_error->empty()) {
            std::string error;
            bool warning(!_error->PopMessage(error));

            NSString *diagnosticMessage([NSString stringWithUTF8String:error.c_str()]);
            if (diagnosticMessage == nil)
                diagnosticMessage = @"<non-UTF8 cache message>";
            CYRootlessDiag(@"DATABASE", @"level=%@ phase=cache-open message=%@",
                warning ? @"WARN" : @"ERROR", CYRootlessDiagnosticsText(diagnosticMessage));
            lprintf("cache_.Open():[%s]\n", error.c_str());

            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:[NSString stringWithUTF8String:error.c_str()] ofType:(warning ? kCydiaProgressEventTypeWarning : kCydiaProgressEventTypeError)] forTask:title];

            SEL repair(NULL);
            if (false);
            else if (error == "dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem. ")
                repair = @selector(configure);
            //else if (error == "The package lists or status file could not be parsed or opened.")
            //    repair = @selector(update);
            // else if (error == "Could not get lock /var/lib/dpkg/lock - open (35 Resource temporarily unavailable)")
            // else if (error == "Could not open lock file /var/lib/dpkg/lock - open (13 Permission denied)")
            // else if (error == "Malformed Status line")
            // else if (error == "The list of sources could not be read.")

            if (repair != NULL && !attemptedRepair) {
                attemptedRepair = true;
                configurationSucceeded_ = false;
                _error->Discard();
                [delegate_ repairWithSelector:repair];
                if (configurationSucceeded_)
                    goto open;
                // Leave the model unavailable and preserve the failure. A
                // persistent maintainer-script error must not loop at launch.
                return;
            }
        }

        return;
    } else if ([self popErrorWithTitle:title forOperation:true])
        return;
    _trace();

    unlink("/tmp/cydia.chk");

    now_ = [[NSDate date] timeIntervalSince1970];

    policy_ = new pkgDepCache::Policy();
    records_ = new pkgRecords(cache_);
    resolver_ = new pkgProblemResolver(cache_);
    lock_ = NULL;

    if (cache_->DelCount() != 0 || cache_->InstCount() != 0) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:UCLocalize("COUNTS_NONZERO_EX") ofType:kCydiaProgressEventTypeError] forTask:title];
        return;
    }

    _profile(reloadDataWithInvocation$pkgApplyStatus)
    if ([self popErrorWithTitle:title forOperation:pkgApplyStatus(cache_)])
        return;
    _end

    if (cache_->BrokenCount() != 0) {
        _profile(pkgApplyStatus$pkgFixBroken)
        if ([self popErrorWithTitle:title forOperation:pkgFixBroken(cache_)])
            return;
        _end

        if (cache_->BrokenCount() != 0) {
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:UCLocalize("STILL_BROKEN_EX") ofType:kCydiaProgressEventTypeError] forTask:title];
            return;
        }

        _profile(pkgApplyStatus$pkgMinimizeUpgrade)
        if ([self popErrorWithTitle:title forOperation:pkgMinimizeUpgrade(cache_)])
            return;
        _end
    }

    for (Source *object in (id) sourceList_) {
        metaIndex *source([object metaIndex]);
        std::vector<pkgIndexFile *> *indices = source->GetIndexFiles();
        for (std::vector<pkgIndexFile *>::const_iterator index = indices->begin(); index != indices->end(); ++index)
            // XXX: this could be more intelligent
            if (dynamic_cast<debPackagesIndex *>(*index) != NULL) {
                pkgCache::PkgFileIterator cached((*index)->FindInCache(cache_));
                if (!cached.end())
                    sourceMap_[cached->ID] = object;
            }
    }

    {
        size_t capacity(MetaFile_->active_);
        if (capacity == 0)
            capacity = 128*1024;
        else
            capacity += 1024;

        std::vector<Package *> packages;
        packages.reserve(capacity);
        size_t lost(0);

        size_t last(0);
        _profile(reloadDataWithInvocation$packageWithIterator)
        for (pkgCache::PkgIterator iterator = cache_->PkgBegin(); !iterator.end(); ++iterator)
            if (Package *package = [Package newPackageWithIterator:iterator withZone:zone_ inPool:&pool_ database:self]) {
                if (unsigned index = package.metadata->index_) {
                    --index;
                    if (packages.size() == index) {
                        packages.push_back(package);
                    } else if (packages.size() <= index) {
                        packages.resize(index + 1, nil);
                        packages[index] = package;
                        continue;
                    } else {
                        std::swap(package, packages[index]);
                        if (package != nil) {
                            if (package.metadata->index_ == index + 1)
                                ++lost;
                            goto lost;
                        }
                        if (last != index)
                            continue;
                    }
                } else {
                    ++lost;
                    lost: if (last == packages.size())
                        packages.push_back(package);
                    else
                        packages[last] = package;
                    ++last;
                }

                for (; last != packages.size(); ++last)
                    if (packages[last] == nil)
                        break;
            }
        _end

        for (size_t next(last + 1); last != packages.size(); ++last, ++next) {
            while (true) {
                if (next == packages.size())
                    goto done;
                if (packages[next] != nil)
                    break;
                ++next;
            }

            std::swap(packages[last], packages[next]);
        } done:;

        packages.resize(last);

        if (lost > 128) {
            NSLog(@"lost = %zu", lost);

            _profile(reloadDataWithInvocation$radix$8)
            CYRadixSortUsingFunction(packages.data(), packages.size(), reinterpret_cast<MenesRadixSortFunction>(&PackagePrefixRadix), reinterpret_cast<void *>(8));
            _end

            _profile(reloadDataWithInvocation$radix$4)
            CYRadixSortUsingFunction(packages.data(), packages.size(), reinterpret_cast<MenesRadixSortFunction>(&PackagePrefixRadix), reinterpret_cast<void *>(4));
            _end

            _profile(reloadDataWithInvocation$radix$0)
            CYRadixSortUsingFunction(packages.data(), packages.size(), reinterpret_cast<MenesRadixSortFunction>(&PackagePrefixRadix), reinterpret_cast<void *>(0));
            _end
        }

        _profile(reloadDataWithInvocation$insertion)
        CYArrayInsertionSortValues(packages.data(), packages.size(), &PackageNameCompare, NULL);
        _end

        packages_ = [[[NSArray alloc] initWithObjects:packages.data() count:packages.size()] autorelease];

        /*_profile(reloadDataWithInvocation$CFQSortArray)
        CFQSortArray(&packages.front(), packages.size(), sizeof(packages.front()), reinterpret_cast<CFComparatorFunction>(&PackageNameCompare_), NULL);
        _end*/

        /*_profile(reloadDataWithInvocation$stdsort)
        std::sort(packages.begin(), packages.end(), PackageNameOrdering());
        _end*/

        /*_profile(reloadDataWithInvocation$CFArraySortValues)
        CFArraySortValues((CFMutableArrayRef) packages_, CFRangeMake(0, [packages_ count]), reinterpret_cast<CFComparatorFunction>(&PackageNameCompare), NULL);
        _end*/

        /*_profile(reloadDataWithInvocation$sortUsingFunction)
        [packages_ sortUsingFunction:reinterpret_cast<NSComparisonResult (*)(id, id, void *)>(&PackageNameCompare) context:NULL];
        _end*/

        MetaFile_->active_ = packages.size();
        for (size_t index(0), count(packages.size()); index != count; ++index) {
            auto package(packages[index]);
            [package setIndex:index];
            [package release];
        }
    }
    ready_ = true;
    CYRootlessDiag(@"DATABASE", @"reload end status=ok sources=%lu packages=%lu durationMs=%llu",
        (unsigned long) [sourceList_ count],
        (unsigned long) [packages_ count],
        (unsigned long long) ((_timestamp - diagnosticsStart) / 1000));
} }

- (void) clear {
@synchronized (self) {
    if (![self ready])
        return;
    delete resolver_;
    resolver_ = new pkgProblemResolver(cache_);

    for (pkgCache::PkgIterator iterator(cache_->PkgBegin()); !iterator.end(); ++iterator)
        if (!cache_[iterator].Keep())
            cache_->MarkKeep(iterator, false);
        else if ((cache_[iterator].iFlags & pkgDepCache::ReInstall) != 0)
            cache_->SetReInstall(iterator, false);
} }

- (void) configure {
    configurationSucceeded_ = false;
    const char *helper("/var/jb/usr/libexec/cydia/cydo");
    char descriptor[32];
    snprintf(descriptor, sizeof(descriptor), "%u", statusfd_);
    char *const arguments[] = {
        const_cast<char *>(helper), const_cast<char *>("--configure"),
        const_cast<char *>("-a"), const_cast<char *>("--status-fd"), descriptor, NULL
    };
    pid_t child(-1);
    int result(posix_spawn(&child, helper, NULL, NULL, arguments, environ));
    int status(0);
    pid_t waited(-1);
    if (result == 0)
        do { waited = waitpid(child, &status, 0); } while (waited == -1 && errno == EINTR);
    configurationSucceeded_ = result == 0 && waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    if (!configurationSucceeded_)
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent
            eventWithMessage:@"Package configuration could not be completed. Review the repair details before trying again."
            ofType:kCydiaProgressEventTypeError] forTask:UCLocalize("DATABASE")];
}

- (bool) clean {
@synchronized (self) {
    // XXX: I don't remember this condition
    if (lock_ != NULL)
        return false;

    FileFd Lock = FileFd(GetLock(_config->FindDir("Dir::Cache::Archives") + "lock"), true);

    NSString *title(UCLocalize("CLEAN_ARCHIVES"));

    if ([self popErrorWithTitle:title])
        return false;

    pkgAcquire fetcher;
    fetcher.Clean(_config->FindDir("Dir::Cache::Archives"));

    CydiaLogCleaner cleaner;
    if ([self popErrorWithTitle:title forOperation:cleaner.Go(_config->FindDir("Dir::Cache::Archives") + "partial/", cache_)])
        return false;

    return true;
} }

- (bool) prepare {
    // A failed previous preparation must never leave Cydia holding the archive
    // lock or a half-built package manager.  Sileo recreates its operation
    // objects for every transaction; do the equivalent cleanup here before
    // asking APT to prepare a fresh download plan.
    manager_ = NULL;
    delete lock_;
    lock_ = NULL;
    CYClearSensitiveDownloadURLs();
    if (![self ready]) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent
            eventWithMessage:@"Package data is not ready. Refresh Sources and try again."
            ofType:kCydiaProgressEventTypeError] forTask:UCLocalize("PREPARE_ARCHIVES")];
        return false;
    }
    fetcher_->Shutdown();

    // Review unresolved dependencies before constructing archive requests.
    // The review remains available, but this queue owns no archive lock or PM.
    if (cache_->BrokenCount() != 0) {
        CYRootlessDiag(@"TRANSACTION", @"prepare reviewOnly=1 reason=unresolved-dependencies archiveRequests=0");
        return true;
    }

    pkgRecords records(cache_);

    lock_ = new FileFd(GetLock(_config->FindDir("Dir::Cache::Archives") + "lock"), true);

    NSString *title(UCLocalize("PREPARE_ARCHIVES"));

    const auto failPrepare = [&]() -> bool {
        manager_ = NULL;
        delete lock_;
        lock_ = NULL;
        CYClearSensitiveDownloadURLs();
        CYRootlessDiag(@"TRANSACTION", @"prepare cleanup archiveLockReleased=1 packageManagerReleased=1");
        return false;
    };

    if ([self popErrorWithTitle:title])
        return failPrepare();

    pkgSourceList list;
    if ([self popErrorWithTitle:title forReadList:list])
        return failPrepare();

    // Rootless hard safety gate: dependency resolution must not be able to
    // smuggle a known rootful-only transition package into a rootless
    // transaction even if its Architecture is "all".
    for (pkgCache::PkgIterator iterator(cache_->PkgBegin()); !iterator.end(); ++iterator) {
        pkgDepCache::StateCache &state(cache_[iterator]);
        if (state.Mode == pkgDepCache::ModeInstall && CYRootlessBlockedLegacyPackage(iterator.Name())) {
            NSString *message([NSString stringWithFormat:@"Blocked rootful-only package %s: it writes to /sbin and is incompatible with /var/jb rootless jailbreaks.", iterator.Name()]);
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:message ofType:kCydiaProgressEventTypeError] forTask:title];
            return failPrepare();
        }
    }

    manager_ = (_system->CreatePM(cache_));
    if (manager_ == NULL) {
        [self popErrorWithTitle:title];
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent
            eventWithMessage:@"APT could not create a package transaction. No changes were applied."
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return failPrepare();
    }
    if ([self popErrorWithTitle:title forOperation:manager_->GetArchives(fetcher_, &list, &records)])
        return failPrepare();

    // Passive package-acquisition diagnostics record the exact Filename field
    // and every source-derived ArchiveURI candidate. A short-lived paid-package
    // URL can be substituted below, but APT's signed-index hash and size checks
    // remain authoritative and unchanged.
    for (pkgCache::PkgIterator iterator(cache_->PkgBegin()); !iterator.end(); ++iterator) {
        pkgDepCache::StateCache &state(cache_[iterator]);
        if (state.Mode != pkgDepCache::ModeInstall)
            continue;
        pkgCache::VerIterator version(cache_->GetCandidateVersion(iterator));
        if (version.end())
            continue;

        size_t candidateIndex(0);
        for (pkgCache::VerFileIterator file(version.FileList()); !file.end(); ++file) {
            pkgIndexFile *index(NULL);
            if (!list.FindIndex(file.File(), index) || index == NULL)
                continue;
            pkgRecords::Parser &parser(records.Lookup(file));
            std::string filename(parser.FileName());
            if (filename.empty())
                continue;
            std::string baseURI(index->ArchiveURI(""));
            std::string composedURI(index->ArchiveURI(filename));
            NSString *owner(CYIsCydiaManagedSourceURI(baseURI) ? @"Cydia" : @"external");
            NSString *filenameText([NSString stringWithUTF8String:filename.c_str()]);
            CYRootlessDiag(@"PACKAGE_DOWNLOAD_PLAN", @"package=%s version=%s architecture=%s sourceOwnership=%@ candidate=%zu Filename=%@ baseURI=%@ composedURL=%@ expectedSize=%llu verification=APT-hash-and-size-unchanged",
                iterator.Name(), version.VerStr(), version.Arch(), owner, candidateIndex++,
                CYRootlessDiagnosticsText(filenameText ?: @"<non-UTF8 Filename>"),
                CYDiagnosticURLString(baseURI), CYDiagnosticURLString(composedURI),
                (unsigned long long) version->Size);
        }
    }

    // Sileo Payment API compatibility for commercial packages. Authentication
    // tokens stay in the iOS Keychain. The provider must confirm ownership and
    // return a short-lived HTTPS URL before APT is allowed to fetch the archive.
    // Only the transport URI changes; expected hashes and sizes still come from
    // the verified Packages index and are enforced by pkgAcqArchive.
    std::map<std::string, std::string> authorizedDownloads;
    for (pkgCache::PkgIterator iterator(cache_->PkgBegin()); !iterator.end(); ++iterator) {
        pkgDepCache::StateCache &state(cache_[iterator]);
        if (state.Mode != pkgDepCache::ModeInstall)
            continue;
        Package *package([self packageWithName:[NSString stringWithUTF8String:iterator.Name()]]);
        if (package == nil || ![package isCommercial])
            continue;
        Source *source([package source]);
        pkgCache::VerIterator version(cache_->GetCandidateVersion(iterator));
        if (source == nil || version.end()) {
            NSString *message([NSString stringWithFormat:@"The paid package %s is not available from a supported repository.", iterator.Name()]);
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:message ofType:kCydiaProgressEventTypeError] forTask:title];
            return failPrepare();
        }

        NSString *model(Machine_ != NULL ? [NSString stringWithUTF8String:Machine_] : nil);
        NSError *authorizationError(nil);
        NSString *authorized(CYRepositoryAuthorizedDownloadURL(
            [source rooturi],
            [package id],
            [NSString stringWithUTF8String:version.VerStr()],
            [NSString stringWithUTF8String:version.Arch()],
            UniqueID_,
            model,
            &authorizationError
        ));
        if (authorized == nil) {
            NSString *reason([authorizationError localizedDescription] ?: CYLocalize(@"The repository did not authorize this download."));
            NSString *message([NSString stringWithFormat:@"%@\n\n%@", [package name] ?: [package id], reason]);
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:message ofType:kCydiaProgressEventTypeError] forTask:title];
            return failPrepare();
        }
        CYRegisterSensitiveDownloadURL(authorized);
        authorizedDownloads[iterator.FullName(true)] = [authorized UTF8String];
    }

    if (!authorizedDownloads.empty()) {
        size_t replaced(0);
        std::set<std::string> handled;
        for (pkgAcquire::UriIterator queued(fetcher_->UriBegin()); queued != fetcher_->UriEnd(); ++queued) {
            std::map<std::string, std::string>::const_iterator authorized(authorizedDownloads.find(queued->ShortDesc));
            if (authorized == authorizedDownloads.end())
                continue;
            const_cast<std::string &>(queued->URI) = authorized->second;
            if (queued->Owner != NULL)
                queued->Owner->GetItemDesc().URI = authorized->second;
            handled.insert(authorized->first);
            ++replaced;
        }
        for (pkgAcquire::ItemIterator item(fetcher_->ItemsBegin()); item != fetcher_->ItemsEnd(); ++item) {
            pkgAcquire::ItemDesc &description((*item)->GetItemDesc());
            if (authorizedDownloads.find(description.ShortDesc) != authorizedDownloads.end() && (*item)->Complete && (*item)->Local)
                handled.insert(description.ShortDesc);
        }
        if (handled.size() != authorizedDownloads.size()) {
            NSString *message(@"A paid package was authorized, but its APT download request could not be located safely.");
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:message ofType:kCydiaProgressEventTypeError] forTask:title];
            return failPrepare();
        }
        CYRootlessDiag(@"ACCOUNT", @"authorizedPaidDownloads=%zu urlValues=not-logged verification=APT-hash-and-size-unchanged", replaced);
    }

    return true;
}

- (NSArray *) transactionOperationsForRequestedIdentifiers:(NSSet *)requestedIdentifiers {
    if (![self ready] || [requestedIdentifiers count] == 0)
        return [NSArray array];

    NSMutableArray *operations([NSMutableArray arrayWithCapacity:[requestedIdentifiers count]]);
    for (pkgCache::PkgIterator iterator(cache_->PkgBegin()); !iterator.end(); ++iterator) {
        NSString *identifier([NSString stringWithUTF8String:iterator.Name()]);
        if (identifier == nil || ![requestedIdentifiers containsObject:identifier])
            continue;

        pkgDepCache::StateCache &state(cache_[iterator]);
        if (state.Delete()) {
            [operations addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                identifier, @"identifier", @"remove", @"action", nil]];
            continue;
        }

        if (!state.Install() && (state.iFlags & pkgDepCache::ReInstall) == 0)
            continue;
        pkgCache::VerIterator version(state.InstVerIter(cache_));
        if (version.end())
            continue;
        NSString *versionText([NSString stringWithUTF8String:version.VerStr()]);
        NSString *architecture([NSString stringWithUTF8String:version.Arch()]);
        if (versionText == nil || architecture == nil)
            continue;
        [operations addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            identifier, @"identifier",
            @"install", @"action",
            versionText, @"version",
            architecture, @"architecture",
            [NSNumber numberWithBool:(state.iFlags & pkgDepCache::ReInstall) != 0], @"reinstall",
        nil]];
    }

    return operations;
}

- (NSSet *) transactionPlan {
    if (![self ready])
        return nil;
    NSMutableSet *identifiers([NSMutableSet set]);
    for (pkgCache::PkgIterator iterator(cache_->PkgBegin()); !iterator.end(); ++iterator)
        [identifiers addObject:[NSString stringWithUTF8String:iterator.Name()]];
    return [NSSet setWithArray:[self transactionOperationsForRequestedIdentifiers:identifiers]];
}

- (bool) restoreTransactionOperations:(NSArray *)operations title:(NSString *)title {
    if (![self ready] || [operations count] == 0)
        return false;

    NSUInteger reapplied(0);
    for (NSDictionary *operation in operations) {
        NSString *identifier([operation objectForKey:@"identifier"]);
        pkgCache::PkgIterator iterator(cache_->FindPkg([identifier UTF8String]));
        if (iterator.end()) {
            NSString *message([NSString stringWithFormat:@"%@ is no longer available after package state changed.", identifier]);
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:message ofType:kCydiaProgressEventTypeError] forTask:title];
            return false;
        }

        pkgProblemResolver *resolver([self resolver]);
        resolver->Clear(iterator);
        if ([[operation objectForKey:@"action"] isEqualToString:@"remove"]) {
            if (iterator.CurrentVer().end())
                continue;
            resolver->Remove(iterator);
            resolver->Protect(iterator);
            cache_->SetReInstall(iterator, false);
            cache_->MarkDelete(iterator, true);
            ++reapplied;
            continue;
        }

        NSString *wantedVersion([operation objectForKey:@"version"]);
        NSString *wantedArchitecture([operation objectForKey:@"architecture"]);
        pkgCache::VerIterator version;
        for (version = iterator.VersionList(); !version.end(); ++version)
            if (strcmp(version.VerStr(), [wantedVersion UTF8String]) == 0 &&
                strcmp(version.Arch(), [wantedArchitecture UTF8String]) == 0)
                break;
        if (version.end()) {
            NSString *message([NSString stringWithFormat:@"The selected version of %@ is no longer available after package state changed.", identifier]);
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:message ofType:kCydiaProgressEventTypeError] forTask:title];
            return false;
        }

        bool reinstall([[operation objectForKey:@"reinstall"] boolValue]);
        pkgCache::VerIterator current(iterator.CurrentVer());
        if (!reinstall && !current.end() && strcmp(current.VerStr(), version.VerStr()) == 0)
            continue;
        resolver->Protect(iterator);
        cache_->SetCandidateVersion(version);
        cache_->SetReInstall(iterator, false);
        cache_->MarkInstall(iterator, true);
        if (reinstall)
            cache_->SetReInstall(iterator, true);
        ++reapplied;
    }

    resolver_->InstallProtect();
    if (!resolver_->Resolve(true)) {
        [self popErrorWithTitle:title];
        CYRootlessDiag(@"TRANSACTION", @"operation restore failed phase=dependency-resolution reapplied=%lu", (unsigned long) reapplied);
        return false;
    }

    CYRootlessDiag(@"TRANSACTION", @"operation restore complete explicitOperations=%lu reapplied=%lu dependencyClosure=resolved",
        (unsigned long) [operations count], (unsigned long) reapplied);
    return true;
}

- (bool) rebuildTransactionForRequestedIdentifiers:(NSSet *)requestedIdentifiers title:(NSString *)title {
    _H<NSSet> reviewedPlan([self transactionPlan]);
    NSArray *operations([[self transactionOperationsForRequestedIdentifiers:requestedIdentifiers] retain]);
    if ([operations count] == 0) {
        CYRootlessDiag(@"DPKG_LOCK", @"automatic replan skipped reason=no-explicit-operations requested=%lu",
            (unsigned long) [requestedIdentifiers count]);
        [operations release];
        return false;
    }

    CYRootlessDiag(@"DPKG_LOCK", @"package database changed before commit; automatic replan begin explicitOperations=%lu",
        (unsigned long) [operations count]);
    [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent
        eventWithMessage:@"Package state changed while downloading. Rechecking the transaction safely…"
        ofType:kCydiaProgressEventTypeWarning] forTask:title];

    [self reloadDataWithInvocation:nil];

    if (![self restoreTransactionOperations:operations title:title]) {
        [operations release];
        CYRootlessDiag(@"DPKG_LOCK", @"automatic replan failed phase=operation-restore");
        return false;
    }
    NSUInteger operationCount([operations count]);
    [operations release];

    if (![reviewedPlan isEqual:[self transactionPlan]]) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent
            eventWithMessage:@"Package state changed and the required changes are different. Review the package queue again before applying them."
            ofType:kCydiaProgressEventTypeError] forTask:title];
        CYRootlessDiag(@"DPKG_LOCK", @"automatic replan stopped reason=reviewed-plan-changed");
        return false;
    }
    if (![self prepare]) {
        CYRootlessDiag(@"DPKG_LOCK", @"automatic replan failed phase=prepare explicitOperations=%lu", (unsigned long) operationCount);
        return false;
    }
    CYRootlessDiag(@"DPKG_LOCK", @"automatic replan complete explicitOperations=%lu dependencyClosure=resolved", (unsigned long) operationCount);
    return true;
}

- (void) perform {
    [self performWithRequestedIdentifiers:nil retryCount:0];
}

- (CYPackageTransactionResult) performWithRequestedIdentifiers:(NSSet *)requestedIdentifiers {
    return [self performWithRequestedIdentifiers:requestedIdentifiers retryCount:0];
}

- (CYPackageTransactionResult) performWithRequestedIdentifiers:(NSSet *)requestedIdentifiers retryCount:(NSUInteger)retryCount {
    bool substrate(RestartSubstrate_);
    RestartSubstrate_ = false;

    NSString *title(UCLocalize("PERFORM_SELECTIONS"));

    if (manager_ == NULL || lock_ == NULL || !cache_.IsDepCacheBuilt() || cache_->BrokenCount() != 0) {
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent
            eventWithMessage:@"Package requirements must be resolved before applying changes. Review the package queue and try again."
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return CYPackageTransactionNotStarted;
    }

    NSMutableArray *before = [NSMutableArray arrayWithCapacity:16]; {
        pkgSourceList list;
        if ([self popErrorWithTitle:title forReadList:list])
            return CYPackageTransactionNotStarted;
        for (pkgSourceList::const_iterator source = list.begin(); source != list.end(); ++source)
            [before addObject:[NSString stringWithUTF8String:(*source)->GetURI().c_str()]];
    }

    for (pkgCache::PkgIterator iterator(cache_->PkgBegin()); !iterator.end(); ++iterator) {
        pkgDepCache::StateCache &state(cache_[iterator]);
        if (state.Mode == pkgDepCache::ModeInstall && CYRootlessBlockedLegacyPackage(iterator.Name())) {
            NSString *message([NSString stringWithFormat:@"Blocked rootful-only package %s before dpkg execution.", iterator.Name()]);
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:message ofType:kCydiaProgressEventTypeError] forTask:title];
            return CYPackageTransactionNotStarted;
        }
    }

    [delegate_ performSelectorOnMainThread:@selector(retainNetworkActivityIndicator) withObject:nil waitUntilDone:YES];

    // GetArchives has already created a fetcher containing only the package
    // archives for this transaction. Temporarily select the device-aware HTTPS
    // method for that synchronous run, then restore the bootstrap method before
    // any later Sources/Release refresh. This avoids a global protocol override.
    _config->Set("Dir::Bin::Methods::https", CydiaPackageHTTPSMethod_);
    CYRootlessDiag(@"APT", @"https-method=embedded-ios-aware scope=package-archives-only transport=https headers=User-Agent,X-Firmware,X-Machine,X-Unique-ID,Sec-CH-UA,Sec-CH-UA-Platform,Sec-CH-UA-Platform-Version,Sec-CH-UA-Arch,Sec-CH-UA-Bitness,Sec-CH-UA-Model values=not-logged verification=apt-gpg-hash-size");
    pkgAcquire::RunResult fetchResult(fetcher_->Run(PulseInterval_));
    _config->Set("Dir::Bin::Methods::https", StandardHTTPSMethod_);
    CYRootlessDiag(@"APT", @"https-method=bootstrap-modern scope=source-metadata restored=1");

    // Balance activity on every exit, including cancellation and transport failure.
    [delegate_ performSelectorOnMainThread:@selector(releaseNetworkActivityIndicator) withObject:nil waitUntilDone:YES];
    bool cancelled([[self safeProgressDelegate] isProgressCancelled]);
    if (fetchResult != pkgAcquire::Continue || cancelled) {
        _trace();
        bool reported([self popErrorWithTitle:title]);
        if (fetchResult != pkgAcquire::Cancelled && !cancelled && !reported)
            [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent
                eventWithMessage:@"Package downloads could not be completed. Try again."
                ofType:kCydiaProgressEventTypeError] forTask:title];
        CYClearSensitiveDownloadURLs();
        return CYPackageTransactionNotStarted;
    }

    bool failed = false;
    for (pkgAcquire::ItemIterator item = fetcher_->ItemsBegin(); item != fetcher_->ItemsEnd(); item++) {
        if ((*item)->Status == pkgAcquire::Item::StatDone && (*item)->Complete)
            continue;
        if ((*item)->Status == pkgAcquire::Item::StatIdle)
            continue;

        std::string uri = (*item)->DescURI();
        std::string error = (*item)->ErrorText;

        NSString *diagnosticError(CYSanitizeDownloadText([NSString stringWithUTF8String:error.c_str()]));
        CYRootlessDiag(@"DOWNLOAD", @"level=ERROR uri=%@ httpStatus=%d message=%@",
            CYDiagnosticURLString(uri), CYHTTPStatusFromAcquireError(error),
            diagnosticError ?: @"<non-UTF8 error>");
        lprintf("pAf:%s:%s\n", [CYDiagnosticURLString(uri) UTF8String], [diagnosticError UTF8String]);
        failed = true;

        CydiaProgressEvent *event([CydiaProgressEvent eventWithMessage:diagnosticError ofType:kCydiaProgressEventTypeError]);
        [delegate_ addProgressEventOnMainThread:event forTask:title];
    }

    CYClearSensitiveDownloadURLs();

    if (failed) {
        _trace();
        return CYPackageTransactionNotStarted;
    }

    if (![delock_ isEqual:GetStatusDate()]) {
        if (retryCount == 0 && [self rebuildTransactionForRequestedIdentifiers:requestedIdentifiers title:title]) {
            CYRootlessDiag(@"DPKG_LOCK", @"automatic retry start attempt=1 maxAttempts=1");
            CYPackageTransactionResult result([self performWithRequestedIdentifiers:requestedIdentifiers retryCount:1]);
            if (substrate && result != CYPackageTransactionNotStarted)
                RestartSubstrate_ = true;
            return result;
        }
        CYRootlessDiag(@"DPKG_LOCK", @"level=ERROR status changed before commit retryCount=%lu automaticRecoveryAvailable=%d",
            (unsigned long) retryCount, [requestedIdentifiers count] != 0);
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent eventWithMessage:UCLocalize("DPKG_LOCKED") ofType:kCydiaProgressEventTypeError] forTask:title];
        return CYPackageTransactionNotStarted;
    }

    // Stop() has already disabled the Cancel button on the main thread.
    // Honor every cancellation accepted before that transition, even if APT
    // finished its last download before the next periodic cancellation pulse.
    if ([[self safeProgressDelegate] isProgressCancelled])
        return CYPackageTransactionNotStarted;
    if (substrate)
        RestartSubstrate_ = true;
    delock_ = nil;

    // Persist a crash marker before the first dpkg child starts.  If Cydia is
    // killed by a package upgrade, a respring, or a third-party tweak while
    // dpkg has already changed the live status database, the next launch must
    // not reuse the pre-transaction pkgcache and offer those versions again.
    NSString *transactionMarker(Cache("dpkg-transaction.incomplete"));
    int marker(creat([transactionMarker UTF8String], 0600));
    if (marker == -1)
        CYRootlessDiag(@"DPKG", @"level=WARN transaction marker create failed errno=%d", errno);
    else {
        close(marker);
        CYRootlessDiag(@"DPKG", @"transaction marker armed");
    }

    pkgPackageManager::OrderResult result(manager_->DoInstall(statusfd_));
    CYRootlessDiag(@"DPKG", @"DoInstall result=%d", (int) result);

    // pkgDPkgPM invalidates APT's binary cache before returning on both
    // success and an ordinary reported failure.  Only an abnormal process
    // termination should leave this marker for launch-time recovery.
    if (unlink([transactionMarker UTF8String]) == -1 && errno != ENOENT)
        CYRootlessDiag(@"DPKG", @"level=WARN transaction marker clear failed errno=%d", errno);
    else
        CYRootlessDiag(@"DPKG", @"transaction marker cleared");

    NSString *oextended(@"/var/jb/var/lib/apt/extended_states");
    NSString *nextended(Cache("extended_states"));

    struct stat info;
    if (stat([nextended UTF8String], &info) != -1 && (info.st_mode & S_IFMT) == S_IFREG)
        system([[NSString stringWithFormat:@"/var/jb/usr/libexec/cydia/cydo /var/jb/bin/cp --remove-destination %@ %@", ShellEscape(nextended), ShellEscape(oextended)] UTF8String]);

    unlink([nextended UTF8String]);
    symlink([oextended UTF8String], [nextended UTF8String]);

    if ([self popErrorWithTitle:title])
        return CYPackageTransactionAttempted;

    if (result != pkgPackageManager::Completed) {
        _trace();
        [delegate_ addProgressEventOnMainThread:[CydiaProgressEvent
            eventWithMessage:@"Package changes did not finish. Review the details before trying again."
            ofType:kCydiaProgressEventTypeError] forTask:title];
        return CYPackageTransactionAttempted;
    }

    NSMutableArray *after = [NSMutableArray arrayWithCapacity:16]; {
        pkgSourceList list;
        if ([self popErrorWithTitle:title forReadList:list])
            return CYPackageTransactionAttempted;
        for (pkgSourceList::const_iterator source = list.begin(); source != list.end(); ++source)
            [after addObject:[NSString stringWithUTF8String:(*source)->GetURI().c_str()]];
    }

    if (![before isEqualToArray:after] && Finish_ == 0)
        [self update];
    return CYPackageTransactionCompleted;
}

- (bool) delocked {
    return ![delock_ isEqual:GetStatusDate()];
}

- (bool) upgrade {
    if (![self ready])
        return false;
    NSString *title(UCLocalize("UPGRADE"));
    if ([self popErrorWithTitle:title forOperation:pkgDistUpgrade(cache_)])
        return false;

    // Old rootful transition packages such as firmware-sbin may
    // advertise Replaces against bootstrap components and get pulled into a
    // dist-upgrade despite being Architecture: all. Keep them out of the
    // queue; normal dependency handling will then surface any real conflict.
    for (pkgCache::PkgIterator iterator(cache_->PkgBegin()); !iterator.end(); ++iterator) {
        if (!CYRootlessBlockedLegacyPackage(iterator.Name()))
            continue;
        pkgDepCache::StateCache &state(cache_[iterator]);
        if (state.Mode == pkgDepCache::ModeInstall) {
            cache_->SetReInstall(iterator, false);
            cache_->MarkKeep(iterator, false);
            lprintf("W:[rootless transaction safety: removed %s from dist-upgrade queue]\n", iterator.Name());
        }
    }

    return true;
}

- (void) update {
    [self updateWithStatus:status_];
}

- (bool) updateWithStatus:(CancelStatus &)status {
    return [self updateWithStatus:status sourceKey:nil];
}

- (bool) updateWithStatus:(CancelStatus &)status sourceKey:(NSString *)sourceKey {
    NSString *title(UCLocalize("REFRESHING_DATA"));
    uint64_t diagnosticsStart(_timestamp);
    CYRootlessDiag(@"REFRESH", @"begin");

    pkgSourceList list;
    if ([self popErrorWithTitle:title forReadList:list]) {
        CYRootlessDiag(@"REFRESH", @"end status=failed phase=read-sources durationMs=%llu", (unsigned long long) ((_timestamp - diagnosticsStart) / 1000));
        if (sourceKey == nil)
            CYStoreRepositoryVerificationState(false, false);
        return false;
    }

    metaIndex *selected(NULL);
    size_t matchingURIEntries(0);
    if (sourceKey != nil) {
        for (metaIndex *entry : list) {
            NSString *key([NSString stringWithFormat:@"%s:%s:%s", entry->GetType(),
                entry->GetURI().c_str(), entry->GetDist().c_str()]);
            if ([key isEqualToString:sourceKey]) {
                selected = entry;
                break;
            }
        }
        // The owner may have removed the source since the swipe opened.
        // Never fall back to refreshing all repositories for a stale key.
        if (selected == NULL)
            return false;
        for (metaIndex *entry : list)
            if (CYSourceIdentity::CanonicalURI(entry->GetURI()) ==
                CYSourceIdentity::CanonicalURI(selected->GetURI()))
                ++matchingURIEntries;
    }

    size_t sourceCount(0);
    std::set<std::string> sourceRoots;
    size_t externalCount(0);
    for (pkgSourceList::const_iterator source = list.begin(); source != list.end(); ++source) {
        if (selected != NULL && *source != selected)
            continue;
        ++sourceCount;
        std::string uri((*source)->GetURI());
        const std::string canonical(CYSourceIdentity::CanonicalURI(uri));
        bool managed(CYIsCydiaManagedSourceURI(uri));
        sourceRoots.insert(uri);
        if (!managed)
            ++externalCount;
        CYRootlessDiag(@"SOURCE_OWNERSHIP", @"owner=%@ uri=%@ canonical=%@ sourceLocalIsolationEligible=1",
            managed ? @"Cydia" : @"external",
            CYDiagnosticURLString(uri), CYDiagnosticURLString(canonical));
    }
    CYRootlessDiag(@"REFRESH", @"sourceEntries=%zu externalEntries=%zu", sourceCount, externalCount);

    // One acquire object owns the lists lock through error processing and
    // cache repair. FileFd(-1, true) is an error, not an empty lock wrapper;
    // opening this lock twice also lets the inner close release both locks.
    pkgAcquire fetcher(&status);
    bool locked(fetcher.GetLock(_config->FindDir("Dir::State::Lists")));
    bool lockError([self popErrorWithTitle:title]);
    if (!locked || lockError) {
        CYRootlessDiag(@"REFRESH", @"end status=failed phase=lists-lock durationMs=%llu", (unsigned long long) ((_timestamp - diagnosticsStart) / 1000));
        if (sourceKey == nil)
            CYStoreRepositoryVerificationState(false, false);
        return false;
    }

    [delegate_ performSelectorOnMainThread:@selector(retainNetworkActivityIndicator) withObject:nil waitUntilDone:YES];

    // Keep the full list alive to preserve the parsed components, architecture
    // filters and signing options. Enqueue only this source; do not run the
    // all-source cleanup or hooks against a one-source acquisition queue.
    bool fullRefresh(selected == NULL);
    bool enqueued(fullRefresh ? list.GetIndexes(&fetcher) : selected->GetIndexes(&fetcher, false));
    bool success(enqueued && AcquireUpdate(fetcher, PulseInterval_, fullRefresh, fullRefresh));
    bool cancelled(status.WasCancelled());
    bool fatal(false);
    bool sourceIsolated(false);
    size_t isolatedFailures(0);
    NSMutableDictionary *sourceIssues([NSMutableDictionary dictionary]);
    size_t quarantined(0);
    if (cancelled)
        _error->Discard();
    else {
        fatal = [self popRefreshErrorsWithTitle:title forOperation:success
            sourceRoots:&sourceRoots isolated:&sourceIsolated failures:&isolatedFailures
            sourceIssues:sourceIssues];

        quarantined = CYQuarantineMalformedPackageLists();
        if (quarantined != 0) {
            CYRootlessDiag(@"REFRESH", @"level=WARN quarantinedMalformedLists=%zu", quarantined);
            lprintf("W:[rootless list safety: quarantined %zu malformed Packages index(es) after Refresh]\n", quarantined);
        }

    }

    // A source-local rejection is still usable when APT retained the prior
    // cache (or no index). Record it separately from a complete refresh so
    // Home never overstates the result.
    bool usable(!cancelled && !fatal && quarantined == 0 && (success || sourceIsolated));
    bool verified(usable && success && !sourceIsolated && isolatedFailures == 0);
    if (selected == NULL)
        CYStoreRepositoryVerificationState(verified, usable,
            usable ? isolatedFailures : 0, sourceIssues);
    else if (!cancelled)
        CYStoreSingleRepositoryRefreshState([NSString stringWithUTF8String:selected->GetURI().c_str()],
            verified, usable, matchingURIEntries == 1, sourceIssues);

    [delegate_ performSelectorOnMainThread:@selector(releaseNetworkActivityIndicator) withObject:nil waitUntilDone:YES];
    CYRootlessDiag(@"REFRESH", @"end status=%@ listUpdateSuccess=%d fatal=%d cancelled=%d sourceIsolated=%d isolatedFailures=%zu quarantined=%zu durationMs=%llu",
        cancelled ? @"cancelled" : (!fatal ? (sourceIsolated ? @"ok-source-isolated" : @"ok") : @"failed"),
        success, fatal, cancelled, sourceIsolated, isolatedFailures, quarantined,
        (unsigned long long) ((_timestamp - diagnosticsStart) / 1000));
    // Callers use this return value specifically for the green
    // "Ready and verified" state. A source-isolated refresh is usable, but it
    // is not a fully verified refresh and must therefore return false here.
    return verified;
}

- (void) setDelegate:(NSObject<DatabaseDelegate> *)delegate {
    @synchronized (self) {
        delegate_ = delegate;
    }
}

- (void) setProgressDelegate:(NSObject<ProgressDelegate> *)delegate {
    @synchronized (self) {
        progress_ = delegate;
    }
    status_.setDelegate(delegate);
}

// The dpkg reader threads live for the whole process and message these
// transient (non-retained) delegates. Hand them a retained+autoreleased
// reference under the same lock the setters use, so a delegate that is being
// torn down at the end of a transaction can never be messaged after it is
// freed (the historical background-thread crash at transaction completion).
- (NSObject<ProgressDelegate> *) safeProgressDelegate {
    @synchronized (self) {
        return [[progress_ retain] autorelease];
    }
}

- (NSObject<DatabaseDelegate> *) safeDatabaseDelegate {
    @synchronized (self) {
        return [[delegate_ retain] autorelease];
    }
}

- (NSObject<ProgressDelegate> *) progressDelegate {
    return progress_;
}

- (Source *) getSource:(pkgCache::PkgFileIterator)file {
    SourceMap::const_iterator i(sourceMap_.find(file->ID));
    return i == sourceMap_.end() ? nil : i->second;
}

- (void) setFetch:(bool)fetch forURI:(const char *)uri {
    for (Source *source in (id) sourceList_)
        [source setFetch:fetch forURI:uri];
}

- (void) resetFetch {
    for (Source *source in (id) sourceList_)
        [source resetFetch];
}

- (NSString *) mappedSectionForPointer:(const char *)section {
    _H<NSString> *mapped;

    _profile(Database$mappedSectionForPointer$Cache)
        mapped = &sections_[section];
    _end

    if (*mapped == NULL) {
        size_t length(strlen(section));
        std::vector<char> spaced(length + 1, '\0');

        _profile(Database$mappedSectionForPointer$Replace)
            for (size_t index(0); index != length; ++index)
                spaced[index] = section[index] == '_' ? ' ' : section[index];
            spaced[length] = '\0';
        _end

        NSString *string;

        _profile(Database$mappedSectionForPointer$stringWithUTF8String)
            string = [NSString stringWithUTF8String:spaced.data()];
        _end

        _profile(Database$mappedSectionForPointer$Map)
            string = [SectionMap_ objectForKey:string] ?: string;
        _end

        *mapped = string;
    } return *mapped;
}

@end
/* }}} */

@interface CydiaObject : CyteObject {
    _transient id delegate_;
}

@end

@interface CydiaWebViewController : CyteWebViewController {
    _H<CydiaObject> cydia_;
}

+ (NSURLRequest *) requestWithHeaders:(NSURLRequest *)request;
+ (void) didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame withCydia:(CydiaObject *)cydia;
- (void) setDelegate:(id)delegate;

@end

/* Web Scripting {{{ */
@implementation CydiaObject

- (void) setDelegate:(id)delegate {
    delegate_ = delegate;
}

- (NSArray *) attributeKeys {
    return [[NSArray arrayWithObjects:
        @"cells",
        @"device",
        @"mcc",
        @"mnc",
        @"operator",
        @"role",
        @"version",
    nil] arrayByAddingObjectsFromArray:[super attributeKeys]];
}

- (NSString *) version {
    return Cydia_;
}

- (NSString *) device {
    return UniqueIdentifier();
}

- (NSArray *) cells {
    auto *$_CTServerConnectionCreate(reinterpret_cast<id (*)(void *, void *, void *)>(dlsym(RTLD_DEFAULT, "_CTServerConnectionCreate")));
    if ($_CTServerConnectionCreate == NULL)
        return nil;

    struct CTResult { int flag; int error; };
    auto *$_CTServerConnectionCellMonitorCopyCellInfo(reinterpret_cast<CTResult (*)(CFTypeRef, void *, CFArrayRef *)>(dlsym(RTLD_DEFAULT, "_CTServerConnectionCellMonitorCopyCellInfo")));
    if ($_CTServerConnectionCellMonitorCopyCellInfo == NULL)
        return nil;

    _H<const void> connection($_CTServerConnectionCreate(NULL, NULL, NULL), true);
    if (connection == nil)
        return nil;

    int count(0);
    CFArrayRef cells(NULL);
    auto result($_CTServerConnectionCellMonitorCopyCellInfo(connection, &count, &cells));
    if (result.flag != 0)
        return nil;

    return [(NSArray *) cells autorelease];
}

- (NSString *) mcc {
    if (CFStringRef (*$CTSIMSupportCopyMobileSubscriberCountryCode)(CFAllocatorRef) = reinterpret_cast<CFStringRef (*)(CFAllocatorRef)>(dlsym(RTLD_DEFAULT, "CTSIMSupportCopyMobileSubscriberCountryCode")))
        return [(NSString *) (*$CTSIMSupportCopyMobileSubscriberCountryCode)(kCFAllocatorDefault) autorelease];
    return nil;
}

- (NSString *) mnc {
    if (CFStringRef (*$CTSIMSupportCopyMobileSubscriberNetworkCode)(CFAllocatorRef) = reinterpret_cast<CFStringRef (*)(CFAllocatorRef)>(dlsym(RTLD_DEFAULT, "CTSIMSupportCopyMobileSubscriberNetworkCode")))
        return [(NSString *) (*$CTSIMSupportCopyMobileSubscriberNetworkCode)(kCFAllocatorDefault) autorelease];
    return nil;
}

- (NSString *) operator {
    if (CFStringRef (*$CTRegistrationCopyOperatorName)(CFAllocatorRef) = reinterpret_cast<CFStringRef (*)(CFAllocatorRef)>(dlsym(RTLD_DEFAULT, "CTRegistrationCopyOperatorName")))
        return [(NSString *) (*$CTRegistrationCopyOperatorName)(kCFAllocatorDefault) autorelease];
    return nil;
}

- (NSString *) role {
    return (id) [NSNull null];
}

+ (NSString *) webScriptNameForSelector:(SEL)selector {
    if (false);
    else if (selector == @selector(addSource:::))
        return @"addSource";
    else if (selector == @selector(addTrivialSource:))
        return @"addTrivialSource";
    else if (selector == @selector(du:))
        return @"du";
    else if (selector == @selector(getAllSources))
        return @"getAllSources";
    else if (selector == @selector(getApplicationInfo:value:))
        return @"getApplicationInfoValue";
    else if (selector == @selector(getDisplayIdentifiers))
        return @"getDisplayIdentifiers";
    else if (selector == @selector(getLocalizedNameForDisplayIdentifier:))
        return @"getLocalizedNameForDisplayIdentifier";
    else if (selector == @selector(getInstalledPackages))
        return @"getInstalledPackages";
    else if (selector == @selector(getPackageById:))
        return @"getPackageById";
    else if (selector == @selector(getMetadataKeys))
        return @"getMetadataKeys";
    else if (selector == @selector(getMetadataValue:))
        return @"getMetadataValue";
    else if (selector == @selector(getSessionValue:))
        return @"getSessionValue";
    else if (selector == @selector(installPackages:))
        return @"installPackages";
    else if (selector == @selector(refreshSources))
        return @"refreshSources";
    else if (selector == @selector(saveConfig))
        return @"saveConfig";
    else if (selector == @selector(setMetadataValue::))
        return @"setMetadataValue";
    else if (selector == @selector(setSessionValue::))
        return @"setSessionValue";
    else if (selector == @selector(substitutePackageNames:))
        return @"substitutePackageNames";
    else if (selector == @selector(setToken:))
        return @"setToken";
    else
        return nil;
}

+ (BOOL) isSelectorExcludedFromWebScript:(SEL)selector {
    return [self webScriptNameForSelector:selector] == nil;
}

- (NSDictionary *) getApplicationInfo:(NSString *)display value:(NSString *)key {
    char path[1024];
    if (SBBundlePathForDisplayIdentifier(SBSSpringBoardServerPort(), [display UTF8String], path) != 0)
        return (id) [NSNull null];
    NSDictionary *info([NSDictionary dictionaryWithContentsOfFile:[[NSString stringWithUTF8String:path] stringByAppendingString:@"/Info.plist"]]);
    if (info == nil)
        return (id) [NSNull null];
    return [info objectForKey:key];
}

- (NSArray *) getDisplayIdentifiers {
    return SBSCopyApplicationDisplayIdentifiers(false, false);
}

- (NSString *) getLocalizedNameForDisplayIdentifier:(NSString *)identifier {
    return [SBSCopyLocalizedApplicationNameForDisplayIdentifier(identifier) autorelease] ?: (id) [NSNull null];
}

- (NSNumber *) getKernelNumber:(NSString *)name {
    const char *string([name UTF8String]);

    size_t size;
    if (sysctlbyname(string, NULL, &size, NULL, 0) == -1)
        return (id) [NSNull null];

    if (size != sizeof(int))
        return (id) [NSNull null];

    int value;
    if (sysctlbyname(string, &value, &size, NULL, 0) == -1)
        return (id) [NSNull null];

    return [NSNumber numberWithInt:value];
}

- (NSArray *) getMetadataKeys {
@synchronized (Values_) {
    return [Values_ allKeys];
} }

- (id) getMetadataValue:(NSString *)key {
@synchronized (Values_) {
    return [Values_ objectForKey:key];
} }

- (void) setMetadataValue:(NSString *)key :(NSString *)value {
@synchronized (Values_) {
    if (value == nil || value == (id) [WebUndefined undefined] || value == (id) [NSNull null])
        [Values_ removeObjectForKey:key];
    else
        [Values_ setObject:value forKey:key];
} }

- (id) getSessionValue:(NSString *)key {
@synchronized (SessionData_) {
    return [SessionData_ objectForKey:key];
} }

- (void) setSessionValue:(NSString *)key :(NSString *)value {
@synchronized (SessionData_) {
    if (value == (id) [WebUndefined undefined])
        [SessionData_ removeObjectForKey:key];
    else
        [SessionData_ setObject:value forKey:key];
} }

- (void) addSource:(NSString *)href :(NSString *)distribution :(WebScriptObject *)sections {
    NSMutableArray *array([NSMutableArray arrayWithCapacity:[sections count]]);

    for (NSString *section in sections)
        [array addObject:section];

    [delegate_ performSelectorOnMainThread:@selector(addSource:) withObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"deb", @"Type",
        href, @"URI",
        distribution, @"Distribution",
        array, @"Sections",
    nil] waitUntilDone:NO];
}

- (BOOL) addTrivialSource:(NSString *)href {
    href = VerifySource(href);
    if (href == nil)
        return NO;
    [delegate_ performSelectorOnMainThread:@selector(addTrivialSource:) withObject:href waitUntilDone:NO];
    return YES;
}

- (void) refreshSources {
    [delegate_ performSelectorOnMainThread:@selector(syncData) withObject:nil waitUntilDone:NO];
}

- (void) saveConfig {
    [delegate_ performSelectorOnMainThread:@selector(_saveConfig) withObject:nil waitUntilDone:NO];
}

- (NSArray *) getAllSources {
    return [[Database sharedInstance] sources];
}

- (NSArray *) getInstalledPackages {
    Database *database([Database sharedInstance]);
@synchronized (database) {
    NSArray *packages([database packages]);
    NSMutableArray *installed([NSMutableArray arrayWithCapacity:1024]);
    for (Package *package in packages)
        if (![package uninstalled])
            [installed addObject:package];
    return installed;
} }

- (Package *) getPackageById:(NSString *)id {
    if (Package *package = [[Database sharedInstance] packageWithName:id]) {
        [package parse];
        return package;
    } else
        return (Package *) [NSNull null];
}

- (NSNumber *) du:(NSString *)path {
    NSNumber *value(nil);

    FILE *du(popen([[NSString stringWithFormat:@"/var/jb/usr/libexec/cydia/cydo /var/jb/usr/libexec/cydia/du -ks %@", ShellEscape(path)] UTF8String], "r"));
    if (du != NULL) {
        char line[1024];
        while (fgets(line, sizeof(line), du) != NULL) {
            size_t length(strlen(line));
            while (length != 0 && line[length - 1] == '\n')
                line[--length] = '\0';
            if (char *tab = strchr(line, '\t')) {
                *tab = '\0';
                value = [NSNumber numberWithUnsignedLong:strtoul(line, NULL, 0)];
            }
        }
        pclose(du);
    }

    return value;
}

- (void) installPackages:(NSArray *)packages {
    [delegate_ performSelectorOnMainThread:@selector(installPackages:) withObject:packages waitUntilDone:NO];
}

- (NSString *) substitutePackageNames:(NSString *)message {
    auto database([Database sharedInstance]);

    // XXX: this check is less racy than you'd expect, but this entire concept is a little awkward
    if (![database hasPackages])
        return message;

    NSMutableArray *words([[[message componentsSeparatedByString:@" "] mutableCopy] autorelease]);
    for (size_t i(0), e([words count]); i != e; ++i) {
        NSString *word([words objectAtIndex:i]);
        if (Package *package = [database packageWithName:word])
            [words replaceObjectAtIndex:i withObject:[package name]];
    }

    return [words componentsJoinedByString:@" "];
}

- (void) setToken:(NSString *)token {
    // XXX: the website expects this :/
}

@end
/* }}} */

@interface NSURL (CydiaSecure)
@end

@implementation NSURL (CydiaSecure)

- (bool) isCydiaSecure {
    return [[[self scheme] lowercaseString] isEqualToString:@"https"];
}

@end

/* Cydia Browser Controller {{{ */
@implementation CydiaWebViewController

- (NSURL *) navigationURL {
    if (NSURLRequest *request = self.request)
        return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://url/%@", [[request URL] absoluteString]]];
    else
        return nil;
}

- (void) webView:(WebView *)view didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame {
    [super webView:view didClearWindowObject:window forFrame:frame];
    [CydiaWebViewController didClearWindowObject:window forFrame:frame withCydia:cydia_];
}

+ (void) didClearWindowObject:(WebScriptObject *)window forFrame:(WebFrame *)frame withCydia:(CydiaObject *)cydia {
    WebDataSource *source([frame dataSource]);
    NSURLResponse *response([source response]);
    NSURL *url([response URL]);
    NSString *scheme([[url scheme] lowercaseString]);

    // Only bundled local documents may access native package-management APIs.
    // Remote HTTPS content remains display-only, even when it comes from the
    // historical Cydia host.
    if ([scheme isEqualToString:@"file"])
        [window setValue:cydia forKey:@"cydia"];
}

- (void) _setupMail:(MFMailComposeViewController *)controller {
    // Diagnostics showed that execution stopped inside this method. The original
    // implementation synchronously ran dpkg on the main thread and passed
    // possibly-nil NSData to MessageUI.  Support must never be blocked by an
    // optional attachment. Attach only files that already exist and are valid.
    CYRootlessDiag(@"SUPPORT", @"_setupMail begin");

    NSData *cydiaLog([NSData dataWithContentsOfFile:@"/tmp/cydia.log"]);
    if (cydiaLog != nil && [cydiaLog length] != 0) {
        [controller addAttachmentData:cydiaLog mimeType:@"text/plain" fileName:@"cydia.log"];
        CYRootlessDiag(@"SUPPORT", @"attached cydia.log bytes=%lu", (unsigned long) [cydiaLog length]);
    }

    // If a prior dpkg listing exists, keep the historical attachment without
    // blocking the UI to regenerate it synchronously.
    NSData *dpkgLog([NSData dataWithContentsOfFile:@"/tmp/dpkgl.log"]);
    if (dpkgLog != nil && [dpkgLog length] != 0)
        [controller addAttachmentData:dpkgLog mimeType:@"text/plain" fileName:@"dpkgl.log"];

    CYRootlessDiag(@"SUPPORT", @"_setupMail complete");
}

- (NSURLRequest *) webView:(WebView *)view resource:(id)resource willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response fromDataSource:(WebDataSource *)source {
    return [CydiaWebViewController requestWithHeaders:[super webView:view resource:resource willSendRequest:request redirectResponse:response fromDataSource:source]];
}

- (NSURLRequest *) webThreadWebView:(WebView *)view resource:(id)resource willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response fromDataSource:(WebDataSource *)source {
    return [CydiaWebViewController requestWithHeaders:[super webThreadWebView:view resource:resource willSendRequest:request redirectResponse:response fromDataSource:source]];
}

+ (NSURLRequest *) requestWithHeaders:(NSURLRequest *)request {
    NSMutableURLRequest *copy([[request mutableCopy] autorelease]);

    NSURL *url([copy URL]);
    NSString *href([url absoluteString]);

    if ([href hasPrefix:@"https://cydia.saurik.com/TSS/"]) {
        if (NSString *agent = [copy valueForHTTPHeaderField:@"X-User-Agent"]) {
            [copy setValue:agent forHTTPHeaderField:@"User-Agent"];
            [copy setValue:nil forHTTPHeaderField:@"X-User-Agent"];
        }

        [copy setValue:nil forHTTPHeaderField:@"Referer"];
        [copy setValue:nil forHTTPHeaderField:@"Origin"];

        [copy setURL:[NSURL URLWithString:[@"http://gs.apple.com/TSS/" stringByAppendingString:[href substringFromIndex:29]]]];
        return copy;
    }

    if ([copy valueForHTTPHeaderField:@"X-Cydia-Cf"] == nil)
        [copy setValue:[NSString stringWithFormat:@"%.2f", kCFCoreFoundationVersionNumber] forHTTPHeaderField:@"X-Cydia-Cf"];
    if (Machine_ != NULL && [copy valueForHTTPHeaderField:@"X-Machine"] == nil)
        [copy setValue:[NSString stringWithUTF8String:Machine_] forHTTPHeaderField:@"X-Machine"];

    return copy;
}

- (void) setDelegate:(id)delegate {
    [super setDelegate:delegate];
    [cydia_ setDelegate:delegate];
}

- (id) init {
    if ((self = [super initWithWidth:0 ofClass:[CydiaWebViewController class]]) != nil) {
        cydia_ = [[[CydiaObject alloc] initWithDelegate:self.indirect] autorelease];
    } return self;
}

@end

/* }}} */

/* Confirmation Controller {{{ */
const char *DepSubstrateIdentifier(const pkgCache::VerIterator &iterator) {
    if (!iterator.end())
        for (pkgCache::DepIterator dep(iterator.DependsList()); !dep.end(); ++dep) {
            if (dep->Type != pkgCache::Dep::Depends && dep->Type != pkgCache::Dep::PreDepends)
                continue;
            pkgCache::PkgIterator package(dep.TargetPkg());
            if (package.end())
                continue;
            if (CYInjectionCompatibility::IsInjectionDependency(package.Name()))
                return package.Name();
        }

    return NULL;
}

bool DepSubstrate(const pkgCache::VerIterator &iterator) {
    return DepSubstrateIdentifier(iterator) != NULL;
}

static const char *CYDetectedInjectionProvider(pkgCacheFile &cache) {
    static const char *providers[] = {
        "ellekit",
        "org.coolstar.libhooker",
        "com.ex.substitute",
        "mobilesubstrate",
        NULL
    };
    for (size_t index(0); providers[index] != NULL; ++index) {
        pkgCache::PkgIterator package(cache->FindPkg(providers[index]));
        if (package.end())
            continue;
        pkgDepCache::StateCache &state(cache[package]);
        if (!package.CurrentVer().end() || state.Mode == pkgDepCache::ModeInstall)
            return providers[index];
    }
    return NULL;
}

static NSString *const CYModernPackageIconDidLoadNotification = @"CYModernPackageIconDidLoad";
static NSCache *CYModernPackageIconCache(void);
static void CYPersistModernPackageIcon(NSString *address, NSData *data);
static UIImage *CYModernPackageIconFromDisk(NSString *address);
static UIImage *CYPreparedPackageIcon(NSData *data, CGFloat scale);
static NSUInteger CYPackageIconMemoryCost(UIImage *image);

@protocol ConfirmationControllerDelegate
- (void) cancelAndClear:(bool)clear;
- (void) confirmWithNavigationController:(UINavigationController *)navigation;
- (void) queue;
- (bool) requestUpdate;
- (bool) requestUpdateForSourceKey:(NSString *)sourceKey;
@end

static UIView *CYModernNativeControllerRoot(NSString *surface) {
    UIView *root([[[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease]);
    [root setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
    [root setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    CYRootlessDiag(@"WEBVIEW", @"action=skipped surface=%@ reason=native-surface-ios17-timer-safety", surface);
    return root;
}

@interface ConfirmationController : CydiaWebViewController {
    _transient Database *database_;

    _H<UIAlertView> essential_;

    _H<NSDictionary> changes_;
    _H<NSDictionary> dependencyActions_;
    _H<NSMutableDictionary> reviewPackages_;
    _H<NSMutableDictionary> reviewVersions_;
    _H<NSSet> requestedIdentifiers_;
    _H<NSMutableArray> issues_;
    _H<NSDictionary> sizes_;

    _H<CydiaModernConfirmationView> modernConfirmationView_;

    BOOL substrate_;
    BOOL confirmationStarted_;
}

- (id) initWithDatabase:(Database *)database;
- (id) initWithDatabase:(Database *)database requestedIdentifiers:(NSSet *)requestedIdentifiers;

@end

@implementation ConfirmationController

- (void) loadView {
    [self setView:CYModernNativeControllerRoot(@"confirmation")];
}

- (void) updateModernConfirmationView {
    if (modernConfirmationView_ == nil || changes_ == nil)
        return;

    NSMutableArray *parts([NSMutableArray arrayWithCapacity:6]);
    NSMutableArray *sections([NSMutableArray arrayWithCapacity:6]);
    NSMutableSet *issueIdentifiers([NSMutableSet set]);
    for (NSDictionary *issue in (NSArray *) issues_) {
        NSString *identifier(CYConfirmationString([issue objectForKey:@"package"]));
        if ([identifier length] != 0)
            [issueIdentifiers addObject:identifier];
        for (NSDictionary *reason in [issue objectForKey:@"reasons"])
            for (NSDictionary *clause in [reason objectForKey:@"clauses"]) {
                NSString *dependency(CYConfirmationString([clause objectForKey:@"package"]));
                if ([dependency length] != 0)
                    [issueIdentifiers addObject:dependency];
            }
    }
    // Use the existing package snapshot: packageWithName: may change APT's
    // candidate selection, which issue presentation must never do.
    NSMutableDictionary *issuePackages([NSMutableDictionary dictionary]);
    if ([issueIdentifiers count] != 0)
        for (Package *package in [database_ packages])
            if ([issueIdentifiers containsObject:[package id]])
                [issuePackages setObject:package forKey:[package id]];
    [sections addObjectsFromArray:CYConfirmationIssueSections(issues_, ^NSDictionary *(NSString *identifier) {
        Package *package([issuePackages objectForKey:identifier]);
        Source *source([package source]);
        NSString *sourceName([source name]);
        NSString *sourceURI([source rooturi]);
        NSString *sourceDetail([sourceURI length] == 0 ? sourceName :
            ([sourceName length] == 0 || [sourceName isEqualToString:sourceURI] ? sourceURI :
                [NSString stringWithFormat:@"%@ (%@)", sourceName, sourceURI]));
        return @{@"name": [package name] ?: identifier, @"source": sourceDetail ?: @""};
    })];
    NSString *primaryAction(nil);
    NSString *primaryKey(nil);
    NSUInteger activeActions(0);
    NSUInteger packageCount(0);
    NSArray *keys([NSArray arrayWithObjects:@"installs", @"reinstalls", @"upgrades", @"dependencies", @"downgrades", @"removes", nil]);
    NSArray *labels([NSArray arrayWithObjects:UCLocalize("INSTALL"), UCLocalize("REINSTALL"), UCLocalize("UPGRADE"), CYLocalize(@"Dependencies"), UCLocalize("DOWNGRADE"), UCLocalize("REMOVE"), nil]);
    for (NSUInteger index(0); index != [keys count]; ++index) {
        NSString *key([keys objectAtIndex:index]);
        NSArray *identifiers([changes_ objectForKey:key]);
        NSUInteger count([identifiers count]);
        if (count == 0)
            continue;

        NSString *label([labels objectAtIndex:index]);
        primaryAction = label;
        primaryKey = key;
        ++activeActions;
        packageCount += count;
        [parts addObject:CYLocalizedMetric(label, count)];

        NSMutableArray *items([NSMutableArray arrayWithCapacity:count]);
        for (NSString *identifier in identifiers) {
            Package *package([reviewPackages_ objectForKey:identifier]);
            [package parse];

            NSString *name(package == nil ? identifier : [package name]);
            NSDictionary *versions([reviewVersions_ objectForKey:identifier]);
            NSString *latest([versions objectForKey:@"selected"]);
            NSString *installed([versions objectForKey:@"installed"]);
            NSString *dependencyAction([dependencyActions_ objectForKey:identifier]);
            NSString *detail(nil);
            if ([key isEqualToString:@"removes"] || [dependencyAction isEqualToString:UCLocalize("REMOVE")])
                detail = CYTransactionVersionDetail(installed, nil, dependencyAction);
            else {
                NSString *action([key isEqualToString:@"reinstalls"] ? UCLocalize("REINSTALL") : dependencyAction);
                detail = CYTransactionVersionDetail(installed, latest, action);
            }

            // Prefer the package's own artwork, read from the shared icon
            // cache/disk so the queue shows real icons immediately; fetch once
            // (and reload the queue) for a remote icon that is not cached yet.
            UIImage *icon(nil);
            if (package != nil) {
                NSURL *remoteIconURL([package remoteIconURL]);
                NSString *remoteIconAddress([remoteIconURL absoluteString]);
                if ([remoteIconAddress length] != 0) {
                    icon = [CYModernPackageIconCache() objectForKey:remoteIconAddress];
                    if (icon == nil)
                        icon = CYModernPackageIconFromDisk(remoteIconAddress);
                    if (icon == nil) {
                        NSString *requestedIdentifier([NSString stringWithString:identifier]);
                        NSURLRequest *request([NSURLRequest requestWithURL:remoteIconURL
                            cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:15.0]);
                        [[[NSURLSession sharedSession] dataTaskWithRequest:request
                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                NSHTTPURLResponse *http([response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *) response : nil);
                                if (error != nil || [http statusCode] != 200 || [data length] == 0 || [data length] > 3 * 1024 * 1024)
                                    return;
                                UIImage *downloaded(CYPreparedPackageIcon(data, [[UIScreen mainScreen] scale]));
                                if (downloaded == nil || [downloaded size].width < 2.0f || [downloaded size].height < 2.0f)
                                    return;
                                [CYModernPackageIconCache() setObject:downloaded forKey:remoteIconAddress cost:CYPackageIconMemoryCost(downloaded)];
                                CYPersistModernPackageIcon(remoteIconAddress, data);
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [[NSNotificationCenter defaultCenter]
                                        postNotificationName:CYModernPackageIconDidLoadNotification object:nil
                                        userInfo:[NSDictionary dictionaryWithObject:requestedIdentifier forKey:@"identifier"]];
                                });
                            }] resume];
                    }
                }
                if (icon == nil)
                    icon = [package icon];
            }
            if (icon == nil)
                icon = CYModernPackageFallbackIcon(nil, identifier);
            [items addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                name ?: identifier, @"name",
                detail ?: identifier, @"detail",
                icon, @"icon",
            nil]];
        }

        [sections addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            label, @"title",
            items, @"items",
            [NSNumber numberWithBool:[key isEqualToString:@"removes"]], @"destructive",
        nil]];
    }

    NSUInteger dependencyCount([[changes_ objectForKey:@"dependencies"] count]);
    NSUInteger requestedUpgradeCount([[changes_ objectForKey:@"upgrades"] count]);
    BOOL upgradeWithDependencies(requestedIdentifiers_ != nil && requestedUpgradeCount != 0 && dependencyCount != 0);
    NSString *operationTitle(upgradeWithDependencies ? UCLocalize("UPGRADE") : (activeActions == 1 ? primaryAction : CYLocalize(@"Package Changes")));
    NSString *summary(upgradeWithDependencies ? [NSString stringWithFormat:CYLocalize(@"%@  •  %@"),
        CYLocalizedMetric(CYLocalize(@"Upgrades"), requestedUpgradeCount),
        CYLocalizedMetric(CYLocalize(@"Dependencies"), dependencyCount)] :
        (activeActions == 1 ? CYLocalizedMetric(CYLocalize(@"Packages"), packageCount) :
        ([parts count] == 0 ? CYLocalize(@"No changes selected") : [parts componentsJoinedByString:@"  •  "])));
    NSString *actionTitle(upgradeWithDependencies ? UCLocalize("UPGRADE") : (activeActions == 1 ? primaryAction : CYLocalize(@"Apply Changes")));
    BOOL destructive(activeActions == 1 && [primaryKey isEqualToString:@"removes"]);
    long long downloading([[sizes_ objectForKey:@"downloading"] longLongValue]);
    NSString *download(packageCount == 0 || downloading <= 0 ? @"" : [NSString stringWithFormat:CYLocalize(@"Download size: %@"),
        [NSByteCountFormatter stringFromByteCount:downloading countStyle:NSByteCountFormatterCountStyleFile]]);

    [modernConfirmationView_ setSummaryTitle:operationTitle detail:summary download:download];
    [modernConfirmationView_ setSections:sections];
    NSMutableArray *warnings([NSMutableArray arrayWithCapacity:2]);
    if ([issues_ count] != 0)
        [warnings addObject:CYLocalizedMetric(CYLocalize(@"Package issues"), [issues_ count])];
    NSString *warning([warnings componentsJoinedByString:@" • "]);
    [modernConfirmationView_ setWarningText:warning];
    BOOL enabled(CYTransactionCanConfirm(changes_, issues_, confirmationStarted_));
    [modernConfirmationView_ setConfirmTitle:actionTitle destructive:destructive enabled:enabled target:self action:@selector(confirmButtonClicked)];
    NSString *symbol([primaryKey isEqualToString:@"removes"] ? @"trash" :
        [primaryKey isEqualToString:@"reinstalls"] ? @"arrow.triangle.2.circlepath" :
        [primaryKey isEqualToString:@"upgrades"] ? @"arrow.up.to.line" :
        [primaryKey isEqualToString:@"downgrades"] ? @"arrow.down.to.line" : @"arrow.down.circle");
    [modernConfirmationView_ setOperationSymbol:packageCount == 0 ? @"tray" : symbol];
    [[self view] bringSubviewToFront:modernConfirmationView_];
}

- (void) viewDidLoad {
    [super viewDidLoad];

    modernConfirmationView_ = [[[CydiaModernConfirmationView alloc] initWithFrame:CGRectZero] autorelease];
    [[self view] addSubview:modernConfirmationView_];
    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [[modernConfirmationView_ leadingAnchor] constraintEqualToAnchor:[[self view] leadingAnchor]],
        [[modernConfirmationView_ trailingAnchor] constraintEqualToAnchor:[[self view] trailingAnchor]],
        [[modernConfirmationView_ topAnchor] constraintEqualToAnchor:[[self view] topAnchor]],
        [[modernConfirmationView_ bottomAnchor] constraintEqualToAnchor:[[self view] bottomAnchor]],
    nil]];
    [self updateModernConfirmationView];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(modernPackageIconDidLoad:)
            name:CYModernPackageIconDidLoadNotification object:nil];
}

- (void) modernPackageIconDidLoad:(NSNotification *)notification {
    // Coalesce bursts of icon downloads into a single queue rebuild.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateModernConfirmationView) object:nil];
    [self performSelector:@selector(updateModernConfirmationView) withObject:nil afterDelay:0.15];
}

- (void) dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    CYModernizeNavigationController([self navigationController]);
    [[self navigationController] setModalInPresentation:YES];
    [[self navigationItem] setTitle:CYLocalize(@"Review Changes")];
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    [self updateModernConfirmationView];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (UIContentSizeCategoryIsAccessibilityCategory([[self traitCollection] preferredContentSizeCategory])) {
        UISheetPresentationController *sheet([[self navigationController] sheetPresentationController]);
        [sheet setSelectedDetentIdentifier:UISheetPresentationControllerDetentIdentifierLarge];
        [sheet setDetents:@[[UISheetPresentationControllerDetent largeDetent]]];
    }
}

- (void) complete {
    if (!CYTransactionCanConfirm(changes_, issues_, confirmationStarted_))
        return;
    confirmationStarted_ = YES;
    [self updateModernConfirmationView];
    if (substrate_)
        RestartSubstrate_ = true;
    [self.delegate confirmWithNavigationController:[self navigationController]];
}

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"remove"]) {
        if (button == [alert cancelButtonIndex])
            [self _doContinue];
        else if (button == [alert firstOtherButtonIndex]) {
            [self performSelector:@selector(complete) withObject:nil afterDelay:0];
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"unable"]) {
        [self.delegate cancelAndClear:YES];
        [self dismissModalViewControllerAnimated:YES];
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else {
        [super alertView:alert clickedButtonAtIndex:button];
    }
}

- (void) _doContinue {
    [self.delegate cancelAndClear:NO];
    [self dismissModalViewControllerAnimated:YES];
}

- (id) invokeDefaultMethodWithArguments:(NSArray *)args {
    [self performSelectorOnMainThread:@selector(_doContinue) withObject:nil waitUntilDone:NO];
    return nil;
}

- (id) initWithDatabase:(Database *)database {
    return [self initWithDatabase:database requestedIdentifiers:nil];
}

- (id) initWithDatabase:(Database *)database requestedIdentifiers:(NSSet *)requestedIdentifiers {
    if ((self = [super init]) != nil) {
        [[self navigationItem] setTitle:CYLocalize(@"Review Changes")];
        [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
        database_ = database;
        requestedIdentifiers_ = requestedIdentifiers;
        reviewPackages_ = [NSMutableDictionary dictionary];
        reviewVersions_ = [NSMutableDictionary dictionary];

        NSMutableArray *installs([NSMutableArray arrayWithCapacity:16]);
        NSMutableArray *reinstalls([NSMutableArray arrayWithCapacity:16]);
        NSMutableArray *upgrades([NSMutableArray arrayWithCapacity:16]);
        NSMutableArray *dependencies([NSMutableArray arrayWithCapacity:8]);
        NSMutableDictionary *dependencyActions([NSMutableDictionary dictionaryWithCapacity:8]);
        NSMutableArray *downgrades([NSMutableArray arrayWithCapacity:16]);
        NSMutableArray *removes([NSMutableArray arrayWithCapacity:16]);

        bool remove(false);

        pkgCacheFile &cache([database_ cache]);
        NSArray *packages([database_ packages]);
#ifdef __arm__
        pkgDepCache::Policy *policy([database_ policy]);
#endif

        issues_ = [NSMutableArray arrayWithCapacity:4];

        for (Package *package in packages) {
            pkgCache::PkgIterator iterator([package iterator]);
            NSString *name([package id]);

            if ([package broken]) {
                NSMutableArray *reasons([NSMutableArray arrayWithCapacity:4]);

                [issues_ addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    name, @"package",
                    reasons, @"reasons",
                nil]];

                pkgCache::VerIterator ver(cache[iterator].InstVerIter(cache));
                if (ver.end())
                    continue;

                for (pkgCache::DepIterator dep(ver.DependsList()); !dep.end(); ) {
                    pkgCache::DepIterator start;
                    pkgCache::DepIterator end;
                    dep.GlobOr(start, end); // ++dep

                    if (!cache->IsImportantDep(end))
                        continue;
                    if ((cache[end] & pkgDepCache::DepGInstall) != 0)
                        continue;

                    NSMutableArray *clauses([NSMutableArray arrayWithCapacity:4]);

                    [reasons addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                        [NSString stringWithUTF8String:start.DepType()], @"relationship",
                        clauses, @"clauses",
                    nil]];

                    _forever {
                        NSString *reason, *installed((NSString *) [WebUndefined undefined]);

                        pkgCache::PkgIterator target(start.TargetPkg());
                        if (cache[target].Delete())
                            reason = @"removed";
                        else if (target->ProvidesList != 0)
                            reason = @"missing";
                        else {
                            pkgCache::VerIterator ver(cache[target].InstVerIter(cache));
                            if (!ver.end()) {
                                reason = @"installed";
                                installed = [NSString stringWithUTF8String:ver.VerStr()];
                            } else if (!cache[target].CandidateVerIter(cache).end())
                                reason = @"uninstalled";
                            else if (target->ProvidesList == 0)
                                reason = @"uninstallable";
                            else
                                reason = @"virtual";
                        }

                        NSDictionary *version(start.TargetVer() == 0 ? (NSDictionary *) [NSNull null] : [NSDictionary dictionaryWithObjectsAndKeys:
                            [NSString stringWithUTF8String:start.CompType()], @"operator",
                            [NSString stringWithUTF8String:start.TargetVer()], @"value",
                        nil]);

                        [clauses addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                            [NSString stringWithUTF8String:start.TargetPkg().Name()], @"package",
                            version, @"version",
                            reason, @"reason",
                            installed, @"installed",
                        nil]];

                        // yes, seriously. (wtf?)
                        if (start == end)
                            break;
                        ++start;
                    }
                }
            }

            pkgDepCache::StateCache &state(cache[iterator]);

            static RegEx special_r("(firmware|gsc\\..*|cy\\+.*)");
            BOOL automatic(requestedIdentifiers_ != nil && ![requestedIdentifiers_ containsObject:name]);

            if (state.NewInstall()) {
                if (automatic) {
                    [dependencies addObject:name];
                    [dependencyActions setObject:UCLocalize("INSTALL") forKey:name];
                } else
                    [installs addObject:name];
            }
            // XXX: else if (state.Install())
            else if (!state.Delete() && (state.iFlags & pkgDepCache::ReInstall) == pkgDepCache::ReInstall) {
                if (automatic) {
                    [dependencies addObject:name];
                    [dependencyActions setObject:UCLocalize("REINSTALL") forKey:name];
                } else
                    [reinstalls addObject:name];
            }
            else if (state.Upgrade() || state.Downgrade()) {
                // APT may distinguish records with identical versions. Classify
                // the selected operation using Debian's full version strings;
                // never infer that a repository rebuilt its archive.
                pkgCache::VerIterator selected(state.InstVerIter(cache));
                pkgCache::VerIterator installed(iterator.CurrentVer());
                int comparison(selected.end() || installed.end() ? 0 :
                    _system->VS->CmpVersion(selected.VerStr(), installed.VerStr()));
                NSString *action(comparison > 0 ? UCLocalize("UPGRADE") :
                    (comparison < 0 ? UCLocalize("DOWNGRADE") : UCLocalize("REINSTALL")));
                if (automatic) {
                    [dependencies addObject:name];
                    [dependencyActions setObject:action forKey:name];
                } else if (comparison > 0)
                    [upgrades addObject:name];
                else if (comparison < 0)
                    [downgrades addObject:name];
                else
                    [reinstalls addObject:name];
            }
            else if (!state.Delete())
                // XXX: _assert(state.Keep());
                continue;
            else if (special_r(name))
                [issues_ addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    [NSNull null], @"package",
                    [NSArray arrayWithObjects:
                        [NSDictionary dictionaryWithObjectsAndKeys:
                            @"Conflicts", @"relationship",
                            [NSArray arrayWithObjects:
                                [NSDictionary dictionaryWithObjectsAndKeys:
                                    name, @"package",
                                    [NSNull null], @"version",
                                    @"installed", @"reason",
                                nil],
                            nil], @"clauses",
                        nil],
                    nil], @"reasons",
                nil]];
            else {
                if ([package essential])
                    remove = true;
                if (automatic) {
                    [dependencies addObject:name];
                    [dependencyActions setObject:UCLocalize("REMOVE") forKey:name];
                } else
                    [removes addObject:name];
            }

            pkgCache::VerIterator selected(state.InstVerIter(cache));
            pkgCache::VerIterator installed(iterator.CurrentVer());
            // Reuse identity/artwork metadata; constructing another Package can
            // update its last-seen metadata. Freeze the actual selected versions
            // separately without changing APT candidates or package metadata.
            [reviewPackages_ setObject:package forKey:name];
            [reviewVersions_ setObject:@{
                @"selected": selected.end() ? @"" : [NSString stringWithUTF8String:selected.VerStr()],
                @"installed": installed.end() ? @"" : [NSString stringWithUTF8String:installed.VerStr()]
            } forKey:name];

            const char *injectionDependency(NULL);
#ifndef __arm__
            injectionDependency = DepSubstrateIdentifier(cache->GetCandidateVersion(iterator));
#else
            injectionDependency = DepSubstrateIdentifier(policy->GetCandidateVer(iterator));
#endif
            if (injectionDependency == NULL)
                injectionDependency = DepSubstrateIdentifier(iterator.CurrentVer());
            if (injectionDependency != NULL) {
                substrate_ = YES;
                const char *detectedProvider(CYDetectedInjectionProvider(cache));
                CYRootlessDiag(@"INJECTION", @"recognized provider=%s dependency=%s dependencyClass=%s package=%s restartFallback=1",
                    detectedProvider != NULL ? detectedProvider : "unknown",
                    injectionDependency,
                    CYInjectionCompatibility::ProviderLabelForDependency(injectionDependency),
                    iterator.Name());
            }
        }

        if (cache->BrokenCount() != 0 && [issues_ count] == 0)
            [issues_ addObject:@{@"package":[NSNull null], @"reasons":@[]}];

        if (!remove)
            essential_ = nil;
        else if (Advanced_) {
            NSString *parenthetical(UCLocalize("PARENTHETICAL"));

            essential_ = [[[UIAlertView alloc]
                initWithTitle:UCLocalize("REMOVING_ESSENTIALS")
                message:UCLocalize("REMOVING_ESSENTIALS_EX")
                delegate:self
                cancelButtonTitle:[NSString stringWithFormat:parenthetical, UCLocalize("CANCEL_OPERATION"), UCLocalize("SAFE")]
                otherButtonTitles:
                    [NSString stringWithFormat:parenthetical, UCLocalize("FORCE_REMOVAL"), UCLocalize("UNSAFE")],
                nil
            ] autorelease];

            [essential_ setContext:@"remove"];
            [essential_ setNumberOfRows:2];
        } else {
            essential_ = [[[UIAlertView alloc]
                initWithTitle:UCLocalize("UNABLE_TO_COMPLY")
                message:UCLocalize("UNABLE_TO_COMPLY_EX")
                delegate:self
                cancelButtonTitle:UCLocalize("OKAY")
                otherButtonTitles:nil
            ] autorelease];

            [essential_ setContext:@"unable"];
        }

        changes_ = [NSDictionary dictionaryWithObjectsAndKeys:
            installs, @"installs",
            reinstalls, @"reinstalls",
            upgrades, @"upgrades",
            dependencies, @"dependencies",
            downgrades, @"downgrades",
            removes, @"removes",
        nil];
        dependencyActions_ = dependencyActions;

        CYRootlessDiag(@"TRANSACTION", @"review requested=%lu automaticDependencies=%lu total=%lu classification=sileo-style",
            (unsigned long) [requestedIdentifiers_ count],
            (unsigned long) [dependencies count],
            (unsigned long) ([installs count] + [reinstalls count] + [upgrades count] + [dependencies count] + [downgrades count] + [removes count]));

        sizes_ = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithInteger:[database_ fetcher].FetchNeeded()], @"downloading",
            [NSNumber numberWithInteger:[database_ fetcher].PartialPresent()], @"resuming",
        nil];

    } return self;
}

- (UIBarButtonItem *) leftButton {
    return [[[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("CANCEL")
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(cancelButtonClicked)
    ] autorelease];
}

#if !AlwaysReload
- (void) applyRightButton {
    // The full native confirmation surface owns the persistent primary action.
    [[self navigationItem] setRightBarButtonItem:nil];
}
#endif

- (void) cancelButtonClicked {
    [self.delegate cancelAndClear:YES];
    [self dismissModalViewControllerAnimated:YES];
}

#if !AlwaysReload
- (void) confirmButtonClicked {
    if (!CYTransactionCanConfirm(changes_, issues_, confirmationStarted_))
        return;
    if (essential_ != nil)
        [essential_ show];
    else
        [self complete];
}
#endif

@end
/* }}} */

/* Progress Data {{{ */
@interface CydiaProgressData : NSObject {
    _transient id delegate_;

    bool running_;
    float percent_;

    float current_;
    float total_;
    float speed_;

    _H<NSMutableArray> events_;
    _H<NSString> title_;

    _H<NSString> status_;
    _H<NSString> finish_;
}

@end

@implementation CydiaProgressData

+ (NSArray *) _attributeKeys {
    return [NSArray arrayWithObjects:
        @"current",
        @"events",
        @"finish",
        @"percent",
        @"running",
        @"speed",
        @"title",
        @"total",
    nil];
}

- (NSArray *) attributeKeys {
    return [[self class] _attributeKeys];
}

+ (BOOL) isKeyExcludedFromWebScript:(const char *)name {
    return ![[self _attributeKeys] containsObject:[NSString stringWithUTF8String:name]] && [super isKeyExcludedFromWebScript:name];
}

- (id) init {
    if ((self = [super init]) != nil) {
        events_ = [NSMutableArray arrayWithCapacity:32];
    } return self;
}

- (id) delegate {
    return delegate_;
}

- (void) setDelegate:(id)delegate {
    delegate_ = delegate;
}

- (void) setPercent:(float)value {
    percent_ = value;
}

- (NSNumber *) percent {
    return [NSNumber numberWithFloat:percent_];
}

- (void) setCurrent:(float)value {
    current_ = value;
}

- (NSNumber *) current {
    return [NSNumber numberWithFloat:current_];
}

- (void) setTotal:(float)value {
    total_ = value;
}

- (NSNumber *) total {
    return [NSNumber numberWithFloat:total_];
}

- (void) setSpeed:(float)value {
    speed_ = value;
}

- (NSNumber *) speed {
    return [NSNumber numberWithFloat:speed_];
}

- (NSArray *) events {
    return events_;
}

- (void) removeAllEvents {
    [events_ removeAllObjects];
}

- (void) addEvent:(CydiaProgressEvent *)event {
    [events_ addObject:event];
}

- (void) setTitle:(NSString *)text {
    title_ = text;
}

- (NSString *) title {
    return title_;
}

- (void) setFinish:(NSString *)text {
    finish_ = text;
}

- (NSString *) finish {
    return (id) finish_ ?: [NSNull null];
}

- (void) setRunning:(bool)running {
    running_ = running;
}

- (NSNumber *) running {
    return running_ ? (NSNumber *) kCFBooleanTrue : (NSNumber *) kCFBooleanFalse;
}

@end
/* }}} */
/* Progress Controller {{{ */
static NSString *CYFinalFinishActionName(int finish, int rebootMode) {
    switch (finish) {
        case 0: return @"return";
        case 1: return @"reopen";
        case 2: return @"restart";
        case 3: return @"reload";
        case 4: return rebootMode == 1 ? @"usreboot" : @"reboot";
        default: return @"unknown";
    }
}

@interface ProgressController : CydiaWebViewController <
    ProgressDelegate
> {
    _transient Database *database_;
    _H<CydiaProgressData, 1> progress_;
    unsigned cancel_;
    bool cancellationRequested_;
    _H<NSMutableSet> warningMessages_;
    _H<CydiaModernProgressView> modernProgressView_;
    bool modernProgressError_;
    bool finishActionStarted_;
}

- (id) initWithDatabase:(Database *)database delegate:(id)delegate;

- (void) invoke:(NSInvocation *)invocation withTitle:(NSString *)title;
- (void) invokeDeferred:(NSArray *)context;

- (void) setTitle:(NSString *)title;
- (void) setCancellable:(bool)cancellable;
- (void) finishActionFailed;
- (void) observeFinishChild:(NSNumber *)process;

@end

@implementation ProgressController

- (void) loadView {
    [self setView:CYModernNativeControllerRoot(@"progress")];
}

- (void) viewDidLoad {
    [super viewDidLoad];

    modernProgressView_ = [[[CydiaModernProgressView alloc] initWithFrame:CGRectZero] autorelease];
    [[self view] addSubview:modernProgressView_];
    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [[modernProgressView_ leadingAnchor] constraintEqualToAnchor:[[self view] leadingAnchor]],
        [[modernProgressView_ trailingAnchor] constraintEqualToAnchor:[[self view] trailingAnchor]],
        [[modernProgressView_ topAnchor] constraintEqualToAnchor:[[self view] topAnchor]],
        [[modernProgressView_ bottomAnchor] constraintEqualToAnchor:[[self view] bottomAnchor]],
    nil]];
    [modernProgressView_ setTransactionTitle:[progress_ title]];
    [modernProgressView_ setStatusText:UCLocalize("LOADING")];
    [modernProgressView_ setTransferCurrent:0 total:0 speed:0];
    [modernProgressView_ setProgressValue:[[progress_ percent] floatValue] animated:NO];
    [modernProgressView_ setRunning:YES];
    [[self view] bringSubviewToFront:modernProgressView_];
}

- (void) dealloc {
    [database_ setProgressDelegate:nil];
    [super dealloc];
}

- (UIBarButtonItem *) leftButton {
    return cancel_ == 1 ? [[[UIBarButtonItem alloc]
        initWithTitle:UCLocalize("CANCEL")
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(cancel)
    ] autorelease] : nil;
}

- (void) updateCancel {
    [super applyLeftButton];
}

- (id) initWithDatabase:(Database *)database delegate:(id)delegate {
    if ((self = [super init]) != nil) {
        database_ = database;
        self.delegate = delegate;

        [database_ setProgressDelegate:self];

        progress_ = [[[CydiaProgressData alloc] init] autorelease];
        [progress_ setDelegate:self];
        warningMessages_ = [NSMutableSet set];

        [self setPageColor:[UIColor systemGroupedBackgroundColor]];

        [[self navigationItem] setHidesBackButton:YES];
        [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];

        [self updateCancel];
    } return self;
}

- (void) updateProgress {
    [modernProgressView_ setNeedsLayout];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UINavigationController *navigation([self navigationController]);
    CYModernizeNavigationController(navigation);
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
}

- (void) viewWillDisappear:(BOOL)animated {
    CYModernizeNavigationController([self navigationController]);
    [super viewWillDisappear:animated];
}

- (void) finishActionFailed {
    [modernProgressView_ setRestarting:NO title:nil];
    [[self navigationItem] setTitle:CYLocalize(@"Summary")];
    finishActionStarted_ = false;
    UIAlertController *alert([UIAlertController alertControllerWithTitle:CYLocalize(@"Restart Unavailable")
        message:CYLocalize(@"The restart could not be completed. You can try again or return to Cydia.")
        preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"Try Again") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self performSelector:@selector(close) withObject:nil afterDelay:0.35];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"Return to Cydia") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        Finish_ = 0;
        RebootMode_ = 0;
        [self performSelector:@selector(close) withObject:nil afterDelay:0.35];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void) observeFinishChild:(NSNumber *)process {
    @autoreleasepool {
        int status(0);
        pid_t result;
        do { result = waitpid([process intValue], &status, 0); } while (result == -1 && errno == EINTR);
        if (result == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
            CYRootlessDiag(@"FINISH", @"restart helper did not complete result=%d status=%d", result, status);
            [self performSelectorOnMainThread:@selector(finishActionFailed) withObject:nil waitUntilDone:NO];
        }
    }
}

- (void) performReboot {
    // Flush all pending filesystem writes before any reboot so freshly
    // installed package files are guaranteed on disk (as Sileo/Zebra do).
    sync();
    if (RebootMode_ == 1) {
        // Sileo finish:usreboot means a userspace reboot, not a full
        // hardware/device reboot. The button names this distinction
        // explicitly and retains the rootless completion route.
        const char *cydo = "/var/jb/usr/libexec/cydia/cydo";
        char *const argv[] = {
            const_cast<char *>(cydo),
            const_cast<char *>("/var/jb/bin/launchctl"),
            const_cast<char *>("reboot"),
            const_cast<char *>("userspace"),
            NULL
        };
        pid_t pid = -1;
        int result = posix_spawn(&pid, cydo, NULL, NULL, argv, environ);
        if (result == 0) {
            CYRootlessDiag(@"FINISH", @"execute reboot mode=userspace child=%d command=/var/jb/bin/launchctl reboot userspace", pid);
            [self performSelectorInBackground:@selector(observeFinishChild:) withObject:@(pid)];
            return;
        }
        CYRootlessDiag(@"FINISH", @"ERROR execute reboot mode=userspace spawn=%d; refusing full-reboot fallback", result);
        [self finishActionFailed];
        return;
    } else {
        CYRootlessDiag(@"FINISH", @"execute reboot mode=full rebootMode=%d", RebootMode_);
        if (void (*SBReboot)(mach_port_t) = reinterpret_cast<void (*)(mach_port_t)>(dlsym(RTLD_DEFAULT, "SBReboot")))
            SBReboot(SBSSpringBoardServerPort());
        else if (reboot2(RB_AUTOBOOT) != 0)
            [self finishActionFailed];
    }
}

- (void) close {
    // The final action can terminate SpringBoard or the whole userspace. Ignore
    // a second tap while the first request is already being dispatched.
    if (finishActionStarted_)
        return;
    finishActionStarted_ = true;

    UpdateExternalStatus(0);

    if (Finish_ > 1)
        [self.delegate saveState];

    switch (Finish_) {
        case 0:
            [self.delegate returnToCydia];
        break;

        case 1:
            [self.delegate terminateWithSuccess];
            /*if ([self.delegate respondsToSelector:@selector(suspendWithAnimation:)])
                [self.delegate suspendWithAnimation:YES];
            else
                [self.delegate suspend];*/
        break;

        case 2:
            _trace();
            goto reload;

        case 3:
            _trace();
            goto reload;

        reload: {
            [modernProgressView_ setRestartingKind:CydiaRestartSpringBoard];
            [[self navigationItem] setTitle:CYLocalize(@"Restarting")];
            [self.delegate performSelector:@selector(reloadSpringBoard) withObject:nil afterDelay:0.5];
            return;
        }

        case 4:
            [modernProgressView_ setRestartingKind:RebootMode_ == 1 ? CydiaRestartUserspace : CydiaRestartDevice];
            [[self navigationItem] setTitle:CYLocalize(@"Restarting")];
            // Commit the same handoff screen before the existing reboot action.
            [self performSelector:@selector(performReboot) withObject:nil afterDelay:0.5];
            return;
    }

    [super close];
}

- (void) setTitle:(NSString *)title {
    [progress_ setTitle:title];
    NSString *stateTitle(title);
    if ([title isEqualToString:UCLocalize("UPDATING_SOURCES")])
        stateTitle = @"UPDATING_SOURCES";
    else if ([title isEqualToString:UCLocalize("RUNNING")])
        stateTitle = @"RUNNING";
    else if ([title isEqualToString:UCLocalize("COMPLETE")])
        stateTitle = @"COMPLETE";
    [modernProgressView_ setTransactionTitle:stateTitle];
    NSString *navigationTitle(stateTitle);
    if ([navigationTitle caseInsensitiveCompare:@"RUNNING"] == NSOrderedSame)
        navigationTitle = CYLocalize(@"Applying");
    else if ([navigationTitle caseInsensitiveCompare:@"UPDATING_SOURCES"] == NSOrderedSame)
        navigationTitle = CYLocalize(@"Refreshing");
    if ([navigationTitle caseInsensitiveCompare:@"COMPLETE"] == NSOrderedSame)
        navigationTitle = CYLocalize(@"Summary");
    else if ([navigationTitle caseInsensitiveCompare:@"REPAIRING"] == NSOrderedSame)
        navigationTitle = UCLocalize("REPAIRING");
    [[self navigationItem] setTitle:navigationTitle];
    [self updateProgress];
}

- (UIBarButtonItem *) rightButton {
    // The modern full-screen surface keeps its final action visible at the
    // bottom, so a second navigation-bar Close button would be redundant.
    return nil;
}

// Package transactions are pushed from the Confirm controller.
// On modern UIKit, starting the transaction synchronously from the Confirm
// button action can begin APT/dpkg before the navigation push has actually
// committed to screen.  The progress events are then recorded correctly, but
// the user keeps seeing Confirm until the transaction is almost finished.
// Defer package transactions until the pushed ProgressController has had a
// display turn. The same screen-first ordering is applied to Sources in
// invokeNewProgress while leaving repair/other modal progress flows unchanged.
- (void) invokeDeferred:(NSArray *)context {
    id value([context objectAtIndex:0]);
    NSInvocation *invocation(value == [NSNull null] ? nil : (NSInvocation *)value);
    NSString *title([context objectAtIndex:1]);
    [self invoke:invocation withTitle:title];
}

- (void) invoke:(NSInvocation *)invocation withTitle:(NSString *)title {
    uint64_t diagnosticsStart(_timestamp);
    CYRootlessDiag(@"TRANSACTION", @"begin title=%@ hasInvocation=%d", title, invocation != nil);
    UpdateExternalStatus(1);

    [progress_ setRunning:true];
    finishActionStarted_ = false;
    @synchronized (self) {
        cancellationRequested_ = false;
    }
    cancel_ = 0;
    [warningMessages_ removeAllObjects];
    modernProgressError_ = false;
    [modernProgressView_ setErrorState:NO];
    [modernProgressView_ setRunning:YES];
    [modernProgressView_ setStatusText:UCLocalize("LOADING")];
    [modernProgressView_ setTransferCurrent:0 total:0 speed:0];
    [modernProgressView_ setProgressValue:0.0f animated:NO];
    [self setTitle:title];
    // Construct the native progress surface before starting the transaction.
    [self view];
    [self updateProgress];

    SHA1SumValue notifyconf; {
        FileFd file;
        if (!file.Open(NotifyConfig_, FileFd::ReadOnly))
            _error->Discard();
        else {
            MMap mmap(file, MMap::ReadOnly);
            SHA1Summation sha1;
            sha1.Add(reinterpret_cast<uint8_t *>(mmap.Data()), mmap.Size());
            notifyconf = sha1.Result();
        }
    }

    SHA1SumValue springlist; {
        FileFd file;
        if (!file.Open(SpringBoard_, FileFd::ReadOnly))
            _error->Discard();
        else {
            MMap mmap(file, MMap::ReadOnly);
            SHA1Summation sha1;
            sha1.Add(reinterpret_cast<uint8_t *>(mmap.Data()), mmap.Size());
            springlist = sha1.Result();
        }
    }

    if (invocation != nil) {
        [invocation yieldToSelector:@selector(invoke)];
        if (!modernProgressError_ && !cancellationRequested_)
            [self setTitle:UCLocalize("COMPLETE")];
    }

    if (Finish_ < 4) {
        FileFd file;
        if (!file.Open(NotifyConfig_, FileFd::ReadOnly))
            _error->Discard();
        else {
            MMap mmap(file, MMap::ReadOnly);
            SHA1Summation sha1;
            sha1.Add(reinterpret_cast<uint8_t *>(mmap.Data()), mmap.Size());
            if (!(notifyconf == sha1.Result()))
                Finish_ = 4;
        }
    }

    if (Finish_ < 3) {
        FileFd file;
        if (!file.Open(SpringBoard_, FileFd::ReadOnly))
            _error->Discard();
        else {
            MMap mmap(file, MMap::ReadOnly);
            SHA1Summation sha1;
            sha1.Add(reinterpret_cast<uint8_t *>(mmap.Data()), mmap.Size());
            if (!(springlist == sha1.Result()))
                Finish_ = 3;
        }
    }

    if (Finish_ < 2) {
        if (RestartSubstrate_) {
            Finish_ = 2;
            CYRootlessDiag(@"FINISH", @"selected fallbackAction=restart reason=recognized-injection-dependency");
        }
    }

    RestartSubstrate_ = false;

    switch (Finish_) {
        case 0: [progress_ setFinish:UCLocalize("RETURN_TO_CYDIA")]; break; /* XXX: Maybe UCLocalize("DONE")? */
        case 1: [progress_ setFinish:UCLocalize("CLOSE_CYDIA")]; break;
        case 2: [progress_ setFinish:UCLocalize("RESTART_SPRINGBOARD")]; break;
        case 3: [progress_ setFinish:UCLocalize("RELOAD_SPRINGBOARD")]; break;
        case 4: [progress_ setFinish:RebootMode_ == 1 ? CYLocalize(@"Restart Userspace") : UCLocalize("REBOOT_DEVICE")]; break;
    }

    UpdateExternalStatus(Finish_ == 0 ? 0 : 2);

    [progress_ setRunning:false];
    if (modernProgressError_) {
        BOOL refreshFailure([title caseInsensitiveCompare:@"UPDATING_SOURCES"] == NSOrderedSame ||
            [[title lowercaseString] rangeOfString:@"refresh"].location != NSNotFound);
        [modernProgressView_ setTransactionTitle:refreshFailure ? @"Refresh Failed" : @"Transaction Failed"];
        [[self navigationItem] setTitle:CYLocalize(@"Failed")];
    } else if (cancellationRequested_) {
        [modernProgressView_ setCancelledState:YES];
        [[self navigationItem] setTitle:CYLocalize(@"Cancelled")];
    } else {
        [modernProgressView_ setProgressValue:1.0f animated:YES];
        [modernProgressView_ setStatusText:UCLocalize("COMPLETE")];
    }
    [modernProgressView_ setFinishTitle:[progress_ finish] target:self action:@selector(close)];
    [modernProgressView_ setRestartRequired:Finish_ > 1 && !modernProgressError_ && !cancellationRequested_];
    [modernProgressView_ setRunning:NO];

    UINotificationFeedbackGenerator *feedback([[[UINotificationFeedbackGenerator alloc] init] autorelease]);
    if (!cancellationRequested_ || modernProgressError_)
        [feedback notificationOccurred:modernProgressError_ ? UINotificationFeedbackTypeError : UINotificationFeedbackTypeSuccess];

    [self updateProgress];

    CYRootlessDiag(@"FINISH", @"transaction title=%@ finishIndex=%d finishLabel=%@ finalAction=%@ rebootMode=%d durationMs=%llu",
        title, Finish_, [progress_ finish], CYFinalFinishActionName(Finish_, RebootMode_), RebootMode_,
        (unsigned long long) ((_timestamp - diagnosticsStart) / 1000));
    [self applyRightButton];
}

- (void) addProgressEvent:(CydiaProgressEvent *)event {
    NSString *type([event type]);
    NSString *package([event package]);
    NSString *rawMessage([event message] ?: @"");
    NSString *message(CYRootlessDiagnosticsText(rawMessage));
    NSString *component(([type isEqualToString:kCydiaProgressEventTypeError] || [type isEqualToString:kCydiaProgressEventTypeWarning]) ? @"APT" : @"PROGRESS");
    CYRootlessDiag(component, @"type=%@ package=%@ message=%@", type, package, message);

    // One ProgressController represents one Refresh/Database or package
    // transaction. Keep every APT warning in diagnostics, but surface an exact
    // warning string only once on this operation's original Progress UI.
    if ([type isEqualToString:kCydiaProgressEventTypeWarning]) {
        @synchronized (warningMessages_) {
            if ([warningMessages_ containsObject:rawMessage]) {
                CYRootlessDiag(@"APT", @"level=INFO suppressedFromUI=1 reason=duplicate-warning operationScope=progress-controller message=%@", message);
                return;
            }
            [warningMessages_ addObject:rawMessage];
        }
    }

    [progress_ addEvent:event];
    [modernProgressView_ appendLogMessage:message type:type];
    if ([type isEqualToString:kCydiaProgressEventTypeError]) {
        modernProgressError_ = true;
        [modernProgressView_ setErrorState:YES];
    }
    [self updateProgress];
}

- (bool) isProgressCancelled {
    @synchronized (self) {
        return cancellationRequested_;
    }
}

- (void) cancel {
    if (cancel_ != 1)
        return;
    @synchronized (self) {
        cancellationRequested_ = true;
    }
    cancel_ = 2;
    [modernProgressView_ setStatusText:CYLocalize(@"Cancelling…")];
    [self updateCancel];
}

- (void) setCancellable:(bool)cancellable {
    unsigned cancel(cancel_);

    if (!cancellable)
        cancel_ = 0;
    else if (cancel_ == 0)
        cancel_ = 1;

    if (cancel != cancel_)
        [self updateCancel];
}

- (void) setProgressCancellable:(NSNumber *)cancellable {
    [self setCancellable:[cancellable boolValue]];
}

- (void) setProgressPercent:(NSNumber *)percent {
    if (cancellationRequested_)
        return;
    [modernProgressView_ beginInstalling];
    [progress_ setPercent:[percent floatValue]];
    [modernProgressView_ setProgressValue:[percent floatValue] animated:YES];
    [self updateProgress];
}

- (void) setProgressStatus:(NSDictionary *)status {
    if (cancellationRequested_)
        return;
    if (status == nil) {
        [progress_ setCurrent:0];
        [progress_ setTotal:0];
        [progress_ setSpeed:0];
        [modernProgressView_ beginInstalling];
        [modernProgressView_ setTransferCurrent:0 total:0 speed:0];
    } else {
        [progress_ setPercent:[[status objectForKey:@"Percent"] floatValue]];

        [progress_ setCurrent:[[status objectForKey:@"Current"] floatValue]];
        [progress_ setTotal:[[status objectForKey:@"Total"] floatValue]];
        [progress_ setSpeed:[[status objectForKey:@"Speed"] floatValue]];
        [modernProgressView_ setDownloadProgressValue:[[status objectForKey:@"Percent"] floatValue]
                                         current:[[status objectForKey:@"Current"] doubleValue]
                                           total:[[status objectForKey:@"Total"] doubleValue]
                                           speed:[[status objectForKey:@"Speed"] doubleValue]];
    }

    [self updateProgress];
}

@end
/* }}} */

/* Package Cell {{{ */
static NSCache *CYModernPackageIconCache(void) {
    static NSCache *cache(nil);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        [cache setCountLimit:300];
        [cache setTotalCostLimit:32 * 1024 * 1024];
    });
    return cache;
}

// Persistent on-disk cache for package icons. Like Sileo/Zebra, an icon
// downloaded once is read straight back from disk on later tab entries and
// cold launches instead of triggering a fresh network fetch, so package rows
// that carry their own icon show it immediately with no visible lag.
static NSString *CYModernPackageIconDiskDirectory(void) {
    static NSString *directory(nil);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *paths(NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES));
        NSString *root([paths count] == 0 ? NSTemporaryDirectory() : [paths objectAtIndex:0]);
        directory = [[root stringByAppendingPathComponent:@"com.saurik.Cydia/PackageIcons"] copy];
    });
    return directory;
}

static NSString *CYModernPackageIconDiskPath(NSString *address) {
    const unsigned char *bytes(reinterpret_cast<const unsigned char *>([address UTF8String]));
    NSUInteger length([address lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    uint64_t hash(1469598103934665603ULL);
    for (NSUInteger index(0); bytes != NULL && index != length; ++index) {
        hash ^= bytes[index];
        hash *= 1099511628211ULL;
    }
    NSString *name([NSString stringWithFormat:@"%016llx.icon", (unsigned long long) hash]);
    return [CYModernPackageIconDiskDirectory() stringByAppendingPathComponent:name];
}

// Keep the on-disk icon cache bounded. iOS purges the Caches directory under
// storage pressure, but a well-behaved app still caps its own footprint: once
// per launch, off the main thread, trim the oldest icons when the cache grows
// past a soft ceiling. Reads that race a deletion simply miss and re-fetch.
static void CYPruneModernPackageIconDiskCacheOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                NSString *directory(CYModernPackageIconDiskDirectory());
                NSFileManager *manager([NSFileManager defaultManager]);
                NSArray *contents([manager contentsOfDirectoryAtPath:directory error:NULL]);
                if ([contents count] == 0)
                    return;

                NSMutableArray *files([NSMutableArray arrayWithCapacity:[contents count]]);
                unsigned long long total(0);
                for (NSString *name in contents) {
                    NSString *path([directory stringByAppendingPathComponent:name]);
                    NSDictionary *attributes([manager attributesOfItemAtPath:path error:NULL]);
                    if (attributes == nil)
                        continue;
                    unsigned long long size([attributes fileSize]);
                    NSDate *date([attributes fileModificationDate] ?: [NSDate distantPast]);
                    total += size;
                    [files addObject:[NSArray arrayWithObjects:path, [NSNumber numberWithUnsignedLongLong:size], date, nil]];
                }

                const unsigned long long ceiling(48ULL * 1024 * 1024);
                const unsigned long long target(32ULL * 1024 * 1024);
                const NSUInteger fileCeiling(1500);
                const NSUInteger fileTarget(1000);
                if (total <= ceiling && [files count] <= fileCeiling)
                    return;

                [files sortUsingComparator:^NSComparisonResult(NSArray *left, NSArray *right) {
                    return [(NSDate *) [left objectAtIndex:2] compare:(NSDate *) [right objectAtIndex:2]];
                }];

                NSUInteger count([files count]);
                NSUInteger removed(0);
                for (NSArray *entry in files) {
                    if (total <= target && count <= fileTarget)
                        break;
                    if ([manager removeItemAtPath:[entry objectAtIndex:0] error:NULL]) {
                        total -= [(NSNumber *) [entry objectAtIndex:1] unsignedLongLongValue];
                        --count;
                        ++removed;
                    }
                }
                if (removed != 0)
                    CYRootlessDiag(@"ICON_CACHE", @"disk prune removed=%lu remainingFiles=%lu remainingBytes=%llu",
                        (unsigned long) removed, (unsigned long) count, total);
            }
        });
    });
}

static void CYPersistModernPackageIcon(NSString *address, NSData *data) {
    if ([address length] == 0 || [data length] == 0 || [data length] > 3 * 1024 * 1024)
        return;
    [[NSFileManager defaultManager] createDirectoryAtPath:CYModernPackageIconDiskDirectory()
        withIntermediateDirectories:YES attributes:nil error:NULL];
    [data writeToFile:CYModernPackageIconDiskPath(address) options:NSDataWritingAtomic error:NULL];
    CYPruneModernPackageIconDiskCacheOnce();
}

// Decode a bounded, screen-scale bitmap before handing an icon to UIKit.
// The 96-point target stays sharp in both list rows and package headers.
static UIImage *CYPreparedPackageIcon(NSData *data, CGFloat scale) {
    if ([data length] == 0 || [data length] > 3 * 1024 * 1024)
        return nil;
    CGImageSourceRef source(CGImageSourceCreateWithData((CFDataRef)data, (CFDictionaryRef)@{(id)kCGImageSourceShouldCache: @NO}));
    if (source == NULL)
        return nil;
    NSDictionary *options(@{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(ceil(96.0f * MAX(1.0f, scale))),
        (id)kCGImageSourceShouldCacheImmediately: @YES
    });
    CGImageRef bitmap(CGImageSourceCreateThumbnailAtIndex(source, 0, (CFDictionaryRef)options));
    CFRelease(source);
    if (bitmap == NULL)
        return nil;
    UIImage *image([UIImage imageWithCGImage:bitmap scale:MAX(1.0f, scale) orientation:UIImageOrientationUp]);
    CGImageRelease(bitmap);
    return [image size].width >= 2.0f && [image size].height >= 2.0f ? image : nil;
}

static NSUInteger CYPackageIconMemoryCost(UIImage *image) {
    CGImageRef bitmap([image CGImage]);
    return bitmap == NULL ? 0 : CGImageGetBytesPerRow(bitmap) * CGImageGetHeight(bitmap);
}

static NSOperationQueue *CYPackageIconReadQueue(void) {
    static NSOperationQueue *queue(nil);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [[NSOperationQueue alloc] init];
        [queue setName:@"com.saurik.Cydia.package-icon-read"];
        [queue setQualityOfService:NSQualityOfServiceUserInitiated];
        [queue setMaxConcurrentOperationCount:2];
    });
    return queue;
}

static UIImage *CYModernPackageIconFromDisk(NSString *address) {
    if ([address length] == 0)
        return nil;
    CYPruneModernPackageIconDiskCacheOnce();
    NSData *data([NSData dataWithContentsOfFile:CYModernPackageIconDiskPath(address)
        options:NSDataReadingMappedIfSafe error:NULL]);
    if ([data length] == 0 || [data length] > 3 * 1024 * 1024)
        return nil;
    UIImage *image(CYPreparedPackageIcon(data, [[UIScreen mainScreen] scale]));
    if (image == nil || [image size].width < 2.0f || [image size].height < 2.0f)
        return nil;
    [CYModernPackageIconCache() setObject:image forKey:address cost:CYPackageIconMemoryCost(image)];
    return image;
}

@interface PackageCell : CyteTableViewCell <
    CyteTableViewCellDelegate
> {
    _H<UIImage> icon_;
    _H<NSString> name_;
    _H<NSString> description_;
    bool commercial_;
    _H<NSString> source_;
    _H<UIImage> badge_;
    _H<UIImage> placard_;
    _H<UIImageView> iconView_;
    _H<UIImageView> badgeView_;
    _H<UIImageView> statusView_;
    _H<UIImageView> paidView_;
    _H<UILabel> nameLabel_;
    _H<UILabel> sourceLabel_;
    _H<UILabel> descriptionLabel_;
    _H<NSString> representedPackageIdentifier_;
    _H<NSOperation> iconReadOperation_;
    NSUInteger iconRequestGeneration_;
    _H<NSURLSessionDataTask> remoteIconTask_;
    bool summarized_;
}

- (PackageCell *) init;
- (void) setPackage:(Package *)package asSummary:(bool)summary;

- (void) drawContentRect:(CGRect)rect;

@end

@implementation PackageCell

- (PackageCell *) init {
    CGRect frame(CGRectMake(0, 0, 320, 84));
    if ((self = [super initWithFrame:frame reuseIdentifier:@"Package"]) != nil) {
        [self.content setHidden:YES];
        [self setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];
        [self setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];

        iconView_ = [[[CydiaSymbolView alloc] init] autorelease];
        [iconView_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [iconView_ setContentMode:UIViewContentModeScaleAspectFit];
        [iconView_ setBackgroundColor:[UIColor tertiarySystemGroupedBackgroundColor]];
        [[iconView_ layer] setCornerRadius:11.0f];
        [[iconView_ layer] setCornerCurve:kCACornerCurveContinuous];
        [[iconView_ layer] setMasksToBounds:YES];

        badgeView_ = [[[CydiaSymbolView alloc] init] autorelease];
        [badgeView_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [badgeView_ setContentMode:UIViewContentModeScaleAspectFit];

        statusView_ = [[[CydiaSymbolView alloc] init] autorelease];
        [statusView_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [statusView_ setContentMode:UIViewContentModeScaleAspectFit];
        [statusView_ setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15.0f weight:UIImageSymbolWeightSemibold]];

        nameLabel_ = [[[UILabel alloc] init] autorelease];
        [nameLabel_ setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
        [nameLabel_ setTextColor:[UIColor labelColor]];
        [nameLabel_ setNumberOfLines:1];
        [nameLabel_ setAdjustsFontForContentSizeCategory:YES];

        sourceLabel_ = [[[UILabel alloc] init] autorelease];
        [sourceLabel_ setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]];
        [sourceLabel_ setTextColor:CYModernLabelColor()];
        [sourceLabel_ setNumberOfLines:1];
        [sourceLabel_ setAdjustsFontForContentSizeCategory:YES];

        descriptionLabel_ = [[[UILabel alloc] init] autorelease];
        [descriptionLabel_ setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]];
        [descriptionLabel_ setTextColor:CYModernPackageDescriptionColor(NO)];
        [descriptionLabel_ setNumberOfLines:1];
        [descriptionLabel_ setAdjustsFontForContentSizeCategory:YES];

        paidView_ = [[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:@"creditcard"]] autorelease];
        [paidView_ setContentMode:UIViewContentModeScaleAspectFit];
        [paidView_ setTintColor:CYModernCommercialColor()];
        [paidView_ setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16.0f weight:UIImageSymbolWeightMedium]];
        [paidView_ setHidden:YES];
        NSLayoutConstraint *paidWidth([[paidView_ widthAnchor] constraintEqualToConstant:20.0f]);
        [paidWidth setPriority:999];
        [paidWidth setActive:YES];
        [[paidView_ heightAnchor] constraintEqualToConstant:20.0f].active = YES;
        [paidView_ setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UILabel *nameLabel(nameLabel_);
        UILabel *sourceLabel(sourceLabel_);
        UILabel *descriptionLabel(descriptionLabel_);
        UIImageView *paidView(paidView_);
        UIStackView *nameRow([[[UIStackView alloc] initWithArrangedSubviews:@[nameLabel, paidView]] autorelease]);
        [nameRow setAxis:UILayoutConstraintAxisHorizontal];
        [nameRow setAlignment:UIStackViewAlignmentCenter];
        [nameRow setSpacing:6.0f];
        UIStackView *labels([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:nameRow, sourceLabel, descriptionLabel, nil]] autorelease]);
        [labels setTranslatesAutoresizingMaskIntoConstraints:NO];
        [labels setAxis:UILayoutConstraintAxisVertical];
        [labels setAlignment:UIStackViewAlignmentFill];
        [labels setSpacing:2.0f];

        [[self contentView] addSubview:iconView_];
        [[self contentView] addSubview:badgeView_];
        [[self contentView] addSubview:labels];
        [[self contentView] addSubview:statusView_];

        [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
            [[iconView_ leadingAnchor] constraintEqualToAnchor:[[self contentView] leadingAnchor] constant:14.0f],
            [[iconView_ centerYAnchor] constraintEqualToAnchor:[[self contentView] centerYAnchor]],
            [[iconView_ widthAnchor] constraintEqualToConstant:46.0f],
            [[iconView_ heightAnchor] constraintEqualToConstant:46.0f],
            [[badgeView_ trailingAnchor] constraintEqualToAnchor:[iconView_ trailingAnchor] constant:3.0f],
            [[badgeView_ bottomAnchor] constraintEqualToAnchor:[iconView_ bottomAnchor] constant:3.0f],
            [[badgeView_ widthAnchor] constraintEqualToConstant:17.0f],
            [[badgeView_ heightAnchor] constraintEqualToConstant:17.0f],
            [[labels leadingAnchor] constraintEqualToAnchor:[iconView_ trailingAnchor] constant:12.0f],
            [[labels centerYAnchor] constraintEqualToAnchor:[[self contentView] centerYAnchor]],
            [[labels trailingAnchor] constraintLessThanOrEqualToAnchor:[statusView_ leadingAnchor] constant:-6.0f],
            [[statusView_ trailingAnchor] constraintEqualToAnchor:[[self contentView] trailingAnchor] constant:-2.0f],
            [[statusView_ topAnchor] constraintEqualToAnchor:[[self contentView] topAnchor] constant:12.0f],
            [[statusView_ widthAnchor] constraintEqualToConstant:20.0f],
            [[statusView_ heightAnchor] constraintEqualToConstant:20.0f],
        nil]];

        UIView *selection([[[UIView alloc] initWithFrame:CGRectZero] autorelease]);
        [selection setBackgroundColor:[CYModernAccentColor() colorWithAlphaComponent:0.12f]];
        [self setSelectedBackgroundView:selection];
    } return self;
}

- (NSString *) accessibilityLabel {
    return commercial_ ? [@[(NSString *)name_ ?: @"", CYLocalize(@"Paid package")] componentsJoinedByString:@", "] : (NSString *)name_;
}

- (void) prepareForReuse {
    ++iconRequestGeneration_;
    [iconReadOperation_ cancel];
    iconReadOperation_ = nil;
    [remoteIconTask_ cancel];
    remoteIconTask_ = nil;
    representedPackageIdentifier_ = nil;
    [iconView_ setImage:nil];
    [paidView_ setHidden:YES];
    commercial_ = false;
    [super prepareForReuse];
}

- (void) setPackage:(Package *)package asSummary:(bool)summary {
    summarized_ = summary;

    NSUInteger generation(++iconRequestGeneration_);
    [iconReadOperation_ cancel];
    iconReadOperation_ = nil;
    [remoteIconTask_ cancel];
    remoteIconTask_ = nil;
    representedPackageIdentifier_ = package == nil ? nil : [NSString stringWithString:[package id]];

    icon_ = nil;
    name_ = nil;
    description_ = nil;
    source_ = nil;
    badge_ = nil;
    placard_ = nil;
    commercial_ = false;

    if (package == nil)
        [self setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];
    else {
        [package parse];

        Source *source = [package source];

        icon_ = [package icon];

        if (NSString *name = [package name])
            name_ = [NSString stringWithString:name];

        if (NSString *description = [package shortDescription])
            description_ = [NSString stringWithString:description];

        commercial_ = [package isCommercial];

        NSString *label = nil;

        if (source != nil)
            label = [source label];
        else if ([[package id] isEqualToString:@"firmware"])
            label = UCLocalize("APPLE");
        else
            label = [NSString stringWithFormat:UCLocalize("SLASH_DELIMITED"), UCLocalize("UNKNOWN"), UCLocalize("LOCAL")];

        NSString *from(label);

        NSString *section = [package simpleSection];
        if (section != nil && ![section isEqualToString:label]) {
            section = [[NSBundle mainBundle] localizedStringForKey:section value:nil table:@"Sections"];
            from = [NSString stringWithFormat:UCLocalize("PARENTHETICAL"), from, section];
        }

        source_ = [NSString stringWithFormat:UCLocalize("FROM"), from];

        if (NSString *purpose = [package primaryPurpose])
            badge_ = [UIImage imageAtPath:[NSString stringWithFormat:@"%@/Purposes/%@.png", App_, purpose]];

        UIColor *color;
        NSString *placard;

        if (NSString *mode = [package mode]) {
            if ([mode isEqualToString:@"REMOVE"] || [mode isEqualToString:@"PURGE"]) {
                color = CYModernQueuedColor(YES);
                placard = @"removing";
            } else {
                color = CYModernQueuedColor(NO);
                placard = @"installing";
            }
        } else {
            color = CYModernCellBackgroundColor();

            if ([package installed] != nil)
                placard = @"installed";
            else
                placard = nil;
        }

        [self setBackgroundColor:color];

        if (placard != nil)
            placard_ = [UIImage imageAtPath:[NSString stringWithFormat:@"%@/%@.png", App_, placard]];
    }

    UIImage *packageIcon(icon_);
    [iconView_ setImage:packageIcon != nil ? packageIcon : CYModernPackageFallbackIcon(nil, package == nil ? nil : [package id])];

    NSURL *remoteIconURL(package == nil ? nil : [package remoteIconURL]);
    NSString *remoteIconAddress([remoteIconURL absoluteString]);
    UIImage *cachedRemoteIcon([remoteIconAddress length] == 0 ? nil :
        [CYModernPackageIconCache() objectForKey:remoteIconAddress]);
    if (cachedRemoteIcon != nil) {
        [iconView_ setImage:cachedRemoteIcon];
    } else if ([remoteIconAddress length] != 0) {
        NSString *requestedIdentifier([NSString stringWithString:[package id]]);
        CGFloat scale([[UIScreen mainScreen] scale]);
        iconReadOperation_ = [NSBlockOperation blockOperationWithBlock:^{
            @autoreleasepool {
                UIImage *diskIcon([CYModernPackageIconCache() objectForKey:remoteIconAddress]);
                if (diskIcon == nil)
                    diskIcon = CYModernPackageIconFromDisk(remoteIconAddress);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != iconRequestGeneration_ || ![representedPackageIdentifier_ isEqualToString:requestedIdentifier])
                        return;
                    iconReadOperation_ = nil;
                    if (diskIcon != nil) {
                        [iconView_ setImage:diskIcon];
                        return;
                    }
                    NSURLRequest *request([NSURLRequest requestWithURL:remoteIconURL
                        cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:15.0]);
                    remoteIconTask_ = [[NSURLSession sharedSession] dataTaskWithRequest:request
                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                            NSHTTPURLResponse *http([response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil);
                            if (error != nil || [http statusCode] != 200)
                                return;
                            UIImage *downloaded(CYPreparedPackageIcon(data, scale));
                            if (downloaded == nil)
                                return;
                            [CYModernPackageIconCache() setObject:downloaded forKey:remoteIconAddress cost:CYPackageIconMemoryCost(downloaded)];
                            CYPersistModernPackageIcon(remoteIconAddress, data);
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (generation != iconRequestGeneration_ || ![representedPackageIdentifier_ isEqualToString:requestedIdentifier])
                                    return;
                                // No per-row cross-dissolve while the list is moving.
                                [iconView_ setImage:downloaded];
                                remoteIconTask_ = nil;
                            });
                        }];
                    [remoteIconTask_ resume];
                });
            }
        }];
        [CYPackageIconReadQueue() addOperation:iconReadOperation_];
    }
    [badgeView_ setImage:badge_];
    [badgeView_ setHidden:badge_ == nil];
    [paidView_ setHidden:!commercial_];
    [paidView_ setTintColor:CYModernCommercialColor()];
    [nameLabel_ setText:name_];
    [nameLabel_ setTextColor:commercial_ ? CYModernCommercialColor() : [UIColor labelColor]];
    [sourceLabel_ setText:source_];
    [sourceLabel_ setTextColor:commercial_ ? CYModernCommercialColor() : CYModernLabelColor()];
    [descriptionLabel_ setText:description_];
    [descriptionLabel_ setTextColor:CYModernPackageDescriptionColor(commercial_)];
    [sourceLabel_ setHidden:summarized_];
    [descriptionLabel_ setHidden:summarized_];

    NSString *mode(package == nil ? nil : [package mode]);
    if ([mode isEqualToString:@"REMOVE"] || [mode isEqualToString:@"PURGE"]) {
        [statusView_ setImage:[UIImage cy_symbolNamed:@"minus.circle.fill"]];
        [statusView_ setTintColor:[UIColor systemRedColor]];
        [statusView_ setHidden:NO];
    } else if (mode != nil) {
        [statusView_ setImage:[UIImage cy_symbolNamed:@"arrow.down.circle.fill"]];
        [statusView_ setTintColor:CYModernAccentColor()];
        [statusView_ setHidden:NO];
    } else if (package != nil && [package installed] != nil) {
        [statusView_ setImage:[UIImage cy_symbolNamed:@"checkmark.circle.fill"]];
        [statusView_ setTintColor:[UIColor systemGreenColor]];
        [statusView_ setHidden:NO];
    } else {
        [statusView_ setHidden:YES];
    }
}

- (void) drawSummaryContentRect:(CGRect)rect {
    float width([self bounds].size.width);

    if (icon_ != nil) {
        CGRect rect;
        rect.size = [(UIImage *) icon_ size];

        while (rect.size.width > 16 || rect.size.height > 16) {
            rect.size.width /= 2;
            rect.size.height /= 2;
        }

        rect.origin.x = 19 - rect.size.width / 2;
        rect.origin.y = 19 - rect.size.height / 2;

        [icon_ drawInRect:Retina(rect)];
    }

    if (badge_ != nil) {
        CGRect rect;
        rect.size = [(UIImage *) badge_ size];

        rect.size.width /= 4;
        rect.size.height /= 4;

        rect.origin.x = 25 - rect.size.width / 2;
        rect.origin.y = 25 - rect.size.height / 2;

        [badge_ drawInRect:Retina(rect)];
    }

    [(commercial_ ? CYModernCommercialColor() : CYModernLabelColor()) set];
    [name_ drawAtPoint:CGPointMake(36, 8) forWidth:(width - (placard_ == nil ? 68 : 94)) withFont:Font18Bold_ lineBreakMode:NSLineBreakByTruncatingTail];

    if (placard_ != nil)
        [placard_ drawAtPoint:CGPointMake(width - 52, 11)];
}

- (void) drawNormalContentRect:(CGRect)rect {
    float width([self bounds].size.width);

    if (icon_ != nil) {
        CGRect rect;
        rect.size = [(UIImage *) icon_ size];

        while (rect.size.width > 32 || rect.size.height > 32) {
            rect.size.width /= 2;
            rect.size.height /= 2;
        }

        rect.origin.x = 25 - rect.size.width / 2;
        rect.origin.y = 25 - rect.size.height / 2;

        [icon_ drawInRect:Retina(rect)];
    }

    if (badge_ != nil) {
        CGRect rect;
        rect.size = [(UIImage *) badge_ size];

        rect.size.width /= 2;
        rect.size.height /= 2;

        rect.origin.x = 36 - rect.size.width / 2;
        rect.origin.y = 36 - rect.size.height / 2;

        [badge_ drawInRect:Retina(rect)];
    }

    [(commercial_ ? CYModernCommercialColor() : CYModernLabelColor()) set];
    [name_ drawAtPoint:CGPointMake(48, 8) forWidth:(width - (placard_ == nil ? 80 : 106)) withFont:Font18Bold_ lineBreakMode:NSLineBreakByTruncatingTail];
    [source_ drawAtPoint:CGPointMake(58, 29) forWidth:(width - 95) withFont:Font12_ lineBreakMode:NSLineBreakByTruncatingTail];

    [CYModernPackageDescriptionColor(commercial_) set];
    [description_ drawAtPoint:CGPointMake(12, 46) forWidth:(width - 46) withFont:Font14_ lineBreakMode:NSLineBreakByTruncatingTail];

    if (placard_ != nil)
        [placard_ drawAtPoint:CGPointMake(width - 52, 9)];
}

- (void) drawContentRect:(CGRect)rect {
    // Native labels and image views provide Dynamic Type and modern tinting.
}

@end
/* }}} */
/* Section Cell {{{ */
@interface SectionCell : CyteTableViewCell <
    CyteTableViewCellDelegate
> {
    _H<NSString> basic_;
    _H<NSString> section_;
    _H<NSString> name_;
    _H<NSString> count_;
    _H<UIImageView> symbol_;
    _H<UILabel> titleLabel_;
    _H<UILabel> countLabel_;
    _H<UISwitch> switch_;
    BOOL editing_;
}

- (void) setSection:(Section *)section editing:(BOOL)editing;

@end

@implementation SectionCell

- (id) initWithFrame:(CGRect)frame reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithFrame:frame reuseIdentifier:reuseIdentifier]) != nil) {
        [self.content setHidden:YES];
        [self setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];

        symbol_ = [[[CydiaSymbolView alloc] initWithImage:CYNoSectionIcon()] autorelease];
        [symbol_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [symbol_ setContentMode:UIViewContentModeScaleAspectFit];
        [symbol_ setBackgroundColor:[UIColor clearColor]];
        [[symbol_ layer] setCornerRadius:10.0f];
        [[symbol_ layer] setCornerCurve:kCACornerCurveContinuous];
        [[symbol_ layer] setMasksToBounds:YES];

        titleLabel_ = [[[UILabel alloc] init] autorelease];
        [titleLabel_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [titleLabel_ setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]];
        [titleLabel_ setTextColor:[UIColor labelColor]];
        [titleLabel_ setAdjustsFontForContentSizeCategory:YES];

        countLabel_ = [[[UILabel alloc] init] autorelease];
        [countLabel_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [countLabel_ setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]];
        [countLabel_ setTextColor:[UIColor secondaryLabelColor]];
        [countLabel_ setTextAlignment:NSTextAlignmentCenter];
        [countLabel_ setAdjustsFontForContentSizeCategory:YES];
        [countLabel_ setBackgroundColor:[UIColor clearColor]];
        [countLabel_ setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        [[self contentView] addSubview:symbol_];
        [[self contentView] addSubview:titleLabel_];
        [[self contentView] addSubview:countLabel_];

        [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
            [[symbol_ leadingAnchor] constraintEqualToAnchor:[[self contentView] leadingAnchor] constant:14.0f],
            [[symbol_ centerYAnchor] constraintEqualToAnchor:[[self contentView] centerYAnchor]],
            [[symbol_ widthAnchor] constraintEqualToConstant:42.0f],
            [[symbol_ heightAnchor] constraintEqualToConstant:42.0f],
            [[titleLabel_ leadingAnchor] constraintEqualToAnchor:[symbol_ trailingAnchor] constant:10.0f],
            [[titleLabel_ centerYAnchor] constraintEqualToAnchor:[[self contentView] centerYAnchor]],
            [[titleLabel_ trailingAnchor] constraintLessThanOrEqualToAnchor:[countLabel_ leadingAnchor] constant:-10.0f],
            [[countLabel_ trailingAnchor] constraintEqualToAnchor:[[self contentView] trailingAnchor] constant:-10.0f],
            [[countLabel_ centerYAnchor] constraintEqualToAnchor:[[self contentView] centerYAnchor]],
            [[countLabel_ widthAnchor] constraintGreaterThanOrEqualToConstant:24.0f],
        nil]];

        switch_ = [[[UISwitch alloc] initWithFrame:CGRectZero] autorelease];
        [switch_ addTarget:self action:@selector(onSwitch:) forEvents:UIControlEventValueChanged];
    } return self;
}

- (void) onSwitch:(id)sender {
    NSMutableDictionary *metadata([Sections_ objectForKey:basic_]);
    if (metadata == nil) {
        metadata = [NSMutableDictionary dictionaryWithCapacity:2];
        [Sections_ setObject:metadata forKey:basic_];
    }

    [metadata setObject:[NSNumber numberWithBool:([switch_ isOn] == NO)] forKey:@"Hidden"];
}

- (void) setSection:(Section *)section editing:(BOOL)editing {
    editing_ = editing;

    basic_ = nil;
    section_ = nil;
    name_ = nil;
    count_ = nil;

    if (section == nil) {
        name_ = UCLocalize("ALL_PACKAGES");
        count_ = nil;
        [symbol_ setImage:[UIImage cy_symbolNamed:@"shippingbox.fill"]];
        [symbol_ setTintColor:CYModernAccentColor()];
        [symbol_ setBackgroundColor:[CYModernAccentColor() colorWithAlphaComponent:0.10f]];
    } else {
        basic_ = [section name];
        section_ = [section localized];

        name_  = section_ == nil || [section_ length] == 0 ? UCLocalize("NO_SECTION") : (NSString *) section_;
        count_ = [NSString stringWithFormat:@"%zd", [section count]];

        if (editing_)
            [switch_ setOn:(isSectionVisible(basic_) ? 1 : 0) animated:NO];
        UIImage *image(CYSectionIconImage(basic_ ?: name_) ?: CYNoSectionIcon());
        [symbol_ setImage:[image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]];
        [symbol_ setTintColor:nil];
        [symbol_ setBackgroundColor:[UIColor clearColor]];
    }

    [titleLabel_ setText:name_];
    [countLabel_ setText:count_];
    [countLabel_ setHidden:count_ == nil];
    [self setAccessoryView:editing ? switch_ : nil];
    [self setAccessoryType:editing ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator];
    [self setSelectionStyle:editing ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault];
}

- (NSString *) accessibilityLabel {
    return name_;
}

- (void) drawContentRect:(CGRect)rect {
    // Native subviews above provide Dynamic Type, tinting and accessibility.
}

@end
/* }}} */

/* File Table {{{ */
#import "Cydia/InstalledFilesView.h"
@interface FileTable : CyteViewController {
    _transient Database *database_;
    _H<Package> package_;
    _H<NSString> name_;
    _H<CydiaInstalledFilesView> filesView_;
}
- (id)initWithDatabase:(Database *)database forPackage:(NSString *)name;
@end

@implementation FileTable
- (id)initWithDatabase:(Database *)database forPackage:(NSString *)name {
    if ((self = [super init])) {
        database_ = database; name_ = name;
        [[self navigationItem] setTitle:UCLocalize("INSTALLED_FILES")];
    }
    return self;
}
- (void)loadView {
    filesView_ = [[[CydiaInstalledFilesView alloc] initWithFrame:CGRectZero] autorelease];
    [self setView:filesView_];
}
- (NSURL *)navigationURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@/files", (NSString *)name_]];
}
- (void)reloadData {
    [super reloadData];
    _H<NSArray> paths;
    _H<NSString> packageName;
    @synchronized (database_) {
        package_ = [database_ packageWithName:name_];
        paths = [NSArray arrayWithArray:[package_ files] ?: @[]];
        packageName = [package_ name] ?: (NSString *)name_;
    }
    NSMutableSet *directories = [NSMutableSet set];
    for (id path in (NSArray *)paths) {
        if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"] ||
            [[path pathComponents] containsObject:@".."]) continue;
        // Only inspect the manifest entry's type, including empty directories.
        // Symbolic links remain file entries; their contents are never traversed.
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if ([attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) [directories addObject:path];
    }
    [filesView_ setFilePaths:paths directories:directories packageName:packageName];
}
- (void)releaseSubviews {
    package_ = nil; filesView_ = nil;
    [super releaseSubviews];
}
@end
/* }}} */
/* Package Controller {{{ */
#import "Cydia/PackageActionsController.h"
enum CYCommercialPackageAccess {
    CYCommercialPackageAccessUnknown,
    CYCommercialPackageAccessChecking,
    CYCommercialPackageAccessInstall,
    CYCommercialPackageAccessSignIn,
    CYCommercialPackageAccessBuy,
    CYCommercialPackageAccessRetry,
    CYCommercialPackageAccessUnavailable,
};

@interface CYPackageController : CydiaWebViewController <
    ASWebAuthenticationPresentationContextProviding
> {
    _transient Database *database_;
    _H<Package> package_;
    _H<NSString> name_;
    bool commercial_;
    std::vector<std::pair<_H<NSString>, _H<NSString>>> buttons_;
    _H<NSArray> versions_;
    _H<CydiaModernPackageDetailView> modernDetail_;
    _H<ASWebAuthenticationSession> purchaseSession_;
    unsigned purchaseEra_;
    bool purchaseInProgress_;
    CYCommercialPackageAccess purchaseAccess_;
    _H<NSString> purchasePrice_;
    BOOL purchaseReturnToVersions_;
    _H<NSArray> purchaseIdentity_;
    NSUInteger purchaseAccountRevision_;
    NSTimeInterval purchaseCheckedAt_;
    BOOL purchaseInfoPending_;
    BOOL purchaseTransitioning_;
    BOOL reloadAfterPurchaseTransition_;
    BOOL purchaseRefreshOnActive_;
    _H<NSString> purchaseFailure_;
    _H<Package> pendingCommercialPackage_;
    unsigned pendingCommercialDatabaseEra_;
    _H<NSURLSessionDataTask> detailIconTask_;
}

- (id) initWithDatabase:(Database *)database forPackage:(NSString *)name withReferrer:(NSString *)referrer;

@end

@implementation CYPackageController

- (void) loadView {
    [self setView:CYModernNativeControllerRoot(@"package-details")];
}

- (void) viewDidLoad {
    [super viewDidLoad];

    // Details is fully native.  Do not construct the obsolete about:blank
    // UIWebView underneath it: WebKitLegacy timers can corrupt their heap on
    // iOS 17 while a paid-package APT/dpkg transaction is running.
    [[self view] setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
    [[self navigationItem] setRightBarButtonItem:nil animated:NO];
    modernDetail_ = [[[CydiaModernPackageDetailView alloc] initWithFrame:CGRectZero] autorelease];
    [[self view] addSubview:modernDetail_];
    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [[modernDetail_ leadingAnchor] constraintEqualToAnchor:[[self view] leadingAnchor]],
        [[modernDetail_ trailingAnchor] constraintEqualToAnchor:[[self view] trailingAnchor]],
        [[modernDetail_ topAnchor] constraintEqualToAnchor:[[self view] topAnchor]],
        [[modernDetail_ bottomAnchor] constraintEqualToAnchor:[[self view] bottomAnchor]],
    nil]];
    [modernDetail_ setNavigationTarget:self settingsAction:@selector(openPackageSettings) filesAction:@selector(openPackageFiles) showFiles:NO];
    [self reloadData];
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@", (id) name_]];
}

- (void) _clickButtonWithPackage:(Package *)package {
    if (package == nil || purchaseInProgress_) return;
    if ([package isCommercial]) {
        [self updateCommercialPurchaseAction:NO];
        if (purchaseInfoPending_) {
            pendingCommercialPackage_ = package;
            pendingCommercialDatabaseEra_ = [database_ era];
            return;
        }
        switch (purchaseAccess_) {
            case CYCommercialPackageAccessSignIn:
            case CYCommercialPackageAccessUnavailable: [self openRepositoryAccount]; return;
            case CYCommercialPackageAccessBuy: [self confirmPurchaseForPackage:package]; return;
            case CYCommercialPackageAccessRetry: [self refreshCommercialPurchaseAction]; return;
            case CYCommercialPackageAccessUnknown:
            case CYCommercialPackageAccessChecking: return;
            case CYCommercialPackageAccessInstall: break;
        }
    }
    [self.delegate installPackage:package];
}

- (void)presentPackageActions:(NSArray *)actions title:(NSString *)title selection:(void (^)(NSString *))selection {
    UINavigationController *existing(CYPackageActionsNavigation(self));
    if (existing == nil) existing = CYPackageActionsNavigation([[[self view] window] rootViewController]);
    if ([self presentedViewController] != nil && existing == nil) return;
    NSString *iconAddress([[package_ remoteIconURL] absoluteString]);
    UIImage *icon(nil);
    if ([iconAddress length] != 0) {
        icon = [CYModernPackageIconCache() objectForKey:iconAddress];
        if (icon == nil) icon = CYModernPackageIconFromDisk(iconAddress);
    }
    if (icon == nil) icon = [package_ icon];
    CydiaPackageActionsController *page = [[[CydiaPackageActionsController alloc]
        initWithTitle:title packageName:[package_ name] version:[package_ installed] ?: [package_ latest]
        icon:icon actions:actions selection:selection] autorelease];
    if (existing != nil) {
        CYReplacePackagePanel(existing, page);
        [existing setModalInPresentation:NO];
        return;
    }
    CydiaModernNavigationController *navigation = [[[CydiaModernNavigationController alloc] initWithRootViewController:page] autorelease];
    [navigation setModalPresentationStyle:UIModalPresentationPageSheet];
    CYModernizeNavigationController(navigation);
    UISheetPresentationController *sheet = [navigation sheetPresentationController];
    [sheet setDetents:@[[UISheetPresentationControllerDetent largeDetent]]];
    [sheet setSelectedDetentIdentifier:UISheetPresentationControllerDetentIdentifierLarge];
    [sheet setPreferredCornerRadius:32];
    [sheet setPrefersGrabberVisible:YES];
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void) _clickButtonWithName:(NSString *)name {
    if ([name isEqualToString:@"CLEAR"])
        return [self.delegate clearPackage:package_];
    else if ([name isEqualToString:@"REMOVE"])
        return [self.delegate removePackage:package_];
    else if ([name isEqualToString:@"DOWNGRADE"]) {
        NSArray *versions = [NSArray arrayWithArray:(NSArray *)versions_ ?: @[]];
        unsigned era = [database_ era];
        NSMutableArray *actions = [NSMutableArray array];
        for (NSUInteger i = 0; i < [versions count]; ++i) {
            Package *version = versions[i];
            [actions addObject:@{@"id":[NSString stringWithFormat:@"%lu",(unsigned long)i],
                @"title":[version latest] ?: @"", @"symbol":@"arrow.down.circle"}];
        }
        [self presentPackageActions:actions title:UCLocalize("DOWNGRADE") selection:^(NSString *identifier) {
            if (era != [database_ era]) { [self reloadData]; return; }
            NSUInteger index = [identifier integerValue];
            if (index < versions.count) [self _clickButtonWithPackage:versions[index]];
        }];
        return;
    }
    else if ([name isEqualToString:@"INSTALL"]);
    else if ([name isEqualToString:@"REINSTALL"]);
    else if ([name isEqualToString:@"UPGRADE"]);
    else return;
    [self _clickButtonWithPackage:package_];
}

- (bool) _allowJavaScriptPanel {
    return commercial_;
}

#if !AlwaysReload
- (void) _customButtonClicked {
    size_t count(buttons_.size());
    if (count == 0)
        return;

    if (count == 1)
        [self _clickButtonWithName:buttons_[0].first];
    else {
        NSMutableArray *actions = [NSMutableArray arrayWithCapacity:count];
        NSDictionary *symbols = @{@"REINSTALL":@"arrow.triangle.2.circlepath", @"REMOVE":@"trash",
            @"DOWNGRADE":@"arrow.down.circle", @"UPGRADE":@"arrow.up.circle", @"INSTALL":@"arrow.down.circle", @"CLEAR":@"xmark.circle"};
        for (const auto &button : buttons_) {
            NSString *identifier = button.first;
            [actions addObject:@{@"id":identifier, @"title":(NSString *)button.second,
                @"symbol":symbols[identifier] ?: @"shippingbox", @"destructive":@([identifier isEqualToString:@"REMOVE"])}];
        }
        unsigned era = [database_ era];
        CYPresentPackageActionMenu(self, [modernDetail_ actionSourceView], actions, ^(NSString *identifier) {
            if (era != [database_ era]) { [self reloadData]; return; }
            for (const auto &button : buttons_)
                if ([button.first isEqualToString:identifier]) { [self _clickButtonWithName:identifier]; return; }
        });
    }
}

- (void) applyLoadingTitle {
    // Don't show "Loading" as the title. Ever.
}

- (UIBarButtonItem *) rightButton {
    return nil;
}
#endif

- (void) openPackageComponent:(NSString *)component {
    if ([name_ length] == 0 || [component length] == 0)
        return;
    NSString *escaped([name_ stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]);
    NSURL *url([NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@/%@", escaped, component]]);
    CyteViewController *page([self.delegate pageForURL:url forExternal:NO withReferrer:[[self navigationURL] absoluteString]]);
    if (page != nil)
        [[self navigationController] pushViewController:page animated:YES];
}

- (void) openPackageSettings {
    [self openPackageComponent:@"settings"];
}

- (void) openPackageFiles {
    [self openPackageComponent:@"files"];
}

- (void) setPageColor:(UIColor *)color {
    return [super setPageColor:nil];
}

- (id) initWithDatabase:(Database *)database forPackage:(NSString *)name withReferrer:(NSString *)referrer {
    if ((self = [super init]) != nil) {
        database_ = database;
        name_ = name == nil ? @"" : [NSString stringWithString:name];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(repositoryAccountStateChanged:)
            name:CYRepositoryAccountStateDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(repositoryAccountStateChanged:)
            name:UIApplicationDidBecomeActiveNotification object:nil];
    } return self;
}

- (void) reloadData {
    if (purchaseTransitioning_) { reloadAfterPurchaseTransition_ = YES; return; }
    [super reloadData];
    [detailIconTask_ cancel];
    detailIconTask_ = nil;

    UINavigationController *presented = (UINavigationController *)[self presentedViewController];
    if (CYInvalidatePackageActionMenu(presented))
        [presented dismissViewControllerAnimated:NO completion:nil];
    else if ([presented isKindOfClass:UINavigationController.class] &&
        [[presented topViewController] isKindOfClass:CydiaPackageActionsController.class]) {
        [(CydiaPackageActionsController *)[presented topViewController] invalidateSelection];
        [presented dismissViewControllerAnimated:NO completion:nil];
    }

    package_ = [database_ packageWithName:name_];
    versions_ = [package_ downgrades];

    buttons_.clear();

    if (package_ != nil) {
        [(Package *) package_ parse];

        commercial_ = [package_ isCommercial];

        if ([package_ mode] != nil)
            buttons_.push_back(std::make_pair(@"CLEAR", UCLocalize("CLEAR")));
        if ([package_ source] == nil);
        else if ([package_ upgradableAndEssential:NO])
            buttons_.push_back(std::make_pair(@"UPGRADE", UCLocalize("UPGRADE")));
        else if ([package_ uninstalled])
            buttons_.push_back(std::make_pair(@"INSTALL", UCLocalize("INSTALL")));
        else
            buttons_.push_back(std::make_pair(@"REINSTALL", UCLocalize("REINSTALL")));
        if (![package_ uninstalled])
            buttons_.push_back(std::make_pair(@"REMOVE", UCLocalize("REMOVE")));
        if ([versions_ count] != 0)
            buttons_.push_back(std::make_pair(@"DOWNGRADE", UCLocalize("DOWNGRADE")));
    }

    NSString *title;
    switch (buttons_.size()) {
        case 0: title = nil; break;
        case 1: title = buttons_[0].second; break;
        default: title = UCLocalize("MODIFY"); break;
    }

    [[self navigationItem] setRightBarButtonItem:nil animated:NO];
    if (package_ == nil) {
        // A stale deep link or a package removed during Refresh must end in a
        // clear recoverable state, never in the permanent skeleton/spinner.
        ++purchaseEra_;
        purchaseInProgress_ = false;
        purchaseReturnToVersions_ = NO;
        purchaseRefreshOnActive_ = NO;
        [purchaseSession_ cancel];
        purchaseSession_ = nil;
        purchaseInfoPending_ = NO;
        purchaseIdentity_ = nil;
        pendingCommercialPackage_ = nil;
        commercial_ = false;
        [modernDetail_ setAccountNotice:nil target:nil action:NULL];
        [modernDetail_ setCommercial:NO];
        [modernDetail_ setUnavailableIdentifier:name_];
        [modernDetail_ setActionTitle:nil destructive:NO target:self action:@selector(customButtonClicked)];
        [modernDetail_ setNavigationTarget:self settingsAction:@selector(openPackageSettings) filesAction:@selector(openPackageFiles) showFiles:NO];
    } else {
        Source *source([package_ source]);
        NSString *repository(source == nil ? CYLocalize(@"Local") : ([source label] ?: [source name]));
        NSString *section([package_ simpleSection]);
        if ([section length] != 0)
            section = [[NSBundle mainBundle] localizedStringForKey:section value:section table:@"Sections"];
        MIMEAddress *address([package_ author] ?: [package_ maintainer]);
        NSString *author(address == nil ? nil : [address name]);
        if ([author length] == 0)
            author = [address address];
        size_t packageSize([package_ size]);
        NSString *size(packageSize == 0 ? @"—" : [NSByteCountFormatter stringFromByteCount:(long long) packageSize countStyle:NSByteCountFormatterCountStyleFile]);
        [modernDetail_ configureWithIcon:[package_ icon]
                                    name:[package_ name]
                              identifier:[package_ id]
                                 summary:[package_ shortDescription]
                        availableVersion:[package_ latest]
                        installedVersion:[package_ installed]
                              repository:repository
                                 section:section
                                    size:size
                                  author:author];
        // Load the repository-hosted icon like the package list does, so
        // Package Details shows the package's own icon instead of only the
        // local/section fallback. Memory -> on-disk cache -> bounded fetch.
        NSURL *remoteIconURL([package_ remoteIconURL]);
        NSString *remoteIconAddress([remoteIconURL absoluteString]);
        if ([remoteIconAddress length] != 0) {
            UIImage *cachedIcon([CYModernPackageIconCache() objectForKey:remoteIconAddress]);
            if (cachedIcon == nil)
                cachedIcon = CYModernPackageIconFromDisk(remoteIconAddress);
            if (cachedIcon != nil)
                [modernDetail_ updateHeroIcon:cachedIcon];
            else {
                NSString *requestedIdentifier([NSString stringWithString:[package_ id]]);
                NSURLRequest *iconRequest([NSURLRequest requestWithURL:remoteIconURL
                    cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:15.0]);
                [detailIconTask_ cancel];
                detailIconTask_ = [[NSURLSession sharedSession] dataTaskWithRequest:iconRequest
                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                        NSHTTPURLResponse *http([response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *) response : nil);
                        if (error != nil || [http statusCode] != 200 || [data length] == 0 || [data length] > 3 * 1024 * 1024)
                            return;
                        UIImage *downloaded(CYPreparedPackageIcon(data, [[UIScreen mainScreen] scale]));
                        if (downloaded == nil || [downloaded size].width < 2.0f || [downloaded size].height < 2.0f)
                            return;
                        [CYModernPackageIconCache() setObject:downloaded forKey:remoteIconAddress cost:CYPackageIconMemoryCost(downloaded)];
                        CYPersistModernPackageIcon(remoteIconAddress, data);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (package_ == nil || ![[package_ id] isEqualToString:requestedIdentifier])
                                return;
                            [modernDetail_ updateHeroIcon:downloaded];
                        });
                    }];
                [detailIconTask_ resume];
            }
        }
        [modernDetail_ setCommercial:commercial_];
        BOOL destructive(buttons_.size() == 1 && [buttons_[0].first isEqualToString:@"REMOVE"]);
        if (!commercial_ || source == nil)
            [modernDetail_ setActionTitle:title destructive:destructive target:self action:@selector(customButtonClicked)];
        [modernDetail_ setNavigationTarget:self settingsAction:@selector(openPackageSettings) filesAction:@selector(openPackageFiles) showFiles:[package_ installed] != nil];
        if (commercial_ && source != nil)
            [self updateCommercialPurchaseAction:NO];
        else {
            ++purchaseEra_;
            purchaseInProgress_ = false;
            purchaseReturnToVersions_ = NO;
            purchaseRefreshOnActive_ = NO;
            [purchaseSession_ cancel];
            purchaseSession_ = nil;
            purchaseInfoPending_ = NO;
            purchaseIdentity_ = nil;
            pendingCommercialPackage_ = nil;
            [modernDetail_ setAccountNotice:nil target:nil action:NULL];
            [modernDetail_ setActionEnabled:YES];
        }
    }
}

// Payment providers remain authoritative for access. A commercial tag alone
// neither grants a download nor tells the user where to connect an account.
// Every entry point renders the same model. Account guidance stays attached;
// asynchronous checking changes only the reserved status caption.
- (void) renderCommercialPurchaseAction {
    if (purchaseTransitioning_ || package_ == nil || !commercial_ || [package_ source] == nil) return;
    BOOL primaryInstall([package_ uninstalled] && [package_ mode] == nil);
    NSString *title(buttons_.empty() ? nil : (buttons_.size() == 1 ? (NSString *)buttons_[0].second : UCLocalize("MODIFY")));
    SEL action(@selector(customButtonClicked));
    NSString *detail([package_ installed] ?: CYLocalize(@"Ready to review"));
    BOOL enabled(YES);
    if (primaryInstall) {
        title = UCLocalize("INSTALL");
        switch (purchaseAccess_) {
            case CYCommercialPackageAccessSignIn:
                title = CYLocalize(@"Sign In"); action = @selector(openRepositoryAccount);
                detail = CYLocalize(@"Sign in through Manage Account first."); break;
            case CYCommercialPackageAccessBuy:
                title = [purchasePrice_ length] == 0 ? CYLocalize(@"Buy") :
                    [NSString stringWithFormat:CYLocalize(@"Buy · %@"), (NSString *)purchasePrice_];
                action = @selector(confirmCurrentPackagePurchase); detail = CYLocalize(@"Purchase"); break;
            case CYCommercialPackageAccessRetry:
                title = CYLocalize(@"Try Again"); action = @selector(refreshCommercialPurchaseAction);
                detail = (NSString *)purchaseFailure_ ?: CYLocalize(@"The repository account rejected the request."); break;
            case CYCommercialPackageAccessUnavailable:
                title = CYLocalize(@"Manage Account"); action = @selector(openRepositoryAccount);
                detail = CYLocalize(@"This package cannot be purchased."); break;
            case CYCommercialPackageAccessUnknown:
            case CYCommercialPackageAccessChecking: enabled = NO; break;
            case CYCommercialPackageAccessInstall: break;
        }
    }
    if (purchaseInfoPending_) {
        detail = CYLocalize(@"Checking purchase…");
        if (primaryInstall) enabled = NO;
    }
    if (purchaseInProgress_) { detail = CYLocalize(@"Purchasing\u2026"); enabled = NO; }
    NSDictionary *accountState(CYRepositoryAccountStateSnapshot([[package_ source] rooturi]));
    [modernDetail_ setAccountState:[accountState objectForKey:@"state"]];
    [modernDetail_ setAccountNotice:CYLocalize(@"Manage sign-ins and explore your purchases.")
        target:self action:@selector(openRepositoryAccount)];
    [modernDetail_ setActionTitle:title destructive:(buttons_.size() == 1 && [buttons_[0].first isEqualToString:@"REMOVE"])
        target:self action:action];
    [modernDetail_ setActionEnabled:enabled];
    [modernDetail_ setActionStatusDetail:detail];
}

- (void) acceptCommercialPackageInfo:(NSDictionary *)info error:(NSError *)error {
    purchasePrice_ = nil;
    purchaseFailure_ = nil;
    if (CYRepositoryAccountErrorRequiresSignIn(error)) purchaseAccess_ = CYCommercialPackageAccessSignIn;
    else if (info == nil && CYRepositoryAccountErrorIsUnsupportedProvider(error)) purchaseAccess_ = CYCommercialPackageAccessInstall;
    else if (info == nil) {
        purchaseAccess_ = CYCommercialPackageAccessRetry;
        purchaseFailure_ = [error localizedDescription];
    } else if ([[info objectForKey:@"purchased"] boolValue]) purchaseAccess_ = CYCommercialPackageAccessInstall;
    else if ([[info objectForKey:@"available"] boolValue]) {
        purchaseAccess_ = CYCommercialPackageAccessBuy;
        id price([info objectForKey:@"price"]);
        purchasePrice_ = [price isKindOfClass:NSString.class] ? price : nil;
    } else purchaseAccess_ = CYCommercialPackageAccessUnavailable;
    purchaseCheckedAt_ = [NSDate timeIntervalSinceReferenceDate];
}

- (void) resumePendingCommercialAction {
    if (pendingCommercialPackage_ == nil || purchaseInfoPending_ || purchaseTransitioning_) return;
    Package *selected([[pendingCommercialPackage_ retain] autorelease]);
    pendingCommercialPackage_ = nil;
    if (pendingCommercialDatabaseEra_ != [database_ era] || [[self navigationController] topViewController] != self) return;
    if (purchaseAccess_ == CYCommercialPackageAccessRetry) {
        [self presentPurchaseError:purchaseFailure_]; return;
    }
    [self _clickButtonWithPackage:selected];
}

- (void) updateCommercialPurchaseAction:(BOOL)force {
    Source *source([package_ source]);
    if (!commercial_ || package_ == nil || source == nil || purchaseInProgress_) return;
    NSString *repositoryURL([source rooturi]);
    NSString *packageID([package_ id]);
    NSString *model(Machine_ != NULL ? [NSString stringWithUTF8String:Machine_] : nil);
    NSArray *identity(@[repositoryURL ?: @"", packageID ?: @"", [package_ latest] ?: @""]);
    NSDictionary *account(CYRepositoryAccountStateSnapshot(repositoryURL));
    NSUInteger revision([[account objectForKey:@"revision"] unsignedIntegerValue]);
    if (![purchaseIdentity_ isEqual:identity] || purchaseAccountRevision_ != revision) {
        ++purchaseEra_;
        purchaseIdentity_ = identity;
        purchaseAccountRevision_ = revision;
        purchaseInfoPending_ = NO;
        purchaseCheckedAt_ = 0;
        purchaseAccess_ = CYCommercialPackageAccessUnknown;
        purchasePrice_ = nil;
        purchaseFailure_ = nil;
        pendingCommercialPackage_ = nil;
        purchaseReturnToVersions_ = NO;
    }
    NSString *state([account objectForKey:@"state"]);
    if ([state isEqualToString:@"signedOut"] || [state isEqualToString:@"unsupported"]) {
        purchaseAccess_ = [state isEqualToString:@"signedOut"] ? CYCommercialPackageAccessSignIn : CYCommercialPackageAccessInstall;
        [self renderCommercialPurchaseAction]; return;
    }
    NSDictionary *snapshot(CYRepositoryPackageInfoSnapshot(repositoryURL, packageID, UniqueID_, model));
    if (!force && [[snapshot objectForKey:@"fresh"] boolValue]) {
        [self acceptCommercialPackageInfo:[snapshot objectForKey:@"info"] error:[snapshot objectForKey:@"error"]];
        [self renderCommercialPurchaseAction]; return;
    }
    NSTimeInterval age([NSDate timeIntervalSinceReferenceDate] - purchaseCheckedAt_);
    NSTimeInterval lifetime(purchaseAccess_ == CYCommercialPackageAccessRetry ? 5.0 : 30.0);
    if (purchaseInfoPending_ || (!force && snapshot == nil && purchaseCheckedAt_ > 0 && age >= 0 && age < lifetime)) {
        [self renderCommercialPurchaseAction]; return;
    }
    if (purchaseAccess_ == CYCommercialPackageAccessUnknown) purchaseAccess_ = CYCommercialPackageAccessChecking;
    purchaseInfoPending_ = YES;
    unsigned era(++purchaseEra_);
    [self renderCommercialPurchaseAction];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error(nil);
        NSDictionary *info(CYRepositoryPackageInfo(repositoryURL, packageID, UniqueID_, model, &error));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (era != purchaseEra_ || ![purchaseIdentity_ isEqual:identity]) return;
            purchaseInfoPending_ = NO;
            if (revision != CYRepositoryAccountStateRevision()) { [self updateCommercialPurchaseAction:NO]; return; }
            [self acceptCommercialPackageInfo:info error:error];
            [self renderCommercialPurchaseAction];
            [self resumePendingCommercialAction];
        });
    });
}

- (void) repositoryAccountStateChanged:(NSNotification *)notification {
    if (![self isViewLoaded] || purchaseInProgress_) return;
    if ([[self navigationController] topViewController] != self) return;
    if (purchaseRefreshOnActive_ && [[notification name] isEqualToString:UIApplicationDidBecomeActiveNotification]) {
        purchaseRefreshOnActive_ = NO;
        [self updateCommercialPurchaseAction:YES]; return;
    }
    [self updateCommercialPurchaseAction:NO];
}

- (void) confirmCurrentPackagePurchase {
    [self confirmPurchaseForPackage:package_];
}

- (void) refreshCommercialPurchaseAction {
    [self updateCommercialPurchaseAction:YES];
}

- (void) openRepositoryAccount {
    Source *source([package_ source]);
    if (source == nil) return;
    UIViewController *presented([self presentedViewController]);
    if (presented != nil) {
        if ([presented isKindOfClass:UINavigationController.class] &&
            [[(UINavigationController *)presented topViewController] isKindOfClass:CydiaPackageActionsController.class]) {
            [(CydiaPackageActionsController *)[(UINavigationController *)presented topViewController] invalidateSelection];
            [presented dismissViewControllerAnimated:YES completion:^{ [self openRepositoryAccount]; }];
        }
        return;
    }
    pendingCommercialPackage_ = nil;
    NSString *repositoryURL([source rooturi]);
    if ([repositoryURL length] == 0) return;
    NSString *repositoryName([source label] ?: [source name] ?: CYLocalize(@"Repository"));
    NSDictionary *repository(@{CYRepositoryAccountNameKey:repositoryName, CYRepositoryAccountURLKey:repositoryURL});
    NSString *model(Machine_ != NULL ? [NSString stringWithUTF8String:Machine_] : nil);
    CydiaRepositoryAccountsViewController *accounts([[[CydiaRepositoryAccountsViewController alloc]
        initWithRepositories:@[repository] deviceIdentifier:UniqueID_ deviceModel:model] autorelease]);
    [accounts setPackageTarget:self action:@selector(openAccountPackage:)];
    Database *database(database_);
    [accounts setPackageResolver:^ NSDictionary *(NSString *identifier, NSString *url, BOOL loadIcon) {
        @synchronized (database) {
            Package *package([database packageWithName:identifier]);
            Source *repository(nil);
            for (Source *candidate in [database sources])
                if ([[candidate rooturi] isEqualToString:url]) { repository = candidate; break; }
            if (package == nil || repository == nil || ![package availableFromSource:repository])
                return nil;
            NSMutableDictionary *metadata([NSMutableDictionary dictionaryWithDictionary:@{
                @"name":[package name] ?: identifier, @"summary":[package shortDescription] ?: @"",
                @"installed":@([package installed] != nil)}]);
            if (loadIcon) {
                NSString *address([[package remoteIconURL] absoluteString]);
                UIImage *icon([address length] == 0 ? nil : [CYModernPackageIconCache() objectForKey:address]);
                if (icon == nil && [address length] != 0) icon = CYModernPackageIconFromDisk(address);
                if (icon == nil) icon = [package icon];
                if (icon != nil) [metadata setObject:icon forKey:@"icon"];
            }
            return metadata;
        }
    }];
    [[self navigationController] pushViewController:accounts animated:YES];
}

- (void) openAccountPackage:(NSString *)identifier {
    if ([identifier length] == 0) return;
    CYPackageController *details([[[CYPackageController alloc] initWithDatabase:database_
        forPackage:identifier withReferrer:nil] autorelease]);
    [details setDelegate:self.delegate];
    [[self navigationController] pushViewController:details animated:YES];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Re-evaluate on every appearance, including a cancelled interactive Back.
    [self updateCommercialPurchaseAction:NO];
    purchaseTransitioning_ = animated && [self transitionCoordinator] != nil;
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    purchaseTransitioning_ = NO;
    if (reloadAfterPurchaseTransition_) { reloadAfterPurchaseTransition_ = NO; [self reloadData]; }
    BOOL force(purchaseRefreshOnActive_);
    purchaseRefreshOnActive_ = NO;
    [self updateCommercialPurchaseAction:force];
    [self resumePendingCommercialAction];
}

- (void) viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    purchaseTransitioning_ = animated && [self transitionCoordinator] != nil;
    pendingCommercialPackage_ = nil;
}

- (void) viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    purchaseTransitioning_ = NO;
    if (reloadAfterPurchaseTransition_) { reloadAfterPurchaseTransition_ = NO; [self reloadData]; }
    [self renderCommercialPurchaseAction];
}

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [detailIconTask_ cancel];
    [purchaseSession_ cancel];
    [super dealloc];
}

// A download choice in Modify or the version picker must explicitly disclose
// that payment is needed before starting device/payment authentication.
- (void) confirmPurchaseForPackage:(Package *)package {
    if (package == nil || package_ == nil || purchaseInProgress_ ||
        ![[package id] isEqualToString:[package_ id]]) return;
    if (purchaseAccess_ != CYCommercialPackageAccessBuy ||
        purchaseAccountRevision_ != CYRepositoryAccountStateRevision()) {
        [self updateCommercialPurchaseAction:NO]; return;
    }
    unsigned era([database_ era]);
    unsigned quoteEra(purchaseEra_);
    NSUInteger revision(CYRepositoryAccountStateRevision());
    NSString *confirmedPrice([NSString stringWithString:(NSString *)purchasePrice_ ?: @""]);
    UIViewController *presented([self presentedViewController]);
    if (presented != nil) {
        if ([presented isKindOfClass:UINavigationController.class] &&
            [[(UINavigationController *)presented topViewController] isKindOfClass:CydiaPackageActionsController.class]) {
            [(CydiaPackageActionsController *)[(UINavigationController *)presented topViewController] invalidateSelection];
            [presented dismissViewControllerAnimated:YES completion:^{
                if (era == [database_ era]) [self confirmPurchaseForPackage:package];
                else [self reloadData];
            }];
        }
        return;
    }
    NSString *title([confirmedPrice length] == 0 ? CYLocalize(@"Buy") :
        [NSString stringWithFormat:CYLocalize(@"Buy · %@"), confirmedPrice]);
    UIAlertController *alert([UIAlertController alertControllerWithTitle:CYLocalize(@"Purchase")
        message:[NSString stringWithFormat:@"%@\n%@", [package name] ?: [package id], [package latest] ?: @""]
        preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:UCLocalize("CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    __block UIAlertController *confirmation(alert); // Nonretaining in this manual-reference-counted file.
    [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        void (^beginPurchase)(void) = ^{
            if (era != [database_ era] || quoteEra != purchaseEra_ ||
                revision != CYRepositoryAccountStateRevision() || purchaseAccess_ != CYCommercialPackageAccessBuy) {
                [self reloadData]; return;
            }
            purchaseReturnToVersions_ = ![[package latest] isEqualToString:[package_ latest]];
            [self buyPackageWithConfirmedPrice:confirmedPrice];
        };
        id<UIViewControllerTransitionCoordinator> coordinator([confirmation transitionCoordinator]);
        if ([confirmation isBeingDismissed] && coordinator != nil) {
            [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                if (![context isCancelled]) beginPurchase();
            }];
        } else [confirmation dismissViewControllerAnimated:YES completion:beginPurchase];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void) endCommercialPurchase {
    purchaseInProgress_ = false;
    purchaseReturnToVersions_ = NO;
    purchaseInfoPending_ = NO;
    pendingCommercialPackage_ = nil;
    purchaseCheckedAt_ = 0;
    ++purchaseEra_;
}

- (void) buyPackageWithConfirmedPrice:(NSString *)confirmedPrice {
    if (purchaseInProgress_ || package_ == nil || purchaseAccess_ != CYCommercialPackageAccessBuy) return;
    Source *source([package_ source]);
    NSString *repositoryURL([source rooturi]);
    if ([repositoryURL length] == 0) return;
    NSString *packageID([package_ id]);
    NSString *model(Machine_ != NULL ? [NSString stringWithUTF8String:Machine_] : nil);
    unsigned databaseEra([database_ era]);
    NSUInteger revision(CYRepositoryAccountStateRevision());
    unsigned era(++purchaseEra_);
    purchaseInProgress_ = true;
    purchaseInfoPending_ = NO;
    pendingCommercialPackage_ = nil;
    [self renderCommercialPurchaseAction];
    // A cached label is not a price authorization. Re-query immediately before
    // payment; a new price requires another explicit confirmation.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *infoError(nil);
        NSDictionary *info(CYRepositoryPackageInfo(repositoryURL, packageID, UniqueID_, model, &infoError));
        dispatch_async(dispatch_get_main_queue(), ^{
            if (era != purchaseEra_) return;
            if (databaseEra != [database_ era] || revision != CYRepositoryAccountStateRevision() ||
                package_ == nil || ![[package_ id] isEqualToString:packageID]) {
                [self endCommercialPurchase]; [self updateCommercialPurchaseAction:NO]; return;
            }
            [self acceptCommercialPackageInfo:info error:infoError];
            if (info == nil || ![[info objectForKey:@"available"] boolValue]) {
                // Purchased but no longer offered packages may still be downloadable.
                if (info != nil && [[info objectForKey:@"purchased"] boolValue]) {
                    [self installConfirmedCommercialPackage]; return;
                }
                [self endCommercialPurchase]; [self renderCommercialPurchaseAction];
                [self presentPurchaseError:infoError != nil ? [infoError localizedDescription] : CYLocalize(@"This package cannot be purchased.")];
                return;
            }
            if ([[info objectForKey:@"purchased"] boolValue]) {
                [self installConfirmedCommercialPackage]; return;
            }
            NSString *price([info objectForKey:@"price"]);
            if (![price isKindOfClass:NSString.class] || ![price isEqualToString:confirmedPrice]) {
                [self endCommercialPurchase]; [self renderCommercialPurchaseAction];
                [self presentPurchaseError:CYLocalize(@"The price changed. Review the updated price and confirm again.")];
                return;
            }
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSString *actionURL(nil);
                NSError *error(nil);
                NSInteger status(CYRepositoryPurchaseCancelled);
                if (revision == CYRepositoryAccountStateRevision())
                    status = CYRepositoryPurchase(repositoryURL, packageID, UniqueID_, model, &actionURL, &error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (era != purchaseEra_) return;
                    if (databaseEra != [database_ era] || revision != CYRepositoryAccountStateRevision() ||
                        package_ == nil || ![[package_ id] isEqualToString:packageID]) {
                        if (status == CYRepositoryPurchaseImmediateSuccess)
                            CYRepositoryAccountPurchaseDidComplete(repositoryURL);
                        [self endCommercialPurchase]; [self updateCommercialPurchaseAction:NO]; return;
                    }
                    if (status == CYRepositoryPurchaseImmediateSuccess)
                        [self completePurchaseAndInstall];
                    else if (status == CYRepositoryPurchaseActionRequired && [actionURL length] != 0)
                        [self presentPurchaseAction:actionURL forPackage:packageID];
                    else {
                        [self endCommercialPurchase]; [self updateCommercialPurchaseAction:YES];
                        if (status != CYRepositoryPurchaseCancelled)
                            [self presentPurchaseError:[error localizedDescription]];
                    }
                });
            });
        });
    });
}

- (void) installConfirmedCommercialPackage {
    if (!purchaseInProgress_ || package_ == nil) return;
    BOOL chooseVersion(purchaseReturnToVersions_);
    purchaseInProgress_ = false;
    purchaseReturnToVersions_ = NO;
    purchaseInfoPending_ = NO;
    pendingCommercialPackage_ = nil;
    ++purchaseEra_;
    purchaseAccountRevision_ = CYRepositoryAccountStateRevision();
    purchaseAccess_ = CYCommercialPackageAccessInstall;
    purchasePrice_ = nil;
    purchaseFailure_ = nil;
    purchaseCheckedAt_ = [NSDate timeIntervalSinceReferenceDate];
    [self reloadData];
    if (package_ == nil) return;
    // A purchase grants access to the package, not permission to replace an
    // explicitly selected older version with the latest one.
    if (chooseVersion) {
        if ([versions_ count] != 0) [self _clickButtonWithName:@"DOWNGRADE"];
    } else [self.delegate installPackage:package_];
}

- (void) completePurchaseAndInstall {
    if (!purchaseInProgress_ || package_ == nil) return;
    CYRepositoryAccountPurchaseDidComplete([[package_ source] rooturi]);
    // authorize_download still re-verifies ownership at fetch time; APT's
    // archive hash and size checks remain enforced.
    [self installConfirmedCommercialPackage];
}

- (void) presentPurchaseAction:(NSString *)urlString forPackage:(NSString *)packageID {
    NSURL *url([NSURL URLWithString:urlString]);
    if (url == nil || ![[[url scheme] lowercaseString] isEqualToString:@"https"] || [[url host] length] == 0) {
        [self endCommercialPurchase]; [self updateCommercialPurchaseAction:NO];
        [self presentPurchaseError:CYLocalize(@"The secure purchase session could not start.")]; return;
    }
    [purchaseSession_ cancel];
    unsigned era(purchaseEra_);
    unsigned databaseEra([database_ era]);
    NSUInteger revision(CYRepositoryAccountStateRevision());
    ASWebAuthenticationSession *session([[[ASWebAuthenticationSession alloc]
        initWithURL:url callbackURLScheme:@"sileo" completionHandler:^(NSURL *callbackURL, NSError *sessionError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // A late cancelled session must not clear a newer session.
                if (era != purchaseEra_) return;
                purchaseSession_ = nil;
                if (databaseEra != [database_ era] || revision != CYRepositoryAccountStateRevision() ||
                    package_ == nil || ![[package_ id] isEqualToString:packageID]) {
                    [self endCommercialPurchase]; [self updateCommercialPurchaseAction:NO]; return;
                }
                NSURLComponents *callback(sessionError == nil && callbackURL != nil ?
                    [NSURLComponents componentsWithURL:callbackURL resolvingAgainstBaseURL:NO] : nil);
                if ([[[callback scheme] lowercaseString] isEqualToString:@"sileo"] &&
                    [[[callback host] lowercaseString] isEqualToString:@"payment_completed"])
                    [self completePurchaseAndInstall];
                else {
                    [self endCommercialPurchase]; [self updateCommercialPurchaseAction:YES];
                    if (sessionError != nil && [sessionError code] != ASWebAuthenticationSessionErrorCodeCanceledLogin)
                        [self presentPurchaseError:[sessionError localizedDescription]];
                }
            });
        }] autorelease]);
    purchaseSession_ = session;
    [session setPresentationContextProvider:self];
    [session setPrefersEphemeralWebBrowserSession:NO];
    if (![session start]) {
        purchaseSession_ = nil;
        [self endCommercialPurchase];
        if ([[UIApplication sharedApplication] canOpenURL:url]) {
            // The controller's existing active notification refreshes the
            // authoritative state on return; an external browser never auto-installs.
            purchaseRefreshOnActive_ = YES;
            [[UIApplication sharedApplication] openURL:url options:[NSDictionary dictionary] completionHandler:nil];
            [self presentPurchaseError:CYLocalize(@"Complete the purchase in the browser that just opened, then return to Cydia.")];
        } else [self presentPurchaseError:CYLocalize(@"The secure purchase session could not start.")];
        [self renderCommercialPurchaseAction];
    }
}

- (void) presentPurchaseError:(NSString *)message {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:CYLocalize(@"Purchase")
        message:([message length] == 0 ? CYLocalize(@"The purchase could not be completed.") : message)
        preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (ASPresentationAnchor) presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    UIWindow *window([[self view] window]);
    if (window != nil && [window windowScene] != nil)
        return window;
    // Fall back to the foreground scene's key window when the detail view is
    // not yet attached to a scene-backed window, so the authentication session
    // always has a valid anchor to start from.
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            [scene activationState] != UISceneActivationStateForegroundActive)
            continue;
        for (UIWindow *candidate in [(UIWindowScene *) scene windows])
            if ([candidate isKeyWindow])
                return candidate;
        UIWindow *first([[(UIWindowScene *) scene windows] firstObject]);
        if (first != nil)
            return first;
    }
    for (UIWindow *candidate in [[UIApplication sharedApplication] windows])
        if (candidate != nil)
            return candidate;

    // UIKit should always have supplied a scene window before authentication
    // reaches this point. Keep a retained, non-null final anchor so a provider
    // cannot crash Cydia if it requests presentation during a scene transition.
    static UIWindow *fallback(nil);
    if (fallback == nil)
        fallback = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    return fallback;
}

- (bool) isLoading {
    return false;
}

@end
/* }}} */

/* Package List Controller {{{ */
@interface PackageListController : CyteListController <
    UITableViewDataSource,
    UITableViewDelegate
> {
    _transient Database *database_;
    unsigned era_;
    _H<NSArray> packages_;
    _H<NSArray> sections_;

    _H<NSArray> thumbs_;
    std::vector<NSInteger> offset_;

    unsigned reloading_;
    BOOL packageSwipePending_;
}

- (id) initWithDatabase:(Database *)database title:(NSString *)title;

- (NSArray *) sectionsForPackages:(NSMutableArray *)packages;
- (NSString *) packageIdentifierAtIndexPath:(NSIndexPath *)path;
- (BOOL) performPackageSwipeAction:(NSString *)action forIdentifier:(NSString *)identifier;

@end

@implementation PackageListController

- (NSURL *) referrerURL {
    return [self navigationURL];
}

- (bool) isSummarized {
    return false;
}

- (bool) showsSections {
    return true;
}

- (void) didSelectPackage:(Package *)package {
    CYPackageController *view([[[CYPackageController alloc] initWithDatabase:database_ forPackage:[package id] withReferrer:[[self referrerURL] absoluteString]] autorelease]);
    [view setDelegate:self.delegate];
    [[self navigationController] pushViewController:view animated:YES];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)list {
    NSInteger count([sections_ count]);
    return count == 0 ? 1 : count;
}

- (NSString *) tableView:(UITableView *)list titleForHeaderInSection:(NSInteger)section {
    if ([sections_ count] == 0 || [[sections_ objectAtIndex:section] count] == 0)
        return nil;
    return [[sections_ objectAtIndex:section] name];
}

- (NSInteger) tableView:(UITableView *)list numberOfRowsInSection:(NSInteger)section {
    if ([sections_ count] == 0)
        return 0;
    return [[sections_ objectAtIndex:section] count];
}

- (Package *) packageAtIndexPath:(NSIndexPath *)path {
@synchronized (database_) {
    if ([database_ era] != era_)
        return nil;

    NSInteger sectionIndex([path section]);
    NSInteger row([path row]);
    if (sectionIndex < 0 || row < 0 || (NSUInteger) sectionIndex >= [sections_ count])
        return nil;
    Section *section([sections_ objectAtIndex:sectionIndex]);
    NSUInteger packageIndex([section row] + row);
    if (packageIndex >= [packages_ count])
        return nil;
    Package *package([packages_ objectAtIndex:packageIndex]);
    return [[package retain] autorelease];
} }

- (NSString *) packageIdentifierAtIndexPath:(NSIndexPath *)path {
@synchronized (database_) {
    // Copy the identifier while Database still owns the same package era.
    // Asking an old Package object for -id after unlocking races the source
    // refresh zone recycle and produced empty Details with a stuck spinner.
    if ([database_ era] != era_)
        return nil;
    NSInteger sectionIndex([path section]);
    NSInteger row([path row]);
    if (sectionIndex < 0 || row < 0 || (NSUInteger) sectionIndex >= [sections_ count])
        return nil;
    Section *section([sections_ objectAtIndex:sectionIndex]);
    NSUInteger packageIndex([section row] + row);
    if (packageIndex >= [packages_ count])
        return nil;
    return [[[[packages_ objectAtIndex:packageIndex] id] copy] autorelease];
} }

- (UITableViewCell *) tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    PackageCell *cell((PackageCell *) [table dequeueReusableCellWithIdentifier:@"Package"]);
    if (cell == nil)
        cell = [[[PackageCell alloc] init] autorelease];

    // The list already owns the candidate objects for this database era.
    // Reuse their parsed metadata instead of constructing and parsing another
    // Package every time a row reappears. Hold the era lock through binding;
    // actions still resolve a fresh package by its copied identifier.
    @synchronized (database_) {
        [cell setPackage:[self packageAtIndexPath:path] asSummary:[self isSummarized]];
    }
    return cell;
}

- (void) tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    NSString *identifier([self packageIdentifierAtIndexPath:path]);
    Package *package([database_ packageWithName:identifier]);
    if ([identifier length] == 0 || package == nil) {
        CYRootlessDiag(@"PACKAGE", @"selection deferred reason=stale-row section=%ld row=%ld",
            (long) [path section], (long) [path row]);
        [table deselectRowAtIndexPath:path animated:YES];
        [self reloadData];
        return;
    }
    [self didSelectPackage:package];
}

// Re-resolve by copied identifier after the contextual-action UI has closed.
// The normal delegate still owns transaction gating, resolution and Review.
- (BOOL) performPackageSwipeAction:(NSString *)action forIdentifier:(NSString *)identifier {
    if ([identifier length] == 0 || ![self isViewLoaded] || [[self view] window] == nil ||
        [[self navigationController] topViewController] != self || [self presentedViewController] != nil || [self isEditing])
        return NO;

    _H<Package> package;
    BOOL installed(NO), commercial(NO), available(NO), queued(NO);
    @synchronized (database_) {
        if ([database_ ready]) {
            package = [database_ packageWithName:identifier];
            if (package != nil) {
                installed = ![package uninstalled];
                commercial = [package isCommercial];
                available = [package source] != nil;
                queued = [package mode] != nil;
            }
        }
    }
    if (package == nil) {
        [self reloadData];
        return NO;
    }

    if ([action isEqualToString:@"remove"] && installed && !queued) {
        [self.delegate removePackage:package];
        return YES;
    }
    if ([action isEqualToString:@"install"] && !installed && !commercial && available && !queued) {
        [self.delegate installPackage:package];
        return YES;
    }
    if ([action isEqualToString:@"details"] || [action isEqualToString:@"remove"] || [action isEqualToString:@"install"]) {
        // Paid packages and changed/queued state use the central details flow.
        // Never replace a queued version or duplicate account checks here.
        [self didSelectPackage:package];
        return YES;
    }
    return NO;
}

- (UISwipeActionsConfiguration *) tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    if ([self isEditing] || packageSwipePending_)
        return nil;
    NSString *identifier(nil);
    BOOL installed(NO), commercial(NO), available(NO), queued(NO);
    @synchronized (database_) {
        if (![database_ ready]) return nil;
        identifier = [self packageIdentifierAtIndexPath:path];
        Package *package([database_ packageWithName:identifier]);
        if ([identifier length] == 0 || package == nil) return nil;
        installed = ![package uninstalled];
        commercial = [package isCommercial];
        available = [package source] != nil;
        queued = [package mode] != nil;
    }

    NSString *operation(@"details");
    NSString *title(UCLocalize("DETAILS"));
    NSString *symbol(queued ? @"ellipsis.circle" : (commercial ? @"creditcard" : @"info.circle"));
    UIContextualActionStyle style(UIContextualActionStyleNormal);
    if (!queued && installed) {
        operation = @"remove"; title = UCLocalize("REMOVE"); symbol = @"trash";
        style = UIContextualActionStyleDestructive;
    } else if (!queued && !commercial && available) {
        operation = @"install"; title = UCLocalize("INSTALL"); symbol = @"arrow.down.circle";
    }
    UIContextualAction *item([UIContextualAction contextualActionWithStyle:style title:title
        handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
            if (packageSwipePending_) { completion(NO); return; }
            packageSwipePending_ = YES;
            completion(YES);
            dispatch_async(dispatch_get_main_queue(), ^{
                packageSwipePending_ = NO;
                [self performPackageSwipeAction:operation forIdentifier:identifier];
            });
        }]);
    [item setImage:[UIImage cy_symbolNamed:symbol]];
    [item setBackgroundColor:style == UIContextualActionStyleDestructive ? [UIColor systemRedColor] : CYModernAccentColor()];
    UISwipeActionsConfiguration *configuration([UISwipeActionsConfiguration configurationWithActions:@[item]]);
    [configuration setPerformsFirstActionWithFullSwipe:NO];
    return configuration;
}

- (NSArray *) sectionIndexTitlesForTableView:(UITableView *)tableView {
    return thumbs_;
}

- (NSInteger) tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index {
    return offset_[index];
}

- (CGFloat) rowHeight {
    return CYModernPackageRowHeight([self isSummarized]);
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Inset-grouped tables on modern UIKit can otherwise fall back to the
    // legacy 44-point row estimate while data is being reloaded.  Our native
    // package cell contains an icon and up to three text lines, so make the
    // intended height explicit for every row.
    return [self rowHeight];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection != nil &&
        ![[previousTraitCollection preferredContentSizeCategory]
            isEqualToString:[[self traitCollection] preferredContentSizeCategory]])
        [[self tableView] reloadData];
}

- (id) initWithDatabase:(Database *)database title:(NSString *)title {
    if ((self = [super initWithTitle:title]) != nil) {
        database_ = database;
    } return self;
}

- (void) releaseSubviews {
    packages_ = nil;
    sections_ = nil;

    thumbs_ = nil;
    offset_.clear();

    [super releaseSubviews];
}

- (bool) shouldBlock {
    return false;
}

- (NSMutableArray *) _reloadPackages {
@synchronized (database_) {
    era_ = [database_ era];
    NSArray *packages([database_ packages]);

    return [NSMutableArray arrayWithArray:packages];
} }

- (void) _reloadData {
    if (reloading_ != 0) {
        reloading_ = 2;
        return;
    }

    NSMutableArray *packages;

  reload:
    if ([self shouldYield]) {
        do {
            CydiaLoadingView *hud;

            if (![self shouldBlock])
                hud = nil;
            else {
                hud = [self.delegate addProgressHUD];
                [hud setText:UCLocalize("LOADING")];
            }

            reloading_ = 1;
            packages = [self yieldToSelector:@selector(_reloadPackages)];

            if (hud != nil)
                [self.delegate removeProgressHUD:hud];
        } while (reloading_ == 2);
    } else {
        packages = [self _reloadPackages];
    }

@synchronized (database_) {
    if (era_ != [database_ era])
        goto reload;
    reloading_ = 0;

    thumbs_ = nil;
    offset_.clear();

    packages_ = packages;

    if ([self showsSections])
        sections_ = [self sectionsForPackages:packages];
    else {
        Section *section([[[Section alloc] initWithName:nil row:0 localize:NO] autorelease]);
        [section setCount:[packages_ count]];
        sections_ = [NSArray arrayWithObject:section];
    }

    [super _reloadData];
}

    PrintTimes();
}

- (NSArray *) sectionsForPackages:(NSMutableArray *)packages {
    Section *prefix([[[Section alloc] initWithName:nil row:0 localize:NO] autorelease]);
    size_t end([packages count]);

    NSMutableArray *sections([NSMutableArray arrayWithCapacity:16]);
    Section *section(prefix);

    thumbs_ = CollationThumbs_;
    offset_ = CollationOffset_;

    size_t offset(0);
    size_t offsets([CollationStarts_ count]);

    NSString *start([CollationStarts_ objectAtIndex:offset]);
    size_t length([start length]);

    for (size_t index(0); index != end; ++index) {
        if (start != nil) {
            Package *package([packages objectAtIndex:index]);
            NSString *name(PackageName(package, @selector(cyname)));

            //while ([start compare:name options:NSNumericSearch range:NSMakeRange(0, length) locale:CollationLocale_] != NSOrderedDescending) {
            while (StringNameCompare(start, name, length) != kCFCompareGreaterThan) {
                NSString *title([CollationTitles_ objectAtIndex:offset]);
                section = [[[Section alloc] initWithName:title row:index localize:NO] autorelease];
                [sections addObject:section];

                start = ++offset == offsets ? nil : [CollationStarts_ objectAtIndex:offset];
                if (start == nil)
                    break;
                length = [start length];
            }
        }

        [section addToCount];
    }

    for (; offset != offsets; ++offset) {
        NSString *title([CollationTitles_ objectAtIndex:offset]);
        Section *section([[[Section alloc] initWithName:title row:end localize:NO] autorelease]);
        [sections addObject:section];
    }

    if ([prefix count] != 0) {
        Section *suffix([sections lastObject]);
        [prefix setName:[suffix name]];
        [suffix setName:nil];
        [sections insertObject:prefix atIndex:(offsets - 1)];
    }

    // The historic collation array contains every alphabet letter, including
    // empty sections.  In UITableViewStyleInsetGrouped those empty sections
    // still receive header/footer spacing and create the huge blank areas seen
    // between E and L.  Keep only sections that actually contain packages and
    // rebuild the side index to point at their compacted positions.
    NSMutableArray *visible([NSMutableArray arrayWithCapacity:[sections count]]);
    NSMutableArray *indexTitles([NSMutableArray arrayWithCapacity:[sections count]]);
    offset_.clear();

    for (Section *candidate in sections) {
        if ([candidate count] == 0)
            continue;

        NSInteger visibleIndex([visible count]);
        [visible addObject:candidate];

        NSString *title([candidate name]);
        if ([title length] != 0) {
            [indexTitles addObject:title];
            offset_.push_back(visibleIndex);
        }
    }

    thumbs_ = indexTitles;
    return visible;
}

@end
/* }}} */
/* Filtered Package List Controller {{{ */
typedef Function<bool, Package *> PackageFilter;
typedef Function<void, NSMutableArray *> PackageSorter;
@interface FilteredPackageListController : PackageListController {
    PackageFilter filter_;
    PackageSorter sorter_;
}

- (id) initWithDatabase:(Database *)database title:(NSString *)title filter:(PackageFilter)filter;

- (void) setFilter:(PackageFilter)filter;
- (void) setSorter:(PackageSorter)sorter;

@end

@implementation FilteredPackageListController

- (void) setFilter:(PackageFilter)filter {
@synchronized (self) {
    filter_ = filter;
} }

- (void) setSorter:(PackageSorter)sorter {
@synchronized (self) {
    sorter_ = sorter;
} }

- (NSMutableArray *) _reloadPackages {
@synchronized (database_) {
    era_ = [database_ era];

    NSArray *packages([database_ packages]);
    NSMutableArray *filtered([NSMutableArray arrayWithCapacity:[packages count]]);

    PackageFilter filter;
    PackageSorter sorter;

    @synchronized (self) {
        filter = filter_;
        sorter = sorter_;
    }

    _profile(PackageTable$reloadData$Filter)
        for (Package *package in packages)
            if (filter(package))
                [filtered addObject:package];
    _end

    if (sorter)
        sorter(filtered);
    return filtered;
} }

- (id) initWithDatabase:(Database *)database title:(NSString *)title filter:(PackageFilter)filter {
    if ((self = [super initWithDatabase:database title:title]) != nil) {
        [self setFilter:filter];
    } return self;
}

@end
/* }}} */

/* Home Controller {{{ */
static NSString *const CYFeaturedEndpoint = @"https://featuredpage.getsileo.app/featured-iphoneos-arm64.json";
static NSString *const CYFeaturedCacheKey = @"CydiaSileoFeaturedBannersV3";
static NSString *const CYHomeQuickMetricsCacheKey = @"CydiaHomeQuickMetricsV1";

static BOOL CYFeaturedHTTPSURLIsAllowed(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0)
        return NO;
    NSURL *url([NSURL URLWithString:value]);
    return [[[[url scheme] lowercaseString] description] isEqualToString:@"https"] &&
        [[url host] length] != 0 && [url user] == nil && [url password] == nil;
}

static void CYCollectFeaturedBannerRecords(id node, NSMutableArray *records, NSString *fallbackRepository) {
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *) node)
            CYCollectFeaturedBannerRecords(child, records, fallbackRepository);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]])
        return;

    NSDictionary *dictionary((NSDictionary *) node);
    NSArray *banners([dictionary objectForKey:@"banners"]);
    if ([banners isKindOfClass:[NSArray class]]) {
        for (id candidate in banners) {
            if (![candidate isKindOfClass:[NSDictionary class]])
                continue;
            NSString *imageURL([candidate objectForKey:@"url"]);
            NSString *title([candidate objectForKey:@"title"]);
            NSString *identifier([candidate objectForKey:@"package"]);
            NSString *repository([candidate objectForKey:@"repoName"]);
            if (!CYFeaturedHTTPSURLIsAllowed(imageURL) ||
                ![title isKindOfClass:[NSString class]] || [title length] == 0 ||
                ![identifier isKindOfClass:[NSString class]] || [identifier length] == 0)
                continue;
            NSNumber *displayText([candidate objectForKey:@"displayText"]);
            NSNumber *hideShadow([candidate objectForKey:@"hideShadow"]);
            if (displayText == nil && ([identifier isEqualToString:@"com.icraze.sleepsaver2"] ||
                [identifier isEqualToString:@"com.amywhile.aemulo"]))
                displayText = @NO;
            [records addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                imageURL, @"imageURL", title, @"name", identifier, @"identifier",
                ([repository isKindOfClass:[NSString class]] && [repository length] != 0 ? repository :
                    ([fallbackRepository length] != 0 ? fallbackRepository : CYLocalize(@"Repository"))), @"repository",
                (displayText ?: @YES), @"displayText", (hideShadow ?: @NO), @"hideShadow",
            nil]];
        }
    }

    for (id child in [dictionary allValues])
        if ([child isKindOfClass:[NSArray class]] || [child isKindOfClass:[NSDictionary class]])
            CYCollectFeaturedBannerRecords(child, records, fallbackRepository);
}

static NSArray *CYFeaturedFallbackBannerRecords(void) {
    return [NSArray arrayWithObjects:
        [NSDictionary dictionaryWithObjectsAndKeys:@"https://featuredpage.getsileo.app/banners/com.icraze.sleepsaver2.jpg", @"imageURL", @"SleepSaver 2", @"name", @"com.icraze.sleepsaver2", @"identifier", @"Havoc", @"repository", @NO, @"displayText", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"https://featuredpage.getsileo.app/banners/com.noisyflake.velvet2.jpg", @"imageURL", @"Velvet 2", @"name", @"com.noisyflake.velvet2", @"identifier", @"Chariz", @"repository", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"https://featuredpage.getsileo.app/banners/com.pixelomer.shijima-ios.jpg", @"imageURL", @"Shijima", @"name", @"com.pixelomer.shijima-ios", @"identifier", @"Havoc", @"repository", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"https://featuredpage.getsileo.app/banners/com.yan.bloom.jpg", @"imageURL", @"Bloom", @"name", @"com.yan.bloom", @"identifier", @"Havoc", @"repository", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"https://featuredpage.getsileo.app/banners/me.tomt000.stageduo.jpg", @"imageURL", @"Dynamic Stage", @"name", @"me.tomt000.stageduo", @"identifier", @"Havoc", @"repository", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"https://featuredpage.getsileo.app/banners/com.amywhile.aemulo.png", @"imageURL", @"Aemulo", @"name", @"com.amywhile.aemulo", @"identifier", @"Chariz", @"repository", @NO, @"displayText", nil], nil];
}

static NSArray *CYFeaturedProcessBannerRecords_ = nil;

static NSArray *CYShuffledFeaturedBannerRecords(NSArray *records) {
    NSMutableArray *shuffled([NSMutableArray arrayWithArray:
        [records isKindOfClass:[NSArray class]] ? records : [NSArray array]]);
    for (NSUInteger remaining([shuffled count]); remaining > 1; --remaining) {
        NSUInteger swap(arc4random_uniform((uint32_t) remaining));
        [shuffled exchangeObjectAtIndex:remaining - 1 withObjectAtIndex:swap];
    }
    return shuffled;
}

static NSArray *CYFeaturedProcessBannerRecords(void) {
    if (CYFeaturedProcessBannerRecords_ == nil) {
        NSArray *cached([[NSUserDefaults standardUserDefaults] arrayForKey:CYFeaturedCacheKey]);
        NSArray *records([cached count] != 0 ? cached : CYFeaturedFallbackBannerRecords());
        CYFeaturedProcessBannerRecords_ = [CYShuffledFeaturedBannerRecords(records) copy];
    }
    return CYFeaturedProcessBannerRecords_;
}

static void CYReplaceFeaturedProcessBannerRecords(NSArray *records) {
    if (![records isKindOfClass:[NSArray class]] || [records count] == 0)
        return;
    [CYFeaturedProcessBannerRecords_ release];
    CYFeaturedProcessBannerRecords_ = [CYShuffledFeaturedBannerRecords(records) copy];
}

@interface HomeController : CyteViewController {
    _transient Database *database_;
    _H<CydiaModernHomeView> home_;
    BOOL featuredPackagesLoaded_;
    NSUInteger featuredRequestGeneration_;
    BOOL manualHomeReloadInProgress_;
    _H<CydiaNavigationButton> reloadButton_;
    BOOL immersive_;
    _H<UITapGestureRecognizer> immersiveTap_;
}

- (id) initWithDatabase:(Database *)database;
- (void) refreshQuickActionMetrics;
- (void) refreshFeaturedPackages;
- (void) applyFeaturedBannerRecords:(NSArray *)records generation:(NSUInteger)generation;
- (void) finishHomeReloadFeedback;

@end

@implementation HomeController

// Home keeps its bottom tab bar fixed: it does not auto-hide on scroll.
- (BOOL) modernScrollTabBarHidingEnabled {
    return NO;
}

- (id) initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) {
        database_ = database;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(presentationWillResignActive)
            name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:@"cydia://home"];
}

- (void) loadView {
    home_ = [[[CydiaModernHomeView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]] autorelease];
    [home_ setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [home_ setActionTarget:self action:@selector(homeActionClicked:)];
    NSDictionary *cached([[NSUserDefaults standardUserDefaults] dictionaryForKey:CYHomeQuickMetricsCacheKey]);
    NSNumber *sourceCount([cached objectForKey:@"sources"]);
    NSNumber *updateCount([cached objectForKey:@"updates"]);
    NSNumber *installedCount([cached objectForKey:@"installed"]);
    NSNumber *availableCount([cached objectForKey:@"available"]);
    if ([sourceCount isKindOfClass:[NSNumber class]] && [updateCount isKindOfClass:[NSNumber class]] &&
        [installedCount isKindOfClass:[NSNumber class]] && [availableCount isKindOfClass:[NSNumber class]])
        [home_ setQuickActionSourceCount:[sourceCount unsignedIntegerValue]
            updateCount:[updateCount unsignedIntegerValue]
            installedCount:[installedCount unsignedIntegerValue]
            availableCount:[availableCount unsignedIntegerValue]];
    [self setView:home_];
    [self refreshQuickActionMetrics];
}

- (void) refreshQuickActionMetrics {
    if (home_ == nil)
        return;

    NSUInteger sources(0), updates(0), installed(0), available(0);
@synchronized (database_) {
    // A nil array is the cold-launch preview. A loaded, empty array is a real
    // snapshot and must clear old cached counts after sources are removed.
    if ([database_ packages] == nil)
        return;
    sources = [[database_ sources] count];
    for (Package *package in [database_ packages]) {
        if ([package unfiltered])
            ++available;
        if (CYInstalledPackageVisibleToUser(package))
            ++installed;
        if ([package upgradableAndEssential:YES] && ![package ignored])
            ++updates;
    }
}
    [home_ setQuickActionSourceCount:sources updateCount:updates
        installedCount:installed availableCount:available];
    [[NSUserDefaults standardUserDefaults] setObject:[NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedInteger:sources], @"sources",
        [NSNumber numberWithUnsignedInteger:updates], @"updates",
        [NSNumber numberWithUnsignedInteger:installed], @"installed",
        [NSNumber numberWithUnsignedInteger:available], @"available", nil]
        forKey:CYHomeQuickMetricsCacheKey];
}

- (void) homeActionClicked:(UIButton *)sender {
    NSInteger destination([sender tag]);
    if (destination == 200) {
        [self openPurchasedPackage:[sender accessibilityIdentifier]];
        return;
    }
    if (destination == 101 || destination == 102) {
        NSString *address(destination == 101 ? @"https://www.facebook.com/Cydia/" : @"https://x.com/saurik");
        NSURL *url([NSURL URLWithString:address]);
        if (url != nil)
            [[UIApplication sharedApplication] openURL:url options:[NSDictionary dictionary] completionHandler:nil];
        return;
    }
    if (destination == 103) {
        NSMutableArray *repositories([NSMutableArray array]);
        for (Source *source in [database_ sources]) {
            NSString *root([source rooturi]);
            NSURL *url([NSURL URLWithString:root]);
            if (![[[url scheme] lowercaseString] isEqualToString:@"https"])
                continue;
            [repositories addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                ([source name] ?: [source label] ?: [url host] ?: CYLocalize(@"Repository")), CYRepositoryAccountNameKey,
                root, CYRepositoryAccountURLKey,
            nil]];
        }
        NSString *model(Machine_ != NULL ? [NSString stringWithUTF8String:Machine_] : nil);
        CydiaRepositoryAccountsViewController *accounts([[[CydiaRepositoryAccountsViewController alloc]
            initWithRepositories:repositories deviceIdentifier:UniqueID_ deviceModel:model] autorelease]);
        [accounts setPackageTarget:self action:@selector(openPurchasedPackage:)];
        Database *resolverDatabase(database_);
        [accounts setPackageResolver:^ NSDictionary *(NSString *identifier, NSString *repositoryURL, BOOL loadIcon) {
            if ([identifier length] == 0)
                return nil;
            @synchronized (resolverDatabase) {
            Package *package([resolverDatabase packageWithName:identifier]);
            Source *repository(nil);
            for (Source *source in [resolverDatabase sources])
                if ([[source rooturi] isEqualToString:repositoryURL]) {
                    repository = source;
                    break;
                }
            if (package == nil || repository == nil || ![package availableFromSource:repository])
                return nil;

            NSMutableDictionary *info([NSMutableDictionary dictionary]);
            NSString *name([package name]);
            if ([name length] != 0)
                [info setObject:name forKey:@"name"];
            NSString *tagline([package shortDescription]);
            if ([tagline length] != 0)
                [info setObject:tagline forKey:@"summary"];
            if ([[package installed] length] != 0)
                [info setObject:[NSNumber numberWithBool:YES] forKey:@"installed"];

            if (!loadIcon)
                return info;

            // Prefer the package's own artwork, read straight from the shared
            // icon cache/disk so repeat visits show it with no lag; fall back
            // to the local section icon while a remote icon downloads.
            NSURL *remoteIconURL([package remoteIconURL]);
            NSString *remoteIconAddress([remoteIconURL absoluteString]);
            UIImage *iconImage(nil);
            if ([remoteIconAddress length] != 0) {
                iconImage = [CYModernPackageIconCache() objectForKey:remoteIconAddress];
                if (iconImage == nil)
                    iconImage = CYModernPackageIconFromDisk(remoteIconAddress);
            }
            if (iconImage == nil)
                iconImage = [package icon];
            if (iconImage != nil)
                [info setObject:iconImage forKey:@"icon"];

            if ([remoteIconAddress length] != 0 &&
                [CYModernPackageIconCache() objectForKey:remoteIconAddress] == nil &&
                CYModernPackageIconFromDisk(remoteIconAddress) == nil) {
                NSString *requestedIdentifier([NSString stringWithString:identifier]);
                NSURLRequest *request([NSURLRequest requestWithURL:remoteIconURL
                    cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:15.0]);
                [[[NSURLSession sharedSession] dataTaskWithRequest:request
                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                        NSHTTPURLResponse *http([response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *) response : nil);
                        if (error != nil || [http statusCode] != 200 || [data length] == 0 || [data length] > 3 * 1024 * 1024)
                            return;
                        UIImage *downloaded(CYPreparedPackageIcon(data, [[UIScreen mainScreen] scale]));
                        if (downloaded == nil || [downloaded size].width < 2.0f || [downloaded size].height < 2.0f)
                            return;
                        [CYModernPackageIconCache() setObject:downloaded forKey:remoteIconAddress cost:CYPackageIconMemoryCost(downloaded)];
                        CYPersistModernPackageIcon(remoteIconAddress, data);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [[NSNotificationCenter defaultCenter]
                                postNotificationName:CYRepositoryPurchasedIconDidLoadNotification object:nil
                                userInfo:[NSDictionary dictionaryWithObject:requestedIdentifier forKey:CYRepositoryPurchasedPackageKey]];
                        });
                    }] resume];
            }
            return info;
            }
        }];
        [[self navigationController] pushViewController:accounts animated:YES];
        return;
    }
    UITabBarController *tabs([self tabBarController]);
    if (tabs == nil)
        tabs = [[self navigationController] tabBarController];
    if (tabs != nil && destination >= 1 && destination <= 4 &&
        destination < (NSInteger) [[tabs viewControllers] count]) {
        NSArray *routes(@[@"cydia://sources", @"cydia://changes", @"cydia://installed", @"cydia://search"]);
        UIViewController *container([[tabs viewControllers] objectAtIndex:destination]);
        if ([container isKindOfClass:[UINavigationController class]]) {
            CyteViewController *page([self.delegate pageForURL:[NSURL URLWithString:[routes objectAtIndex:destination - 1]]
                forExternal:NO withReferrer:[[self navigationURL] absoluteString]]);
            if (page != nil)
                [(UINavigationController *)container setViewControllers:@[page] animated:NO];
        }
        [tabs setSelectedIndex:destination];
    }
}

- (void) openPurchasedPackage:(NSString *)identifier {
    if ([identifier length] == 0 || [database_ packageWithName:identifier] == nil) {
        UIAlertController *alert([UIAlertController alertControllerWithTitle:CYLocalize(@"Package Unavailable")
            message:[NSString stringWithFormat:CYLocalize(@"%@ is not listed in your current sources. It may have been removed or may not be available for this device. Refresh Sources to check again."), identifier ?: CYLocalize(@"This purchase")]
            preferredStyle:UIAlertControllerStyleAlert]);
        [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"Refresh Sources") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self.delegate requestUpdate];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"Close") style:UIAlertActionStyleCancel handler:nil]];
        [[self navigationController] presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSString *escaped([identifier stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]]);
    NSURL *url([NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@", escaped]]);
    CyteViewController *page([self.delegate pageForURL:url forExternal:NO withReferrer:[[self navigationURL] absoluteString]]);
    if (page != nil)
        [[self navigationController] pushViewController:page animated:YES];
}

- (void) reloadButtonClicked {
    // Home's reload refreshes the Home dashboard (featured banner + quick action
    // metrics), not the repositories. A repository refresh stays on the Sources
    // tab (pull to refresh / its own control).
    if (manualHomeReloadInProgress_)
        return;
    manualHomeReloadInProgress_ = YES;
    [reloadButton_ setLoading:YES];
    CYRootlessDiag(@"HOME", @"manual Home reload started");
    [self reloadData];
    [self refreshFeaturedPackages];
}

- (void) finishHomeReloadFeedback {
    if (!manualHomeReloadInProgress_)
        return;
    manualHomeReloadInProgress_ = NO;
    [reloadButton_ setLoading:NO];
    CYRootlessDiag(@"HOME", @"manual Home reload finished");
}

- (void) toggleFullScreenClicked {
    [self setImmersive:!immersive_ animated:YES];
}

- (void) presentationWillResignActive {
    if (immersive_)
        [self setImmersive:NO animated:NO];
}

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (immersive_)
        [self.delegate setHomePresentationActive:NO];
    [super dealloc];
}

- (void) exitFullScreenByTap {
    if (immersive_)
        [self setImmersive:NO animated:YES];
}

- (void) setImmersive:(BOOL)immersive animated:(BOOL)animated {
    if (immersive_ == immersive)
        return;
    immersive_ = immersive;
    [self.delegate setHomePresentationActive:immersive_];
    animated = animated && !UIAccessibilityIsReduceMotionEnabled();
    [[self navigationController] setNavigationBarHidden:immersive_ animated:animated];
    UITabBarController *tabs([self tabBarController] ?: [[self navigationController] tabBarController]);
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 180000
    if (@available(iOS 18.0, *))
        [tabs setTabBarHidden:immersive_ animated:animated];
    else
#endif
    if ([tabs isKindOfClass:[CyteTabBarController class]])
        [(CyteTabBarController *) tabs setScrollTabBarHidden:immersive_ animated:animated];
    [immersiveTap_ setEnabled:immersive_];
    [home_ setFullScreenControlsVisible:immersive_ animated:animated
        target:self action:@selector(exitFullScreenByTap)];
}

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Rotation normally restores scroll-hidden tabs. Preserve the user's
    // explicit presentation mode while UIKit adapts the new screen bounds.
    if (immersive_) {
        UITabBarController *tabs([self tabBarController] ?: [[self navigationController] tabBarController]);
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 180000
        if (@available(iOS 18.0, *)) {
            if (![tabs isTabBarHidden])
                [tabs setTabBarHidden:YES animated:NO];
        } else
#endif
        if ([tabs isKindOfClass:[CyteTabBarController class]] && ![(CyteTabBarController *)tabs isScrollTabBarHidden])
            [(CyteTabBarController *)tabs setScrollTabBarHidden:YES animated:NO];
    }
}

- (void) viewWillDisappear:(BOOL)animated {
    // Never leave Home in immersive state: restore both bars before leaving.
    if (immersive_)
        [self setImmersive:NO animated:NO];
    [super viewWillDisappear:animated];
}

- (void) applyFeaturedBannerRecords:(NSArray *)records generation:(NSUInteger)generation {
    if (generation != featuredRequestGeneration_ || ![records isKindOfClass:[NSArray class]])
        return;

    BOOL databaseReady([database_ hasPackages]);
    NSMutableArray *featured([NSMutableArray array]);
    NSMutableSet *seenPackages([NSMutableSet set]);
    @synchronized (database_) {
        for (NSDictionary *banner in records) {
            NSString *identifier([banner objectForKey:@"identifier"]);
            NSString *imageURL([banner objectForKey:@"imageURL"]);
            if (![identifier isKindOfClass:[NSString class]] || [seenPackages containsObject:identifier] ||
                !CYFeaturedHTTPSURLIsAllowed(imageURL))
                continue;
            // Before the local database finishes loading, the cached banners
            // were already validated when stored. Show them as-is instead of
            // briefly emptying the strip and rebuilding it after the launch
            // refresh, which was the visible Home flicker.
            if (databaseReady) {
                Package *package([database_ packageWithName:identifier]);
                if (package == nil || ![package visible] || [package source] == nil || [[package latest] length] == 0)
                    continue;
            }
            [seenPackages addObject:identifier];
            [featured addObject:banner];
        }
    }
    // Never empty an already-populated strip only because the database is not
    // ready yet; that empty->full transition is what flickered on launch.
    if ([featured count] == 0 && !databaseReady && featuredPackagesLoaded_)
        return;
    featuredPackagesLoaded_ = [featured count] != 0;
    [home_ setFeaturedPackages:featured];
}

- (void) refreshFeaturedPackages {
    NSUInteger generation(++featuredRequestGeneration_);
    BOOL refreshVisibleBanners(manualHomeReloadInProgress_);
    if (!featuredPackagesLoaded_)
        [self applyFeaturedBannerRecords:CYFeaturedProcessBannerRecords() generation:generation];

    // The first-run privacy decision is a real network gate. Cached artwork
    // may paint underneath the opaque consent surface, but repository
    // discovery begins only after the user accepts.
    if (!CydiaPrivacyConsentIsAccepted()) {
        [self finishHomeReloadFeedback];
        return;
    }

    // Cards can already exist beneath the first-run consent surface. Resume
    // their missing artwork now without replacing the visible carousel.
    [home_ loadFeaturedArtwork];

    // Sileo and Zebra discover repository artwork through this exact file at
    // each source root. Aggregate every installed source rather than keeping
    // a hand-maintained host list, while retaining Sileo's global selection.
    NSMutableArray *endpoints([NSMutableArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:
        CYFeaturedEndpoint, @"url", @"", @"repository", nil]]);
    NSMutableSet *seenEndpoints([NSMutableSet setWithObject:CYFeaturedEndpoint]);
    @synchronized (database_) {
        for (Source *source in [database_ sources]) {
            NSURL *base([NSURL URLWithString:[source rooturi]]);
            NSString *scheme([[base scheme] lowercaseString]);
            if (!([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) ||
                [[base host] length] == 0 || [base user] != nil || [base password] != nil)
                continue;
            NSURL *featuredURL([base URLByAppendingPathComponent:@"sileo-featured.json"]);
            NSString *absolute([featuredURL absoluteString]);
            if ([absolute length] == 0 || [seenEndpoints containsObject:absolute])
                continue;
            [seenEndpoints addObject:absolute];
            [endpoints addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                absolute, @"url", ([source name] ?: [source label] ?: [base host] ?: CYLocalize(@"Repository")), @"repository", nil]];
        }
    }

    NSMutableArray *orderedResults([NSMutableArray arrayWithCapacity:[endpoints count]]);
    for (NSUInteger index(0); index != [endpoints count]; ++index)
        [orderedResults addObject:[NSNull null]];
    __block NSUInteger remaining([endpoints count]);
    __block BOOL finalResultsApplied(NO);

    for (NSUInteger index(0); index != [endpoints count]; ++index) {
        NSDictionary *endpoint([endpoints objectAtIndex:index]);
        NSURL *url([NSURL URLWithString:[endpoint objectForKey:@"url"]]);
        NSURLRequest *request([NSURLRequest requestWithURL:url
            cachePolicy:refreshVisibleBanners ? NSURLRequestReloadIgnoringLocalCacheData : NSURLRequestReturnCacheDataElseLoad
            timeoutInterval:15.0]);
        NSURLSessionDataTask *task([[NSURLSession sharedSession] dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSMutableArray *records([NSMutableArray array]);
                NSHTTPURLResponse *http([response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *) response : nil);
                if (error == nil && [http statusCode] == 200 && [data length] != 0 && [data length] <= 512 * 1024) {
                    NSError *jsonError(nil);
                    id payload([NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError]);
                    if (jsonError == nil && payload != nil)
                        CYCollectFeaturedBannerRecords(payload, records, [endpoint objectForKey:@"repository"]);
                }

                BOOL complete(NO);
                NSArray *snapshot(nil);
                @synchronized (orderedResults) {
                    [orderedResults replaceObjectAtIndex:index withObject:records];
                    complete = --remaining == 0;
                    snapshot = [[orderedResults copy] autorelease];
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != featuredRequestGeneration_ || finalResultsApplied)
                        return;
                    if (complete)
                        finalResultsApplied = YES;
                    // An empty Home can display the first usable source without
                    // waiting for every other repository to finish or time out.
                    // Keep an existing carousel and its position until the final
                    // explicit refresh result, preserving the normal stable order.
                    if (!complete && featuredPackagesLoaded_)
                        return;
                    NSMutableArray *combined([NSMutableArray array]);
                    for (id result in snapshot)
                        if ([result isKindOfClass:[NSArray class]])
                            [combined addObjectsFromArray:result];
                    if (!complete && [combined count] == 0)
                        return;
                    // A failed manual refresh keeps the useful banners already on screen.
                    if ([combined count] == 0 && refreshVisibleBanners && featuredPackagesLoaded_) {
                        [self finishHomeReloadFeedback];
                        return;
                    }
                    if ([combined count] == 0)
                        [combined addObjectsFromArray:CYFeaturedFallbackBannerRecords()];
                    if (complete)
                        [[NSUserDefaults standardUserDefaults] setObject:combined forKey:CYFeaturedCacheKey];

                    // Automatic discovery preserves the visible carousel. Only an
                    // explicit Home Reload applies fresh banners immediately.
                    if (refreshVisibleBanners || !featuredPackagesLoaded_) {
                        CYReplaceFeaturedProcessBannerRecords(combined);
                        [self applyFeaturedBannerRecords:CYFeaturedProcessBannerRecords() generation:generation];
                    }
                    if (complete)
                        [self finishHomeReloadFeedback];
                });
            }]);
        [task resume];
    }
}

- (void) viewDidLoad {
    [super viewDidLoad];
    [[self navigationItem] setTitle:UCLocalize("HOME")];
    // Home owns a complete native dashboard, so a second large-title row only
    // wastes space and can clip while the dashboard scrolls. Keep one compact
    // bar: About, centred Home, Refresh.
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    [[self navigationItem] setLeftBarButtonItem:[self leftButton]];
    reloadButton_ = [[[CydiaNavigationButton alloc] initWithSymbol:@"arrow.clockwise"
        label:CYLocalize(@"Reload Home") target:self action:@selector(reloadButtonClicked)] autorelease];
    UIBarButtonItem *reloadItem([[[UIBarButtonItem alloc] initWithCustomView:reloadButton_] autorelease]);
    CydiaNavigationButton *fullScreen([[[CydiaNavigationButton alloc]
        initWithSymbol:@"arrow.up.left.and.arrow.down.right" label:CYLocalize(@"Full Screen")
        target:self action:@selector(toggleFullScreenClicked)] autorelease]);
    UIBarButtonItem *fullScreenItem([[[UIBarButtonItem alloc] initWithCustomView:fullScreen] autorelease]);
    // Reload (rightmost) refreshes the Home dashboard; the expand glyph beside
    // it toggles an immersive full-screen view of Home.
    [[self navigationItem] setRightBarButtonItems:[NSArray arrayWithObjects:reloadItem, fullScreenItem, nil]];

    immersiveTap_ = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(exitFullScreenByTap)] autorelease];
    [immersiveTap_ setCancelsTouchesInView:YES];
    [immersiveTap_ setEnabled:NO];
    [[self view] addGestureRecognizer:immersiveTap_];

    [self refreshFeaturedPackages];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    [self refreshQuickActionMetrics];
}

- (void) reloadData {
    [super reloadData];
    [self refreshQuickActionMetrics];
}

- (void) aboutButtonClicked {
    CydiaModernAboutViewController *about([[[CydiaModernAboutViewController alloc] init] autorelease]);
    [about setModalPresentationStyle:UIModalPresentationPageSheet];
    [about setModalPresentationCapturesStatusBarAppearance:YES];
    UISheetPresentationController *sheet([about sheetPresentationController]);
    [sheet setDetents:@[[UISheetPresentationControllerDetent largeDetent]]];
    [sheet setSelectedDetentIdentifier:UISheetPresentationControllerDetentIdentifierLarge];
    [sheet setPrefersGrabberVisible:YES];
    [sheet setPreferredCornerRadius:28.0f];
    [self presentViewController:about animated:YES completion:nil];
}

- (UIBarButtonItem *) leftButton {
    UIBarButtonItem *item([[[UIBarButtonItem alloc]
        initWithImage:[UIImage cy_symbolNamed:@"info.circle"]
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(aboutButtonClicked)
    ] autorelease]);
    [item setAccessibilityLabel:UCLocalize("ABOUT")];
    return item;
}

- (void) releaseSubviews {
    home_ = nil;
    [super releaseSubviews];
}

@end
/* }}} */

/* Cydia Tab Bar Controller {{{ */
@interface CydiaTabBarController : CyteTabBarController <
    UITabBarControllerDelegate,
    FetchDelegate
> {
    _transient Database *database_;

    bool updating_;
    bool pendingUpdate_;
    bool cancelRequested_;
    _H<NSString> updatingSourceKey_;
    NSUInteger sourceRefreshGeneration_;
    bool hasRepositoryVerificationResult_;
    bool repositoriesVerified_;
    _H<UIActivityIndicatorView> sourceActivity_;
    _H<UIImageView> sourceCompletion_;
    // XXX: ok, "updatedelegate_"?...
    _transient NSObject<CydiaDelegate> *updatedelegate_;
}

- (void) beginUpdate;
- (void) beginUpdateForSourceKey:(NSString *)sourceKey;
- (void) queueUpdateAfterCurrent;
- (BOOL) updating;
- (BOOL) hasRepositoryVerificationResult;
- (BOOL) repositoriesVerified;
- (void) refreshHomeStatus;
- (void) setSourceActivityVisible:(BOOL)visible;
- (void) layoutSourceActivity;
- (void) showSourceCompletionWithResult:(NSDictionary *)result;
- (void) restoreSelectedTabAfterUpdate:(NSNumber *)index;
- (void) synchronizeSourceRefreshUI;

@end

@implementation CydiaTabBarController

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutSourceActivity];
}

- (void) layoutSourceActivity {
    UITabBar *bar([self tabBar]);
    NSArray *controllers([self viewControllers]);
    if ([controllers count] <= 1)
        return;

    // UITabBar's private button subviews are transient during the first
    // layout pass and their order changes between iOS releases. Position the
    // activity indicator from the public item count instead: Sources is item
    // index 1, so its center is always 1.5 item widths from the left edge.
    const CGFloat itemWidth(CGRectGetWidth([bar bounds]) / (CGFloat) [controllers count]);
    const CGFloat centerX(itemWidth * 1.5f);
    const CGFloat centerY(17.0f);
    if (sourceActivity_ != nil) {
        [sourceActivity_ setCenter:CGPointMake(centerX, centerY)];
        [bar bringSubviewToFront:sourceActivity_];
    }
    if (sourceCompletion_ != nil) {
        [sourceCompletion_ setCenter:CGPointMake(centerX, centerY)];
        [bar bringSubviewToFront:sourceCompletion_];
    }
}

- (void) setSourceActivityVisible:(BOOL)visible {
    // The Sources screen now shows a modern top progress bar during a refresh
    // (see SourcesController -setSourceRefreshActive:). The old tab-bar spinner
    // is intentionally not shown so there is a single, non-redundant indicator.
    // The brief completion checkmark below is kept as success confirmation.
}

- (void) synchronizeSourceRefreshUI {
    // Sources and Changes expose the same repository-refresh operation. Keep
    // both navigation bars driven by this one authoritative state transition;
    // otherwise the selected controller can reload while updating_ is still
    // true and retain a stale Cancel button after the worker has finished.
    SEL stateChanged(NSSelectorFromString(@"sourceRefreshStateDidChange"));
    for (UIViewController *container in [self viewControllers]) {
        UIViewController *root(container);
        if ([container isKindOfClass:[UINavigationController class]])
            root = [[(UINavigationController *) container viewControllers] firstObject];
        if ([root respondsToSelector:stateChanged])
            [root performSelector:stateChanged];
    }
}

- (void) showSourceCompletionWithResult:(NSDictionary *)result {
    if (updating_ || [[result objectForKey:@"generation"] unsignedIntegerValue] != sourceRefreshGeneration_)
        return;
    [self setSourceActivityVisible:NO];
    [sourceCompletion_ removeFromSuperview];
    sourceCompletion_ = nil;

    // Green means that refreshed package data is usable. Operational source
    // problems remain orange; signing-key compatibility is handled by APT and
    // no longer requires a separate user approval step.
    BOOL success([[result objectForKey:@"success"] boolValue]);
    UIColor *color(success ? [UIColor systemGreenColor] : [UIColor systemOrangeColor]);
    NSString *symbol(success ? @"checkmark.circle.fill" : @"exclamationmark.circle.fill");
    sourceCompletion_ = [[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:symbol]] autorelease];
    [sourceCompletion_ setFrame:CGRectMake(0.0f, 0.0f, 30.0f, 30.0f)];
    [sourceCompletion_ setContentMode:UIViewContentModeCenter];
    [sourceCompletion_ setTintColor:color];
    [sourceCompletion_ setPreferredSymbolConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:24.0f weight:UIImageSymbolWeightSemibold]];
    [sourceCompletion_ setBackgroundColor:[[UIColor systemBackgroundColor] colorWithAlphaComponent:0.96f]];
    [[sourceCompletion_ layer] setCornerRadius:15.0f];
    [[sourceCompletion_ layer] setCornerCurve:kCACornerCurveContinuous];
    [sourceCompletion_ setUserInteractionEnabled:NO];
    [sourceCompletion_ setIsAccessibilityElement:YES];
    [sourceCompletion_ setAccessibilityLabel:success ? [result objectForKey:@"label"] : CYLocalize(@"Source refresh completed with warnings")];
    [[self tabBar] addSubview:sourceCompletion_];
    [self layoutSourceActivity];

    UIImageView *completion(sourceCompletion_);
    [completion setAlpha:0.0f];
    [completion setTransform:CGAffineTransformMakeScale(0.42f, 0.42f)];
    [UIView animateWithDuration:0.52f delay:0.0f
        usingSpringWithDamping:0.60f initialSpringVelocity:0.75f
        options:UIViewAnimationOptionCurveEaseOut animations:^{
            [completion setAlpha:1.0f];
            [completion setTransform:CGAffineTransformIdentity];
        } completion:^(BOOL finished) {
            if (!finished)
                return;
            [UIView animateWithDuration:0.24f delay:(success ? 1.05f : 1.45f)
                options:UIViewAnimationOptionCurveEaseIn animations:^{
                    [completion setAlpha:0.0f];
                    [completion setTransform:CGAffineTransformMakeScale(0.72f, 0.72f)];
                } completion:^(BOOL faded) {
                    if (faded && sourceCompletion_ == completion) {
                        [completion removeFromSuperview];
                        sourceCompletion_ = nil;
                    }
                }];
        }];
}

- (id) initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) {
        database_ = database;
        NSDictionary *state([NSDictionary dictionaryWithContentsOfFile:CacheState_]);
        NSNumber *verified([state objectForKey:@"LastUpdateVerified"]);
        hasRepositoryVerificationResult_ = verified != nil;
        repositoriesVerified_ = [verified boolValue];
        [self setDelegate:self];

        [[self view] setAutoresizingMask:UIViewAutoresizingFlexibleBoth];
    } return self;
}

- (void) beginUpdate {
    [self beginUpdateForSourceKey:nil];
}

- (void) beginUpdateForSourceKey:(NSString *)sourceKey {
    if (updating_)
        return;
    CYBeginSourceRefreshAppearance();
    updatingSourceKey_ = sourceKey == nil ? nil : [NSString stringWithString:sourceKey];
    ++sourceRefreshGeneration_;

    [[sourceCompletion_ layer] removeAllAnimations];
    [sourceCompletion_ removeFromSuperview];
    sourceCompletion_ = nil;

    UIViewController *controller([[self viewControllers] objectAtIndex:1]);
    UITabBarItem *item([controller tabBarItem]);
    [item setBadgeValue:nil];

    [updatedelegate_ retainNetworkActivityIndicator];
    cancelRequested_ = false;
    updating_ = true;
    [self setSourceActivityVisible:YES];
    [self synchronizeSourceRefreshUI];
    CYRootlessDiag(@"SOURCES", @"UI refresh state active=1 reason=begin");

    [NSThread
        detachNewThreadSelector:@selector(performUpdate)
        toTarget:self
        withObject:nil
    ];
}

- (void) queueUpdateAfterCurrent {
    if (updating_) {
        pendingUpdate_ = true;
        CYRootlessDiag(@"REFRESH", @"queued follow-up refresh reason=source-list-changed parallelRefresh=0");
        return;
    }
    [self beginUpdate];
}

- (void) performUpdate {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    SourceStatus status(self, database_);
    bool verified([database_ updateWithStatus:status sourceKey:updatingSourceKey_]);

    [self
        performSelectorOnMainThread:@selector(completeUpdateWithVerification:)
        withObject:[NSNumber numberWithBool:verified]
        waitUntilDone:NO
    ];

    [pool release];
}

- (void) stopUpdateWithSelector:(SEL)selector {
    NSNumber *selectedIndex([NSNumber numberWithUnsignedInteger:[self selectedIndex]]);
    BOOL restarting(selector == @selector(reloadDataAndRestartSourceRefresh));
    [self setSourceActivityVisible:NO];
    [database_ resetFetch];
    [updatedelegate_ releaseNetworkActivityIndicator];

    UIViewController *controller([[self viewControllers] objectAtIndex:1]);
    [[controller tabBarItem] setBadgeValue:nil];

    // Zebra publishes refreshDidFinish only after rebuilding its cache, and
    // Sileo likewise reloads its package model before clearing update state.
    // Keep updating_ true through Cydia's synchronous final model reload so a
    // package action cannot enter APT in the tiny interval between the worker
    // finishing and the new Source/Package objects becoming authoritative.
    // A queued follow-up is the one exception: release the old pass directly
    // before its synchronous reload-and-begin handoff.
    if (restarting)
        updating_ = false;
    [updatedelegate_ performSelector:selector];
    if (!restarting)
        updating_ = false;

    // Reloading the database must never be interpreted as navigation. Keep
    // the tab that was visible when this refresh completed; in particular a
    // Home refresh cannot silently reveal Sources.
    [self restoreSelectedTabAfterUpdate:selectedIndex];
    [self synchronizeSourceRefreshUI];
    CYRootlessDiag(@"SOURCES", @"UI refresh state active=%d reason=%@",
        updating_ ? 1 : 0, restarting ? @"queued-restart" : @"finished");
}

- (void) restoreSelectedTabAfterUpdate:(NSNumber *)index {
    NSUInteger expected([index unsignedIntegerValue]);
    if (expected >= [[self viewControllers] count] || [self selectedIndex] == expected)
        return;
    CYRootlessDiag(@"NAVIGATION", @"restored tab after repository refresh expected=%lu unexpected=%lu",
        (unsigned long) expected, (unsigned long) [self selectedIndex]);
    [self setSelectedIndex:expected];
}

- (void) refreshHomeStatus {
    if ([[self viewControllers] count] == 0)
        return;
    UIViewController *container([[self viewControllers] objectAtIndex:0]);
    UIViewController *root(container);
    if ([container isKindOfClass:[UINavigationController class]])
        root = [[(UINavigationController *)container viewControllers] firstObject];
    if ([root isKindOfClass:[HomeController class]])
        [(HomeController *)root refreshFeaturedPackages];
}

- (void) completeUpdateWithVerification:(NSNumber *)verified {
    if (!updating_)
        return;

    BOOL cancelled(cancelRequested_);
    BOOL singleSource(updatingSourceKey_ != nil);
    NSString *completedName([NSString stringWithString:
        [[database_ sourceWithKey:updatingSourceKey_] name] ?: UCLocalize("SOURCES")]);
    updatingSourceKey_ = nil;
    // cancelUpdate clears an already queued pass. If a source is added or
    // removed after that cancellation request, syncData sets pendingUpdate_
    // again and the new source list still deserves its own clean pass.
    BOOL restart(pendingUpdate_);
    pendingUpdate_ = false;
    cancelRequested_ = false;
    if (singleSource) {
        NSDictionary *state([NSDictionary dictionaryWithContentsOfFile:CacheState_]);
        hasRepositoryVerificationResult_ = [state objectForKey:@"LastUpdateVerified"] != nil;
        repositoriesVerified_ = [[state objectForKey:@"LastUpdateVerified"] boolValue];
    } else {
        hasRepositoryVerificationResult_ = true;
        repositoriesVerified_ = [verified boolValue];
    }
    if (restart) {
        // A source was added or removed while the current refresh was already
        // running (including after a cancellation request). Rebuild the local
        // model and run exactly one follow-up pass; never start a second APT
        // list update in parallel.
        [self stopUpdateWithSelector:@selector(reloadDataAndRestartSourceRefresh)];
    } else if (cancelled) {
        if (!singleSource) {
            repositoriesVerified_ = false;
            CYStoreRepositoryVerificationState(false, false);
        }
        [self stopUpdateWithSelector:@selector(updateDataAndLoad)];
    } else {
        [self stopUpdateWithSelector:@selector(reloadDataAfterSourceRefresh)];
        // Discover artwork published by newly added or updated repositories,
        // but keep the currently visible process order and scroll position.
        // The refreshed selection becomes visible only after a cold launch.
        [self refreshHomeStatus];
        NSDictionary *result(@{
            @"success": @([verified boolValue] || (!singleSource && CYRepositoryRefreshReadyForUse())),
            @"generation": @(sourceRefreshGeneration_),
            @"label": singleSource ? [NSString stringWithFormat:@"%@ — %@", completedName, UCLocalize("DONE")] : CYLocalize(@"Sources refreshed")
        });
        [self performSelector:@selector(showSourceCompletionWithResult:) withObject:result afterDelay:0.05];
    }
}

- (void) cancelUpdate {
    if (!updating_)
        return;
    pendingUpdate_ = false;
    cancelRequested_ = true;
    [database_ resetFetch];
    [self setSourceActivityVisible:NO];
}

- (void) cancelPressed {
    [self cancelUpdate];
}

- (BOOL) updating {
    return updating_;
}

- (BOOL) hasRepositoryVerificationResult {
    return hasRepositoryVerificationResult_;
}

- (BOOL) repositoriesVerified {
    return repositoriesVerified_;
}

- (bool) isSourceCancelled {
    return cancelRequested_ || !updating_;
}

- (void) startSourceFetch:(NSString *)uri {
}

- (void) stopSourceFetch:(NSString *)uri {
}

- (void) setUpdateDelegate:(id)delegate {
    updatedelegate_ = delegate;
}

@end
/* }}} */

/* Cydia:// Protocol {{{ */
@interface CydiaURLProtocol : CyteURLProtocol {
}

@end

@implementation CydiaURLProtocol

+ (NSString *) scheme {
    return @"cydia";
}

- (bool) loadForPath:(NSString *)path ofRequest:(NSURLRequest *)request {
    NSRange slash([path rangeOfString:@"/"]);

    NSString *command;
    if (slash.location == NSNotFound) {
        command = path;
        path = nil;
    } else {
        command = [path substringToIndex:slash.location];
        path = [path substringFromIndex:(slash.location + 1)];
    }

    Database *database([Database sharedInstance]);

    if (false);
    else if ([command isEqualToString:@"application-icon"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

        UIImage *icon(nil);

        if (icon == nil && $SBSCopyIconImagePNGDataForDisplayIdentifier != NULL) {
            NSData *data([$SBSCopyIconImagePNGDataForDisplayIdentifier(path) autorelease]);
            icon = [UIImage imageWithData:data];
        }

        if (icon == nil)
            if (NSString *file = SBSCopyIconImagePathForDisplayIdentifier(path))
                icon = [UIImage imageAtPath:file];

        if (icon == nil)
            icon = CYModernPackageFallbackIcon(@"Applications", path);

        [self _returnPNGWithImage:icon forRequest:request];
    } else if ([command isEqualToString:@"package-icon"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        Package *package([database packageWithName:path]);
        if (package == nil)
            goto fail;
        [package parse];
        UIImage *icon([package icon]);
        [self _returnPNGWithImage:icon forRequest:request];
    } else if ([command isEqualToString:@"uikit-image"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        UIImage *icon(_UIImageWithName(path));
        [self _returnPNGWithImage:icon forRequest:request];
    } else if ([command isEqualToString:@"section-icon"]) {
        if (path == nil)
            goto fail;
        path = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        UIImage *icon(CYSectionIconImage(path));
        if (icon == nil)
            icon = CYNoSectionIcon();
        [self _returnPNGWithImage:icon forRequest:request];
    } else fail: {
        return [super loadForPath:path ofRequest:request];
    }

    return true;
}

@end
/* }}} */

/* Section Controller {{{ */
@interface SectionController : FilteredPackageListController {
    _H<NSString> key_;
    _H<NSString> section_;
}

- (id) initWithDatabase:(Database *)database source:(Source *)source section:(NSString *)section;

@end

@implementation SectionController

- (BOOL) supportsPullToRefresh {
    // All Packages and category lists use the shared database snapshot.
    // Repository refresh belongs to Sources, where progress is tracked.
    return NO;
}

- (NSURL *) referrerURL {
    NSString *name(section_);
    name = name ?: @"*";
    NSString *key(key_);
    key = key ?: @"*";
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/sections/%@/%@", UI_, [key stringByAddingPercentEscapesIncludingReserved], [name stringByAddingPercentEscapesIncludingReserved]]];
}

- (NSURL *) navigationURL {
    NSString *name(section_);
    name = name ?: @"*";
    NSString *key(key_);
    key = key ?: @"*";
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://sections/%@/%@", [key stringByAddingPercentEscapesIncludingReserved], [name stringByAddingPercentEscapesIncludingReserved]]];
}

- (id) initWithDatabase:(Database *)database source:(Source *)source section:(NSString *)section {
    NSString *title;
    if (section == nil)
        title = UCLocalize("ALL_PACKAGES");
    else if (![section isEqual:@""])
        title = [[NSBundle mainBundle] localizedStringForKey:Simplify(section) value:nil table:@"Sections"];
    else
        title = UCLocalize("NO_SECTION");

    if ((self = [super initWithDatabase:database title:title]) != nil) {
        key_ = [source key];
        section_ = section;
    } return self;
}

- (void) reloadData {
    Source *source([database_ sourceWithKey:key_]);
    _H<NSString> name(section_);

    [self setFilter:[=](Package *package) {
        NSString *section([package section]);

        bool sectionMatches(name == nil ||
            (section == nil ? [name length] == 0 : [name isEqualToString:section]));
        return sectionMatches && (
            source == nil ||
            [package availableFromSource:source]
        ) && [package visible];
    }];

    [super reloadData];
}

@end
/* }}} */
/* Sections Controller {{{ */
@interface SectionsController : CyteViewController <
    UITableViewDataSource,
    UITableViewDelegate
> {
    _transient Database *database_;
    _H<NSString> key_;
    _H<NSMutableArray> sections_;
    _H<NSMutableArray> filtered_;
    _H<UITableView, 2> list_;
}

- (id) initWithDatabase:(Database *)database source:(Source *)source;
- (void) editButtonClicked;

@end

@implementation SectionsController

- (NSURL *) navigationURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://sources/%@", [key_ stringByAddingPercentEscapesIncludingReserved]]];
}

- (Source *) source {
    if (key_ == nil)
        return nil;
    return [database_ sourceWithKey:key_];
}

- (void) updateNavigationItem {
    [[self navigationItem] setTitle:[self isEditing] ? UCLocalize("SECTION_VISIBILITY") : UCLocalize("SECTIONS")];
    if ([sections_ count] == 0) {
        [[self navigationItem] setRightBarButtonItem:nil];
    } else {
        [[self navigationItem] setRightBarButtonItem:CYModernBarButtonItem(
            [self isEditing] ? @"checkmark" : @"pencil",
            [self isEditing] ? UCLocalize("DONE") : UCLocalize("EDIT"),
            [self isEditing] ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain,
            self, @selector(editButtonClicked)) animated:([[self navigationItem] rightBarButtonItem] != nil)];
    }
}

- (void) setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];

    if (editing)
        [list_ reloadData];
    else
        [self.delegate updateData];

    [self updateNavigationItem];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [list_ deselectRowAtIndexPath:[list_ indexPathForSelectedRow] animated:animated];
}

- (void) viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self setEditing:NO];
}

- (Section *) sectionAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isEditing])
        return [sections_ objectAtIndex:[indexPath row]];
    if ([indexPath section] == 0)
        return nil;
    return [filtered_ objectAtIndex:[indexPath row]];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return [self isEditing] ? 1 : 2;
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (![self isEditing] && section == 1)
        return @"CATEGORIES";
    return nil;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self isEditing])
        return [sections_ count];
    if (section == 0)
        return 1;
    return [filtered_ count];
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return CYModernSectionRowHeight();
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseIdentifier = @"SectionCell";

    SectionCell *cell = (SectionCell *)[tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (cell == nil)
        cell = [[[SectionCell alloc] initWithFrame:CGRectZero reuseIdentifier:reuseIdentifier] autorelease];

    [cell setSection:[self sectionAtIndexPath:indexPath] editing:[self isEditing]];

    return cell;
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isEditing])
        return;

    Section *section = [self sectionAtIndexPath:indexPath];

    SectionController *controller = [[[SectionController alloc]
        initWithDatabase:database_
        source:[self source]
        section:[section name]
    ] autorelease];
    [controller setDelegate:self.delegate];

    [[self navigationController] pushViewController:controller animated:YES];
}

- (void) loadView {
    list_ = [[[UITableView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame] style:CYModernGroupedTableStyle()] autorelease];
    [list_ setAutoresizingMask:UIViewAutoresizingFlexibleBoth];
    CYModernizeTableView(list_);
    UIView *topSpacing([[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 1.0f, 12.0f)] autorelease]);
    [topSpacing setBackgroundColor:[UIColor clearColor]];
    [list_ setTableHeaderView:topSpacing];
    [list_ setSeparatorInset:UIEdgeInsetsMake(0.0f, 57.0f, 0.0f, 0.0f)];
    [list_ setEstimatedRowHeight:56.0f];
    [(UITableView *) list_ setDataSource:self];
    [list_ setDelegate:self];
    [self setView:list_];
}

- (void) viewDidLoad {
    [super viewDidLoad];

    [[self navigationItem] setTitle:UCLocalize("SECTIONS")];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The back item already identifies the selected source. Keep a single
    // compact Sections title instead of rendering a second oversized header.
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection != nil &&
        ![[previousTraitCollection preferredContentSizeCategory]
            isEqualToString:[[self traitCollection] preferredContentSizeCategory]])
        [list_ reloadData];
}

- (void) releaseSubviews {
    list_ = nil;

    sections_ = nil;
    filtered_ = nil;

    [super releaseSubviews];
}

- (id) initWithDatabase:(Database *)database source:(Source *)source {
    if ((self = [super init]) != nil) {
        database_ = database;
        key_ = [source key];
    } return self;
}

- (void) reloadData {
    [super reloadData];

    NSArray *packages = [database_ packages];

    sections_ = [NSMutableArray arrayWithCapacity:16];
    filtered_ = [NSMutableArray arrayWithCapacity:16];

    NSMutableDictionary *sections([NSMutableDictionary dictionaryWithCapacity:32]);

    Source *source([self source]);

    _trace();
    for (Package *package in packages) {
        if (source != nil && ![package availableFromSource:source])
            continue;

        NSString *name([package section]);
        NSString *key(name == nil ? @"" : name);

        Section *section;

        _profile(SectionsView$reloadData$Section)
            section = [sections objectForKey:key];
            if (section == nil) {
                _profile(SectionsView$reloadData$Section$Allocate)
                    section = [[[Section alloc] initWithName:key localize:YES] autorelease];
                    [sections setObject:section forKey:key];
                _end
            }
        _end

        [section addToCount];

        _profile(SectionsView$reloadData$Filter)
            if (![package visible])
                continue;
        _end

        [section addToRow];
    }
    _trace();

    [sections_ addObjectsFromArray:[sections allValues]];

    [sections_ sortUsingSelector:@selector(compareByLocalized:)];

    for (Section *section in (id) sections_) {
        size_t count([section row]);
        if (count == 0)
            continue;

        section = [[[Section alloc] initWithName:[section name] localized:[section localized]] autorelease];
        [section setCount:count];
        [filtered_ addObject:section];
    }

    [self updateNavigationItem];
    [list_ reloadData];
    _trace();
}

- (void) editButtonClicked {
    [self setEditing:![self isEditing] animated:YES];
}

@end
/* }}} */

/* Changes Controller {{{ */
@interface ChangesController : FilteredPackageListController {
    size_t upgrades_;
    _H<CydiaSourceRefreshBar> refreshBar_;
}

- (id) initWithDatabase:(Database *)database;
- (void) refreshUpgradeButton;
- (void) sourceRefreshStateDidChange;

@end

@implementation ChangesController

- (BOOL) supportsPullToRefresh {
    // Reload is the explicit repository action. Pulling this local list should
    // not insert a spinner or suggest that a second refresh has started.
    return NO;
}

- (void) loadView {
    [super loadView];
    UIView *view([self view]);
    refreshBar_ = [[[CydiaSourceRefreshBar alloc] initWithFrame:CGRectZero] autorelease];
    [refreshBar_ setTranslatesAutoresizingMaskIntoConstraints:NO];
    [refreshBar_ setIsAccessibilityElement:YES];
    [refreshBar_ setAccessibilityLabel:CYLocalize(@"Refreshing")];
    [view addSubview:refreshBar_];
    [NSLayoutConstraint activateConstraints:@[
        [[refreshBar_ topAnchor] constraintEqualToAnchor:[[view safeAreaLayoutGuide] topAnchor] constant:2.0f],
        [[refreshBar_ leadingAnchor] constraintEqualToAnchor:[view leadingAnchor]],
        [[refreshBar_ trailingAnchor] constraintEqualToAnchor:[view trailingAnchor]],
        [[refreshBar_ heightAnchor] constraintEqualToConstant:3.0f],
    ]];
    [refreshBar_ setRefreshing:[self.delegate updating]];
}

- (void) releaseSubviews {
    refreshBar_ = nil;
    [super releaseSubviews];
}

- (NSURL *) referrerURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/changes/", UI_]];
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:@"cydia://changes"];
}

- (Package *) packageAtIndexPath:(NSIndexPath *)path {
@synchronized (database_) {
    if ([database_ era] != era_)
        return nil;

    NSUInteger sectionIndex([path section]);
    if (sectionIndex >= [sections_ count])
        return nil;
    Section *section([sections_ objectAtIndex:sectionIndex]);
    NSInteger row([path row]);
    if (row < 0)
        return nil;
    NSUInteger packageIndex([section row] + row);
    if (packageIndex >= [packages_ count])
        return nil;
    return [[[packages_ objectAtIndex:packageIndex] retain] autorelease];
} }

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"norefresh"])
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
}

- (void) setLeftBarButtonItem {
    if ([self.delegate updating])
        [[self navigationItem] setLeftBarButtonItem:CYModernBarButtonItem(@"xmark", UCLocalize("CANCEL"),
            UIBarButtonItemStyleDone, self, @selector(cancelButtonClicked)) animated:YES];
    else
        [[self navigationItem] setLeftBarButtonItem:CYModernBarButtonItem(@"arrow.clockwise", UCLocalize("REFRESH"),
            UIBarButtonItemStylePlain, self, @selector(refreshButtonClicked)) animated:YES];
}

- (void) refreshButtonClicked {
    [self.delegate requestUpdate];
}

- (void) cancelButtonClicked {
    [self.delegate cancelUpdate];
    // Cancellation is cooperative. Prevent repeated requests while the APT
    // worker unwinds; the central completion signal restores Refresh only
    // after the database has reached its final, authoritative state.
    [[[self navigationItem] leftBarButtonItem] setEnabled:NO];
}

- (void) sourceRefreshStateDidChange {
    [refreshBar_ setRefreshing:[self.delegate updating]];
    [self setLeftBarButtonItem];
    [self refreshUpgradeButton];
    CYRootlessDiag(@"CHANGES", @"UI refresh state active=%d leftAction=%@ upgrades=%zu",
        [self.delegate updating] ? 1 : 0,
        [self.delegate updating] ? @"cancel" : @"refresh", upgrades_);
}

- (void) upgradeButtonClicked {
    if ([self.delegate updating])
        return;
    [[[self navigationItem] rightBarButtonItem] setEnabled:NO];
    [self.delegate distUpgrade];
    // Keep the action visible until APT has actually accepted the queue. The
    // previous speculative removal made a failed attempt look like a dead UI.
    [self performSelector:@selector(refreshUpgradeButton) withObject:nil afterDelay:0.25];
}

- (void) updateUpgradeButtonWithCount:(size_t)count animated:(BOOL)animated {
    upgrades_ = count;
    UINavigationItem *navigationItem([self navigationItem]);
    if (upgrades_ == 0) {
        [navigationItem setRightBarButtonItem:nil animated:animated];
        return;
    }

    NSString *title([NSString stringWithFormat:UCLocalize("PARENTHETICAL"), UCLocalize("UPGRADE"), [NSString stringWithFormat:@"%zu", upgrades_]]);
    UIBarButtonItem *button([navigationItem rightBarButtonItem]);
    if (button == nil || [button action] != @selector(upgradeButtonClicked)) {
        button = [[[UIBarButtonItem alloc]
            initWithTitle:title
            style:UIBarButtonItemStylePlain
            target:self
            action:@selector(upgradeButtonClicked)
        ] autorelease];
        [navigationItem setRightBarButtonItem:button animated:animated];
    } else {
        [button setTitle:title];
    }
    [button setEnabled:![self.delegate updating]];
    [button setAccessibilityLabel:title];
}

- (void) refreshUpgradeButton {
    size_t count(0);
@synchronized (database_) {
    for (Package *package in [database_ packages])
        if ([package upgradableAndEssential:YES] && ![package ignored])
            ++count;
}
    [self updateUpgradeButtonWithCount:count animated:YES];
}

- (bool) shouldYield {
    return true;
}

- (bool) shouldBlock {
    // The current snapshot stays visible while the local list is rebuilt.
    // Network activity is already represented by the repository refresh bar.
    return false;
}

- (void) useFilter {
@synchronized (self) {
    [self setFilter:[](Package *package) {
        return [package upgradableAndEssential:YES] || [package visible];
    }];

    [self setSorter:[](NSMutableArray *packages) {
        [packages radixSortUsingFunction:reinterpret_cast<MenesRadixSortFunction>(&PackageChangesRadix) withContext:NULL];
    }];
} }

- (id) initWithDatabase:(Database *)database {
    if ((self = [super initWithDatabase:database title:UCLocalize("CHANGES")]) != nil) {
        upgrades_ = 0;
        [self useFilter];
    } return self;
}

- (void) viewDidLoad {
    [super viewDidLoad];
    // Changes is already identified by the selected tab. Keep one compact
    // navigation row for Refresh, the centred title and Upgrade.
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    [self setLeftBarButtonItem];
    [self refreshUpgradeButton];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    [refreshBar_ setRefreshing:[self.delegate updating]];
    [self setLeftBarButtonItem];
    // The list loads asynchronously. Read the current atomic Database snapshot
    // now so Upgrade is already correct on the first visible frame.
    [self refreshUpgradeButton];
}

- (void) reloadData {
    [self setLeftBarButtonItem];
    [self refreshUpgradeButton];
    [super reloadData];
}

- (NSArray *) sectionsForPackages:(NSMutableArray *)packages {
    NSMutableArray *sections([NSMutableArray arrayWithCapacity:16]);

    Section *upgradable = [[[Section alloc] initWithName:UCLocalize("AVAILABLE_UPGRADES") localize:NO] autorelease];
    Section *ignored = nil;
    Section *section = nil;
    NSString *lastDate = nil;

    size_t upgrades = 0;

    // A date-only section header avoids awkward locale strings such as
    // "NEW AT 29.08.2026. AT 22:49:59" and keeps the Changes list scannable.
    CFDateFormatterRef formatter(CFDateFormatterCreate(NULL, Locale_, kCFDateFormatterMediumStyle, kCFDateFormatterNoStyle));

    for (size_t offset = 0, count = [packages count]; offset != count; ++offset) {
        Package *package = [packages objectAtIndex:offset];

        BOOL uae = [package upgradableAndEssential:YES];

        if (!uae) {
            time_t seen([package seen]);
            NSString *date((NSString *) CFDateFormatterCreateStringWithDate(
                NULL, formatter, (CFDateRef) [NSDate dateWithTimeIntervalSince1970:seen]));
            [date autorelease];
            if (date == nil)
                date = @"";

            // Several successful refreshes on the same day have different
            // exact timestamps but the same date-only heading. Group by the
            // heading users actually see so Changes never repeats identical
            // "New at <date>" sections.
            if (section == nil || ![lastDate isEqualToString:date]) {
                lastDate = date;

                _profile(ChangesController$reloadData$Allocate)
                    NSString *name([NSString stringWithFormat:CYLocalize(@"Added or updated · %@"), date]);
                    section = [[[Section alloc] initWithName:name row:offset localize:NO] autorelease];
                    [sections addObject:section];
                _end
            }

            [section addToCount];
        } else if ([package ignored]) {
            if (ignored == nil) {
                ignored = [[[Section alloc] initWithName:UCLocalize("IGNORED_UPGRADES") row:offset localize:NO] autorelease];
            }
            [ignored addToCount];
        } else {
            ++upgrades;
            [upgradable addToCount];
        }
    }
    _trace();

    CFRelease(formatter);

    // Every observed date is meaningful. Dropping the final date bucket
    // silently discarded real packages, including the only day on new setups.

    if ([ignored count] != 0)
        [sections insertObject:ignored atIndex:0];
    if (upgrades != 0)
        [sections insertObject:upgradable atIndex:0];

    [self updateUpgradeButtonWithCount:upgrades animated:YES];

    return sections;
}

@end
/* }}} */
/* Search Controller {{{ */
@interface SearchController : FilteredPackageListController <
    UISearchBarDelegate
> {
    _H<UISearchBar, 1> search_;
    _H<UISearchController> searchController_;
    _H<UIView> emptyState_;
    BOOL searchloaded_;
    bool summary_;
}

- (id) initWithDatabase:(Database *)database query:(NSString *)query;
- (void) reloadData;
- (void) updateEmptyState;

@end

@implementation SearchController

- (BOOL) supportsPullToRefresh {
    return NO;
}

- (NSURL *) referrerURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/search?q=%@", UI_, [([search_ text] ?: @"") stringByAddingPercentEscapesIncludingReserved]]];
}

- (NSURL *) navigationURL {
    if ([search_ text] == nil || [[search_ text] isEqualToString:@""])
        return [NSURL URLWithString:@"cydia://search"];
    else
        return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://search/%@", [[search_ text] stringByAddingPercentEscapesIncludingReserved]]];
}

- (void) useSearch {
    _H<NSString> query([[search_ text] ?: @"" stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    summary_ = false;

@synchronized (self) {
    [self setFilter:[=](Package *package) {
        if (![package unfiltered])
            return false;
        if (!CYPackageMatchesSileoSearch(package, query))
            return false;
        return true;
    }];

    [self setSorter:[=](NSMutableArray *packages) {
        [packages sortUsingFunction:CYSearchPackageCompare context:(void *) (NSString *) query];
    }];
}

    [self clearData];
    [self reloadData];
}

- (void) searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [self useSearch];
}

- (void) searchBarButtonClicked:(UISearchBar *)searchBar {
    [search_ resignFirstResponder];
    [self useSearch];
    [self updateEmptyState];
}

- (void) searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [search_ setText:@""];
    [self searchBarButtonClicked:searchBar];
}

- (void) searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self searchBarButtonClicked:searchBar];
}

- (void) searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    [self updateEmptyState];
    [self useSearch];
}

- (bool) shouldYield {
    return YES;
}

- (bool) shouldBlock {
    return false;
}

- (bool) isSummarized {
    return false;
}

- (bool) showsSections {
    return false;
}

- (void) loadView {
    [super loadView];

    emptyState_ = [[[UIView alloc] initWithFrame:[[self tableView] bounds]] autorelease];
    [emptyState_ setBackgroundColor:[UIColor clearColor]];

    UIImageView *icon([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:@"magnifyingglass.circle.fill"]] autorelease]);
    [icon setTintColor:[UIColor tertiaryLabelColor]];
    [icon setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:42.0f weight:UIImageSymbolWeightRegular]];

    UILabel *title([[[UILabel alloc] init] autorelease]);
    [title setText:CYLocalize(@"Search Packages")];
    [title setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2]];
    [title setTextColor:[UIColor labelColor]];
    [title setTextAlignment:NSTextAlignmentCenter];
    [title setAdjustsFontForContentSizeCategory:YES];

    UILabel *detail([[[UILabel alloc] init] autorelease]);
    [detail setText:CYLocalize(@"Find packages by name, identifier, author, or maintainer.")];
    [detail setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]];
    [detail setTextColor:[UIColor secondaryLabelColor]];
    [detail setTextAlignment:NSTextAlignmentCenter];
    [detail setNumberOfLines:2];
    [detail setAdjustsFontForContentSizeCategory:YES];

    UIStackView *content([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:icon, title, detail, nil]] autorelease]);
    [content setTranslatesAutoresizingMaskIntoConstraints:NO];
    [content setAxis:UILayoutConstraintAxisVertical];
    [content setAlignment:UIStackViewAlignmentCenter];
    [content setSpacing:8.0f];
    [emptyState_ addSubview:content];

    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [[content centerXAnchor] constraintEqualToAnchor:[emptyState_ centerXAnchor]],
        [[content centerYAnchor] constraintEqualToAnchor:[emptyState_ centerYAnchor] constant:-72.0f],
        [[content leadingAnchor] constraintGreaterThanOrEqualToAnchor:[emptyState_ leadingAnchor] constant:28.0f],
        [[content trailingAnchor] constraintLessThanOrEqualToAnchor:[emptyState_ trailingAnchor] constant:-28.0f],
    nil]];

    [[self tableView] setBackgroundView:emptyState_];
    [self updateEmptyState];
}

- (void) updateEmptyState {
    [emptyState_ setHidden:[[search_ text] length] != 0];
}

- (id) initWithDatabase:(Database *)database query:(NSString *)query {
    if ((self = [super initWithDatabase:database title:UCLocalize("SEARCH")])) {
        searchController_ = [[[UISearchController alloc] initWithSearchResultsController:nil] autorelease];
        [searchController_ setObscuresBackgroundDuringPresentation:NO];
        search_ = [searchController_ searchBar];
        [search_ setPlaceholder:UCLocalize("SEARCH_EX")];
        [search_ setDelegate:self];
        [[search_ searchTextField] setEnablesReturnKeyAutomatically:NO];
        [[self navigationItem] setSearchController:searchController_];
        [[self navigationItem] setHidesSearchBarWhenScrolling:NO];
        [self setDefinesPresentationContext:YES];

        if (query != nil)
            [search_ setText:query];
        [self useSearch];
        [self updateEmptyState];
    } return self;
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The search field is the primary control, so a second oversized Search
    // heading only delays access to it.
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    searchloaded_ = YES;
    [self updateEmptyState];

    if ([self isSummarized])
        [search_ becomeFirstResponder];
}

- (void) reloadData {
    [self resetCursor];
    [super reloadData];
}

- (void) didSelectPackage:(Package *)package {
    [search_ resignFirstResponder];
    [super didSelectPackage:package];
}

@end
/* }}} */
/* Package Settings Controller {{{ */
@interface PackageSettingsController : CyteViewController <
    UITableViewDataSource,
    UITableViewDelegate
> {
    _transient Database *database_;
    _H<NSString> name_;
    _H<Package> package_;
    _H<UITableView, 2> table_;
    _H<UISwitch> subscribedSwitch_;
    _H<UISwitch> ignoredSwitch_;
    _H<UITableViewCell> subscribedCell_;
    _H<UITableViewCell> ignoredCell_;
}

- (id) initWithDatabase:(Database *)database package:(NSString *)package;

@end

@implementation PackageSettingsController

- (NSURL *) navigationURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"cydia://package/%@/settings", (id) name_]];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    if (package_ == nil)
        return 0;

    if ([package_ installed] == nil)
        return 1;
    else
        return 2;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (package_ == nil)
        return 0;

    // both sections contain just one item right now.
    return 1;
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return nil;
}

- (NSString *) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return UCLocalize("SHOW_ALL_CHANGES_EX");
    else
        return UCLocalize("IGNORE_UPGRADES_EX");
}

- (void) onSubscribed:(id)control {
    bool value([control isOn]);
    if (package_ == nil)
        return;
    if ([package_ setSubscribed:value])
        [self.delegate updateData];
}

static bool CYSetPackageSelection(NSString *name, bool hold) {
    const char *cydo = "/var/jb/usr/libexec/cydia/cydo";
    const char *package = [name UTF8String];
    if (package == NULL || package[0] == '\0') {
        CYRootlessDiag(@"PACKAGESETTINGS", @"level=ERROR ignore-upgrades failed phase=validate reason=empty-package");
        return false;
    }

    std::string selection(package);
    selection += hold ? " hold\n" : " install\n";
    CYRootlessDiag(@"PACKAGESETTINGS", @"ignore-upgrades begin package=%@ requested=%@",
        name, hold ? @"hold" : @"install");

    int input[2];
    if (pipe(input) != 0) {
        CYRootlessDiag(@"PACKAGESETTINGS", @"level=ERROR ignore-upgrades failed package=%@ phase=pipe errno=%d error=%s",
            name, errno, strerror(errno));
        return false;
    }

    // Feed the tiny dpkg selection record before starting the child. Keeping
    // the read end open in this process prevents a SIGPIPE race if cydo/dpkg
    // startup fails; the child later receives the already-buffered record.
    bool wrote = true;
    size_t offset = 0;
    while (offset < selection.size()) {
        ssize_t count = write(input[1], selection.data() + offset, selection.size() - offset);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            CYRootlessDiag(@"PACKAGESETTINGS", @"level=ERROR ignore-upgrades failed package=%@ phase=write-stdin errno=%d error=%s",
                name, errno, strerror(errno));
            wrote = false;
            break;
        }
        offset += static_cast<size_t>(count);
    }
    close(input[1]);
    if (!wrote) {
        close(input[0]);
        return false;
    }

    posix_spawn_file_actions_t actions;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) {
        CYRootlessDiag(@"PACKAGESETTINGS", @"level=ERROR ignore-upgrades failed package=%@ phase=file-actions-init status=%d", name, result);
        close(input[0]);
        return false;
    }

    result = posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    if (result == 0)
        result = posix_spawn_file_actions_addclose(&actions, input[0]);

    char *const argv[] = {
        const_cast<char *>(cydo),
        const_cast<char *>("--set-selections"),
        NULL
    };

    pid_t pid = -1;
    if (result == 0)
        result = posix_spawn(&pid, cydo, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(input[0]);

    if (result != 0) {
        CYRootlessDiag(@"PACKAGESETTINGS", @"level=ERROR ignore-upgrades failed package=%@ phase=spawn status=%d", name, result);
        return false;
    }

    CYRootlessDiag(@"PACKAGESETTINGS", @"ignore-upgrades child pid=%d package=%@", pid, name);

    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(pid, &status, 0);
    } while (waited < 0 && errno == EINTR);

    if (waited != pid) {
        CYRootlessDiag(@"PACKAGESETTINGS", @"level=ERROR ignore-upgrades failed package=%@ phase=waitpid child=%d waited=%d errno=%d error=%s",
            name, pid, waited, errno, strerror(errno));
        return false;
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        CYRootlessDiag(@"PACKAGESETTINGS", @"level=ERROR ignore-upgrades failed package=%@ phase=child-exit rawStatus=%d exited=%d exitCode=%d signaled=%d signal=%d",
            name, status, WIFEXITED(status), WIFEXITED(status) ? WEXITSTATUS(status) : -1,
            WIFSIGNALED(status), WIFSIGNALED(status) ? WTERMSIG(status) : 0);
        return false;
    }

    CYRootlessDiag(@"PACKAGESETTINGS", @"ignore-upgrades end status=ok package=%@ selected=%@ bytes=%zu",
        name, hold ? @"hold" : @"install", selection.size());
    return true;
}

- (void) _updateIgnored {
    bool on([ignoredSwitch_ isOn]);
    NSString *name((id) name_);
    if (!CYSetPackageSelection(name, on))
        CYRootlessDiag(@"PACKAGESETTINGS", @"level=ERROR ignore-upgrades request not applied package=%@ requested=%@",
            name, on ? @"hold" : @"install");
}

- (void) onIgnored:(id)control {
    NSInvocation *invocation([NSInvocation invocationWithMethodSignature:[self methodSignatureForSelector:@selector(_updateIgnored)]]);
    [invocation setTarget:self];
    [invocation setSelector:@selector(_updateIgnored)];

    [self.delegate reloadDataWithInvocation:invocation];
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (package_ == nil)
        return [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil] autorelease];

    switch ([indexPath section]) {
        case 0: return subscribedCell_;
        case 1: return ignoredCell_;

        _nodefault
    }

    return [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil] autorelease];
}

- (void) loadView {
    UIView *view([[[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]] autorelease]);
    [view setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
    [self setView:view];

    table_ = [[[UITableView alloc] initWithFrame:[[self view] bounds] style:CYModernGroupedTableStyle()] autorelease];
    [table_ setAutoresizingMask:UIViewAutoresizingFlexibleBoth];
    CYModernizeTableView(table_);
    [(UITableView *) table_ setDataSource:self];
    [table_ setDelegate:self];
    [view addSubview:table_];

    subscribedSwitch_ = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 50, 20)] autorelease];
    [subscribedSwitch_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];
    [subscribedSwitch_ addTarget:self action:@selector(onSubscribed:) forEvents:UIControlEventValueChanged];

    ignoredSwitch_ = [[[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 50, 20)] autorelease];
    [ignoredSwitch_ setAutoresizingMask:UIViewAutoresizingFlexibleLeftMargin];
    [ignoredSwitch_ addTarget:self action:@selector(onIgnored:) forEvents:UIControlEventValueChanged];

    subscribedCell_ = [[[UITableViewCell alloc] init] autorelease];
    [subscribedCell_ setText:UCLocalize("SHOW_ALL_CHANGES")];
    [subscribedCell_ setAccessoryView:subscribedSwitch_];
    [subscribedCell_ setSelectionStyle:UITableViewCellSelectionStyleNone];

    ignoredCell_ = [[[UITableViewCell alloc] init] autorelease];
    [ignoredCell_ setText:UCLocalize("IGNORE_UPGRADES")];
    [ignoredCell_ setAccessoryView:ignoredSwitch_];
    [ignoredCell_ setSelectionStyle:UITableViewCellSelectionStyleNone];
}

- (void) viewDidLoad {
    [super viewDidLoad];

    [[self navigationItem] setTitle:UCLocalize("SETTINGS")];
}

- (void) releaseSubviews {
    ignoredCell_ = nil;
    subscribedCell_ = nil;
    table_ = nil;
    ignoredSwitch_ = nil;
    subscribedSwitch_ = nil;

    [super releaseSubviews];
}

- (id) initWithDatabase:(Database *)database package:(NSString *)package {
    if ((self = [super init]) != nil) {
        database_ = database;
        name_ = package;
    } return self;
}

- (void) reloadData {
    [super reloadData];

    package_ = [database_ packageWithName:name_];

    if (package_ != nil) {
        [subscribedSwitch_ setOn:([package_ subscribed] ? 1 : 0) animated:NO];
        [ignoredSwitch_ setOn:([package_ ignored] ? 1 : 0) animated:NO];
    } // XXX: what now, G?

    [table_ reloadData];
}

@end
/* }}} */

/* Installed Controller {{{ */
@interface InstalledController : FilteredPackageListController {
    bool sectioned_;
    _H<UISegmentedControl> segmented_;
    _H<UIView> modeHeader_;
    _H<UILabel> modeCaption_;
}

- (id) initWithDatabase:(Database *)database;
- (void) queueStatusDidChange;
- (void) updateModeHeaderForCurrentContentSize;

@end

@implementation InstalledController

- (BOOL) supportsPullToRefresh {
    return NO;
}

- (NSURL *) referrerURL {
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/#!/installed/", UI_]];
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:@"cydia://installed"];
}

- (void) useRecent {
    sectioned_ = false;

@synchronized (self) {
    [self setFilter:[](Package *package) {
        return ![package uninstalled] && package->role_ < 7;
    }];

    [self setSorter:[](NSMutableArray *packages) {
        [packages radixSortUsingSelector:@selector(recent)];
    }];
} }

- (void) useFilter:(UISegmentedControl *)segmented {
    NSInteger selected([segmented selectedSegmentIndex]);
    if (selected == 2)
        return [self useRecent];
    sectioned_ = true;

@synchronized (self) {
    if (selected == 0)
        [self setFilter:[](Package *package) {
            return CYInstalledPackageVisibleToUser(package);
        }];
    else
        [self setFilter:[](Package *package) {
            // Match the all-installed boundary used by Sileo and Zebra while
            // keeping Cydia's internal role::cydia metapackages out of the UI.
            return ![package uninstalled] && package->role_ < 7;
        }];

    [self setSorter:nullptr];
} }

- (NSArray *) sectionsForPackages:(NSMutableArray *)packages {
    if (sectioned_)
        return [super sectionsForPackages:packages];
    NSDateFormatter *formatter([[[NSDateFormatter alloc] init] autorelease]);
    [formatter setDateStyle:NSDateFormatterLongStyle];
    [formatter setTimeStyle:NSDateFormatterNoStyle];
    NSMutableArray *sections([NSMutableArray array]);
    Section *section(nil);
    NSDate *lastDay(nil);
    for (NSUInteger offset(0); offset < [packages count]; ++offset) {
        Package *package([packages objectAtIndex:offset]);
        NSDate *day(CYLibraryDay([package upgraded]));
        if (section == nil || !(day == lastDay || [day isEqualToDate:lastDay])) {
            lastDay = day;
            NSString *name(day == nil ? CYLocalize(@"Date unavailable") : [formatter stringFromDate:day]);
            section = [[[Section alloc] initWithName:name row:offset localize:NO] autorelease];
            [sections addObject:section];
        }
        [section addToCount];
    }
    return sections;
}

- (id) initWithDatabase:(Database *)database {
    if ((self = [super initWithDatabase:database title:UCLocalize("INSTALLED")]) != nil) {
        segmented_ = [[[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:UCLocalize("USER"), UCLocalize("EXPERT"), UCLocalize("RECENT"), nil]] autorelease];
        [segmented_ setSelectedSegmentIndex:0];
        [segmented_ setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];
        [segmented_ setSelectedSegmentTintColor:CYModernPrimaryButtonColor()];
        [segmented_ setTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:
            [UIColor labelColor], NSForegroundColorAttributeName,
            [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], NSFontAttributeName,
        nil] forState:UIControlStateNormal];
        [segmented_ setTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:
            [UIColor whiteColor], NSForegroundColorAttributeName,
            [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote], NSFontAttributeName,
        nil] forState:UIControlStateSelected];

        [segmented_ addTarget:self action:@selector(modeChanged:) forEvents:UIControlEventValueChanged];
        [self useFilter:segmented_];

        [self queueStatusDidChange];
    } return self;
}

- (void) loadView {
    [super loadView];

    modeHeader_ = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    [modeHeader_ setBackgroundColor:[UIColor clearColor]];

    UISegmentedControl *segmented(segmented_);
    [segmented setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [modeHeader_ addSubview:segmented];
    modeCaption_ = [[[UILabel alloc] init] autorelease];
    [modeCaption_ setTextColor:[UIColor secondaryLabelColor]];
    [modeCaption_ setNumberOfLines:0];
    [modeCaption_ setAdjustsFontForContentSizeCategory:YES];
    [modeHeader_ addSubview:modeCaption_];
    [self updateModeHeaderForCurrentContentSize];
}

- (void) updateModeHeaderForCurrentContentSize {
    if (modeHeader_ == nil)
        return;
    UITableView *table([self tableView]);
    // Three translated segment titles must remain legible on compact iPhones.
    // Scale with the user's text setting, but cap this inherently horizontal
    // control before UIKit starts clipping the titles at accessibility sizes.
    UIFont *font([[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
        scaledFontForFont:[UIFont systemFontOfSize:13.0f]
        maximumPointSize:18.0f]);
    [segmented_ setTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:
        [UIColor labelColor], NSForegroundColorAttributeName,
        font, NSFontAttributeName,
    nil] forState:UIControlStateNormal];
    [segmented_ setTitleTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:
        [UIColor whiteColor], NSForegroundColorAttributeName,
        font, NSFontAttributeName,
    nil] forState:UIControlStateSelected];
    CGFloat segmentHeight(ceil(MAX(36.0f, [font lineHeight] + 16.0f)));
    [modeCaption_ setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]];
    NSArray *captions(@[CYLocalize(@"Apps, tweaks and themes"), CYLocalize(@"All installed packages, including dependencies"), CYLocalize(@"Latest installations and updates first")]);
    [modeCaption_ setText:[captions objectAtIndex:MAX(0, MIN(2, [segmented_ selectedSegmentIndex]))]];
    CGFloat width(MAX(0.0f, [table bounds].size.width - 40.0f));
    CGFloat captionHeight(ceil([modeCaption_ sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height));
    CGFloat headerHeight(segmentHeight + captionHeight + 32.0f);
    [modeHeader_ setFrame:CGRectMake(0.0f, 0.0f, [table bounds].size.width, headerHeight)];
    [segmented_ setFrame:CGRectMake(16.0f, 8.0f,
        MAX(0.0f, [modeHeader_ bounds].size.width - 32.0f), segmentHeight)];
    [modeCaption_ setFrame:CGRectMake(20.0f, segmentHeight + 16.0f, width, captionHeight)];
    [table setTableHeaderView:modeHeader_];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[self navigationItem] setTitleView:nil];
    // Keep Installed compact; the segmented control immediately below is the
    // useful hierarchy for this screen.
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    [self updateModeHeaderForCurrentContentSize];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection != nil &&
        ![[previousTraitCollection preferredContentSizeCategory]
            isEqualToString:[[self traitCollection] preferredContentSizeCategory]]) {
        [self updateModeHeaderForCurrentContentSize];
        [[self tableView] reloadData];
    }
}

#if !AlwaysReload
- (void) queueButtonClicked {
    [self.delegate queue];
}
#endif

- (void) queueStatusDidChange {
#if !AlwaysReload
    if (Queuing_) {
        [[self navigationItem] setRightBarButtonItem:CYModernBarButtonItem(@"list.bullet.rectangle", UCLocalize("QUEUE"),
            UIBarButtonItemStyleDone, self, @selector(queueButtonClicked))];
    } else {
        [[self navigationItem] setRightBarButtonItem:nil];
    }
#endif
}

- (void) modeChanged:(UISegmentedControl *)segmented {
    [self useFilter:segmented];
    [self updateModeHeaderForCurrentContentSize];
    [self reloadData];
}

@end
/* }}} */

/* Source Cell {{{ */
@interface SourceCell : CyteTableViewCell <
    CyteTableViewCellDelegate,
    SourceDelegate
> {
    _H<Source, 1> source_;
    _H<NSURL> url_;
    _H<UIImage> icon_;
    _H<NSString> origin_;
    _H<NSString> label_;
    _H<UIImageView> iconView_;
    _H<UILabel> originLabel_;
    _H<UILabel> detailLabel_;
    _H<UIView> refreshBar_;
    _H<CAGradientLayer> refreshShimmer_;
}

- (void) setSource:(Source *)source;
- (void) setUnavailableSource;
- (void) setFetch:(NSNumber *)fetch;

@end

@implementation SourceCell

- (void) _setImage:(NSArray *)data {
    if ([url_ isEqual:[data objectAtIndex:0]]) {
        icon_ = [data objectAtIndex:1];
        [iconView_ setTintColor:nil];
        [UIView transitionWithView:iconView_ duration:0.18
            options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
            animations:^{ [iconView_ setImage:icon_]; } completion:NULL];
    }
}

- (void) _setSource:(NSURL *) url {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    if (NSData *data = [NSURLConnection
        sendSynchronousRequest:[NSURLRequest
            requestWithURL:url
            cachePolicy:NSURLRequestUseProtocolCachePolicy
            timeoutInterval:10
        ]

        returningResponse:NULL
        error:NULL
    ])
        if (UIImage *image = CYPreparedPackageIcon(data, [[UIScreen mainScreen] scale])) {
            // Persist to the shared on-disk icon cache so the repository icon
            // is read straight back on the next visit instead of re-fetched,
            // which is what made the Sources list flash a placeholder on entry.
            NSString *address([url absoluteString]);
            if ([address length] != 0) {
                CYPersistModernPackageIcon(address, data);
                [CYModernPackageIconCache() setObject:image forKey:address cost:CYPackageIconMemoryCost(image)];
            }
            [self performSelectorOnMainThread:@selector(_setImage:) withObject:[NSArray arrayWithObjects:url, image, nil] waitUntilDone:NO];
        }

    [pool release];
}

- (void) setSource:(Source *)source {
    NSString *previousKey([source_ key]);
    NSString *nextKey([source key]);
    NSURL *nextURL([source iconURL]);
    BOOL sameSource(source_ != nil &&
        ((previousKey == nil && nextKey == nil) || [previousKey isEqualToString:nextKey]));
    BOOL preserveIcon(sameSource && icon_ != nil &&
        ((url_ == nil && nextURL == nil) || [url_ isEqual:nextURL]));

    source_ = source;
    [source_ setDelegate:self];

    [self setFetch:[NSNumber numberWithBool:[source_ fetch]]];

    origin_ = [source name];
    NSString *issue(CYRepositoryIssueCode([source rooturi]));
    if (issue != nil && !CYRepositoryIssueIsSecurity(issue)) {
        label_ = CYRepositoryIssueSummary(issue);
        [detailLabel_ setTextColor:[UIColor systemRedColor]];
    } else {
        label_ = [source rooturi];
        [detailLabel_ setTextColor:[UIColor secondaryLabelColor]];
    }
    [originLabel_ setText:origin_];
    [detailLabel_ setText:label_];

    url_ = nextURL;
    if (!preserveIcon) {
        // Read the repository icon from the shared memory/disk cache first so a
        // previously seen source shows its real icon immediately, with no
        // placeholder flash on entry or during a refresh. Only fetch (and then
        // persist) when the icon has never been cached.
        NSString *iconAddress([nextURL absoluteString]);
        UIImage *cachedIcon(nil);
        if ([iconAddress length] != 0) {
            cachedIcon = [CYModernPackageIconCache() objectForKey:iconAddress];
            if (cachedIcon == nil)
                cachedIcon = CYModernPackageIconFromDisk(iconAddress);
        }
        if (cachedIcon != nil) {
            icon_ = cachedIcon;
            [iconView_ setTintColor:nil];
            [iconView_ setImage:icon_];
        } else {
            icon_ = [UIImage cy_symbolNamed:@"square.stack.3d.up.fill"];
            [iconView_ setTintColor:CYModernAccentColor()];
            [iconView_ setImage:icon_];
            if (nextURL != nil)
                [NSThread detachNewThreadSelector:@selector(_setSource:) toTarget:self withObject:nextURL];
        }
    }
}

- (void) setAllSource {
    source_ = nil;
    url_ = nil;
    [self setRefreshing:NO];

    icon_ = [UIImage cy_symbolNamed:@"square.stack.3d.up.fill"];
    origin_ = UCLocalize("ALL_SOURCES");
    label_ = UCLocalize("ALL_SOURCES_EX");
    [detailLabel_ setTextColor:[UIColor secondaryLabelColor]];
    [iconView_ setTintColor:CYModernAccentColor()];
    [iconView_ setImage:icon_];
    [originLabel_ setText:origin_];
    [detailLabel_ setText:label_];
}

- (void) setUnavailableSource {
    source_ = nil;
    url_ = nil;
    [self setRefreshing:YES];

    icon_ = [UIImage cy_symbolNamed:@"square.stack.3d.up.fill"];
    origin_ = CYLocalize(@"Refreshing source…");
    label_ = CYLocalize(@"Please wait for the source list to finish updating");
    [detailLabel_ setTextColor:[UIColor secondaryLabelColor]];
    [iconView_ setTintColor:CYModernAccentColor()];
    [iconView_ setImage:icon_];
    [originLabel_ setText:origin_];
    [detailLabel_ setText:label_];
}

- (SourceCell *) initWithFrame:(CGRect)frame reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithFrame:frame reuseIdentifier:reuseIdentifier]) != nil) {
        [self.content setHidden:YES];
        [self setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];

        iconView_ = [[[CydiaSymbolView alloc] init] autorelease];
        [iconView_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [iconView_ setContentMode:UIViewContentModeScaleAspectFill];
        [iconView_ setClipsToBounds:YES];
        [iconView_ setBackgroundColor:[UIColor tertiarySystemGroupedBackgroundColor]];
        [[iconView_ layer] setCornerRadius:10.0f];
        [[iconView_ layer] setCornerCurve:kCACornerCurveContinuous];

        originLabel_ = [[[UILabel alloc] init] autorelease];
        [originLabel_ setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
        [originLabel_ setTextColor:[UIColor labelColor]];
        [originLabel_ setNumberOfLines:1];
        [originLabel_ setAdjustsFontForContentSizeCategory:YES];

        detailLabel_ = [[[UILabel alloc] init] autorelease];
        [detailLabel_ setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]];
        [detailLabel_ setTextColor:[UIColor secondaryLabelColor]];
        [detailLabel_ setNumberOfLines:2];
        [detailLabel_ setAdjustsFontForContentSizeCategory:YES];

        UILabel *originLabel(originLabel_);
        UILabel *detailLabel(detailLabel_);
        UIStackView *labels([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:originLabel, detailLabel, nil]] autorelease]);
        [labels setTranslatesAutoresizingMaskIntoConstraints:NO];
        [labels setAxis:UILayoutConstraintAxisVertical];
        [labels setAlignment:UIStackViewAlignmentFill];
        [labels setSpacing:3.0f];

        // Modern refresh indicator: a thin accent bar with a highlight that
        // sweeps across it while this source is being refreshed. Replaces the
        // old per-cell spinner; the small tab-bar spinner is kept separately.
        refreshBar_ = [[[UIView alloc] init] autorelease];
        [refreshBar_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [refreshBar_ setBackgroundColor:[CYModernAccentColor() colorWithAlphaComponent:0.16f]];
        [[refreshBar_ layer] setCornerRadius:1.5f];
        [refreshBar_ setClipsToBounds:YES];
        [refreshBar_ setHidden:YES];
        [refreshBar_ setUserInteractionEnabled:NO];

        refreshShimmer_ = [CAGradientLayer layer];
        [refreshShimmer_ setStartPoint:CGPointMake(0.0f, 0.5f)];
        [refreshShimmer_ setEndPoint:CGPointMake(1.0f, 0.5f)];
        [self updateRefreshColors];
        [refreshShimmer_ setLocations:[NSArray arrayWithObjects:@(0.0), @(0.5), @(1.0), nil]];
        [[refreshBar_ layer] addSublayer:refreshShimmer_];

        [[self contentView] addSubview:iconView_];
        [[self contentView] addSubview:labels];
        [[self contentView] addSubview:refreshBar_];

        [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
            [[iconView_ leadingAnchor] constraintEqualToAnchor:[[self contentView] leadingAnchor] constant:14.0f],
            [[iconView_ centerYAnchor] constraintEqualToAnchor:[[self contentView] centerYAnchor]],
            [[iconView_ widthAnchor] constraintEqualToConstant:42.0f],
            [[iconView_ heightAnchor] constraintEqualToConstant:42.0f],
            [[labels leadingAnchor] constraintEqualToAnchor:[iconView_ trailingAnchor] constant:12.0f],
            [[labels centerYAnchor] constraintEqualToAnchor:[[self contentView] centerYAnchor]],
            [[labels trailingAnchor] constraintLessThanOrEqualToAnchor:[[self contentView] trailingAnchor] constant:-16.0f],
            [[refreshBar_ leadingAnchor] constraintEqualToAnchor:[iconView_ trailingAnchor] constant:12.0f],
            [[refreshBar_ trailingAnchor] constraintEqualToAnchor:[[self contentView] trailingAnchor] constant:-16.0f],
            [[refreshBar_ bottomAnchor] constraintEqualToAnchor:[[self contentView] bottomAnchor] constant:-9.0f],
            [[refreshBar_ heightAnchor] constraintEqualToConstant:3.0f],
        nil]];

        UIView *selection([[[UIView alloc] initWithFrame:CGRectZero] autorelease]);
        [selection setBackgroundColor:[CYModernAccentColor() colorWithAlphaComponent:0.12f]];
        [self setSelectedBackgroundView:selection];

    } return self;
}

- (void) updateRefreshColors {
    UIColor *color([CYModernAccentColor() resolvedColorWithTraitCollection:self.traitCollection]);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [refreshShimmer_ setColors:@[(id)[[color colorWithAlphaComponent:0] CGColor],
        (id)[color CGColor], (id)[[color colorWithAlphaComponent:0] CGColor]]];
    [CATransaction commit];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous])
        [self updateRefreshColors];
}

- (void) layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [refreshShimmer_ setFrame:[refreshBar_ bounds]];
    [CATransaction commit];
}

- (NSString *) accessibilityLabel {
    return origin_;
}

- (void) drawContentRect:(CGRect)rect {
    // Native labels and image view provide Dynamic Type and consistent cards.
}

- (void) setRefreshing:(BOOL)refreshing {
    if (refreshing) {
        [refreshBar_ setHidden:NO];
        if ([refreshShimmer_ animationForKey:@"cySourceShimmer"] == nil) {
            CABasicAnimation *sweep([CABasicAnimation animationWithKeyPath:@"locations"]);
            [sweep setFromValue:[NSArray arrayWithObjects:@(-0.6), @(-0.3), @(0.0), nil]];
            [sweep setToValue:[NSArray arrayWithObjects:@(1.0), @(1.3), @(1.6), nil]];
            [sweep setDuration:1.15];
            [sweep setRepeatCount:HUGE_VALF];
            [sweep setRemovedOnCompletion:NO];
            [sweep setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
            [refreshShimmer_ addAnimation:sweep forKey:@"cySourceShimmer"];
        }
    } else {
        [refreshShimmer_ removeAnimationForKey:@"cySourceShimmer"];
        [refreshBar_ setHidden:YES];
    }
}

- (void) setFetch:(NSNumber *)fetch {
    [self setRefreshing:[fetch boolValue]];
}

- (void) setSourceFetch:(NSArray *)state {
    // Delivery may follow row reuse or a database-model replacement. A stale
    // source must not change the indicator of the source now shown here.
    if ([state objectAtIndex:0] != (id) source_)
        return;
    [self setFetch:[state objectAtIndex:1]];
}

@end
/* }}} */
/* Sources Controller {{{ */
@interface SourcesController : CyteViewController <
    UITableViewDataSource,
    UITableViewDelegate
> {
    _transient Database *database_;
    unsigned era_;

    _H<UITableView, 2> list_;
    _H<UIRefreshControl> refresh_;
    _H<CydiaSourceRefreshBar> refreshBar_;
    BOOL sourceRefreshActive_;
    _H<NSMutableArray> sources_;
    int offset_;

    _H<NSString> href_;
    _H<CydiaLoadingView> hud_;
    _H<NSError> error_;
    NSURLConnection *validation_;
    BOOL repositoryResponse_;
}

- (id) initWithDatabase:(Database *)database;
- (void) updateButtonsForEditingStatusAnimated:(BOOL)animated;
- (void) openPackagesForSource:(Source *)source;
- (void) presentSourceStatusForSource:(Source *)source issue:(NSString *)issue;
- (void) showAddSourcePromptWithURL:(NSString *)url;
- (void) sourceRefreshStateDidChange;

@end

@implementation SourcesController

// Sources keeps its bottom tab bar fixed: it does not auto-hide on scroll.
- (BOOL) modernScrollTabBarHidingEnabled {
    return NO;
}

- (void) _releaseConnection:(NSURLConnection *)connection {
    if (connection != nil) {
        [connection cancel];
        //[connection setDelegate:nil];
        [connection release];
    }
}

- (void) dealloc {
    [self _releaseConnection:validation_];

    [super dealloc];
}

- (NSURL *) navigationURL {
    return [NSURL URLWithString:@"cydia://sources"];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [list_ deselectRowAtIndexPath:[list_ indexPathForSelectedRow] animated:animated];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1)
        return UCLocalize("INDIVIDUAL_SOURCES");
    return nil;
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;
        case 1: return [sources_ count];
        default: return 0;
    }
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return CYModernSourceRowHeight();
}

- (Source *) sourceAtIndexPath:(NSIndexPath *)indexPath {
@synchronized (database_) {
    if ([indexPath section] != 1)
        return nil;
    NSUInteger index([indexPath row]);
    if (index >= [sources_ count])
        return nil;
    Source *snapshot([sources_ objectAtIndex:index]);
    if ([database_ era] == era_)
        return snapshot;

    // A source refresh replaces Database's Source objects and increments its
    // era. Resolve the tapped row through its stable APT key instead of
    // returning nil (which used to be interpreted as the synthetic
    // "All Sources" row).
    NSString *key([snapshot key]);
    return [key length] == 0 ? nil : [database_ sourceWithKey:key];
} }

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"SourceCell";

    SourceCell *cell = (SourceCell *) [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (cell == nil) cell = [[[SourceCell alloc] initWithFrame:CGRectZero reuseIdentifier:cellIdentifier] autorelease];
    [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];

    Source *source([self sourceAtIndexPath:indexPath]);
    if ([indexPath section] == 0)
        [cell setAllSource];
    else if (source == nil)
        [cell setUnavailableSource];
    else
        [cell setSource:source];

    return cell;
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([indexPath section] == 0) {
        [self openPackagesForSource:nil];
        return;
    }

    Source *source([self sourceAtIndexPath:indexPath]);
    if (source == nil) {
        CYRootlessDiag(@"SOURCES", @"selection deferred reason=stale-source-snapshot section=%ld row=%ld databaseEra=%u viewEra=%u",
            (long) [indexPath section], (long) [indexPath row], [database_ era], era_);
        [self reloadData];
        [list_ deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }

    NSString *issue(CYRepositoryIssueCode([source rooturi]));
    if (issue != nil && !CYRepositoryIssueIsSecurity(issue)) {
        [self presentSourceStatusForSource:source issue:issue];
        return;
    }
    [self openPackagesForSource:source];
}

- (void) openPackagesForSource:(Source *)source {
    SectionsController *controller([[[SectionsController alloc]
        initWithDatabase:database_
        source:source
    ] autorelease]);

    [controller setDelegate:self.delegate];
    [[self navigationController] pushViewController:controller animated:YES];
}

- (void) presentSourceStatusForSource:(Source *)source issue:(NSString *)issue {
    NSString *title(CYLocalize(@"Source Problem"));
    NSString *message([NSString stringWithFormat:@"%@\n\n%@\n\n%@",
        CYRepositoryIssueSummary(issue),
        CYRepositoryIssueExplanation(issue),
        [source rooturi]]);

    UIAlertController *alert([UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"View Cached Packages")
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self openPackagesForSource:source];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL) tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self sourceAtIndexPath:indexPath] != nil;
}

- (UITableViewCellEditingStyle) tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    Source *source([self sourceAtIndexPath:indexPath]);
    NSString *key([source key]);
    return key != nil && [source record] != nil && [source record] == [Sources_ objectForKey:key] &&
        ![self.delegate updating] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (BOOL) removeSourceWithKey:(NSString *)key expectedRecord:(NSDictionary *)record {
    if ([key length] == 0 || record == nil || [self.delegate updating])
        return NO;
    @synchronized (database_) {
        Source *source([database_ sourceWithKey:key]);
        if ([source record] != record || [Sources_ objectForKey:key] != record)
            return NO;
        [Sources_ removeObjectForKey:key];
    }
    [self.delegate syncData];
    return YES;
}

- (UISwipeActionsConfiguration *) tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    Source *source([self sourceAtIndexPath:indexPath]);
    NSString *key([source key]);
    if ([key length] == 0 || [self.delegate updating])
        return nil;
    NSString *sourceKey([NSString stringWithString:key]);
    NSMutableArray *actions([NSMutableArray array]);
    NSDictionary *record([source record]);
    if (record != nil && record == [Sources_ objectForKey:sourceKey]) {
        UIContextualAction *remove([UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
            title:UCLocalize("REMOVE") handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
                completion([self removeSourceWithKey:sourceKey expectedRecord:record]);
            }]);
        [remove setImage:[UIImage cy_symbolNamed:@"trash"]];
        [actions addObject:remove];
    }
    UIContextualAction *refresh([UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:UCLocalize("REFRESH") handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
            completion([self.delegate requestUpdateForSourceKey:sourceKey]);
        }]);
    [refresh setImage:[UIImage cy_symbolNamed:@"arrow.clockwise"]];
    [refresh setBackgroundColor:CYModernAccentColor()];
    [actions addObject:refresh];
    UISwipeActionsConfiguration *configuration([UISwipeActionsConfiguration configurationWithActions:actions]);
    [configuration setPerformsFirstActionWithFullSwipe:NO];
    return configuration;
}

- (void) tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete)
        return;
    Source *source([self sourceAtIndexPath:indexPath]);
    [self removeSourceWithKey:[source key] expectedRecord:[source record]];
}

- (void) tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    [self updateButtonsForEditingStatusAnimated:YES];
}

- (void) complete {
    [self.delegate addTrivialSource:href_];
    href_ = nil;

    [self.delegate syncData];
}

- (void) _endConnection:(NSURLConnection *)connection {
    if (connection != validation_)
        return;
    [connection release];
    validation_ = nil;

    [self.delegate releaseNetworkActivityIndicator];
    [self.delegate removeProgressHUD:hud_];
    hud_ = nil;

    if (repositoryResponse_) {
        CYRootlessDiag(@"SOURCES", @"validation status=ok uri=%@ method=HEAD endpoint=Release", CYRootlessDiagnosticsText(href_));
        [self complete];
    } else {
        // Match Sileo's current behavior: a failed lightweight Release probe
        // is advisory. Some valid repositories reject HEAD or are temporarily
        // offline, so let the user add them and allow the serialized APT
        // refresh to produce the authoritative per-source result.
        NSString *reason(error_ != nil ? [error_ localizedDescription] : UCLocalize("NOT_REPOSITORY_EX"));
        NSString *sourceURL((NSString *) href_);
        NSString *message([NSString stringWithFormat:@"%@\n\n%@", reason, sourceURL != nil ? sourceURL : @""]);
        UIAlertView *alert = [[[UIAlertView alloc]
            initWithTitle:UCLocalize("NOT_REPOSITORY")
            message:message
            delegate:self
            cancelButtonTitle:UCLocalize("CANCEL")
            otherButtonTitles:UCLocalize("ADD_ANYWAY"), nil
        ] autorelease];
        [alert setContext:@"warning"];
        [alert setNumberOfRows:1];
        [alert show];
        CYRootlessDiag(@"SOURCES", @"validation status=advisory-failed uri=%@ addAnywayAvailable=1 error=%@",
            CYRootlessDiagnosticsText(href_), CYRootlessDiagnosticsText(reason));
    }
    error_ = nil;
}

- (void) connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response {
    NSInteger status([response statusCode]);
    repositoryResponse_ = status >= 200 && status < 400;
}

- (void) connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    lprintf("connection:\"%s\" didFailWithError:\"%s\"\n", [href_ UTF8String], [[error localizedDescription] UTF8String]);
    repositoryResponse_ = false;
    error_ = error;
    [self _endConnection:connection];
}

- (void) connectionDidFinishLoading:(NSURLConnection *)connection {
    [self _endConnection:connection];
}

- (NSURLConnection *) _requestHRef:(NSString *)href method:(NSString *)method {
    NSURL *url([NSURL URLWithString:href]);

    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:url
        cachePolicy:NSURLRequestUseProtocolCachePolicy
        timeoutInterval:10
    ];

    [request setHTTPMethod:method];

    if (Machine_ != NULL)
        [request setValue:[NSString stringWithUTF8String:Machine_] forHTTPHeaderField:@"X-Machine"];

    if (UniqueID_ != nil)
        [request setValue:UniqueID_ forHTTPHeaderField:@"X-Unique-ID"];

    if ([url isCydiaSecure]) {
        if (UniqueID_ != nil)
            [request setValue:UniqueID_ forHTTPHeaderField:@"X-Cydia-Id"];
    }

    return [[[NSURLConnection alloc] initWithRequest:request delegate:self] autorelease];
}

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"source"]) {
        switch (button) {
            case 1: {
                NSString *href = [[alert textField] text];
                href = VerifySource(href);
                if (href == nil)
                    break;
                href_ = href;
                repositoryResponse_ = false;
                error_ = nil;
                // Sileo validates one standard Release endpoint, then adds and
                // refreshes the repository. Avoid seven parallel legacy probes,
                // which could leave the old HUD waiting for the slowest server.
                validation_ = [[self _requestHRef:[href_ stringByAppendingString:@"Release"] method:@"HEAD"] retain];
                hud_ = [self.delegate addProgressHUD];
                [hud_ setText:UCLocalize("VERIFYING_URL")];
                [self.delegate retainNetworkActivityIndicator];
            } break;

            case 0:
            break;

            _nodefault
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"trivial"])
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    else if ([context isEqualToString:@"urlerror"])
        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    else if ([context isEqualToString:@"warning"]) {
        switch (button) {
            case 1:
                [self performSelector:@selector(complete) withObject:nil afterDelay:0];
            break;

            case 0:
            break;

            _nodefault
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    }
}

- (void) updateButtonsForEditingStatusAnimated:(BOOL)animated {
    BOOL editing([list_ isEditing]);

    if (editing)
        [[self navigationItem] setLeftBarButtonItem:CYModernBarButtonItem(@"plus", UCLocalize("ADD"),
            UIBarButtonItemStylePlain, self, @selector(addButtonClicked)) animated:animated];
    else if ([self.delegate updating])
        [[self navigationItem] setLeftBarButtonItem:CYModernBarButtonItem(@"xmark", UCLocalize("CANCEL"),
            UIBarButtonItemStyleDone, self, @selector(cancelButtonClicked)) animated:animated];
    else
        [[self navigationItem] setLeftBarButtonItem:CYModernBarButtonItem(@"arrow.clockwise", UCLocalize("REFRESH"),
            UIBarButtonItemStylePlain, self, @selector(refreshButtonClicked)) animated:animated];

    [[self navigationItem] setRightBarButtonItem:CYModernBarButtonItem(editing ? @"checkmark" : @"pencil",
        editing ? UCLocalize("DONE") : UCLocalize("EDIT"),
        editing ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain,
        self, @selector(editButtonClicked)) animated:animated];
}

- (void) loadView {
    list_ = [[[UITableView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame] style:CYModernGroupedTableStyle()] autorelease];
    [list_ setAutoresizingMask:UIViewAutoresizingFlexibleBoth];
    CYModernizeTableView(list_);
    UIView *topSpacing([[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 1.0f, 14.0f)] autorelease]);
    [topSpacing setBackgroundColor:[UIColor clearColor]];
    [list_ setTableHeaderView:topSpacing];
    [list_ setEstimatedRowHeight:70.0f];
    [(UITableView *) list_ setDataSource:self];
    [list_ setDelegate:self];
    refresh_ = [[[UIRefreshControl alloc] init] autorelease];
    [refresh_ setTintColor:[UIColor clearColor]];
    [refresh_ addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];
    [list_ setRefreshControl:refresh_];

    // The refresh bar owns its fluorescent palette and animation lifecycle.
    refreshBar_ = [[[CydiaSourceRefreshBar alloc] initWithFrame:CGRectZero] autorelease];
    [refreshBar_ setTranslatesAutoresizingMaskIntoConstraints:NO];
    [list_ addSubview:refreshBar_];
    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [[refreshBar_ topAnchor] constraintEqualToAnchor:[[list_ safeAreaLayoutGuide] topAnchor] constant:2.0f],
        [[refreshBar_ leadingAnchor] constraintEqualToAnchor:[[list_ frameLayoutGuide] leadingAnchor]],
        [[refreshBar_ trailingAnchor] constraintEqualToAnchor:[[list_ frameLayoutGuide] trailingAnchor]],
        [[refreshBar_ heightAnchor] constraintEqualToConstant:3.0f],
    nil]];

    [self setView:list_];
}

- (void) setSourceRefreshActive:(BOOL)active {
    sourceRefreshActive_ = active;
    [refreshBar_ setRefreshing:active];
}

- (void) sourceRefreshStateDidChange {
    BOOL active([self.delegate updating]);
    if (!active)
        [refresh_ endRefreshing];
    [self setSourceRefreshActive:active];
    [self updateButtonsForEditingStatusAnimated:YES];
}

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [list_ bringSubviewToFront:refreshBar_];
}

- (void) pullToRefresh {
    // Pull remains a shortcut; the shared top bar owns refresh feedback.
    [refresh_ endRefreshing];
    [self.delegate requestUpdate];
}

- (void) viewDidLoad {
    [super viewDidLoad];

    [[self navigationItem] setTitle:UCLocalize("SOURCES")];
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    [self updateButtonsForEditingStatusAnimated:NO];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Sources needs the actions, not a duplicate oversized title row.
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    [list_ setEditing:NO];
    [self sourceRefreshStateDidChange];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection != nil &&
        ![[previousTraitCollection preferredContentSizeCategory]
            isEqualToString:[[self traitCollection] preferredContentSizeCategory]])
        [list_ reloadData];
}

- (void) releaseSubviews {
    refresh_ = nil;
    refreshBar_ = nil;
    sourceRefreshActive_ = NO;
    list_ = nil;

    sources_ = nil;

    [super releaseSubviews];
}

- (id) initWithDatabase:(Database *)database {
    if ((self = [super init]) != nil) {
        database_ = database;
    } return self;
}

- (void) reloadData {
    [super reloadData];
    [self updateButtonsForEditingStatusAnimated:YES];

    NSArray *previousSources(sources_ == nil ? [NSArray array] : [NSArray arrayWithArray:sources_]);
    BOOL sameStructure(NO);

@synchronized (database_) {
    era_ = [database_ era];

    sources_ = [NSMutableArray arrayWithCapacity:16];
    [sources_ addObjectsFromArray:[database_ sources]];
    _trace();
    [sources_ sortUsingSelector:@selector(compareByName:)];
    _trace();

    int count([sources_ count]);
    offset_ = 0;
    for (int i = 0; i != count; i++) {
        if ([[sources_ objectAtIndex:i] record] == nil)
            break;
        offset_++;
    }

    sameStructure = [previousSources count] == [sources_ count];
    if (sameStructure) {
        for (NSUInteger index(0); index != [sources_ count]; ++index) {
            Source *before([previousSources objectAtIndex:index]);
            Source *after([sources_ objectAtIndex:index]);
            NSString *beforeKey([before key] ?: [before rooturi] ?: @"");
            NSString *afterKey([after key] ?: [after rooturi] ?: @"");
            if (![beforeKey isEqualToString:afterKey]) {
                sameStructure = NO;
                break;
            }
        }
    }
}

    // A normal refresh replaces Source model objects but usually does not
    // change the list structure. Rebind only visible cells in that case so
    // cached repository artwork remains on screen and all rows do not flash at
    // the same instant. Structural changes still reload once, without UIKit
    // transition animations and without jumping the scroll position.
    [UIView performWithoutAnimation:^{
        if (sameStructure) {
            for (NSIndexPath *path in [list_ indexPathsForVisibleRows]) {
                if ([path section] != 1 || [path row] >= (NSInteger) [sources_ count])
                    continue;
                SourceCell *cell((SourceCell *) [list_ cellForRowAtIndexPath:path]);
                [cell setSource:[sources_ objectAtIndex:[path row]]];
            }
        } else {
            CGPoint contentOffset([list_ contentOffset]);
            [list_ reloadData];
            [list_ layoutIfNeeded];
            [list_ setContentOffset:contentOffset animated:NO];
        }
        [list_ layoutIfNeeded];
    }];
    [self sourceRefreshStateDidChange];
}

- (void) showAddSourcePromptWithURL:(NSString *)url {
    UIAlertView *alert = [[[UIAlertView alloc]
        initWithTitle:UCLocalize("ENTER_APT_URL")
        message:nil
        delegate:self
        cancelButtonTitle:UCLocalize("CANCEL")
        otherButtonTitles:
            UCLocalize("ADD_SOURCE"),
        nil
    ] autorelease];

    [alert setContext:@"source"];

    [alert setNumberOfRows:1];
    [alert addTextFieldWithValue:([url length] != 0 ? url : @"https://") label:@""];

    NSObject<UITextInputTraits> *traits = [[alert textField] textInputTraits];
    [traits setAutocapitalizationType:UITextAutocapitalizationTypeNone];
    [traits setAutocorrectionType:UITextAutocorrectionTypeNo];
    [traits setKeyboardType:UIKeyboardTypeURL];
    // XXX: UIReturnKeyDone
    [traits setReturnKeyType:UIReturnKeyNext];

    [alert show];
}

- (void) showAddSourcePrompt {
    [self showAddSourcePromptWithURL:nil];
}

- (void) addButtonClicked {
    [self showAddSourcePrompt];
}

- (void) refreshButtonClicked {
    [self.delegate requestUpdate];
}

- (void) cancelButtonClicked {
    [self.delegate cancelUpdate];
    // Keep all three indicators in the running state until the APT worker has
    // really stopped. The shared completion callback then changes Cancel to
    // Refresh, ends pull-to-refresh and removes the top bar atomically.
    [[[self navigationItem] leftBarButtonItem] setEnabled:NO];
}

- (void) editButtonClicked {
    [list_ setEditing:![list_ isEditing] animated:YES];
    [self updateButtonsForEditingStatusAnimated:YES];
}

@end
/* }}} */

@interface Cydia : CyteApplication <
    ConfirmationControllerDelegate,
    DatabaseDelegate,
    CydiaDelegate
> {
    _H<CyteWindow> window_;
    _H<CydiaTabBarController> tabbar_;
    _H<CyteTabBarController> emulated_;
    _H<CydiaModernPrivacyConsentView> privacyConsent_;

    _H<NSMutableArray> essential_;
    _H<NSMutableArray> broken_;
    _H<UIViewController> essentialController_;

    Database *database_;

    _H<NSURL> starturl_;

    unsigned locked_;
    BOOL homePresentationActive_;

    bool loaded_;
    bool transactionReloadPending_;
    bool packageTransactionActive_;
    bool sourceRefreshPendingAfterTransaction_;
    _H<NSMutableSet> queuedRequestedIdentifiers_;
    _H<NSArray> queuedOperationsAwaitingReload_;
    _H<NSMutableArray> preparationErrors_;
}

- (void) loadData;
- (BOOL) beginPackageTransaction;
- (void) endPackageTransaction;
- (bool) performWithRequestedIdentifiers:(NSSet *)requestedIdentifiers;
- (void) recordRequestedPackage:(Package *)package;
- (void) showPrivacyConsentIfNeeded;
- (void) privacyConsentAccepted;
- (void) privacyConsentDeclined;

@end

@implementation Cydia

- (void) showPrivacyConsentIfNeeded {
    if (CYPrivacyConsentAccepted()) {
        CYRootlessDiag(@"PRIVACY", @"first-launch acknowledgement already stored version=%ld",
            (long) CYPrivacyConsentCurrentVersion_);
        return;
    }

    privacyConsent_ = [[[CydiaModernPrivacyConsentView alloc] initWithFrame:[window_ bounds]] autorelease];
    [privacyConsent_ setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [privacyConsent_ configureWithTarget:self
                            acceptAction:@selector(privacyConsentAccepted)
                           declineAction:@selector(privacyConsentDeclined)];
    [window_ addSubview:privacyConsent_];
    [window_ bringSubviewToFront:privacyConsent_];
    CYRootlessDiag(@"PRIVACY", @"first-launch acknowledgement presented version=%ld networkRefreshDeferred=1",
        (long) CYPrivacyConsentCurrentVersion_);
}

- (void) privacyConsentAccepted {
    if (!CYStorePrivacyConsent()) {
        [privacyConsent_ showPersistenceError:CYLocalize(@"Cydia could not save your choice. Please try again.")];
        CYRootlessDiag(@"PRIVACY", @"ERROR acknowledgement persistence failed version=%ld",
            (long) CYPrivacyConsentCurrentVersion_);
        return;
    }

    CYRootlessDiag(@"PRIVACY", @"acknowledgement accepted and stored locally version=%ld",
        (long) CYPrivacyConsentCurrentVersion_);
    CydiaModernPrivacyConsentView *view(privacyConsent_);
    [view setUserInteractionEnabled:NO];
    NSTimeInterval duration(UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.24);
    [UIView animateWithDuration:duration animations:^{
        [view setAlpha:0.0f];
    } completion:^(BOOL finished) {
        [view removeFromSuperview];
        privacyConsent_ = nil;
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification,
            [[tabbar_ selectedViewController] view]);
        // No repository request is started before the user accepts. Continue
        // the one normal launch refresh now that the first-run gate is gone.
        [self _loaded];
        [tabbar_ refreshHomeStatus];
        [self refreshIfPossible];
    }];
}

- (void) privacyConsentDeclined {
    // Declining intentionally stores nothing. A later launch asks again.
    CYRootlessDiag(@"PRIVACY", @"acknowledgement declined persistence=none action=suspend");
    [self suspendReturningToLastApp:YES];
}

- (void) setHomePresentationActive:(BOOL)active {
    homePresentationActive_ = active;
    [self setIdleTimerDisabled:locked_ != 0 || homePresentationActive_];
}

- (void) lockSuspend {
    if (locked_++ == 0) {
        if ($SBSSetInterceptsMenuButtonForever != NULL)
            (*$SBSSetInterceptsMenuButtonForever)(true);

        [self setIdleTimerDisabled:YES];
    }
}

- (void) unlockSuspend {
    if (--locked_ == 0) {
        [self setIdleTimerDisabled:homePresentationActive_];

        if ($SBSSetInterceptsMenuButtonForever != NULL)
            (*$SBSSetInterceptsMenuButtonForever)(false);
    }
}

- (void) beginUpdate {
    if (packageTransactionActive_) {
        sourceRefreshPendingAfterTransaction_ = true;
        CYRootlessDiag(@"REFRESH", @"queued reason=package-transaction-active aptSerialization=1 parallelRefresh=0");
        return;
    }
    [tabbar_ beginUpdate];
}

- (void) cancelUpdate {
    [tabbar_ cancelUpdate];
}

- (bool) requestUpdate {
    return [self requestUpdateForSourceKey:nil];
}

- (bool) requestUpdateForSourceKey:(NSString *)sourceKey {
    if (packageTransactionActive_) {
        UIAlertController *alert([UIAlertController alertControllerWithTitle:CYLocalize(@"Package Changes Open")
            message:CYLocalize(@"Finish or cancel the current package changes before refreshing Sources.")
            preferredStyle:UIAlertControllerStyleAlert]);
        [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"OK") style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *presenter([tabbar_ presentedViewController] ?: (UIViewController *) tabbar_);
        [presenter presentViewController:alert animated:YES completion:nil];
        CYRootlessDiag(@"REFRESH", @"deferred reason=package-transaction-active aptSerialization=1 parallelRefresh=0");
        return false;
    }
    if ([tabbar_ updating]) {
        CYRootlessDiag(@"REFRESH", @"manual ignored reason=refresh-already-active parallelRefresh=0");
        return false;
    }
    // Refresh the repositories the user actually configured. Availability of
    // the historical cydia.saurik.com host says nothing about those sources.
    CYRootlessDiag(@"AUTO_REFRESH", @"manual requested repositoryReachability=per-source duplicateGuard=updating");
    if (sourceKey != nil) {
        if ([sourceKey length] == 0 || [database_ sourceWithKey:sourceKey] == nil)
            return false;
        [tabbar_ beginUpdateForSourceKey:sourceKey];
    } else
        [self beginUpdate];
    return true;
}

- (BOOL) updating {
    return [tabbar_ updating];
}

- (BOOL) hasRepositoryVerificationResult {
    return [tabbar_ hasRepositoryVerificationResult];
}

- (BOOL) repositoriesVerified {
    return [tabbar_ repositoriesVerified];
}

- (void) performEssentialUpgrade {
    @synchronized (self) {
        if (![self beginPackageTransaction])
            return;
        for (Package *essential in (id) essential_) {
            [self recordRequestedPackage:essential];
            [essential install];
        }
        [self resolve];
        [self perform];
    }
}

- (void) essentialUpgradeActionClicked:(UIButton *)sender {
    NSInteger action([sender tag]);
    if (essentialController_ == nil || ![[essentialController_ view] isUserInteractionEnabled] || action < 0 || action > 2)
        return;
    if (action == 0) {
        Ignored_ = YES;
        [essentialController_ dismissViewControllerAnimated:YES completion:nil];
        essentialController_ = nil;
        return;
    }
    UIViewController *pending([[(UIViewController *)essentialController_ retain] autorelease]);
    [[pending view] setUserInteractionEnabled:NO];
    if (action == 1) [self performEssentialUpgrade];
    else [self distUpgrade];
    // The same navigation view now hosts Review, or still hosts the choices
    // after a deferred/failed preparation. Both must remain interactive.
    [[pending view] setUserInteractionEnabled:YES];
}

- (void) presentEssentialUpgradeSheet {
    if (essentialController_ != nil || [essential_ count] == 0 || [tabbar_ presentedViewController] != nil)
        return;

    int count([essential_ count]);
    NSString *title(count == 1 ? UCLocalize("ESSENTIAL_UPGRADE") :
        [NSString stringWithFormat:UCLocalize("ESSENTIAL_UPGRADES"), count]);

    CydiaModernEssentialView *view([[[CydiaModernEssentialView alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease]);
    [view configureWithTitle:title
                    message:CYLocalize(@"Update these essential packages to keep Cydia and your jailbreak working reliably.")
             essentialTitle:UCLocalize("UPGRADE_ESSENTIAL")
              completeTitle:CYLocalize(@"Upgrade All")
                ignoreTitle:CYLocalize(@"Not Now")
                     target:self
                     action:@selector(essentialUpgradeActionClicked:)];

    CydiaModernSheetController *page([[[CydiaModernSheetController alloc] init] autorelease]);
    [page setView:view];
    [[page navigationItem] setTitle:UCLocalize("ESSENTIAL_UPGRADE")];
    [[page navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    essentialController_ = [[[CydiaModernNavigationController alloc] initWithRootViewController:page] autorelease];
    CYModernizeNavigationController((UINavigationController *)(UIViewController *)essentialController_);
    [essentialController_ setModalPresentationCapturesStatusBarAppearance:YES];
    [essentialController_ setModalPresentationStyle:UIModalPresentationPageSheet];
    [essentialController_ setModalInPresentation:YES];
    [essentialController_ setPreferredContentSize:CGSizeMake(0.0f, 460.0f)];
    UISheetPresentationController *sheet([essentialController_ sheetPresentationController]);
    [sheet setDetents:@[[UISheetPresentationControllerDetent largeDetent]]];
    [sheet setSelectedDetentIdentifier:UISheetPresentationControllerDetentIdentifierLarge];
    [sheet setPrefersGrabberVisible:YES];
    [sheet setPreferredCornerRadius:28.0f];

    [tabbar_ presentViewController:essentialController_ animated:YES completion:nil];
}

- (void) _loaded {
    // Do not present repair/essential-upgrade UI behind the opaque first-run
    // decision. It is evaluated immediately after acceptance instead.
    if (privacyConsent_ != nil) {
        CYRootlessDiag(@"PRIVACY", @"startup prompts deferred reason=acknowledgement-pending");
        return;
    }

    if ([broken_ count] != 0) {
        int count = [broken_ count];

        UIAlertView *alert = [[[UIAlertView alloc]
            initWithTitle:(count == 1 ? UCLocalize("HALFINSTALLED_PACKAGE") : [NSString stringWithFormat:UCLocalize("HALFINSTALLED_PACKAGES"), count])
            message:UCLocalize("HALFINSTALLED_PACKAGE_EX")
            delegate:self
            cancelButtonTitle:[NSString stringWithFormat:UCLocalize("PARENTHETICAL"), UCLocalize("FORCIBLY_CLEAR"), UCLocalize("UNSAFE")]
            otherButtonTitles:
                UCLocalize("TEMPORARY_IGNORE"),
            nil
        ] autorelease];

        [alert setContext:@"fixhalf"];
        [alert setNumberOfRows:2];
        [alert show];
    } else if (!Ignored_ && [essential_ count] != 0) {
        [self presentEssentialUpgradeSheet];
    }
}

- (void) returnToCydia {
    // ProgressController dismisses immediately after this callback.  Delay a
    // final in-place package refresh until the transaction navigation has
    // fully left the hierarchy. This makes Install become Modify immediately,
    // without requiring a tab switch or reopening Search.
    [self performSelector:@selector(finishReturningToCydia) withObject:nil afterDelay:0.4];
}

- (void) finishReturningToCydia {
    if (transactionReloadPending_) {
        [self reloadDataWithInvocation:nil preservingVisibleController:YES];
        transactionReloadPending_ = false;
        CYRootlessDiag(@"TRANSACTION", @"final visible package state reloaded after modal dismissal");
    }
    [self _loaded];
    [self endPackageTransaction];
}

- (void) reloadSpringBoard {
    // Match Sileo's rootless completion path: flush package writes and invoke
    // uikittools' sbreload as a separate privileged process. Avoid the legacy
    // private SpringBoardServices objects and long sleeps while UIKit is
    // tearing down the transaction controller.
    sync();
    NSObject *delegate([database_ progressDelegate]);
    ProgressController *progress([delegate isKindOfClass:[ProgressController class]] ? (ProgressController *)delegate : nil);
    const char *cydo = "/var/jb/usr/libexec/cydia/cydo";
    char *const reloadArguments[] = {
        const_cast<char *>(cydo),
        const_cast<char *>("/var/jb/usr/bin/sbreload"),
        NULL
    };
    pid_t pid = -1;
    int result = posix_spawn(&pid, cydo, NULL, NULL, reloadArguments, environ);
    if (result == 0) {
        CYRootlessDiag(@"FINISH", @"execute respring child=%d command=/var/jb/usr/bin/sbreload", pid);
        [progress performSelectorInBackground:@selector(observeFinishChild:) withObject:@(pid)];
        return;
    }

    // uikittools is a declared dependency, but retain a shell-free rootless
    // fallback for a damaged bootstrap rather than leaving the UI stuck.
    CYRootlessDiag(@"FINISH", @"WARN sbreload spawn=%d; fallback=launchctl-stop-backboardd", result);
    char *const fallbackArguments[] = {
        const_cast<char *>(cydo),
        const_cast<char *>("/var/jb/bin/launchctl"),
        const_cast<char *>("stop"),
        const_cast<char *>("com.apple.backboardd"),
        NULL
    };
    pid = -1;
    result = posix_spawn(&pid, cydo, NULL, NULL, fallbackArguments, environ);
    CYRootlessDiag(@"FINISH", result == 0 ? @"execute respring fallback child=%d" : @"ERROR respring fallback spawn=%d", result == 0 ? pid : result);
    if (result == 0)
        [progress performSelectorInBackground:@selector(observeFinishChild:) withObject:@(pid)];
    else
        [progress finishActionFailed];
}

- (void) _saveConfig {
    SaveConfig(database_);
}

// Navigation controller for the queuing badge.
- (UINavigationController *) queueNavigationController {
    NSArray *controllers = [tabbar_ viewControllers];
    return [controllers objectAtIndex:3];
}

- (void) _updateData {
    [self _saveConfig];
    [window_ unloadData];

    UINavigationController *navigation = [self queueNavigationController];

    id queuedelegate = nil;
    if ([[navigation viewControllers] count] > 0)
        queuedelegate = [[navigation viewControllers] objectAtIndex:0];

    [queuedelegate queueStatusDidChange];
    [[navigation tabBarItem] setBadgeValue:(Queuing_ ? UCLocalize("Q_D") : nil)];
}

- (void) _updateDataPreservingVisibleController {
    [self _saveConfig];

    // Repository refresh completion updates the visible screen in place.
    // Off-screen tabs still discard stale Package/Source objects, but the
    // selected controller is reloaded without tearing its view hierarchy down
    // and producing a full-screen flash.
    UIViewController *selected([tabbar_ selectedViewController]);
    for (UINavigationController *navigation in [tabbar_ viewControllers]) {
        if (navigation == selected)
            [navigation reloadData];
        else
            [navigation unloadData];
    }

    UINavigationController *navigation([self queueNavigationController]);
    id queuedelegate([[navigation viewControllers] count] == 0 ? nil : [[navigation viewControllers] objectAtIndex:0]);
    [queuedelegate queueStatusDidChange];
    [[navigation tabBarItem] setBadgeValue:(Queuing_ ? UCLocalize("Q_D") : nil)];
}

- (void) _refreshIfPossible {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    // After local startup, refresh once unless usable data was refreshed within
    // the last 15 minutes. Manual refresh remains available. loaded_ and the
    // tab controller's updating_ guard prevent duplicate refresh workers.
    if (loaded_) {
        CYRootlessDiag(@"AUTO_REFRESH", @"startup skipped reason=already-requested processScope=1");
        [self performSelectorOnMainThread:@selector(_loaded) withObject:nil waitUntilDone:NO];
    } else {
        loaded_ = true;
        // Throttle: skip the automatic launch refresh when the repositories
        // were already refreshed within the last 15 minutes, so a quick re-open
        // stays clean and static. The Refresh button and pull-to-refresh always
        // work; a missing or older timestamp still refreshes.
        NSDictionary *state([NSDictionary dictionaryWithContentsOfFile:CacheState_]);
        id last([state objectForKey:@"LastUpdate"]);
        NSTimeInterval age([last isKindOfClass:[NSDate class]] ? -[(NSDate *) last timeIntervalSinceNow] : -1.0);
        if ([[state objectForKey:@"LastUpdateUsable"] boolValue] && age >= 0.0 && age < 900.0) {
            CYRootlessDiag(@"AUTO_REFRESH", @"startup skipped reason=recent-refresh ageSeconds=%.0f throttleSeconds=900", age);
            [self performSelectorOnMainThread:@selector(_loaded) withObject:nil waitUntilDone:NO];
        } else {
            CYRootlessDiag(@"AUTO_REFRESH", @"startup requested trigger=fresh-process throttleSeconds=900 ageSeconds=%.0f", age);
            [self performSelectorOnMainThread:@selector(beginUpdate) withObject:nil waitUntilDone:NO];
        }
    }

    [pool release];
}

- (void) refreshIfPossible {
    [NSThread detachNewThreadSelector:@selector(_refreshIfPossible) toTarget:self withObject:nil];
}

- (void) reloadDataWithInvocation:(NSInvocation *)invocation {
    [self reloadDataWithInvocation:invocation preservingVisibleController:NO];
}

- (void) reloadDataWithInvocation:(NSInvocation *)invocation preservingVisibleController:(BOOL)preserveVisibleController {
_profile(reloadDataWithInvocation)
@synchronized (self) {
    // Like Sileo's repoRefresh(), preserve the user's explicit package queue
    // across every APT model rebuild. Source add/delete/refresh replaces all
    // Package objects, so old in-memory marks alone are not sufficient.
    BOOL hadQueuedOperations(Queuing_ && [queuedRequestedIdentifiers_ count] != 0);
    NSArray *queuedOperations(hadQueuedOperations ?
        [(queuedOperationsAwaitingReload_ != nil ? (NSArray *) queuedOperationsAwaitingReload_ :
            [database_ transactionOperationsForRequestedIdentifiers:queuedRequestedIdentifiers_]) retain] : nil);

    CydiaLoadingView *hud(loaded_ && !preserveVisibleController ? [self addProgressHUD] : nil);
    if (hud != nil)
        [hud setText:UCLocalize("RELOADING_DATA")];

    [database_ yieldToSelector:@selector(reloadDataWithInvocation:) withObject:invocation];
    if (![database_ ready]) {
        // No APT objects survive a failed reload. Keep explicit intent for a
        // later retry without dereferencing or clearing an unavailable cache.
        queuedOperationsAwaitingReload_ = queuedOperations;
        [queuedOperations release];
        [essential_ removeAllObjects];
        [broken_ removeAllObjects];
        if (hud != nil)
            [self removeProgressHUD:hud];
        CYRootlessDiag(@"DATABASE", @"UI reload stopped reason=model-unavailable");
        return;
    }

    queuedOperationsAwaitingReload_ = nil;
    BOOL queueRestored(NO);
    if (hadQueuedOperations && [queuedOperations count] != 0) {
        queueRestored = [database_ restoreTransactionOperations:queuedOperations title:@"Package Queue"];
        if (queueRestored) {
            // An external package manager may already have satisfied every
            // requested operation while Sources were refreshing.
            NSArray *remaining([database_ transactionOperationsForRequestedIdentifiers:queuedRequestedIdentifiers_]);
            if ([remaining count] == 0)
                queueRestored = NO;
        }
    }
    [queuedOperations release];
    if (hadQueuedOperations && !queueRestored) {
        [database_ clear];
        [queuedRequestedIdentifiers_ removeAllObjects];
        CYRootlessDiag(@"TRANSACTION", @"queued operations cleared after model reload reason=unavailable-or-already-satisfied");
    } else if (queueRestored) {
        CYRootlessDiag(@"TRANSACTION", @"queued operations preserved across model reload explicit=%lu dependencyClosure=recomputed",
            (unsigned long) [queuedRequestedIdentifiers_ count]);
    }

    size_t changes(0);

    [essential_ removeAllObjects];
    [broken_ removeAllObjects];

    _profile(reloadDataWithInvocation$Essential)
    NSArray *packages([database_ packages]);
    for (Package *package in packages) {
        if ([package half])
            [broken_ addObject:package];
        if ([package upgradableAndEssential:YES] && ![package ignored]) {
            if ([package essential] && [package installed] != nil)
                [essential_ addObject:package];
            ++changes;
        }
    }
    _end

    UITabBarItem *changesItem = [[[tabbar_ viewControllers] objectAtIndex:2] tabBarItem];
    if (changes != 0) {
        _trace();
        NSString *badge([[NSNumber numberWithInt:changes] stringValue]);
        [changesItem setBadgeValue:badge];
        [changesItem setAnimatedBadge:([essential_ count] > 0)];
        [self setApplicationIconBadgeNumber:changes];
    } else {
        _trace();
        [changesItem setBadgeValue:nil];
        [changesItem setAnimatedBadge:NO];
        [self setApplicationIconBadgeNumber:0];
    }

    Queuing_ = queueRestored;
    if (preserveVisibleController)
        [self _updateDataPreservingVisibleController];
    else
        [self _updateData];

    if (hud != nil)
        [self removeProgressHUD:hud];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:CYRepositoryPackageLibraryDidReloadNotification object:nil];
    });
}
_end

    PrintTimes();
}

- (void) reloadDataAfterSourceRefresh {
    CYRootlessDiag(@"SOURCES", @"refresh completion reload mode=in-place fullScreenHUD=0 selectedTab=%lu",
        (unsigned long) [tabbar_ selectedIndex]);
    [self reloadDataWithInvocation:nil preservingVisibleController:YES];
    if ([database_ progressDelegate] == nil)
        [self _loaded];
}

- (void) updateData {
    [self _updateData];
}

- (void) updateDataAndLoad {
    [self _updateData];
    if ([database_ progressDelegate] == nil)
        [self _loaded];
}

- (void) update_ {
    [database_ update];
    [self performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:YES];
}

- (void) disemulate {
    if (emulated_ == nil)
        return;

    // The cached dashboard already advances its carousel. Transfer that exact
    // artwork position before replacing it, so cold launch cannot rewind it.
    UINavigationController *cachedNavigation([[emulated_ viewControllers] firstObject]);
    UINavigationController *liveNavigation([[tabbar_ viewControllers] firstObject]);
    UIView *cachedHome([[[cachedNavigation viewControllers] firstObject] view]);
    UIView *liveHome([[[liveNavigation viewControllers] firstObject] view]);
    if ([cachedHome isKindOfClass:[CydiaModernHomeView class]] && [liveHome isKindOfClass:[CydiaModernHomeView class]])
        [(CydiaModernHomeView *)liveHome continueFeaturedPositionFromView:(CydiaModernHomeView *)cachedHome];
    [window_ setRootViewController:tabbar_];
    emulated_ = nil;

    // A root-controller swap must never cover the first-launch decision.
    if (privacyConsent_ != nil)
        [window_ bringSubviewToFront:privacyConsent_];

    [window_ setUserInteractionEnabled:YES];
}

- (void) presentModalViewController:(UIViewController *)controller force:(BOOL)force {
    UINavigationController *navigation([[[CydiaModernNavigationController alloc] initWithRootViewController:controller] autorelease]);

    UIViewController *parent;
    if (emulated_ == nil)
        parent = tabbar_;
    else if (!force)
        parent = emulated_;
    else {
        [self disemulate];
        parent = tabbar_;
    }

    [navigation setModalPresentationStyle:UIModalPresentationPageSheet];
    UISheetPresentationController *sheet([navigation sheetPresentationController]);
    [sheet setDetents:@[[UISheetPresentationControllerDetent largeDetent]]];
    [sheet setSelectedDetentIdentifier:UISheetPresentationControllerDetentIdentifierLarge];
    [parent presentModalViewController:navigation animated:YES];
}

- (ProgressController *) invokeNewProgress:(NSInvocation *)invocation forController:(UINavigationController *)navigation withTitle:(NSString *)title {
    CYRootlessDiag(navigation != nil ? @"TRANSACTION" : @"SOURCES", @"progress screen requested title=%@", title);
    ProgressController *progress([[[ProgressController alloc] initWithDatabase:database_ delegate:self] autorelease]);
    [progress setTitle:title];

    if (navigation != nil) {
        UISheetPresentationController *sheet([navigation sheetPresentationController]);
        [sheet setDetents:@[[UISheetPresentationControllerDetent largeDetent]]];
        [sheet setSelectedDetentIdentifier:UISheetPresentationControllerDetentIdentifierLarge];
        // Retain the same sheet and settle its next page before APT/dpkg starts.
        // No horizontal push or second presentation during a package operation.
        CYReplacePackagePanel(navigation, progress);

        NSArray *context([NSArray arrayWithObjects:
            invocation != nil ? (id)invocation : (id)[NSNull null],
            title != nil ? title : @"",
            nil
        ]);
        [progress performSelector:@selector(invokeDeferred:)
                       withObject:context
                       afterDelay:0.35];
    } else {
        [self presentModalViewController:progress force:YES];

        // Sources follows the same screen-first ordering as
        // package transactions.  Present the original Updating Sources
        // ProgressController first, let UIKit/WebKit commit one display turn,
        // then begin the APT refresh.  This preserves the already-correct
        // source progress stream while avoiding any pre-progress pause.
        if ([title isEqualToString:@"UPDATING_SOURCES"]) {
            NSArray *context([NSArray arrayWithObjects:
                invocation != nil ? (id)invocation : (id)[NSNull null],
                title != nil ? title : @"",
                nil
            ]);
            [progress performSelector:@selector(invokeDeferred:)
                           withObject:context
                           afterDelay:0.35];
        } else {
            // Repair and other modal progress flows keep their existing
            // immediate behavior; only Sources is deliberately deferred.
            [progress invoke:invocation withTitle:title];
        }
    }

    return progress;
}

- (void) detachNewProgressSelector:(SEL)selector toTarget:(id)target forController:(UINavigationController *)navigation title:(NSString *)title {
    [self invokeNewProgress:[NSInvocation invocationWithSelector:selector forTarget:target] forController:navigation withTitle:title];
}

- (void) repairWithInvocation:(NSInvocation *)invocation {
    _trace();
    [self invokeNewProgress:invocation forController:nil withTitle:@"REPAIRING"];
    _trace();
}

- (void) repairWithSelector:(SEL)selector {
    [self performSelectorOnMainThread:@selector(repairWithInvocation:) withObject:[NSInvocation invocationWithSelector:selector forTarget:database_] waitUntilDone:YES];
}

- (void) reloadData {
    [self reloadDataWithInvocation:nil];
    if ([database_ progressDelegate] == nil)
        [self _loaded];
}

- (void) reloadDataAndRestartSourceRefresh {
    [self reloadDataWithInvocation:nil preservingVisibleController:YES];
    CYRootlessDiag(@"REFRESH", @"starting queued follow-up after local source model reload");
    [tabbar_ beginUpdate];
}

- (void) syncData {
    CYRootlessDiag(@"SOURCES", @"syncData begin managedCount=%lu", (unsigned long) [Sources_ count]);
    [self _saveConfig];

    if (packageTransactionActive_) {
        // Source files may be changed by an external cydia:// link while a
        // confirmation sheet is open. Persist now, but defer all APT model
        // work until the package transaction releases the cache.
        sourceRefreshPendingAfterTransaction_ = true;
        CYRootlessDiag(@"SOURCES", @"syncData deferred reason=package-transaction-active managedCount=%lu parallelRefresh=0", (unsigned long) [Sources_ count]);
        return;
    }

    // Add/Delete Source must be reflected by the Sources controller
    // immediately after the persistent source file changes.  The original
    // flow only rebuilt Database::sourceList_ after the network Refresh
    // finished, so the visible Sources screen kept its old snapshot until a
    // manual Refresh.  Rebuild the local APT/database model first (no network
    // access), which causes the currently visible SourcesController to reload
    // from /var/jb/etc/apt plus Cydia's managed source list.  Then preserve the
    // original background source Refresh so newly-added repositories still
    // fetch Release/Packages metadata normally.
    if ([tabbar_ updating]) {
        // Never mutate Database/APT cache while ListUpdate owns it. The tab
        // controller serializes one follow-up refresh, which begins with the
        // local model reload after the active update has completely stopped.
        CYRootlessDiag(@"SOURCES", @"syncData deferred local reload reason=active-refresh managedCount=%lu parallelRefresh=0", (unsigned long) [Sources_ count]);
        [tabbar_ queueUpdateAfterCurrent];
        return;
    }

    [self reloadDataWithInvocation:nil preservingVisibleController:YES];
    CYRootlessDiag(@"SOURCES", @"syncData local reload complete managedCount=%lu", (unsigned long) [Sources_ count]);
    [tabbar_ queueUpdateAfterCurrent];
}

- (void) addSource:(NSDictionary *) source {
    CYRootlessDiag(@"SOURCES", @"add requested uri=%@ distribution=%@",
        CYRootlessDiagnosticsText([source objectForKey:@"URI"]),
        [source objectForKey:@"Distribution"] ?: @"<nil>");
    CydiaAddSource(source);
}

- (void) addSource:(NSString *)href withDistribution:(NSString *)distribution andSections:(NSArray *)sections {
    CYRootlessDiag(@"SOURCES", @"add requested uri=%@ distribution=%@ sections=%lu",
        CYRootlessDiagnosticsText(href), distribution ?: @"<nil>", (unsigned long) [sections count]);
    CydiaAddSource(href, distribution, sections);
}

// XXX: this method should not return anything
- (BOOL) addTrivialSource:(NSString *)href {
    CYRootlessDiag(@"SOURCES", @"add trivial requested uri=%@", CYRootlessDiagnosticsText(href));
    CydiaAddSource(href, @"./");
    return YES;
}

- (void) resolve {
    pkgProblemResolver *resolver = [database_ resolver];

    resolver->InstallProtect();
    if (!resolver->Resolve(true))
        _error->Discard();
}

- (NSNumber *) prepareDatabaseForConfirmation {
    // A package action may resolve to no work (for example, clearing the last
    // queued item). Do not take an archive lock or open an empty Review page.
    if ([database_ ready] && [database_ cache]->BrokenCount() == 0 && [[database_ transactionPlan] count] == 0)
        return [NSNumber numberWithBool:NO];
    return [NSNumber numberWithBool:[database_ prepare]];
}

- (BOOL) beginPackageTransaction {
    if (packageTransactionActive_) {
        CYRootlessDiag(@"TRANSACTION", @"action=deferred reason=package-transaction-already-active queueMutated=0");
        return NO;
    }
    if (![database_ ready]) {
        UIAlertController *alert([UIAlertController alertControllerWithTitle:CYLocalize(@"Package Data Unavailable")
            message:CYLocalize(@"Refresh Sources before making package changes.")
            preferredStyle:UIAlertControllerStyleAlert]);
        [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"OK") style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *presenter([tabbar_ presentedViewController] ?: (UIViewController *) tabbar_);
        [presenter presentViewController:alert animated:YES completion:nil];
        return NO;
    }
    if (![tabbar_ updating])
        packageTransactionActive_ = true;
    if (packageTransactionActive_)
        return YES;

    // Repository refresh and package resolution both mutate the same APT
    // cache. Sileo and Zebra serialize those operations; doing the same here
    // avoids stale dependency plans and the old cancel/prepare race. Do not
    // cancel a healthy refresh or mutate the package queue underneath it.
    UIAlertController *alert([UIAlertController alertControllerWithTitle:CYLocalize(@"Sources Are Refreshing")
        message:CYLocalize(@"Please wait for the Sources indicator to finish, then try the package action again.")
        preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *presenter([tabbar_ presentedViewController] ?: (UIViewController *) tabbar_);
    [presenter presentViewController:alert animated:YES completion:nil];
    CYRootlessDiag(@"TRANSACTION", @"action=deferred reason=source-refresh-active aptSerialization=1 queueMutated=0");
    return NO;
}

- (void) endPackageTransaction {
    if (!packageTransactionActive_)
        return;
    packageTransactionActive_ = false;
    CYRootlessDiag(@"TRANSACTION", @"state=released aptSerialization=1");

    if (sourceRefreshPendingAfterTransaction_) {
        sourceRefreshPendingAfterTransaction_ = false;
        CYRootlessDiag(@"REFRESH", @"starting deferred refresh after package transaction");
        [self syncData];
    }
}

- (bool) perform {
    return [self performWithRequestedIdentifiers:nil];
}

- (bool) performWithRequestedIdentifiers:(NSSet *)requestedIdentifiers {
    if (requestedIdentifiers != nil)
        [queuedRequestedIdentifiers_ unionSet:requestedIdentifiers];
    NSSet *effectiveIdentifiers([queuedRequestedIdentifiers_ count] == 0 ? nil :
        [NSSet setWithSet:queuedRequestedIdentifiers_]);

    UINavigationController *existing(CYPackageActionsNavigation(tabbar_));
    if (existing == nil && [essentialController_ isKindOfClass:UINavigationController.class] &&
        [essentialController_ presentingViewController] != nil)
        existing = (UINavigationController *)(UIViewController *)essentialController_;
    // Keep the chosen action visible during resolution instead of flashing a
    // full-screen HUD between Modify and Review. Preserve the transaction lock.
    BOOL interactionEnabled([window_ isUserInteractionEnabled]);
    preparationErrors_ = [NSMutableArray array];
    [window_ setUserInteractionEnabled:NO];
    [self lockSuspend];
    NSNumber *prepared([self yieldToSelector:@selector(prepareDatabaseForConfirmation)]);
    [self unlockSuspend];
    [window_ setUserInteractionEnabled:interactionEnabled];
    NSString *preparationError([preparationErrors_ componentsJoinedByString:@"\n\n"]);
    preparationErrors_ = nil;
    BOOL hasOperations([[database_ transactionPlan] count] != 0);
    BOOL hasIssues([database_ ready] && [database_ cache]->BrokenCount() != 0);
    if (![prepared boolValue] || (!hasOperations && !hasIssues)) {
        // Preparation errors arrive before a ProgressController exists. Show
        // their reason here, and retain a badge only for a real plan or issue.
        Queuing_ = (hasOperations || hasIssues) && [effectiveIdentifiers count] != 0;
        if (!Queuing_) {
            [queuedRequestedIdentifiers_ removeAllObjects];
            queuedOperationsAwaitingReload_ = nil;
        }
        [self _updateDataPreservingVisibleController];
        [self endPackageTransaction];
        NSString *message([preparationError length] != 0 ? preparationError :
            (hasOperations || hasIssues ? CYLocalize(@"Review the details before trying again.") : CYLocalize(@"No changes selected")));
        UIAlertController *alert([UIAlertController alertControllerWithTitle:CYLocalize(@"Package Changes")
            message:message preferredStyle:UIAlertControllerStyleAlert]);
        [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"OK") style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *presenter(tabbar_);
        while ([presenter presentedViewController] != nil)
            presenter = [presenter presentedViewController];
        [presenter presentViewController:alert animated:YES completion:nil];
        return false;
    }

    ConfirmationController *page([[[ConfirmationController alloc]
        initWithDatabase:database_ requestedIdentifiers:effectiveIdentifiers] autorelease]);
    [page setDelegate:self];
    if (existing != nil && ![existing isBeingDismissed]) {
        [existing setModalInPresentation:YES];
        CYReplacePackagePanel(existing, page);
        if (existing == (UIViewController *)essentialController_) essentialController_ = nil;
        return true;
    }
    UINavigationController *confirm_([[[CydiaModernNavigationController alloc] initWithRootViewController:page] autorelease]);

    [confirm_ setModalPresentationStyle:UIModalPresentationPageSheet];
    [confirm_ setModalInPresentation:YES];
    UISheetPresentationController *sheet([confirm_ sheetPresentationController]);
    if (sheet != nil) {
        [sheet setDetents:@[[UISheetPresentationControllerDetent largeDetent]]];
        [sheet setSelectedDetentIdentifier:UISheetPresentationControllerDetentIdentifierLarge];
        [sheet setPreferredCornerRadius:32.0f];
        [sheet setPrefersGrabberVisible:YES];
        [sheet setPrefersScrollingExpandsWhenScrolledToEdge:NO];
    }
    [tabbar_ presentModalViewController:confirm_ animated:YES];

    return true;
}

- (void) recordRequestedPackage:(Package *)package {
    NSString *identifier([package id]);
    if (identifier != nil)
        [queuedRequestedIdentifiers_ addObject:identifier];
}

- (void) queue {
    @synchronized (self) {
        if (![self beginPackageTransaction])
            return;
        [self perform];
    }
}

- (void) clearPackage:(Package *)package {
    @synchronized (self) {
        if (![self beginPackageTransaction])
            return;
        NSString *identifier([package id]);
        if (identifier != nil)
            [queuedRequestedIdentifiers_ removeObject:identifier];
        [package clear];
        [self resolve];
        [self perform];
    }
}

- (void) installPackages:(NSArray *)packages {
    @synchronized (self) {
        if (![self beginPackageTransaction])
            return;
        for (Package *package in packages) {
            [self recordRequestedPackage:package];
            [package install];
        }
        [self resolve];
        [self perform];
    }
}

- (void) installPackage:(Package *)package {
    @synchronized (self) {
        if (![self beginPackageTransaction])
            return;
        [self recordRequestedPackage:package];
        [package install];
        [self resolve];
        [self perform];
    }
}

- (void) removePackage:(Package *)package {
    @synchronized (self) {
        if (![self beginPackageTransaction])
            return;
        [self recordRequestedPackage:package];
        [package remove];
        [self resolve];
        [self perform];
    }
}

- (void) distUpgrade {
    @synchronized (self) {
        if (![self beginPackageTransaction])
            return;
        NSMutableSet *requestedIdentifiers([NSMutableSet setWithCapacity:32]);
        for (Package *package in [database_ packages])
            if ([package upgradableAndEssential:YES] && ![package ignored])
                [requestedIdentifiers addObject:[package id]];
        if (![database_ upgrade]) {
            [self endPackageTransaction];
            return;
        }
        [self performWithRequestedIdentifiers:requestedIdentifiers];
    }
}

- (void) _uicache {
    _trace();
    system("/var/jb/usr/bin/uicache");
    _trace();
}

- (void) uicache {
    CydiaLoadingView *hud(packageTransactionActive_ ? nil : [self addProgressHUD]);
    [hud setText:UCLocalize("LOADING")];
    [self yieldToSelector:@selector(_uicache)];
    if (hud != nil) [self removeProgressHUD:hud];
}

- (void) reloadDataAfterPackageTransaction {
    // Keep Progress/Summary and its presentation attached while refreshing the
    // installed database. A full window unload tears down the visible sheet.
    [self reloadDataWithInvocation:nil preservingVisibleController:YES];
}

- (void) perform_ {
    NSSet *requestedIdentifiers;
    NSArray *requestedOperations;
    @synchronized (self) {
        requestedIdentifiers = [queuedRequestedIdentifiers_ count] == 0 ? nil :
            [[NSSet alloc] initWithSet:queuedRequestedIdentifiers_];
        requestedOperations = [[database_ transactionOperationsForRequestedIdentifiers:requestedIdentifiers] retain];
    }
    CYPackageTransactionResult result([database_ performWithRequestedIdentifiers:requestedIdentifiers]);
    @synchronized (self) {
        // A failed download, accepted cancellation or changed dependency plan
        // has not touched dpkg. Keep explicit intent for the existing queue
        // restoration path, which requires a new review and confirmation.
        Queuing_ = result == CYPackageTransactionNotStarted && [requestedOperations count] != 0;
        queuedOperationsAwaitingReload_ = Queuing_ ? requestedOperations : nil;
        if (!Queuing_)
            [queuedRequestedIdentifiers_ removeAllObjects];
    }
    [requestedOperations release];
    [requestedIdentifiers release];
    // Always refresh installed state in place. Once dpkg has been attempted,
    // never restore or replay the old queue: even a failed attempt may already
    // have installed or removed packages. A pending restart only affects their
    // runtime activation, so Details, Installed and Changes update immediately.
    transactionReloadPending_ = true;
    [self performSelectorOnMainThread:@selector(reloadDataAfterPackageTransaction) withObject:nil waitUntilDone:YES];
    if (Finish_ != 0 || RestartSubstrate_) {
        // A restart is pending: also mark the cache stale so the post-restart
        // cold launch rebuilds from the live dpkg database.
        if (NSMutableDictionary *cache = [NSMutableDictionary dictionaryWithContentsOfFile:CacheState_]) {
            [cache removeObjectForKey:@"LastUpdate"];
            [cache writeToFile:CacheState_ atomically:YES];
        }
    }
    if (UICache_) {
        UICache_ = false;
        [self performSelectorOnMainThread:@selector(uicache) withObject:nil waitUntilDone:YES];
    }
}

- (void) confirmWithNavigationController:(UINavigationController *)navigation {
    Queuing_ = false;
    [self lockSuspend];
    [self detachNewProgressSelector:@selector(perform_) toTarget:self forController:navigation title:@"RUNNING"];
    [self unlockSuspend];
}

- (void) cancelAndClear:(bool)clear {
    @synchronized (self) {
        if (clear) {
            [database_ clear];
            queuedOperationsAwaitingReload_ = nil;
            [queuedRequestedIdentifiers_ removeAllObjects];
            Queuing_ = false;
        } else {
            Queuing_ = true;
        }

        [self _updateData];
    }
    [self endPackageTransaction];
}

- (void) alertView:(UIAlertView *)alert clickedButtonAtIndex:(NSInteger)button {
    NSString *context([alert context]);

    if ([context isEqualToString:@"conffile"]) {
        FILE *input = [database_ input];
        if (button == [alert cancelButtonIndex])
            fprintf(input, "N\n");
        else if (button == [alert firstOtherButtonIndex])
            fprintf(input, "Y\n");
        fflush(input);

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    } else if ([context isEqualToString:@"fixhalf"]) {
        if (button == [alert cancelButtonIndex]) {
            @synchronized (self) {
                if (![self beginPackageTransaction]) {
                    [alert dismissWithClickedButtonIndex:-1 animated:YES];
                    return;
                }
                for (Package *broken in (id) broken_) {
                    [broken remove];
                    NSString *id(ShellEscape([broken id]));
                    system([[NSString stringWithFormat:@"/var/jb/usr/libexec/cydia/cydo /var/jb/bin/rm -f"
                        " /var/jb/var/lib/dpkg/info/%@.prerm"
                        " /var/jb/var/lib/dpkg/info/%@.postrm"
                        " /var/jb/var/lib/dpkg/info/%@.preinst"
                        " /var/jb/var/lib/dpkg/info/%@.postinst"
                        " /var/jb/var/lib/dpkg/info/%@.extrainst_"
                    "", id, id, id, id, id] UTF8String]);
                }

                [self resolve];
                [self perform];
            }
        } else if (button == [alert firstOtherButtonIndex]) {
            [broken_ removeAllObjects];
            [self _loaded];
        }

        [alert dismissWithClickedButtonIndex:-1 animated:YES];
    }
}

- (void) system:(NSString *)command {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    _trace();
    system([command UTF8String]);
    _trace();

    [pool release];
}

- (void) applicationWillSuspend {
    [database_ clean];
    [super applicationWillSuspend];
}

- (BOOL) isSafeToSuspend {
    if (locked_ != 0) {
#if !ForRelease
        NSLog(@"isSafeToSuspend: locked_ != 0");
#endif
        return false;
    }

    if ([tabbar_ modalViewController] != nil)
        return false;

    // Use external process status API internally.
    // This is probably a really bad idea.
    // XXX: what is the point of this? does this solve anything at all?
    uint64_t status = 0;
    int notify_token;
    if (notify_register_check("com.saurik.Cydia.status", &notify_token) == NOTIFY_STATUS_OK) {
        notify_get_state(notify_token, &status);
        notify_cancel(notify_token);
    }

    if (status != 0) {
#if !ForRelease
        NSLog(@"isSafeToSuspend: status != 0");
#endif
        return false;
    }

#if !ForRelease
    NSLog(@"isSafeToSuspend: -> true");
#endif
    return true;
}

- (void) suspendReturningToLastApp:(BOOL)returning {
    if ([self isSafeToSuspend])
        [super suspendReturningToLastApp:returning];
}

- (void) suspend {
    if ([self isSafeToSuspend])
        [super suspend];
}

- (void) applicationSuspend {
    if ([self isSafeToSuspend])
        [super applicationSuspend];
}

- (void) applicationSuspend:(GSEventRef)event {
    if ([self isSafeToSuspend])
        [super applicationSuspend:event];
}

- (void) _animateSuspension:(BOOL)arg0 duration:(double)arg1 startTime:(double)arg2 scale:(float)arg3 {
    if ([self isSafeToSuspend])
        [super _animateSuspension:arg0 duration:arg1 startTime:arg2 scale:arg3];
}

- (void) _setSuspended:(BOOL)value {
    if ([self isSafeToSuspend])
        [super _setSuspended:value];
}

- (CydiaLoadingView *) addProgressHUD {
    CydiaLoadingView *hud([[[CydiaLoadingView alloc] initWithFrame:CGRectZero] autorelease]);
    [hud setAutoresizingMask:UIViewAutoresizingFlexibleBoth];

    [window_ setUserInteractionEnabled:NO];

    UIViewController *target(tabbar_);
    if (UIViewController *modal = [target modalViewController])
        target = modal;

    [hud showInView:[target view]];

    [self lockSuspend];
    return hud;
}

- (void) removeProgressHUD:(CydiaLoadingView *)hud {
    [self unlockSuspend];
    [hud hide];
    [hud removeFromSuperview];
    [window_ setUserInteractionEnabled:YES];
}

- (CyteViewController *) pageForPackage:(NSString *)name withReferrer:(NSString *)referrer {
    return [[[CYPackageController alloc] initWithDatabase:database_ forPackage:name withReferrer:referrer] autorelease];
}

- (CyteViewController *) pageForURL:(NSURL *)url forExternal:(BOOL)external withReferrer:(NSString *)referrer {
    NSString *scheme([[url scheme] lowercaseString]);
    if ([[url absoluteString] length] <= [scheme length] + 3)
        return nil;

    NSString *externalSource(CYExternalSourceFromCydiaURL(url));
    if ([externalSource length] != 0) {
        SourcesController *sources([[[SourcesController alloc] initWithDatabase:database_] autorelease]);
        [sources setDelegate:self];
        [sources showAddSourcePromptWithURL:externalSource];
        CYRootlessDiag(@"SOURCES", @"external add route decoded uri=%@", CYRootlessDiagnosticsText(externalSource));
        return sources;
    }

    NSString *path([[url absoluteString] substringFromIndex:[scheme length] + 3]);
    NSArray *components([path componentsSeparatedByString:@"/"]);

    if ([scheme isEqualToString:@"apptapp"] && [components count] > 0 && [[components objectAtIndex:0] isEqualToString:@"package"]) {
        CyteViewController *controller([self pageForPackage:[components objectAtIndex:1] withReferrer:referrer]);
        if (controller != nil)
            [controller setDelegate:self];
        return controller;
    }

    if ([components count] < 1 || ![scheme isEqualToString:@"cydia"])
        return nil;

    NSString *base([components objectAtIndex:0]);

    CyteViewController *controller = nil;

    if ([base isEqualToString:@"url"]) {
        // This kind of URL can contain slashes in the argument, so we can't parse them below.
        NSString *destination = [[url absoluteString] substringFromIndex:([scheme length] + [@"://" length] + [base length] + [@"/" length])];
        controller = [[[CydiaWebViewController alloc] initWithURL:[NSURL URLWithString:destination]] autorelease];
    } else if (!external && [components count] == 1) {
        if ([base isEqualToString:@"sources"]) {
            controller = [[[SourcesController alloc] initWithDatabase:database_] autorelease];
        }

        if ([base isEqualToString:@"home"]) {
            controller = [[[HomeController alloc] initWithDatabase:database_] autorelease];
        }

        if ([base isEqualToString:@"sections"]) {
            controller = [[[SectionsController alloc] initWithDatabase:database_ source:nil] autorelease];
        }

        if ([base isEqualToString:@"search"]) {
            controller = [[[SearchController alloc] initWithDatabase:database_ query:nil] autorelease];
        }

        if ([base isEqualToString:@"changes"]) {
            controller = [[[ChangesController alloc] initWithDatabase:database_] autorelease];
        }

        if ([base isEqualToString:@"installed"]) {
            controller = [[[InstalledController alloc] initWithDatabase:database_] autorelease];
        }
    } else if ([components count] == 2) {
        NSString *argument = [[components objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

        if ([base isEqualToString:@"package"]) {
            controller = [self pageForPackage:argument withReferrer:referrer];
        }

        if (!external && [base isEqualToString:@"search"]) {
            controller = [[[SearchController alloc] initWithDatabase:database_ query:argument] autorelease];
        }

        if (!external && [base isEqualToString:@"sections"]) {
            if ([argument isEqualToString:@"all"] || [argument isEqualToString:@"*"])
                argument = nil;
            controller = [[[SectionController alloc] initWithDatabase:database_ source:nil section:argument] autorelease];
        }

        if ([base isEqualToString:@"sources"]) {
            if ([argument isEqualToString:@"add"]) {
                controller = [[[SourcesController alloc] initWithDatabase:database_] autorelease];
                [(SourcesController *)controller showAddSourcePrompt];
            } else {
                Source *source([database_ sourceWithKey:argument]);
                controller = [[[SectionsController alloc] initWithDatabase:database_ source:source] autorelease];
            }
        }

        if (!external && [base isEqualToString:@"launch"]) {
            [self launchApplicationWithIdentifier:argument suspended:NO];
            return nil;
        }
    } else if (!external && [components count] == 3) {
        NSString *arg1 = [[components objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *arg2 = [[components objectAtIndex:2] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

        if ([base isEqualToString:@"package"]) {
            if ([arg2 isEqualToString:@"settings"]) {
                controller = [[[PackageSettingsController alloc] initWithDatabase:database_ package:arg1] autorelease];
            } else if ([arg2 isEqualToString:@"files"]) {
                controller = [[[FileTable alloc] initWithDatabase:database_ forPackage:arg1] autorelease];
            }
        }

        if ([base isEqualToString:@"sections"]) {
            Source *source([arg1 isEqualToString:@"*"] ? nil : [database_ sourceWithKey:arg1]);
            NSString *section([arg2 isEqualToString:@"*"] ? nil : arg2);
            controller = [[[SectionController alloc] initWithDatabase:database_ source:source section:section] autorelease];
        }
    }

    [controller setDelegate:self];
    return controller;
}

- (BOOL) openCydiaURL:(NSURL *)url forExternal:(BOOL)external {
    CyteViewController *page([self pageForURL:url forExternal:external withReferrer:nil]);

    if (page != nil)
        [tabbar_ setUnselectedViewController:page];

    return page != nil;
}

- (void) applicationOpenURL:(NSURL *)url {
    [super applicationOpenURL:url];

    if (!loaded_)
        starturl_ = url;
    else
        [self openCydiaURL:url forExternal:YES];
}

- (void) applicationWillResignActive:(UIApplication *)application {
    // Stop refreshing if you get a phone call or lock the device.
    if ([tabbar_ updating])
        [tabbar_ cancelUpdate];

    if ([[self superclass] instancesRespondToSelector:@selector(applicationWillResignActive:)])
        [super applicationWillResignActive:application];
}

- (void) saveState {
    [[NSDictionary dictionaryWithObjectsAndKeys:
        @"InterfaceState", [tabbar_ navigationURLCollection],
        @"LastClosed", [NSDate date],
        @"InterfaceIndex", [NSNumber numberWithInt:[tabbar_ selectedIndex]],
    nil] writeToFile:SavedState_ atomically:YES];

    [self _saveConfig];
}

- (void) applicationWillTerminate:(UIApplication *)application {
    [self saveState];
}

- (void) applicationDidEnterBackground:(UIApplication *)application {
    if (kCFCoreFoundationVersionNumber < 1000 && [self isSafeToSuspend])
        return [self terminateWithSuccess];
    Backgrounded_ = [NSDate date];
    [self saveState];
}

- (void) applicationWillEnterForeground:(UIApplication *)application {
    if (Backgrounded_ == nil)
        return;

    NSTimeInterval interval([Backgrounded_ timeIntervalSinceNow]);

    if (interval <= -(30*60)) {
        [tabbar_ setSelectedIndex:0];
        [[[tabbar_ viewControllers] objectAtIndex:0] popToRootViewControllerAnimated:NO];
    }

    // Automatic source refresh is deliberately process-scoped. Returning from
    // the background keeps the current process and therefore does not refresh
    // again; the user can still start a manual Refresh at any time.
    CYRootlessDiag(@"AUTO_REFRESH", @"foreground skipped reason=process-already-running manualRefreshAvailable=1");

    // Home and its banner order are process-scoped. A normal return from the
    // background resumes the exact same carousel; only a fully new Cydia
    // process selects another random order.

    if ([database_ delocked])
        [self reloadData];
}

- (void) setConfigurationData:(NSString *)data {
    static RegEx conffile_r("'(.*)' '(.*)' ([01]) ([01])");

    if (!conffile_r(data)) {
        lprintf("E:invalid conffile\n");
        return;
    }

    NSString *ofile = conffile_r[1];
    //NSString *nfile = conffile_r[2];

    UIAlertView *alert = [[[UIAlertView alloc]
        initWithTitle:UCLocalize("CONFIGURATION_UPGRADE")
        message:[NSString stringWithFormat:@"%@\n\n%@", UCLocalize("CONFIGURATION_UPGRADE_EX"), ofile]
        delegate:self
        cancelButtonTitle:UCLocalize("KEEP_OLD_COPY")
        otherButtonTitles:
            UCLocalize("ACCEPT_NEW_COPY"),
            // XXX: UCLocalize("SEE_WHAT_CHANGED"),
        nil
    ] autorelease];

    [alert setContext:@"conffile"];
    [alert setNumberOfRows:2];
    [alert show];
}

- (void) applicationDidFinishLaunching:(id)unused {
    NSString *appVersion([[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"<unknown>");
    NSString *appBuild([[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"<unknown>");
    CYRootlessDiag(@"SESSION", @"begin format=2 appVersion=%@ appBuild=%@ ios=%@ uid=%d euid=%d",
        appVersion, appBuild, [[UIDevice currentDevice] systemVersion], getuid(), geteuid());
    CYRootlessDiag(@"APP", @"Cydia launch");
    CYApplyModernAppearance();
    [super applicationDidFinishLaunching:unused];

    Font12_ = [UIFont systemFontOfSize:12];
    Font12Bold_ = [UIFont boldSystemFontOfSize:12];
    Font14_ = [UIFont systemFontOfSize:14];
    Font18_ = [UIFont systemFontOfSize:18];
    Font18Bold_ = [UIFont boldSystemFontOfSize:18];
    Font22Bold_ = [UIFont boldSystemFontOfSize:22];

    essential_ = [NSMutableArray arrayWithCapacity:4];
    broken_ = [NSMutableArray arrayWithCapacity:4];
    queuedRequestedIdentifiers_ = [NSMutableSet setWithCapacity:16];

    window_ = [[[CyteWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    [window_ setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
    [window_ setTintColor:CYModernAccentColor()];

    [window_ setUserInteractionEnabled:NO];

    // Paint the complete cached Home immediately while the local APT model is
    // opening. The window remains hidden until this root view has completed
    // its first layout, so UIKit can never expose an empty black window frame.
    // It uses the same process-scoped banner order that the live Home
    // controller will retain.
    CFAbsoluteTime cachedHomeStarted(CFAbsoluteTimeGetCurrent());
    NSArray *processBanners(CYFeaturedProcessBannerRecords());
    NSUInteger launchBannerCount(MIN((NSUInteger) 6, [processBanners count]));
    NSMutableArray *launchBanners([NSMutableArray arrayWithCapacity:launchBannerCount]);
    for (NSUInteger index(0); index != launchBannerCount; ++index) {
        NSMutableDictionary *banner([[[processBanners objectAtIndex:index] mutableCopy] autorelease]);
        [banner setObject:@YES forKey:@"launchCacheOnly"];
        [launchBanners addObject:banner];
    }
    emulated_ = [[[CyteTabBarController alloc] init] autorelease];
    // The cached Home is already the real first screen, so its tab bar must be
    // real as well.  Construct the same five items as the live controller
    // before the window becomes visible.  A one-controller placeholder makes
    // UITabBarController omit the bar on the first frame and then visibly
    // insert it when the APT-backed controller replaces this preview.
    [emulated_ addViewControllers:nil,
        @"Cydia", @"home",
        UCLocalize("SOURCES"), @"sources",
        UCLocalize("CHANGES"), @"changes",
        UCLocalize("INSTALLED"), @"installed",
        UCLocalize("SEARCH"), @"search",
    nil];

    CydiaLoadingViewController *loading([[[CydiaLoadingViewController alloc]
        initWithFeaturedPackages:launchBanners] autorelease]);
    UINavigationController *navigation([[emulated_ viewControllers] objectAtIndex:0]);
    [navigation setViewControllers:[NSArray arrayWithObject:loading]];
    [emulated_ setSelectedIndex:0];
    [emulated_ setScrollTabBarHidden:NO animated:NO];

    [window_ setRootViewController:emulated_];
    [[emulated_ view] setNeedsLayout];
    [[emulated_ view] layoutIfNeeded];
    [window_ layoutIfNeeded];

    // Install the opaque first-run surface before the window is shown. This
    // keeps Home from flashing underneath it on a fresh installation.
    [self showPrivacyConsentIfNeeded];
    [window_ layoutIfNeeded];

    [window_ orderFront:self];
    [window_ makeKey:self];
    [window_ setHidden:NO];

    // Return to the run loop now.  This is the critical launch boundary: it
    // lets Core Animation commit the complete cached Home instead of leaving
    // SpringBoard's black launch surface visible while old APT setup runs.
    CYRootlessDiag(@"APP", @"first Home frame scheduled duration=%.3f launchBanners=%lu totalBanners=%lu launchTabs=%lu",
        CFAbsoluteTimeGetCurrent() - cachedHomeStarted,
        (unsigned long) launchBannerCount, (unsigned long) [processBanners count],
        (unsigned long) [[emulated_ viewControllers] count]);
    [self performSelector:@selector(completeDeferredLaunch) withObject:nil afterDelay:0.05];
}

- (void) completeDeferredLaunch {
    if (CYDeferredStartupWork_) {
        CYDeferredStartupWork_();
        CYDeferredStartupWork_ = std::function<void()>();
    }

    if ([WebPreferences respondsToSelector:@selector(setWebKitLinkTimeVersion:)])
        [WebPreferences setWebKitLinkTimeVersion:PACKED_VERSION(3453,0,0)];

    // Everything below may touch disk or initialize WebKit. Keep it behind the
    // already committed cached Home so none of this work can extend the launch
    // surface or replace it with a blank frame.
    NSURLCache *launchCache([NSURLCache sharedURLCache]);
    if ([launchCache memoryCapacity] < 32 * 1024 * 1024)
        [launchCache setMemoryCapacity:32 * 1024 * 1024];
    if ([launchCache diskCapacity] < 160 * 1024 * 1024)
        [launchCache setDiskCapacity:160 * 1024 * 1024];
    [CyteWebViewController _initialize];
    [NSURLProtocol registerClass:[CydiaURLProtocol class]];

    // this would disallow http{,s} URLs from accessing this data
    //[WebView registerURLSchemeAsLocal:@"cydia"];

    database_ = [Database sharedInstance];
    [database_ setDelegate:self];

    tabbar_ = [[[CydiaTabBarController alloc] initWithDatabase:database_] autorelease];

    [tabbar_ addViewControllers:nil,
        @"Cydia", @"home",
        UCLocalize("SOURCES"), @"sources",
        UCLocalize("CHANGES"), @"changes",
        UCLocalize("INSTALLED"), @"installed",
        UCLocalize("SEARCH"), @"search",
    nil];

    [tabbar_ setUpdateDelegate:self];

    [self performSelector:@selector(loadData) withObject:nil afterDelay:0];
_trace();
}

- (NSArray *) defaultStartPages {
    NSMutableArray *standard = [NSMutableArray array];
    [standard addObject:[NSArray arrayWithObject:@"cydia://home"]];
    [standard addObject:[NSArray arrayWithObject:@"cydia://sources"]];
    [standard addObject:[NSArray arrayWithObject:@"cydia://changes"]];
    [standard addObject:[NSArray arrayWithObject:@"cydia://installed"]];
    [standard addObject:[NSArray arrayWithObject:@"cydia://search"]];
    return standard;
}

- (void) loadData {
_trace();
    if ([emulated_ modalViewController] != nil)
        [emulated_ dismissModalViewControllerAnimated:YES];
    [window_ setUserInteractionEnabled:NO];

    [self reloadDataWithInvocation:nil];
    if (privacyConsent_ == nil)
        [self refreshIfPossible];
    else
        CYRootlessDiag(@"AUTO_REFRESH", @"startup deferred reason=privacy-acknowledgement-pending networkStarted=0");

    NSDictionary *state([NSDictionary dictionaryWithContentsOfFile:SavedState_]);

    int savedIndex = [[state objectForKey:@"InterfaceIndex"] intValue];
    NSArray *saved = [[[state objectForKey:@"InterfaceState"] mutableCopy] autorelease];
    int standardIndex = 0;
    NSArray *standard = [self defaultStartPages];

    BOOL valid = YES;

    if (saved == nil)
        valid = NO;

    NSDate *closed = [state objectForKey:@"LastClosed"];
    if (valid && closed != nil) {
        NSTimeInterval interval([closed timeIntervalSinceNow]);
        if (interval <= -(30*60))
            valid = NO;
    }

    if (valid && [saved count] != [standard count])
        valid = NO;

    if (valid) {
        for (unsigned int i = 0; i < [standard count]; i++) {
            NSArray *std = [standard objectAtIndex:i], *sav = [saved objectAtIndex:i];
            // XXX: The "hasPrefix" sanity check here could be, in theory, fooled,
            //      but it's good enough for now.
            if ([sav count] == 0 || ![[sav objectAtIndex:0] hasPrefix:[std objectAtIndex:0]]) {
                valid = NO;
                break;
            }
        }
    }

    NSArray *items = nil;
    if (valid) {
        [tabbar_ setSelectedIndex:savedIndex];
        items = saved;
    } else {
        [tabbar_ setSelectedIndex:standardIndex];
        items = standard;
    }

    for (unsigned int tab = 0; tab < [[tabbar_ viewControllers] count]; tab++) {
        NSArray *stack = [items objectAtIndex:tab];
        UINavigationController *navigation = [[tabbar_ viewControllers] objectAtIndex:tab];
        NSMutableArray *current = [NSMutableArray array];

        for (unsigned int nav = 0; nav < [stack count]; nav++) {
            NSString *addr = [stack objectAtIndex:nav];
            NSURL *url = [NSURL URLWithString:addr];
            CyteViewController *page = [self pageForURL:url forExternal:NO withReferrer:nil];
            if (page != nil)
                [current addObject:page];
        }

        [navigation setViewControllers:current];
    }

    // Replace the cached launch dashboard only after every live navigation
    // stack is populated.  Both controllers already have the same five-item
    // tab bar, so the root swap cannot expose an empty intermediate frame.
    [self disemulate];

    // (Try to) show the startup URL.
    if (starturl_ != nil) {
        [self openCydiaURL:starturl_ forExternal:YES];
        starturl_ = nil;
    }
}

- (void) showActionSheet:(UIActionSheet *)sheet fromItem:(UIBarButtonItem *)item {
    if (!IsWildcat_) {
       [sheet addButtonWithTitle:UCLocalize("CANCEL")];
       [sheet setCancelButtonIndex:[sheet numberOfButtons] - 1];
    }

    if (item != nil && IsWildcat_) {
        [sheet showFromBarButtonItem:item animated:YES];
    } else {
        [sheet showInView:window_];
    }
}

- (void) addProgressEvent:(CydiaProgressEvent *)event forTask:(NSString *)task {
    if (preparationErrors_ != nil) {
        if ([[event type] isEqualToString:kCydiaProgressEventTypeError]) {
            NSString *message(CYRootlessDiagnosticsText(CYLocalize([event message] ?: @"")));
            if ([message length] != 0 && ![preparationErrors_ containsObject:message])
                [preparationErrors_ addObject:message];
        }
        CYRootlessDiag(@"PROGRESS", @"preparation event retainedForFeedback=1 type=%@ task=%@ message=%@",
            [event type] ?: @"<nil>", task ?: @"<nil>", CYRootlessDiagnosticsText([event message] ?: @""));
        return;
    }
    id<ProgressDelegate> progress([database_ progressDelegate]);
    if (progress == nil) {
        // Startup and Home-button Refresh already expose their live state in
        // Home. Do not create a transaction sheet only when a final warning
        // arrives: that used to mark the sheet complete before the warning was
        // appended, producing mixed "Refreshing / complete" commands.
        CYRootlessDiag(@"PROGRESS", @"background refresh event routedTo=home type=%@ task=%@ message=%@",
            [event type] ?: @"<nil>", task ?: @"<nil>",
            CYRootlessDiagnosticsText([event message] ?: @""));
        return;
    }
    [progress setTitle:task];
    [progress addProgressEvent:event];
}

- (void) addProgressEventForTask:(NSArray *)data {
    CydiaProgressEvent *event([data objectAtIndex:0]);
    NSString *task([data count] < 2 ? nil : [data objectAtIndex:1]);
    [self addProgressEvent:event forTask:task];
}

- (void) addProgressEventOnMainThread:(CydiaProgressEvent *)event forTask:(NSString *)task {
    [self performSelectorOnMainThread:@selector(addProgressEventForTask:) withObject:[NSArray arrayWithObjects:event, task, nil] waitUntilDone:YES];
}

@end

/*IMP alloc_;
id Alloc_(id self, SEL selector) {
    id object = alloc_(self, selector);
    lprintf("[%s]A-%p\n", self->isa->name, object);
    return object;
}*/

/*IMP dealloc_;
id Dealloc_(id self, SEL selector) {
    id object = dealloc_(self, selector);
    lprintf("[%s]D-%p\n", self->isa->name, object);
    return object;
}*/

static NSMutableDictionary *AutoreleaseDeepMutableCopyOfDictionary(CFTypeRef type) {
    if (type == NULL)
        return nil;
    if (CFGetTypeID(type) != CFDictionaryGetTypeID()) {
        CFRelease(type);
        return nil;
    }
    CFTypeRef copy(CFPropertyListCreateDeepCopy(kCFAllocatorDefault, type, kCFPropertyListMutableContainers));
    CFRelease(type);
    return [(NSMutableDictionary *) copy autorelease];
}

int main_copy();
int main_file();
int main_gpgv();
int main_rred(int, char *argv[]);

#ifndef __arm__
#define main_gzip main_store
#else
int main_gzip(int, char *argv[]);
#endif

int main_store(int, char *argv[]);

int main_http(int, const char *argv[]);

int main(int argc, char *argv[]) {
    const char *argv0(argv[0]);
    if (const char *slash = strrchr(argv0, '/'))
        argv0 = slash + 1;
    if (false);
    else if (!strcmp(argv0, "copy"))
        return main_copy();
    else if (!strcmp(argv0, "file"))
        return main_file();
    else if (!strcmp(argv0, "gpgv"))
        return main_gpgv();
    else if (!strcmp(argv0, "rred"))
        return main_rred(argc, argv);
    // The apt64 store method selects the compressor from argv[0].  Route all
    // compression aliases through main_store on arm64 as well; modern clang
    // does not define __arm__ for arm64, so the legacy conditional otherwise
    // lets lzma/gzip/bzip2 fall through into the UIKit application entrypoint.
    else if (!strcmp(argv0, "bzip2"))
        return main_store(argc, argv);
    else if (!strcmp(argv0, "gzip"))
        return main_store(argc, argv);
    else if (!strcmp(argv0, "lzma"))
        return main_store(argc, argv);
    else if (!strcmp(argv0, "xz"))
        return main_store(argc, argv);
    else if (!strcmp(argv0, "zstd"))
        return main_store(argc, argv);
    else if (!strcmp(argv0, "lz4"))
        return main_store(argc, argv);
    else if (!strcmp(argv0, "store"))
        return main_store(argc, argv);
    else if (!strcmp(argv0, "http"))
        return main_http(argc, (const char **) argv);
    else if (!strcmp(argv0, "https"))
        return main_http(argc, (const char **) argv);
    else {}

    // Ensure we have a stdout and stderr
    int fd(open("/tmp/cydia.log", O_WRONLY | O_APPEND | O_CREAT, 0644));
    // Added this because stderr output ended up in metadata.cb0 somehow once
    // Perhaps we were spawned with stderr or stdout closed?
    //
    // Ensure we have a stdout and stderr
    if (fd != -1) {
        if (fcntl(STDOUT_FILENO, F_GETFD) == -1)
            (void) dup2(fd, STDOUT_FILENO);
        (void) dup2(fd, STDERR_FILENO);
        if (fd > STDERR_FILENO)
            close(fd);
    }

    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    // Start reading cached artwork while the remaining application setup runs.
    // This never waits for images or grants network access to the launch view.
    CYPrewarmFeaturedBannerArtwork(CYFeaturedProcessBannerRecords(), 3.0f);

    _trace();

    CyteInitialize([NSString stringWithFormat:@"Cydia/%@", Cydia_]);
    UpdateExternalStatus(0);

    SessionData_ = [NSMutableDictionary dictionaryWithCapacity:4];

    UI_ = CydiaURL([NSString stringWithFormat:@"ui/ios~%@/1.1", IsWildcat_ ? @"ipad" : @"iphone"]);
    PackageName = reinterpret_cast<CYString &(*)(Package *, SEL)>(method_getImplementation(class_getInstanceMethod([Package class], @selector(cyname))));

    /* Set Locale {{{ */
    Locale_ = CFLocaleCopyCurrent();
    Languages_ = [NSLocale preferredLanguages];

    std::string languages;
    const char *translation(NULL);

    // XXX: this isn't really a language, but this is compatible with older Cydia builds
    if (Locale_ != NULL)
        if (const char *language = [(NSString *) CFLocaleGetIdentifier(Locale_) UTF8String]) {
            RegEx pattern("([a-z][a-z])(?:-[A-Za-z]*)?(_[A-Z][A-Z])?");
            if (pattern(language)) {
                translation = strdup([pattern->*@"%1$@%2$@" UTF8String]);
                languages += translation;
                languages += ",";
            }
        }

    if (Languages_ != nil)
        for (NSString *locale : Languages_) {
            auto components([NSLocale componentsFromLocaleIdentifier:locale]);
            NSString *language([components objectForKey:(id)kCFLocaleLanguageCode]);
            if (NSString *script = [components objectForKey:(id)kCFLocaleScriptCode])
                language = [NSString stringWithFormat:@"%@-%@", language, script];
            languages += [language UTF8String];
            languages += ",";
        }

    languages += "en";
    NSLog(@"Setting Language: [%s] %s", translation, languages.c_str());
    /* }}} */
    /* Index Collation {{{ */
    if (Class $UILocalizedIndexedCollation = objc_getClass("UILocalizedIndexedCollation")) { @try {
        NSBundle *bundle([NSBundle bundleForClass:$UILocalizedIndexedCollation]);
        NSString *path([bundle pathForResource:@"UITableViewLocalizedSectionIndex" ofType:@"plist"]);
        //path = @"/System/Library/Frameworks/UIKit.framework/.lproj/UITableViewLocalizedSectionIndex.plist";
        NSDictionary *dictionary([NSDictionary dictionaryWithContentsOfFile:path]);
        _H<UILocalizedIndexedCollation> collation([[[$UILocalizedIndexedCollation alloc] initWithDictionary:dictionary] autorelease]);

        if (NSLocale **locale = MSHookIvarPointer<NSLocale *>(collation, "_locale"))
            CollationLocale_ = *locale;

        if (kCFCoreFoundationVersionNumber >= 800 && [[CollationLocale_ localeIdentifier] isEqualToString:@"zh@collation=stroke"]) {
            CollationThumbs_ = [NSArray arrayWithObjects:@"1",@"•",@"4",@"•",@"7",@"•",@"10",@"•",@"13",@"•",@"16",@"•",@"19",@"A",@"•",@"E",@"•",@"I",@"•",@"M",@"•",@"R",@"•",@"V",@"•",@"Z",@"#",nil];
            for (NSInteger offset : (NSInteger[]) {0,1,3,4,6,7,9,10,12,13,15,16,18,25,26,29,30,33,34,37,38,42,43,46,47,50,51})
                CollationOffset_.push_back(offset);
            CollationTitles_ = [NSArray arrayWithObjects:@"1 畫",@"2 畫",@"3 畫",@"4 畫",@"5 畫",@"6 畫",@"7 畫",@"8 畫",@"9 畫",@"10 畫",@"11 畫",@"12 畫",@"13 畫",@"14 畫",@"15 畫",@"16 畫",@"17 畫",@"18 畫",@"19 畫",@"20 畫",@"21 畫",@"22 畫",@"23 畫",@"24 畫",@"25 畫以上",@"A",@"B",@"C",@"D",@"E",@"F",@"G",@"H",@"I",@"J",@"K",@"L",@"M",@"N",@"O",@"P",@"Q",@"R",@"S",@"T",@"U",@"V",@"W",@"X",@"Y",@"Z",@"#",nil];
            CollationStarts_ = [NSArray arrayWithObjects:@"一",@"丁",@"丈",@"不",@"且",@"丞",@"串",@"並",@"亭",@"乘",@"乾",@"傀",@"亂",@"僎",@"僵",@"儐",@"償",@"叢",@"儳",@"嚴",@"儷",@"儻",@"囌",@"囑",@"廳",@"a",@"b",@"c",@"d",@"e",@"f",@"g",@"h",@"i",@"j",@"k",@"l",@"m",@"n",@"o",@"p",@"q",@"r",@"s",@"t",@"u",@"v",@"w",@"x",@"y",@"z",@"ʒ",nil];
        } else {

        CollationThumbs_ = [collation sectionIndexTitles];
        for (size_t index(0), end([CollationThumbs_ count]); index != end; ++index)
            CollationOffset_.push_back([collation sectionForSectionIndexTitleAtIndex:index]);

        CollationTitles_ = [collation sectionTitles];
        if (NSArray **starts = MSHookIvarPointer<NSArray *>(collation, "_sectionStartStrings"))
            CollationStarts_ = *starts;

        NSString **transform = MSHookIvarPointer<NSString *>(collation, "_transform");
        if (transform != NULL && *transform != nil) {
            /*if ([collation respondsToSelector:@selector(transformedCollationStringForString:)])
                CollationModify_ = [=](NSString *value) { return [collation transformedCollationStringForString:value]; };*/
            const UChar *uid(reinterpret_cast<const UChar *>([*transform cStringUsingEncoding:NSUnicodeStringEncoding]));
            UErrorCode code(U_ZERO_ERROR);
            CollationTransl_ = utrans_openU(uid, -1, UTRANS_FORWARD, NULL, 0, NULL, &code);
            if (!U_SUCCESS(code))
                NSLog(@"%s", u_errorName(code));
        }

        }
    } @catch (NSException *e) {
        NSLog(@"%@", e);
        goto hard;
    } } else hard: {
        CollationLocale_ = [[[NSLocale alloc] initWithLocaleIdentifier:@"en@collation=dictionary"] autorelease];

        CollationThumbs_ = [NSArray arrayWithObjects:@"A",@"B",@"C",@"D",@"E",@"F",@"G",@"H",@"I",@"J",@"K",@"L",@"M",@"N",@"O",@"P",@"Q",@"R",@"S",@"T",@"U",@"V",@"W",@"X",@"Y",@"Z",@"#",nil];
        for (NSInteger offset(0); offset != 28; ++offset)
            CollationOffset_.push_back(offset);

        CollationTitles_ = [NSArray arrayWithObjects:@"A",@"B",@"C",@"D",@"E",@"F",@"G",@"H",@"I",@"J",@"K",@"L",@"M",@"N",@"O",@"P",@"Q",@"R",@"S",@"T",@"U",@"V",@"W",@"X",@"Y",@"Z",@"#",nil];
        CollationStarts_ = [NSArray arrayWithObjects:@"a",@"b",@"c",@"d",@"e",@"f",@"g",@"h",@"i",@"j",@"k",@"l",@"m",@"n",@"o",@"p",@"q",@"r",@"s",@"t",@"u",@"v",@"w",@"x",@"y",@"z",@"ʒ",nil];
    }
    /* }}} */

    App_ = [[NSBundle mainBundle] bundlePath];
    Advanced_ = YES;

    Cache_ = [[NSString stringWithFormat:@"%@/Library/Caches/com.saurik.Cydia", @"/var/mobile"] retain];
    mkdir([Cache_ UTF8String], 0755);

    /*Method alloc = class_getClassMethod([NSObject class], @selector(alloc));
    alloc_ = alloc->method_imp;
    alloc->method_imp = (IMP) &Alloc_;*/

    /*Method dealloc = class_getClassMethod([NSObject class], @selector(dealloc));
    dealloc_ = dealloc->method_imp;
    dealloc->method_imp = (IMP) &Dealloc_;*/

    void *gestalt(dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_GLOBAL | RTLD_LAZY));
    $MGCopyAnswer = reinterpret_cast<CFStringRef (*)(CFStringRef)>(dlsym(gestalt, "MGCopyAnswer"));
    UniqueID_ = UniqueIdentifier([UIDevice currentDevice]);

    /* System Information {{{ */
    size_t size;

    int maxproc;
    size = sizeof(maxproc);
    if (sysctlbyname("kern.maxproc", &maxproc, &size, NULL, 0) == -1)
        perror("sysctlbyname(\"kern.maxproc\", ?)");
    else if (maxproc < 64) {
        maxproc = 64;
        if (sysctlbyname("kern.maxproc", NULL, NULL, &maxproc, sizeof(maxproc)) == -1)
            perror("sysctlbyname(\"kern.maxproc\", #)");
    }
    /* }}} */
    /* Load Database {{{ */
    SectionMap_ = [[[NSDictionary alloc] initWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"Sections" ofType:@"plist"]] autorelease];

    _trace();
    mkdir("/var/mobile/Library/Cydia", 0755);
    MetaFile_.Open("/var/mobile/Library/Cydia/metadata.cb0");
    _trace();

    Values_ = AutoreleaseDeepMutableCopyOfDictionary(CFPreferencesCopyAppValue(CFSTR("CydiaValues"), CFSTR("com.saurik.Cydia")));
    Sections_ = AutoreleaseDeepMutableCopyOfDictionary(CFPreferencesCopyAppValue(CFSTR("CydiaSections"), CFSTR("com.saurik.Cydia")));
    Sources_ = AutoreleaseDeepMutableCopyOfDictionary(CFPreferencesCopyAppValue(CFSTR("CydiaSources"), CFSTR("com.saurik.Cydia")));
    Version_ = [(NSNumber *) CFPreferencesCopyAppValue(CFSTR("CydiaVersion"), CFSTR("com.saurik.Cydia")) autorelease];

    _trace();
    NSDictionary *metadata([[[NSMutableDictionary alloc] initWithContentsOfFile:@"/var/jb/var/lib/cydia/metadata.plist"] autorelease]);

    if (Values_ == nil)
        Values_ = [metadata objectForKey:@"Values"];
    if (Values_ == nil)
        Values_ = [[[NSMutableDictionary alloc] initWithCapacity:4] autorelease];
    // Migrate away from the removed per-source Trust workflow.
    [Values_ removeObjectForKey:@"ExplicitlyTrustedRepositoryURIs"];

    if (Sections_ == nil)
        Sections_ = [metadata objectForKey:@"Sections"];
    if (Sections_ == nil)
        Sections_ = [[[NSMutableDictionary alloc] initWithCapacity:32] autorelease];

    if (Sources_ == nil)
        Sources_ = [metadata objectForKey:@"Sources"];
    if (Sources_ == nil)
        Sources_ = [[[NSMutableDictionary alloc] initWithCapacity:0] autorelease];

    // XXX: this wrong, but in a way that doesn't matter :/
    if (Version_ == nil)
        Version_ = [metadata objectForKey:@"Version"];
    if (Version_ == nil)
        Version_ = [NSNumber numberWithUnsignedInt:0];

    if (NSDictionary *packages = [metadata objectForKey:@"Packages"]) {
        bool fail(false);
        CFDictionaryApplyFunction((CFDictionaryRef) packages, &PackageImport, &fail);
        _trace();
        if (fail)
            NSLog(@"unable to import package preferences... from 2010? oh well :/");
    }

    if ([Version_ unsignedIntValue] == 0) {
        // Rootless public build: keep the bootstrap/Sileo APT source set as-is.
        // Do not auto-add legacy Cydia repositories on first launch.
        Version_ = [NSNumber numberWithUnsignedInt:1];

        if (NSMutableDictionary *cache = [NSMutableDictionary dictionaryWithContentsOfFile:CacheState_]) {
            [cache removeObjectForKey:@"LastUpdate"];
            [cache writeToFile:CacheState_ atomically:YES];
        }
    }

    _H<NSMutableArray> broken([NSMutableArray array]);
    for (NSString *key in (id) Sources_)
        if ([key rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"# "]].location != NSNotFound || ![([[Sources_ objectForKey:key] objectForKey:@"URI"] ?: @"/") hasSuffix:@"/"])
            [broken addObject:key];
    if ([broken count] != 0)
        for (NSString *key in (id) broken)
            [Sources_ removeObjectForKey:key];
    broken = nil;

    SaveConfig(nil);

    // UIKit must be allowed to display the cached Home before any root helper,
    // firmware maintenance or APT initialization can block the main thread.
    // main's stack remains valid for UIApplicationMain's lifetime, so the
    // language data captured here is safe until this one-shot job runs.
    CYDeferredStartupWork_ = [&, translation] {
    CFAbsoluteTime deferredStarted(CFAbsoluteTimeGetCurrent());
    system("/var/jb/usr/libexec/cydia/cydo /var/jb/bin/rm -f /var/jb/var/lib/cydia/metadata.plist");
    /* }}} */

    if (kCFCoreFoundationVersionNumber > 1000)
        system("/var/jb/usr/libexec/cydia/cydo /var/jb/usr/libexec/cydia/setnsfpn /var/jb/var/lib");

    int version([[NSString stringWithContentsOfFile:@"/var/jb/var/lib/cydia/firmware.ver"] intValue]);

    // iOS 15+ rootless: firmware.sh maintains Cydia's virtual firmware
    // package metadata only. Do not couple that maintenance to the legacy
    // rootful /User compatibility symlink or attempt to repair the sealed rootfs.
    if (version != 6 || access("/var/jb/var/lib/cydia/firmware.pending", F_OK) == 0) {
        _trace();
        system("/var/jb/usr/libexec/cydia/cydo /var/jb/usr/libexec/cydia/firmware.sh");
        _trace();
    }

    if (access("/tmp/cydia.chk", F_OK) == 0) {
        if (unlink([Cache("pkgcache.bin") UTF8String]) == -1)
            _assert(errno == ENOENT);
        if (unlink([Cache("srcpkgcache.bin") UTF8String]) == -1)
            _assert(errno == ENOENT);
    }

    // A persistent marker distinguishes a process that disappeared while
    // dpkg was active from a normal application close.  Rebuild only APT's
    // generated binary caches; signed repository indexes and downloaded
    // archives remain intact.  This makes the next queue reflect the live
    // dpkg database instead of reinstalling the half that already completed.
    NSString *transactionMarker(Cache("dpkg-transaction.incomplete"));
    if (access([transactionMarker UTF8String], F_OK) == 0) {
        unlink([Cache("pkgcache.bin") UTF8String]);
        unlink([Cache("srcpkgcache.bin") UTF8String]);
        if (unlink([transactionMarker UTF8String]) == -1 && errno != ENOENT)
            CYRootlessDiag(@"DPKG", @"level=WARN interrupted marker clear failed errno=%d", errno);
        CYRootlessDiag(@"DPKG", @"interrupted transaction detected cachesInvalidated=1");
    }

    // Older rootless builds published the same Cydia-managed source list twice:
    // once as cydia-added.list and once through a cydia.list symlink. Remove
    // only that exact legacy symlink so APT sees every managed repository once.
    const char *cleanupCydo = "/var/jb/usr/libexec/cydia/cydo";
    char *const cleanupArguments[] = {
        const_cast<char *>(cleanupCydo),
        const_cast<char *>("--cleanup-legacy-source-link"),
        NULL
    };
    pid_t cleanupPid = -1;
    int cleanupSpawn(posix_spawn(&cleanupPid, cleanupCydo, NULL, NULL, cleanupArguments, environ));
    if (cleanupSpawn != 0) {
        CYRootlessDiag(@"SOURCES", @"level=ERROR legacy symlink cleanup phase=spawn status=%d", cleanupSpawn);
    } else {
        int cleanupStatus = 0;
        pid_t cleanupWaited;
        do {
            cleanupWaited = waitpid(cleanupPid, &cleanupStatus, 0);
        } while (cleanupWaited < 0 && errno == EINTR);

        if (cleanupWaited != cleanupPid) {
            CYRootlessDiag(@"SOURCES", @"level=ERROR legacy symlink cleanup phase=waitpid child=%d waited=%d errno=%d error=%s",
                cleanupPid, cleanupWaited, errno, strerror(errno));
        } else if (!WIFEXITED(cleanupStatus) || WEXITSTATUS(cleanupStatus) != 0) {
            CYRootlessDiag(@"SOURCES", @"level=ERROR legacy symlink cleanup phase=child-exit child=%d rawStatus=%d exited=%d exitCode=%d signaled=%d signal=%d",
                cleanupPid, cleanupStatus, WIFEXITED(cleanupStatus), WIFEXITED(cleanupStatus) ? WEXITSTATUS(cleanupStatus) : -1,
                WIFSIGNALED(cleanupStatus), WIFSIGNALED(cleanupStatus) ? WTERMSIG(cleanupStatus) : 0);
        } else {
            CYRootlessDiag(@"SOURCES", @"legacy symlink cleanup status=ok child=%d", cleanupPid);
        }
    }

    /* APT Initialization {{{ */
    _assert(pkgInitConfig(*_config));

    // Rootless iOS 15+: Cydia is rootless-only in this build.
    // Modern jailbreak repositories can publish both rootful
    // (iphoneos-arm) and rootless (iphoneos-arm64) variants in one index,
    // while dpkg may also expose iphoneos-arm as a foreign compatibility
    // architecture. Historical Cydia then sees both variants as separate
    // package objects and may choose the rootful/older candidate.
    //
    // Force APT's native architecture and configured architecture list to
    // the public rootless package architecture. Architecture: all remains
    // implicitly valid in APT.
    _config->Set("APT::Architecture", "iphoneos-arm64");
    _config->Clear("APT::Architectures");
    _config->Set("APT::Architectures", "iphoneos-arm64");

    _assert(pkgInitSystem(*_config, _system));

    const Configuration::Item *arch = _config->Tree("APT::Architecture");
    NSLog(@"Common Arch: %s\n", arch->Value.c_str());
    common_arch = arch->Value.c_str();
    NSLog(@"Cydia rootless APT::Architecture: %s", _config->Find("APT::Architecture").c_str());
    NSLog(@"Cydia rootless APT::Architectures: %s", _config->Find("APT::Architectures").c_str());
    // Current jailbreak package managers accept the mixed repository formats
    // still present in the ecosystem without a per-source Trust ceremony.
    // Keep GPG verification when a repository provides it, but allow unsigned,
    // weakly signed and expired legacy metadata to be consumed directly. APT
    // still verifies every downloaded archive against the size and hashes in
    // the selected Packages record, and HTTPS downloads may not downgrade.
    _config->Set("Acquire::AllowInsecureRepositories", true);
    _config->Set("Acquire::AllowWeakRepositories", true);
    _config->Set("Acquire::AllowDowngradeToInsecureRepositories", true);
    _config->Set("Acquire::Check-Valid-Until", false);
    _config->Set("APT::Get::AllowUnauthenticated", true);
    CYRootlessDiag(@"SOURCE_COMPAT", @"startup approvalUI=0 allowInsecureMetadata=1 allowWeakMetadata=1 allowExpiredMetadata=1 packageHashAndSizeVerification=required httpsDowngrade=blocked");

    // Rootless iOS 15+: prefer the bootstrap's current APT
    // acquire-method binaries. Procursus installs modern APT methods under
    // /var/jb/usr/libexec/apt/methods; keep a small compatibility search list
    // for older rootless layouts, then fall back to Cydia's embedded methods.
    const char *requiredMethods[] = {"http", "https", "gpgv", "store", "copy", "file", "rred", NULL};
    const char *methodCandidates[] = {
        "/var/jb/usr/libexec/apt/methods",
        "/var/jb/usr/lib/apt/methods",
        "/var/jb/libexec/apt/methods",
        "/var/jb/lib/apt/methods",
        NULL
    };

    const char *systemMethods = NULL;
    for (size_t candidate = 0; methodCandidates[candidate] != NULL; ++candidate) {
        bool complete = true;
        for (size_t method = 0; requiredMethods[method] != NULL; ++method) {
            char executable[1024];
            snprintf(executable, sizeof(executable), "%s/%s", methodCandidates[candidate], requiredMethods[method]);
            if (access(executable, X_OK) != 0) {
                complete = false;
                break;
            }
        }
        if (complete) {
            systemMethods = methodCandidates[candidate];
            break;
        }
    }

    const char *methodsPath = systemMethods != NULL ? systemMethods : CYDIA_APPLICATION_PATH;
    _config->Set("Dir::Bin::Methods", methodsPath);
    NSLog(@"Cydia APT methods: %s", methodsPath);

    // FIX08: source metadata/Release files must stay on the bootstrap's modern
    // HTTPS method. Package transactions switch temporarily inside -perform.
    StandardHTTPSMethod_ = std::string(methodsPath) + "/https";
    _config->Set("Dir::Bin::Methods::https", StandardHTTPSMethod_);
    NSLog(@"Cydia APT source-metadata HTTPS method: %s", StandardHTTPSMethod_.c_str());
    CYRootlessDiag(@"APT", @"https-method=bootstrap-modern scope=source-metadata package-method=deferred values=not-logged verification=apt-gpg-hash-size");

    // FIX08 R4: advertise every Packages representation used by current
    // rootless repositories. The pinned APT defaults point at rootful tools,
    // so a repository publishing only Packages.xz or Packages.zst could be
    // visible to Sileo but empty in Cydia. All paths below are generic
    // bootstrap paths and the final uncompressed fallback remains enabled.
    _config->Set("Acquire::CompressionTypes::zst", "zstd");
    _config->Set("Acquire::CompressionTypes::xz", "xz");
    _config->Set("Acquire::CompressionTypes::bz2", "bzip2");
    _config->Set("Acquire::CompressionTypes::gz", "gzip");
    _config->Set("Acquire::CompressionTypes::lzma", "lzma");
    _config->Set("Acquire::CompressionTypes::lz4", "lz4");
    _config->Set("Acquire::CompressionTypes::Order", "zst,xz,bz2,gz,lzma,lz4");
    _config->Set("Dir::Bin::zstd", "/var/jb/usr/bin/zstd");
    _config->Set("Dir::Bin::xz", "/var/jb/usr/bin/xz");
    _config->Set("Dir::Bin::bzip2", "/var/jb/usr/bin/bzip2");
    _config->Set("Dir::Bin::gzip", "/var/jb/usr/bin/gzip");
    _config->Set("Dir::Bin::lzma", "/var/jb/usr/bin/xz");
    _config->Set("Dir::Bin::lz4", "/var/jb/usr/bin/lz4");
    _config->Set("APT::Compressor::lzma::Binary", "xz");
    _config->Clear("APT::Compressor::lzma::UncompressArg");
    _config->Set("APT::Compressor::lzma::UncompressArg::", "--format=lzma");
    _config->Set("APT::Compressor::lzma::UncompressArg::", "-d");
#if defined(CYDIA_TROLLSTORE_R2)
    CYRootlessDiag(@"APT", @"runtime-variant=%s application-method-root=%s bridge-only=1",
        CYDIA_RUNTIME_VARIANT, CYDIA_APPLICATION_PATH);
#endif
    CYRootlessDiag(@"APT", @"compressed-index-fallback order=zst,xz,bz2,gz,lzma,lz4,uncompressed tools=rootless-bootstrap repo-hardcode=0");

    // Rootless iOS 15+: APT's gpgv verifier historically defaults
    // to /usr/bin/gpgv (or searches PATH).  On a rootless bootstrap the real
    // verifier is under /var/jb.  Set both the process PATH inherited by
    // acquire methods and APT's explicit gpg binary path.
    const char *rootlessPath = "/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin";
    setenv("PATH", rootlessPath, 1);
    if (access("/var/jb/usr/bin/gpgv", X_OK) == 0)
        _config->Set("Dir::Bin::gpg", "/var/jb/usr/bin/gpgv");
    else if (access("/var/jb/bin/gpgv", X_OK) == 0)
        _config->Set("Dir::Bin::gpg", "/var/jb/bin/gpgv");

    // Keep the old embedded gpgv fallback rootless-aware as well.
    if (access("/var/jb/usr/bin/apt-key", X_OK) == 0)
        _config->Set("Dir::Bin::apt-key", "/var/jb/usr/bin/apt-key");

    // SHA-1 remains classified as weak so APT reports it accurately, while the
    // compatibility policy above decides whether the repository is usable.
    _config->Set("APT::Hashes::SHA1::Weak", false);
    _config->Clear("APT::Key::Assert-Pubkey-Algo");

    _config->Set("pkgCacheGen::ForceEssential", "");

    if (translation != NULL)
        _config->Set("APT::Acquire::Translation", translation);
    _config->Set("Acquire::Languages", languages);

    // A dead repository must not hold the entire Sources state indefinitely.
    // Sileo and Zebra both bound each network request; use a conservative
    // timeout here for APT's HTTP and HTTPS methods and one retry for transient
    // mobile-network failures.
    _config->Set("Acquire::http::Timeout", 25);
    _config->Set("Acquire::https::Timeout", 25);
    _config->Set("Acquire::Retries", 1);

    int64_t usermem(0);
    size = sizeof(usermem);
    if (sysctlbyname("hw.usermem", &usermem, &size, NULL, 0) == -1)
        usermem = 0;
    _config->Set("Acquire::http::MaxParallel", usermem >= 384 * 1024 * 1024 ? 16 : 3);

    mkdir([Cache("archives") UTF8String], 0755);
    mkdir([Cache("archives/partial") UTF8String], 0755);
    _config->Set("Dir::Cache", [Cache_ UTF8String]);

    symlink("/var/jb/var/lib/apt/extended_states", [Cache("extended_states") UTF8String]);
    _config->Set("Dir::State", [Cache_ UTF8String]);

    mkdir([Cache("lists") UTF8String], 0755);
    mkdir([Cache("lists/partial") UTF8String], 0755);
    mkdir([Cache("periodic") UTF8String], 0755);
    _config->Set("Dir::State::Lists", [Cache("lists") UTF8String]);

    std::string logs("/var/mobile/Library/Logs/Cydia");
    mkdir(logs.c_str(), 0755);
    _config->Set("Dir::Log", logs);

    _config->Set("Dir::Bin::dpkg", "/var/jb/usr/libexec/cydia/cydo");
    CYRootlessDiag(@"APP", @"deferred runtime ready duration=%.3f", CFAbsoluteTimeGetCurrent() - deferredStarted);
    };
    /* }}} */
    /* Color Choices {{{ */
    space_ = CGColorSpaceCreateDeviceRGB();

    Blue_.Set(space_, 0.2, 0.2, 1.0, 1.0);
    Blueish_.Set(space_, 0x19/255.f, 0x32/255.f, 0x50/255.f, 1.0);
    Black_.Set(space_, 0.0, 0.0, 0.0, 1.0);
    Folder_.Set(space_, 0x8e/255.f, 0x8e/255.f, 0x93/255.f, 1.0);
    Off_.Set(space_, 0.9, 0.9, 0.9, 1.0);
    White_.Set(space_, 1.0, 1.0, 1.0, 1.0);
    Gray_.Set(space_, 0.4, 0.4, 0.4, 1.0);
    Green_.Set(space_, 0.0, 0.5, 0.0, 1.0);
    Purple_.Set(space_, 0.0, 0.0, 0.7, 1.0);
    Purplish_.Set(space_, 0.4, 0.4, 0.8, 1.0);

    InstallingColor_ = [UIColor colorWithRed:0.88f green:1.00f blue:0.88f alpha:1.00f];
    RemovingColor_ = [UIColor colorWithRed:1.00f green:0.88f blue:0.88f alpha:1.00f];
    /* }}}*/
    /* UIKit Configuration {{{ */
    // XXX: I have a feeling this was important
    //UIKeyboardDisableAutomaticAppearance();
    /* }}} */

    $SBSSetInterceptsMenuButtonForever = reinterpret_cast<void (*)(bool)>(dlsym(RTLD_DEFAULT, "SBSSetInterceptsMenuButtonForever"));
    $SBSCopyIconImagePNGDataForDisplayIdentifier = reinterpret_cast<NSData *(*)(NSString *)>(dlsym(RTLD_DEFAULT, "SBSCopyIconImagePNGDataForDisplayIdentifier"));

    const char *symbol(kCFCoreFoundationVersionNumber >= 800 ? "MGGetBoolAnswer" : "GSSystemHasCapability");
    BOOL (*GSSystemHasCapability)(CFStringRef) = reinterpret_cast<BOOL (*)(CFStringRef)>(dlsym(RTLD_DEFAULT, symbol));
    bool fast = GSSystemHasCapability != NULL && GSSystemHasCapability(CFSTR("armv7"));

    PulseInterval_ = fast ? 50000 : 500000;

    Colon_ = UCLocalize("COLON_DELIMITED");
    Elision_ = UCLocalize("ELISION");
    Error_ = UCLocalize("ERROR");
    Warning_ = UCLocalize("WARNING");

    _trace();
    int value(UIApplicationMain(argc, argv, @"Cydia", @"Cydia"));

    CGColorSpaceRelease(space_);
    CFRelease(Locale_);

    [pool release];
    return value;
}
