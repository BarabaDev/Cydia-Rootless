/*
 * Cydia iOS 15+ rootless compatibility shim.
 *
 * Original Cydia used SDURLCache because early iPhone OS releases did not
 * provide useful on-disk NSURLCache behaviour. Modern iOS does. Keep the
 * original SDURLCache class interface so CyteKit remains unchanged while
 * delegating storage to Foundation's NSURLCache implementation.
 */
#ifndef CYDIA_ROOTLESS_SDURLCACHE_H
#define CYDIA_ROOTLESS_SDURLCACHE_H

#import <Foundation/Foundation.h>

@interface SDURLCache : NSURLCache
- (void)createDiskCachePath;
@end

#endif
