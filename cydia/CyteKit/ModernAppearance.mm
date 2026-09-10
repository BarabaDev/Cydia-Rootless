/* Cydia 1.1.30 - modern rootless appearance layer for iOS 15+ */

#include "CyteKit/UCPlatform.h"
#include "CyteKit/ModernAppearance.h"
#include "Cydia/ModernLocalization.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdlib.h>

@implementation UIImage (CydiaModernSymbols)
+ (UIImage *) cy_symbolNamed:(NSString *)name {
    return [self cy_symbolNamed:name withConfiguration:nil];
}
+ (UIImage *) cy_symbolNamed:(NSString *)name withConfiguration:(UIImageConfiguration *)configuration {
    if ([name length] == 0) return nil;
    static NSDictionary *modernNames;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        modernNames = [@{
            @"arrow.clockwise": @"arrow.trianglehead.clockwise",
            @"arrow.counterclockwise": @"arrow.trianglehead.counterclockwise",
            @"arrow.triangle.2.circlepath": @"arrow.trianglehead.2.clockwise.rotate.90",
            @"clock.arrow.circlepath": @"clock.arrow.trianglehead.counterclockwise.rotate.90"
        } retain];
    });
    NSString *modern([modernNames objectForKey:name]);
    UIImage *image(nil);
    if (@available(iOS 18.0, *))
        if (modern != nil) image = [UIImage systemImageNamed:modern];
    if (image == nil) image = [UIImage systemImageNamed:name];
    if (image == nil) image = [UIImage systemImageNamed:@"questionmark.circle"];
    UIImageConfiguration *base([UIImageSymbolConfiguration configurationWithWeight:UIImageSymbolWeightRegular]);
    if (configuration != nil) base = [base configurationByApplyingConfiguration:configuration];
    return [image imageByApplyingSymbolConfiguration:(UIImageSymbolConfiguration *)base];
}
@end

@implementation CydiaSymbolView
- (void) refreshSymbolRendering {
    if (applyingSymbolRendering_) return;
    applyingSymbolRendering_ = YES;
    if (![[self image] isSymbolImage]) {
        [super setPreferredSymbolConfiguration:baseSymbolConfiguration_];
        applyingSymbolRendering_ = NO;
        return;
    }
    UIColor *color([self tintColor] ?: [UIColor labelColor]);
    BOOL contrast([[self traitCollection] accessibilityContrast] == UIAccessibilityContrastHigh);
    UIImageSymbolConfiguration *appearance(contrast ?
        [UIImageSymbolConfiguration configurationWithPaletteColors:@[color, color, color]] :
        [UIImageSymbolConfiguration configurationWithHierarchicalColor:color]);
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 260000
    if (@available(iOS 26.0, *))
        if (!contrast) appearance = (UIImageSymbolConfiguration *)[appearance configurationByApplyingConfiguration:
            [UIImageSymbolConfiguration configurationWithColorRenderingMode:UIImageSymbolColorRenderingModeGradient]];
#endif
    if (baseSymbolConfiguration_ != nil)
        appearance = (UIImageSymbolConfiguration *)[appearance configurationByApplyingConfiguration:baseSymbolConfiguration_];
    [super setPreferredSymbolConfiguration:appearance];
    applyingSymbolRendering_ = NO;
}
- (void) setImage:(UIImage *)image {
    [super setImage:image];
    [self refreshSymbolRendering];
}
- (void) setPreferredSymbolConfiguration:(UIImageSymbolConfiguration *)configuration {
    if (baseSymbolConfiguration_ != configuration) {
        [baseSymbolConfiguration_ release];
        baseSymbolConfiguration_ = [configuration retain];
    }
    [self refreshSymbolRendering];
}
- (void) tintColorDidChange {
    [super tintColorDidChange];
    [self refreshSymbolRendering];
}
- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self refreshSymbolRendering];
}
- (void) dealloc {
    [baseSymbolConfiguration_ release];
    [super dealloc];
}
@end

// Refresh colors stay separate from the red/orange warning and error states.
static const CGFloat CYSourceRefreshHues_[] = {
    210, 216, 222, 228, 234, 240, 246, 252,
    258, 264, 270, 276, 282, 288, 294, 300,
    306, 312, 318, 132, 138, 144, 150, 156,
    162, 168, 174, 180, 186, 192, 198, 204
};
static uint32_t CYSourceRefreshPaletteIndex_ = 0;
static BOOL CYSourceRefreshPaletteSelected_ = NO;

