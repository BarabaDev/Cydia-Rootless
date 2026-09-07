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

#include "CyteKit/ViewController.h"
#include "CyteKit/ModernAppearance.h"
#include "CyteKit/TabBarController.h"

#include "iPhonePrivate.h"
#include <Menes/ObjectHandle.h>

@implementation UIViewController (Cydia)

- (BOOL) hasLoaded {
    return YES;
}

- (void) reloadData {
    [self view];
}

- (void) unloadData {
    if (UIViewController *modal = [self modalViewController])
        [modal unloadData];
}

- (UIViewController *) parentOrPresentingViewController {
    if (UIViewController *parent = [self parentViewController])
        return parent;
    if ([self respondsToSelector:@selector(presentingViewController)])
        return [self presentingViewController];
    return nil;
}

- (UIViewController *) rootViewController {
    UIViewController *base(self);
    while ([base parentOrPresentingViewController] != nil)
        base = [base parentOrPresentingViewController];
    return base;
}

- (NSURL *) navigationURL {
    return nil;
}

@end

static UIScrollView *CYModernPrimaryScrollView(UIView *view) {
    // Never bind scroll-driven tab-bar behavior to content hidden behind a
    // native replacement surface (for example Package Details over WebView).
    if ([view isHidden])
        return nil;

    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scroll((UIScrollView *) view);
        if ([scroll isScrollEnabled])
            return scroll;
    }

    for (UIView *subview in [view subviews])
        if (UIScrollView *scroll = CYModernPrimaryScrollView(subview))
            return scroll;
    return nil;
}

@implementation CyteViewController {
    _transient id delegate_;
    BOOL loaded_;
    _H<UIColor> color_;
    _transient UIScrollView *modernScrollView_;
    BOOL modernTabBarHiddenForScroll_;
}

- (CyteTabBarController *) modernTabBarController {
    UITabBarController *tabs([self tabBarController]);
    if (tabs == nil)
        tabs = [[self navigationController] tabBarController];
    return [tabs isKindOfClass:[CyteTabBarController class]] ? (CyteTabBarController *) tabs : nil;
}

- (BOOL) isActiveModernScrollController {
    CyteTabBarController *tabs([self modernTabBarController]);
    if (tabs == nil || [[self view] window] == nil)
        return NO;
    UINavigationController *navigation([self navigationController]);
    if (navigation != nil && [navigation topViewController] != self)
        return NO;
    UIViewController *selected([tabs selectedViewController]);
    return selected == self || selected == navigation;
}

- (BOOL) modernScrollTabBarHidingEnabled {
    return YES;
}

- (void) setModernScrollTabBarHidden:(BOOL)hidden animated:(BOOL)animated {
    CyteTabBarController *tabs([self modernTabBarController]);
    if (tabs == nil)
        return;
    modernTabBarHiddenForScroll_ = hidden;
    [tabs setScrollTabBarHidden:hidden animated:animated];
}

- (void) restoreModernScrollTabBarWhenSettled {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restoreModernScrollTabBarWhenSettled) object:nil];
    if (modernScrollView_ != nil && ([modernScrollView_ isDragging] || [modernScrollView_ isDecelerating])) {
        [self performSelector:@selector(restoreModernScrollTabBarWhenSettled) withObject:nil afterDelay:0.12];
        return;
    }
    if (modernTabBarHiddenForScroll_)
        [self setModernScrollTabBarHidden:NO animated:YES];
}

