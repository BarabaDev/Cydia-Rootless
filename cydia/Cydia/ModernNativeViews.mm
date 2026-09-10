/* Cydia 1.1.30 Rootless - complete native iOS 15+ transaction UI */

#include "Cydia/ModernLocalization.h"
#include "Cydia/ModernNativeViews.h"
#include "Cydia/TransactionPresentation.h"
#include "CyteKit/ModernAppearance.h"
#include "Version.h"
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>

static UILabel *CYM3Label(UIFontTextStyle style, UIColor *color, NSInteger lines) {
    UILabel *label([[[UILabel alloc] init] autorelease]);
    [label setFont:[UIFont preferredFontForTextStyle:style]];
    [label setTextColor:color];
    [label setNumberOfLines:lines];
    [label setAdjustsFontForContentSizeCategory:YES];
    return label;
}

static UIVisualEffectView *CYM3Card(UIBlurEffectStyle style, CGFloat radius) {
    UIVisualEffectView *card([[[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:style]] autorelease]);
    [card setTranslatesAutoresizingMaskIntoConstraints:NO];
    [[card layer] setCornerRadius:radius];
    [[card layer] setCornerCurve:kCACornerCurveContinuous];
    [[card layer] setMasksToBounds:YES];
    [[card layer] setBorderWidth:1.0f / [[UIScreen mainScreen] scale]];
    [[card layer] setBorderColor:[[[UIColor separatorColor] colorWithAlphaComponent:0.32f] CGColor]];
    return card;
}

static UIVisualEffectView *CYM3ContentCard(CGFloat radius) {
    UIVisualEffectView *card(CYM3Card(UIBlurEffectStyleSystemMaterial, radius));
    [card setEffect:nil];
    [card setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];
    [[card layer] setBorderWidth:0.0f];
    return card;
}

@interface CYM3GlassPanel : UIVisualEffectView
@end
@implementation CYM3GlassPanel
- (id) initWithEffect:(UIVisualEffect *)effect {
    if ((self = [super initWithEffect:effect]) != nil) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshMaterial)
            name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshMaterial)
            name:UIAccessibilityDarkerSystemColorsStatusDidChangeNotification object:nil];
        [self refreshMaterial];
    }
    return self;
}
- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}
- (void) refreshMaterial {
    BOOL opaque(UIAccessibilityIsReduceTransparencyEnabled() || UIAccessibilityDarkerSystemColorsEnabled());
    if (opaque)
        [self setEffect:nil];
    else {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 260000
        if (@available(iOS 26.0, *))
            [self setEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
        else
#endif
            [self setEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    }
    [self setBackgroundColor:opaque ? [UIColor secondarySystemGroupedBackgroundColor] : [UIColor clearColor]];
    UIColor *edge([[self traitCollection] userInterfaceStyle] == UIUserInterfaceStyleDark ?
        [[UIColor whiteColor] colorWithAlphaComponent:0.12f] : [[UIColor whiteColor] colorWithAlphaComponent:0.65f]);
    [[self layer] setBorderColor:[edge CGColor]];
}
- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([[self traitCollection] hasDifferentColorAppearanceComparedToTraitCollection:previous])
        [self refreshMaterial];
}
@end

static UIVisualEffectView *CYM3FloatingPanel(void) {
    CYM3GlassPanel *panel([[[CYM3GlassPanel alloc] initWithEffect:nil] autorelease]);
    [panel setTranslatesAutoresizingMaskIntoConstraints:NO];
    [[panel layer] setCornerRadius:26.0f];
    [[panel layer] setCornerCurve:kCACornerCurveContinuous];
    [[panel layer] setMasksToBounds:YES];
    [[panel layer] setBorderWidth:1.0f / [[UIScreen mainScreen] scale]];
    return panel;
}

@interface CYM3AdaptiveButton : UIButton {
    BOOL adaptsFilledForeground_;
}
@property(nonatomic) BOOL adaptsFilledForeground;
@end
@implementation CYM3AdaptiveButton
@synthesize adaptsFilledForeground = adaptsFilledForeground_;
- (void) setBackgroundColor:(UIColor *)background {
    [super setBackgroundColor:background];
    if (!adaptsFilledForeground_ || background == nil) return;
    // Keep the standard Cydia/iOS foreground. Increased Contrast may brighten
    // system blue in dark mode, so choose readable text against that exact fill.
    UIColor *foreground([UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (traits.accessibilityContrast != UIAccessibilityContrastHigh) return [UIColor whiteColor];
        CGFloat red=0, green=0, blue=0, alpha=0;
        if (![[background resolvedColorWithTraitCollection:traits] getRed:&red green:&green blue:&blue alpha:&alpha] || alpha < 0.99)
            return [UIColor whiteColor];
        CGFloat (^linear)(CGFloat)=^CGFloat(CGFloat value) {
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
        };
        CGFloat luminance=0.2126*linear(red)+0.7152*linear(green)+0.0722*linear(blue);
        return luminance > 0.179 ? [UIColor blackColor] : [UIColor whiteColor];
    }]);
    [self setTitleColor:foreground forState:UIControlStateNormal];
}
- (CGSize) intrinsicContentSize {
    CGSize size([super intrinsicContentSize]);
    CGFloat imageWidth([self currentImage] == nil ? 0.0f : MAX([self currentImage].size.width, CGRectGetWidth([[self imageView] bounds])));
    CGFloat width(CGRectGetWidth([self bounds]) - [self contentEdgeInsets].left - [self contentEdgeInsets].right - imageWidth);
    if (width > 0.0f) {
        CGSize text([[self titleLabel] sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)]);
        size.height = MAX(size.height, ceil(text.height) + [self contentEdgeInsets].top + [self contentEdgeInsets].bottom);
    }
    return size;
}
- (void) layoutSubviews {
    CGFloat previous([[self titleLabel] preferredMaxLayoutWidth]);
    CGFloat imageWidth([self currentImage] == nil ? 0.0f : MAX([self currentImage].size.width, CGRectGetWidth([[self imageView] bounds])));
    CGFloat width(MAX(0.0f, CGRectGetWidth([self bounds]) - [self contentEdgeInsets].left - [self contentEdgeInsets].right - imageWidth));
    [[self titleLabel] setPreferredMaxLayoutWidth:width];
    if (fabs(previous - width) > 0.5f)
        [self invalidateIntrinsicContentSize];
    [super layoutSubviews];
    [[self layer] setCornerRadius:MIN(28.0f, CGRectGetHeight([self bounds]) / 2.0f)];
}
@end

static UIButton *CYM3FilledButton(void) {
    UIButton *button([CYM3AdaptiveButton buttonWithType:UIButtonTypeSystem]);
    [button setTranslatesAutoresizingMaskIntoConstraints:NO];
    [[button titleLabel] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
    [[button titleLabel] setAdjustsFontForContentSizeCategory:YES];
    [[button titleLabel] setNumberOfLines:0];
    [[button titleLabel] setTextAlignment:NSTextAlignmentCenter];
    [button setContentEdgeInsets:UIEdgeInsetsMake(10.0f, 14.0f, 10.0f, 14.0f)];
    [button setContentHorizontalAlignment:UIControlContentHorizontalAlignmentCenter];
    [button setContentVerticalAlignment:UIControlContentVerticalAlignmentCenter];
    [button setTitleEdgeInsets:UIEdgeInsetsZero];
    [button setImageEdgeInsets:UIEdgeInsetsZero];
    [(CYM3AdaptiveButton *)button setAdaptsFilledForeground:YES];
    [button setBackgroundColor:CYModernPrimaryButtonColor()];
    [[button layer] setCornerRadius:14.0f];
    [[button layer] setCornerCurve:kCACornerCurveContinuous];
    return button;
}

@implementation CydiaModernPrivacyConsentView

- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
        [self setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
        [self setAccessibilityViewIsModal:YES];

        UIScrollView *scroll([[[UIScrollView alloc] init] autorelease]);
        [scroll setTranslatesAutoresizingMaskIntoConstraints:NO];
        [scroll setAlwaysBounceVertical:YES];
        [scroll setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentNever];
        [scroll setKeyboardDismissMode:UIScrollViewKeyboardDismissModeInteractive];
        [self addSubview:scroll];

        UIView *content([[[UIView alloc] init] autorelease]);
        [content setTranslatesAutoresizingMaskIntoConstraints:NO];
        [scroll addSubview:content];

        UIImageView *appIcon([[[CydiaSymbolView alloc] initWithImage:[UIImage imageNamed:@"Icon-60"]] autorelease]);
        [appIcon setTranslatesAutoresizingMaskIntoConstraints:NO];
        [appIcon setContentMode:UIViewContentModeScaleAspectFit];
        [[appIcon layer] setCornerRadius:17.0f];
        [[appIcon layer] setCornerCurve:kCACornerCurveContinuous];
        [[appIcon layer] setMasksToBounds:YES];
        [appIcon setAccessibilityLabel:@"Cydia"];

        UILabel *eyebrow(CYM3Label(UIFontTextStyleCaption1, CYModernAccentColor(), 1));
        [eyebrow setText:CYLocalize(@"FIRST LAUNCH")];
        [eyebrow setTextAlignment:NSTextAlignmentCenter];
        [eyebrow setFont:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
            scaledFontForFont:[UIFont systemFontOfSize:12.0f weight:UIFontWeightBold]]];

        UILabel *title(CYM3Label(UIFontTextStyleTitle1, [UIColor labelColor], 0));
        [title setText:CYLocalize(@"Cydia Privacy")];
        [title setTextAlignment:NSTextAlignmentCenter];

        UILabel *summary(CYM3Label(UIFontTextStyleBody, [UIColor secondaryLabelColor], 0));
        [summary setText:CYLocalize(@"Review how Cydia connects to sources and stores your data.")];
        [summary setTextAlignment:NSTextAlignmentCenter];

        UIStackView *header([[[UIStackView alloc] initWithArrangedSubviews:
            [NSArray arrayWithObjects:appIcon, eyebrow, title, summary, nil]] autorelease]);
        [header setAxis:UILayoutConstraintAxisVertical];
        [header setAlignment:UIStackViewAlignmentCenter];
        [header setSpacing:7.0f];
        [header setCustomSpacing:15.0f afterView:appIcon];

        UIVisualEffectView *notice(CYM3ContentCard(24.0f));
        UIImageView *noticeIcon([[[CydiaSymbolView alloc]
            initWithImage:[UIImage cy_symbolNamed:@"lock.shield.fill"]] autorelease]);
        [noticeIcon setTranslatesAutoresizingMaskIntoConstraints:NO];
        [noticeIcon setTintColor:CYModernAccentColor()];
        [noticeIcon setPreferredSymbolConfiguration:[UIImageSymbolConfiguration
            configurationWithPointSize:25.0f weight:UIImageSymbolWeightSemibold]];

        UILabel *noticeTitle(CYM3Label(UIFontTextStyleHeadline, [UIColor labelColor], 0));
        [noticeTitle setText:CYLocalize(@"Repository connections")];
        UILabel *noticeText(CYM3Label(UIFontTextStyleSubheadline, [UIColor secondaryLabelColor], 0));
        [noticeText setText:CYLocalize(@"Cydia connects to your sources for package lists and downloads. Sources receive network information and may receive device details for compatibility, accounts, and purchases.")];

        UIStackView *noticeCopy([[[UIStackView alloc] initWithArrangedSubviews:
            [NSArray arrayWithObjects:noticeTitle, noticeText, nil]] autorelease]);
        [noticeCopy setAxis:UILayoutConstraintAxisVertical];
        [noticeCopy setSpacing:4.0f];

        UIStackView *noticeContent([[[UIStackView alloc] initWithArrangedSubviews:
            [NSArray arrayWithObjects:noticeIcon, noticeCopy, nil]] autorelease]);
        [noticeContent setTranslatesAutoresizingMaskIntoConstraints:NO];
        [noticeContent setAxis:UILayoutConstraintAxisHorizontal];
        [noticeContent setAlignment:UIStackViewAlignmentTop];
        [noticeContent setSpacing:13.0f];
        [[notice contentView] addSubview:noticeContent];

        privacyButton_ = [UIButton buttonWithType:UIButtonTypeSystem];
        [privacyButton_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [[privacyButton_ titleLabel] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
        [[privacyButton_ titleLabel] setAdjustsFontForContentSizeCategory:YES];
        [[privacyButton_ titleLabel] setNumberOfLines:0];
        [[privacyButton_ titleLabel] setTextAlignment:NSTextAlignmentCenter];
        [privacyButton_ setTitle:CYLocalize(@"View privacy information") forState:UIControlStateNormal];
        [privacyButton_ setContentEdgeInsets:UIEdgeInsetsMake(10.0f, 12.0f, 10.0f, 12.0f)];
        [privacyButton_ addTarget:self action:@selector(togglePrivacyDetails) forControlEvents:UIControlEventTouchUpInside];

        privacyDetails_ = [[[UIStackView alloc] init] autorelease];
        [privacyDetails_ setAxis:UILayoutConstraintAxisVertical];
        [privacyDetails_ setSpacing:6.0f];
        NSArray *privacySections(@[
            @[CYLocalize(@"On this device"), CYLocalize(@"Your source list, package metadata cache, preferences, repository account credentials, and this acceptance are stored locally. Account credentials are protected by the device Keychain.")],
            @[CYLocalize(@"Shared with sources"), CYLocalize(@"Repository requests can include your IP address, iOS and device model information, and a device identifier header. Paid repositories may use this information to authenticate an account, confirm ownership, or authorize a download.")],
            @[CYLocalize(@"Your choice"), CYLocalize(@"This acceptance is stored only on this device and is not sent to a server. Cydia does not add an advertising or analytics service. Each third-party repository is responsible for its own content and privacy practices.")]
        ]);
        for (NSArray *section in privacySections) {
            UILabel *heading(CYM3Label(UIFontTextStyleSubheadline, [UIColor labelColor], 0));
            [heading setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
            [heading setText:[section firstObject]];
            [heading setAccessibilityTraits:UIAccessibilityTraitHeader];
            UILabel *body(CYM3Label(UIFontTextStyleFootnote, [UIColor secondaryLabelColor], 0));
            [body setText:[section lastObject]];
            [privacyDetails_ addArrangedSubview:heading];
            [privacyDetails_ addArrangedSubview:body];
            [privacyDetails_ setCustomSpacing:18.0f afterView:body];
        }
        [privacyDetails_ setHidden:YES];
        [privacyDetails_ setAccessibilityIdentifier:@"CydiaPrivacyDetails"];

        persistenceError_ = CYM3Label(UIFontTextStyleFootnote, [UIColor systemRedColor], 0);
        [persistenceError_ setTextAlignment:NSTextAlignmentCenter];
        [persistenceError_ setHidden:YES];
        [persistenceError_ setAccessibilityIdentifier:@"CydiaPrivacyPersistenceError"];

        UIButton *decline([UIButton buttonWithType:UIButtonTypeSystem]);
        [decline setTranslatesAutoresizingMaskIntoConstraints:NO];
        [[decline titleLabel] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
        [[decline titleLabel] setAdjustsFontForContentSizeCategory:YES];
        [[decline titleLabel] setNumberOfLines:0];
        [decline setTitle:CYLocalize(@"Decline") forState:UIControlStateNormal];
        [decline setContentEdgeInsets:UIEdgeInsetsMake(10.0f, 14.0f, 10.0f, 14.0f)];
        [decline addTarget:self action:@selector(declineClicked) forControlEvents:UIControlEventTouchUpInside];
        [decline setAccessibilityHint:CYLocalize(@"Closes Cydia without saving acceptance.")];

        UIButton *accept(CYM3FilledButton());
        [accept setTitle:CYLocalize(@"Accept") forState:UIControlStateNormal];
        [accept addTarget:self action:@selector(acceptClicked) forControlEvents:UIControlEventTouchUpInside];
        [accept setAccessibilityHint:CYLocalize(@"Saves this choice on this device and continues to Cydia.")];

        UIStackView *actions([[[UIStackView alloc] initWithArrangedSubviews:
            [NSArray arrayWithObjects:decline, accept, nil]] autorelease]);
        [actions setAxis:UILayoutConstraintAxisVertical];
        [actions setSpacing:7.0f];

        UIStackView *stack([[[UIStackView alloc] initWithArrangedSubviews:
            [NSArray arrayWithObjects:header, notice, privacyButton_, privacyDetails_, persistenceError_, actions, nil]] autorelease]);
        [stack setTranslatesAutoresizingMaskIntoConstraints:NO];
        [stack setAxis:UILayoutConstraintAxisVertical];
        [stack setAlignment:UIStackViewAlignmentFill];
        [stack setSpacing:14.0f];
        [stack setCustomSpacing:20.0f afterView:header];
        [stack setCustomSpacing:7.0f afterView:privacyButton_];
        [content addSubview:stack];

        UILayoutGuide *frameGuide([scroll frameLayoutGuide]);
        UILayoutGuide *contentGuide([scroll contentLayoutGuide]);
        [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
            [[scroll leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
            [[scroll trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
            [[scroll topAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] topAnchor]],
            [[scroll bottomAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] bottomAnchor]],
            [[content leadingAnchor] constraintEqualToAnchor:[contentGuide leadingAnchor]],
            [[content trailingAnchor] constraintEqualToAnchor:[contentGuide trailingAnchor]],
            [[content topAnchor] constraintEqualToAnchor:[contentGuide topAnchor]],
            [[content bottomAnchor] constraintEqualToAnchor:[contentGuide bottomAnchor]],
            [[content widthAnchor] constraintEqualToAnchor:[frameGuide widthAnchor]],
            [[stack leadingAnchor] constraintGreaterThanOrEqualToAnchor:[content leadingAnchor] constant:24.0f],
            [[stack trailingAnchor] constraintLessThanOrEqualToAnchor:[content trailingAnchor] constant:-24.0f],
            [[stack topAnchor] constraintEqualToAnchor:[content topAnchor] constant:30.0f],
            [[stack bottomAnchor] constraintEqualToAnchor:[content bottomAnchor] constant:-30.0f],
            [[stack widthAnchor] constraintLessThanOrEqualToConstant:620.0f],
            [[appIcon widthAnchor] constraintEqualToConstant:72.0f],
            [[appIcon heightAnchor] constraintEqualToConstant:72.0f],
            [[noticeContent leadingAnchor] constraintEqualToAnchor:[[notice contentView] leadingAnchor] constant:16.0f],
            [[noticeContent trailingAnchor] constraintEqualToAnchor:[[notice contentView] trailingAnchor] constant:-16.0f],
            [[noticeContent topAnchor] constraintEqualToAnchor:[[notice contentView] topAnchor] constant:16.0f],
            [[noticeContent bottomAnchor] constraintEqualToAnchor:[[notice contentView] bottomAnchor] constant:-16.0f],
            [[noticeIcon widthAnchor] constraintEqualToConstant:30.0f],
            [[noticeIcon heightAnchor] constraintEqualToConstant:30.0f],
            [[decline heightAnchor] constraintGreaterThanOrEqualToConstant:50.0f],
            [[accept heightAnchor] constraintGreaterThanOrEqualToConstant:54.0f],
        nil]];

        NSLayoutConstraint *center([[stack centerXAnchor] constraintEqualToAnchor:[content centerXAnchor]]);
        [center setPriority:UILayoutPriorityRequired];
        [center setActive:YES];
        NSLayoutConstraint *preferredWidth([[stack widthAnchor] constraintEqualToAnchor:[content widthAnchor] constant:-48.0f]);
        [preferredWidth setPriority:UILayoutPriorityDefaultHigh];
        [preferredWidth setActive:YES];
    }
    return self;
}

- (void) configureWithTarget:(id)target acceptAction:(SEL)acceptAction declineAction:(SEL)declineAction {
    actionTarget_ = target;
    acceptAction_ = acceptAction;
    declineAction_ = declineAction;
}

- (void) togglePrivacyDetails {
    detailsExpanded_ = !detailsExpanded_;
    [privacyDetails_ setHidden:!detailsExpanded_];
    [privacyButton_ setTitle:(detailsExpanded_ ? CYLocalize(@"Hide privacy information") : CYLocalize(@"View privacy information"))
        forState:UIControlStateNormal];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,
        detailsExpanded_ ? (id)privacyDetails_ : (id)privacyButton_);
}

- (void) showPersistenceError:(NSString *)message {
    [persistenceError_ setText:message];
    [persistenceError_ setHidden:[message length] == 0];
    if ([message length] != 0)
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
}

- (void) acceptClicked {
    if (actionTarget_ != nil && acceptAction_ != NULL)
        [actionTarget_ performSelector:acceptAction_ withObject:nil];
}

- (void) declineClicked {
    if (actionTarget_ != nil && declineAction_ != NULL)
        [actionTarget_ performSelector:declineAction_ withObject:nil];
}

@end

static UIVisualEffectView *CYM3AboutRow(NSString *symbol, UIColor *color, NSString *title, NSString *detail) {
    UIVisualEffectView *row(CYM3Card(UIBlurEffectStyleSystemThinMaterial, 18.0f));

    UIView *iconTile([[[UIView alloc] init] autorelease]);
    [iconTile setTranslatesAutoresizingMaskIntoConstraints:NO];
    [iconTile setBackgroundColor:[color colorWithAlphaComponent:0.13f]];
    [[iconTile layer] setCornerRadius:12.0f];
    [[iconTile layer] setCornerCurve:kCACornerCurveContinuous];

    UIImageView *icon([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:symbol]] autorelease]);
    [icon setTranslatesAutoresizingMaskIntoConstraints:NO];
    [icon setTintColor:color];
    [icon setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20.0f weight:UIImageSymbolWeightSemibold]];
    [iconTile addSubview:icon];

    UILabel *titleLabel(CYM3Label(UIFontTextStyleHeadline, [UIColor labelColor], 0));
    [titleLabel setText:title];
    UILabel *detailLabel(CYM3Label(UIFontTextStyleFootnote, [UIColor secondaryLabelColor], 0));
    [detailLabel setText:detail];

    UIStackView *labels([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:titleLabel, detailLabel, nil]] autorelease]);
    [labels setAxis:UILayoutConstraintAxisVertical];
    [labels setSpacing:2.0f];

    UIStackView *content([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:iconTile, labels, nil]] autorelease]);
    [content setTranslatesAutoresizingMaskIntoConstraints:NO];
    [content setAxis:UILayoutConstraintAxisHorizontal];
    [content setAlignment:UIStackViewAlignmentCenter];
    [content setSpacing:12.0f];
    [[row contentView] addSubview:content];

    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [[row heightAnchor] constraintGreaterThanOrEqualToConstant:58.0f],
        [[content leadingAnchor] constraintEqualToAnchor:[[row contentView] leadingAnchor] constant:13.0f],
        [[content trailingAnchor] constraintEqualToAnchor:[[row contentView] trailingAnchor] constant:-13.0f],
        [[content topAnchor] constraintEqualToAnchor:[[row contentView] topAnchor] constant:7.0f],
        [[content bottomAnchor] constraintEqualToAnchor:[[row contentView] bottomAnchor] constant:-7.0f],
        [[iconTile widthAnchor] constraintEqualToConstant:40.0f],
        [[iconTile heightAnchor] constraintEqualToConstant:40.0f],
        [[icon centerXAnchor] constraintEqualToAnchor:[iconTile centerXAnchor]],
        [[icon centerYAnchor] constraintEqualToAnchor:[iconTile centerYAnchor]],
    nil]];

    return row;
}

static NSAttributedString *CYM3LegalText(NSString *visible) {
    UIFont *baseFont([[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
        scaledFontForFont:[UIFont monospacedSystemFontOfSize:14.0f weight:UIFontWeightMedium]]);
    UIFont *strongFont([[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
        scaledFontForFont:[UIFont monospacedSystemFontOfSize:14.0f weight:UIFontWeightSemibold]]);
    NSMutableParagraphStyle *paragraph([[[NSMutableParagraphStyle alloc] init] autorelease]);
    [paragraph setLineSpacing:3.0f];
    [paragraph setParagraphSpacing:2.0f];
    [paragraph setAlignment:NSTextAlignmentLeft];

    NSMutableAttributedString *result([[[NSMutableAttributedString alloc] initWithString:visible
        attributes:[NSDictionary dictionaryWithObjectsAndKeys:
            baseFont, NSFontAttributeName,
            [UIColor secondaryLabelColor], NSForegroundColorAttributeName,
            paragraph, NSParagraphStyleAttributeName,
        nil]] autorelease]);

    NSArray *strongTokens([NSArray arrayWithObjects:@"BarabaDev", @"GNU GPL v3 or later", nil]);
    for (NSString *token in strongTokens) {
        NSRange range([visible rangeOfString:token]);
        if (range.location != NSNotFound) {
            [result addAttribute:NSFontAttributeName value:strongFont range:range];
            [result addAttribute:NSForegroundColorAttributeName value:[UIColor labelColor] range:range];
        }
    }

    NSString *sourceToken(@"github.com/BarabaDev/Cydia-Rootless");
    NSArray *blueTokens([NSArray arrayWithObjects:@"Modern Rootless", sourceToken, nil]);
    for (NSString *token in blueTokens) {
        NSRange range([visible rangeOfString:token]);
        if (range.location != NSNotFound) {
            [result addAttribute:NSFontAttributeName value:strongFont range:range];
            [result addAttribute:NSForegroundColorAttributeName value:CYModernAccentColor() range:range];
        }
    }

    NSRange sourceRange([visible rangeOfString:sourceToken]);
    if (sourceRange.location != NSNotFound)
        [result addAttribute:NSLinkAttributeName
            value:[NSURL URLWithString:@"https://github.com/BarabaDev/Cydia-Rootless"]
            range:sourceRange];

    return result;
}

@implementation CydiaModernAboutViewController
- (UIStatusBarStyle) preferredStatusBarStyle {
    return [[self traitCollection] userInterfaceStyle] == UIUserInterfaceStyleDark ? UIStatusBarStyleLightContent : UIStatusBarStyleDarkContent;
}

#include "CyteKit/InterfaceOrientation.h"

- (void)openLicense {
    CydiaModernSheetController *page = [[[CydiaModernSheetController alloc] init] autorelease];
    page.title = CYLocalize(@"Credits & license");
    page.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    UITextView *text = [[[UITextView alloc] initWithFrame:CGRectZero] autorelease];
    text.editable = NO; text.selectable = YES;
    text.backgroundColor = [UIColor systemBackgroundColor];
    text.textColor = [UIColor labelColor];
    text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    text.adjustsFontForContentSizeCategory = YES;
    text.textContainerInset = UIEdgeInsetsMake(20, 16, 20, 16);
    NSString *path = [[NSBundle mainBundle] pathForResource:@"COPYING" ofType:nil];
    NSString *gpl = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSMutableString *licenses = [NSMutableString stringWithString:gpl ?: @"GNU GPL v3 — https://www.gnu.org/licenses/gpl-3.0.html"];
    for (NSString *name in @[@"NOTICES", @"AGPL-3.0", @"GPL-2.0"]) {
        NSString *resource = [[NSBundle mainBundle] pathForResource:name ofType:@"txt" inDirectory:@"Licenses"];
        NSString *notice = resource == nil ? nil : [NSString stringWithContentsOfFile:resource encoding:NSUTF8StringEncoding error:nil];
        if (notice.length != 0)
            [licenses appendFormat:@"\n\n────────────────────────\n\n%@", notice];
    }
    text.text = licenses;
    page.view = text;
    page.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:CYLocalize(@"Done")
        style:UIBarButtonItemStyleDone target:self action:@selector(closeLicense)] autorelease];
    CydiaModernNavigationController *navigation = [[[CydiaModernNavigationController alloc] initWithRootViewController:page] autorelease];
    CYModernizeNavigationController(navigation);
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent largeDetent]];
    navigation.sheetPresentationController.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)closeLicense {
    [[self presentedViewController] dismissViewControllerAnimated:YES completion:nil];
}

