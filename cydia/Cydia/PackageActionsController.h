#import <UIKit/UIKit.h>

@interface CydiaPackageActionsController : UITableViewController
- (instancetype)initWithTitle:(NSString *)title packageName:(NSString *)name version:(NSString *)version
    icon:(UIImage *)icon actions:(NSArray *)actions selection:(void (^)(NSString *identifier))selection;
- (void)invalidateSelection;
@end

// Keep the large package sheet attached while moving between transaction steps.
UINavigationController *CYPackageActionsNavigation(UIViewController *presenter);
void CYReplacePackagePanel(UINavigationController *navigation, UIViewController *page);

// The initial chooser dismisses completely before starting a package action.
BOOL CYPresentPackageActionMenu(UIViewController *presenter, UIView *sourceView, NSArray *actions, void (^selection)(NSString *identifier));
BOOL CYInvalidatePackageActionMenu(UIViewController *controller);
