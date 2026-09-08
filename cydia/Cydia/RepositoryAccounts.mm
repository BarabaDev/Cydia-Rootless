/* Cydia 1.1.24 Rootless - repository accounts compatible with Sileo's API. */

#include "Cydia/ModernLocalization.h"
#include "Cydia/RepositoryAccounts.h"
#include "Cydia/LibraryPresentation.h"
#include "Cydia/RepositoryRequestPolicy.h"
#include "CyteKit/ModernAppearance.h"

#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>

NSString *const CYRepositoryAccountNameKey = @"name";
NSString *const CYRepositoryAccountURLKey = @"url";
NSString *const CYRepositoryPurchasedIconDidLoadNotification = @"CYRepositoryPurchasedIconDidLoad";
NSString *const CYRepositoryPackageLibraryDidReloadNotification = @"CYRepositoryPackageLibraryDidReload";
NSString *const CYRepositoryPurchasedPackageKey = @"CYRepositoryPurchasedPackage";

static NSString *const CYRepositoryAccountErrorDomain = @"com.saurik.Cydia.RepositoryAccounts";

static NSString *const CYRepositoryAccountKeychainService = @"com.saurik.Cydia.RepositoryAccount.Token";
static NSString *const CYRepositoryAccountSecretKeychainService = @"com.saurik.Cydia.RepositoryAccount.PaymentSecret";

enum {
    CYRepositoryAccountErrorInvalidURL = 1,
    CYRepositoryAccountErrorNetwork,
    CYRepositoryAccountErrorResponse,
    CYRepositoryAccountErrorNotSignedIn,
    CYRepositoryAccountErrorNotPurchased,
    CYRepositoryAccountErrorKeychain,
};

static NSError *CYAccountError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:CYRepositoryAccountErrorDomain code:code userInfo:
        [NSDictionary dictionaryWithObject:(message ?: CYLocalize(@"Repository account error")) forKey:NSLocalizedDescriptionKey]];
}

static NSString *const CYRepositoryAccountInvalidateKey = @"CYRepositoryInvalidate";
static NSString *const CYRepositoryAccountRecoveryURLKey = @"CYRepositoryRecoveryURL";

static NSError *CYAccountErrorWithFlags(NSInteger code, NSString *message, BOOL invalidate, NSString *recoveryURL) {
    NSMutableDictionary *info([NSMutableDictionary dictionaryWithObject:(message ?: CYLocalize(@"Repository account error")) forKey:NSLocalizedDescriptionKey]);
    if (invalidate)
        [info setObject:[NSNumber numberWithBool:YES] forKey:CYRepositoryAccountInvalidateKey];
    if ([recoveryURL length] != 0)
        [info setObject:recoveryURL forKey:CYRepositoryAccountRecoveryURLKey];
    return [NSError errorWithDomain:CYRepositoryAccountErrorDomain code:code userInfo:info];
}

// A repository that reports the stored token as no longer valid asks Cydia to
// clear it, exactly as Sileo does, so the next attempt prompts a fresh sign-in.
static BOOL CYAccountErrorRequestsInvalidation(NSError *error) {
    return [[[error userInfo] objectForKey:CYRepositoryAccountInvalidateKey] boolValue];
}

static BOOL CYValidHTTPSURL(NSURL *url) {
    return CYRepositoryHTTPSURLIsValid(url);
}

static NSURL *CYEndpointURL(NSURL *base, NSString *component) {
    if (!CYValidHTTPSURL(base) || [component length] == 0)
        return nil;
    return [base URLByAppendingPathComponent:component isDirectory:NO];
}

@interface CYSecureRequestDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation CYSecureRequestDelegate

- (void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    // Authenticated redirects stay at the original provider. Public endpoint
    // discovery can follow HTTPS redirects without forwarding credentials.
    completionHandler(CYRepositoryRedirectIsAllowed([task originalRequest], request) ? request : nil);
}

@end

static NSData *CYRepositoryRequest(NSURL *url, NSString *method, NSDictionary *body, NSError **error) {
    if (!CYValidHTTPSURL(url)) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorInvalidURL, CYLocalize(@"The repository account endpoint must use HTTPS."));
        return nil;
    }

    NSMutableURLRequest *request([NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0]);
    [request setHTTPMethod:method ?: @"GET"];
    [request setValue:@"Cydia/1.1.24" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (body != nil) {
        NSError *jsonError(nil);
        NSData *json([NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError]);
        if (json == nil) {
            if (error != NULL)
                *error = jsonError;
            return nil;
        }
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setHTTPBody:json];
    }

    __block NSData *data(nil);
    __block NSURLResponse *response(nil);
    __block NSError *requestError(nil);
    dispatch_semaphore_t semaphore(dispatch_semaphore_create(0));

    // Enforce HTTPS across the entire redirect chain via CYSecureRequestDelegate
    // so an authenticated request can never be downgraded to cleartext HTTP.
    // These requests run only on background account workers, so the wait below
    // never blocks the main thread.
    NSURLSessionConfiguration *configuration([NSURLSessionConfiguration ephemeralSessionConfiguration]);
    [configuration setRequestCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
    [configuration setTimeoutIntervalForResource:30.0];
    [configuration setHTTPCookieStorage:nil];
    [configuration setURLCache:nil];
    NSURLSession *session([NSURLSession sessionWithConfiguration:configuration
        delegate:[[[CYSecureRequestDelegate alloc] init] autorelease] delegateQueue:nil]);
    NSURLSessionDataTask *task([session dataTaskWithRequest:request
        completionHandler:^(NSData *taskData, NSURLResponse *taskResponse, NSError *taskError) {
            data = [taskData retain];
            response = [taskResponse retain];
            requestError = [taskError retain];
            dispatch_semaphore_signal(semaphore);
        }]);
    [task resume];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];
    dispatch_release(semaphore);
    [data autorelease];
    [response autorelease];
    [requestError autorelease];
    if (requestError != nil || data == nil) {
        if (error != NULL)
            *error = requestError ?: CYAccountError(CYRepositoryAccountErrorNetwork, CYLocalize(@"The repository account could not be reached."));
        return nil;
    }
    if (![response isKindOfClass:[NSHTTPURLResponse class]] || !CYValidHTTPSURL([response URL])) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The repository account returned an insecure response."));
        return nil;
    }
    NSInteger status([(NSHTTPURLResponse *)response statusCode]);
    if (status < 200 || status >= 300) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, [NSString stringWithFormat:CYLocalize(@"The repository account returned HTTP %ld."), (long) status]);
        return nil;
    }
    if ([data length] > 2 * 1024 * 1024) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The repository account response is too large."));
        return nil;
    }
    return data;
}