void CYBeginSourceRefreshAppearance(void) {
    const uint32_t count(sizeof(CYSourceRefreshHues_) / sizeof(CYSourceRefreshHues_[0]));
    // Choose uniformly from every other entry without a retry loop. The first
    // refresh can choose any shade, including the initial default blue.
    CYSourceRefreshPaletteIndex_ = CYSourceRefreshPaletteSelected_ ?
        (CYSourceRefreshPaletteIndex_ + 1 + arc4random_uniform(count - 1)) % count :
        arc4random_uniform(count);
    CYSourceRefreshPaletteSelected_ = YES;
}

static UIColor *CYSourceRefreshColor(void) {
    const CGFloat hue(CYSourceRefreshHues_[CYSourceRefreshPaletteIndex_]);
    // Capture this refresh's hue. Resolving Light/Dark or increased contrast
    // must not select another color or change the other tab's refresh state.
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL dark([traits userInterfaceStyle] == UIUserInterfaceStyleDark);
        BOOL contrast([traits accessibilityContrast] == UIAccessibilityContrastHigh);
        CGFloat saturation(dark ? (contrast ? 0.38f : 0.45f) : 0.78f);
        CGFloat brightness(dark ? 0.96f : (hue < 186 ? 0.56f : (hue < 198 ? 0.60f : (hue < 210 ? 0.66f : 0.82f))));
        if (contrast && !dark) brightness -= 0.10f;
        return [UIColor colorWithHue:hue / 360.0f saturation:saturation brightness:brightness alpha:1.0f];
    }];
}

@implementation CydiaSourceRefreshBar
- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
        [self setUserInteractionEnabled:NO];
        [self setHidden:YES];
        [[self layer] setCornerRadius:1.5];
        [self setClipsToBounds:YES];
        spectrum_ = [[CAGradientLayer layer] retain];
        [spectrum_ setStartPoint:CGPointMake(0, 0.5)];
        [spectrum_ setEndPoint:CGPointMake(1, 0.5)];
        [spectrum_ setLocations:@[@0, @0.5, @1]];
        [[self layer] addSublayer:spectrum_];
        NSNotificationCenter *center([NSNotificationCenter defaultCenter]);
        [center addObserver:self selector:@selector(stopMotion) name:UIApplicationWillResignActiveNotification object:nil];
        for (NSString *name in @[UIApplicationDidBecomeActiveNotification,
            UIAccessibilityReduceMotionStatusDidChangeNotification, NSProcessInfoPowerStateDidChangeNotification])
            [center addObserver:self selector:@selector(refreshMotion) name:name object:nil];
    }
    return self;
}
- (void) layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [spectrum_ setFrame:[self bounds]];
    [CATransaction commit];
}
- (void) stopMotion {
    [spectrum_ removeAllAnimations];
}
- (void) refreshMotion {
    [self stopMotion];
    if (!refreshing_ || [self window] == nil)
        return;
    // Keep the chosen tint for this whole refresh, including tab switches,
    // appearance changes and returning from the background.
    UIColor *refreshColor([CYSourceRefreshColor() resolvedColorWithTraitCollection:self.traitCollection]);
    BOOL contrast([self.traitCollection accessibilityContrast] == UIAccessibilityContrastHigh);
    NSArray *bright(@[(id)[[refreshColor colorWithAlphaComponent:contrast ? 0.72f : 0.40f] CGColor],
        (id)[refreshColor CGColor],
        (id)[[refreshColor colorWithAlphaComponent:contrast ? 0.82f : 0.56f] CGColor]]);
    NSArray *soft(@[(id)[[refreshColor colorWithAlphaComponent:contrast ? 0.80f : 0.48f] CGColor],
        (id)[[refreshColor colorWithAlphaComponent:contrast ? 1.0f : 0.90f] CGColor],
        (id)[[refreshColor colorWithAlphaComponent:contrast ? 0.88f : 0.64f] CGColor]]);
    NSArray *frames(@[bright, soft, bright]);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [spectrum_ setColors:[frames firstObject]];
    [CATransaction commit];
    if (UIAccessibilityIsReduceMotionEnabled() || [[NSProcessInfo processInfo] isLowPowerModeEnabled] ||
        [[UIApplication sharedApplication] applicationState] != UIApplicationStateActive)
        return;
    CAKeyframeAnimation *colors([CAKeyframeAnimation animationWithKeyPath:@"colors"]);
    [colors setValues:frames];
    [colors setDuration:43.2];
    [colors setRepeatCount:FLT_MAX];
    NSMutableArray *timing([NSMutableArray array]);
    for (NSUInteger index = 1; index < [frames count]; ++index)
        [timing addObject:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
    [colors setTimingFunctions:timing];
    [spectrum_ addAnimation:colors forKey:@"CydiaSourceSpectrum"];
    CABasicAnimation *sweep([CABasicAnimation animationWithKeyPath:@"locations"]);
    [sweep setFromValue:@[@(-0.6), @(-0.3), @0]];
    [sweep setToValue:@[@1, @1.3, @1.6]];
    [sweep setDuration:1.8];
    [sweep setRepeatCount:FLT_MAX];
    [spectrum_ addAnimation:sweep forKey:@"CydiaSourceSweep"];
}
- (void) didMoveToWindow {
    [super didMoveToWindow];
    [self refreshMotion];
}
- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous])
        [self refreshMotion];
}
- (void) setRefreshing:(BOOL)refreshing {
    if (refreshing_ == refreshing)
        return;
    refreshing_ = refreshing;
    [self setHidden:!refreshing];
    [self refreshMotion];
}
- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopMotion];
    [spectrum_ release];
    [super dealloc];
}
@end