- (void) viewDidLoad {
    [super viewDidLoad];
    [[self view] setBackgroundColor:[UIColor systemGroupedBackgroundColor]];

    UIImageView *appIcon([[[CydiaSymbolView alloc] initWithImage:[UIImage imageNamed:@"Icon-60"]] autorelease]);
    [appIcon setTranslatesAutoresizingMaskIntoConstraints:NO];
    [appIcon setContentMode:UIViewContentModeScaleAspectFit];
    [[appIcon layer] setCornerRadius:16.0f];
    [[appIcon layer] setCornerCurve:kCACornerCurveContinuous];
    [[appIcon layer] setMasksToBounds:YES];

    UILabel *title(CYM3Label(UIFontTextStyleTitle2, [UIColor labelColor], 0));
    [title setText:@"Cydia Installer"];
    [title setTextAlignment:NSTextAlignmentCenter];
    UILabel *subtitle(CYM3Label(UIFontTextStyleSubheadline, CYModernAccentColor(), 0));
    [subtitle setText:@"Modern Rootless"];
    [subtitle setTextAlignment:NSTextAlignmentCenter];

    UIStackView *header([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:appIcon, title, subtitle, nil]] autorelease]);
    [header setAxis:UILayoutConstraintAxisVertical];
    [header setAlignment:UIStackViewAlignmentCenter];
    [header setSpacing:5.0f];

    UIVisualEffectView *original(CYM3AboutRow(@"shippingbox.fill", CYModernAccentColor(), CYLocalize(@"Original Cydia"), @"Jay Freeman (saurik)  •  SaurikIT, LLC"));
    UIVisualEffectView *modifiedBase(CYM3AboutRow(@"wrench.and.screwdriver.fill", CYModernAccentColor(), CYLocalize(@"Modified Cydia"), @"Sam Bingner"));
    UIVisualEffectView *modern(CYM3AboutRow(@"person.crop.circle.fill", CYModernAccentColor(), CYLocalize(@"Modern Rootless edition"), @"BarabaDev  •  @barabadev  •  barabadev.com"));

    UIStackView *credits([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:original, modifiedBase, modern, nil]] autorelease]);
    [credits setAxis:UILayoutConstraintAxisVertical];
    [credits setSpacing:9.0f];

    legalCopy_ = [@"Modern Rootless • BarabaDev • 10 September 2026\n\nUnofficial modified edition.\nGNU GPL v3 or later; Cytore: GNU AGPL v3 or later. Component notices included.\nSource: github.com/BarabaDev/Cydia-Rootless" copy];

    UIView *legalIconTile([[[UIView alloc] init] autorelease]);
    [legalIconTile setTranslatesAutoresizingMaskIntoConstraints:NO];
    [legalIconTile setBackgroundColor:[CYModernAccentColor() colorWithAlphaComponent:0.13f]];
    [[legalIconTile layer] setCornerRadius:12.0f];
    [[legalIconTile layer] setCornerCurve:kCACornerCurveContinuous];
    UIImageView *legalIcon([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:@"chevron.left.forwardslash.chevron.right"]] autorelease]);
    [legalIcon setTranslatesAutoresizingMaskIntoConstraints:NO];
    [legalIcon setTintColor:CYModernAccentColor()];
    [legalIcon setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18.0f weight:UIImageSymbolWeightSemibold]];
    [legalIconTile addSubview:legalIcon];

    UILabel *legalEyebrow(CYM3Label(UIFontTextStyleCaption2, CYModernAccentColor(), 0));
    [legalEyebrow setText:CYLocalize(@"UNOFFICIAL • OPEN SOURCE")];
    [legalEyebrow setFont:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2]
        scaledFontForFont:[UIFont systemFontOfSize:11.0f weight:UIFontWeightBold]]];
    UILabel *legalTitle(CYM3Label(UIFontTextStyleHeadline, [UIColor labelColor], 0));
    [legalTitle setText:CYLocalize(@"Credits & license")];
    UIStackView *legalHeadings([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:legalEyebrow, legalTitle, nil]] autorelease]);
    [legalHeadings setAxis:UILayoutConstraintAxisVertical];
    [legalHeadings setSpacing:1.0f];

    UILabel *licenseBadge(CYM3Label(UIFontTextStyleCaption2, CYModernAccentColor(), 1));
    [licenseBadge setText:@"GPLv3+"];
    [licenseBadge setTextAlignment:NSTextAlignmentCenter];
    [licenseBadge setFont:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2]
        scaledFontForFont:[UIFont monospacedSystemFontOfSize:11.0f weight:UIFontWeightSemibold]]];
    [licenseBadge setBackgroundColor:[CYModernAccentColor() colorWithAlphaComponent:0.11f]];
    [[licenseBadge layer] setCornerRadius:10.0f];
    [[licenseBadge layer] setCornerCurve:kCACornerCurveContinuous];
    [licenseBadge setClipsToBounds:YES];

    UIStackView *legalHeader([[[UIStackView alloc] initWithArrangedSubviews:
        [NSArray arrayWithObjects:legalIconTile, legalHeadings, licenseBadge, nil]] autorelease]);
    [legalHeader setAxis:UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory) ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal];
    [legalHeader setAlignment:UIStackViewAlignmentCenter];
    [legalHeader setSpacing:11.0f];

    UIView *legalDivider([[[UIView alloc] init] autorelease]);
    [legalDivider setTranslatesAutoresizingMaskIntoConstraints:NO];
    [legalDivider setBackgroundColor:[[UIColor separatorColor] colorWithAlphaComponent:0.38f]];

    legalText_ = [[[UITextView alloc] init] autorelease];
    [legalText_ setTranslatesAutoresizingMaskIntoConstraints:NO];
    [legalText_ setDelegate:self];
    [legalText_ setEditable:NO];
    [legalText_ setSelectable:YES];
    [legalText_ setScrollEnabled:NO];
    [legalText_ setBackgroundColor:[UIColor clearColor]];
    [legalText_ setTextContainerInset:UIEdgeInsetsZero];
    [[legalText_ textContainer] setLineFragmentPadding:0.0f];
    [legalText_ setLinkTextAttributes:[NSDictionary dictionaryWithObjectsAndKeys:
        CYModernAccentColor(), NSForegroundColorAttributeName,
        [NSNumber numberWithInteger:NSUnderlineStyleSingle], NSUnderlineStyleAttributeName,
    nil]];
    [legalText_ setAccessibilityLabel:legalCopy_];
    [legalText_ setAccessibilityHint:CYLocalize(@"The source address opens GitHub in your browser")];

    UIButton *licenseButton = [CYM3AdaptiveButton buttonWithType:UIButtonTypeSystem];
    [licenseButton setTitle:CYLocalize(@"Credits & license") forState:UIControlStateNormal];
    [licenseButton setImage:[UIImage cy_symbolNamed:@"doc.text"] forState:UIControlStateNormal];
    [licenseButton.titleLabel setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
    [licenseButton.titleLabel setAdjustsFontForContentSizeCategory:YES];
    [licenseButton.titleLabel setNumberOfLines:0];
    [licenseButton.titleLabel setTextAlignment:NSTextAlignmentCenter];
    [licenseButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [licenseButton addTarget:self action:@selector(openLicense) forControlEvents:UIControlEventTouchUpInside];
    [legalText_ setAttributedText:CYM3LegalText(legalCopy_)];
    [legalText_ setAdjustsFontForContentSizeCategory:YES];

    UIStackView *legalContent([[[UIStackView alloc] initWithArrangedSubviews:
        [NSArray arrayWithObjects:legalHeader, legalDivider, legalText_, licenseButton, nil]] autorelease]);
    [legalContent setTranslatesAutoresizingMaskIntoConstraints:NO];
    [legalContent setAxis:UILayoutConstraintAxisVertical];
    [legalContent setAlignment:UIStackViewAlignmentFill];
    [legalContent setSpacing:12.0f];

    legalNotice_ = CYM3Card(UIBlurEffectStyleSystemThinMaterial, 18.0f);
    [[legalNotice_ contentView] addSubview:legalContent];
    // The license is visible immediately; no detent-change callback is required.

    closeButton_ = CYM3FilledButton();
    [closeButton_ setTitle:CYLocalize(@"Done") forState:UIControlStateNormal];
    [closeButton_ setAccessibilityHint:CYLocalize(@"Returns to Home")];
    [closeButton_ addTarget:self action:@selector(closeClicked) forControlEvents:UIControlEventTouchUpInside];
    [closeButton_ setBackgroundColor:CYModernPrimaryButtonColor()];
    [[closeButton_ layer] setCornerRadius:17.0f];

    UIScrollView *scroll = [[[UIScrollView alloc] init] autorelease];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [[self view] addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];

    UIStackView *content([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:header, credits, legalNotice_, closeButton_, nil]] autorelease]);
    [content setTranslatesAutoresizingMaskIntoConstraints:NO];
    [content setAxis:UILayoutConstraintAxisVertical];
    [content setSpacing:12.0f];
    [content setCustomSpacing:28.0f afterView:credits];
    [content setCustomSpacing:30.0f afterView:legalNotice_];
    [scroll addSubview:content];

    NSLayoutConstraint *legalMinimumHeight([[legalNotice_ heightAnchor] constraintGreaterThanOrEqualToConstant:188.0f]);
    [legalMinimumHeight setPriority:UILayoutPriorityRequired - 1.0f];
    NSLayoutConstraint *closeMinimumHeight([[closeButton_ heightAnchor] constraintGreaterThanOrEqualToConstant:48.0f]);
    [closeMinimumHeight setPriority:UILayoutPriorityRequired - 1.0f];

    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:18],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-18],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-36],
        [[appIcon widthAnchor] constraintEqualToConstant:58.0f],
        [[appIcon heightAnchor] constraintEqualToConstant:58.0f],
        [[title widthAnchor] constraintLessThanOrEqualToAnchor:[header widthAnchor]],
        [[subtitle widthAnchor] constraintLessThanOrEqualToAnchor:[header widthAnchor]],
        [[legalContent leadingAnchor] constraintEqualToAnchor:[[legalNotice_ contentView] leadingAnchor] constant:15.0f],
        [[legalContent trailingAnchor] constraintEqualToAnchor:[[legalNotice_ contentView] trailingAnchor] constant:-15.0f],
        [[legalContent topAnchor] constraintEqualToAnchor:[[legalNotice_ contentView] topAnchor] constant:12.0f],
        [[legalContent bottomAnchor] constraintEqualToAnchor:[[legalNotice_ contentView] bottomAnchor] constant:-12.0f],
        [[legalIconTile widthAnchor] constraintEqualToConstant:42.0f],
        [[legalIconTile heightAnchor] constraintEqualToConstant:42.0f],
        [[legalIcon centerXAnchor] constraintEqualToAnchor:[legalIconTile centerXAnchor]],
        [[legalIcon centerYAnchor] constraintEqualToAnchor:[legalIconTile centerYAnchor]],
        [[licenseBadge widthAnchor] constraintGreaterThanOrEqualToConstant:58.0f],
        [[licenseBadge heightAnchor] constraintGreaterThanOrEqualToConstant:30.0f],
        [[legalDivider heightAnchor] constraintEqualToConstant:1.0f / [[UIScreen mainScreen] scale]],
        legalMinimumHeight,
        closeMinimumHeight,
    nil]];
}

- (void) closeClicked {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL) textView:(UITextView *)textView shouldInteractWithURL:(NSURL *)URL
    inRange:(NSRange)characterRange interaction:(UITextItemInteraction)interaction {
    NSString *scheme([[URL scheme] lowercaseString]);
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"])
        return NO;
    [[UIApplication sharedApplication] openURL:URL options:[NSDictionary dictionary]
        completionHandler:nil];
    return NO;
}

- (void) dealloc {
    [legalCopy_ release];
    [super dealloc];
}

@end

static UIButton *CYM3ActionButton(NSString *title, NSString *subtitle, NSString *symbol, UIColor *color,
    NSInteger tag, UILabel **subtitleOutput) {
    UIButton *button([UIButton buttonWithType:UIButtonTypeSystem]);
    [button setTranslatesAutoresizingMaskIntoConstraints:NO];
    [button setTag:tag];
    [button setAccessibilityLabel:title];
    [button setAccessibilityHint:subtitle];
    [button setContentHorizontalAlignment:UIControlContentHorizontalAlignmentLeading];
    [button setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];
    [[button layer] setCornerRadius:20.0f];
    [[button layer] setCornerCurve:kCACornerCurveContinuous];
    [[button layer] setBorderWidth:1.0f / [[UIScreen mainScreen] scale]];
    [[button layer] setBorderColor:[[[UIColor separatorColor] colorWithAlphaComponent:0.24f] CGColor]];

    UIImageView *icon([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:symbol]] autorelease]);
    [icon setTranslatesAutoresizingMaskIntoConstraints:NO];
    [icon setTintColor:color];
    [icon setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:26.0f weight:UIImageSymbolWeightRegular]];

    UIView *iconTile([[[UIView alloc] init] autorelease]);
    [iconTile setTranslatesAutoresizingMaskIntoConstraints:NO];
    [iconTile setBackgroundColor:[color colorWithAlphaComponent:0.07f]];
    [[iconTile layer] setCornerRadius:22.0f];
    [[iconTile layer] setCornerCurve:kCACornerCurveContinuous];
    [iconTile addSubview:icon];

    UILabel *titleLabel(CYM3Label(UIFontTextStyleHeadline, [UIColor labelColor], 0));
    [titleLabel setText:title];
    UILabel *subtitleLabel(CYM3Label(UIFontTextStyleCaption1, [UIColor secondaryLabelColor], 0));
    [subtitleLabel setText:subtitle];
    if (subtitleOutput != NULL)
        *subtitleOutput = subtitleLabel;

    UIStackView *labels([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:titleLabel, subtitleLabel, nil]] autorelease]);
    [labels setAxis:UILayoutConstraintAxisVertical];
    [labels setSpacing:2.0f];

    UIStackView *content([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:iconTile, labels, nil]] autorelease]);
    [content setTranslatesAutoresizingMaskIntoConstraints:NO];
    [content setAxis:UILayoutConstraintAxisHorizontal];
    [content setAlignment:UIStackViewAlignmentCenter];
    [content setSpacing:12.0f];
    [content setUserInteractionEnabled:NO];
    [button addSubview:content];

    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [[content leadingAnchor] constraintEqualToAnchor:[button leadingAnchor] constant:14.0f],
        [[content trailingAnchor] constraintLessThanOrEqualToAnchor:[button trailingAnchor] constant:-10.0f],
        [[content topAnchor] constraintEqualToAnchor:[button topAnchor] constant:12.0f],
        [[content bottomAnchor] constraintEqualToAnchor:[button bottomAnchor] constant:-12.0f],
        [[iconTile widthAnchor] constraintEqualToConstant:44.0f],
        [[iconTile heightAnchor] constraintEqualToConstant:44.0f],
        [[icon centerXAnchor] constraintEqualToAnchor:[iconTile centerXAnchor]],
        [[icon centerYAnchor] constraintEqualToAnchor:[iconTile centerYAnchor]],
        [[icon widthAnchor] constraintEqualToConstant:29.0f],
        [[icon heightAnchor] constraintEqualToConstant:29.0f],
    nil]];
    return button;
}

static UIButton *CYM3DestinationButton(NSString *title, NSString *glyph, UIColor *color, NSInteger tag) {
    UIButton *button([UIButton buttonWithType:UIButtonTypeSystem]);
    [button setTranslatesAutoresizingMaskIntoConstraints:NO];
    [button setTag:tag];
    [button setAccessibilityLabel:title];
    [button setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];
    [[button layer] setCornerRadius:16.0f];
    [[button layer] setCornerCurve:kCACornerCurveContinuous];
    [[button layer] setBorderWidth:1.0f / [[UIScreen mainScreen] scale]];
    [[button layer] setBorderColor:[[[UIColor separatorColor] colorWithAlphaComponent:0.28f] CGColor]];

    UIView *iconTile([[[UIView alloc] init] autorelease]);
    [iconTile setTranslatesAutoresizingMaskIntoConstraints:NO];
    [iconTile setBackgroundColor:color];
    [[iconTile layer] setCornerRadius:12.0f];
    [[iconTile layer] setCornerCurve:kCACornerCurveContinuous];
    [[iconTile layer] setMasksToBounds:YES];

    UIView *icon(nil);
    if ([glyph hasPrefix:@"sf:"]) {
        UIImageView *symbol([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:[glyph substringFromIndex:3]]] autorelease]);
        [symbol setTintColor:color];
        [iconTile setBackgroundColor:[color colorWithAlphaComponent:0.07f]];
        [[iconTile layer] setCornerRadius:22.0f];
        [symbol setContentMode:UIViewContentModeScaleAspectFit];
        [symbol setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:26.0f weight:UIImageSymbolWeightRegular]];
        icon = symbol;
    } else {
        UILabel *letter([[[UILabel alloc] init] autorelease]);
        [letter setText:glyph];
        [letter setTextAlignment:NSTextAlignmentCenter];
        [letter setTextColor:[UIColor whiteColor]];
        [letter setFont:[UIFont systemFontOfSize:28.0f weight:UIFontWeightBold]];
        [letter setAdjustsFontSizeToFitWidth:YES];
        [letter setMinimumScaleFactor:0.65f];
        icon = letter;
    }
    [icon setTranslatesAutoresizingMaskIntoConstraints:NO];
    [iconTile addSubview:icon];

    UILabel *titleLabel(CYM3Label(UIFontTextStyleHeadline, [UIColor labelColor], 0));
    [titleLabel setText:title];
    UIImageView *chevron([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:@"chevron.right"]] autorelease]);
    [chevron setTranslatesAutoresizingMaskIntoConstraints:NO];
    [chevron setTintColor:[UIColor tertiaryLabelColor]];
    [chevron setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14.0f weight:UIImageSymbolWeightSemibold]];

    UIStackView *content([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:iconTile, titleLabel, chevron, nil]] autorelease]);
    [content setTranslatesAutoresizingMaskIntoConstraints:NO];
    [content setAxis:UILayoutConstraintAxisHorizontal];
    [content setAlignment:UIStackViewAlignmentCenter];
    [content setSpacing:11.0f];
    [content setUserInteractionEnabled:NO];
    [button addSubview:content];

    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [[content leadingAnchor] constraintEqualToAnchor:[button leadingAnchor] constant:12.0f],
        [[content trailingAnchor] constraintEqualToAnchor:[button trailingAnchor] constant:-12.0f],
        [[content topAnchor] constraintEqualToAnchor:[button topAnchor] constant:9.0f],
        [[content bottomAnchor] constraintEqualToAnchor:[button bottomAnchor] constant:-9.0f],
        [[iconTile widthAnchor] constraintEqualToConstant:44.0f],
        [[iconTile heightAnchor] constraintEqualToConstant:44.0f],
        [[icon centerXAnchor] constraintEqualToAnchor:[iconTile centerXAnchor]],
        [[icon centerYAnchor] constraintEqualToAnchor:[iconTile centerYAnchor]],
        [[icon widthAnchor] constraintLessThanOrEqualToConstant:29.0f],
        [[icon heightAnchor] constraintLessThanOrEqualToConstant:29.0f],
        [[chevron widthAnchor] constraintEqualToConstant:10.0f],
    nil]];
    return button;
}

@interface CYM3FeaturedPackageButton : UIButton {
    UIImageView *bannerImage_;
    NSString *imageURL_;
    BOOL launchCacheOnly_;
}
- (void) loadBannerIfNeeded;
- (NSString *) featuredImageURL;
- (UIImage *) loadedBannerImage;
- (void) adoptLoadedBannerImage:(UIImage *)image;
- (void) updateFeaturedPackage:(NSDictionary *)package;
- (id) initWithPackage:(NSDictionary *)package palette:(NSUInteger)palette;
- (void) featuredBannerDidLoad:(NSNotification *)notification;
@end

// Artwork is presented on its own at every text size. The complete package
// name remains available to VoiceOver without adding anything to the image.
static CGFloat CYM3FeaturedHeight(UITraitCollection *traits) {
    return 148.0f;
}

static NSString *const CYM3FeaturedBannerDidLoadNotification = @"CYM3FeaturedBannerDidLoadNotification";

static NSCache *CYM3FeaturedBannerCache(void) {
    static NSCache *cache(nil);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        [cache setCountLimit:96];
        [cache setTotalCostLimit:64 * 1024 * 1024];
    });
    return cache;
}

static NSMutableSet *CYM3FeaturedBannerRequests(void) {
    static NSMutableSet *requests(nil);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ requests = [[NSMutableSet alloc] init]; });
    return requests;
}

// Cache-only launch cards and live Home cards share one disk lookup. A live
// card may permit the same pending lookup to download only after consent.
static NSMutableSet *CYM3FeaturedBannerNetworkRequests(void) {
    static NSMutableSet *requests(nil);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ requests = [[NSMutableSet alloc] init]; });
    return requests;
}

static NSString *CYM3FeaturedBannerDiskDirectory(void) {
    static NSString *directory(nil);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *paths(NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES));
        NSString *root([paths count] == 0 ? NSTemporaryDirectory() : [paths objectAtIndex:0]);
        directory = [[root stringByAppendingPathComponent:@"com.saurik.Cydia/FeaturedBanners"] copy];
    });
    return directory;
}