- (void) modernScrollPanChanged:(UIPanGestureRecognizer *)gesture {
    if (![self isActiveModernScrollController]) {
        [self setModernScrollTabBarHidden:NO animated:NO];
        return;
    }

    // Home and Sources keep a fixed tab bar: never hide it on their scroll.
    if (![self modernScrollTabBarHidingEnabled]) {
        if (modernTabBarHiddenForScroll_)
            [self setModernScrollTabBarHidden:NO animated:NO];
        return;
    }

    UIGestureRecognizerState state([gesture state]);
    if (state == UIGestureRecognizerStateBegan) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restoreModernScrollTabBarWhenSettled) object:nil];
        return;
    }

    if (state == UIGestureRecognizerStateChanged) {
        CGPoint movement([gesture translationInView:modernScrollView_]);
        CGFloat vertical(movement.y < 0.0f ? -movement.y : movement.y);
        CGFloat horizontal(movement.x < 0.0f ? -movement.x : movement.x);
        UIEdgeInsets inset([modernScrollView_ adjustedContentInset]);
        CGFloat visibleHeight(CGRectGetHeight([modernScrollView_ bounds]) - inset.top - inset.bottom);
        BOOL scrollable([modernScrollView_ contentSize].height > visibleHeight + 12.0f);
        BOOL pullingPastTop([modernScrollView_ contentOffset].y <= -inset.top && movement.y > 0.0f);
        if (scrollable && !pullingPastTop && vertical >= 8.0f && vertical > horizontal) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restoreModernScrollTabBarWhenSettled) object:nil];
            if (!modernTabBarHiddenForScroll_)
                [self setModernScrollTabBarHidden:YES animated:YES];
        }
        return;
    }

    if (state == UIGestureRecognizerStateEnded || state == UIGestureRecognizerStateCancelled ||
        state == UIGestureRecognizerStateFailed) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restoreModernScrollTabBarWhenSettled) object:nil];
        [self performSelector:@selector(restoreModernScrollTabBarWhenSettled) withObject:nil afterDelay:0.12];
    }
}

- (void) trackModernScrollView {
    UIScrollView *scroll(CYModernPrimaryScrollView([self view]));
    if (scroll == modernScrollView_)
        return;
    if (modernScrollView_ != nil)
        [[modernScrollView_ panGestureRecognizer] removeTarget:self action:@selector(modernScrollPanChanged:)];
    modernScrollView_ = scroll;
    if (modernScrollView_ != nil)
        [[modernScrollView_ panGestureRecognizer] addTarget:self action:@selector(modernScrollPanChanged:)];
}

- (void) setDelegate:(id)delegate {
    delegate_ = delegate;
}

- (id) delegate {
    return delegate_;
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self setModernScrollTabBarHidden:NO animated:NO];

    UINavigationController *navigation([self navigationController]);
    if (navigation != nil) {
        CYModernizeNavigationController(navigation);
        NSArray *controllers([navigation viewControllers]);
        BOOL root([controllers count] != 0 && [controllers objectAtIndex:0] == self);
        // Native transaction pages explicitly choose a compact title before
        // presentation. Do not briefly expand it and collapse it again.
        if ([[self navigationItem] largeTitleDisplayMode] != UINavigationItemLargeTitleDisplayModeNever)
            [[self navigationItem] setLargeTitleDisplayMode:
                root ? UINavigationItemLargeTitleDisplayModeAlways : UINavigationItemLargeTitleDisplayModeNever];
    }

    // Load on first appearance. We don't need to set the loaded flag here
    // because it is set for us the first time -reloadData is called.
    if (![self hasLoaded])
        [self reloadData];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self trackModernScrollView];
}

- (void) viewWillDisappear:(BOOL)animated {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restoreModernScrollTabBarWhenSettled) object:nil];
    [self setModernScrollTabBarHidden:NO animated:NO];
    [super viewWillDisappear:animated];
}

- (BOOL) hasLoaded {
    return loaded_;
}

- (void) releaseSubviews {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restoreModernScrollTabBarWhenSettled) object:nil];
    if (modernScrollView_ != nil)
        [[modernScrollView_ panGestureRecognizer] removeTarget:self action:@selector(modernScrollPanChanged:)];
    modernScrollView_ = nil;
    modernTabBarHiddenForScroll_ = NO;
    loaded_ = NO;
}

- (void) setView:(UIView *)view {
    // Nasty hack for 2.x-compatibility. In 3.0+, we can and
    // should just override -viewDidUnload instead.
    if (view == nil)
        [self releaseSubviews];

    [super setView:view];
}

- (void) reloadData {
    [super reloadData];

    // This is called automatically on the first appearance of a controller,
    // or any other time it needs to reload the information shown. However (!),
    // this is not called by any tab bar or navigation controller's -reloadData
    // method unless this controller returns YES from -hadLoaded.
    loaded_ = YES;
}

- (void) unloadData {
    loaded_ = NO;
    [super unloadData];
}

- (void) setPageColor:(UIColor *)color {
    if (color == nil)
        color = [UIColor systemGroupedBackgroundColor];
    color_ = color;
}

- (UIColor *) pageColor {
    return color_;
}

#include "InterfaceOrientation.h"

@end