@implementation CydiaNavigationButton
- (id) initWithSymbol:(NSString *)symbol label:(NSString *)label target:(id)target action:(SEL)action {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 44, 44)]) != nil) {
        [self setTranslatesAutoresizingMaskIntoConstraints:NO];
        [[self widthAnchor] constraintEqualToConstant:44.0f].active = YES;
        [[self heightAnchor] constraintEqualToConstant:44.0f].active = YES;
        symbolView_ = [[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:symbol
            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22.0f weight:UIImageSymbolWeightRegular]]] autorelease];
        [symbolView_ setContentMode:UIViewContentModeScaleAspectFit];
        [self addSubview:symbolView_];
        activity_ = [[[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium] autorelease];
        [activity_ setHidesWhenStopped:YES];
        [activity_ setUserInteractionEnabled:NO];
        [self addSubview:activity_];
        [self setIsAccessibilityElement:YES];
        [self setAccessibilityTraits:UIAccessibilityTraitButton];
        [self setAccessibilityLabel:label];
        if (target != nil && action != NULL)
            [self addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (CGSize) intrinsicContentSize { return CGSizeMake(44.0f, 44.0f); }
- (void) layoutSubviews {
    [super layoutSubviews];
    CGPoint centre(CGPointMake(CGRectGetMidX([self bounds]), CGRectGetMidY([self bounds])));
    [symbolView_ setBounds:CGRectMake(0, 0, 26.0f, 26.0f)];
    [symbolView_ setCenter:centre];
    [activity_ setCenter:centre];
}
- (void) tintColorDidChange {
    [super tintColorDidChange];
    [activity_ setColor:[self tintColor]];
}
- (void) setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [symbolView_ setAlpha:highlighted ? 0.45f : 1.0f];
}
- (void) setLoading:(BOOL)loading {
    [symbolView_ setHidden:loading];
    [self setEnabled:!loading];
    [self setAccessibilityTraits:UIAccessibilityTraitButton | (loading ? UIAccessibilityTraitNotEnabled : 0)];
    [self setAccessibilityValue:loading ? CYLocalize(@"Refreshing") : nil];
    [activity_ setColor:[self tintColor]];
    if (loading)
        [activity_ startAnimating];
    else
        [activity_ stopAnimating];
}
@end

@implementation CydiaModernSheetController
#include "InterfaceOrientation.h"
- (UIStatusBarStyle) preferredStatusBarStyle {
    return [[self traitCollection] userInterfaceStyle] == UIUserInterfaceStyleDark ? UIStatusBarStyleLightContent : UIStatusBarStyleDarkContent;
}
- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self setNeedsStatusBarAppearanceUpdate];
}
@end

@implementation CydiaModernNavigationController
#include "InterfaceOrientation.h"
- (id) initWithRootViewController:(UIViewController *)root {
    if ((self = [super initWithRootViewController:root]) != nil)
        [self setModalPresentationCapturesStatusBarAppearance:YES];
    return self;
}
- (UIViewController *) childViewControllerForStatusBarStyle { return nil; }
- (UIStatusBarStyle) preferredStatusBarStyle {
    return [[self traitCollection] userInterfaceStyle] == UIUserInterfaceStyleDark ? UIStatusBarStyleLightContent : UIStatusBarStyleDarkContent;
}
- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self setNeedsStatusBarAppearanceUpdate];
}
@end

UIColor *CYModernAccentColor(void) {
    // Upstream Cydia leaves navigation and action tint to UIKit. Use the same
    // system blue, including its dark-appearance and increased-contrast variants.
    return [UIColor systemBlueColor];
}

UIColor *CYModernPrimaryButtonColor(void) {
    return [UIColor systemBlueColor];
}

