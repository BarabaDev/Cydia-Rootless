/* Secure repository accounts for Sileo Payment API compatible sources. */

#ifndef Cydia_RepositoryAccounts_H
#define Cydia_RepositoryAccounts_H

#import <AuthenticationServices/AuthenticationServices.h>
#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const CYRepositoryAccountNameKey;
FOUNDATION_EXPORT NSString *const CYRepositoryAccountURLKey;

/* Presentation-only account state. Changes are posted on the main thread after
 * sign-in, sign-out, expiry or confirmed entitlement change. userInfo contains
 * "revision" (NSNumber); no credential values are exposed. */
FOUNDATION_EXPORT NSString *const CYRepositoryAccountStateDidChangeNotification;
FOUNDATION_EXPORT NSUInteger CYRepositoryAccountStateRevision(void);

/* Memory-only, safe on the main thread. Keys: "revision" (NSNumber), "state"
 * (NSString: unknown/signedOut/signedIn/unsupported). Unknown means this process
 * has not learned the provider/account state yet; this performs no discovery or
 * Keychain lookup and does not authorize a purchase or download. */
FOUNDATION_EXPORT NSDictionary *CYRepositoryAccountStateSnapshot(NSString *repositoryURL);

/* Memory-only display snapshot, or nil when unknown/invalidated. Keys:
 * "revision", "fresh" (NSNumber), optional "info" (NSDictionary) / "error"
 * (NSError). Successful quotes expire after 30 seconds; transient errors after
 * 5 seconds. A stale quote may be displayed but must be refreshed before Buy.
 * Fresh CYRepositoryPackageInfo queries record only unchanged-revision results.
 * Async callers must also compare the captured revision before applying a result. */
FOUNDATION_EXPORT NSDictionary *CYRepositoryPackageInfoSnapshot(NSString *repositoryURL,
    NSString *packageIdentifier, NSString *deviceIdentifier, NSString *deviceModel);

/* Call once after confirmed purchase completion, including browser completion.
 * Invalidates display quotes and notifies observers without changing credentials. */
FOUNDATION_EXPORT void CYRepositoryAccountPurchaseDidComplete(NSString *repositoryURL);

/* Resolves a purchased package identifier to display metadata for the modern
 * Purchased Packages list. Result keys (all optional): "name" (NSString),
 * "summary" (NSString), "icon" (UIImage), "installed" (NSNumber BOOL).
 * Returns nil when the package is not offered by this repository. Metadata-only
 * requests (loadIcon = NO) must not start artwork downloads. */
typedef NSDictionary *(^CYRepositoryPackageResolver)(NSString *identifier, NSString *repositoryURL, BOOL loadIcon);
FOUNDATION_EXPORT NSString *const CYRepositoryPackageLibraryDidReloadNotification;

/* Posted on the main thread when a purchased package's remote icon finishes
 * downloading, so an open Purchased Packages list can refresh that row. The
 * userInfo carries CYRepositoryPurchasedPackageKey (the package identifier). */
FOUNDATION_EXPORT NSString *const CYRepositoryPurchasedIconDidLoadNotification;
FOUNDATION_EXPORT NSString *const CYRepositoryPurchasedPackageKey;

@interface CydiaRepositoryAccountsViewController : UITableViewController <ASWebAuthenticationPresentationContextProviding>

- (id) initWithRepositories:(NSArray *)repositories
           deviceIdentifier:(NSString *)deviceIdentifier
                deviceModel:(NSString *)deviceModel;
- (void) setPackageTarget:(id)target action:(SEL)action;
- (void) setPackageResolver:(CYRepositoryPackageResolver)resolver;

@end

/* Called from the APT preparation worker. Returns a short-lived HTTPS URL
 * only after the repository account confirms that the package is owned. */
FOUNDATION_EXPORT NSString *CYRepositoryAuthorizedDownloadURL(
    NSString *repositoryURL,
    NSString *packageIdentifier,
    NSString *version,
    NSString *architecture,
    NSString *deviceIdentifier,
    NSString *deviceModel,
    NSError **error
);

enum {
    CYRepositoryPurchaseImmediateSuccess = 0,
    CYRepositoryPurchaseActionRequired = 1,
    CYRepositoryPurchaseFailed = -1,
    CYRepositoryPurchaseCancelled = -2,
};

/* Commercial package price and ownership for the native Buy action.
 * Result keys: "price" (NSString), "purchased" (NSNumber BOOL),
 * "available" (NSNumber BOOL). Returns nil when signed out or on error. */
FOUNDATION_EXPORT NSDictionary *CYRepositoryPackageInfo(
    NSString *repositoryURL,
    NSString *packageIdentifier,
    NSString *deviceIdentifier,
    NSString *deviceModel,
    NSError **error
);

/* Classifies a missing or invalid account credential after payment-provider
 * discovery. Unavailable or unsupported providers do not require sign-in. */
FOUNDATION_EXPORT BOOL CYRepositoryAccountErrorRequiresSignIn(NSError *error);

/* A repository without the supported HTTPS payment-discovery protocol keeps
 * its ordinary package actions. Transient failures of that protocol do not
 * count as unsupported, and this never authorizes a package download. */
FOUNDATION_EXPORT BOOL CYRepositoryAccountErrorIsUnsupportedProvider(NSError *error);

/* Starts an in-app purchase after device authentication and returns one of the
 * CYRepositoryPurchase* codes. On CYRepositoryPurchaseActionRequired, *actionURL
 * receives a short-lived HTTPS URL to present in ASWebAuthenticationSession
 * (callback scheme "sileo", success host "payment_completed"). */
FOUNDATION_EXPORT NSInteger CYRepositoryPurchase(
    NSString *repositoryURL,
    NSString *packageIdentifier,
    NSString *deviceIdentifier,
    NSString *deviceModel,
    NSString **actionURL,
    NSError **error
);

#endif