static NSString *CYM3FeaturedBannerDiskPath(NSString *imageURL) {
    const unsigned char *bytes(reinterpret_cast<const unsigned char *>([imageURL UTF8String]));
    NSUInteger length([imageURL lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    uint64_t hash(1469598103934665603ULL);
    for (NSUInteger index(0); bytes != NULL && index != length; ++index) {
        hash ^= bytes[index];
        hash *= 1099511628211ULL;
    }
    NSString *name([NSString stringWithFormat:@"%016llx.banner", (unsigned long long) hash]);
    return [CYM3FeaturedBannerDiskDirectory() stringByAppendingPathComponent:name];
}

static void CYM3PersistFeaturedBanner(NSString *imageURL, NSData *data) {
    if ([imageURL length] == 0 || [data length] == 0 || [data length] > 5 * 1024 * 1024)
        return;
    [[NSFileManager defaultManager] createDirectoryAtPath:CYM3FeaturedBannerDiskDirectory()
        withIntermediateDirectories:YES attributes:nil error:NULL];
    [data writeToFile:CYM3FeaturedBannerDiskPath(imageURL) options:NSDataWritingAtomic error:NULL];
}

static UIImage *CYM3DecodeFeaturedBanner(NSData *data, CGFloat scale) {
    if ([data length] == 0 || [data length] > 5 * 1024 * 1024)
        return nil;
    CGFloat displayScale(isfinite(scale) && scale > 0.0f ? MIN(scale, 3.0f) : 1.0f);
    NSDictionary *sourceOptions(@{(NSString *)kCGImageSourceShouldCache: @NO});
    CGImageSourceRef source(CGImageSourceCreateWithData((CFDataRef)data, (CFDictionaryRef)sourceOptions));
    if (source == NULL)
        return nil;
    NSDictionary *properties((NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    double width([[properties objectForKey:(NSString *)kCGImagePropertyPixelWidth] doubleValue]);
    double height([[properties objectForKey:(NSString *)kCGImagePropertyPixelHeight] doubleValue]);
    NSInteger orientation([[properties objectForKey:(NSString *)kCGImagePropertyOrientation] integerValue]);
    [properties release];
    // Curated artwork may be much larger than the card (Bohemic is 4096 x 2589).
    // Validate source metadata, then decode a bounded thumbnail, never the full bitmap.
    if (!isfinite(width) || !isfinite(height) || width < 2.0 || height < 2.0 ||
        width > 32768.0 || height > 32768.0 || width * height > 100.0 * 1024.0 * 1024.0) {
        CFRelease(source);
        return nil;
    }
    if (orientation >= 5 && orientation <= 8) {
        double swap(width); width = height; height = swap;
    }
    double ratio(MIN(1.0, MAX(263.0 * displayScale / width, 148.0 * displayScale / height)));
    NSUInteger maxDimension((NSUInteger)MAX(2.0, MIN(1536.0, ceil(MAX(width, height) * ratio))));
    NSDictionary *thumbnailOptions(@{
        (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (NSString *)kCGImageSourceShouldCacheImmediately: @YES,
        (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxDimension)
    });
    CGImageRef thumbnail(CGImageSourceCreateThumbnailAtIndex(source, 0, (CFDictionaryRef)thumbnailOptions));
    CFRelease(source);
    if (thumbnail == NULL)
        return nil;
    size_t decodedWidth(CGImageGetWidth(thumbnail)), decodedHeight(CGImageGetHeight(thumbnail));
    UIImage *image(nil);
    if (decodedWidth >= 2 && decodedHeight >= 2 && decodedWidth <= 1536 && decodedHeight <= 1536)
        image = [UIImage imageWithCGImage:thumbnail scale:displayScale orientation:UIImageOrientationUp];
    CGImageRelease(thumbnail);
    return image;
}

static NSUInteger CYM3FeaturedBannerCost(UIImage *image) {
    CGImageRef bitmap([image CGImage]);
    size_t rowBytes(bitmap == NULL ? 0 : CGImageGetBytesPerRow(bitmap));
    size_t height(bitmap == NULL ? 0 : CGImageGetHeight(bitmap));
    return height == 0 || rowBytes > NSUIntegerMax / height ? 0 : rowBytes * height;
}

static UIImage *CYM3CachedFeaturedBanner(NSString *imageURL, CGFloat scale) {
    UIImage *image([CYM3FeaturedBannerCache() objectForKey:imageURL]);
    if (image != nil)
        return image;
    // The direct file cache avoids initializing NSURLCache during launch. Even
    // local reads and image decoding run off the main thread before first paint.
    NSData *data([NSData dataWithContentsOfFile:CYM3FeaturedBannerDiskPath(imageURL)
        options:NSDataReadingMappedIfSafe error:NULL]);
    image = CYM3DecodeFeaturedBanner(data, scale);
    if (image != nil)
        [CYM3FeaturedBannerCache() setObject:image forKey:imageURL cost:CYM3FeaturedBannerCost(image)];
    return image;
}

static void CYM3FinishFeaturedBannerRequest(NSString *imageURL, UIImage *image) {
    @synchronized (CYM3FeaturedBannerRequests()) {
        [CYM3FeaturedBannerRequests() removeObject:imageURL];
        [CYM3FeaturedBannerNetworkRequests() removeObject:imageURL];
    }
    if (image != nil)
        [[NSNotificationCenter defaultCenter] postNotificationName:CYM3FeaturedBannerDidLoadNotification
            object:imageURL userInfo:@{@"image":image}];
}

static BOOL CYM3FeaturedResponseNeedsCacheRefresh(NSData *data) {
    if ([data length] == 0) return YES;
    if ([data length] > 5 * 1024 * 1024) return NO;
    // Inspect encoded metadata only. Valid artwork rejected by the decoder's
    // resource limits must not cause repeated network downloads.
    CGImageSourceRef source(CGImageSourceCreateWithData((CFDataRef)data,
        (CFDictionaryRef)@{(NSString *)kCGImageSourceShouldCache:@NO}));
    BOOL invalid(source == NULL || CGImageSourceGetCount(source) == 0 ||
        CGImageSourceGetStatusAtIndex(source, 0) != kCGImageStatusComplete);
    if (source != NULL) CFRelease(source);
    return invalid;
}

static NSTimeInterval CYM3FeaturedRetryDelay(NSError *error, NSHTTPURLResponse *response, NSUInteger retry) {
    BOOL transient(NO);
    if ([[error domain] isEqualToString:NSURLErrorDomain]) {
        switch ([error code]) {
            case NSURLErrorTimedOut:
            case NSURLErrorNotConnectedToInternet:
            case NSURLErrorNetworkConnectionLost:
            case NSURLErrorCannotFindHost:
            case NSURLErrorCannotConnectToHost:
            case NSURLErrorDNSLookupFailed:
                transient = YES;
        }
    } else if (error == nil) {
        NSInteger status([response statusCode]);
        transient = status == 408 || status == 429 || status == 500 || status == 502 || status == 503 || status == 504;
    }
    if (!transient) return -1.0;
    NSTimeInterval delay(retry == 0 ? 0.6 : 1.5);
    NSString *retryAfter([response valueForHTTPHeaderField:@"Retry-After"]);
    if ([retryAfter length] != 0) {
        double seconds(0);
        NSScanner *scanner([NSScanner scannerWithString:retryAfter]);
        // A longer or date-form server delay is left for a later user retry;
        // never send an automatic retry earlier than the server requested.
        if (![scanner scanDouble:&seconds] || ![scanner isAtEnd] || !isfinite(seconds) || seconds < 0 || seconds > 15)
            return -1.0;
        delay = MAX(delay, seconds);
    }
    return delay;
}

static void CYM3DownloadFeaturedBanner(NSString *imageURL, NSURLRequest *request, CGFloat scale, NSUInteger retry, BOOL refreshedInvalidCache) {
    BOOL download(NO);
    @synchronized (CYM3FeaturedBannerRequests()) {
        download = [CYM3FeaturedBannerRequests() containsObject:imageURL] &&
            [CYM3FeaturedBannerNetworkRequests() containsObject:imageURL];
    }
    if (!download || !CydiaPrivacyConsentIsAccepted()) {
        CYM3FinishFeaturedBannerRequest(imageURL, nil);
        return;
    }
    // Early cache warming creates no URL request and never initializes
    // CFNetwork. Only a later live card can permit a missing image download.
    if (request == nil) {
        NSURL *url([NSURL URLWithString:imageURL]);
        if (url == nil) { CYM3FinishFeaturedBannerRequest(imageURL, nil); return; }
        request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:15.0];
    }
    // This chain is shared by looping cards and retains no individual view.
    NSURLSessionDataTask *task([[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http([response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil);
            UIImage *image(error == nil && [http statusCode] == 200 ? CYM3DecodeFeaturedBanner(data, scale) : nil);
            if (image != nil) {
                [CYM3FeaturedBannerCache() setObject:image forKey:imageURL cost:CYM3FeaturedBannerCost(image)];
                // Deliver the retained image itself before cache maintenance.
                dispatch_async(dispatch_get_main_queue(), ^{ CYM3FinishFeaturedBannerRequest(imageURL, image); });
                CYM3PersistFeaturedBanner(imageURL, data);
                NSCachedURLResponse *persisted([[[NSCachedURLResponse alloc]
                    initWithResponse:response data:data userInfo:nil storagePolicy:NSURLCacheStorageAllowed] autorelease]);
                [[NSURLCache sharedURLCache] storeCachedResponse:persisted forRequest:request];
                return;
            }
            BOOL invalidBody(error == nil && [http statusCode] == 200 && CYM3FeaturedResponseNeedsCacheRefresh(data));
            if (invalidBody)
                [[NSURLCache sharedURLCache] removeCachedResponseForRequest:request];
            NSTimeInterval delay(CYM3FeaturedRetryDelay(error, http, retry));
            if (invalidBody && !refreshedInvalidCache) delay = 0.6;
            if (retry >= 2 || delay < 0.0 || (invalidBody && refreshedInvalidCache)) {
                dispatch_async(dispatch_get_main_queue(), ^{ CYM3FinishFeaturedBannerRequest(imageURL, nil); });
                return;
            }
            NSMutableURLRequest *fresh([request mutableCopy]);
            [fresh setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                CYM3DownloadFeaturedBanner(imageURL, fresh, scale, retry + 1, refreshedInvalidCache || invalidBody);
            });
            [fresh release];
        }]);
    [task resume];
}

static void CYM3RequestFeaturedBanner(NSString *imageURL, NSURLRequest *request, CGFloat scale, BOOL allowNetwork) {
    if ((allowNetwork && request == nil) || [imageURL length] == 0 || [CYM3FeaturedBannerCache() objectForKey:imageURL] != nil)
        return;
    @synchronized (CYM3FeaturedBannerRequests()) {
        if (allowNetwork)
            [CYM3FeaturedBannerNetworkRequests() addObject:imageURL];
        if ([CYM3FeaturedBannerRequests() containsObject:imageURL])
            return;
        [CYM3FeaturedBannerRequests() addObject:imageURL];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            UIImage *cached(CYM3CachedFeaturedBanner(imageURL, scale));
            dispatch_async(dispatch_get_main_queue(), ^{
                if (cached != nil) CYM3FinishFeaturedBannerRequest(imageURL, cached);
                else CYM3DownloadFeaturedBanner(imageURL, request, scale, 0, NO);
            });
        }
    });
}

void CYPrewarmFeaturedBannerArtwork(NSArray *packages, CGFloat scale) {
    if (![packages isKindOfClass:[NSArray class]]) return;
    NSMutableSet *seen([NSMutableSet set]);
    NSUInteger count(MIN((NSUInteger)6, [packages count]));
    for (NSUInteger index(0); index < count; ++index) {
        id package([packages objectAtIndex:index]);
        if (![package isKindOfClass:[NSDictionary class]]) continue;
        id value([package objectForKey:@"imageURL"]);
        if (![value isKindOfClass:[NSString class]] || [seen containsObject:value]) continue;
        NSURL *url([NSURL URLWithString:value]);
        if (![[[url scheme] lowercaseString] isEqualToString:@"https"] || [[url host] length] == 0 ||
            [url user] != nil || [url password] != nil) continue;
        [seen addObject:value];
        CYM3RequestFeaturedBanner(value, nil, scale, NO);
    }
}

@implementation CYM3FeaturedPackageButton

- (id) initWithPackage:(NSDictionary *)package palette:(NSUInteger)palette {
    if ((self = [super initWithFrame:CGRectZero]) != nil) {
        [self setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self setClipsToBounds:YES];
        [[self layer] setCornerRadius:16.0f];
        [[self layer] setCornerCurve:kCACornerCurveContinuous];
        [self setAccessibilityTraits:UIAccessibilityTraitButton];
        [self setAccessibilityIdentifier:[package objectForKey:@"identifier"]];

        (void)palette;
        [self setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];

        bannerImage_ = [[[CydiaSymbolView alloc] init] autorelease];
        [bannerImage_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [bannerImage_ setContentMode:UIViewContentModeScaleAspectFill];
        [bannerImage_ setClipsToBounds:YES];
        [bannerImage_ setUserInteractionEnabled:NO];
        [bannerImage_ setAccessibilityIgnoresInvertColors:YES];
        [[bannerImage_ layer] setCornerRadius:16.0f];
        [[bannerImage_ layer] setCornerCurve:kCACornerCurveContinuous];
        [self addSubview:bannerImage_];

        [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
            [[bannerImage_ leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
            [[bannerImage_ trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
            [[bannerImage_ topAnchor] constraintEqualToAnchor:[self topAnchor]],
            [[bannerImage_ heightAnchor] constraintEqualToConstant:148.0f],
        nil]];

        NSString *label([NSString stringWithFormat:CYLocalize(@"%@. Featured package from %@"),
            [package objectForKey:@"name"] ?: CYLocalize(@"Package"),
            [package objectForKey:@"repository"] ?: @""]);
        [self setAccessibilityLabel:label];

        imageURL_ = [[package objectForKey:@"imageURL"] copy];
        launchCacheOnly_ = [[package objectForKey:@"launchCacheOnly"] boolValue];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(featuredBannerDidLoad:)
            name:CYM3FeaturedBannerDidLoadNotification object:nil];
        [self loadBannerIfNeeded];
    }
    return self;
}

- (void) loadBannerIfNeeded {
    if ([bannerImage_ image] != nil)
        return;
    UIImage *cached([CYM3FeaturedBannerCache() objectForKey:imageURL_]);
    if (cached != nil) {
        [bannerImage_ setImage:cached];
        [self setNeedsLayout];
    } else {
        BOOL allowNetwork(!launchCacheOnly_ && CydiaPrivacyConsentIsAccepted());
        NSURL *url(allowNetwork ? [NSURL URLWithString:imageURL_] : nil);
        NSURLRequest *request(url == nil ? nil : [NSURLRequest requestWithURL:url
            cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:15.0]);
        CYM3RequestFeaturedBanner(imageURL_, request, [[UIScreen mainScreen] scale], allowNetwork);
    }
}

- (NSString *) featuredImageURL { return imageURL_; }
- (UIImage *) loadedBannerImage { return [bannerImage_ image]; }
- (void) updateFeaturedPackage:(NSDictionary *)package {
    // Reused cards keep their image and layer; only their presentation metadata
    // and cache-only launch permission change.
    launchCacheOnly_ = [[package objectForKey:@"launchCacheOnly"] boolValue];
    [self setAccessibilityLabel:[NSString stringWithFormat:CYLocalize(@"%@. Featured package from %@"),
        [package objectForKey:@"name"] ?: CYLocalize(@"Package"),
        [package objectForKey:@"repository"] ?: @""]];
    [self loadBannerIfNeeded];
}
- (void) adoptLoadedBannerImage:(UIImage *)image {
    if (image == nil || [bannerImage_ image] != nil) return;
    [UIView performWithoutAnimation:^{ [bannerImage_ setImage:image]; }];
    [self setNeedsLayout];
}

- (void) featuredBannerDidLoad:(NSNotification *)notification {
    if (![[notification object] isEqualToString:imageURL_])
        return;
    UIImage *image([[notification userInfo] objectForKey:@"image"]);
    if (![image isKindOfClass:[UIImage class]])
        image = [CYM3FeaturedBannerCache() objectForKey:imageURL_];
    if (image == nil || [bannerImage_ image] == image)
        return;
    // The first cached/network image should be visible in its next frame,
    // rather than spending another 220 ms fading in from an empty card.
    if ([bannerImage_ image] == nil || [self window] == nil) {
        [UIView performWithoutAnimation:^{ [bannerImage_ setImage:image]; }];
    } else {
        [UIView transitionWithView:bannerImage_ duration:0.22
            options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
            animations:^{ [bannerImage_ setImage:image]; } completion:nil];
    }
    [self setNeedsLayout];
}

- (void) setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.16 animations:^{
        [bannerImage_ setAlpha:highlighted ? 0.78f : 1.0f];
        [self setTransform:highlighted ? CGAffineTransformMakeScale(0.985f, 0.985f) : CGAffineTransformIdentity];
    }];
}

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [imageURL_ release];
    [super dealloc];
}

@end

// The presentation mark is rendered once at the current display scale.
// Core Animation supplies a centred reveal, a small tilt and an occasional sheen.
static NSMutableAttributedString *CYM3PresentationText(void) {
    UIFontDescriptor *descriptor([[UIFont systemFontOfSize:39 weight:UIFontWeightHeavy] fontDescriptor]);
    descriptor = [descriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold | UIFontDescriptorTraitItalic];
    NSMutableAttributedString *text([[[NSMutableAttributedString alloc] initWithString:@"CYDIA "
        attributes:@{NSFontAttributeName:[UIFont fontWithDescriptor:descriptor size:39], NSKernAttributeName:@0.6}] autorelease]);
    [text appendAttributedString:[[[NSAttributedString alloc] initWithString:@ CYDIA_VERSION
        attributes:@{NSFontAttributeName:[UIFont fontWithDescriptor:descriptor size:28], NSKernAttributeName:@0.3}] autorelease]];
    return text;
}

@interface CYM3PresentationWordmarkView : UIView {
    UIImageView *letters_;
    CALayer *sheen_;
    CALayer *letterMask_;
    CAGradientLayer *highlight_;
    CGSize renderedSize_;
    BOOL shimmerActive_;
}
- (void) setShimmerActive:(BOOL)active delay:(CFTimeInterval)delay;
@end
@implementation CYM3PresentationWordmarkView
- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
        [self setOpaque:NO];
        letters_ = [[[CydiaSymbolView alloc] initWithFrame:[self bounds]] autorelease];
        [self addSubview:letters_];
        sheen_ = [[CALayer layer] retain];
        letterMask_ = [[CALayer layer] retain];
        [sheen_ setMask:letterMask_];
        highlight_ = [[CAGradientLayer layer] retain];
        [highlight_ setColors:@[(id)[[UIColor clearColor] CGColor],
            (id)[[UIColor colorWithWhite:1 alpha:0.7] CGColor], (id)[[UIColor clearColor] CGColor]]];
        [highlight_ setLocations:@[@0, @0.5, @1]];
        [highlight_ setStartPoint:CGPointMake(0, 0.15)];
        [highlight_ setEndPoint:CGPointMake(1, 0.85)];
        [sheen_ addSublayer:highlight_];
        [[self layer] addSublayer:sheen_];
        [sheen_ setOpacity:0];
    }
    return self;
}
- (void) layoutSubviews {
    [super layoutSubviews];
    CGSize bounds([self bounds].size);
    if (bounds.width <= 0 || bounds.height <= 0 || CGSizeEqualToSize(bounds, renderedSize_))
        return;
    renderedSize_ = bounds;
    NSMutableAttributedString *text(CYM3PresentationText());
    CGSize size([text size]);
    CGFloat scale(MIN(1.0, (bounds.width - 20.0) / MAX(1.0, size.width + 5.0)));
    // Centre the face and extrusion together, not the old worm-and-text canvas.
    CGPoint origin(CGPointMake((bounds.width / scale - size.width - 1.8) * 0.5,
        (bounds.height / scale - size.height - 3.5) * 0.5));
    NSRange all(NSMakeRange(0, [text length]));
    UIGraphicsImageRendererFormat *format([UIGraphicsImageRendererFormat defaultFormat]);
    [format setOpaque:NO];
    [format setScale:MAX(1.0, [[self traitCollection] displayScale])];
    UIGraphicsImageRenderer *renderer([[[UIGraphicsImageRenderer alloc] initWithSize:bounds format:format] autorelease]);
    UIImage *mask([renderer imageWithActions:^(UIGraphicsImageRendererContext *drawing) {
        CGContextScaleCTM([drawing CGContext], scale, scale);
        [text addAttribute:NSForegroundColorAttributeName value:[UIColor whiteColor] range:all];
        [text drawAtPoint:origin];
    }]);
    UIImage *face([renderer imageWithActions:^(UIGraphicsImageRendererContext *drawing) {
        [mask drawAtPoint:CGPointZero];
        CGContextRef context([drawing CGContext]);
        CGContextSetBlendMode(context, kCGBlendModeSourceIn);
        NSArray *colors(@[(id)[[UIColor colorWithRed:1 green:0.88 blue:0.68 alpha:1] CGColor],
            (id)[[UIColor colorWithRed:0.92 green:0.64 blue:0.38 alpha:1] CGColor],
            (id)[[UIColor colorWithRed:0.70 green:0.37 blue:0.19 alpha:1] CGColor]]);
        CGColorSpaceRef space(CGColorSpaceCreateDeviceRGB());
        CGGradientRef gradient(CGGradientCreateWithColors(space, (CFArrayRef)colors, NULL));
        CGContextDrawLinearGradient(context, gradient, CGPointMake(0, origin.y * scale + 6),
            CGPointMake(0, (origin.y + size.height - 2) * scale),
            kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }]);
    UIImage *artwork([renderer imageWithActions:^(UIGraphicsImageRendererContext *drawing) {
        CGContextRef context([drawing CGContext]);
        CGContextSaveGState(context);
        CGContextScaleCTM(context, scale, scale);
        [text addAttribute:NSForegroundColorAttributeName
            value:[UIColor colorWithRed:0.36 green:0.19 blue:0.12 alpha:1] range:all];
        CGContextSetShadowWithColor(context, CGSizeMake(0, 2), 2.5, [[UIColor colorWithWhite:0 alpha:0.18] CGColor]);
        [text drawAtPoint:CGPointMake(origin.x + 1.8, origin.y + 3.5)];
        CGContextSetShadowWithColor(context, CGSizeZero, 0, NULL);
        for (NSInteger depth(5); depth > 0; --depth)
            [text drawAtPoint:CGPointMake(origin.x + depth * 0.28, origin.y + depth * 0.55)];
        CGContextRestoreGState(context);
        [face drawAtPoint:CGPointZero];
    }]);
    [letters_ setFrame:[self bounds]];
    [letters_ setImage:artwork];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [sheen_ setFrame:[self bounds]];
    [letterMask_ setFrame:[self bounds]];
    [letterMask_ setContents:(id)[mask CGImage]];
    [letterMask_ setContentsScale:[mask scale]];
    [highlight_ setFrame:CGRectMake(-bounds.width * 0.35, 0, bounds.width * 0.30, bounds.height)];
    [CATransaction commit];
    if (shimmerActive_)
        [self setShimmerActive:YES delay:0];
}
- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([previous displayScale] != [[self traitCollection] displayScale]) {
        renderedSize_ = CGSizeZero;
        [self setNeedsLayout];
    }
}
- (void) setShimmerActive:(BOOL)active delay:(CFTimeInterval)delay {
    shimmerActive_ = active;
    [highlight_ removeAllAnimations];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [sheen_ setOpacity:active ? 1 : 0];
    [CATransaction commit];
    if (!active)
        return;
    CGFloat width(CGRectGetWidth([self bounds]));
    CAKeyframeAnimation *light([CAKeyframeAnimation animationWithKeyPath:@"position.x"]);
    [light setValues:@[@(-width * 0.2), @(-width * 0.2), @(width * 1.2), @(width * 1.2)]];
    [light setKeyTimes:@[@0, @0.24, @0.47, @1]];
    [light setDuration:8.0];
    [light setBeginTime:[highlight_ convertTime:CACurrentMediaTime() fromLayer:nil] + delay];
    [light setRepeatCount:FLT_MAX];
    [highlight_ addAnimation:light forKey:@"CydiaLetterSheen"];
}
- (void) dealloc {
    [highlight_ removeAllAnimations];
    [highlight_ release];
    [letterMask_ release];
    [sheen_ release];
    [super dealloc];
}
@end