static NSDictionary *CYRepositoryJSON(NSURL *url, NSString *method, NSDictionary *body, NSError **error) {
    NSData *data(CYRepositoryRequest(url, method, body, error));
    if (data == nil)
        return nil;
    NSError *jsonError(nil);
    id object([NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError]);
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (error != NULL)
            *error = jsonError ?: CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The repository account returned invalid JSON."));
        return nil;
    }
    NSDictionary *dictionary((NSDictionary *) object);
    id success([dictionary objectForKey:@"success"]);
    NSString *providerError([dictionary objectForKey:@"error"]);
    if (([success respondsToSelector:@selector(boolValue)] && ![success boolValue]) ||
        ([providerError isKindOfClass:[NSString class]] && [providerError length] != 0)) {
        if (error != NULL) {
            id invalidateValue([dictionary objectForKey:@"invalidate"]);
            BOOL invalidate([invalidateValue respondsToSelector:@selector(boolValue)] && [invalidateValue boolValue]);
            id recovery([dictionary objectForKey:@"recovery_url"]);
            NSString *recoveryURL([recovery isKindOfClass:[NSString class]] ? recovery : nil);
            *error = CYAccountErrorWithFlags(CYRepositoryAccountErrorResponse,
                ([providerError isKindOfClass:[NSString class]] && [providerError length] != 0) ?
                    providerError : CYLocalize(@"The repository account rejected the request."), invalidate, recoveryURL);
        }
        return nil;
    }
    return dictionary;
}

static NSMutableDictionary *CYRepositoryPaymentProviderCache(void) {
    static NSMutableDictionary *cache(nil);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSMutableDictionary alloc] init];
    });
    return cache;
}

static NSURL *CYRepositoryPaymentProvider(NSString *repositoryURL, NSError **error) {
    NSURL *repository([NSURL URLWithString:repositoryURL]);
    if (!CYValidHTTPSURL(repository)) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorInvalidURL, CYLocalize(@"Paid repositories must use HTTPS."));
        return nil;
    }
    NSString *cacheKey([[repository absoluteString]
        stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]]);
    @synchronized (CYRepositoryPaymentProviderCache()) {
        NSURL *cached([CYRepositoryPaymentProviderCache() objectForKey:cacheKey]);
        if (cached != nil)
            return cached;
    }

    NSData *data(CYRepositoryRequest(CYEndpointURL(repository, @"payment_endpoint"), @"GET", nil, error));
    if (data == nil)
        return nil;
    if ([data length] > 2048) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The payment endpoint is too large."));
        return nil;
    }
    NSString *text([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]);
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSURL *provider([NSURL URLWithString:text]);
    if (!CYValidHTTPSURL(provider)) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorInvalidURL, CYLocalize(@"The payment provider must use HTTPS."));
        return nil;
    }
    @synchronized (CYRepositoryPaymentProviderCache()) {
        [CYRepositoryPaymentProviderCache() setObject:provider forKey:cacheKey];
    }
    return provider;
}

static NSMutableDictionary *CYKeychainQuery(NSURL *provider, NSString *service) {
    return [NSMutableDictionary dictionaryWithObjectsAndKeys:
        (id) kSecClassGenericPassword, (id) kSecClass,
        service, (id) kSecAttrService,
        [provider absoluteString], (id) kSecAttrAccount,
    nil];
}

