#pragma once

#import <Foundation/Foundation.h>

static inline BOOL CYRepositoryHTTPSURLIsValid(NSURL *url) {
    if (url == nil || ![[[url scheme] lowercaseString] isEqualToString:@"https"] ||
        [[url host] length] == 0 || [url user] != nil || [url password] != nil)
        return NO;
    NSString *host([[url host] lowercaseString]);
    return ![host isEqualToString:@"localhost"] && ![host hasSuffix:@".localhost"];
}

// Public discovery may move to another HTTPS host. Account requests carry
// credentials in their body and must stay with the provider that received them.
static inline BOOL CYRepositoryRedirectIsAllowed(NSURLRequest *original, NSURLRequest *redirect) {
    NSURL *target([redirect URL]);
    if (!CYRepositoryHTTPSURLIsValid(target))
        return NO;
    if ([[original HTTPMethod] isEqualToString:@"GET"] && [original HTTPBody] == nil && [original HTTPBodyStream] == nil)
        return YES;
    NSURL *source([original URL]);
    return CYRepositoryHTTPSURLIsValid(source) &&
        [[[source host] lowercaseString] isEqualToString:[[target host] lowercaseString]] &&
        [([source port] ?: @443) isEqual:([target port] ?: @443)];
}