@interface CYM3HomeGraffitiView : UIView {
    UIView *canvas_;
    UIView *motion_;
    CYM3PresentationWordmarkView *word_;
    BOOL presenting_;
}
- (void) paintAnimated:(BOOL)animated;
- (void) stopPainting;
- (void) refreshMotion;
- (void) haltAnimations;
@end
@implementation CYM3HomeGraffitiView
- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
        [self setUserInteractionEnabled:NO];
        canvas_ = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 304, 94)] autorelease];
        [self addSubview:canvas_];
        motion_ = [[[UIView alloc] initWithFrame:CGRectMake(0, 7, 304, 66)] autorelease];
        [canvas_ addSubview:motion_];
        word_ = [[[CYM3PresentationWordmarkView alloc] initWithFrame:[motion_ bounds]] autorelease];
        [motion_ addSubview:word_];
        UIImageView *hint([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:@"chevron.up"]] autorelease]);
        [hint setFrame:CGRectMake(144, 81, 16, 9)];
        [hint setContentMode:UIViewContentModeScaleAspectFit];
        [hint setTintColor:[UIColor secondaryLabelColor]];
        [canvas_ addSubview:hint];
        NSNotificationCenter *center([NSNotificationCenter defaultCenter]);
        [center addObserver:self selector:@selector(haltAnimations) name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(refreshMotion) name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:self selector:@selector(refreshMotion) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(refreshMotion) name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(refreshMotion) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    }
    return self;
}
- (void) layoutSubviews {
    [super layoutSubviews];
    CGFloat scale(MIN(1.0, CGRectGetWidth([self bounds]) / 304.0));
    [canvas_ setTransform:CGAffineTransformMakeScale(scale, scale)];
    [canvas_ setCenter:CGPointMake(CGRectGetMidX([self bounds]), CGRectGetMidY([self bounds]))];
}
- (BOOL) allowsMotion {
    return presenting_ && [self window] != nil &&
        [[UIApplication sharedApplication] applicationState] == UIApplicationStateActive &&
        !UIAccessibilityIsReduceMotionEnabled() && !UIAccessibilityIsVoiceOverRunning() &&
        ![[NSProcessInfo processInfo] isLowPowerModeEnabled];
}
- (void) didMoveToWindow {
    [super didMoveToWindow];
    [self refreshMotion];
}
- (void) haltAnimations {
    [[motion_ layer] removeAllAnimations];
    [[word_ layer] removeAllAnimations];
    [word_ setShimmerActive:NO delay:0];
}
- (void) stopPainting {
    presenting_ = NO;
    [self haltAnimations];
}
- (void) beginIdleMotionAfterDelay:(CFTimeInterval)delay {
    CAKeyframeAnimation *tilt([CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"]);
    [tilt setValues:@[@0, @(-0.007), @0, @0.007, @0]];
    CAKeyframeAnimation *floaty([CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"]);
    [floaty setValues:@[@0, @(-1.4), @0, @1.4, @0]];
    for (CAKeyframeAnimation *animation in @[tilt, floaty]) {
        [animation setDuration:6.0];
        [animation setKeyTimes:@[@0, @0.25, @0.5, @0.75, @1]];
        [animation setCalculationMode:kCAAnimationCubic];
    }
    CAAnimationGroup *drift([CAAnimationGroup animation]);
    [drift setAnimations:@[tilt, floaty]];
    [drift setDuration:6.0];
    [drift setBeginTime:[[motion_ layer] convertTime:CACurrentMediaTime() fromLayer:nil] + delay];
    [drift setRepeatCount:FLT_MAX];
    [[motion_ layer] addAnimation:drift forKey:@"CydiaCentredDrift"];
    [word_ setShimmerActive:YES delay:delay];
}
- (void) refreshMotion {
    [self haltAnimations];
    if ([self allowsMotion])
        [self beginIdleMotionAfterDelay:0];
}
- (void) paintAnimated:(BOOL)animated {
    [self haltAnimations];
    presenting_ = YES;
    [word_ layoutIfNeeded];
    if (![self allowsMotion])
        return;
    const CFTimeInterval revealDuration(animated ? 0.8 : 0);
    if (animated) {
        // One continuous scale curve: no midpoint slowdown or overshoot.
        CABasicAnimation *grow([CABasicAnimation animationWithKeyPath:@"transform.scale"]);
        [grow setFromValue:@0.012];
        [grow setToValue:@1];
        [grow setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
        [grow setDuration:revealDuration];
        // Use one explicit clock while navigation and tab bars settle. An
        // automatic start time can be rebased by the first render commit.
        [grow setBeginTime:[[word_ layer] convertTime:CACurrentMediaTime() fromLayer:nil]];
        [grow setFillMode:kCAFillModeBackwards];
        [[word_ layer] addAnimation:grow forKey:@"CydiaPointReveal"];
    }
    [self beginIdleMotionAfterDelay:revealDuration];
}
- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self haltAnimations];
    [super dealloc];
}
@end

@interface CydiaModernHomeView () {
    NSArray *actionButtons_;
    NSArray *featuredRecords_;
    NSArray *homeRows_;
    UILabel *homeVersion_;
    UIStackView *heroRow_;
    UILabel *heroAuthor_;
    UILabel *heroTitle_;
    NSLayoutConstraint *homeScrollBottom_;
    NSLayoutConstraint *graffitiBottom_;
    NSLayoutConstraint *featuredHeight_;
    UIScrollView *homeScroll_;
    UIView *fullScreenDock_;
    CYM3HomeGraffitiView *graffiti_;
    UIButton *showControls_;
    BOOL fullScreenControlsVisible_;
    UILabel *sourcesMetric_;
    UILabel *changesMetric_;
    UILabel *installedMetric_;
    UILabel *searchMetric_;
    UIScrollView *featuredScroll_;
    UIStackView *featuredStack_;
    CADisplayLink *featuredTicker_;
    id actionTarget_;
    SEL actionSelector_;
    CGFloat featuredCardWidth_;
    CGFloat featuredCycleWidth_;
    CFTimeInterval featuredLastTimestamp_;
    CGFloat featuredTravelVelocity_;
    BOOL featuredRebuilding_;
}
- (void) startFeaturedTicker;
- (void) stopFeaturedTicker;
- (NSDictionary *) featuredPosition;
- (void) restoreFeaturedPosition:(NSDictionary *)position;
- (void) ensureFeaturedCoverageWithReusableCards:(NSMutableDictionary *)reusable;
@end

@implementation CydiaModernHomeView

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopFeaturedTicker];
    [featuredScroll_ setDelegate:nil];
    [actionButtons_ release];
    [homeRows_ release];
    [featuredRecords_ release];
    [homeScrollBottom_ release];
    [graffitiBottom_ release];
    [featuredHeight_ release];
    [super dealloc];
}

- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
        [self setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
        NSNotificationCenter *motionCenter([NSNotificationCenter defaultCenter]);
        [motionCenter addObserver:self selector:@selector(stopFeaturedTicker) name:UIApplicationWillResignActiveNotification object:nil];
        [motionCenter addObserver:self selector:@selector(resumeFeaturedMotion) name:UIApplicationDidBecomeActiveNotification object:nil];
        [motionCenter addObserver:self selector:@selector(refreshFeaturedMotion) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
        [motionCenter addObserver:self selector:@selector(refreshFeaturedMotion) name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];

        UIScrollView *scroll([[[UIScrollView alloc] init] autorelease]);
        [scroll setTranslatesAutoresizingMaskIntoConstraints:NO];
        [scroll setAlwaysBounceVertical:YES];
        homeScroll_ = scroll;
        [self addSubview:scroll];

        UIStackView *content([[[UIStackView alloc] init] autorelease]);
        [content setTranslatesAutoresizingMaskIntoConstraints:NO];
        [content setAxis:UILayoutConstraintAxisVertical];
        [content setAlignment:UIStackViewAlignmentFill];
        [content setSpacing:12.0f];
        [scroll addSubview:content];

        UIView *hero([[[UIView alloc] init] autorelease]);
        [hero setTranslatesAutoresizingMaskIntoConstraints:NO];

        UIImageView *appIcon([[[CydiaSymbolView alloc] initWithImage:[UIImage imageNamed:@"Icon-60"]] autorelease]);
        [appIcon setTranslatesAutoresizingMaskIntoConstraints:NO];
        [appIcon setContentMode:UIViewContentModeScaleAspectFit];
        [[appIcon layer] setCornerRadius:16.0f];
        [[appIcon layer] setCornerCurve:kCACornerCurveContinuous];
        [[appIcon layer] setMasksToBounds:YES];

        UILabel *heroTitle(CYM3Label(UIFontTextStyleTitle1, [UIColor labelColor], 0));
        [heroTitle setText:CYLocalize(@"Welcome to Cydia™")];
        heroTitle_ = heroTitle;
        [heroTitle setTextAlignment:NSTextAlignmentCenter];
        UILabel *heroAuthor(CYM3Label(UIFontTextStyleTitle3, [UIColor labelColor], 0));
        heroAuthor_ = heroAuthor;
        [self updateHomeAuthorFont];
        [heroAuthor setTextAlignment:NSTextAlignmentCenter];

        UIStackView *heroLabels([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:heroTitle, heroAuthor, nil]] autorelease]);
        [heroLabels setTranslatesAutoresizingMaskIntoConstraints:NO];
        [heroLabels setAxis:UILayoutConstraintAxisVertical];
        [heroLabels setAlignment:UIStackViewAlignmentFill];
        [heroLabels setSpacing:5.0f];
        heroRow_ = [[[UIStackView alloc] initWithArrangedSubviews:@[appIcon, heroLabels]] autorelease];
        [heroRow_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [heroRow_ setAlignment:UIStackViewAlignmentCenter];
        [heroRow_ setSpacing:14.0f];
        [hero addSubview:heroRow_];

        UIButton *facebook(CYM3DestinationButton(@"Cydia", @"f", [UIColor colorWithRed:0.18f green:0.40f blue:0.68f alpha:1.0f], 101));
        UIButton *twitter(CYM3DestinationButton(@"saurik", @"𝕏", [UIColor colorWithRed:0.05f green:0.68f blue:0.88f alpha:1.0f], 102));
        UIStackView *socialRow([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:facebook, twitter, nil]] autorelease]);
        [socialRow setAxis:UILayoutConstraintAxisHorizontal];
        [socialRow setDistribution:UIStackViewDistributionFillEqually];
        [socialRow setSpacing:10.0f];

        UIButton *account(CYM3DestinationButton(CYLocalize(@"Manage Account"), @"sf:person.crop.circle", CYModernAccentColor(), 103));
        [account setAccessibilityHint:CYLocalize(@"Sign in to compatible repositories and view purchased packages")];

        UILabel *quickTitle(CYM3Label(UIFontTextStyleHeadline, [UIColor labelColor], 1));
        [quickTitle setText:CYLocalize(@"Quick Actions")];
        [quickTitle setLayoutMargins:UIEdgeInsetsMake(4.0f, 4.0f, 0.0f, 0.0f)];

        UIButton *sources(CYM3ActionButton(CYLocalize(@"Sources"), CYLocalize(@"Repositories"), @"square.stack.3d.up", CYModernAccentColor(), 1, &sourcesMetric_));
        UIButton *changes(CYM3ActionButton(CYLocalize(@"Changes"), CYLocalize(@"Updates"), @"clock.arrow.circlepath", CYModernAccentColor(), 2, &changesMetric_));
        UIButton *installed(CYM3ActionButton(CYLocalize(@"Installed"), CYLocalize(@"Your packages"), @"shippingbox", CYModernAccentColor(), 3, &installedMetric_));
        UIButton *search(CYM3ActionButton(CYLocalize(@"Search"), CYLocalize(@"Find packages"), @"magnifyingglass", CYModernAccentColor(), 4, &searchMetric_));
        actionButtons_ = [[NSArray alloc] initWithObjects:sources, changes, installed, search, facebook, twitter, account, nil];

        UIStackView *firstRow([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:sources, changes, nil]] autorelease]);
        [firstRow setAxis:UILayoutConstraintAxisHorizontal];
        [firstRow setDistribution:UIStackViewDistributionFillEqually];
        [firstRow setSpacing:10.0f];
        UIStackView *secondRow([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:installed, search, nil]] autorelease]);
        [secondRow setAxis:UILayoutConstraintAxisHorizontal];
        [secondRow setDistribution:UIStackViewDistributionFillEqually];
        [secondRow setSpacing:10.0f];

        homeRows_ = [[NSArray alloc] initWithObjects:socialRow, firstRow, secondRow, nil];

        featuredScroll_ = [[[UIScrollView alloc] init] autorelease];
        [featuredScroll_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        // Carousel phase uses forward content coordinates. Keep this artwork
        // strip in that order so an RTL 6-to-60 handoff retains the visible card.
        [featuredScroll_ setSemanticContentAttribute:UISemanticContentAttributeForceLeftToRight];
        [featuredScroll_ setDelegate:self];
        [featuredScroll_ setShowsHorizontalScrollIndicator:NO];
        [featuredScroll_ setBounces:NO];
        [featuredScroll_ setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentNever];
        [featuredScroll_ setDirectionalLockEnabled:YES];
        // Preserve UIKit's full, soft finger inertia. Fast deceleration feels
        // like the strip hits a brake as soon as the user lets go.
        [featuredScroll_ setDecelerationRate:UIScrollViewDecelerationRateNormal];
        [featuredScroll_ setContentInset:UIEdgeInsetsMake(0.0f, 4.0f, 0.0f, 4.0f)];
        [featuredScroll_ setHidden:YES];

        featuredStack_ = [[[UIStackView alloc] init] autorelease];
        [featuredStack_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [featuredStack_ setSemanticContentAttribute:UISemanticContentAttributeForceLeftToRight];
        [featuredStack_ setAxis:UILayoutConstraintAxisHorizontal];
        [featuredStack_ setAlignment:UIStackViewAlignmentFill];
        [featuredStack_ setSpacing:12.0f];
        [featuredScroll_ addSubview:featuredStack_];

        UILabel *footer(CYM3Label(UIFontTextStyleFootnote, [UIColor secondaryLabelColor], 1));
        [footer setText:@"Cydia 1.1.30"];
        homeVersion_ = footer;
        [footer setTextAlignment:NSTextAlignmentCenter];

        [content addArrangedSubview:hero];
        [content addArrangedSubview:featuredScroll_];
        [content addArrangedSubview:socialRow];
        [content addArrangedSubview:account];
        [content addArrangedSubview:quickTitle];
        [content addArrangedSubview:firstRow];
        [content addArrangedSubview:secondRow];
        [content addArrangedSubview:footer];
        [content setCustomSpacing:14.0f afterView:hero];
        [content setCustomSpacing:18.0f afterView:featuredScroll_];
        [content setCustomSpacing:18.0f afterView:account];
        [content setCustomSpacing:18.0f afterView:secondRow];

        homeScrollBottom_ = [[[scroll bottomAnchor] constraintEqualToAnchor:[self bottomAnchor]] retain];
        featuredHeight_ = [[[featuredScroll_ heightAnchor] constraintEqualToConstant:148.0f] retain];
        [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
            [[scroll leadingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] leadingAnchor]],
            [[scroll trailingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] trailingAnchor]],
            [[scroll topAnchor] constraintEqualToAnchor:[self topAnchor]],
            homeScrollBottom_,
            [[content leadingAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] leadingAnchor] constant:16.0f],
            [[content trailingAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] trailingAnchor] constant:-16.0f],
            [[content topAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] topAnchor] constant:12.0f],
            [[content bottomAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] bottomAnchor] constant:-24.0f],
            [[content widthAnchor] constraintEqualToAnchor:[[scroll frameLayoutGuide] widthAnchor] constant:-32.0f],
            [[hero heightAnchor] constraintGreaterThanOrEqualToConstant:146.0f],
            [[heroRow_ leadingAnchor] constraintGreaterThanOrEqualToAnchor:[hero leadingAnchor] constant:12.0f],
            [[heroRow_ trailingAnchor] constraintLessThanOrEqualToAnchor:[hero trailingAnchor] constant:-12.0f],
            [[heroRow_ centerXAnchor] constraintEqualToAnchor:[hero centerXAnchor]],
            [[heroRow_ widthAnchor] constraintLessThanOrEqualToConstant:640.0f],
            [[heroRow_ topAnchor] constraintEqualToAnchor:[hero topAnchor] constant:16.0f],
            [[heroRow_ bottomAnchor] constraintEqualToAnchor:[hero bottomAnchor] constant:-16.0f],
            [[appIcon widthAnchor] constraintEqualToConstant:78.0f],
            [[appIcon heightAnchor] constraintEqualToConstant:78.0f],
            [[socialRow heightAnchor] constraintGreaterThanOrEqualToConstant:64.0f],
            [[account heightAnchor] constraintGreaterThanOrEqualToConstant:64.0f],
            [[firstRow heightAnchor] constraintGreaterThanOrEqualToConstant:84.0f],
            [[secondRow heightAnchor] constraintGreaterThanOrEqualToConstant:84.0f],
            featuredHeight_,
            [[featuredStack_ leadingAnchor] constraintEqualToAnchor:[[featuredScroll_ contentLayoutGuide] leadingAnchor] constant:4.0f],
            [[featuredStack_ trailingAnchor] constraintEqualToAnchor:[[featuredScroll_ contentLayoutGuide] trailingAnchor] constant:-4.0f],
            [[featuredStack_ topAnchor] constraintEqualToAnchor:[[featuredScroll_ contentLayoutGuide] topAnchor]],
            [[featuredStack_ bottomAnchor] constraintEqualToAnchor:[[featuredScroll_ contentLayoutGuide] bottomAnchor]],
            [[featuredStack_ heightAnchor] constraintEqualToAnchor:[[featuredScroll_ frameLayoutGuide] heightAnchor]],
        nil]];

        // Keep the icon and title together on iPad, while allowing the labels
        // to wrap within the available width on compact and zoomed displays.
        NSLayoutConstraint *heroWidth([[heroRow_ widthAnchor] constraintEqualToAnchor:[hero widthAnchor] constant:-24.0f]);
        [heroWidth setPriority:UILayoutPriorityDefaultLow - 1];
        [heroWidth setActive:YES];

        fullScreenDock_ = [[[UIView alloc] init] autorelease];
        [fullScreenDock_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [fullScreenDock_ setHidden:YES];
        [self addSubview:fullScreenDock_];
        showControls_ = [UIButton buttonWithType:UIButtonTypeCustom];
        [showControls_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [showControls_ setAccessibilityLabel:CYLocalize(@"Show Controls")];
        [showControls_ setAccessibilityHint:CYLocalize(@"Restore the navigation bar and tabs")];
        [fullScreenDock_ addSubview:showControls_];
        graffiti_ = [[[CYM3HomeGraffitiView alloc] initWithFrame:CGRectMake(0, 0, 304, 94)] autorelease];
        [graffiti_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [showControls_ addSubview:graffiti_];
        [NSLayoutConstraint activateConstraints:@[
            [[graffiti_ leadingAnchor] constraintEqualToAnchor:[showControls_ leadingAnchor]],
            [[graffiti_ trailingAnchor] constraintEqualToAnchor:[showControls_ trailingAnchor]],
            [[graffiti_ topAnchor] constraintEqualToAnchor:[showControls_ topAnchor]],
            [[graffiti_ bottomAnchor] constraintEqualToAnchor:[showControls_ bottomAnchor]]
        ]];
        graffitiBottom_ = [[[fullScreenDock_ bottomAnchor] constraintEqualToAnchor:[self bottomAnchor] constant:-8.0f] retain];
        NSLayoutConstraint *stageWidth([[fullScreenDock_ widthAnchor] constraintEqualToConstant:304.0f]);
        [stageWidth setPriority:UILayoutPriorityDefaultHigh];
        [stageWidth setActive:YES];
        [NSLayoutConstraint activateConstraints:@[
            [[fullScreenDock_ centerXAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] centerXAnchor]],
            graffitiBottom_,
            [[fullScreenDock_ widthAnchor] constraintLessThanOrEqualToAnchor:[[self safeAreaLayoutGuide] widthAnchor] constant:-24.0f],
            [[fullScreenDock_ heightAnchor] constraintEqualToConstant:94.0f],
            [[showControls_ leadingAnchor] constraintEqualToAnchor:[fullScreenDock_ leadingAnchor]],
            [[showControls_ trailingAnchor] constraintEqualToAnchor:[fullScreenDock_ trailingAnchor]],
            [[showControls_ topAnchor] constraintEqualToAnchor:[fullScreenDock_ topAnchor]],
            [[showControls_ bottomAnchor] constraintEqualToAnchor:[fullScreenDock_ bottomAnchor]]
        ]];
    }
    return self;
}

- (void) updateHomeAuthorFont {
    UIFont *font([UIFont preferredFontForTextStyle:UIFontTextStyleTitle3 compatibleWithTraitCollection:[self traitCollection]]);
    NSMutableAttributedString *author([[[NSMutableAttributedString alloc] initWithString:CYLocalize(@"by Jay Freeman (saurik)")
        attributes:@{NSFontAttributeName:font}] autorelease]);
    NSRange authorRange([[author string] rangeOfString:@"Jay Freeman (saurik)"]);
    if (authorRange.location != NSNotFound)
        [author addAttribute:NSFontAttributeName value:[UIFont systemFontOfSize:[font pointSize] weight:UIFontWeightSemibold]
            range:authorRange];
    [heroAuthor_ setAttributedText:author];
}

- (void) layoutSubviews {
    UIEdgeInsets safe([self safeAreaInsets]);
    CGFloat featuredHeight(CYM3FeaturedHeight([self traitCollection]));
    if (fabs([featuredHeight_ constant] - featuredHeight) > 0.5f)
        [featuredHeight_ setConstant:featuredHeight];
    CGFloat width(CGRectGetWidth([self bounds]) - safe.left - safe.right);
    BOOL largeText([[UIFont preferredFontForTextStyle:UIFontTextStyleBody compatibleWithTraitCollection:[self traitCollection]] pointSize] > 17.0f);
    UIFont *titleFont([[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1]
        scaledFontForFont:[UIFont systemFontOfSize:width < 430.0f ? 24.0f : 28.0f]
        compatibleWithTraitCollection:[self traitCollection]]);
    if (fabs([[heroTitle_ font] pointSize] - [titleFont pointSize]) > 0.1f)
        [heroTitle_ setFont:titleFont];
    CGFloat bottomSafe([[self window] safeAreaInsets].bottom);
    [graffitiBottom_ setConstant:-(bottomSafe + 8.0f)];
    // Reserve a dedicated bottom stage; artwork never covers package actions.
    CGFloat stage(fullScreenControlsVisible_ ? 94.0f + bottomSafe + 20.0f : 0.0f);
    if (fabs([homeScrollBottom_ constant] + stage) > 0.5f)
        [homeScrollBottom_ setConstant:-stage];
    UILayoutConstraintAxis heroAxis(width < 390.0f || largeText ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal);
    UILayoutConstraintAxis rowAxis(width < 390.0f || largeText ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal);
    if ([heroRow_ axis] != heroAxis)
        [heroRow_ setAxis:heroAxis];
    for (UIStackView *row in homeRows_)
        if ([row axis] != rowAxis)
            [row setAxis:rowAxis];
    [super layoutSubviews];
    [self ensureFeaturedCoverage];
}

- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateHomeAuthorFont];
    [self setNeedsLayout];
}

- (void) setFullScreenControlsVisible:(BOOL)visible animated:(BOOL)animated target:(id)target action:(SEL)action {
    [showControls_ removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [showControls_ addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    if (fullScreenControlsVisible_ == visible)
        return;
    fullScreenControlsVisible_ = visible;
    [homeVersion_ setHidden:visible];
    [fullScreenDock_ setUserInteractionEnabled:visible];
    [fullScreenDock_ setAccessibilityElementsHidden:!visible];
    [[fullScreenDock_ layer] removeAllAnimations];
    [self setNeedsLayout];
    if (visible) {
        // Resolve and render the final geometry before revealing the mark.
        // Its scale animation alone owns the entrance; a parent fade/slide
        // would make the same reveal appear to start twice.
        [UIView performWithoutAnimation:^{
            [fullScreenDock_ setHidden:NO];
            [fullScreenDock_ setAlpha:1.0f];
            [fullScreenDock_ setTransform:CGAffineTransformIdentity];
            [self layoutIfNeeded];
            [graffiti_ layoutIfNeeded];
        }];
        [graffiti_ paintAnimated:animated];
        return;
    }
    [graffiti_ stopPainting];
    if (!animated || UIAccessibilityIsReduceMotionEnabled()) {
        [fullScreenDock_ setHidden:YES];
        [fullScreenDock_ setAlpha:0.0f];
        [fullScreenDock_ setTransform:CGAffineTransformIdentity];
        return;
    }
    [UIView animateWithDuration:0.18 delay:0
        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
        animations:^{
            [fullScreenDock_ setAlpha:0.0f];
        } completion:^(BOOL finished) {
            if (!fullScreenControlsVisible_)
                [fullScreenDock_ setHidden:YES];
        }];
}

- (void) setActionTarget:(id)target action:(SEL)action {
    actionTarget_ = target;
    actionSelector_ = action;
    for (UIButton *button in actionButtons_) {
        [button removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    }
}

- (void) setQuickActionSourceCount:(NSUInteger)sources
                       updateCount:(NSUInteger)updates
                    installedCount:(NSUInteger)installed
                    availableCount:(NSUInteger)available {
    NSString *sourceText(CYLocalizedMetric(CYLocalize(@"Repositories"), sources));
    NSString *updateText(CYLocalizedMetric(CYLocalize(@"Updates"), updates));
    NSString *installedText(CYLocalizedMetric(CYLocalize(@"User"), installed));
    NSString *availableText(CYLocalizedMetric(CYLocalize(@"Packages"), available));

    [sourcesMetric_ setText:sourceText];
    [changesMetric_ setText:updateText];
    [installedMetric_ setText:installedText];
    [searchMetric_ setText:availableText];

    NSArray *values([NSArray arrayWithObjects:sourceText, updateText, installedText, availableText, nil]);
    for (NSUInteger index(0); index < 4 && index < [actionButtons_ count]; ++index)
        [[actionButtons_ objectAtIndex:index] setAccessibilityValue:[values objectAtIndex:index]];
}

- (void) loadFeaturedArtwork {
    // Acceptance or a later Home refresh resumes missing artwork without
    // rebuilding cards, reshuffling the strip, or restarting its position.
    for (CYM3FeaturedPackageButton *card in [featuredStack_ arrangedSubviews])
        [card loadBannerIfNeeded];
}

- (void) setFeaturedPackages:(NSArray *)packages {
    if ([featuredRecords_ isEqualToArray:packages])
        return;
    NSDictionary *position([self featuredPosition]);
    [self stopFeaturedTicker];
    featuredRebuilding_ = YES;
    NSArray *oldCards([[featuredStack_ arrangedSubviews] copy]);
    NSMutableDictionary *reusable([NSMutableDictionary dictionary]);
    for (CYM3FeaturedPackageButton *view in oldCards) {
        NSArray *key(@[[view accessibilityIdentifier] ?: @"", [view featuredImageURL] ?: @""]);
        NSMutableArray *cards([reusable objectForKey:key]);
        if (cards == nil) {
            cards = [NSMutableArray array];
            [reusable setObject:cards forKey:key];
        }
        [cards addObject:view];
        [featuredStack_ removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSArray *snapshot([packages copy]);
    [featuredRecords_ release];
    featuredRecords_ = snapshot;
    NSUInteger count([packages count]);
    BOOL available(count != 0);
    [featuredScroll_ setHidden:!available];
    if (!available) {
        featuredCycleWidth_ = 0.0f;
        featuredRebuilding_ = NO;
        [oldCards release];
        return;
    }

    // Match Sileo's curated 263 x 148 artwork contract exactly so the app or
    // tweak remains visible instead of being replaced by an enlarged icon.
    featuredCardWidth_ = 263.0f;
    featuredCycleWidth_ = count * featuredCardWidth_ + count * [featuredStack_ spacing];
    [self ensureFeaturedCoverageWithReusableCards:reusable];
    [UIView performWithoutAnimation:^{
        [self layoutIfNeeded];
        [featuredScroll_ layoutIfNeeded];
        [featuredStack_ layoutIfNeeded];
        [self restoreFeaturedPosition:position];
    }];
    featuredRebuilding_ = NO;
    [oldCards release];
    if (featuredTravelVelocity_ == 0.0f)
        featuredTravelVelocity_ = 14.0f;
    [self startFeaturedTicker];
}

- (NSDictionary *) featuredPosition {
    if (featuredCycleWidth_ <= 0.0f || [featuredRecords_ count] == 0)
        return nil;
    CGFloat stride(featuredCardWidth_ + [featuredStack_ spacing]);
    CGFloat phase(fmod([featuredScroll_ contentOffset].x, featuredCycleWidth_));
    if (phase < 0.0f) phase += featuredCycleWidth_;
    NSUInteger index(MIN((NSUInteger)floor(phase / stride), [featuredRecords_ count] - 1));
    NSString *identifier([[featuredRecords_ objectAtIndex:index] objectForKey:@"identifier"]);
    return identifier == nil ? nil : @{@"identifier":identifier, @"offset":@(phase - index * stride)};
}

- (void) restoreFeaturedPosition:(NSDictionary *)position {
    CGFloat offset(featuredCycleWidth_);
    for (NSUInteger index(0); position != nil && index < [featuredRecords_ count]; ++index)
        if ([[[featuredRecords_ objectAtIndex:index] objectForKey:@"identifier"] isEqual:[position objectForKey:@"identifier"]]) {
            offset += index * (featuredCardWidth_ + [featuredStack_ spacing]) + [[position objectForKey:@"offset"] doubleValue];
            break;
        }
    [featuredScroll_ setContentOffset:CGPointMake(offset, 0.0f) animated:NO];
}

- (void) continueFeaturedPositionFromView:(CydiaModernHomeView *)home {
    if (home == nil || home == self || featuredCycleWidth_ <= 0.0f)
        return;
    // Transfer already displayed artwork as well as its position. NSCache may
    // have evicted an image that the launch cards still retain; the live Home
    // must not go blank and wait for a second asynchronous disk decode.
    NSMutableDictionary *artwork([NSMutableDictionary dictionary]);
    for (CYM3FeaturedPackageButton *card in [home->featuredStack_ arrangedSubviews]) {
        NSString *url([card featuredImageURL]);
        UIImage *image([card loadedBannerImage]);
        if ([url length] != 0 && image != nil) {
            [artwork setObject:image forKey:url];
            [CYM3FeaturedBannerCache() setObject:image forKey:url cost:CYM3FeaturedBannerCost(image)];
        }
    }
    for (CYM3FeaturedPackageButton *card in [featuredStack_ arrangedSubviews]) {
        NSString *url([card featuredImageURL]);
        if ([url length] != 0)
            [card adoptLoadedBannerImage:[artwork objectForKey:url]];
    }
    featuredRebuilding_ = YES;
    [UIView performWithoutAnimation:^{
        [self layoutIfNeeded];
        [featuredScroll_ layoutIfNeeded];
        [self restoreFeaturedPosition:[home featuredPosition]];
    }];
    featuredRebuilding_ = NO;
    featuredTravelVelocity_ = 14.0f;
    featuredLastTimestamp_ = 0.0;
}

- (void) ensureFeaturedCoverage {
    [self ensureFeaturedCoverageWithReusableCards:nil];
}

- (void) ensureFeaturedCoverageWithReusableCards:(NSMutableDictionary *)reusable {
    NSUInteger count([featuredRecords_ count]);
    if (count == 0 || featuredCycleWidth_ <= 0.0f)
        return;
    CGFloat viewport(MAX(CGRectGetWidth([featuredScroll_ bounds]), CGRectGetWidth([self bounds]) - 32.0f));
    // Keep a complete viewport after the wrap boundary, even for one banner
    // on an iPad or after rotation. Appending preserves order and scroll offset.
    NSUInteger sequences(MAX((NSUInteger)3, (NSUInteger)ceil(viewport / featuredCycleWidth_) + 2));
    NSUInteger existing([[featuredStack_ arrangedSubviews] count] / count);
    for (NSUInteger copy(existing); copy < sequences; ++copy) {
        for (NSUInteger index(0); index != count; ++index) {
            NSDictionary *package([featuredRecords_ objectAtIndex:index]);
            NSArray *key(@[[package objectForKey:@"identifier"] ?: @"", [package objectForKey:@"imageURL"] ?: @""]);
            NSMutableArray *cards([reusable objectForKey:key]);
            CYM3FeaturedPackageButton *card(nil);
            if ([cards count] != 0) {
                card = [[[cards objectAtIndex:0] retain] autorelease];
                [cards removeObjectAtIndex:0];
                [card updateFeaturedPackage:package];
            } else {
                card = [[[CYM3FeaturedPackageButton alloc] initWithPackage:package palette:index] autorelease];
                [[card widthAnchor] constraintEqualToConstant:featuredCardWidth_].active = YES;
            }
            [card setTag:200];
            [card removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
            if (actionTarget_ != nil && actionSelector_ != NULL)
                [card addTarget:actionTarget_ action:actionSelector_ forControlEvents:UIControlEventTouchUpInside];
            [featuredStack_ addArrangedSubview:card];
        }
    }
}

- (void) refreshFeaturedMotion {
    [self stopFeaturedTicker];
    [self startFeaturedTicker];
}

- (void) resumeFeaturedMotion {
    if ([self window] != nil)
        [self loadFeaturedArtwork];
    // Start forward from the same visible artwork; never replay a previous
    // reverse throw or count time spent outside the app as animation time.
    featuredTravelVelocity_ = 14.0f;
    [self refreshFeaturedMotion];
}

- (void) startFeaturedTicker {
    if (featuredTicker_ != nil || featuredCycleWidth_ <= 0.0f || UIAccessibilityIsReduceMotionEnabled() || UIAccessibilityIsVoiceOverRunning() ||
        [[UIApplication sharedApplication] applicationState] != UIApplicationStateActive || [self window] == nil)
        return;
    featuredLastTimestamp_ = 0.0;
    featuredTicker_ = [[CADisplayLink displayLinkWithTarget:self selector:@selector(advanceFeaturedCarousel:)] retain];
    [featuredTicker_ addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void) stopFeaturedTicker {
    [featuredTicker_ invalidate];
    [featuredTicker_ release];
    featuredTicker_ = nil;
    featuredLastTimestamp_ = 0.0;
}

- (void) advanceFeaturedCarousel:(CADisplayLink *)ticker {
    if ([featuredScroll_ isTracking] || [featuredScroll_ isDragging] || [featuredScroll_ isDecelerating] ||
        [[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
        featuredLastTimestamp_ = [ticker timestamp];
        return;
    }
    if (featuredLastTimestamp_ == 0.0) {
        featuredLastTimestamp_ = [ticker timestamp];
        return;
    }
    CFTimeInterval elapsed(MAX(0.0, MIN(0.05, [ticker timestamp] - featuredLastTimestamp_)));
    featuredLastTimestamp_ = [ticker timestamp];
    CGFloat direction(featuredTravelVelocity_ < 0.0f ? -1.0f : 1.0f);
    CGFloat speed(fabs(featuredTravelVelocity_));
    // A throw keeps moving forever in the direction selected by the user.
    // Its fast impulse eases into a quiet cruise but never stops or reverses.
    if (speed > 14.0f)
        speed = MAX(14.0f, speed - (CGFloat) (elapsed * 150.0f));
    else if (speed < 14.0f)
        speed = MIN(14.0f, speed + (CGFloat) (elapsed * 22.0f));
    featuredTravelVelocity_ = direction * speed;
    CGPoint offset([featuredScroll_ contentOffset]);
    offset.x += (CGFloat) (elapsed * featuredTravelVelocity_);
    [featuredScroll_ setContentOffset:offset animated:NO];
    [self normalizeFeaturedOffset];
}

- (void) normalizeFeaturedOffset {
    if (featuredRebuilding_ || featuredCycleWidth_ <= 0.0f)
        return;
    CGPoint offset([featuredScroll_ contentOffset]);
    CGFloat previous(offset.x);
    if (offset.x >= featuredCycleWidth_ * 2.0f)
        offset.x -= featuredCycleWidth_;
    else if (offset.x < featuredCycleWidth_ * 0.5f)
        offset.x += featuredCycleWidth_;
    if (fabs(offset.x - previous) > 0.01f) {
        featuredRebuilding_ = YES;
        [featuredScroll_ setContentOffset:offset animated:NO];
        featuredRebuilding_ = NO;
    }
}

- (void) scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView != featuredScroll_)
        return;
    featuredLastTimestamp_ = 0.0;
}

- (void) scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == featuredScroll_ && ![scrollView isTracking])
        [self normalizeFeaturedOffset];
}

- (void) scrollViewWillEndDragging:(UIScrollView *)scrollView
    withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    if (scrollView != featuredScroll_ || UIAccessibilityIsReduceMotionEnabled() || UIAccessibilityIsVoiceOverRunning())
        return;
    CGFloat fingerVelocity([[scrollView panGestureRecognizer] velocityInView:scrollView].x);
    CGFloat contentVelocity(-fingerVelocity);
    if (fabs(contentVelocity) >= 18.0f)
        featuredTravelVelocity_ = MAX(-620.0f, MIN(620.0f, contentVelocity));
    else
        featuredTravelVelocity_ = featuredTravelVelocity_ < 0.0f ? -14.0f : 14.0f;

    // Suppress UIKit's separate braking animation; the display link takes
    // over this direction continuously on the next frame.
    *targetContentOffset = [scrollView contentOffset];
}

- (void) scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (scrollView == featuredScroll_ && !decelerate)
        featuredLastTimestamp_ = 0.0;
}

- (void) scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView == featuredScroll_)
        featuredLastTimestamp_ = 0.0;
}

- (void) didMoveToWindow {
    [super didMoveToWindow];
    if ([self window] != nil) {
        [self loadFeaturedArtwork];
        [self startFeaturedTicker];
    }
}

- (void) willMoveToWindow:(UIWindow *)newWindow {
    if (newWindow == nil)
        [self stopFeaturedTicker];
    [super willMoveToWindow:newWindow];
}

@end

@interface CydiaModernEssentialView () {
    UILabel *title_;
    UILabel *message_;
    UIButton *essential_;
    UIButton *complete_;
    UIButton *ignore_;
}
@end

@implementation CydiaModernEssentialView

- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
        [self setBackgroundColor:[UIColor systemGroupedBackgroundColor]];

        UIVisualEffectView *card(CYM3ContentCard(24.0f));
        UIScrollView *scroll([[[UIScrollView alloc] init] autorelease]);
        [scroll setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self addSubview:scroll];
        [scroll addSubview:card];

        UIImageView *icon([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:@"arrow.up.circle.fill"]] autorelease]);
        [icon setTranslatesAutoresizingMaskIntoConstraints:NO];
        [icon setContentMode:UIViewContentModeScaleAspectFit];
        [icon setTintColor:CYModernAccentColor()];
        [icon setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:40.0f weight:UIImageSymbolWeightSemibold]];

        UIView *iconRow([[[UIView alloc] init] autorelease]);
        [iconRow addSubview:icon];
        title_ = CYM3Label(UIFontTextStyleTitle2, [UIColor labelColor], 2);
        [title_ setTextAlignment:NSTextAlignmentCenter];
        message_ = CYM3Label(UIFontTextStyleBody, [UIColor secondaryLabelColor], 0);
        [message_ setTextAlignment:NSTextAlignmentCenter];

        complete_ = CYM3FilledButton();
        [complete_ setTag:2];
        essential_ = [CYM3AdaptiveButton buttonWithType:UIButtonTypeSystem];
        [essential_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [essential_ setContentEdgeInsets:UIEdgeInsetsMake(10.0f, 14.0f, 10.0f, 14.0f)];
        [essential_ setTag:1];
        [essential_ setBackgroundColor:[CYModernAccentColor() colorWithAlphaComponent:0.12f]];
        [[essential_ layer] setCornerRadius:14.0f];
        [[essential_ layer] setCornerCurve:kCACornerCurveContinuous];
        [[essential_ titleLabel] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
        [[essential_ titleLabel] setAdjustsFontForContentSizeCategory:YES];
        [[essential_ titleLabel] setNumberOfLines:0];
        [[essential_ titleLabel] setTextAlignment:NSTextAlignmentCenter];

        ignore_ = [CYM3AdaptiveButton buttonWithType:UIButtonTypeSystem];
        [ignore_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [ignore_ setContentEdgeInsets:UIEdgeInsetsMake(8.0f, 14.0f, 8.0f, 14.0f)];
        [ignore_ setTag:0];
        [[ignore_ titleLabel] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]];
        [[ignore_ titleLabel] setAdjustsFontForContentSizeCategory:YES];
        [[ignore_ titleLabel] setNumberOfLines:0];
        [[ignore_ titleLabel] setTextAlignment:NSTextAlignmentCenter];
        [ignore_ setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];

        UIStackView *stack([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:iconRow, title_, message_, complete_, essential_, ignore_, nil]] autorelease]);
        [stack setTranslatesAutoresizingMaskIntoConstraints:NO];
        [stack setAxis:UILayoutConstraintAxisVertical];
        [stack setAlignment:UIStackViewAlignmentFill];
        [stack setSpacing:12.0f];
        [stack setCustomSpacing:18.0f afterView:message_];
        [[card contentView] addSubview:stack];

        [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
            [[scroll leadingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] leadingAnchor]],
            [[scroll trailingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] trailingAnchor]],
            [[scroll topAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] topAnchor]],
            [[scroll bottomAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] bottomAnchor]],
            [[card leadingAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] leadingAnchor] constant:16.0f],
            [[card trailingAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] trailingAnchor] constant:-16.0f],
            [[card topAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] topAnchor] constant:24.0f],
            [[card bottomAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] bottomAnchor] constant:-16.0f],
            [[card widthAnchor] constraintEqualToAnchor:[[scroll frameLayoutGuide] widthAnchor] constant:-32.0f],
            [[iconRow heightAnchor] constraintEqualToConstant:52.0f],
            [[icon widthAnchor] constraintEqualToConstant:52.0f],
            [[icon heightAnchor] constraintEqualToConstant:52.0f],
            [[icon centerXAnchor] constraintEqualToAnchor:[iconRow centerXAnchor]],
            [[icon centerYAnchor] constraintEqualToAnchor:[iconRow centerYAnchor]],
            [[stack leadingAnchor] constraintEqualToAnchor:[[card contentView] leadingAnchor] constant:20.0f],
            [[stack trailingAnchor] constraintEqualToAnchor:[[card contentView] trailingAnchor] constant:-20.0f],
            [[stack topAnchor] constraintEqualToAnchor:[[card contentView] topAnchor] constant:22.0f],
            [[stack bottomAnchor] constraintEqualToAnchor:[[card contentView] bottomAnchor] constant:-18.0f],
            [[complete_ heightAnchor] constraintGreaterThanOrEqualToConstant:52.0f],
            [[essential_ heightAnchor] constraintGreaterThanOrEqualToConstant:50.0f],
            [[ignore_ heightAnchor] constraintGreaterThanOrEqualToConstant:44.0f],
        nil]];
    }
    return self;
}