static BOOL CYValidRepositoryCredential(NSString *credential, NSUInteger maximumLength) {
    if (![credential isKindOfClass:[NSString class]])
        return NO;
    NSString *trimmed([credential stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    if ([trimmed length] == 0 || [trimmed length] > maximumLength)
        return NO;
    return [trimmed rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
}

// Serialize credential snapshots and mutations. Generations also distinguish a
// fresh sign-in that happens to return the same token as an older request.
static NSMutableDictionary *CYRepositoryCredentialGenerations(void) {
    static NSMutableDictionary *generations;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ generations = [[NSMutableDictionary alloc] init]; });
    return generations;
}

static NSUInteger CYRepositoryCredentialsGeneration_;

static NSUInteger CYRepositoryCredentialsGeneration(void) {
    @synchronized (CYRepositoryCredentialGenerations()) {
        return CYRepositoryCredentialsGeneration_;
    }
}

static void CYAdvanceRepositoryCredentialsGeneration(NSURL *provider) {
    // Called while holding the shared credential lock.
    [CYRepositoryCredentialGenerations() setObject:@(++CYRepositoryCredentialsGeneration_)
        forKey:[provider absoluteString]];
}

static NSString *CYRepositoryToken(NSURL *provider, NSUInteger *generation = NULL) {
    if (generation != NULL) *generation = 0;
    if (!CYValidHTTPSURL(provider))
        return nil;
    @synchronized (CYRepositoryCredentialGenerations()) {
        if (generation != NULL)
            *generation = [[CYRepositoryCredentialGenerations() objectForKey:[provider absoluteString]] unsignedIntegerValue];
        NSMutableDictionary *query(CYKeychainQuery(provider, CYRepositoryAccountKeychainService));
        [query setObject:(id) kCFBooleanTrue forKey:(id) kSecReturnData];
        [query setObject:(id) kSecMatchLimitOne forKey:(id) kSecMatchLimit];
        CFTypeRef result(NULL);
        OSStatus status(SecItemCopyMatching((CFDictionaryRef) query, &result));
        if (status != errSecSuccess || result == NULL)
            return nil;
        NSData *data([(NSData *) result autorelease]);
        NSString *token([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]);
        if (!CYValidRepositoryCredential(token, 4096))
            return nil;
        return [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
}

static NSString *CYRepositorySecret(NSURL *provider) {
    if (!CYValidHTTPSURL(provider))
        return nil;
    NSMutableDictionary *query(CYKeychainQuery(provider, CYRepositoryAccountSecretKeychainService));
    [query setObject:(id) kCFBooleanTrue forKey:(id) kSecReturnData];
    [query setObject:(id) kSecMatchLimitOne forKey:(id) kSecMatchLimit];
    CFTypeRef result(NULL);
    OSStatus status(SecItemCopyMatching((CFDictionaryRef) query, &result));
    if (status != errSecSuccess || result == NULL)
        return nil;
    NSData *data([(NSData *) result autorelease]);
    NSString *secret([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]);
    if (!CYValidRepositoryCredential(secret, 8192))
        return nil;
    return [secret stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL CYStoreRepositoryCredential(NSURL *provider, NSString *credential, NSString *service,
    CFTypeRef accessibility, NSUInteger maximumLength, NSError **error) {
    if (!CYValidHTTPSURL(provider) || !CYValidRepositoryCredential(credential, maximumLength)) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The repository returned an invalid account credential."));
        return NO;
    }
    @synchronized (CYRepositoryCredentialGenerations()) {
        NSString *normalized([credential stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        NSData *data([normalized dataUsingEncoding:NSUTF8StringEncoding]);
        NSMutableDictionary *query(CYKeychainQuery(provider, service));
        NSDictionary *update([NSDictionary dictionaryWithObjectsAndKeys:
            data, (id) kSecValueData,
            (id) accessibility, (id) kSecAttrAccessible,
        nil]);
        OSStatus status(SecItemUpdate((CFDictionaryRef) query, (CFDictionaryRef) update));
        if (status == errSecItemNotFound) {
            [query addEntriesFromDictionary:update];
            status = SecItemAdd((CFDictionaryRef) query, NULL);
        }
        if (status != errSecSuccess) {
            if (error != NULL)
                *error = CYAccountError(CYRepositoryAccountErrorKeychain, CYLocalize(@"The sign-in token could not be saved in Keychain."));
            return NO;
        }
        if ([service isEqualToString:CYRepositoryAccountKeychainService])
            CYAdvanceRepositoryCredentialsGeneration(provider);
        return YES;
    }
}

static BOOL CYStoreRepositoryToken(NSURL *provider, NSString *token, NSError **error) {
    return CYStoreRepositoryCredential(provider, token, CYRepositoryAccountKeychainService,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly, 4096, error);
}

static BOOL CYStoreRepositoryPaymentSecret(NSURL *provider, NSString *secret, NSError **error) {
    return CYStoreRepositoryCredential(provider, secret, CYRepositoryAccountSecretKeychainService,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, 8192, error);
}

static void CYDeleteRepositoryToken(NSURL *provider) {
    if (CYValidHTTPSURL(provider)) {
        @synchronized (CYRepositoryCredentialGenerations()) {
            OSStatus tokenStatus(SecItemDelete((CFDictionaryRef) CYKeychainQuery(provider, CYRepositoryAccountKeychainService)));
            OSStatus secretStatus(SecItemDelete((CFDictionaryRef) CYKeychainQuery(provider, CYRepositoryAccountSecretKeychainService)));
            if (tokenStatus == errSecSuccess || secretStatus == errSecSuccess)
                CYAdvanceRepositoryCredentialsGeneration(provider);
        }
    }
}

static BOOL CYDeleteRepositoryTokenIfUnchanged(NSURL *provider, NSString *token, NSUInteger generation) {
    @synchronized (CYRepositoryCredentialGenerations()) {
        NSUInteger currentGeneration;
        NSString *current(CYRepositoryToken(provider, &currentGeneration));
        if (generation != currentGeneration || ![current isEqualToString:token])
            return NO;
        CYDeleteRepositoryToken(provider);
        return YES;
    }
}

static NSDictionary *CYRepositoryUserInfo(NSURL *provider, NSString *token,
    NSString *deviceIdentifier, NSString *deviceModel, NSError **error) {
    if ([token length] == 0 || [deviceIdentifier length] == 0 || [deviceModel length] == 0) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorNotSignedIn, CYLocalize(@"Sign in through Manage Account first."));
        return nil;
    }
    return CYRepositoryJSON(CYEndpointURL(provider, @"user_info"), @"POST",
        [NSDictionary dictionaryWithObjectsAndKeys:
            token, @"token",
            deviceIdentifier, @"udid",
            deviceModel, @"device",
        nil], error);
}

static NSArray *CYPurchasedItems(NSDictionary *userInfo) {
    id items([userInfo objectForKey:@"items"]);
    if (![items isKindOfClass:[NSArray class]])
        return [NSArray array];
    NSMutableArray *valid([NSMutableArray array]);
    for (id item in (NSArray *) items)
        if ([item isKindOfClass:[NSString class]] && [item length] > 0 && [item length] <= 256)
            [valid addObject:item];
    return valid;
}

static NSURL *CYRepositoryPackageEndpoint(NSURL *provider, NSString *packageIdentifier, NSString *action) {
    NSURL *base(CYEndpointURL(provider, @"package"));
    if (base == nil || [packageIdentifier length] == 0)
        return nil;
    return [[base URLByAppendingPathComponent:packageIdentifier isDirectory:NO] URLByAppendingPathComponent:action isDirectory:NO];
}

NSString *CYRepositoryAuthorizedDownloadURL(
    NSString *repositoryURL,
    NSString *packageIdentifier,
    NSString *version,
    NSString *architecture,
    NSString *deviceIdentifier,
    NSString *deviceModel,
    NSError **error
) {
    if ([packageIdentifier length] == 0 || [deviceIdentifier length] == 0 || [deviceModel length] == 0) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"This device cannot authorize a paid package download."));
        return nil;
    }
    NSURL *provider(CYRepositoryPaymentProvider(repositoryURL, error));
    if (provider == nil)
        return nil;
    NSUInteger credentialGeneration;
    NSString *token(CYRepositoryToken(provider, &credentialGeneration));
    if ([token length] == 0) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorNotSignedIn, CYLocalize(@"Sign in through Manage Account first."));
        return nil;
    }

    NSURL *packageEndpoint([[CYEndpointURL(provider, @"package") URLByAppendingPathComponent:packageIdentifier isDirectory:NO] URLByAppendingPathComponent:@"authorize_download" isDirectory:NO]);
    NSDictionary *body([NSDictionary dictionaryWithObjectsAndKeys:
        token, @"token",
        deviceIdentifier, @"udid",
        deviceModel, @"device",
        version ?: @"", @"version",
        architecture ?: @"iphoneos-arm64", @"architecture",
        repositoryURL, @"repo",
    nil]);
    NSError *authorizeError(nil);
    NSDictionary *response(CYRepositoryJSON(packageEndpoint, @"POST", body, &authorizeError));
    if (response == nil) {
        if (CYAccountErrorRequestsInvalidation(authorizeError))
            CYDeleteRepositoryTokenIfUnchanged(provider, token, credentialGeneration);
        if (error != NULL)
            *error = authorizeError ?: CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The repository did not authorize this download."));
        return nil;
    }
    NSString *download([response objectForKey:@"url"]);
    NSURL *downloadURL([download isKindOfClass:[NSString class]] ? [NSURL URLWithString:download] : nil);
    if (!CYValidHTTPSURL(downloadURL)) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The repository returned an invalid download URL."));
        return nil;
    }
    return [downloadURL absoluteString];
}

NSDictionary *CYRepositoryPackageInfo(
    NSString *repositoryURL,
    NSString *packageIdentifier,
    NSString *deviceIdentifier,
    NSString *deviceModel,
    NSError **error
) {
    if ([packageIdentifier length] == 0) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"This package cannot be queried for purchase."));
        return nil;
    }
    NSURL *provider(CYRepositoryPaymentProvider(repositoryURL, error));
    if (provider == nil)
        return nil;
    NSUInteger credentialGeneration;
    NSString *token(CYRepositoryToken(provider, &credentialGeneration));
    if ([token length] == 0) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorNotSignedIn, CYLocalize(@"Sign in through Manage Account first."));
        return nil;
    }
    NSURL *endpoint(CYRepositoryPackageEndpoint(provider, packageIdentifier, @"info"));
    NSDictionary *body([NSDictionary dictionaryWithObjectsAndKeys:
        token, @"token",
        deviceIdentifier ?: @"", @"udid",
        deviceModel ?: @"", @"device",
    nil]);
    NSError *infoError(nil);
    NSDictionary *response(CYRepositoryJSON(endpoint, @"POST", body, &infoError));
    if (response == nil) {
        if (CYAccountErrorRequestsInvalidation(infoError))
            CYDeleteRepositoryTokenIfUnchanged(provider, token, credentialGeneration);
        if (error != NULL)
            *error = infoError;
        return nil;
    }
    id price([response objectForKey:@"price"]);
    id purchased([response objectForKey:@"purchased"]);
    id available([response objectForKey:@"available"]);
    return [NSDictionary dictionaryWithObjectsAndKeys:
        ([price isKindOfClass:[NSString class]] ? price : @""), @"price",
        [NSNumber numberWithBool:([purchased respondsToSelector:@selector(boolValue)] && [purchased boolValue])], @"purchased",
        [NSNumber numberWithBool:([available respondsToSelector:@selector(boolValue)] && [available boolValue])], @"available",
    nil];
}

