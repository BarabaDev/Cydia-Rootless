/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
*/

/* GNU General Public License, Version 3 {{{ */
/*
 * Cydia is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License,
 * or (at your option) any later version.
 *
 * Cydia is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Cydia.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

#include "CyteKit/UCPlatform.h"

#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>

#include "CyteKit/ListController.h"
#include "CyteKit/ModernAppearance.h"
#include "CyteKit/extern.h"

#include "iPhonePrivate.h"
#include <Menes/ObjectHandle.h>

static CGFloat CYStatusBarHeight() {
    CGSize size([[UIApplication sharedApplication] statusBarFrame].size);
    return UIInterfaceOrientationIsPortrait([[UIApplication sharedApplication] statusBarOrientation]) ? size.height : size.width;
}

@implementation CyteListController {
    _H<UITableView, 2> list_;
    _H<UIRefreshControl> refresh_;
}

- (bool) shouldYield {
    return false;
}

- (BOOL) supportsPullToRefresh {
    return YES;
}

- (void) deselectWithAnimation:(BOOL)animated {
    [list_ deselectRowAtIndexPath:[list_ indexPathForSelectedRow] animated:animated];
}

- (void) resizeForKeyboardBounds:(CGRect)bounds duration:(NSTimeInterval)duration curve:(UIViewAnimationCurve)curve {
    CGRect base = [[self view] bounds];
    base.size.height -= bounds.size.height;
    base.origin = [list_ frame].origin;

    [UIView beginAnimations:nil context:NULL];
    [UIView setAnimationBeginsFromCurrentState:YES];
    [UIView setAnimationCurve:curve];
    [UIView setAnimationDuration:duration];
    [list_ setFrame:base];
    [UIView commitAnimations];
}

- (void) resizeForKeyboardBounds:(CGRect)bounds duration:(NSTimeInterval)duration {
    [self resizeForKeyboardBounds:bounds duration:duration curve:UIViewAnimationCurveLinear];
}

- (void) resizeForKeyboardBounds:(CGRect)bounds {
    [self resizeForKeyboardBounds:bounds duration:0];
}

- (void) getKeyboardCurve:(UIViewAnimationCurve *)curve duration:(NSTimeInterval *)duration forNotification:(NSNotification *)notification {
    NSNumber *curveValue([[notification userInfo] objectForKey:UIKeyboardAnimationCurveUserInfoKey]);
    NSNumber *durationValue([[notification userInfo] objectForKey:UIKeyboardAnimationDurationUserInfoKey]);
    *curve = curveValue == nil ? UIViewAnimationCurveEaseInOut : (UIViewAnimationCurve) [curveValue integerValue];
    *duration = durationValue == nil ? 0.3 : [durationValue doubleValue];
}

- (void) keyboardWillShow:(NSNotification *)notification {
    CGRect bounds;
    CGPoint center;
    [[[notification userInfo] objectForKey:UIKeyboardBoundsUserInfoKey] getValue:&bounds];
    [[[notification userInfo] objectForKey:UIKeyboardCenterEndUserInfoKey] getValue:&center];

    NSTimeInterval duration;
    UIViewAnimationCurve curve;
    [self getKeyboardCurve:&curve duration:&duration forNotification:notification];

    CGRect kbframe = CGRectMake(Retina(center.x - bounds.size.width / 2), Retina(center.y - bounds.size.height / 2), bounds.size.width, bounds.size.height);
    UIViewController *base([self rootViewController]);
    CGRect viewframe = [[base view] convertRect:[list_ frame] fromView:[list_ superview]];
    CGRect intersection = CGRectIntersection(viewframe, kbframe);

    if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iPhoneOS_3_0) // XXX: _UIApplicationLinkedOnOrAfter(4)
        intersection.size.height += CYStatusBarHeight();

    [self resizeForKeyboardBounds:intersection duration:duration curve:curve];
}

- (void) keyboardWillHide:(NSNotification *)notification {
    NSTimeInterval duration;
    UIViewAnimationCurve curve;
    [self getKeyboardCurve:&curve duration:&duration forNotification:notification];

    [self resizeForKeyboardBounds:CGRectZero duration:duration curve:curve];
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self resizeForKeyboardBounds:CGRectZero];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void) viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    [self resizeForKeyboardBounds:CGRectZero];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self deselectWithAnimation:animated];
}

- (id) initWithTitle:(NSString *)title {
    if ((self = [super init]) != nil) {
        [[self navigationItem] setTitle:title];
    } return self;
}

- (void) releaseSubviews {
    refresh_ = nil;
    list_ = nil;
    [super releaseSubviews];
}

- (CGFloat) rowHeight {
    return 0;
}

- (UITableView *) tableView {
    return list_;
}

- (void) updateHeight {
    [list_ setRowHeight:[self rowHeight]];
}

- (void) loadView {
    UIView *view([[[UIView alloc] initWithFrame:[[UIScreen mainScreen] applicationFrame]] autorelease]);
    [view setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
    [self setView:view];

    list_ = [[[UITableView alloc] initWithFrame:[[self view] bounds] style:CYModernGroupedTableStyle()] autorelease];
    [list_ setAutoresizingMask:(UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight)];
    CYModernizeTableView(list_);
    [view addSubview:list_];

    if ([self supportsPullToRefresh]) {
        refresh_ = [[[UIRefreshControl alloc] init] autorelease];
        [refresh_ setTintColor:CYModernAccentColor()];
        [refresh_ addTarget:self action:@selector(pullToRefresh) forControlEvents:UIControlEventValueChanged];
        [list_ setRefreshControl:refresh_];
    }

    // XXX: is 20 the most optimal number here?
    [list_ setSectionIndexMinimumDisplayRowCount:20];

    [list_ setDataSource:(id)self];
    [list_ setDelegate:(id)self];

    [self updateHeight];
}

- (void) pullToRefresh {
    [self reloadData];
}

- (void) _reloadData {
    [self updateHeight];

    [list_ setDataSource:(id)self];
    [list_ reloadData];
    [refresh_ endRefreshing];
}

- (void) reloadData {
    [super reloadData];

    if ([self shouldYield])
        [self performSelector:@selector(_reloadData) withObject:nil afterDelay:0];
    else
        [self _reloadData];
}

- (void) resetCursor {
    [list_ scrollRectToVisible:CGRectMake(0, 0, 1, 1) animated:NO];
}

- (void) clearData {
    [self updateHeight];

    [list_ setDataSource:nil];
    [list_ reloadData];

    [self resetCursor];
}

@end
