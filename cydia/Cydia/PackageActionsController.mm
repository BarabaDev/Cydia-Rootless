#import "PackageActionsController.h"
#import "ModernLocalization.h"
#import "CyteKit/ModernAppearance.h"

// A compact action chooser, separate from the large version/review panels.
@interface CydiaPackageActionMenuController : CydiaModernSheetController <UIViewControllerTransitioningDelegate, UIPopoverPresentationControllerDelegate> {
    NSArray *items_;
    NSArray *buttons_;
    void (^selection_)(NSString *);
    UIStackView *actions_;
    UIScrollView *scroll_;
    UIButton *cancel_;
    BOOL choosing_;
    BOOL invalidated_;
    BOOL delivered_;
}
- (id)initWithActions:(NSArray *)actions selection:(void (^)(NSString *))selection;
- (CGFloat)menuHeightForWidth:(CGFloat)width;
- (void)invalidateSelection;
- (void)cancel;
@end

@interface CydiaPackageActionMenuPresentation : UIPresentationController
@end
@implementation CydiaPackageActionMenuPresentation {
    UIView *dimming_;
}
- (BOOL)shouldRemovePresentersView { return NO; }
- (CGRect)frameOfPresentedViewInContainerView {
    UIView *container=self.containerView;
    UIEdgeInsets safe=container.safeAreaInsets;
    CGFloat width=MIN(420.0,MAX(1.0,container.bounds.size.width-safe.left-safe.right-32.0));
    CGFloat available=MAX(1.0,container.bounds.size.height-safe.top-safe.bottom-32.0);
    CGFloat height=MIN(available,[(CydiaPackageActionMenuController *)self.presentedViewController menuHeightForWidth:width]);
    return CGRectMake((container.bounds.size.width-width)/2.0,
        container.bounds.size.height-safe.bottom-16.0-height,width,height);
}
- (void)presentationTransitionWillBegin {
    dimming_=[[UIView alloc] initWithFrame:self.containerView.bounds];
    dimming_.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    dimming_.backgroundColor=[UIColor colorWithWhite:0 alpha:0.32];
    dimming_.alpha=0;
    [dimming_ addGestureRecognizer:[[[UITapGestureRecognizer alloc] initWithTarget:self.presentedViewController action:@selector(cancel)] autorelease]];
    [self.containerView insertSubview:dimming_ atIndex:0];
    id<UIViewControllerTransitionCoordinator> coordinator=self.presentedViewController.transitionCoordinator;
    if (coordinator) [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context){dimming_.alpha=1;} completion:nil];
    else dimming_.alpha=1;
}
- (void)presentationTransitionDidEnd:(BOOL)completed { if (!completed) [dimming_ removeFromSuperview]; }
- (void)dismissalTransitionWillBegin {
    id<UIViewControllerTransitionCoordinator> coordinator=self.presentedViewController.transitionCoordinator;
    if (coordinator) [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context){dimming_.alpha=0;} completion:nil];
    else dimming_.alpha=0;
}
- (void)dismissalTransitionDidEnd:(BOOL)completed { if (completed) [dimming_ removeFromSuperview]; }
- (void)containerViewWillLayoutSubviews {
    [super containerViewWillLayoutSubviews];
    dimming_.frame=self.containerView.bounds;
    CGRect frame=self.frameOfPresentedViewInContainerView;
    self.presentedView.bounds=CGRectMake(0,0,frame.size.width,frame.size.height);
    self.presentedView.center=CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame));
}
- (void)dealloc { [dimming_ release]; [super dealloc]; }
@end