NSInteger CYRepositoryPurchase(
    NSString *repositoryURL,
    NSString *packageIdentifier,
    NSString *deviceIdentifier,
    NSString *deviceModel,
    NSString **actionURL,
    NSError **error
) {
    if (actionURL != NULL)
        *actionURL = nil;
    if ([packageIdentifier length] == 0) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"This package cannot be purchased."));
        return CYRepositoryPurchaseFailed;
    }
    NSURL *provider(CYRepositoryPaymentProvider(repositoryURL, error));
    if (provider == nil)
        return CYRepositoryPurchaseFailed;
    NSUInteger credentialGeneration;
    NSString *token(CYRepositoryToken(provider, &credentialGeneration));
    if ([token length] == 0) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorNotSignedIn, CYLocalize(@"Sign in through Manage Account first."));
        return CYRepositoryPurchaseFailed;
    }

    // Require device authentication (Face ID / Touch ID / passcode) before a
    // purchase is sent. With no passcode configured the request proceeds
    // without the payment secret, matching Sileo's fallback.
    LAContext *context([[[LAContext alloc] init] autorelease]);
    NSError *policyError(nil);
    BOOL includePaymentSecret(NO);
    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&policyError]) {
        __block BOOL authenticated(NO);
        __block BOOL cancelled(NO);
        dispatch_semaphore_t gate(dispatch_semaphore_create(0));
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
            localizedReason:CYLocalize(@"Authenticate to complete your purchase")
            reply:^(BOOL success, NSError *evaluateError) {
                authenticated = success;
                NSInteger code([evaluateError code]);
                if (!success && (code == LAErrorUserCancel || code == LAErrorSystemCancel ||
                    code == LAErrorAppCancel || code == LAErrorUserFallback))
                    cancelled = YES;
                dispatch_semaphore_signal(gate);
            }];
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
        dispatch_release(gate);
        if (cancelled)
            return CYRepositoryPurchaseCancelled;
        if (!authenticated) {
            if (error != NULL)
                *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"Device authentication was required to complete the purchase."));
            return CYRepositoryPurchaseFailed;
        }
        includePaymentSecret = YES;
    } else if (![[policyError domain] isEqualToString:LAErrorDomain] || [policyError code] != LAErrorPasscodeNotSet) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"Device authentication is unavailable. Try again before purchasing."));
        return CYRepositoryPurchaseFailed;
    }

    NSMutableDictionary *body([NSMutableDictionary dictionaryWithObjectsAndKeys:
        token, @"token",
        deviceIdentifier ?: @"", @"udid",
        deviceModel ?: @"", @"device",
    nil]);
    NSString *secret(includePaymentSecret ? CYRepositorySecret(provider) : nil);
    if ([secret length] != 0)
        [body setObject:secret forKey:@"payment_secret"];

    NSURL *endpoint(CYRepositoryPackageEndpoint(provider, packageIdentifier, @"purchase"));
    NSError *purchaseError(nil);
    NSDictionary *response(CYRepositoryJSON(endpoint, @"POST", body, &purchaseError));
    if (response == nil) {
        if (CYAccountErrorRequestsInvalidation(purchaseError))
            CYDeleteRepositoryTokenIfUnchanged(provider, token, credentialGeneration);
        if (error != NULL)
            *error = purchaseError ?: CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The purchase could not be completed."));
        return CYRepositoryPurchaseFailed;
    }

    id statusValue([response objectForKey:@"status"]);
    if (![statusValue isKindOfClass:[NSNumber class]]) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The repository returned an invalid purchase status."));
        return CYRepositoryPurchaseFailed;
    }
    NSInteger status([statusValue integerValue]);
    if (status < CYRepositoryPurchaseFailed || status > CYRepositoryPurchaseActionRequired) {
        if (error != NULL)
            *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The repository returned an invalid purchase status."));
        return CYRepositoryPurchaseFailed;
    }
    if (status == CYRepositoryPurchaseActionRequired) {
        id url([response objectForKey:@"url"]);
        NSURL *parsed([url isKindOfClass:[NSString class]] ? [NSURL URLWithString:url] : nil);
        if (!CYValidHTTPSURL(parsed)) {
            if (error != NULL)
                *error = CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The repository returned an invalid purchase action URL."));
            return CYRepositoryPurchaseFailed;
        }
        if (actionURL != NULL)
            *actionURL = [parsed absoluteString];
    }
    return status;
}

// Give every image the same point-sized canvas. UIKit otherwise keeps small
// downloaded bitmaps at their native size, even with a reserved layout size.
static UIImage *CYRepositoryArtwork(UIImage *image, UIColor *symbolColor) {
    const CGFloat side(44.0);
    UIGraphicsImageRenderer *renderer([[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)] autorelease]);
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect bounds(CGRectMake(0, 0, side, side));
        UIImage *drawing(image);
        if (symbolColor != nil) {
            [[symbolColor colorWithAlphaComponent:0.12] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:12.0] fill];
            drawing = [image imageWithTintColor:symbolColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            bounds = CGRectInset(bounds, 10.0, 10.0);
        }
        CGSize size([drawing size]);
        if (size.width <= 0 || size.height <= 0) return;
        CGFloat scale(MIN(CGRectGetWidth(bounds) / size.width, CGRectGetHeight(bounds) / size.height));
        CGSize fitted(CGSizeMake(size.width * scale, size.height * scale));
        [drawing drawInRect:CGRectMake(CGRectGetMidX(bounds) - fitted.width / 2,
            CGRectGetMidY(bounds) - fitted.height / 2, fitted.width, fitted.height)];
    }];
}

