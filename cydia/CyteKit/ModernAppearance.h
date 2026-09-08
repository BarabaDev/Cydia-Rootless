/* Cydia 1.1.23 Rootless - iOS 15+ appearance helpers */

#ifndef CyteKit_ModernAppearance_H
#define CyteKit_ModernAppearance_H

#import <UIKit/UIKit.h>

// Resolve new SF Symbols when present, with iOS 15 fallbacks for every alias.
@interface UIImage (CydiaModernSymbols)
+ (UIImage *) cy_symbolNamed:(NSString *)name;
+ (UIImage *) cy_symbolNamed:(NSString *)name withConfiguration:(UIImageConfiguration *)configuration;
@end

// Palette and gradient rendering applies only to SF Symbols, never package art.
@interface CydiaSymbolView : UIImageView {
    UIImageSymbolConfiguration *baseSymbolConfiguration_;
    BOOL applyingSymbolRendering_;
}
@end

@interface CydiaModernSheetController : UIViewController
@end

@interface CydiaModernNavigationController : UINavigationController
@end

// A source-refresh indicator that owns and stops its decorative animations.
@interface CydiaSourceRefreshBar : UIView {
    CAGradientLayer *spectrum_;
    BOOL refreshing_;
}
- (void) setRefreshing:(BOOL)refreshing;
@end

// A stable navigation hit area whose symbol and activity indicator share a centre.
@interface CydiaNavigationButton : UIControl {
    UIImageView *symbolView_;
    UIActivityIndicatorView *activity_;
}
- (id) initWithSymbol:(NSString *)symbol label:(NSString *)label target:(id)target action:(SEL)action;
- (void) setLoading:(BOOL)loading;
@end

void CYApplyModernAppearance(void);
void CYModernizeNavigationController(UINavigationController *navigation);
void CYModernizeDarkNavigationController(UINavigationController *navigation);
void CYModernizeTableView(UITableView *table);

UITableViewStyle CYModernGroupedTableStyle(void);
UIImage *CYModernTabImage(NSString *identifier, BOOL selected);
UIBarButtonItem *CYModernBarButtonItem(NSString *symbol, NSString *label,
    UIBarButtonItemStyle style, id target, SEL action);

// Upstream Cydia uses UIKit blue; system colors adapt to appearance and contrast.
UIColor *CYModernAccentColor(void);
UIColor *CYModernPrimaryButtonColor(void);
UIColor *CYModernCellBackgroundColor(void);
UIColor *CYModernLabelColor(void);
UIColor *CYModernSecondaryLabelColor(void);
UIColor *CYModernCommercialColor(void);
UIColor *CYModernPackageDescriptionColor(BOOL commercial);
UIColor *CYModernQueuedColor(BOOL removing);

#endif//CyteKit_ModernAppearance_H