@interface CydiaPackageActionMenuAnimator : NSObject <UIViewControllerAnimatedTransitioning> {
    BOOL presenting_;
}
- (id)initPresenting:(BOOL)presenting;
@end
@implementation CydiaPackageActionMenuAnimator
- (id)initPresenting:(BOOL)presenting { if ((self=[super init])) presenting_=presenting; return self; }
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)context { return UIAccessibilityIsReduceMotionEnabled() ? 0.15 : 0.24; }
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    UIViewController *controller=[context viewControllerForKey:presenting_ ? UITransitionContextToViewControllerKey : UITransitionContextFromViewControllerKey];
    UIView *view=[context viewForKey:presenting_ ? UITransitionContextToViewKey : UITransitionContextFromViewKey] ?: controller.view;
    if (presenting_) {
        view.frame=[context finalFrameForViewController:controller];
        [context.containerView addSubview:view];
        [view layoutIfNeeded];
    }
    CGAffineTransform hidden=UIAccessibilityIsReduceMotionEnabled() ? CGAffineTransformIdentity :
        CGAffineTransformMakeTranslation(0,CGRectGetHeight(context.containerView.bounds)-CGRectGetMinY(view.frame));
    view.transform=presenting_ ? hidden : CGAffineTransformIdentity;
    view.alpha=presenting_ ? 0 : 1;
    [UIView animateWithDuration:[self transitionDuration:context] delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        view.transform=presenting_ ? CGAffineTransformIdentity : hidden;
        view.alpha=presenting_ ? 1 : 0;
    } completion:^(BOOL finished){
        BOOL completed=![context transitionWasCancelled];
        if (!presenting_ && completed) [view removeFromSuperview];
        view.transform=CGAffineTransformIdentity;
        view.alpha=1;
        [context completeTransition:completed];
    }];
}
@end