static UIListContentConfiguration *CYRepositoryRow(NSString *title, NSString *subtitle, UIImage *icon, UIColor *color) {
    UIListContentConfiguration *content([UIListContentConfiguration subtitleCellConfiguration]);
    [content setText:title]; [content setSecondaryText:subtitle];
    [[content textProperties] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
    [[content textProperties] setNumberOfLines:0];
    [[content secondaryTextProperties] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]];
    [[content secondaryTextProperties] setNumberOfLines:2];
    [[content secondaryTextProperties] setColor:[UIColor secondaryLabelColor]];
    [content setDirectionalLayoutMargins:NSDirectionalEdgeInsetsMake(14, 18, 14, 12)];
    [content setTextToSecondaryTextVerticalPadding:4];
    [content setImage:CYRepositoryArtwork(icon ?: [UIImage cy_symbolNamed:@"shippingbox.fill"], color)];
    [[content imageProperties] setMaximumSize:CGSizeMake(44,44)];
    [[content imageProperties] setReservedLayoutSize:CGSizeMake(44,44)];
    [[content imageProperties] setCornerRadius:12];
    return content;
}

@interface CydiaPurchasedPackagesViewController : UITableViewController <UISearchResultsUpdating> {
    NSArray *packages_;
    NSArray *availablePackages_;
    NSArray *visiblePackages_;
    NSMutableDictionary *metadata_;
    NSString *providerName_;
    NSString *repositoryURL_;
    id packageTarget_;
    SEL packageAction_;
    CYRepositoryPackageResolver resolver_;
    UISearchController *searchController_;
}
- (id) initWithPackages:(NSArray *)packages providerName:(NSString *)providerName repositoryURL:(NSString *)repositoryURL
                 target:(id)target action:(SEL)action resolver:(CYRepositoryPackageResolver)resolver;
- (void) reloadPackageMetadata;
@end

@implementation CydiaPurchasedPackagesViewController
- (id) initWithPackages:(NSArray *)packages providerName:(NSString *)providerName repositoryURL:(NSString *)repositoryURL
                 target:(id)target action:(SEL)action resolver:(CYRepositoryPackageResolver)resolver {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]) != nil) {
        packages_ = [[[NSOrderedSet orderedSetWithArray:packages] array] copy];
        providerName_ = [providerName copy]; repositoryURL_ = [repositoryURL copy];
        packageTarget_ = target; packageAction_ = action; resolver_ = [resolver copy];
        metadata_ = [[NSMutableDictionary alloc] init];
        [[self navigationItem] setTitle:CYLocalize(@"Purchased Packages")];
        [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    }
    return self;
}
- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [packages_ release]; [availablePackages_ release]; [visiblePackages_ release];
    [metadata_ release]; [providerName_ release]; [repositoryURL_ release];
    [resolver_ release]; [searchController_ release];
    [super dealloc];
}
- (void) viewDidLoad {
    [super viewDidLoad];
    CYModernizeTableView([self tableView]);
    [[self tableView] setRowHeight:UITableViewAutomaticDimension];
    [[self tableView] setEstimatedRowHeight:80];
    searchController_ = [[UISearchController alloc] initWithSearchResultsController:nil];
    [searchController_ setObscuresBackgroundDuringPresentation:NO];
    [searchController_ setSearchResultsUpdater:self];
    [[searchController_ searchBar] setPlaceholder:CYLocalize(@"Search purchases")];
    [[self navigationItem] setSearchController:searchController_];
    [[self navigationItem] setHidesSearchBarWhenScrolling:NO];
    [self setDefinesPresentationContext:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(purchasedIconDidLoad:)
        name:CYRepositoryPurchasedIconDidLoadNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadPackageMetadata)
        name:CYRepositoryPackageLibraryDidReloadNotification object:nil];
}
- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadPackageMetadata];
}
- (void) reloadPackageMetadata {
    [metadata_ removeAllObjects];
    NSMutableArray *available([NSMutableArray array]);
    for (NSString *identifier in packages_) {
        NSDictionary *info(resolver_ != NULL ? resolver_(identifier, repositoryURL_, NO) : nil);
        if (info != nil) {
            [metadata_ setObject:info forKey:identifier];
            [available addObject:identifier];
        }
    }
    [available sortUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSString *lhs([[metadata_ objectForKey:left] objectForKey:@"name"] ?: left);
        NSString *rhs([[metadata_ objectForKey:right] objectForKey:@"name"] ?: right);
        NSComparisonResult order([lhs localizedStandardCompare:rhs]);
        return order == NSOrderedSame ? [left compare:right] : order;
    }];
    [availablePackages_ release]; availablePackages_ = [available copy];
    [self updateSearchResultsForSearchController:searchController_];
}
- (void) purchasedIconDidLoad:(NSNotification *)notification {
    NSString *identifier([[notification userInfo] objectForKey:CYRepositoryPurchasedPackageKey]);
    NSUInteger row([visiblePackages_ indexOfObject:identifier]);
    if (row == NSNotFound) return;
    NSIndexPath *path([NSIndexPath indexPathForRow:row inSection:0]);
    if ([[[self tableView] indexPathsForVisibleRows] containsObject:path])
        [[self tableView] reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
}
- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX((NSUInteger)1, [visiblePackages_ count]);
}
- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return providerName_;
}
- (NSString *) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSUInteger unavailable([packages_ count] - [availablePackages_ count]);
    if (unavailable != 0)
        return [NSString stringWithFormat:CYLocalize(@"%lu of %lu purchases are listed in this source. Other purchases may have been removed or may not be offered for this device. Refresh Sources to check again."),
            (unsigned long)[availablePackages_ count], (unsigned long)[packages_ count]];
    return CYLocalize(@"Purchases available from this repository.");
}
- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell([tableView dequeueReusableCellWithIdentifier:@"PurchasedPackage"]);
    if (cell == nil) cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"PurchasedPackage"] autorelease];
    [cell setAccessoryView:nil]; [cell setAccessoryType:UITableViewCellAccessoryNone];
    if ([visiblePackages_ count] == 0) {
        BOOL searching([[[searchController_ searchBar] text] length] != 0);
        [cell setContentConfiguration:CYRepositoryRow(searching ? CYLocalize(@"No matching purchases") : CYLocalize(@"No packages available"),
            searching ? CYLocalize(@"Try another name or package identifier.") : CYLocalize(@"Refresh Sources to check this repository again."),
            [UIImage cy_symbolNamed:searching ? @"magnifyingglass" : @"bag"], CYModernAccentColor())];
        [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
        return cell;
    }
    NSString *identifier([visiblePackages_ objectAtIndex:[indexPath row]]);
    NSDictionary *info(resolver_ != NULL ? resolver_(identifier, repositoryURL_, YES) : nil);
    if (info == nil) info = [metadata_ objectForKey:identifier];
    UIImage *icon([info objectForKey:@"icon"]);
    [cell setContentConfiguration:CYRepositoryRow([info objectForKey:@"name"] ?: identifier,
        [info objectForKey:@"summary"] ?: [NSString stringWithFormat:CYLocalize(@"Purchased from %@"), providerName_],
        icon, icon == nil ? CYModernAccentColor() : nil)];
    [cell setSelectionStyle:UITableViewCellSelectionStyleDefault];
    if ([[info objectForKey:@"installed"] boolValue]) {
        UIImageView *check([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:@"checkmark.circle.fill"]] autorelease]);
        [check setTintColor:[UIColor systemGreenColor]]; [check sizeToFit];
        [check setIsAccessibilityElement:YES]; [check setAccessibilityLabel:CYLocalize(@"Installed")];
        [cell setAccessoryView:check];
    } else [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
    return cell;
}
- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([visiblePackages_ count] == 0) return;
    NSString *identifier([visiblePackages_ objectAtIndex:[indexPath row]]);
    // Recheck after refresh; a previously rendered row may no longer exist.
    if (resolver_ == NULL || resolver_(identifier, repositoryURL_, NO) == nil) {
        [self reloadPackageMetadata];
        return;
    }
    if ([packageTarget_ respondsToSelector:packageAction_])
        [packageTarget_ performSelector:packageAction_ withObject:identifier];
}
- (void) updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query([[[searchController searchBar] text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    NSArray *filtered([availablePackages_ filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *identifier, NSDictionary *bindings) {
        return CYPurchaseMatchesQuery(identifier, [[metadata_ objectForKey:identifier] objectForKey:@"name"], query);
    }]]);
    [visiblePackages_ release]; visiblePackages_ = [filtered copy];
    [[self tableView] reloadData];
}
@end