- (void) configureWithTitle:(NSString *)title
                    message:(NSString *)message
             essentialTitle:(NSString *)essentialTitle
              completeTitle:(NSString *)completeTitle
                ignoreTitle:(NSString *)ignoreTitle
                     target:(id)target
                     action:(SEL)action {
    [title_ setText:title];
    [message_ setText:message];
    [essential_ setTitle:essentialTitle forState:UIControlStateNormal];
    [complete_ setTitle:completeTitle forState:UIControlStateNormal];
    [ignore_ setTitle:ignoreTitle forState:UIControlStateNormal];
    for (UIButton *button in [NSArray arrayWithObjects:essential_, complete_, ignore_, nil]) {
        [button removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    }
}

@end


@interface CydiaModernProgressTrack : UIView {
    CAGradientLayer *fillLayer_;
    float progressValue_;
    BOOL indeterminate_;
    BOOL failureTint_;
}
- (void) setProgressValue:(float)value animated:(BOOL)animated;
- (void) setIndeterminate:(BOOL)indeterminate;
- (void) setFailureTint:(BOOL)failure;
@end

@implementation CydiaModernProgressTrack

- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
        [self setTranslatesAutoresizingMaskIntoConstraints:NO];
        NSNotificationCenter *motionCenter([NSNotificationCenter defaultCenter]);
        [motionCenter addObserver:self selector:@selector(refreshMotion) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
        [motionCenter addObserver:self selector:@selector(stopMotion) name:UIApplicationWillResignActiveNotification object:nil];
        [motionCenter addObserver:self selector:@selector(refreshMotion) name:UIApplicationDidBecomeActiveNotification object:nil];
        [motionCenter addObserver:self selector:@selector(refreshMotion) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
        [self setBackgroundColor:[UIColor tertiarySystemFillColor]];
        [[self layer] setCornerRadius:5.0f];
        [[self layer] setCornerCurve:kCACornerCurveContinuous];
        [[self layer] setMasksToBounds:YES];
        fillLayer_ = [[CAGradientLayer layer] retain];
        [fillLayer_ setStartPoint:CGPointMake(0.0f, 0.5f)];
        [fillLayer_ setEndPoint:CGPointMake(1.0f, 0.5f)];
        [fillLayer_ setCornerRadius:5.0f];
        [[self layer] addSublayer:fillLayer_];
        [self setFailureTint:NO];
        [self setIsAccessibilityElement:YES];
        [self setAccessibilityLabel:CYLocalize(@"Progress")];
        [self setAccessibilityTraits:UIAccessibilityTraitUpdatesFrequently];
    }
    return self;
}

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [fillLayer_ release];
    [super dealloc];
}

- (void) stopMotion {
    [fillLayer_ removeAnimationForKey:@"CydiaCompactProgressSweep"];
}
- (void) refreshMotion {
    [self stopMotion];
    [self setNeedsLayout];
}
- (void) layoutSubviews {
    [super layoutSubviews];
    CGFloat width(CGRectGetWidth([self bounds]));
    CGFloat height(CGRectGetHeight([self bounds]));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (indeterminate_)
        [fillLayer_ setFrame:CGRectMake(0.0f, 0.0f, MAX(36.0f, width * 0.28f), height)];
    else
        [fillLayer_ setFrame:CGRectMake(0.0f, 0.0f,
            progressValue_ <= 0.0f ? 0.0f : MAX(height, width * progressValue_), height)];
    [CATransaction commit];

    if (indeterminate_ && !UIAccessibilityIsReduceMotionEnabled() &&
        [[UIApplication sharedApplication] applicationState] == UIApplicationStateActive && width > 0.0f && [fillLayer_ animationForKey:@"CydiaCompactProgressSweep"] == nil) {
        CABasicAnimation *sweep([CABasicAnimation animationWithKeyPath:@"transform.translation.x"]);
        [sweep setFromValue:[NSNumber numberWithFloat:-MAX(36.0f, width * 0.28f)]];
        [sweep setToValue:[NSNumber numberWithFloat:width]];
        [sweep setDuration:1.05];
        [sweep setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
        [sweep setRepeatCount:FLT_MAX];
        [fillLayer_ addAnimation:sweep forKey:@"CydiaCompactProgressSweep"];
    }
}

- (void) setProgressValue:(float)value animated:(BOOL)animated {
    progressValue_ = MAX(0.0f, MIN(1.0f, value));
    indeterminate_ = NO;
    [fillLayer_ removeAnimationForKey:@"CydiaCompactProgressSweep"];
    [self setNeedsLayout];
    if (animated) {
        [UIView animateWithDuration:0.24 delay:0.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            [self layoutIfNeeded];
        } completion:nil];
    } else
        [self layoutIfNeeded];
    NSString *valueText([NSString stringWithFormat:CYLocalize(@"%.0f percent"), progressValue_ * 100.0f]);
    [self setAccessibilityValue:valueText];
}

- (void) setIndeterminate:(BOOL)indeterminate {
    indeterminate_ = indeterminate;
    if (!indeterminate_)
        [fillLayer_ removeAnimationForKey:@"CydiaCompactProgressSweep"];
    [self setNeedsLayout];
    [self setAccessibilityValue:indeterminate_ ? CYLocalize(@"In progress") : CYLocalizedPercent(progressValue_)];
}

- (void) setFailureTint:(BOOL)failure {
    failureTint_ = failure;
    UIColor *start([(failure ? [UIColor systemRedColor] : CYModernAccentColor()) resolvedColorWithTraitCollection:self.traitCollection]);
    UIColor *end([(failure ? [UIColor systemOrangeColor] : CYModernPrimaryButtonColor()) resolvedColorWithTraitCollection:self.traitCollection]);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [fillLayer_ setColors:@[(id)[start CGColor], (id)[end CGColor]]];
    [CATransaction commit];
}
- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous])
        [self setFailureTint:failureTint_];
}

@end

@interface CydiaModernProgressView () {
    UIView *stateIconTile_;
    UIVisualEffectView *restartPanel_;
    UIStackView *restartLights_;
    NSLayoutConstraint *stateIconWidth_;
    NSLayoutConstraint *stateIconHeight_;
    NSLayoutConstraint *contentMaximumWidth_;
    UIImageView *stateIcon_;
    CAShapeLayer *ringTrack_;
    CAShapeLayer *progressRing_;
    UILabel *title_;
    UILabel *status_;
    CydiaModernProgressTrack *progressTrack_;
    UILabel *metrics_;
    UILabel *phase_;
    UIStackView *progressLabels_;
    CYTransactionProgressState phaseState_;
    UILabel *percent_;
    UIButton *details_;
    UITextView *log_;
    NSLayoutConstraint *logHeight_;
    UIButton *finish_;
    BOOL expanded_;
    BOOL running_;
    BOOL error_;
    BOOL cancelled_;
    BOOL refreshing_;
    BOOL restarting_;
    BOOL restartRequired_;
    BOOL detailsBeforeRestart_;
    NSUInteger issueCount_;
}
- (void) toggleDetails;
- (NSString *) readableStatus:(NSString *)message;
- (void) updateStateAppearance;
- (void) updateStateLayerColors;
- (void) setRingStrokeEnd:(float)value animated:(BOOL)animated;
@end

@implementation CydiaModernProgressView

- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
        [self setTranslatesAutoresizingMaskIntoConstraints:NO];
        NSNotificationCenter *motionCenter([NSNotificationCenter defaultCenter]);
        [motionCenter addObserver:self selector:@selector(refreshMotion) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
        [motionCenter addObserver:self selector:@selector(stopMotion) name:UIApplicationWillResignActiveNotification object:nil];
        [motionCenter addObserver:self selector:@selector(refreshMotion) name:UIApplicationDidBecomeActiveNotification object:nil];
        [self setBackgroundColor:[UIColor systemGroupedBackgroundColor]];

        UIScrollView *scroll([[[UIScrollView alloc] init] autorelease]);
        [scroll setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self addSubview:scroll];
        UIView *canvas([[[UIView alloc] init] autorelease]);
        [canvas setTranslatesAutoresizingMaskIntoConstraints:NO];
        [scroll addSubview:canvas];
        stateIconTile_ = [[[UIView alloc] init] autorelease];
        [stateIconTile_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [stateIconTile_ setBackgroundColor:[CYModernAccentColor() colorWithAlphaComponent:0.11f]];
        [[stateIconTile_ layer] setCornerRadius:36.0f];
        [[stateIconTile_ layer] setCornerCurve:kCACornerCurveContinuous];

        stateIcon_ = [[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:@"arrow.triangle.2.circlepath"]] autorelease];
        [stateIcon_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [stateIcon_ setTintColor:CYModernAccentColor()];
        [stateIcon_ setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30.0f weight:UIImageSymbolWeightSemibold]];
        // Premium App Store-style progress ring hugging the state icon: the
        // faint full track plus an accent arc whose strokeEnd follows the real
        // download/install percentage. Purely a visual mirror of the same
        // real progress the bar below shows.
        const CGFloat ringInset(3.0f);
        const CGFloat ringRadius(36.0f - ringInset);
        UIBezierPath *ringPath([UIBezierPath bezierPathWithArcCenter:CGPointMake(36.0f, 36.0f)
            radius:ringRadius startAngle:(CGFloat) (-M_PI_2) endAngle:(CGFloat) (M_PI * 1.5) clockwise:YES]);
        ringTrack_ = [CAShapeLayer layer];
        [ringTrack_ setFrame:CGRectMake(0.0f, 0.0f, 72.0f, 72.0f)];
        [ringTrack_ setPath:[ringPath CGPath]];
        [ringTrack_ setFillColor:[[UIColor clearColor] CGColor]];
        [ringTrack_ setStrokeColor:[[CYModernAccentColor() colorWithAlphaComponent:0.16f] CGColor]];
        [ringTrack_ setLineWidth:4.0f];
        [[stateIconTile_ layer] addSublayer:ringTrack_];
        progressRing_ = [CAShapeLayer layer];
        [progressRing_ setFrame:CGRectMake(0.0f, 0.0f, 72.0f, 72.0f)];
        [progressRing_ setPath:[ringPath CGPath]];
        [progressRing_ setFillColor:[[UIColor clearColor] CGColor]];
        [progressRing_ setStrokeColor:[CYModernAccentColor() CGColor]];
        [progressRing_ setLineWidth:4.0f];
        [progressRing_ setLineCap:kCALineCapRound];
        [progressRing_ setStrokeEnd:0.0f];
        [[stateIconTile_ layer] addSublayer:progressRing_];

        [stateIconTile_ addSubview:stateIcon_];
        UIView *iconRow([[[UIView alloc] init] autorelease]);
        [iconRow setTranslatesAutoresizingMaskIntoConstraints:NO];
        [iconRow addSubview:stateIconTile_];

        title_ = CYM3Label(UIFontTextStyleTitle1, [UIColor labelColor], 0);
        [title_ setTextAlignment:NSTextAlignmentCenter];
        [title_ setFont:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1] scaledFontForFont:[UIFont systemFontOfSize:28.0f weight:UIFontWeightSemibold]]];
        status_ = CYM3Label(UIFontTextStyleSubheadline, [UIColor secondaryLabelColor], 0);
        [status_ setTextAlignment:NSTextAlignmentCenter];

        progressTrack_ = [[[CydiaModernProgressTrack alloc] initWithFrame:CGRectZero] autorelease];
        phase_ = CYM3Label(UIFontTextStyleFootnote, CYModernAccentColor(), 0);
        [phase_ setTextAlignment:NSTextAlignmentCenter];
        metrics_ = CYM3Label(UIFontTextStyleCaption1, [UIColor secondaryLabelColor], 0);
        percent_ = CYM3Label(UIFontTextStyleCaption1, [UIColor secondaryLabelColor], 1);
        [percent_ setTextAlignment:NSTextAlignmentRight];
        progressLabels_ = [[[UIStackView alloc] initWithArrangedSubviews:
            [NSArray arrayWithObjects:metrics_, percent_, nil]] autorelease];
        [progressLabels_ setAxis:UILayoutConstraintAxisHorizontal];
        [progressLabels_ setDistribution:UIStackViewDistributionFill];
        [progressLabels_ setSpacing:8.0f];
        [percent_ setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [metrics_ setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        UIStackView *content([[[UIStackView alloc] initWithArrangedSubviews:
            [NSArray arrayWithObjects:iconRow, phase_, title_, status_, progressTrack_, progressLabels_, nil]] autorelease]);
        [content setTranslatesAutoresizingMaskIntoConstraints:NO];
        [content setAxis:UILayoutConstraintAxisVertical];
        [content setAlignment:UIStackViewAlignmentFill];
        [content setSpacing:12.0f];
        [content setCustomSpacing:18.0f afterView:iconRow];
        [content setCustomSpacing:7.0f afterView:title_];
        [content setCustomSpacing:24.0f afterView:status_];
        [content setCustomSpacing:7.0f afterView:progressTrack_];
        restartLights_ = [[[UIStackView alloc] init] autorelease];
        [restartLights_ setAxis:UILayoutConstraintAxisHorizontal];
        [restartLights_ setAlignment:UIStackViewAlignmentCenter];
        [restartLights_ setDistribution:UIStackViewDistributionEqualCentering];
        UIView *lightRow([[[UIView alloc] init] autorelease]);
        [restartLights_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [lightRow addSubview:restartLights_];
        for (NSUInteger index(0); index < 3; ++index) {
            UIView *light([[[UIView alloc] init] autorelease]);
            [light setBackgroundColor:CYModernAccentColor()];
            [[light layer] setCornerRadius:3.0];
            [light setAlpha:0.45];
            [restartLights_ addArrangedSubview:light];
            [[light widthAnchor] constraintEqualToConstant:6.0].active = YES;
            [[light heightAnchor] constraintEqualToConstant:6.0].active = YES;
        }
        [[restartLights_ centerXAnchor] constraintEqualToAnchor:[lightRow centerXAnchor]].active = YES;
        [[restartLights_ centerYAnchor] constraintEqualToAnchor:[lightRow centerYAnchor]].active = YES;
        [[restartLights_ widthAnchor] constraintEqualToConstant:42.0].active = YES;
        NSLayoutConstraint *lightHeight([[lightRow heightAnchor] constraintEqualToConstant:8.0]);
        [lightHeight setPriority:999];
        [lightHeight setActive:YES];
        [lightRow setHidden:YES];
        [content addArrangedSubview:lightRow];
        restartPanel_ = CYM3FloatingPanel();
        [restartPanel_ setHidden:YES];
        [canvas addSubview:restartPanel_];
        [canvas addSubview:content];

        details_ = [CYM3AdaptiveButton buttonWithType:UIButtonTypeSystem];
        [details_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [[details_ titleLabel] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]];
        [[details_ titleLabel] setAdjustsFontForContentSizeCategory:YES];
        [[details_ titleLabel] setNumberOfLines:0];
        [[details_ titleLabel] setTextAlignment:NSTextAlignmentCenter];
        [details_ setTitle:CYLocalize(@"View details") forState:UIControlStateNormal];
        [details_ setImage:[UIImage cy_symbolNamed:@"chevron.down"] forState:UIControlStateNormal];
        [details_ setSemanticContentAttribute:UISemanticContentAttributeForceRightToLeft];
        [details_ setImageEdgeInsets:UIEdgeInsetsMake(0.0f, 7.0f, 0.0f, -7.0f)];
        [details_ addTarget:self action:@selector(toggleDetails) forControlEvents:UIControlEventTouchUpInside];
        [details_ setHidden:NO];
        [canvas addSubview:details_];

        log_ = [[[UITextView alloc] initWithFrame:CGRectZero] autorelease];
        [log_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [log_ setEditable:NO];
        [log_ setSelectable:YES];
        [log_ setBackgroundColor:[UIColor clearColor]];
        [log_ setTextContainerInset:UIEdgeInsetsMake(4.0f, 0.0f, 4.0f, 0.0f)];
        [log_ setFont:[UIFont monospacedSystemFontOfSize:11.5f weight:UIFontWeightRegular]];
        [log_ setTextColor:[UIColor secondaryLabelColor]];
        [log_ setHidden:YES];
        [log_ setAccessibilityLabel:CYLocalize(@"Technical details")];
        [canvas addSubview:log_];

        finish_ = CYM3FilledButton();
        [finish_ setHidden:YES];
        [[finish_ layer] setCornerRadius:16.0f];
        [self addSubview:finish_];

        logHeight_ = [[log_ heightAnchor] constraintEqualToConstant:0.0f];
        [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
            [[scroll leadingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] leadingAnchor]],
            [[scroll trailingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] trailingAnchor]],
            [[scroll topAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] topAnchor]],
            [[scroll bottomAnchor] constraintEqualToAnchor:[finish_ topAnchor] constant:-12.0f],
            [[canvas leadingAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] leadingAnchor]],
            [[canvas trailingAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] trailingAnchor]],
            [[canvas topAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] topAnchor]],
            [[canvas bottomAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] bottomAnchor]],
            [[canvas widthAnchor] constraintEqualToAnchor:[[scroll frameLayoutGuide] widthAnchor]],
            [[canvas heightAnchor] constraintGreaterThanOrEqualToAnchor:[[scroll frameLayoutGuide] heightAnchor]],
            [[content leadingAnchor] constraintGreaterThanOrEqualToAnchor:[canvas leadingAnchor] constant:44.0f],
            [[content trailingAnchor] constraintLessThanOrEqualToAnchor:[canvas trailingAnchor] constant:-44.0f],
            [[content centerXAnchor] constraintEqualToAnchor:[canvas centerXAnchor]],
            [[restartPanel_ leadingAnchor] constraintEqualToAnchor:[content leadingAnchor] constant:-24.0f],
            [[restartPanel_ trailingAnchor] constraintEqualToAnchor:[content trailingAnchor] constant:24.0f],
            [[restartPanel_ topAnchor] constraintEqualToAnchor:[content topAnchor] constant:-28.0f],
            [[restartPanel_ bottomAnchor] constraintEqualToAnchor:[content bottomAnchor] constant:28.0f],
            [[content topAnchor] constraintGreaterThanOrEqualToAnchor:[canvas topAnchor] constant:34.0f],
            
            [[iconRow heightAnchor] constraintEqualToConstant:72.0f],
            [[stateIconTile_ widthAnchor] constraintEqualToConstant:72.0f],
            [[stateIconTile_ heightAnchor] constraintEqualToConstant:72.0f],
            [[stateIconTile_ centerXAnchor] constraintEqualToAnchor:[iconRow centerXAnchor]],
            [[stateIconTile_ centerYAnchor] constraintEqualToAnchor:[iconRow centerYAnchor]],
            [[stateIcon_ centerXAnchor] constraintEqualToAnchor:[stateIconTile_ centerXAnchor]],
            [[stateIcon_ centerYAnchor] constraintEqualToAnchor:[stateIconTile_ centerYAnchor]],

            [[details_ topAnchor] constraintEqualToAnchor:[content bottomAnchor] constant:14.0f],
            [[details_ centerXAnchor] constraintEqualToAnchor:[canvas centerXAnchor]],
            [[details_ leadingAnchor] constraintGreaterThanOrEqualToAnchor:[canvas leadingAnchor] constant:24],
            [[details_ trailingAnchor] constraintLessThanOrEqualToAnchor:[canvas trailingAnchor] constant:-24],
            [[details_ heightAnchor] constraintGreaterThanOrEqualToConstant:44.0f],
            [[log_ topAnchor] constraintEqualToAnchor:[details_ bottomAnchor] constant:4.0f],
            [[log_ leadingAnchor] constraintEqualToAnchor:[canvas leadingAnchor] constant:28.0f],
            [[log_ trailingAnchor] constraintEqualToAnchor:[canvas trailingAnchor] constant:-28.0f],
            [[log_ bottomAnchor] constraintLessThanOrEqualToAnchor:[canvas bottomAnchor] constant:-12.0f],
            logHeight_,
            [[finish_ leadingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] leadingAnchor] constant:20.0f],
            [[finish_ trailingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] trailingAnchor] constant:-20.0f],
            [[finish_ bottomAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] bottomAnchor] constant:-16.0f],
            [[finish_ heightAnchor] constraintGreaterThanOrEqualToConstant:54.0f],
        nil]];

        contentMaximumWidth_ = [[content widthAnchor] constraintLessThanOrEqualToConstant:440.0f];
        [contentMaximumWidth_ setActive:YES];
        NSLayoutConstraint *contentWidth([[content widthAnchor] constraintEqualToAnchor:[canvas widthAnchor] constant:-88.0f]);
        [contentWidth setPriority:999];
        [contentWidth setActive:YES];
        stateIconWidth_ = [[stateIcon_ widthAnchor] constraintEqualToConstant:34.0];
        stateIconHeight_ = [[stateIcon_ heightAnchor] constraintEqualToConstant:34.0];
        [stateIconWidth_ setActive:YES];
        [stateIconHeight_ setActive:YES];
        [stateIcon_ setContentMode:UIViewContentModeScaleAspectFit];
        NSLayoutConstraint *trackHeight([[progressTrack_ heightAnchor] constraintEqualToConstant:8.0f]);
        [trackHeight setPriority:999]; // A hidden arranged view has zero height.
        [trackHeight setActive:YES];
        NSLayoutConstraint *center([[content centerYAnchor] constraintEqualToAnchor:[canvas centerYAnchor] constant:-28.0f]);
        [center setPriority:UILayoutPriorityDefaultHigh];
        [center setActive:YES];
        [self setTransactionTitle:CYLocalize(@"Working")];
        [self setStatusText:CYLocalize(@"Preparing…")];
        [self setTransferCurrent:0 total:0 speed:0];
        [self setRunning:YES];
        [self updateAccessibleLayout];
    }
    return self;
}

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}
- (void) stopMotion {
    [[stateIcon_ layer] removeAnimationForKey:@"CydiaCompactProgressRotation"];
    [progressRing_ removeAnimationForKey:@"CydiaRestartOrbit"];
    for (UIView *light in [restartLights_ arrangedSubviews])
        [[light layer] removeAnimationForKey:@"CydiaRestartLight"];
}
- (void) refreshMotion {
    [self stopMotion];
    if ((!running_ && !restarting_) || UIAccessibilityIsReduceMotionEnabled() ||
        [[UIApplication sharedApplication] applicationState] != UIApplicationStateActive)
        return;
    CABasicAnimation *rotation([CABasicAnimation animationWithKeyPath:@"transform.rotation.z"]);
    [rotation setFromValue:@0];
    [rotation setToValue:@(M_PI * 2.0)];
    [rotation setDuration:1.25];
    [rotation setRepeatCount:FLT_MAX];
    if (restarting_) {
        if ([self window] == nil || [[NSProcessInfo processInfo] isLowPowerModeEnabled])
            return;
        NSUInteger index(0);
        for (UIView *light in [restartLights_ arrangedSubviews]) {
            CABasicAnimation *pulse([CABasicAnimation animationWithKeyPath:@"opacity"]);
            [pulse setFromValue:@0.25]; [pulse setToValue:@1.0];
            [pulse setAutoreverses:YES]; [pulse setDuration:0.85];
            [pulse setRepeatCount:FLT_MAX];
            [pulse setBeginTime:CACurrentMediaTime() + 0.18 * index++];
            [pulse setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut]];
            [[light layer] addAnimation:pulse forKey:@"CydiaRestartLight"];
        }
    } else
        [[stateIcon_ layer] addAnimation:rotation forKey:@"CydiaCompactProgressRotation"];
}