static NSDictionary *CYTitleAttributes(UIColor *color, UIFontTextStyle style) {
    UIFont *font([UIFont preferredFontForTextStyle:style]);
    return [NSDictionary dictionaryWithObjectsAndKeys:
        color, NSForegroundColorAttributeName,
        font, NSFontAttributeName,
    nil];
}

static UINavigationBarAppearance *CYNavigationAppearance(BOOL dark) {
    UINavigationBarAppearance *appearance([[[UINavigationBarAppearance alloc] init] autorelease]);
    [appearance configureWithDefaultBackground];

    UIColor *background(dark ? [UIColor blackColor] : [UIColor systemBackgroundColor]);
    UIColor *foreground(dark ? [UIColor whiteColor] : [UIColor labelColor]);

    [appearance setBackgroundColor:[background colorWithAlphaComponent:0.88f]];
    [appearance setBackgroundEffect:[UIBlurEffect effectWithStyle:
        dark ? UIBlurEffectStyleSystemChromeMaterialDark : UIBlurEffectStyleSystemChromeMaterial]];
    [appearance setShadowColor:[UIColor separatorColor]];
    [appearance setTitleTextAttributes:CYTitleAttributes(foreground, UIFontTextStyleHeadline)];
    [appearance setLargeTitleTextAttributes:CYTitleAttributes(foreground, UIFontTextStyleLargeTitle)];
    return appearance;
}