@interface CydiaRepositoryAccountsViewController () {
    NSArray *repositories_;
    NSArray *providers_;
    NSString *deviceIdentifier_;
    NSString *deviceModel_;
    id packageTarget_;
    SEL packageAction_;
    CYRepositoryPackageResolver resolver_;
    ASWebAuthenticationSession *authenticationSession_;
    NSURL *authenticatingProvider_;
    BOOL loading_;
    BOOL reloadPending_;
    NSUInteger accountLoadGeneration_;
    NSUInteger authenticationGeneration_;
}

- (void) reloadAccounts;

@end

@implementation CydiaRepositoryAccountsViewController

- (id) initWithRepositories:(NSArray *)repositories deviceIdentifier:(NSString *)deviceIdentifier deviceModel:(NSString *)deviceModel {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped]) != nil) {
        repositories_ = [repositories copy];
        deviceIdentifier_ = [deviceIdentifier copy];
        deviceModel_ = [deviceModel copy];
        providers_ = [[NSArray alloc] init];
        [[self navigationItem] setTitle:CYLocalize(@"Manage Account")];
    }
    return self;
}

- (void) dealloc {
    [authenticationSession_ cancel];
    [authenticationSession_ release];
    [authenticatingProvider_ release];
    [repositories_ release];
    [providers_ release];
    [deviceIdentifier_ release];
    [deviceModel_ release];
    [resolver_ release];
    [super dealloc];
}

- (void) setPackageTarget:(id)target action:(SEL)action {
    packageTarget_ = target;
    packageAction_ = action;
}

- (void) setPackageResolver:(CYRepositoryPackageResolver)resolver {
    if (resolver_ == resolver)
        return;
    [resolver_ release];
    resolver_ = [resolver copy];
}

- (void) viewDidLoad {
    [super viewDidLoad];
    CYModernizeTableView([self tableView]);
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    [[self tableView] setRowHeight:UITableViewAutomaticDimension];
    [[self tableView] setEstimatedRowHeight:68.0f];

    UIView *header([[[UIView alloc] initWithFrame:CGRectMake(0,0,320,130)] autorelease]);
    UIImageView *icon([[[CydiaSymbolView alloc] initWithImage:CYRepositoryArtwork(
        [UIImage cy_symbolNamed:@"person.crop.circle.badge.checkmark"], CYModernAccentColor())] autorelease]);
    [icon setTranslatesAutoresizingMaskIntoConstraints:NO];
    UILabel *title([[[UILabel alloc] init] autorelease]);
    [title setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2]];
    [title setText:CYLocalize(@"Your accounts")];
    [title setTextColor:[UIColor labelColor]];
    [title setNumberOfLines:0]; [title setAdjustsFontForContentSizeCategory:YES];
    UILabel *caption([[[UILabel alloc] init] autorelease]);
    [caption setText:CYLocalize(@"Manage sign-ins and explore your purchases.")];
    [caption setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]];
    [caption setTextColor:[UIColor secondaryLabelColor]];
    [caption setNumberOfLines:0]; [caption setAdjustsFontForContentSizeCategory:YES];
    UIStackView *copy([[[UIStackView alloc] initWithArrangedSubviews:@[title, caption]] autorelease]);
    [copy setTranslatesAutoresizingMaskIntoConstraints:NO];
    [copy setAxis:UILayoutConstraintAxisVertical]; [copy setSpacing:5];
    [header addSubview:icon]; [header addSubview:copy];
    [NSLayoutConstraint activateConstraints:@[
        [[icon leadingAnchor] constraintEqualToAnchor:[header leadingAnchor] constant:24],
        [[icon topAnchor] constraintEqualToAnchor:[header topAnchor] constant:22],
        [[icon widthAnchor] constraintEqualToConstant:52], [[icon heightAnchor] constraintEqualToConstant:52],
        [[copy leadingAnchor] constraintEqualToAnchor:[icon trailingAnchor] constant:16],
        [[copy trailingAnchor] constraintEqualToAnchor:[header trailingAnchor] constant:-24],
        [[copy topAnchor] constraintEqualToAnchor:[header topAnchor] constant:22],
        [[copy bottomAnchor] constraintEqualToAnchor:[header bottomAnchor] constant:-20],
        [[icon bottomAnchor] constraintLessThanOrEqualToAnchor:[header bottomAnchor] constant:-20]
    ]];
    [[self tableView] setTableHeaderView:header];

    UIRefreshControl *refresh([[[UIRefreshControl alloc] init] autorelease]);
    [refresh addTarget:self action:@selector(reloadAccounts) forControlEvents:UIControlEventValueChanged];
    [self setRefreshControl:refresh];
    [self reloadAccounts];
}

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header([[self tableView] tableHeaderView]);
    CGFloat width(CGRectGetWidth([header bounds]));
    CGFloat height([header systemLayoutSizeFittingSize:CGSizeMake(width, 0)
        withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);
    if (width > 0 && fabs(CGRectGetHeight([header frame]) - ceil(height)) > 0.5) {
        CGRect frame([header frame]); frame.size.height = ceil(height);
        [header setFrame:frame];
        [[self tableView] setTableHeaderView:header];
    }
}
- (void) traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (![self isViewLoaded]) return;
    [[self tableView] reloadData];
    [[self view] setNeedsLayout];
}

- (void) reloadAccounts {
    if (loading_) {
        reloadPending_ = YES;
        return;
    }
    reloadPending_ = NO;
    loading_ = YES;
    accountLoadGeneration_ = CYRepositoryCredentialsGeneration();
    [[self refreshControl] beginRefreshing];
    [[self tableView] reloadData];
    [self performSelectorInBackground:@selector(loadAccountsInBackground) withObject:nil];
}

