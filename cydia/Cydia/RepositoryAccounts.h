/* Secure repository accounts for Sileo Payment API compatible sources. */

#ifndef Cydia_RepositoryAccounts_H
#define Cydia_RepositoryAccounts_H

#import <AuthenticationServices/AuthenticationServices.h>
#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const CYRepositoryAccountNameKey;
FOUNDATION_EXPORT NSString *const CYRepositoryAccountURLKey;

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