static char CYNavigationAppearanceKey;
static BOOL CYNavigationAppearanceNeedsUpdate(UINavigationBar *bar, BOOL dark) {
    NSString *key = [NSString stringWithFormat:@"%d:%@", dark, bar.traitCollection.preferredContentSizeCategory];
    if ([objc_getAssociatedObject(bar, &CYNavigationAppearanceKey) isEqual:key]) return NO;
    objc_setAssociatedObject(bar, &CYNavigationAppearanceKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
    return YES;
}

void CYModernizeNavigationController(UINavigationController *navigation) {
    if (navigation == nil)
        return;

    [navigation setModalPresentationCapturesStatusBarAppearance:YES];

    UINavigationBar *bar([navigation navigationBar]);
    // Dynamic colors already follow sheet elevation and dark mode. Replacing
    // the blur appearance on every willAppear/willDisappear causes a flash.
    if (!CYNavigationAppearanceNeedsUpdate(bar, NO)) return;
    UINavigationBarAppearance *appearance(CYNavigationAppearance(NO));
    [bar setStandardAppearance:appearance];
    [bar setCompactAppearance:appearance];
    [bar setScrollEdgeAppearance:appearance];
    [bar setCompactScrollEdgeAppearance:appearance];
    [bar setPrefersLargeTitles:YES];
    [bar setTintColor:CYModernAccentColor()];
    [bar setBarStyle:UIBarStyleDefault];
    [bar setTitleTextAttributes:nil];

    [[navigation toolbar] setTintColor:CYModernAccentColor()];
}

void CYModernizeDarkNavigationController(UINavigationController *navigation) {
    if (navigation == nil)
        return;

    UINavigationBar *bar([navigation navigationBar]);
    if (!CYNavigationAppearanceNeedsUpdate(bar, YES)) return;
    UINavigationBarAppearance *appearance(CYNavigationAppearance(YES));
    [bar setStandardAppearance:appearance];
    [bar setCompactAppearance:appearance];
    [bar setScrollEdgeAppearance:appearance];
    [bar setCompactScrollEdgeAppearance:appearance];
    [bar setTintColor:CYModernAccentColor()];
    [bar setBarStyle:UIBarStyleBlack];
}

void CYApplyModernAppearance(void) {
    UINavigationBar *navigation([UINavigationBar appearance]);
    UINavigationBarAppearance *navigationAppearance(CYNavigationAppearance(NO));
    [navigation setStandardAppearance:navigationAppearance];
    [navigation setCompactAppearance:navigationAppearance];
    [navigation setScrollEdgeAppearance:navigationAppearance];
    [navigation setCompactScrollEdgeAppearance:navigationAppearance];
    [navigation setTintColor:CYModernAccentColor()];

    UITabBarAppearance *tabAppearance([[[UITabBarAppearance alloc] init] autorelease]);
    [tabAppearance configureWithDefaultBackground];
    [tabAppearance setBackgroundColor:[[UIColor systemBackgroundColor] colorWithAlphaComponent:0.88f]];
    [tabAppearance setBackgroundEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    [tabAppearance setShadowColor:[UIColor separatorColor]];

    UITabBarItemAppearance *items([tabAppearance stackedLayoutAppearance]);
    [[items normal] setIconColor:[UIColor secondaryLabelColor]];
    [[items normal] setTitleTextAttributes:[NSDictionary dictionaryWithObject:[UIColor secondaryLabelColor]
        forKey:NSForegroundColorAttributeName]];
    [[items selected] setIconColor:CYModernAccentColor()];
    [[items selected] setTitleTextAttributes:[NSDictionary dictionaryWithObject:CYModernAccentColor()
        forKey:NSForegroundColorAttributeName]];

    [tabAppearance setInlineLayoutAppearance:items];
    [tabAppearance setCompactInlineLayoutAppearance:items];

    UITabBar *tab([UITabBar appearance]);
    [tab setStandardAppearance:tabAppearance];
    [tab setScrollEdgeAppearance:tabAppearance];
    [tab setTintColor:CYModernAccentColor()];
    [tab setUnselectedItemTintColor:[UIColor secondaryLabelColor]];

    [[UIBarButtonItem appearance] setTintColor:CYModernAccentColor()];
    [[UISwitch appearance] setOnTintColor:CYModernAccentColor()];
    [[UIProgressView appearance] setProgressTintColor:CYModernAccentColor()];
}

void CYModernizeTableView(UITableView *table) {
    if (table == nil)
        return;

    [table setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
    [table setSeparatorColor:[UIColor separatorColor]];
    [table setSectionIndexColor:CYModernAccentColor()];
    [table setSectionIndexBackgroundColor:[UIColor clearColor]];
    [table setKeyboardDismissMode:UIScrollViewKeyboardDismissModeInteractive];
    [table setCellLayoutMarginsFollowReadableWidth:YES];
    [table setSectionHeaderTopPadding:8.0f];
}

UITableViewStyle CYModernGroupedTableStyle(void) {
    return UITableViewStyleInsetGrouped;
}

UIBarButtonItem *CYModernBarButtonItem(NSString *symbol, NSString *label,
    UIBarButtonItemStyle style, id target, SEL action) {
    UIBarButtonItem *item([[[UIBarButtonItem alloc] initWithImage:[UIImage cy_symbolNamed:symbol]
        style:style target:target action:action] autorelease]);
    [item setAccessibilityLabel:label];
    return item;
}

UIImage *CYModernTabImage(NSString *identifier, BOOL selected) {
    NSString *symbol(nil);

    if ([identifier isEqualToString:@"home"])
        symbol = selected ? @"star.fill" : @"star";
    else if ([identifier isEqualToString:@"sources"])
        symbol = selected ? @"square.stack.3d.up.fill" : @"square.stack.3d.up";
    else if ([identifier isEqualToString:@"changes"])
        symbol = @"clock.arrow.circlepath";
    else if ([identifier isEqualToString:@"installed"])
        symbol = selected ? @"shippingbox.fill" : @"shippingbox";
    else if ([identifier isEqualToString:@"search"])
        symbol = @"magnifyingglass";

    return symbol == nil ? nil : [UIImage cy_symbolNamed:symbol];
}

UIColor *CYModernCellBackgroundColor(void) {
    return [UIColor systemBackgroundColor];
}

UIColor *CYModernLabelColor(void) {
    return [UIColor labelColor];
}

UIColor *CYModernSecondaryLabelColor(void) {
    return [UIColor secondaryLabelColor];
}

UIColor *CYModernCommercialColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        // Upstream Purple_ is RGB(0, 0, 0.7), a deep blue rather than purple.
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ?
            [[UIColor systemBlueColor] resolvedColorWithTraitCollection:traits] :
            [UIColor colorWithRed:0.0 green:0.0 blue:0.7 alpha:1.0];
    }];
}

UIColor *CYModernPackageDescriptionColor(BOOL commercial) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [[UIColor secondaryLabelColor] resolvedColorWithTraitCollection:traits];
        // Upstream uses Purplish_ for commercial descriptions and Gray_ otherwise.
        return commercial ? [UIColor colorWithRed:0.4 green:0.4 blue:0.8 alpha:1.0] :
            [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0];
    }];
}

UIColor *CYModernQueuedColor(BOOL removing) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
            UIColor *color(removing ? [UIColor systemRedColor] : [UIColor systemGreenColor]);
            return [[color resolvedColorWithTraitCollection:traits] colorWithAlphaComponent:0.16f];
        }
        // Preserve upstream InstallingColor_ and RemovingColor_ exactly in light mode.
        return removing ? [UIColor colorWithRed:1.0 green:0.88 blue:0.88 alpha:1.0] :
            [UIColor colorWithRed:0.88 green:1.0 blue:0.88 alpha:1.0];
    }];
}