- (void) loadAccountsInBackground {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);
    NSMutableArray *providers([NSMutableArray array]);
    NSMutableSet *seen([NSMutableSet set]);
    NSOperationQueue *queue([[[NSOperationQueue alloc] init] autorelease]);
    [queue setMaxConcurrentOperationCount:4];
    for (NSDictionary *repository in repositories_) {
        [queue addOperationWithBlock:^{
            NSAutoreleasePool *operationPool([[NSAutoreleasePool alloc] init]);
            NSString *repositoryURL([repository objectForKey:CYRepositoryAccountURLKey]);
            NSError *error(nil);
            NSURL *provider(CYRepositoryPaymentProvider(repositoryURL, &error));
            if (provider != nil) {
                BOOL duplicate(NO);
                @synchronized (seen) {
                    duplicate = [seen containsObject:[provider absoluteString]];
                    if (!duplicate)
                        [seen addObject:[provider absoluteString]];
                }
                if (!duplicate) {
                    NSDictionary *info(CYRepositoryJSON(CYEndpointURL(provider, @"info"), @"GET", nil, &error));
                    NSMutableDictionary *record([NSMutableDictionary dictionary]);
                    [record setObject:provider forKey:@"provider"];
                    [record setObject:repositoryURL forKey:@"repository"];
                    NSString *providerName([info objectForKey:@"name"]);
                    [record setObject:([providerName isKindOfClass:[NSString class]] && [providerName length] != 0 ? providerName : [provider host]) forKey:@"name"];
                    NSString *description([info objectForKey:@"description"]);
                    if ([description isKindOfClass:[NSString class]] && [description length] != 0)
                        [record setObject:description forKey:@"description"];

                    NSUInteger credentialGeneration;
                    NSString *token(CYRepositoryToken(provider, &credentialGeneration));
                    BOOL signedIn(token != nil);
                    [record setObject:[NSNumber numberWithBool:signedIn] forKey:@"signedIn"];
                    if (signedIn) {
                        NSDictionary *userInfo(CYRepositoryUserInfo(provider, token, deviceIdentifier_, deviceModel_, &error));
                        if (userInfo != nil) {
                            id user([userInfo objectForKey:@"user"]);
                            if ([user isKindOfClass:[NSDictionary class]])
                                [record setObject:user forKey:@"user"];
                            [record setObject:CYPurchasedItems(userInfo) forKey:@"items"];
                        } else if (error != nil) {
                            if (CYAccountErrorRequestsInvalidation(error)) {
                                CYDeleteRepositoryTokenIfUnchanged(provider, token, credentialGeneration);
                                [record setObject:[NSNumber numberWithBool:NO] forKey:@"signedIn"];
                            }
                            [record setObject:[error localizedDescription] forKey:@"error"];
                        }
                    }
                    @synchronized (providers) {
                        [providers addObject:record];
                    }
                }
            }
            [operationPool drain];
        }];
    }
    [queue waitUntilAllOperationsAreFinished];
    [providers sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [[left objectForKey:@"name"] localizedCaseInsensitiveCompare:[right objectForKey:@"name"]];
    }];
    NSArray *finished([NSArray arrayWithArray:providers]);
    [self performSelectorOnMainThread:@selector(finishLoadingAccounts:) withObject:finished waitUntilDone:YES];
    [pool drain];
}

- (void) finishLoadingAccounts:(NSArray *)providers {
    loading_ = NO;
    // A sign-in/sign-out or a queued refresh supersedes this snapshot. Keep
    // the refresh indicator running until the current account state arrives.
    if (reloadPending_ || accountLoadGeneration_ != CYRepositoryCredentialsGeneration()) {
        [self reloadAccounts];
        return;
    }
    [providers_ release];
    providers_ = [providers copy];
    [[self refreshControl] endRefreshing];
    [[self tableView] reloadData];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return [providers_ count] == 0 ? 1 : [providers_ count];
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([providers_ count] == 0)
        return 1;
    NSDictionary *provider([providers_ objectAtIndex:section]);
    return [[provider objectForKey:@"signedIn"] boolValue] ? 2 : 1;
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ([providers_ count] == 0)
        return CYLocalize(@"Repository Accounts");
    return [[providers_ objectAtIndex:section] objectForKey:@"name"];
}