@implementation CydiaPackageActionMenuController
- (id)initWithActions:(NSArray *)actions selection:(void (^)(NSString *))selection {
    if ((self=[super init])) {
        items_=[[NSArray alloc] initWithArray:actions copyItems:YES];
        selection_=[selection copy];
    }
    return self;
}
- (UIButton *)buttonForItem:(NSDictionary *)item cancel:(BOOL)cancel {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints=NO;
    button.accessibilityIdentifier=cancel ? @"CANCEL" : item[@"id"];
    button.accessibilityLabel=cancel ? CYLocalize(@"Cancel") : item[@"title"];
    button.accessibilityTraits=UIAccessibilityTraitButton;
    UIButtonConfiguration *configuration=[UIButtonConfiguration plainButtonConfiguration];
    configuration.title=button.accessibilityLabel;
    // Equal insets keep the text itself centered. The decorative symbol has
    // its own leading column, so its width cannot shift translated titles.
    configuration.titleAlignment=UIButtonConfigurationTitleAlignmentCenter;
    configuration.contentInsets=NSDirectionalEdgeInsetsMake(13,56,13,56);
    configuration.titleLineBreakMode=NSLineBreakByWordWrapping;
    UIColor *color=[item[@"destructive"] boolValue] ? [UIColor systemRedColor] : CYModernAccentColor();
    configuration.baseForegroundColor=color;
    button.configuration=configuration;
    button.tintColor=color;
    button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentCenter;
    button.titleLabel.textAlignment=NSTextAlignmentCenter;
    UIImageView *symbol=[[[UIImageView alloc] initWithImage:[UIImage cy_symbolNamed:cancel ? @"xmark" : (item[@"symbol"] ?: @"shippingbox")]] autorelease];
    symbol.translatesAutoresizingMaskIntoConstraints=NO;
    symbol.contentMode=UIViewContentModeScaleAspectFit;
    symbol.preferredSymbolConfiguration=[UIImageSymbolConfiguration configurationWithPointSize:23 weight:UIImageSymbolWeightRegular];
    symbol.tintColor=color;
    symbol.isAccessibilityElement=NO;
    symbol.accessibilityIdentifier=@"CYPackageActionSymbol";
    [button addSubview:symbol];
    [NSLayoutConstraint activateConstraints:@[
        [symbol.leadingAnchor constraintEqualToAnchor:button.leadingAnchor constant:18],
        [symbol.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        [symbol.widthAnchor constraintEqualToConstant:26],
        [symbol.heightAnchor constraintEqualToConstant:30]
    ]];
    button.titleLabel.numberOfLines=0;
    button.titleLabel.adjustsFontForContentSizeCategory=YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:54].active=YES;
    [button addTarget:self action:cancel ? @selector(cancel) : @selector(choose:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (void)loadView {
    self.view=[[[UIView alloc] initWithFrame:CGRectZero] autorelease];
    self.view.backgroundColor=[UIColor clearColor];
    self.view.accessibilityViewIsModal=YES;
    scroll_=[[[UIScrollView alloc] init] autorelease];
    scroll_.translatesAutoresizingMaskIntoConstraints=NO;
    scroll_.backgroundColor=[UIColor secondarySystemGroupedBackgroundColor];
    scroll_.layer.cornerRadius=16; scroll_.layer.cornerCurve=kCACornerCurveContinuous;
    scroll_.clipsToBounds=YES;
    scroll_.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    actions_=[[[UIStackView alloc] init] autorelease];
    actions_.translatesAutoresizingMaskIntoConstraints=NO;
    actions_.axis=UILayoutConstraintAxisVertical;
    NSMutableArray *buttons=[NSMutableArray array];
    for (NSDictionary *item in items_) {
        if (buttons.count!=0) {
            UIView *separator=[[[UIView alloc] init] autorelease];
            separator.backgroundColor=[UIColor separatorColor];
            [separator.heightAnchor constraintEqualToConstant:1.0/UIScreen.mainScreen.scale].active=YES;
            [actions_ addArrangedSubview:separator];
        }
        UIButton *button=[self buttonForItem:item cancel:NO];
        [actions_ addArrangedSubview:button]; [buttons addObject:button];
    }
    buttons_=[buttons copy];
    cancel_=[self buttonForItem:nil cancel:YES];
    cancel_.backgroundColor=[UIColor secondarySystemGroupedBackgroundColor];
    cancel_.layer.cornerRadius=16; cancel_.layer.cornerCurve=kCACornerCurveContinuous; cancel_.clipsToBounds=YES;
    [scroll_ addSubview:actions_]; [self.view addSubview:scroll_]; [self.view addSubview:cancel_];
    [NSLayoutConstraint activateConstraints:@[
        [scroll_.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll_.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll_.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll_.bottomAnchor constraintEqualToAnchor:cancel_.topAnchor constant:-8],
        [cancel_.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [cancel_.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [cancel_.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [actions_.leadingAnchor constraintEqualToAnchor:scroll_.contentLayoutGuide.leadingAnchor],
        [actions_.trailingAnchor constraintEqualToAnchor:scroll_.contentLayoutGuide.trailingAnchor],
        [actions_.topAnchor constraintEqualToAnchor:scroll_.contentLayoutGuide.topAnchor],
        [actions_.bottomAnchor constraintEqualToAnchor:scroll_.contentLayoutGuide.bottomAnchor],
        [actions_.widthAnchor constraintEqualToAnchor:scroll_.frameLayoutGuide.widthAnchor]
    ]];
    [self updateFonts];
}
- (void)updateFonts {
    for (UIButton *button in [buttons_ arrayByAddingObject:cancel_]) {
        UIButtonConfiguration *configuration=button.configuration;
        UIFont *font=[UIFont preferredFontForTextStyle:button==cancel_ ? UIFontTextStyleHeadline : UIFontTextStyleBody compatibleWithTraitCollection:self.traitCollection];
        configuration.attributedTitle=[[[NSAttributedString alloc] initWithString:button.accessibilityLabel attributes:@{NSFontAttributeName:font}] autorelease];
        button.configuration=configuration;
    }
    self.preferredContentSize=CGSizeMake(340,[self menuHeightForWidth:340]);
    if (self.viewIfLoaded.window!=nil) [self.presentationController.containerView setNeedsLayout];
}
- (CGFloat)menuHeightForWidth:(CGFloat)width {
    [self loadViewIfNeeded];
    CGSize fitting=CGSizeMake(width,UILayoutFittingCompressedSize.height);
    CGFloat actions=[actions_ systemLayoutSizeFittingSize:fitting withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    CGFloat cancel=[cancel_ systemLayoutSizeFittingSize:fitting withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    return ceil(actions+8+cancel);
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (self.isViewLoaded && ![previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) [self updateFonts];
}
- (void)invalidateSelection {
    invalidated_=YES;
    [selection_ release]; selection_=nil;
    for (UIButton *button in buttons_) button.enabled=NO;
    cancel_.enabled=NO;
}
- (void)choose:(UIButton *)sender {
    if (choosing_ || invalidated_ || selection_==nil) return;
    choosing_=YES;
    for (UIButton *button in buttons_) button.enabled=NO;
    cancel_.enabled=NO;
    NSString *identifier=sender.accessibilityIdentifier;
    UIViewController *presenter=self.presentingViewController;
    void (^complete)(void)=^{
        if (delivered_ || invalidated_) return;
        delivered_=YES;
        void (^selection)(NSString *)=[[selection_ copy] autorelease];
        [self invalidateSelection];
        if (self.presentingViewController==nil && self.viewIfLoaded.window==nil && presenter.viewIfLoaded.window!=nil && selection!=nil)
            selection(identifier);
    };
    id<UIViewControllerTransitionCoordinator> coordinator=self.transitionCoordinator;
    if (self.isBeingDismissed && coordinator!=nil) {
        [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){
            if (context.isCancelled) [self invalidateSelection]; else complete();
        }];
    } else [self dismissViewControllerAnimated:YES completion:complete];
}
- (void)cancel {
    if (choosing_) return;
    [self invalidateSelection];
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (!choosing_) [self invalidateSelection];
}
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller { return UIModalPresentationNone; }
- (UIPresentationController *)presentationControllerForPresentedViewController:(UIViewController *)presented presentingViewController:(UIViewController *)presenting sourceViewController:(UIViewController *)source {
    return [[[CydiaPackageActionMenuPresentation alloc] initWithPresentedViewController:presented presentingViewController:presenting] autorelease];
}
- (id<UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented presentingController:(UIViewController *)presenting sourceController:(UIViewController *)source {
    return [[[CydiaPackageActionMenuAnimator alloc] initPresenting:YES] autorelease];
}
- (id<UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed {
    return [[[CydiaPackageActionMenuAnimator alloc] initPresenting:NO] autorelease];
}
- (void)dealloc { [items_ release]; [buttons_ release]; [selection_ release]; [super dealloc]; }
@end

BOOL CYPresentPackageActionMenu(UIViewController *presenter, UIView *sourceView, NSArray *actions, void (^selection)(NSString *)) {
    if (presenter.viewIfLoaded.window==nil || presenter.presentedViewController!=nil || actions.count==0 || selection==nil) return NO;
    CydiaPackageActionMenuController *menu=[[[CydiaPackageActionMenuController alloc] initWithActions:actions selection:selection] autorelease];
    if (presenter.traitCollection.userInterfaceIdiom==UIUserInterfaceIdiomPad) {
        menu.modalPresentationStyle=UIModalPresentationPopover;
        UIView *anchor=sourceView.window==presenter.view.window ? sourceView : presenter.view;
        menu.popoverPresentationController.sourceView=anchor;
        CGRect rect=anchor==sourceView ? anchor.bounds : CGRectMake(CGRectGetMidX(anchor.bounds),CGRectGetMidY(anchor.bounds),1,1);
        menu.popoverPresentationController.sourceRect=rect;
        menu.popoverPresentationController.permittedArrowDirections=UIPopoverArrowDirectionAny;
        menu.popoverPresentationController.backgroundColor=[UIColor systemGroupedBackgroundColor];
        menu.popoverPresentationController.delegate=menu;
    } else {
        menu.modalPresentationStyle=UIModalPresentationCustom;
        menu.transitioningDelegate=menu;
    }
    menu.view.tintColor=CYModernAccentColor();
    [presenter presentViewController:menu animated:YES completion:nil];
    return YES;
}

BOOL CYInvalidatePackageActionMenu(UIViewController *controller) {
    if (![controller isKindOfClass:CydiaPackageActionMenuController.class]) return NO;
    [(CydiaPackageActionMenuController *)controller invalidateSelection];
    return YES;
}

UINavigationController *CYPackageActionsNavigation(UIViewController *presenter) {
    for (UIViewController *candidate = presenter; candidate != nil; candidate = candidate.presentedViewController)
        if ([candidate isKindOfClass:UINavigationController.class] && !candidate.isBeingDismissed &&
            [[(UINavigationController *)candidate topViewController] isKindOfClass:CydiaPackageActionsController.class])
            return (UINavigationController *)candidate;
    // A sheet may be presented by a child of the selected tab/navigation stack.
    if ([presenter isKindOfClass:UITabBarController.class])
        return CYPackageActionsNavigation([(UITabBarController *)presenter selectedViewController]);
    if ([presenter isKindOfClass:UINavigationController.class])
        return CYPackageActionsNavigation([(UINavigationController *)presenter visibleViewController]);
    return nil;
}

void CYReplacePackagePanel(UINavigationController *navigation, UIViewController *page) {
    [UIView performWithoutAnimation:^{
        page.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
        navigation.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
        [navigation setViewControllers:@[page] animated:NO];
        [navigation.view layoutIfNeeded];
    }];
}

@implementation CydiaPackageActionsController {
    NSArray *actions_;
    void (^selection_)(NSString *);
    UIView *header_;
    UILabel *name_;
    UILabel *version_;
    BOOL choosing_;
}
- (instancetype)initWithTitle:(NSString *)title packageName:(NSString *)name version:(NSString *)version
    icon:(UIImage *)icon actions:(NSArray *)actions selection:(void (^)(NSString *identifier))selection {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = title;
        self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
        actions_ = [[NSArray alloc] initWithArray:actions copyItems:YES];
        selection_ = [selection copy];
        header_ = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 88)];
        UIImageView *art = [[[CydiaSymbolView alloc] initWithImage:icon ?: [UIImage cy_symbolNamed:@"shippingbox"]] autorelease];
        art.contentMode = UIViewContentModeScaleAspectFit;
        art.layer.cornerRadius = 11; art.layer.cornerCurve = kCACornerCurveContinuous; art.clipsToBounds = YES;
        art.translatesAutoresizingMaskIntoConstraints = NO;
        name_ = [[UILabel alloc] init]; version_ = [[UILabel alloc] init];
        name_.text = name; version_.text = version;
        name_.textColor = [UIColor labelColor]; version_.textColor = [UIColor secondaryLabelColor];
        for (UILabel *label in @[name_,version_]) {
            label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = YES;
            label.lineBreakMode = NSLineBreakByWordWrapping;
        }
        UIStackView *text = [[[UIStackView alloc] initWithArrangedSubviews:@[name_,version_]] autorelease];
        text.axis = UILayoutConstraintAxisVertical; text.spacing = 3;
        text.translatesAutoresizingMaskIntoConstraints = NO;
        [header_ addSubview:art]; [header_ addSubview:text];
        [NSLayoutConstraint activateConstraints:@[
            [art.leadingAnchor constraintEqualToAnchor:header_.readableContentGuide.leadingAnchor constant:4],
            [art.centerYAnchor constraintEqualToAnchor:text.centerYAnchor],
            [art.widthAnchor constraintEqualToConstant:48], [art.heightAnchor constraintEqualToConstant:48],
            [art.topAnchor constraintGreaterThanOrEqualToAnchor:header_.topAnchor constant:16],
            [text.leadingAnchor constraintEqualToAnchor:art.trailingAnchor constant:12],
            [text.trailingAnchor constraintEqualToAnchor:header_.readableContentGuide.trailingAnchor constant:-4],
            [text.topAnchor constraintEqualToAnchor:header_.topAnchor constant:18],
            [text.bottomAnchor constraintEqualToAnchor:header_.bottomAnchor constant:-18],
        ]];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    CYModernizeTableView(self.tableView);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    self.tableView.tableHeaderView = header_;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:CYLocalize(@"Cancel")
        style:UIBarButtonItemStylePlain target:self action:@selector(cancel)] autorelease];
    [self updateFonts];
}
- (void)updateFonts {
    name_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline compatibleWithTraitCollection:self.traitCollection];
    version_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline compatibleWithTraitCollection:self.traitCollection];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    // Sheet elevation and tint changes do not change the rows or their geometry.
    if (self.isViewLoaded && ![previous.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [UIView performWithoutAnimation:^{
            [self updateFonts]; [self.tableView reloadData]; [self.view setNeedsLayout];
        }];
    }
}
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (width <= 1) return;
    header_.frame = CGRectMake(0, 0, width, header_.bounds.size.height);
    [header_ layoutIfNeeded];
    CGSize fit = [header_ systemLayoutSizeFittingSize:CGSizeMake(width,UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (fabs(header_.bounds.size.height-fit.height)>.5 || fabs(header_.bounds.size.width-width)>.5) {
        header_.frame = CGRectMake(0,0,width,fit.height);
        self.tableView.tableHeaderView = header_;
    }
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return actions_.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PackageAction"];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"PackageAction"] autorelease];
        [cell.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    }
    NSDictionary *item = actions_[indexPath.row];
    BOOL destructive = [item[@"destructive"] boolValue];
    UIColor *color = destructive ? [UIColor systemRedColor] : CYModernAccentColor();
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = item[@"title"];
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline compatibleWithTraitCollection:tableView.traitCollection];
    content.textProperties.color = destructive ? color : [UIColor labelColor];
    content.textProperties.numberOfLines = 0;
    content.image = [UIImage cy_symbolNamed:item[@"symbol"] ?: @"shippingbox"];
    content.imageProperties.tintColor = color;
    content.imageProperties.maximumSize = CGSizeMake(24,24);
    content.imageProperties.reservedLayoutSize = CGSizeMake(28,28);
    content.imageToTextPadding = 12;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(12,16,12,16);
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (choosing_ || indexPath.row >= (NSInteger)actions_.count || selection_ == nil) return;
    choosing_ = YES; tableView.userInteractionEnabled = NO;
    [self retain]; // A successful selection replaces this controller synchronously.
    UINavigationController *navigation = [[self.navigationController retain] autorelease];
    BOOL wasModalInPresentation = navigation.modalInPresentation;
    navigation.modalInPresentation = YES;
    self.navigationItem.leftBarButtonItem.enabled = NO;
    NSString *identifier = actions_[indexPath.row][@"id"];
    void (^completion)(NSString *) = [[selection_ copy] autorelease];
    // The caller replaces the page inside this sheet. Dismissing first exposes
    // the package page and produces two modal animations for a single action.
    completion(identifier);
    if (navigation.topViewController == self && selection_ != nil) {
        // A busy refresh or failed preparation leaves the action available to retry.
        choosing_ = NO; tableView.userInteractionEnabled = YES;
        self.navigationItem.leftBarButtonItem.enabled = YES;
        navigation.modalInPresentation = wasModalInPresentation;
        [tableView deselectRowAtIndexPath:indexPath animated:NO];
    } else {
        [self invalidateSelection];
    }
    [self release];
}
- (void)invalidateSelection { [selection_ release]; selection_ = nil; }
- (void)cancel {
    [self invalidateSelection];
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed || self.navigationController.presentingViewController == nil)
        [self invalidateSelection];
}
- (void)dealloc {
    [actions_ release]; [selection_ release]; [header_ release]; [name_ release]; [version_ release]; [super dealloc];
}
@end