- (void) didMoveToWindow {
    [super didMoveToWindow];
    if ([self window] == nil) [self stopMotion];
    else [self refreshMotion];
}

- (void) updateAccessibleLayout {
    BOOL large(UIContentSizeCategoryIsAccessibilityCategory([[self traitCollection] preferredContentSizeCategory]));
    [contentMaximumWidth_ setConstant:large ? 660.0f : 440.0f];
    [progressLabels_ setAxis:large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal];
    [progressLabels_ setAlignment:UIStackViewAlignmentFill];
    [percent_ setTextAlignment:large ? NSTextAlignmentLeft : NSTextAlignmentRight];
}
- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateAccessibleLayout];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previous])
        [self updateStateLayerColors];
}

- (NSString *) readableStatus:(NSString *)message {
    if ([message length] == 0)
        return CYLocalize(@"Preparing…");
    if ([message hasSuffix:@" (iphoneos-arm64)"])
        message = [message substringToIndex:[message length] - [@" (iphoneos-arm64)" length]];
    NSString *value([message lowercaseString]);
    if ([value rangeOfString:@"no_pubkey"].location != NSNotFound ||
        [value rangeOfString:@"signature"].location != NSNotFound ||
        [value rangeOfString:@"not signed"].location != NSNotFound ||
        [value rangeOfString:@"gpg error"].location != NSNotFound)
        return refreshing_ ? CYLocalize(@"A repository could not be verified") : CYLocalize(@"Package verification failed");
    if ([value rangeOfString:@"download"].location != NSNotFound ||
        [value rangeOfString:@"fetch"].location != NSNotFound ||
        [value rangeOfString:@"retriev"].location != NSNotFound)
        return refreshing_ ? CYLocalize(@"Downloading repository data…") : CYLocalize(@"Downloading packages…");
    if ([value rangeOfString:@"unpack"].location != NSNotFound ||
        [value rangeOfString:@"prepar"].location != NSNotFound)
        return CYLocalize(@"Preparing packages…");
    if ([value rangeOfString:@"setting up"].location != NSNotFound ||
        [value rangeOfString:@"configur"].location != NSNotFound ||
        [value rangeOfString:@"processing trigger"].location != NSNotFound)
        return CYLocalize(@"Applying changes…");
    if ([message rangeOfString:@"\n"].location != NSNotFound || [message length] > 96)
        return refreshing_ ? CYLocalize(@"Refreshing repositories…") : CYLocalize(@"Applying package changes…");
    return CYLocalize(message);
}

- (void) setTransactionTitle:(NSString *)title {
    NSString *value([title length] == 0 ? CYLocalize(@"Working") : title);
    if ([value caseInsensitiveCompare:@"UPDATING_SOURCES"] == NSOrderedSame ||
        [[value lowercaseString] rangeOfString:@"refresh"].location != NSNotFound) {
        refreshing_ = YES;
        value = CYLocalize(@"Refreshing Sources");
    } else if ([value caseInsensitiveCompare:@"RUNNING"] == NSOrderedSame ||
        [value caseInsensitiveCompare:@"WORKING"] == NSOrderedSame)
        value = refreshing_ ? CYLocalize(@"Refreshing Sources") : CYLocalize(@"Preparing Changes");
    else if ([value caseInsensitiveCompare:@"REPAIRING"] == NSOrderedSame)
        value = CYLocalize(@"Repairing");
    else if ([value caseInsensitiveCompare:@"COMPLETE"] == NSOrderedSame)
        value = refreshing_ ? CYLocalize(@"Sources Updated") : CYLocalize(@"Changes Complete");
    [title_ setText:CYLocalize(value)];
    [phase_ setHidden:refreshing_ || !running_];
}

- (void) setStatusText:(NSString *)status {
    if (restarting_) return;
    [status_ setText:[self readableStatus:status]];
}

- (void) setProgressValue:(float)value animated:(BOOL)animated {
    float bounded(MAX(0.0f, MIN(1.0f, value)));
    [progressTrack_ setIndeterminate:NO];
    [progressTrack_ setProgressValue:bounded animated:animated && !UIAccessibilityIsReduceMotionEnabled()];
    [self setRingStrokeEnd:bounded animated:animated];
    [percent_ setText:CYLocalizedPercent(bounded)];
}

- (void) setRingStrokeEnd:(float)value animated:(BOOL)animated {
    animated = animated && !UIAccessibilityIsReduceMotionEnabled();
    float bounded(MAX(0.0f, MIN(1.0f, value)));
    [CATransaction begin];
    [CATransaction setDisableActions:!animated];
    if (animated)
        [CATransaction setAnimationDuration:0.24];
    [progressRing_ setStrokeEnd:bounded];
    [CATransaction commit];
}

- (void) beginInstalling {
    if (refreshing_ || !running_)
        return;
    if (phaseState_.advance(CYTransactionInstalling)) {
        [title_ setText:CYLocalize(@"Applying Changes")];
        [phase_ setText:CYLocalize(@"Applying · 2/2")];
        [metrics_ setText:CYLocalize(@"Applying package changes")];
        [status_ setText:CYLocalize(@"Preparing package changes…")];
        [self setProgressValue:0 animated:NO];
        [percent_ setText:@"—"];
        [progressTrack_ setIndeterminate:YES];
    }
}

- (void) setTransferCurrent:(double)current total:(double)total speed:(double)speed {
    if (!refreshing_ && phaseState_.phase == CYTransactionInstalling)
        return;
    if (total <= 0.0) {
        [metrics_ setText:running_ ? CYLocalize(@"Preparing…") : @""];
        [percent_ setText:@"—"];
        [progressTrack_ setIndeterminate:running_];
        return;
    }
    if (!refreshing_ && phaseState_.advance(CYTransactionDownloading)) {
        [title_ setText:CYLocalize(@"Downloading Packages")];
        [phase_ setText:CYLocalize(@"Downloading · 1/2")];
    }
    [progressTrack_ setIndeterminate:NO];
    NSString *currentText([NSByteCountFormatter stringFromByteCount:(long long) current countStyle:NSByteCountFormatterCountStyleFile]);
    NSString *totalText([NSByteCountFormatter stringFromByteCount:(long long) total countStyle:NSByteCountFormatterCountStyleFile]);
    NSMutableString *text([NSMutableString stringWithFormat:CYLocalize(@"%@ of %@"), currentText, totalText]);
    if (speed > 0.0) {
        NSString *speedText([NSByteCountFormatter stringFromByteCount:(long long) speed countStyle:NSByteCountFormatterCountStyleFile]);
        [text appendFormat:@" · %@", [NSString stringWithFormat:CYLocalize(@"%@/s"), speedText]];
    }
    [metrics_ setText:text];
}

- (void) setDownloadProgressValue:(float)value current:(double)current total:(double)total speed:(double)speed {
    if (!running_ || (!refreshing_ && phaseState_.phase == CYTransactionInstalling))
        return;
    [self setTransferCurrent:current total:total speed:speed];
    if (total > 0.0)
        [self setProgressValue:value animated:YES];
}

- (void) appendLogMessage:(NSString *)message type:(NSString *)type {
    if ([message length] == 0)
        return;
    NSString *normalizedType([type lowercaseString]);
    BOOL isError([normalizedType isEqualToString:@"error"]);
    BOOL isWarning([normalizedType isEqualToString:@"warning"]);
    UIColor *color(isError ? [UIColor systemRedColor] : (isWarning ? [UIColor systemOrangeColor] : [UIColor secondaryLabelColor]));
    NSDictionary *attributes([NSDictionary dictionaryWithObjectsAndKeys:
        [UIFont monospacedSystemFontOfSize:11.5f weight:UIFontWeightRegular], NSFontAttributeName,
        color, NSForegroundColorAttributeName,
    nil]);
    NSTextStorage *text([log_ textStorage]);
    [text beginEditing];
    if ([text length] != 0)
        [text appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n" attributes:attributes] autorelease]];
    [text appendAttributedString:[[[NSAttributedString alloc] initWithString:message attributes:attributes] autorelease]];
    // Keep UI updates linear and bounded during large upgrades. Full activity
    // is still recorded by the controller's diagnostics stream.
    const NSUInteger limit(128 * 1024);
    if ([text length] > limit) {
        NSUInteger excess([text length] - limit);
        NSRange line([[text string] rangeOfString:@"\n" options:0 range:NSMakeRange(excess, [text length] - excess)]);
        [text deleteCharactersInRange:NSMakeRange(0, line.location == NSNotFound ? excess : NSMaxRange(line))];
    }
    [text endEditing];
    // Preserve late diagnostic output without replacing the restart handoff.
    if (restarting_) return;

    if (isError || isWarning) {
        ++issueCount_;
        [details_ setHidden:NO];
        NSString *label(CYLocalizedMetric(CYLocalize(@"View details"), issueCount_));
        [details_ setTitle:label forState:UIControlStateNormal];
        [status_ setText:isError ? (refreshing_ ? CYLocalize(@"Some sources could not be updated") : CYLocalize(@"The operation could not be completed")) :
            CYLocalize(@"A warning needs your attention")];
        if (isError && !expanded_)
            [self toggleDetails];
    } else
        [self setStatusText:message];
}

- (void) toggleDetails {
    expanded_ = !expanded_;
    [details_ setImage:[UIImage cy_symbolNamed:expanded_ ? @"chevron.up" : @"chevron.down"] forState:UIControlStateNormal];
    [log_ setHidden:!expanded_];
    [logHeight_ setConstant:expanded_ ? 150.0f : 0.0f];
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.22 animations:^{
        [self layoutIfNeeded];
    }];
    if (expanded_)
        [log_ scrollRangeToVisible:NSMakeRange([[log_ text] length], 0)];
}

- (void) updateStateAppearance {
    UIColor *color(error_ ? [UIColor systemRedColor] : (cancelled_ ? [UIColor systemOrangeColor] : (running_ ? CYModernAccentColor() : [UIColor systemGreenColor])));
    NSString *symbol(error_ ? @"exclamationmark.triangle.fill" : (cancelled_ ? @"pause.circle.fill" : (running_ ? @"arrow.triangle.2.circlepath" : @"checkmark.circle.fill")));
    [stateIcon_ setImage:[UIImage cy_symbolNamed:symbol]];
    [stateIcon_ setTintColor:color];
    [stateIconTile_ setBackgroundColor:[color colorWithAlphaComponent:0.11f]];
    [progressTrack_ setFailureTint:error_];
    [self updateStateLayerColors];
}

- (void) updateStateLayerColors {
    UIColor *color([(error_ ? [UIColor systemRedColor] : (cancelled_ ? [UIColor systemOrangeColor] :
        (running_ ? CYModernAccentColor() : [UIColor systemGreenColor]))) resolvedColorWithTraitCollection:self.traitCollection]);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [ringTrack_ setStrokeColor:[[color colorWithAlphaComponent:0.16f] CGColor]];
    [progressRing_ setStrokeColor:[color CGColor]];
    [CATransaction commit];
}

- (void) setRunning:(BOOL)running {
    if (restarting_ && detailsBeforeRestart_ && !expanded_) [self toggleDetails];
    [details_ setHidden:NO];
    restarting_ = NO;
    [self stopMotion];
    [restartPanel_ setHidden:YES];
    [[restartLights_ superview] setHidden:YES];
    [ringTrack_ setHidden:NO]; [progressRing_ setHidden:NO];
    [stateIconWidth_ setConstant:34.0]; [stateIconHeight_ setConstant:34.0];
    [[stateIcon_ layer] setCornerRadius:0];
    [[stateIcon_ layer] setMasksToBounds:NO];
    [title_ setFont:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1] scaledFontForFont:[UIFont systemFontOfSize:28.0f weight:UIFontWeightSemibold]]];
    running_ = running;
    [self updateStateAppearance];
    [[stateIcon_ layer] removeAnimationForKey:@"CydiaCompactProgressRotation"];
    [phase_ setHidden:refreshing_ || !running_];
    [progressTrack_ setHidden:!running_];
    [progressLabels_ setHidden:!running_];
    if (running_) {
        restartRequired_ = NO;
        phaseState_.reset();
        [phase_ setText:CYLocalize(@"Preparing…")];
        [self refreshMotion];
        [finish_ setHidden:YES];
        [finish_ setUserInteractionEnabled:NO];
        [progressTrack_ setIndeterminate:YES];
        return;
    }

    [progressTrack_ setIndeterminate:NO];
    if (!error_ && !cancelled_)
        [progressTrack_ setProgressValue:1.0f animated:YES];
    [self setRingStrokeEnd:(error_ || cancelled_ ? [progressRing_ strokeEnd] : 1.0f) animated:YES];
    [percent_ setText:error_ || cancelled_ ? CYLocalize(@"Stopped") : CYLocalizedPercent(1.0)];
    [title_ setText:error_ ? (refreshing_ ? CYLocalize(@"Refresh Incomplete") : CYLocalize(@"Couldn’t Complete")) :
        (cancelled_ ? CYLocalize(@"Cancelled") : (refreshing_ ? CYLocalize(@"Sources Updated") : CYLocalize(@"Changes Complete")))];
    if (error_)
        [status_ setText:refreshing_ ? CYLocalize(@"Some sources may still show older package data") : CYLocalize(@"Review the details before trying again.")];
    else if (cancelled_)
        [status_ setText:CYLocalize(@"The operation was cancelled. You can try again when ready.")];
    else if (issueCount_ != 0)
        [status_ setText:refreshing_ ? CYLocalize(@"Updated with repository warnings") : CYLocalize(@"Completed with warnings")];
    else
        [status_ setText:refreshing_ ? CYLocalize(@"Repositories are ready") : (restartRequired_ ?
            CYLocalize(@"Your packages are installed. Restart to activate the changes.") : CYLocalize(@"Your package changes have been applied."))];
    if (restartRequired_ && !error_ && !cancelled_) {
        [title_ setText:CYLocalize(@"Ready to Restart")];
        [stateIcon_ setImage:[UIImage cy_symbolNamed:@"checkmark"]];
    }
    [metrics_ setText:issueCount_ == 0 ? @"" :
        CYLocalizedMetric(CYLocalize(@"Details"), issueCount_)];
    [finish_ setHidden:NO];
    [finish_ setUserInteractionEnabled:YES];
    [finish_ setBackgroundColor:error_ ? [UIColor systemRedColor] : CYModernPrimaryButtonColor()];
}

- (void) setCancelledState:(BOOL)cancelled {
    cancelled_ = cancelled;
    [self updateStateAppearance];
}

- (void) setErrorState:(BOOL)error {
    error_ = error;
    cancelled_ = NO;
    if (!error_) {
        issueCount_ = 0;
        expanded_ = NO;
        [details_ setHidden:NO];
        [details_ setTitle:CYLocalize(@"View details") forState:UIControlStateNormal];
        [details_ setImage:[UIImage cy_symbolNamed:@"chevron.down"] forState:UIControlStateNormal];
        [log_ setHidden:YES];
        [logHeight_ setConstant:0.0f];
        [log_ setAttributedText:[[[NSAttributedString alloc] initWithString:@""] autorelease]];
    }
    [self updateStateAppearance];
}

- (void) setFinishTitle:(NSString *)title target:(id)target action:(SEL)action {
    [finish_ setTitle:[title length] == 0 ? CYLocalize(@"Done") : CYLocalize(title) forState:UIControlStateNormal];
    [finish_ removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [finish_ addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
}

- (void) setRestartRequired:(BOOL)required {
    restartRequired_ = required;
}

- (void) setRestartingKind:(CydiaRestartKind)kind {
    NSString *title(CYLocalize(@"Restarting SpringBoard"));
    NSString *message(CYLocalize(@"Your packages are installed.\nReopening the Home Screen…"));
    if (kind == CydiaRestartUserspace) {
        title = CYLocalize(@"Restarting Userspace");
        message = CYLocalize(@"Your packages are installed.\nRestarting system services…");
    } else if (kind == CydiaRestartDevice) {
        title = CYLocalize(@"Restarting Device");
        message = CYLocalize(@"Your packages are installed.\nThe device is restarting…");
    }
    [self setRestarting:YES title:title];
    [status_ setText:message];
}

- (void) setRestarting:(BOOL)restarting title:(NSString *)title {
    if (!restarting) {
        [self setRunning:NO];
        return;
    }
    if (!restarting_) detailsBeforeRestart_ = expanded_;
    restarting_ = YES;
    [self stopMotion];
    if (expanded_) [self toggleDetails];
    void (^update)(void) = ^{
        [details_ setHidden:YES];
        [finish_ setHidden:YES];
        [finish_ setUserInteractionEnabled:NO];
        [progressTrack_ setHidden:YES];
        [progressLabels_ setHidden:YES];
        [phase_ setHidden:YES];
        [restartPanel_ setHidden:NO];
        [[restartLights_ superview] setHidden:NO];
        [title_ setFont:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle2] scaledFontForFont:
            [UIFont systemFontOfSize:24.0 weight:UIFontWeightSemibold]]];
        [title_ setText:title];
        [status_ setText:CYLocalize(@"Your packages are installed.\nReopening the Home Screen…")];
        [stateIcon_ setImage:[UIImage imageNamed:@"Icon-60"] ?: [UIImage cy_symbolNamed:@"shippingbox.fill"]];
        [stateIconWidth_ setConstant:72.0]; [stateIconHeight_ setConstant:72.0];
        [[stateIcon_ layer] setCornerRadius:16.0];
        [[stateIcon_ layer] setCornerCurve:kCACornerCurveContinuous];
        [[stateIcon_ layer] setMasksToBounds:YES];
        [stateIconTile_ setBackgroundColor:[UIColor clearColor]];
        [ringTrack_ setHidden:YES]; [progressRing_ setHidden:YES];
        [self layoutIfNeeded];
    };
    // Keep the sheet opaque through the restart handoff; animate only its dots.
    [UIView performWithoutAnimation:update];
    [self refreshMotion];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, title);
}

@end

// Separate the package identity, exact version requirement and next step.
// One cell represents one failed OR group, including every alternative.
@interface CydiaModernIssueCell : UITableViewCell {
    UIStackView *copy_;
}
- (void) configureWithItem:(NSDictionary *)item;
@end

