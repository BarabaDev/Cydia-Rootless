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

#include "CyteKit/TabBarController.h"
#include "CyteKit/ModernAppearance.h"

#include "iPhonePrivate.h"
#include <Menes/ObjectHandle.h>

#import <QuartzCore/QuartzCore.h>

@implementation CyteTabBarController {
    _transient UIViewController *transient_;
    _H<UIViewController> remembered_;
    BOOL scrollTabBarHidden_;
}

- (BOOL) isScrollTabBarHidden {
    return scrollTabBarHidden_;
}

- (void) setSelectedIndex:(NSUInteger)selectedIndex {
    [self setScrollTabBarHidden:NO animated:NO];
    [super setSelectedIndex:selectedIndex];
}

- (void) setSelectedViewController:(UIViewController *)selectedViewController {
    [self setScrollTabBarHidden:NO animated:NO];
    [super setSelectedViewController:selectedViewController];
}

- (void) setScrollTabBarHidden:(BOOL)hidden animated:(BOOL)animated {
    UITabBar *bar([self tabBar]);
    if (bar == nil)
        return;

    scrollTabBarHidden_ = hidden;

    // UITabBarController owns the tab bar frame, safe-area geometry and touch
    // routing. Never translate either the view or its layer: an interrupted
    // layer animation can look restored while leaving hit testing disabled or
    // the presentation layer displaced. Fade the canonical bar in place and
    // force every call to repair its complete interactive state.
    [[bar layer] removeAllAnimations];
    [bar setTransform:CGAffineTransformIdentity];
    [[bar layer] setTransform:CATransform3DIdentity];
    [bar setHidden:NO];
    [bar setUserInteractionEnabled:!hidden];
    [bar setAccessibilityElementsHidden:hidden];

    if (!animated) {
        [bar setAlpha:hidden ? 0.0f : 1.0f];
        return;
    }

    if (hidden) {
        // Fade out smoothly in one stage.
        [UIView animateWithDuration:0.16 delay:0.0
            options:(UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionBeginFromCurrentState)
            animations:^{ [bar setAlpha:0.0f]; } completion:NULL];
        return;
    }

    // Show: ease the bar back in over two stages — first to a dim version,
    // then up to full — so it appears gradually instead of snapping on all at
    // once. A cubic keyframe curve keeps the dim -> full hand-off seamless.
    [UIView animateKeyframesWithDuration:0.42 delay:0.0
        options:(UIViewKeyframeAnimationOptionCalculationModeCubic | UIViewAnimationOptionBeginFromCurrentState)
        animations:^{
            [UIView addKeyframeWithRelativeStartTime:0.0 relativeDuration:0.45 animations:^{
                [bar setAlpha:0.35f];
            }];
            [UIView addKeyframeWithRelativeStartTime:0.45 relativeDuration:0.55 animations:^{
                [bar setAlpha:1.0f];
            }];
        } completion:NULL];
}

- (NSArray *) navigationURLCollection {
    NSMutableArray *items([NSMutableArray array]);

    // XXX: Should this deal with transient view controllers?
    for (id navigation in [self viewControllers]) {
        NSArray *stack = [navigation performSelector:@selector(navigationURLCollection)];
        if (stack != nil)
            [items addObject:stack];
    }

    return items;
}

- (void) addViewControllers:(id)no, ... {
    va_list args;
    va_start(args, no);

    NSMutableArray *controllers([NSMutableArray array]);

    for (;;) {
        auto title(va_arg(args, NSString *));
        if (title == nil)
            break;

        UINavigationController *controller([[[UINavigationController alloc] init] autorelease]);
        [controllers addObject:controller];

        auto identifier(va_arg(args, NSString *));
        UIImage *modern(CYModernTabImage(identifier, NO));
        UIImage *modernSelected(CYModernTabImage(identifier, YES));
        if (modern == nil)
            modern = [UIImage cy_symbolNamed:@"circle"];

        [controller setTabBarItem:[[[UITabBarItem alloc]
            initWithTitle:title
            image:modern
            selectedImage:(modernSelected ?: modern)
        ] autorelease]];

        CYModernizeNavigationController(controller);
    }

    va_end(args);

    [self setViewControllers:controllers];
}

- (void) didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];

    // presenting a UINavigationController on 2.x does not update its transitionView
    // it thereby will not allow its topViewController to be unloaded by memory pressure
    if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iPhoneOS_3_0) {
        UIViewController *selected([self selectedViewController]);
        for (UINavigationController *controller in [self viewControllers])
            if (controller != selected)
                if (UIViewController *top = [controller topViewController])
                    [top unloadView];
    }
}

- (void) tabBarController:(UITabBarController *)tabBarController didSelectViewController:(UIViewController *)viewController {
    [self setScrollTabBarHidden:NO animated:NO];

    if ([self unselectedViewController])
        [self setUnselectedViewController:nil];

    // presenting a UINavigationController on 2.x does not update its transitionView
    // if this view was unloaded, the tranitionView may currently be presenting nothing
    if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iPhoneOS_3_0) {
        UINavigationController *navigation((UINavigationController *) viewController);
        [navigation pushViewController:[[[UIViewController alloc] init] autorelease] animated:NO];
        [navigation popViewControllerAnimated:NO];
    }
}

- (void) viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [self setScrollTabBarHidden:NO animated:NO];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

- (void) dismissModalViewControllerAnimated:(BOOL)animated {
    if ([self modalViewController] == nil && [self unselectedViewController] != nil)
        [self setUnselectedViewController:nil];
    else
        [super dismissModalViewControllerAnimated:YES];
}

- (void) setUnselectedViewController:(UIViewController *)transient {
    if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iPhoneOS_3_0) {
        if (transient != nil) {
            [[[self viewControllers] objectAtIndex:0] pushViewController:transient animated:YES];
            [self setSelectedIndex:0];
        } return;
    }

    NSMutableArray *controllers = [[[self viewControllers] mutableCopy] autorelease];
    if (transient != nil) {
        UINavigationController *navigation([[[UINavigationController alloc] init] autorelease]);
        [navigation setViewControllers:[NSArray arrayWithObject:transient]];
        transient = navigation;

        if (transient_ == nil)
            remembered_ = [controllers objectAtIndex:0];
        transient_ = transient;
        [transient_ setTabBarItem:[remembered_ tabBarItem]];
        [controllers replaceObjectAtIndex:0 withObject:transient_];
        [self setSelectedIndex:0];
        [self setViewControllers:controllers];
        [self concealTabBarSelection];
    } else if (remembered_ != nil) {
        [remembered_ setTabBarItem:[transient_ tabBarItem]];
        transient_ = transient;
        [controllers replaceObjectAtIndex:0 withObject:remembered_];
        remembered_ = nil;
        [self setViewControllers:controllers];
        [self revealTabBarSelection];
    }
}

- (UIViewController *) unselectedViewController {
    return transient_;
}

- (void) unloadData {
    [super unloadData];

    for (UINavigationController *controller in [self viewControllers])
        [controller unloadData];

    if (UIViewController *selected = [self selectedViewController])
        [selected reloadData];

    if (UIViewController *unselected = [self unselectedViewController]) {
        [unselected unloadData];
        [unselected reloadData];
    }
}

#include "InterfaceOrientation.h"

@end
