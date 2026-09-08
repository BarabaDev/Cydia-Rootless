#import "InstalledFilesView.h"
#import "InstalledFileTree.h"
#import "ModernLocalization.h"
#import "CyteKit/ModernAppearance.h"

@interface CYInstalledFileCell : UITableViewCell
@property(nonatomic, retain) UILabel *nameLabel;
@property(nonatomic, retain) UILabel *detailLabel;
@property(nonatomic, retain) CydiaSymbolView *symbolView;
@property(nonatomic, retain) CydiaSymbolView *disclosureView;
@property(nonatomic, retain) UIView *symbolTile;
@property(nonatomic, retain) NSLayoutConstraint *indent;
@end

@implementation CYInstalledFileCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier])) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.symbolTile = [[[UIView alloc] init] autorelease];
        self.symbolTile.layer.cornerRadius = 10;
        self.symbolTile.layer.cornerCurve = kCACornerCurveContinuous;
        self.symbolView = [[[CydiaSymbolView alloc] init] autorelease];
        self.symbolView.contentMode = UIViewContentModeScaleAspectFit;
        self.disclosureView = [[[CydiaSymbolView alloc] init] autorelease];
        self.disclosureView.contentMode = UIViewContentModeScaleAspectFit;
        self.disclosureView.tintColor = [UIColor tertiaryLabelColor];
        self.nameLabel = [[[UILabel alloc] init] autorelease];
        self.detailLabel = [[[UILabel alloc] init] autorelease];
        for (UILabel *label in @[self.nameLabel,self.detailLabel]) {
            label.numberOfLines = 0;
            label.lineBreakMode = NSLineBreakByCharWrapping;
            label.adjustsFontForContentSizeCategory = YES;
            label.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
            [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
        }
        self.nameLabel.textColor = [UIColor labelColor];
        self.detailLabel.textColor = [UIColor secondaryLabelColor];
        UIStackView *text = [[[UIStackView alloc] initWithArrangedSubviews:@[self.nameLabel,self.detailLabel]] autorelease];
        text.axis = UILayoutConstraintAxisVertical; text.spacing = 2;
        [self.contentView addSubview:self.symbolTile];
        [self.symbolTile addSubview:self.symbolView];
        [self.contentView addSubview:text];
        [self.contentView addSubview:self.disclosureView];
        for (UIView *view in @[self.symbolTile,self.symbolView,self.disclosureView,text])
            view.translatesAutoresizingMaskIntoConstraints = NO;
        self.indent = [self.symbolTile.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14];
        [NSLayoutConstraint activateConstraints:@[
            self.indent,
            [self.symbolTile.widthAnchor constraintEqualToConstant:30],
            [self.symbolTile.heightAnchor constraintEqualToConstant:30],
            [self.symbolTile.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.symbolTile.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8],
            [self.symbolView.centerXAnchor constraintEqualToAnchor:self.symbolTile.centerXAnchor],
            [self.symbolView.centerYAnchor constraintEqualToAnchor:self.symbolTile.centerYAnchor],
            [self.symbolView.widthAnchor constraintEqualToConstant:20],
            [self.symbolView.heightAnchor constraintEqualToConstant:20],
            [text.leadingAnchor constraintEqualToAnchor:self.symbolTile.trailingAnchor constant:10],
            [text.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
            [text.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
            [text.trailingAnchor constraintEqualToAnchor:self.disclosureView.leadingAnchor constant:-10],
            [self.disclosureView.widthAnchor constraintEqualToConstant:12],
            [self.disclosureView.heightAnchor constraintEqualToConstant:16],
            [self.disclosureView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.disclosureView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
        ]];
        self.isAccessibilityElement = YES;
    }
    return self;
}
- (void)dealloc {
    [_nameLabel release]; [_detailLabel release]; [_symbolView release]; [_disclosureView release];
    [_symbolTile release]; [_indent release]; [super dealloc];
}
@end

@interface CydiaInstalledFilesView () <UITableViewDataSource, UITableViewDelegate> {
    UITableView *table_;
    UILabel *heading_;
    UILabel *count_;
    UILabel *empty_;
    CYInstalledFileTree *tree_;
    NSArray *rows_;
    NSMutableSet *expanded_;
}
@end

@implementation CydiaInstalledFilesView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor systemGroupedBackgroundColor];
        expanded_ = [[NSMutableSet alloc] init];
        heading_ = [[UILabel alloc] init];
        count_ = [[UILabel alloc] init];
        for (UILabel *label in @[heading_,count_]) {
            label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = YES;
        }
        heading_.textColor = [UIColor labelColor]; count_.textColor = [UIColor secondaryLabelColor];
        UIStackView *header = [[[UIStackView alloc] initWithArrangedSubviews:@[heading_,count_]] autorelease];
        header.axis = UILayoutConstraintAxisVertical; header.spacing = 3;
        header.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:header];
        table_ = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
        CYModernizeTableView(table_);
        table_.translatesAutoresizingMaskIntoConstraints = NO;
        table_.rowHeight = UITableViewAutomaticDimension; table_.estimatedRowHeight = 52;
        table_.dataSource = self; table_.delegate = self;
        table_.sectionHeaderHeight = 4; table_.sectionFooterHeight = 4;
        [table_ registerClass:CYInstalledFileCell.class forCellReuseIdentifier:@"InstalledFile"];
        [self addSubview:table_];
        empty_ = [[UILabel alloc] init];
        empty_.numberOfLines = 0; empty_.textAlignment = NSTextAlignmentCenter;
        empty_.textColor = [UIColor secondaryLabelColor]; empty_.adjustsFontForContentSizeCategory = YES;
        empty_.text = CYLocalize(@"No installed files");
        empty_.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:empty_];
        [NSLayoutConstraint activateConstraints:@[
            [header.leadingAnchor constraintEqualToAnchor:self.readableContentGuide.leadingAnchor constant:4],
            [header.trailingAnchor constraintEqualToAnchor:self.readableContentGuide.trailingAnchor constant:-4],
            [header.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor constant:12],
            [table_.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:6],
            [table_.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor],
            [table_.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor],
            [table_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [empty_.leadingAnchor constraintEqualToAnchor:self.readableContentGuide.leadingAnchor constant:20],
            [empty_.trailingAnchor constraintEqualToAnchor:self.readableContentGuide.trailingAnchor constant:-20],
            [empty_.centerYAnchor constraintEqualToAnchor:table_.centerYAnchor],
        ]];
        [self updateFonts];
    }
    return self;
}
- (void)updateFonts {
    heading_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline compatibleWithTraitCollection:self.traitCollection];
    count_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote compatibleWithTraitCollection:self.traitCollection];
    empty_.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody compatibleWithTraitCollection:self.traitCollection];
}
- (void)layoutSubviews {
    heading_.hidden = CGRectGetHeight(self.bounds) > 0 && CGRectGetHeight(self.bounds) < 350;
    [super layoutSubviews];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateFonts]; [table_ reloadData];
}
- (void)setFilePaths:(NSArray *)paths directories:(NSSet *)directories packageName:(NSString *)name {
    BOOL first = tree_ == nil;
    [tree_ release]; tree_ = [[CYInstalledFileTree alloc] initWithPaths:paths directories:directories];
    [expanded_ intersectSet:[NSSet setWithArray:tree_.nodes.allKeys]];
    if (first) [expanded_ addObjectsFromArray:tree_.roots];
    heading_.text = name ?: CYLocalize(@"Installed Files");
    count_.text = CYLocalizedMetric(CYLocalize(@"Items"), tree_.itemCount);
    empty_.hidden = tree_.itemCount != 0;
    [self rebuildRows];
}
- (void)rebuildRows {
    [rows_ release]; rows_ = [[tree_ visibleRowsWithExpandedPaths:expanded_] copy];
    [table_ reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return rows_.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return 4; }
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section { return 4; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    CYInstalledFileCell *cell = [tableView dequeueReusableCellWithIdentifier:@"InstalledFile" forIndexPath:indexPath];
    NSDictionary *row = rows_[indexPath.row];
    BOOL folder = [row[@"directory"] boolValue], open = [expanded_ containsObject:row[@"path"]];
    NSString *extension = [row[@"name"] pathExtension].lowercaseString;
    UIColor *tint = [UIColor secondaryLabelColor]; NSString *symbol = @"doc.text";
    if (folder) { tint = CYModernAccentColor(); symbol = open ? @"folder.fill" : @"folder"; }
    else if ([@[@"png",@"jpg",@"jpeg",@"webp",@"heic",@"svg",@"gif"] containsObject:extension]) { tint = [UIColor systemPurpleColor]; symbol = @"photo"; }
    else if ([@[@"plist",@"json",@"xml",@"strings",@"css",@"js",@"html"] containsObject:extension]) { tint = [UIColor systemOrangeColor]; symbol = @"doc.text"; }
    else if ([@[@"dylib",@"a",@"so"] containsObject:extension] || extension.length == 0) { tint = [UIColor systemIndigoColor]; symbol = @"terminal"; }
    cell.symbolView.image = [UIImage cy_symbolNamed:symbol]; cell.symbolView.tintColor = tint;
    cell.symbolTile.backgroundColor = [tint colorWithAlphaComponent:.09];
    cell.nameLabel.text = row[@"name"];
    cell.nameLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
        scaledFontForFont:[UIFont systemFontOfSize:15 weight:folder ? UIFontWeightSemibold : UIFontWeightRegular]
        compatibleWithTraitCollection:tableView.traitCollection];
    cell.detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1 compatibleWithTraitCollection:tableView.traitCollection];
    cell.detailLabel.text = [row[@"depth"] unsignedIntegerValue] == 0 ? row[@"path"] : folder ?
        CYLocalizedMetric(CYLocalize(@"Items"), [row[@"children"] count]) : extension.length ? extension.uppercaseString : CYLocalize(@"File");
    cell.indent.constant = 14 + MIN([row[@"depth"] unsignedIntegerValue], (NSUInteger)2) * 10;
    cell.disclosureView.hidden = !folder;
    cell.disclosureView.image = [UIImage cy_symbolNamed:open ? @"chevron.down" : @"chevron.forward"];
    cell.selectionStyle = folder ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@",row[@"name"],folder ? CYLocalize(@"Folder") : CYLocalize(@"File")];
    cell.accessibilityValue = folder ? (open ? CYLocalize(@"Expanded") : CYLocalize(@"Collapsed")) : nil;
    cell.accessibilityHint = row[@"path"];
    cell.accessibilityTraits = folder ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
    cell.separatorInset = UIEdgeInsetsMake(0, cell.indent.constant + 40, 0, 16);
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = rows_[indexPath.row];
    if (![row[@"directory"] boolValue]) return;
    NSString *path = row[@"path"];
    // Keep the selected folder under the user's finger while updating its children.
    CGFloat offset = [tableView rectForRowAtIndexPath:indexPath].origin.y - tableView.contentOffset.y;
    if ([expanded_ containsObject:path]) [expanded_ removeObject:path]; else [expanded_ addObject:path];
    [self rebuildRows]; [tableView layoutIfNeeded];
    NSUInteger index = [rows_ indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger i, BOOL *stop) {
        return [item[@"path"] isEqualToString:path];
    }];
    if (index != NSNotFound) {
        NSIndexPath *position = [NSIndexPath indexPathForRow:index inSection:0];
        CGFloat desired = [tableView rectForRowAtIndexPath:position].origin.y - offset;
        CGFloat minimum = -tableView.adjustedContentInset.top;
        CGFloat maximum = MAX(minimum,tableView.contentSize.height-tableView.bounds.size.height+tableView.adjustedContentInset.bottom);
        [tableView setContentOffset:CGPointMake(0,MIN(MAX(desired,minimum),maximum)) animated:NO];
        if (UIAccessibilityIsVoiceOverRunning())
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, [tableView cellForRowAtIndexPath:position]);
    }
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSString *path = rows_[indexPath.row][@"path"];
    return [UIContextMenuConfiguration configurationWithIdentifier:path previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        UIAction *copy = [UIAction actionWithTitle:CYLocalize(@"Copy Path") image:[UIImage cy_symbolNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *action) {
            [UIPasteboard generalPasteboard].string = path;
        }];
        return [UIMenu menuWithTitle:path children:@[copy]];
    }];
}
- (void)dealloc {
    table_.dataSource = nil; table_.delegate = nil;
    [table_ release]; [heading_ release]; [count_ release]; [empty_ release];
    [tree_ release]; [rows_ release]; [expanded_ release]; [super dealloc];
}
@end