@implementation CydiaModernIssueCell
- (id) initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier]) != nil) {
        copy_ = [[[UIStackView alloc] init] autorelease];
        [copy_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [copy_ setAxis:UILayoutConstraintAxisVertical];
        [copy_ setSpacing:5.0f];
        [[self contentView] addSubview:copy_];
        [NSLayoutConstraint activateConstraints:@[
            [[copy_ leadingAnchor] constraintEqualToAnchor:[[self contentView] leadingAnchor] constant:16.0f],
            [[copy_ trailingAnchor] constraintEqualToAnchor:[[self contentView] trailingAnchor] constant:-16.0f],
            [[copy_ topAnchor] constraintEqualToAnchor:[[self contentView] topAnchor] constant:14.0f],
            [[copy_ bottomAnchor] constraintEqualToAnchor:[[self contentView] bottomAnchor] constant:-14.0f]
        ]];
        [self setSelectionStyle:UITableViewCellSelectionStyleNone];
        [self setBackgroundColor:[UIColor secondarySystemGroupedBackgroundColor]];
    }
    return self;
}
- (void) addText:(NSString *)text style:(UIFontTextStyle)style color:(UIColor *)color {
    if ([text length] == 0)
        return;
    UILabel *label(CYM3Label(style, color, 0));
    [label setText:text];
    [label setLineBreakMode:NSLineBreakByWordWrapping];
    [copy_ addArrangedSubview:label];
}
- (void) configureWithItem:(NSDictionary *)item {
    for (UIView *view in [[[copy_ arrangedSubviews] copy] autorelease])
        [view removeFromSuperview];
    [self addText:[item objectForKey:@"heading"] ?: [item objectForKey:@"name"]
        style:UIFontTextStyleSubheadline color:[UIColor secondaryLabelColor]];
    NSArray *requirements([item objectForKey:@"requirements"]);
    if ([requirements count] == 0) {
        [self addText:[item objectForKey:@"detail"] style:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
        return;
    }
    NSUInteger index(0);
    for (NSDictionary *requirement in requirements) {
        if (index++ != 0)
            [self addText:CYLocalize(@"OR") style:UIFontTextStyleCaption1 color:[UIColor secondaryLabelColor]];
        NSString *name([requirement objectForKey:@"name"]);
        [self addText:name style:UIFontTextStyleHeadline color:[UIColor labelColor]];
        NSString *identifier([requirement objectForKey:@"identifier"]);
        if (![name isEqualToString:identifier])
            [self addText:identifier style:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
        NSString *version([requirement objectForKey:@"version"]);
        if ([version length] != 0)
            [self addText:[NSString stringWithFormat:CYLocalize(@"Required version: %@"), version]
                style:UIFontTextStyleSubheadline color:[UIColor labelColor]];
        [self addText:[requirement objectForKey:@"source"] style:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
        [self addText:CYLocalize([requirement objectForKey:@"explanation"]) style:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
        [copy_ setCustomSpacing:12.0f afterView:[[copy_ arrangedSubviews] lastObject]];
    }
    [self addText:[item objectForKey:@"context"] style:UIFontTextStyleFootnote color:[UIColor secondaryLabelColor]];
}
@end

// Keep review content contrast stable when UIKit elevates a modal sheet.
static UIColor *CYM3ReviewColor(BOOL card) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if ([traits userInterfaceStyle] == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:card ? 0.12f : 0.055f alpha:1.0f];
        return card ? [UIColor whiteColor] : [UIColor colorWithRed:0.949f green:0.949f blue:0.969f alpha:1.0f];
    }];
}

@interface CydiaModernConfirmationView () {
    UIVisualEffectView *summary_;
    UIView *regularTableHeader_;
    UIView *compactSummary_;
    UILabel *compactTitle_;
    UILabel *compactDetail_;
    UILabel *compactDownload_;
    UILabel *compactWarning_;
    UIStackView *actionContent_;
    NSLayoutConstraint *tableTop_;
    NSLayoutConstraint *tableAccessibleTop_;
    UIView *iconTile_;
    UIImageView *icon_;
    UILabel *title_;
    UILabel *detail_;
    UILabel *download_;
    UILabel *warning_;
    UILabel *empty_;
    UITableView *table_;
    UIVisualEffectView *actionDock_;
    UILabel *actionDetail_;
    UIButton *confirm_;
    NSArray *sections_;
    NSString *operationSymbol_;
}
@end

@implementation CydiaModernConfirmationView

- (void) dealloc {
    [table_ setDataSource:nil];
    [table_ setDelegate:nil];
    [regularTableHeader_ release];
    [compactSummary_ release];
    [sections_ release];
    [operationSymbol_ release];
    [tableTop_ release];
    [tableAccessibleTop_ release];
    [super dealloc];
}

- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
        [self setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self setBackgroundColor:CYM3ReviewColor(NO)];
        sections_ = [[NSArray alloc] init];
        operationSymbol_ = [@"arrow.down.to.line" copy];

        // The operation is the heading; content cards are reserved for packages.
        summary_ = CYM3ContentCard(0.0f);
        [summary_ setBackgroundColor:[UIColor clearColor]];
        [self addSubview:summary_];
        iconTile_ = [[[UIView alloc] init] autorelease];
        [iconTile_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [[iconTile_ layer] setCornerRadius:28.0f];
        [[iconTile_ layer] setCornerCurve:kCACornerCurveContinuous];
        icon_ = [[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:operationSymbol_]] autorelease];
        [icon_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [icon_ setContentMode:UIViewContentModeScaleAspectFit];
        [icon_ setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:29 weight:UIImageSymbolWeightRegular]];
        [iconTile_ addSubview:icon_];
        title_ = CYM3Label(UIFontTextStyleTitle1, [UIColor labelColor], 0);
        [title_ setFont:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1]
            scaledFontForFont:[UIFont systemFontOfSize:28 weight:UIFontWeightBold]]];
        detail_ = CYM3Label(UIFontTextStyleSubheadline, [UIColor secondaryLabelColor], 0);
        download_ = CYM3Label(UIFontTextStyleFootnote, [UIColor secondaryLabelColor], 0);
        warning_ = CYM3Label(UIFontTextStyleFootnote, [UIColor systemOrangeColor], 0);
        [warning_ setHidden:YES];
        UIStackView *labels([[[UIStackView alloc] initWithArrangedSubviews:@[title_, detail_, download_, warning_]] autorelease]);
        [labels setAxis:UILayoutConstraintAxisVertical];
        [labels setSpacing:4.0f];
        UIStackView *heading([[[UIStackView alloc] initWithArrangedSubviews:@[iconTile_, labels]] autorelease]);
        [heading setAxis:UILayoutConstraintAxisHorizontal];
        [heading setAlignment:UIStackViewAlignmentCenter];
        [heading setSpacing:16.0f];
        [heading setTranslatesAutoresizingMaskIntoConstraints:NO];
        [[summary_ contentView] addSubview:heading];

        table_ = [[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped] autorelease];
        [table_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [table_ setBackgroundColor:[UIColor clearColor]];
        [table_ setDataSource:self];
        [table_ setDelegate:self];
        [table_ setRowHeight:UITableViewAutomaticDimension];
        [table_ setEstimatedRowHeight:80.0f];
        [table_ setSectionHeaderTopPadding:0.0f];
        [table_ setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentNever];
        regularTableHeader_ = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 0.01f)];
        [table_ setTableHeaderView:regularTableHeader_];
        [self addSubview:table_];
        // The compact layout scrolls the same review information with the
        // package queue so large text never hides download sizes or warnings.
        compactSummary_ = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
        compactTitle_ = CYM3Label(UIFontTextStyleTitle1, [UIColor labelColor], 0);
        [compactTitle_ setAccessibilityTraits:UIAccessibilityTraitHeader];
        compactDetail_ = CYM3Label(UIFontTextStyleSubheadline, [UIColor secondaryLabelColor], 0);
        compactDownload_ = CYM3Label(UIFontTextStyleFootnote, [UIColor secondaryLabelColor], 0);
        compactWarning_ = CYM3Label(UIFontTextStyleFootnote, [UIColor systemOrangeColor], 0);
        [compactDownload_ setHidden:YES];
        [compactWarning_ setHidden:YES];
        UIStackView *compactLabels([[[UIStackView alloc] initWithArrangedSubviews:
            @[compactTitle_, compactDetail_, compactDownload_, compactWarning_]] autorelease]);
        [compactLabels setTranslatesAutoresizingMaskIntoConstraints:NO];
        [compactLabels setAxis:UILayoutConstraintAxisVertical];
        [compactLabels setSpacing:4.0f];
        [compactSummary_ addSubview:compactLabels];
        [NSLayoutConstraint activateConstraints:@[
            [[compactLabels leadingAnchor] constraintEqualToAnchor:[compactSummary_ leadingAnchor] constant:24.0f],
            [[compactLabels trailingAnchor] constraintEqualToAnchor:[compactSummary_ trailingAnchor] constant:-24.0f],
            [[compactLabels topAnchor] constraintEqualToAnchor:[compactSummary_ topAnchor] constant:20.0f],
            [[compactLabels bottomAnchor] constraintEqualToAnchor:[compactSummary_ bottomAnchor] constant:-12.0f]
        ]];
        empty_ = CYM3Label(UIFontTextStyleBody, [UIColor secondaryLabelColor], 0);
        [empty_ setTextAlignment:NSTextAlignmentCenter];
        [empty_ setText:CYLocalize(@"Select a package to continue.")];
        [empty_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self addSubview:empty_];

        actionDock_ = CYM3FloatingPanel();
        [self addSubview:actionDock_];
        confirm_ = CYM3FilledButton();
        [confirm_ setTitle:CYLocalize(@"Confirm") forState:UIControlStateNormal];
        [confirm_ setImage:nil forState:UIControlStateNormal];
        [[confirm_ titleLabel] setAdjustsFontSizeToFitWidth:NO];
        actionDetail_ = CYM3Label(UIFontTextStyleFootnote, [UIColor secondaryLabelColor], 0);
        [actionDetail_ setTextAlignment:NSTextAlignmentCenter];
        actionContent_ = [[[UIStackView alloc] initWithArrangedSubviews:@[confirm_, actionDetail_]] autorelease];
        [actionContent_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [actionContent_ setAxis:UILayoutConstraintAxisVertical];
        [actionContent_ setAlignment:UIStackViewAlignmentFill];
        [actionContent_ setSpacing:10.0f];
        [[actionDock_ contentView] addSubview:actionContent_];

        [NSLayoutConstraint activateConstraints:@[
            [[summary_ leadingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] leadingAnchor] constant:24.0f],
            [[summary_ trailingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] trailingAnchor] constant:-24.0f],
            [[summary_ topAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] topAnchor] constant:20.0f],
            [[heading leadingAnchor] constraintEqualToAnchor:[[summary_ contentView] leadingAnchor]],
            [[heading trailingAnchor] constraintEqualToAnchor:[[summary_ contentView] trailingAnchor]],
            [[heading topAnchor] constraintEqualToAnchor:[[summary_ contentView] topAnchor]],
            [[heading bottomAnchor] constraintEqualToAnchor:[[summary_ contentView] bottomAnchor] constant:-12.0f],
            [[iconTile_ widthAnchor] constraintEqualToConstant:56.0f],
            [[iconTile_ heightAnchor] constraintEqualToConstant:56.0f],
            [[icon_ centerXAnchor] constraintEqualToAnchor:[iconTile_ centerXAnchor]],
            [[icon_ centerYAnchor] constraintEqualToAnchor:[iconTile_ centerYAnchor]],
            [[icon_ widthAnchor] constraintEqualToConstant:32.0f],
            [[icon_ heightAnchor] constraintEqualToConstant:32.0f],
            [[table_ leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
            [[table_ trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
            [[table_ bottomAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] bottomAnchor]],
            [[empty_ topAnchor] constraintEqualToAnchor:[table_ topAnchor] constant:28.0f],
            [[empty_ leadingAnchor] constraintEqualToAnchor:[summary_ leadingAnchor]],
            [[empty_ trailingAnchor] constraintEqualToAnchor:[summary_ trailingAnchor]],
            [[actionDock_ leadingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] leadingAnchor] constant:16.0f],
            [[actionDock_ trailingAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] trailingAnchor] constant:-16.0f],
            [[actionDock_ bottomAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] bottomAnchor] constant:-10.0f],
            [[actionContent_ leadingAnchor] constraintEqualToAnchor:[[actionDock_ contentView] leadingAnchor] constant:12.0f],
            [[actionContent_ trailingAnchor] constraintEqualToAnchor:[[actionDock_ contentView] trailingAnchor] constant:-12.0f],
            [[actionContent_ topAnchor] constraintEqualToAnchor:[[actionDock_ contentView] topAnchor] constant:12.0f],
            [[actionContent_ bottomAnchor] constraintEqualToAnchor:[[actionDock_ contentView] bottomAnchor] constant:-12.0f],
            [[confirm_ heightAnchor] constraintGreaterThanOrEqualToConstant:54.0f]
        ]];
        tableTop_ = [[[table_ topAnchor] constraintEqualToAnchor:[summary_ bottomAnchor] constant:8.0f] retain];
        tableAccessibleTop_ = [[[table_ topAnchor] constraintEqualToAnchor:[[self safeAreaLayoutGuide] topAnchor]] retain];
        [self updateAccessibleLayout];
    }
    return self;
}

- (void) layoutSubviews {
    CGFloat height(CGRectGetHeight([self bounds]));
    BOOL collapsed(UIContentSizeCategoryIsAccessibilityCategory([[self traitCollection] preferredContentSizeCategory]) ||
        (height > 0.0f && height < 300.0f));
    if ([summary_ isHidden] != collapsed) [self updateAccessibleLayout];
    [super layoutSubviews];
    if (collapsed) {
        CGFloat width(CGRectGetWidth([table_ bounds]));
        if (width > 0.0f) {
            CGSize fit([compactSummary_ systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel]);
            if (fabs(CGRectGetWidth([compactSummary_ frame]) - width) > 0.5f ||
                fabs(CGRectGetHeight([compactSummary_ frame]) - ceil(fit.height)) > 0.5f) {
                [compactSummary_ setFrame:CGRectMake(0, 0, width, ceil(fit.height))];
                [table_ setTableHeaderView:compactSummary_];
            }
        }
    }
    CGFloat bottom(MAX(0.0f, CGRectGetMaxY([table_ frame]) - CGRectGetMinY([actionDock_ frame])) + 12.0f);
    if (fabs([table_ contentInset].bottom - bottom) > 0.5f) {
        [table_ setContentInset:UIEdgeInsetsMake(0, 0, bottom, 0)];
        [table_ setVerticalScrollIndicatorInsets:UIEdgeInsetsMake(0, 0, bottom, 0)];
    }
}

- (void) updateAccessibleLayout {
    BOOL large(UIContentSizeCategoryIsAccessibilityCategory([[self traitCollection] preferredContentSizeCategory]));
    CGFloat height(CGRectGetHeight([self bounds]));
    BOOL collapsed(large || (height > 0.0f && height < 300.0f));
    [summary_ setHidden:collapsed];
    // Deactivate before activating the alternative to avoid transient conflicts.
    [tableTop_ setActive:NO];
    [tableAccessibleTop_ setActive:NO];
    [(collapsed ? tableAccessibleTop_ : tableTop_) setActive:YES];
    [table_ setTableHeaderView:collapsed ? compactSummary_ : regularTableHeader_];
    [empty_ setHidden:collapsed || [sections_ count] != 0];
    [actionDetail_ setHidden:collapsed];
    [table_ reloadData];
}
- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (![[previous preferredContentSizeCategory] isEqualToString:[[self traitCollection] preferredContentSizeCategory]])
        [self updateAccessibleLayout];
}

- (void) setSummaryTitle:(NSString *)title detail:(NSString *)detail download:(NSString *)download {
    [title_ setText:title];
    [detail_ setText:detail];
    [download_ setText:download];
    [download_ setHidden:[download length] == 0];
    [compactTitle_ setText:title];
    [compactDetail_ setText:detail];
    [compactDownload_ setText:download];
    [compactDownload_ setHidden:[download length] == 0];
    [self setNeedsLayout];
}

- (void) setSections:(NSArray *)sections {
    if ([sections_ isEqualToArray:sections]) return;
    // Icon downloads must not rebuild the entire review table. Its queue and
    // measured row positions remain unchanged while artwork arrives.
    BOOL sameRows = sections_ != nil && [sections_ count] == [sections count];
    for (NSUInteger section = 0; sameRows && section < [sections count]; ++section) {
        NSMutableDictionary *oldSection = [[sections_[section] mutableCopy] autorelease];
        NSMutableDictionary *newSection = [[sections[section] mutableCopy] autorelease];
        NSArray *oldItems = oldSection[@"items"], *newItems = newSection[@"items"];
        [oldSection removeObjectForKey:@"items"]; [newSection removeObjectForKey:@"items"];
        sameRows = [oldSection isEqual:newSection] && oldItems.count == newItems.count;
        for (NSUInteger row = 0; sameRows && row < oldItems.count; ++row) {
            NSMutableDictionary *oldItem = [[oldItems[row] mutableCopy] autorelease];
            NSMutableDictionary *newItem = [[newItems[row] mutableCopy] autorelease];
            [oldItem removeObjectForKey:@"icon"]; [newItem removeObjectForKey:@"icon"];
            sameRows = [oldItem isEqual:newItem];
        }
    }
    [sections_ release];
    sections_ = [sections copy];
    [empty_ setHidden:[summary_ isHidden] || [sections_ count] != 0];
    [UIView performWithoutAnimation:^{
        if (!sameRows) { [table_ reloadData]; return; }
        for (NSIndexPath *path in [table_ indexPathsForVisibleRows]) {
            if ([sections_[path.section][@"issue"] boolValue]) continue;
            UITableViewCell *cell = [table_ cellForRowAtIndexPath:path];
            UIListContentConfiguration *content = [[(UIListContentConfiguration *)cell.contentConfiguration copy] autorelease];
            content.image = sections_[path.section][@"items"][path.row][@"icon"];
            cell.contentConfiguration = content;
        }
    }];
}

- (void) setWarningText:(NSString *)warning {
    [warning_ setText:warning];
    [download_ setHidden:[warning length] != 0 || [[download_ text] length] == 0];
    [warning_ setHidden:[warning length] == 0];
    [compactWarning_ setText:warning];
    [compactDownload_ setHidden:[download_ isHidden]];
    [compactWarning_ setHidden:[warning_ isHidden]];
    [self setNeedsLayout];
}

- (void) setOperationSymbol:(NSString *)symbol {
    if (operationSymbol_ != symbol) {
        [operationSymbol_ release];
        operationSymbol_ = [symbol copy];
    }
    [icon_ setImage:[UIImage cy_symbolNamed:[warning_ isHidden] ? operationSymbol_ : @"exclamationmark.triangle"]];
}

- (void) setConfirmTitle:(NSString *)title destructive:(BOOL)destructive enabled:(BOOL)enabled target:(id)target action:(SEL)action {
    NSUInteger packages(0);
    for (NSDictionary *section in sections_)
        if (![[section objectForKey:@"issue"] boolValue]) packages += [[section objectForKey:@"items"] count];
    enabled = enabled && packages != 0;
    BOOL blocked(![warning_ isHidden]);
    UIColor *color(blocked ? [UIColor systemOrangeColor] : (destructive ? [UIColor systemRedColor] : CYModernAccentColor()));
    [confirm_ setTitle:title forState:UIControlStateNormal];
    [confirm_ setImage:nil forState:UIControlStateNormal];
    [confirm_ setTitleEdgeInsets:UIEdgeInsetsZero];
    [confirm_ setImageEdgeInsets:UIEdgeInsetsZero];
    [confirm_ setEnabled:enabled];
    [confirm_ setAlpha:enabled ? 1.0f : 0.45f];
    [confirm_ setBackgroundColor:destructive ? [UIColor systemRedColor] : CYModernPrimaryButtonColor()];
    [icon_ setTintColor:packages == 0 && !blocked ? [UIColor secondaryLabelColor] : color];
    [iconTile_ setBackgroundColor:[color colorWithAlphaComponent:0.08f]];
    [self setOperationSymbol:destructive ? @"trash" : operationSymbol_];
    [actionDetail_ setText:enabled ? (destructive ? CYLocalize(@"No package download required") : CYLocalize(@"Downloads checked before installation")) :
        (blocked ? CYLocalize(@"Review the requirements above") : CYLocalize(@"No changes selected"))];
    [confirm_ removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [confirm_ addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
}

- (NSInteger) numberOfSectionsInTableView:(UITableView *)tableView {
    return [sections_ count];
}

- (NSInteger) tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [[[sections_ objectAtIndex:section] objectForKey:@"items"] count];
}

- (CGFloat) tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    NSString *text([self tableView:tableView titleForHeaderInSection:section]);
    CGFloat width(MAX(1.0f, CGRectGetWidth([tableView bounds]) - 72.0f));
    CGRect bounds([text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin
        attributes:@{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1 compatibleWithTraitCollection:[tableView traitCollection]]} context:nil]);
    return ceil(CGRectGetHeight(bounds)) + 19.0f;
}
- (CGFloat) tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 8.0f;
}
- (UIView *) tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *header([[[UIView alloc] init] autorelease]);
    UILabel *label(CYM3Label(UIFontTextStyleCaption1, [UIColor secondaryLabelColor], 0));
    [label setText:[self tableView:tableView titleForHeaderInSection:section]];
    [label setAccessibilityTraits:UIAccessibilityTraitHeader];
    [label setTranslatesAutoresizingMaskIntoConstraints:NO];
    [header addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [[label topAnchor] constraintEqualToAnchor:[header topAnchor] constant:12.0f],
        [[label bottomAnchor] constraintEqualToAnchor:[header bottomAnchor] constant:-7.0f],
        [[label leadingAnchor] constraintEqualToAnchor:[header leadingAnchor] constant:16.0f],
        [[label trailingAnchor] constraintEqualToAnchor:[header trailingAnchor] constant:-16.0f]
    ]];
    return header;
}

- (NSString *) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSDictionary *entry([sections_ objectAtIndex:section]);
    if ([[entry objectForKey:@"issue"] boolValue])
        return [[entry objectForKey:@"title"] localizedCapitalizedString];
    NSUInteger queueSections(0);
    for (NSDictionary *candidate in sections_)
        if (![[candidate objectForKey:@"issue"] boolValue])
            ++queueSections;
    if (queueSections == 1)
        return [CYLocalize(@"PACKAGE QUEUE") localizedCapitalizedString];
    return [[entry objectForKey:@"title"] localizedCapitalizedString];
}

- (UITableViewCell *) tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *section([sections_ objectAtIndex:[indexPath section]]);
    NSDictionary *item([[section objectForKey:@"items"] objectAtIndex:[indexPath row]]);
    BOOL issue([[section objectForKey:@"issue"] boolValue]);
    if (issue) {
        CydiaModernIssueCell *cell([tableView dequeueReusableCellWithIdentifier:@"ModernIssueCell"]);
        if (cell == nil)
            cell = [[[CydiaModernIssueCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"ModernIssueCell"] autorelease];
        [cell configureWithItem:item];
        [cell setBackgroundColor:CYM3ReviewColor(YES)];
        return cell;
    }
    static NSString *identifier(@"ModernConfirmationCell");
    UITableViewCell *cell([tableView dequeueReusableCellWithIdentifier:identifier]);
    if (cell == nil)
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier] autorelease];
    UIListContentConfiguration *content([UIListContentConfiguration subtitleCellConfiguration]);
    [content setText:[item objectForKey:@"name"]];
    [content setSecondaryText:[item objectForKey:@"detail"]];
    [content setImage:issue ? [UIImage cy_symbolNamed:@"exclamationmark.triangle.fill"] : [item objectForKey:@"icon"]];
    [[content imageProperties] setTintColor:issue ? [UIColor systemOrangeColor] : nil];
    [[content imageProperties] setMaximumSize:CGSizeMake(44.0f, 44.0f)];
    [[content imageProperties] setReservedLayoutSize:CGSizeMake(44.0f, 44.0f)];
    [[content imageProperties] setCornerRadius:11.0f];
    [content setDirectionalLayoutMargins:NSDirectionalEdgeInsetsMake(16, 16, 16, 16)];
    [[content textProperties] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
    [[content textProperties] setNumberOfLines:0];
    [[content secondaryTextProperties] setNumberOfLines:0];
    [[content textProperties] setLineBreakMode:NSLineBreakByWordWrapping];
    [[content secondaryTextProperties] setLineBreakMode:NSLineBreakByWordWrapping];
    [[content secondaryTextProperties] setColor:[UIColor secondaryLabelColor]];
    [[content textProperties] setColor:[UIColor labelColor]];
    [cell setContentConfiguration:content];
    [cell setBackgroundColor:CYM3ReviewColor(YES)];
    [cell setSelectionStyle:UITableViewCellSelectionStyleNone];
    return cell;
}

@end

@interface CYM3PackageInfoButton : UIButton {
    UIStackView *rowContent_;
}
- (void) setRowContent:(UIStackView *)content;
@end
@implementation CYM3PackageInfoButton
- (NSString *) accessibilityLabel {
    NSArray *content([rowContent_ arrangedSubviews]);
    return [content count] > 1 ? [(UILabel *)[content objectAtIndex:1] text] : [super accessibilityLabel];
}
- (NSString *) accessibilityValue {
    return [(UILabel *)[rowContent_ viewWithTag:7002] text];
}
- (void) setRowContent:(UIStackView *)content {
    rowContent_ = content;
    BOOL large(UIContentSizeCategoryIsAccessibilityCategory([[self traitCollection] preferredContentSizeCategory]));
    [rowContent_ setAxis:large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal];
    [rowContent_ setAlignment:large ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter];
    UILabel *value((UILabel *)[rowContent_ viewWithTag:7002]);
    [value setTextAlignment:large ? NSTextAlignmentLeft : NSTextAlignmentRight];
}
- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self setRowContent:rowContent_];
}
@end

static UIButton *CYM3PackageInfoRow(NSString *symbol, UIColor *color, NSString *title, NSString *value, UILabel **valueOut, BOOL disclosure) {
    CYM3PackageInfoButton *row([CYM3PackageInfoButton buttonWithType:UIButtonTypeSystem]);
    [row setTranslatesAutoresizingMaskIntoConstraints:NO];
    [row setContentHorizontalAlignment:UIControlContentHorizontalAlignmentFill];
    [row setBackgroundColor:[UIColor clearColor]];
    [row setIsAccessibilityElement:YES];
    [row setAccessibilityTraits:disclosure ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText];

    UIView *iconTile([[[UIView alloc] init] autorelease]);
    [iconTile setTranslatesAutoresizingMaskIntoConstraints:NO];
    [iconTile setBackgroundColor:[UIColor clearColor]];
    [[iconTile layer] setCornerRadius:11.0f];
    [[iconTile layer] setCornerCurve:kCACornerCurveContinuous];

    UIImageView *icon([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:symbol]] autorelease]);
    [icon setTranslatesAutoresizingMaskIntoConstraints:NO];
    [icon setTintColor:color];
    [icon setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22.0f weight:UIImageSymbolWeightRegular]];
    [iconTile addSubview:icon];

    UILabel *titleLabel(CYM3Label(UIFontTextStyleSubheadline, [UIColor labelColor], 0));
    [titleLabel setText:title];
    [titleLabel setLineBreakMode:NSLineBreakByTruncatingTail];
    UILabel *valueLabel(CYM3Label(UIFontTextStyleFootnote, [UIColor secondaryLabelColor], 0));
    [valueLabel setText:value];
    [valueLabel setTag:7002];
    [valueLabel setLineBreakMode:NSLineBreakByTruncatingMiddle];
    [valueLabel setTextAlignment:NSTextAlignmentRight];
    [valueLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    if (valueOut != NULL)
        *valueOut = valueLabel;

    UIImageView *chevron([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:@"chevron.right"]] autorelease]);
    [chevron setTranslatesAutoresizingMaskIntoConstraints:NO];
    [chevron setTintColor:[UIColor tertiaryLabelColor]];
    [chevron setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13.0f weight:UIImageSymbolWeightSemibold]];
    [chevron setHidden:!disclosure];

    UIStackView *line([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:iconTile, titleLabel, valueLabel, chevron, nil]] autorelease]);
    [line setTranslatesAutoresizingMaskIntoConstraints:NO];
    [line setAxis:UILayoutConstraintAxisHorizontal];
    [line setAlignment:UIStackViewAlignmentCenter];
    [line setSpacing:11.0f];
    [line setUserInteractionEnabled:NO];
    [row addSubview:line];
    [row setRowContent:line];

    UIView *separator([[[UIView alloc] init] autorelease]);
    [separator setTranslatesAutoresizingMaskIntoConstraints:NO];
    [separator setBackgroundColor:[[UIColor separatorColor] colorWithAlphaComponent:0.28f]];
    [separator setTag:7001];
    [row addSubview:separator];

    [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
        [[row heightAnchor] constraintGreaterThanOrEqualToConstant:52.0f],
        [[line leadingAnchor] constraintEqualToAnchor:[row leadingAnchor] constant:13.0f],
        [[line trailingAnchor] constraintEqualToAnchor:[row trailingAnchor] constant:-13.0f],
        [[line topAnchor] constraintEqualToAnchor:[row topAnchor] constant:9.0f],
        [[line bottomAnchor] constraintEqualToAnchor:[row bottomAnchor] constant:-9.0f],
        [[iconTile widthAnchor] constraintEqualToConstant:30.0f],
        [[iconTile heightAnchor] constraintEqualToConstant:30.0f],
        [[icon centerXAnchor] constraintEqualToAnchor:[iconTile centerXAnchor]],
        [[icon centerYAnchor] constraintEqualToAnchor:[iconTile centerYAnchor]],
        [[chevron widthAnchor] constraintEqualToConstant:10.0f],
        [[separator leadingAnchor] constraintEqualToAnchor:[row leadingAnchor] constant:54.0f],
        [[separator trailingAnchor] constraintEqualToAnchor:[row trailingAnchor]],
        [[separator bottomAnchor] constraintEqualToAnchor:[row bottomAnchor]],
        [[separator heightAnchor] constraintEqualToConstant:1.0f / [[UIScreen mainScreen] scale]],
    nil]];
    return row;
}

@interface CydiaModernPackageDetailView () {
    UIActivityIndicatorView *spinner_;
    UIImageView *icon_;
    UILabel *name_;
    UILabel *identifier_;
    UILabel *summary_;
    UILabel *version_;
    UIStackView *identityStack_;
    UIStackView *contentStack_;
    UIStackView *commercialBadge_;
    UIVisualEffectView *accountNoticeCard_;
    UILabel *accountNotice_;
    UIButton *accountNoticeButton_;
    UIStackView *accountStateRow_;
    UIImageView *accountStateIcon_;
    UILabel *accountStateLabel_;
    NSString *accountState_;
    NSLayoutConstraint *accountStateHeight_;
    CGFloat accountStateMeasuredWidth_;
    UIFont *accountStateMeasuredFont_;
    UIImageView *stateIcon_;
    UIView *stateTile_;
    UILabel *stateTitle_;
    UILabel *stateDetail_;
    NSLayoutConstraint *stateDetailMinimumHeight_;
    BOOL commercial_;
    UIButton *action_;
    UIStackView *actionContent_;
    NSLayoutConstraint *actionWidth_;
    UIStackView *identityRow_;
    NSLayoutConstraint *identityWidth_;
    UILabel *repositoryValue_;
    UILabel *authorValue_;
    UILabel *sectionValue_;
    UILabel *sizeValue_;
    UIButton *settings_;
    UIButton *files_;
}
@end

@implementation CydiaModernPackageDetailView

- (void) dealloc {
    [actionWidth_ release];
    [stateDetailMinimumHeight_ release];
    [identityWidth_ release];
    [commercialBadge_ release];
    [accountNoticeCard_ release];
    [accountState_ release];
    [accountStateHeight_ release];
    [accountStateMeasuredFont_ release];
    [super dealloc];
}

- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
        [self setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self setBackgroundColor:[UIColor systemGroupedBackgroundColor]];

        UIScrollView *scroll([[[UIScrollView alloc] init] autorelease]);
        [scroll setTranslatesAutoresizingMaskIntoConstraints:NO];
        [scroll setAlwaysBounceVertical:YES];
        [self addSubview:scroll];

        UIStackView *content([[[UIStackView alloc] init] autorelease]);
        [content setTranslatesAutoresizingMaskIntoConstraints:NO];
        [content setAxis:UILayoutConstraintAxisVertical];
        [content setAlignment:UIStackViewAlignmentFill];
        [content setSpacing:12.0f];
        [scroll addSubview:content];
        contentStack_ = content;

        UIVisualEffectView *hero(CYM3ContentCard(24.0f));
        icon_ = [[[CydiaSymbolView alloc] init] autorelease];
        [icon_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [icon_ setContentMode:UIViewContentModeScaleAspectFit];
        [[icon_ layer] setCornerRadius:17.0f];
        [[icon_ layer] setCornerCurve:kCACornerCurveContinuous];
        [[icon_ layer] setMasksToBounds:YES];

        name_ = CYM3Label(UIFontTextStyleTitle2, [UIColor labelColor], 0);
        [name_ setLineBreakMode:NSLineBreakByWordWrapping];
        identifier_ = CYM3Label(UIFontTextStyleCaption1, [UIColor secondaryLabelColor], 0);
        [identifier_ setLineBreakMode:NSLineBreakByCharWrapping];
        version_ = CYM3Label(UIFontTextStyleSubheadline, CYModernAccentColor(), 0);
        summary_ = CYM3Label(UIFontTextStyleBody, [UIColor secondaryLabelColor], 0);

        UIStackView *identity([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:name_, identifier_, version_, nil]] autorelease]);
        identityStack_ = identity;
        UIImageView *paidIcon([[[CydiaSymbolView alloc] initWithImage:[UIImage cy_symbolNamed:@"creditcard"]] autorelease]);
        [paidIcon setTintColor:CYModernCommercialColor()];
        [paidIcon setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16.0f weight:UIImageSymbolWeightMedium]];
        [paidIcon setContentMode:UIViewContentModeScaleAspectFit];
        [paidIcon setTranslatesAutoresizingMaskIntoConstraints:NO];
        [paidIcon setIsAccessibilityElement:NO];
        UILabel *paidLabel(CYM3Label(UIFontTextStyleSubheadline, CYModernCommercialColor(), 0));
        [paidLabel setText:CYLocalize(@"Paid package")];
        commercialBadge_ = [[UIStackView alloc] initWithArrangedSubviews:@[paidIcon, paidLabel]];
        [commercialBadge_ setAxis:UILayoutConstraintAxisHorizontal];
        [commercialBadge_ setAlignment:UIStackViewAlignmentCenter];
        [commercialBadge_ setSpacing:6.0f];
        [commercialBadge_ setIsAccessibilityElement:YES];
        [commercialBadge_ setAccessibilityLabel:CYLocalize(@"Paid package")];
        [commercialBadge_ setAccessibilityIdentifier:@"CydiaPaidPackageBadge"];
        [[paidIcon widthAnchor] constraintEqualToConstant:20.0f].active = YES;
        [[paidIcon heightAnchor] constraintEqualToConstant:20.0f].active = YES;
        [identity setAxis:UILayoutConstraintAxisVertical];
        [identity setAlignment:UIStackViewAlignmentFill];
        [identity setSpacing:3.0f];
        UIStackView *heroTop([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:icon_, identity, nil]] autorelease]);
        identityRow_ = heroTop;
        identityWidth_ = [[[identity widthAnchor] constraintEqualToAnchor:[heroTop widthAnchor]] retain];
        [heroTop setAxis:UILayoutConstraintAxisHorizontal];
        [heroTop setAlignment:UIStackViewAlignmentCenter];
        [heroTop setSpacing:15.0f];
        UIStackView *heroContent([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:heroTop, summary_, nil]] autorelease]);
        [heroContent setTranslatesAutoresizingMaskIntoConstraints:NO];
        [heroContent setAxis:UILayoutConstraintAxisVertical];
        [heroContent setAlignment:UIStackViewAlignmentFill];
        [heroContent setSpacing:14.0f];
        [[hero contentView] addSubview:heroContent];

        UIVisualEffectView *actionDock(CYM3FloatingPanel());
        stateTile_ = [[[UIView alloc] init] autorelease];
        [stateTile_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [[stateTile_ layer] setCornerRadius:12.0f];
        [[stateTile_ layer] setCornerCurve:kCACornerCurveContinuous];
        stateIcon_ = [[[CydiaSymbolView alloc] init] autorelease];
        [stateIcon_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [stateIcon_ setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19.0f weight:UIImageSymbolWeightSemibold]];
        [stateTile_ addSubview:stateIcon_];
        stateTitle_ = CYM3Label(UIFontTextStyleHeadline, [UIColor labelColor], 0);
        stateDetail_ = CYM3Label(UIFontTextStyleCaption1, [UIColor secondaryLabelColor], 0);
        [stateDetail_ setLineBreakMode:NSLineBreakByTruncatingMiddle];
        stateDetailMinimumHeight_ = [[[stateDetail_ heightAnchor] constraintGreaterThanOrEqualToConstant:0.0f] retain];
        UIStackView *stateLabels([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:stateTitle_, stateDetail_, nil]] autorelease]);
        [stateLabels setAxis:UILayoutConstraintAxisVertical];
        [stateLabels setSpacing:2.0f];
        UIStackView *state([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:stateTile_, stateLabels, nil]] autorelease]);
        [state setAxis:UILayoutConstraintAxisHorizontal];
        [state setAlignment:UIStackViewAlignmentCenter];
        [state setSpacing:11.0f];

        action_ = CYM3FilledButton();
        [action_ setContentEdgeInsets:UIEdgeInsetsMake(10.0f, 18.0f, 10.0f, 18.0f)];
        [action_ setContentHorizontalAlignment:UIControlContentHorizontalAlignmentCenter];
        [action_ setContentVerticalAlignment:UIControlContentVerticalAlignmentCenter];
        [[action_ titleLabel] setTextAlignment:NSTextAlignmentCenter];
        [[action_ titleLabel] setLineBreakMode:NSLineBreakByWordWrapping];
        [action_ setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *actionContent([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:state, action_, nil]] autorelease]);
        actionContent_ = actionContent;
        [actionContent setTranslatesAutoresizingMaskIntoConstraints:NO];
        [actionContent setAxis:UILayoutConstraintAxisHorizontal];
        [actionContent setAlignment:UIStackViewAlignmentCenter];
        [actionContent setSpacing:12.0f];
        [[actionDock contentView] addSubview:actionContent];

        accountNoticeCard_ = [CYM3ContentCard(20.0f) retain];
        [accountNoticeCard_ setAccessibilityIdentifier:@"CydiaPackageAccountNotice"];
        accountNotice_ = CYM3Label(UIFontTextStyleBody, [UIColor secondaryLabelColor], 0);
        accountStateIcon_ = [[[CydiaSymbolView alloc] init] autorelease];
        [accountStateIcon_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [accountStateIcon_ setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18.0f weight:UIImageSymbolWeightMedium]];
        [accountStateIcon_ setContentMode:UIViewContentModeScaleAspectFit];
        [accountStateIcon_ setIsAccessibilityElement:NO];
        accountStateLabel_ = CYM3Label(UIFontTextStyleSubheadline, [UIColor labelColor], 0);
        [accountStateLabel_ setLineBreakMode:NSLineBreakByWordWrapping];
        [accountStateLabel_ setIsAccessibilityElement:NO];
        accountStateRow_ = [[[UIStackView alloc] initWithArrangedSubviews:@[accountStateIcon_, accountStateLabel_]] autorelease];
        [accountStateRow_ setAxis:UILayoutConstraintAxisHorizontal];
        [accountStateRow_ setAlignment:UIStackViewAlignmentCenter];
        [accountStateRow_ setSpacing:8.0f];
        [accountStateRow_ setIsAccessibilityElement:YES];
        [accountStateRow_ setAccessibilityIdentifier:@"CydiaPackageAccountState"];
        [accountStateRow_ setAccessibilityLabel:CYLocalize(@"Repository Accounts")];
        accountStateHeight_ = [[[accountStateRow_ heightAnchor] constraintEqualToConstant:22.0f] retain];
        [accountStateHeight_ setActive:YES];
        accountNoticeButton_ = [CYM3AdaptiveButton buttonWithType:UIButtonTypeSystem];
        [accountNoticeButton_ setTitle:CYLocalize(@"Manage Account") forState:UIControlStateNormal];
        [accountNoticeButton_ setImage:[UIImage cy_symbolNamed:@"person.crop.circle"] forState:UIControlStateNormal];
        [[accountNoticeButton_ titleLabel] setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
        [[accountNoticeButton_ titleLabel] setAdjustsFontForContentSizeCategory:YES];
        [[accountNoticeButton_ titleLabel] setNumberOfLines:0];
        [[accountNoticeButton_ titleLabel] setTextAlignment:NSTextAlignmentCenter];
        [accountNoticeButton_ setContentEdgeInsets:UIEdgeInsetsMake(10.0f, 14.0f, 10.0f, 14.0f)];
        [accountNoticeButton_ setAccessibilityIdentifier:@"CydiaPackageManageAccount"];
        UIStackView *accountContent([[[UIStackView alloc] initWithArrangedSubviews:@[accountNotice_, accountStateRow_, accountNoticeButton_]] autorelease]);
        [accountContent setTranslatesAutoresizingMaskIntoConstraints:NO];
        [accountContent setAxis:UILayoutConstraintAxisVertical];
        [accountContent setSpacing:6.0f];
        [[accountNoticeCard_ contentView] addSubview:accountContent];
        [NSLayoutConstraint activateConstraints:@[
            [[accountContent leadingAnchor] constraintEqualToAnchor:[[accountNoticeCard_ contentView] leadingAnchor] constant:14.0f],
            [[accountContent trailingAnchor] constraintEqualToAnchor:[[accountNoticeCard_ contentView] trailingAnchor] constant:-14.0f],
            [[accountContent topAnchor] constraintEqualToAnchor:[[accountNoticeCard_ contentView] topAnchor] constant:12.0f],
            [[accountContent bottomAnchor] constraintEqualToAnchor:[[accountNoticeCard_ contentView] bottomAnchor] constant:-12.0f],
            [[accountStateIcon_ widthAnchor] constraintEqualToConstant:20.0f],
            [[accountStateIcon_ heightAnchor] constraintEqualToConstant:20.0f],
            [[accountNoticeButton_ heightAnchor] constraintGreaterThanOrEqualToConstant:44.0f]
        ]];
        [self setAccountState:nil];

        UILabel *informationTitle(CYM3Label(UIFontTextStyleCaption1, [UIColor secondaryLabelColor], 1));
        [informationTitle setText:CYLocalize(@"PACKAGE INFORMATION")];
        UIVisualEffectView *information(CYM3ContentCard(24.0f));
        UIButton *repository(CYM3PackageInfoRow(@"square.stack.3d.up", CYModernAccentColor(), CYLocalize(@"Repository"), @"—", &repositoryValue_, NO));
        UIButton *author(CYM3PackageInfoRow(@"person.crop.circle", CYModernAccentColor(), CYLocalize(@"Author"), @"—", &authorValue_, NO));
        UIButton *section(CYM3PackageInfoRow(@"square.grid.2x2", CYModernAccentColor(), CYLocalize(@"Category"), @"—", &sectionValue_, NO));
        UIButton *size(CYM3PackageInfoRow(@"internaldrive", CYModernAccentColor(), CYLocalize(@"Installed Size"), @"—", &sizeValue_, NO));
        [[size viewWithTag:7001] setHidden:YES];
        UIStackView *informationRows([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:repository, author, section, size, nil]] autorelease]);
        [informationRows setTranslatesAutoresizingMaskIntoConstraints:NO];
        [informationRows setAxis:UILayoutConstraintAxisVertical];
        [informationRows setSpacing:0.0f];
        [[information contentView] addSubview:informationRows];

        UILabel *manageTitle(CYM3Label(UIFontTextStyleCaption1, [UIColor secondaryLabelColor], 1));
        [manageTitle setText:CYLocalize(@"MANAGE PACKAGE")];
        UIVisualEffectView *manage(CYM3ContentCard(24.0f));
        settings_ = CYM3PackageInfoRow(@"slider.horizontal.3", [UIColor systemGrayColor], CYLocalize(@"Package Settings"), CYLocalize(@"Visibility & updates"), NULL, YES);
        files_ = CYM3PackageInfoRow(@"folder", CYModernAccentColor(), CYLocalize(@"Installed Files"), CYLocalize(@"Browse package contents"), NULL, YES);
        [[files_ viewWithTag:7001] setHidden:YES];
        UIStackView *manageRows([[[UIStackView alloc] initWithArrangedSubviews:[NSArray arrayWithObjects:settings_, files_, nil]] autorelease]);
        [manageRows setTranslatesAutoresizingMaskIntoConstraints:NO];
        [manageRows setAxis:UILayoutConstraintAxisVertical];
        [manageRows setSpacing:0.0f];
        [[manage contentView] addSubview:manageRows];

        [content addArrangedSubview:hero];
        [content addArrangedSubview:actionDock];
        [content addArrangedSubview:informationTitle];
        [content addArrangedSubview:information];
        [content addArrangedSubview:manageTitle];
        [content addArrangedSubview:manage];
        [content setCustomSpacing:18.0f afterView:actionDock];
        [content setCustomSpacing:18.0f afterView:information];
        [content setCustomSpacing:18.0f afterView:manage];

        spinner_ = [[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge] autorelease];
        [spinner_ setTranslatesAutoresizingMaskIntoConstraints:NO];
        [spinner_ setHidesWhenStopped:YES];
        [spinner_ setColor:CYModernAccentColor()];
        [self addSubview:spinner_];

        [NSLayoutConstraint activateConstraints:[NSArray arrayWithObjects:
            [[scroll leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
            [[scroll trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
            [[scroll topAnchor] constraintEqualToAnchor:[self topAnchor]],
            [[scroll bottomAnchor] constraintEqualToAnchor:[self bottomAnchor]],
            [[content leadingAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] leadingAnchor] constant:16.0f],
            [[content trailingAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] trailingAnchor] constant:-16.0f],
            [[content topAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] topAnchor] constant:14.0f],
            [[content bottomAnchor] constraintEqualToAnchor:[[scroll contentLayoutGuide] bottomAnchor] constant:-26.0f],
            [[content widthAnchor] constraintEqualToAnchor:[[scroll frameLayoutGuide] widthAnchor] constant:-32.0f],
            [[heroContent leadingAnchor] constraintEqualToAnchor:[[hero contentView] leadingAnchor] constant:18.0f],
            [[heroContent trailingAnchor] constraintEqualToAnchor:[[hero contentView] trailingAnchor] constant:-18.0f],
            [[heroContent topAnchor] constraintEqualToAnchor:[[hero contentView] topAnchor] constant:18.0f],
            [[heroContent bottomAnchor] constraintEqualToAnchor:[[hero contentView] bottomAnchor] constant:-18.0f],
            [[icon_ widthAnchor] constraintEqualToConstant:60.0f],
            [[icon_ heightAnchor] constraintEqualToConstant:60.0f],
            [[actionDock heightAnchor] constraintGreaterThanOrEqualToConstant:76.0f],
            [[actionContent leadingAnchor] constraintEqualToAnchor:[[actionDock contentView] leadingAnchor] constant:13.0f],
            [[actionContent trailingAnchor] constraintEqualToAnchor:[[actionDock contentView] trailingAnchor] constant:-13.0f],
            [[actionContent topAnchor] constraintEqualToAnchor:[[actionDock contentView] topAnchor] constant:11.0f],
            [[actionContent bottomAnchor] constraintEqualToAnchor:[[actionDock contentView] bottomAnchor] constant:-11.0f],
            [[stateTile_ widthAnchor] constraintEqualToConstant:42.0f],
            [[stateTile_ heightAnchor] constraintEqualToConstant:42.0f],
            [[stateIcon_ centerXAnchor] constraintEqualToAnchor:[stateTile_ centerXAnchor]],
            [[stateIcon_ centerYAnchor] constraintEqualToAnchor:[stateTile_ centerYAnchor]],
            [[action_ heightAnchor] constraintGreaterThanOrEqualToConstant:44.0f],
            // Prevent Upgrade/Reinstall/Modify from jumping horizontally as
            // their intrinsic title widths change.

            [[informationRows leadingAnchor] constraintEqualToAnchor:[[information contentView] leadingAnchor]],
            [[informationRows trailingAnchor] constraintEqualToAnchor:[[information contentView] trailingAnchor]],
            [[informationRows topAnchor] constraintEqualToAnchor:[[information contentView] topAnchor]],
            [[informationRows bottomAnchor] constraintEqualToAnchor:[[information contentView] bottomAnchor]],
            [[manageRows leadingAnchor] constraintEqualToAnchor:[[manage contentView] leadingAnchor]],
            [[manageRows trailingAnchor] constraintEqualToAnchor:[[manage contentView] trailingAnchor]],
            [[manageRows topAnchor] constraintEqualToAnchor:[[manage contentView] topAnchor]],
            [[manageRows bottomAnchor] constraintEqualToAnchor:[[manage contentView] bottomAnchor]],
            [[spinner_ centerXAnchor] constraintEqualToAnchor:[self centerXAnchor]],
            [[spinner_ centerYAnchor] constraintEqualToAnchor:[self centerYAnchor]],
        nil]];
        actionWidth_ = [[[action_ widthAnchor] constraintEqualToConstant:144.0f] retain];
        [self updateAccessibleLayout];
        [self setLoading:YES];
    }
    return self;
}

- (void) updateAccessibleLayout {
    BOOL large(UIContentSizeCategoryIsAccessibilityCategory([[self traitCollection] preferredContentSizeCategory]));
    UIFont *caption([UIFont preferredFontForTextStyle:UIFontTextStyleCaption1 compatibleWithTraitCollection:[self traitCollection]]);
    [stateDetailMinimumHeight_ setConstant:ceil([caption lineHeight] * 2.0f)];
    [stateDetailMinimumHeight_ setActive:commercial_ && !large];
    [identityWidth_ setActive:large];
    [identityRow_ setAxis:large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal];
    [actionWidth_ setActive:!large];
    [actionContent_ setAxis:large ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal];
    [actionContent_ setAlignment:large ? UIStackViewAlignmentFill : UIStackViewAlignmentCenter];
    [self updateAccountStateLayout];
}

- (void) updateAccountStateLayout {
    UIFont *font([UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline compatibleWithTraitCollection:[self traitCollection]]);
    [accountStateLabel_ setFont:font];
    // Content margins (32), card padding (28), symbol (20) and spacing (8).
    // Reserve every possible localized state at this width and text size, so
    // signing in never changes the card's height. Accessibility text can wrap.
    CGFloat width(CGRectGetWidth([self bounds]) - 88.0f);
    if (width <= 0.0f) {
        [accountStateHeight_ setConstant:MAX(22.0f, ceil([font lineHeight]))];
        return;
    }
    if (accountStateMeasuredWidth_ == width && [accountStateMeasuredFont_ isEqual:font]) return;
    accountStateMeasuredWidth_ = width;
    [accountStateMeasuredFont_ release];
    accountStateMeasuredFont_ = [font retain];
    CGFloat height(MAX(22.0f, ceil([font lineHeight])));
    for (NSString *label in @[CYLocalize(@"Signed in"), CYLocalize(@"Not signed in"),
        CYLocalize(@"Checking…"), CYLocalize(@"Unavailable")]) {
        CGRect bounds([label boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
            attributes:@{NSFontAttributeName:font} context:nil]);
        height = MAX(height, ceil(CGRectGetHeight(bounds)));
    }
    [accountStateHeight_ setConstant:height];
}

- (void) layoutSubviews {
    [self updateAccountStateLayout];
    [super layoutSubviews];
}
- (void) traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateAccessibleLayout];
}

- (void) setLoading:(BOOL)loading {
    if (loading) {
        [spinner_ startAnimating];
        [self setUserInteractionEnabled:NO];
    } else {
        [spinner_ stopAnimating];
        [self setUserInteractionEnabled:YES];
    }
}

- (void) setUnavailableIdentifier:(NSString *)identifier {
    [self setCommercial:NO];
    [self setAccountNotice:nil target:nil action:NULL];
    [icon_ setImage:[UIImage cy_symbolNamed:@"questionmark.folder.fill"]];
    [icon_ setTintColor:[UIColor systemOrangeColor]];
    [name_ setText:CYLocalize(@"Package unavailable")];
    [identifier_ setText:identifier];
    [summary_ setText:CYLocalize(@"Package data changed while repositories were refreshing. Return to Changes and try again.")];
    [version_ setText:CYLocalize(@"Refresh required")];

    [stateIcon_ setImage:[UIImage cy_symbolNamed:@"exclamationmark.triangle.fill"]];
    [stateIcon_ setTintColor:[UIColor systemOrangeColor]];
    [stateTile_ setBackgroundColor:[[UIColor systemOrangeColor] colorWithAlphaComponent:0.13f]];
    [stateTitle_ setText:CYLocalize(@"Unavailable")];
    [stateDetail_ setText:CYLocalize(@"Repository data changed")];
    [repositoryValue_ setText:@"—"];
    [authorValue_ setText:@"—"];
    [sectionValue_ setText:@"—"];
    [sizeValue_ setText:@"—"];
    [settings_ setEnabled:NO];
    [settings_ setAlpha:0.45f];
    [files_ setHidden:YES];
    [self setLoading:NO];
}

- (void) configureWithIcon:(UIImage *)icon
                      name:(NSString *)name
                identifier:(NSString *)identifier
                   summary:(NSString *)summary
          availableVersion:(NSString *)availableVersion
          installedVersion:(NSString *)installedVersion
                repository:(NSString *)repository
                   section:(NSString *)section
                      size:(NSString *)size
                    author:(NSString *)author {
    [settings_ setEnabled:YES];
    [settings_ setAlpha:1.0f];
    [icon_ setImage:icon];
    [name_ setText:[name length] == 0 ? CYLocalize(@"Package") : name];
    [identifier_ setText:identifier];
    [summary_ setText:[summary length] == 0 ? CYLocalize(@"No package description is available.") : summary];

    BOOL installed([installedVersion length] != 0);
    NSString *versionText(nil);
    if ([availableVersion length] != 0 && installed && ![availableVersion isEqualToString:installedVersion])
        versionText = [NSString stringWithFormat:CYLocalize(@"Available %@  •  Installed %@"), availableVersion, installedVersion];
    else if ([availableVersion length] != 0)
        versionText = [NSString stringWithFormat:CYLocalize(@"Version %@"), availableVersion];
    else if (installed)
        versionText = [NSString stringWithFormat:CYLocalize(@"Installed %@"), installedVersion];
    else
        versionText = CYLocalize(@"Version unavailable");
    [version_ setText:versionText];

    UIColor *stateColor(installed ? [UIColor systemGreenColor] : CYModernAccentColor());
    [stateIcon_ setImage:[UIImage cy_symbolNamed:installed ? @"checkmark.shield.fill" : @"arrow.down.circle.fill"]];
    [stateIcon_ setTintColor:stateColor];
    [stateTile_ setBackgroundColor:[stateColor colorWithAlphaComponent:0.13f]];
    [stateTitle_ setText:installed ? CYLocalize(@"Installed") : CYLocalize(@"Available")];
    [stateDetail_ setLineBreakMode:NSLineBreakByTruncatingMiddle];
    [stateDetail_ setText:installed ? installedVersion : CYLocalize(@"Ready to review")];

    [repositoryValue_ setText:[repository length] == 0 ? CYLocalize(@"Local") : repository];
    [authorValue_ setText:[author length] == 0 ? CYLocalize(@"Unknown author") : author];
    [sectionValue_ setText:[section length] == 0 ? CYLocalize(@"Uncategorized") : section];
    [sizeValue_ setText:[size length] == 0 || [size isEqualToString:@"—"] ? CYLocalize(@"Not provided") : size];
    [self setLoading:NO];
}

- (void) setCommercial:(BOOL)commercial {
    commercial_ = commercial;
    [self updateAccessibleLayout];
    if (commercial) {
        if ([commercialBadge_ superview] == nil)
            [identityStack_ insertArrangedSubview:commercialBadge_ atIndex:2];
    } else {
        [identityStack_ removeArrangedSubview:commercialBadge_];
        [commercialBadge_ removeFromSuperview];
        [self setAccountNotice:nil target:nil action:NULL];
    }
}

- (void) setAccountState:(NSString *)state {
    if (![state isEqualToString:@"signedIn"] && ![state isEqualToString:@"signedOut"] &&
        ![state isEqualToString:@"unsupported"])
        state = @"unknown";
    if ([accountState_ isEqualToString:state]) return;
    [accountState_ release];
    accountState_ = [state copy];
    NSString *label(CYLocalize(@"Checking…"));
    NSString *symbol(@"ellipsis.circle");
    UIColor *tint([UIColor secondaryLabelColor]);
    if ([state isEqualToString:@"signedIn"]) {
        label = CYLocalize(@"Signed in");
        symbol = @"checkmark.circle.fill";
        tint = [UIColor systemGreenColor];
    } else if ([state isEqualToString:@"signedOut"]) {
        label = CYLocalize(@"Not signed in");
        symbol = @"person.crop.circle";
    } else if ([state isEqualToString:@"unsupported"]) {
        label = CYLocalize(@"Unavailable");
        symbol = @"person.crop.circle";
    }
    [UIView performWithoutAnimation:^{
        [accountStateLabel_ setText:label];
        [accountStateIcon_ setImage:[UIImage cy_symbolNamed:symbol]];
        [accountStateIcon_ setTintColor:tint];
        [accountStateRow_ setAccessibilityValue:label];
    }];
}

- (void) setAccountNotice:(NSString *)notice target:(id)target action:(SEL)action {
    if ([accountNotice_ text] != notice && (notice == nil || ![[accountNotice_ text] isEqualToString:notice]))
        [accountNotice_ setText:notice];
    [accountNoticeButton_ removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    BOOL actionable(target != nil && action != NULL);
    [accountNoticeButton_ setEnabled:actionable];
    if (actionable)
        [accountNoticeButton_ addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    if ([notice length] != 0) {
        if ([accountNoticeCard_ superview] == nil)
            [contentStack_ insertArrangedSubview:accountNoticeCard_ atIndex:2];
    } else {
        [contentStack_ removeArrangedSubview:accountNoticeCard_];
        [accountNoticeCard_ removeFromSuperview];
        [self setAccountState:nil];
    }
}

- (void) setActionEnabled:(BOOL)enabled {
    [action_ setEnabled:enabled];
}

- (void) setActionStatusDetail:(NSString *)detail {
    [stateDetail_ setLineBreakMode:NSLineBreakByWordWrapping];
    if ([stateDetail_ text] == detail || (detail != nil && [[stateDetail_ text] isEqualToString:detail])) return;
    [stateDetail_ setText:detail];
}

- (UIView *) actionSourceView { return action_; }

- (void) updateHeroIcon:(UIImage *)icon {
    if (icon == nil)
        return;
    [UIView transitionWithView:icon_ duration:0.18
        options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
        animations:^{ [icon_ setImage:icon]; } completion:nil];
}

- (void) setActionTitle:(NSString *)title destructive:(BOOL)destructive target:(id)target action:(SEL)action {
    [action_ setHidden:[title length] == 0];
    if ([action_ titleForState:UIControlStateNormal] != title &&
        (title == nil || ![[action_ titleForState:UIControlStateNormal] isEqualToString:title])) {
        [UIView performWithoutAnimation:^{
            [action_ setTitle:title forState:UIControlStateNormal];
            [action_ layoutIfNeeded];
        }];
    }
    // Keep the action word optically and mathematically centred. Reserving
    // space for a leading symbol shifts short titles such as Modify/Install.
    [action_ setImage:nil forState:UIControlStateNormal];
    [action_ setTitleEdgeInsets:UIEdgeInsetsZero];
    [action_ setImageEdgeInsets:UIEdgeInsetsZero];
    [action_ setBackgroundColor:destructive ? [UIColor systemRedColor] : CYModernPrimaryButtonColor()];
    [action_ removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [action_ addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
}

- (void) setNavigationTarget:(id)target settingsAction:(SEL)settingsAction filesAction:(SEL)filesAction showFiles:(BOOL)showFiles {
    [settings_ removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [settings_ addTarget:target action:settingsAction forControlEvents:UIControlEventTouchUpInside];
    [files_ removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [files_ addTarget:target action:filesAction forControlEvents:UIControlEventTouchUpInside];
    [files_ setHidden:!showFiles];
    [[settings_ viewWithTag:7001] setHidden:!showFiles];
}

@end
