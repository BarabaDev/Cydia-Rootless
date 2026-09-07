#import "PackageActionsController.h"
#import "ModernLocalization.h"
#import "CyteKit/ModernAppearance.h"

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
        header_ = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 116)];
        UIImageView *art = [[[UIImageView alloc] initWithImage:icon ?: [UIImage cy_symbolNamed:@"shippingbox"]] autorelease];
        art.contentMode = UIViewContentModeScaleAspectFit;
        art.layer.cornerRadius = 15; art.layer.cornerCurve = kCACornerCurveContinuous; art.clipsToBounds = YES;
        art.translatesAutoresizingMaskIntoConstraints = NO;
        name_ = [[UILabel alloc] init]; version_ = [[UILabel alloc] init];
        name_.text = name; version_.text = version;
        name_.textColor = [UIColor labelColor]; version_.textColor = [UIColor secondaryLabelColor];
        for (UILabel *label in @[name_,version_]) {
            label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = YES;
            label.lineBreakMode = NSLineBreakByWordWrapping;
        }
        UIStackView *text = [[[UIStackView alloc] initWithArrangedSubviews:@[name_,version_]] autorelease];
        text.axis = UILayoutConstraintAxisVertical; text.spacing = 5;
        text.translatesAutoresizingMaskIntoConstraints = NO;
        [header_ addSubview:art]; [header_ addSubview:text];
        [NSLayoutConstraint activateConstraints:@[
            [art.leadingAnchor constraintEqualToAnchor:header_.readableContentGuide.leadingAnchor constant:4],
            [art.centerYAnchor constraintEqualToAnchor:text.centerYAnchor],
            [art.widthAnchor constraintEqualToConstant:60], [art.heightAnchor constraintEqualToConstant:60],
            [art.topAnchor constraintGreaterThanOrEqualToAnchor:header_.topAnchor constant:20],
            [text.leadingAnchor constraintEqualToAnchor:art.trailingAnchor constant:16],
            [text.trailingAnchor constraintEqualToAnchor:header_.readableContentGuide.trailingAnchor constant:-4],
            [text.topAnchor constraintEqualToAnchor:header_.topAnchor constant:28],
            [text.bottomAnchor constraintEqualToAnchor:header_.bottomAnchor constant:-28],
        ]];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    CYModernizeTableView(self.tableView);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78;
    self.tableView.tableHeaderView = header_;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:CYLocalize(@"Cancel")
        style:UIBarButtonItemStylePlain target:self action:@selector(cancel)] autorelease];
    [self updateFonts];
}
- (void)updateFonts {
    name_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2 compatibleWithTraitCollection:self.traitCollection];
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
        [cell.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:74].active = YES;
    }
    NSDictionary *item = actions_[indexPath.row];
    BOOL destructive = [item[@"destructive"] boolValue];
    UIColor *color = destructive ? [UIColor systemRedColor] : [UIColor systemBlueColor];
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = item[@"title"];
    content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline compatibleWithTraitCollection:tableView.traitCollection];
    content.textProperties.color = destructive ? color : [UIColor labelColor];
    content.textProperties.numberOfLines = 0;
    content.image = [UIImage cy_symbolNamed:item[@"symbol"] ?: @"shippingbox"];
    content.imageProperties.tintColor = color;
    content.imageProperties.maximumSize = CGSizeMake(28,28);
    content.imageProperties.reservedLayoutSize = CGSizeMake(42,42);
    content.imageToTextPadding = 12;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(18,20,18,20);
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