- (NSString *) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ([providers_ count] == 0)
        return CYLocalize(@"Accounts from supported sources appear here. Pull down to check again.");
    NSDictionary *provider([providers_ objectAtIndex:section]);
    if ([[provider objectForKey:@"error"] length] != 0)
        return [provider objectForKey:@"error"];
    return [[provider objectForKey:@"signedIn"] boolValue] ? nil :
        CYLocalize(@"Sign in with this repository to access your purchases.");
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell([tableView dequeueReusableCellWithIdentifier:@"RepositoryAccount"]);
    if (cell == nil) cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"RepositoryAccount"] autorelease];
    [cell setAccessoryView:nil]; [cell setAccessoryType:UITableViewCellAccessoryNone];
    if ([providers_ count] == 0) {
        [cell setContentConfiguration:CYRepositoryRow(loading_ ? CYLocalize(@"Checking your sources…") : CYLocalize(@"No accounts available"),
            loading_ ? CYLocalize(@"Finding repositories that support sign-in.") : CYLocalize(@"Add a supported repository in Sources."),
            [UIImage cy_symbolNamed:@"person.crop.circle"], CYModernAccentColor())];
        if (loading_) {
            UIActivityIndicatorView *activity([[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium] autorelease]);
            [activity startAnimating]; [cell setAccessoryView:activity];
        }
        [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
        return cell;
    }
    NSDictionary *provider([providers_ objectAtIndex:[indexPath section]]);
    NSString *title(nil), *detail(nil), *symbol(nil);
    UIColor *color(CYModernAccentColor());
    if ([indexPath row] == 0) {
        BOOL signedIn([[provider objectForKey:@"signedIn"] boolValue]);
        NSDictionary *user([provider objectForKey:@"user"]);
        NSString *name([user objectForKey:@"name"]), *email([user objectForKey:@"email"]);
        title = signedIn ? (([name isKindOfClass:[NSString class]] && [name length] != 0) ? name : CYLocalize(@"Signed in")) : CYLocalize(@"Sign In");
        detail = signedIn ? (([email isKindOfClass:[NSString class]] && [email length] != 0) ? email : CYLocalize(@"Account connected")) : CYLocalize(@"Connect your repository account");
        symbol = signedIn ? @"person.crop.circle.badge.checkmark" : @"person.crop.circle.badge.plus";
        color = signedIn ? [UIColor systemGreenColor] : CYModernAccentColor();
    } else {
        NSUInteger count([[provider objectForKey:@"items"] count]);
        title = CYLocalize(@"Purchased Packages"); symbol = @"bag";
        detail = CYLocalizedMetric(CYLocalize(@"Purchases"), count);
    }
    [cell setContentConfiguration:CYRepositoryRow(title, detail, [UIImage cy_symbolNamed:symbol], color)];
    [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
    [cell setSelectionStyle:UITableViewCellSelectionStyleDefault];
    return cell;
}

- (void) showError:(NSError *)error {
    UIAlertController *alert([UIAlertController alertControllerWithTitle:CYLocalize(@"Manage Account") message:[error localizedDescription] preferredStyle:UIAlertControllerStyleAlert]);
    [alert addAction:[UIAlertAction actionWithTitle:CYLocalize(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void) beginAuthenticationForProvider:(NSURL *)provider {
    if ([deviceIdentifier_ length] == 0 || [deviceModel_ length] == 0) {
        [self showError:CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The device identity needed by this repository is unavailable."))];
        return;
    }
    NSURLComponents *components([NSURLComponents componentsWithURL:CYEndpointURL(provider, @"authenticate") resolvingAgainstBaseURL:NO]);
    [components setQueryItems:[NSArray arrayWithObjects:
        [NSURLQueryItem queryItemWithName:@"udid" value:deviceIdentifier_],
        [NSURLQueryItem queryItemWithName:@"model" value:deviceModel_],
    nil]];
    NSURL *authenticationURL([components URL]);
    if (!CYValidHTTPSURL(authenticationURL)) {
        [self showError:CYAccountError(CYRepositoryAccountErrorInvalidURL, CYLocalize(@"The sign-in URL is invalid."))];
        return;
    }

    NSUInteger generation(++authenticationGeneration_);
    [authenticationSession_ cancel];
    [authenticationSession_ release];
    [authenticatingProvider_ release];
    authenticatingProvider_ = [provider copy];
    authenticationSession_ = [[ASWebAuthenticationSession alloc] initWithURL:authenticationURL callbackURLScheme:@"sileo" completionHandler:^(NSURL *callbackURL, NSError *sessionError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // A cancelled older browser session cannot clear or complete a newer one.
            if (generation != authenticationGeneration_)
                return;
            NSURL *providerURL([[authenticatingProvider_ retain] autorelease]);
            [authenticationSession_ release];
            authenticationSession_ = nil;
            [authenticatingProvider_ release];
            authenticatingProvider_ = nil;
            if (sessionError != nil) {
                if ([sessionError code] != ASWebAuthenticationSessionErrorCodeCanceledLogin)
                    [self showError:sessionError];
                return;
            }
            NSURLComponents *callback([NSURLComponents componentsWithURL:callbackURL resolvingAgainstBaseURL:NO]);
            if (![[[callback scheme] lowercaseString] isEqualToString:@"sileo"] || ![[[callback host] lowercaseString] isEqualToString:@"authentication_success"]) {
                [self showError:CYAccountError(CYRepositoryAccountErrorResponse, CYLocalize(@"The repository returned an invalid sign-in callback."))];
                return;
            }
            NSString *token(nil);
            NSString *paymentSecret(nil);
            for (NSURLQueryItem *item in [callback queryItems])
                if ([[item name] isEqualToString:@"token"])
                    token = [item value];
                else if ([[item name] isEqualToString:@"payment_secret"])
                    paymentSecret = [item value];
            NSError *storeError(nil);
            if (!CYStoreRepositoryToken(providerURL, token, &storeError)) {
                [self showError:storeError];
                return;
            }
            // A fresh account token must never inherit an older account's secret.
            OSStatus cleared(SecItemDelete((CFDictionaryRef) CYKeychainQuery(providerURL, CYRepositoryAccountSecretKeychainService)));
            if (cleared != errSecSuccess && cleared != errSecItemNotFound) {
                CYDeleteRepositoryToken(providerURL);
                [self showError:CYAccountError(CYRepositoryAccountErrorKeychain, CYLocalize(@"The previous account credential could not be cleared. Sign in again."))];
                return;
            }
            if (CYValidRepositoryCredential(paymentSecret, 8192)) {
                LAContext *context([[[LAContext alloc] init] autorelease]);
                NSError *policyError(nil);
                BOOL hasPasscode([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&policyError]);
                // Providers can still authorize purchases without a secret on
                // devices without a passcode; do not retain a weaker secret.
                if (hasPasscode && !CYStoreRepositoryPaymentSecret(providerURL, paymentSecret, &storeError)) {
                    [self reloadAccounts];
                    [self showError:storeError];
                    return;
                }
            }
            [self reloadAccounts];
        });
    }];
    [authenticationSession_ setPresentationContextProvider:self];
    [authenticationSession_ setPrefersEphemeralWebBrowserSession:NO];
    if (![authenticationSession_ start]) {
        [authenticationSession_ release];
        authenticationSession_ = nil;
        [authenticatingProvider_ release];
        authenticatingProvider_ = nil;
        [self showError:CYAccountError(CYRepositoryAccountErrorNetwork, CYLocalize(@"The secure sign-in session could not start."))];
    }
}

- (void) signOutProvider:(NSURL *)provider {
    // Clear this account locally before the request. A late sign-out response
    // must never erase a newer sign-in to the same provider.
    NSString *token(CYRepositoryToken(provider));
    CYDeleteRepositoryToken(provider);
    [self reloadAccounts];
    if (token == nil)
        return;
    NSDictionary *body(@{@"token":token, @"udid":deviceIdentifier_ ?: @"", @"device":deviceModel_ ?: @""});
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            CYRepositoryJSON(CYEndpointURL(provider, @"sign_out"), @"POST", body, NULL);
        }
    });
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([providers_ count] == 0)
        return;
    NSDictionary *provider([providers_ objectAtIndex:[indexPath section]]);
    if ([indexPath row] == 1) {
        CydiaPurchasedPackagesViewController *purchases([[[CydiaPurchasedPackagesViewController alloc]
            initWithPackages:([provider objectForKey:@"items"] ?: [NSArray array])
            providerName:[provider objectForKey:@"name"] repositoryURL:[provider objectForKey:@"repository"]
            target:packageTarget_ action:packageAction_
            resolver:resolver_] autorelease]);
        [[self navigationController] pushViewController:purchases animated:YES];
        return;
    }

    NSURL *providerURL([provider objectForKey:@"provider"]);
    if (![[provider objectForKey:@"signedIn"] boolValue]) {
        [self beginAuthenticationForProvider:providerURL];
        return;
    }
    UIAlertController *actions([UIAlertController alertControllerWithTitle:[provider objectForKey:@"name"] message:CYLocalize(@"Repository account") preferredStyle:UIAlertControllerStyleActionSheet]);
    [actions addAction:[UIAlertAction actionWithTitle:CYLocalize(@"Refresh Purchases") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self reloadAccounts];
    }]];
    [actions addAction:[UIAlertAction actionWithTitle:CYLocalize(@"Sign Out") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self signOutProvider:providerURL];
    }]];
    [actions addAction:[UIAlertAction actionWithTitle:CYLocalize(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover([actions popoverPresentationController]);
    [popover setSourceView:tableView];
    [popover setSourceRect:[tableView rectForRowAtIndexPath:indexPath]];
    [self presentViewController:actions animated:YES completion:nil];
}

- (ASPresentationAnchor) presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return [[self view] window];
}

@end
