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

#include "Cydia/LoadingViewController.h"
#include "Cydia/ModernNativeViews.h"
#include "CyteKit/ModernAppearance.h"

@implementation CydiaLoadingViewController

- (id) initWithFeaturedPackages:(NSArray *)packages {
    if ((self = [super init]) != nil)
        featuredPackages_ = [packages copy];
    return self;
}

- (void) loadView {
    CydiaModernHomeView *home([[[CydiaModernHomeView alloc]
        initWithFrame:[[UIScreen mainScreen] applicationFrame]] autorelease]);
    [home setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [home setFeaturedPackages:featuredPackages_];
    NSDictionary *metrics([[NSUserDefaults standardUserDefaults] dictionaryForKey:@"CydiaHomeQuickMetricsV1"]);
    NSNumber *sources([metrics objectForKey:@"sources"]);
    NSNumber *updates([metrics objectForKey:@"updates"]);
    NSNumber *installed([metrics objectForKey:@"installed"]);
    NSNumber *available([metrics objectForKey:@"available"]);
    if ([sources isKindOfClass:[NSNumber class]] && [updates isKindOfClass:[NSNumber class]] &&
        [installed isKindOfClass:[NSNumber class]] && [available isKindOfClass:[NSNumber class]])
        [home setQuickActionSourceCount:[sources unsignedIntegerValue]
            updateCount:[updates unsignedIntegerValue]
            installedCount:[installed unsignedIntegerValue]
            availableCount:[available unsignedIntegerValue]];
    [self setView:home];

    [[self navigationItem] setTitle:@"Home"];
    [[self navigationItem] setLargeTitleDisplayMode:UINavigationItemLargeTitleDisplayModeNever];
    [[self navigationItem] setLeftBarButtonItem:[[[UIBarButtonItem alloc]
        initWithImage:[UIImage cy_symbolNamed:@"info.circle"]
        style:UIBarButtonItemStylePlain target:nil action:nil] autorelease]];
    // This is the cached first frame shown while APT finishes opening.  Keep
    // its navigation chrome identical to the live Home controller so the
    // full-screen control never appears late when the live controller swaps
    // in.  The launch window is intentionally non-interactive until that swap.
    CydiaNavigationButton *reload([[[CydiaNavigationButton alloc] initWithSymbol:@"arrow.clockwise"
        label:@"Reload Home" target:nil action:NULL] autorelease]);
    UIBarButtonItem *reloadItem([[[UIBarButtonItem alloc] initWithCustomView:reload] autorelease]);
    CydiaNavigationButton *fullScreen([[[CydiaNavigationButton alloc]
        initWithSymbol:@"arrow.up.left.and.arrow.down.right" label:@"Full Screen" target:nil action:NULL] autorelease]);
    UIBarButtonItem *fullScreenItem([[[UIBarButtonItem alloc] initWithCustomView:fullScreen] autorelease]);
    [[self navigationItem] setRightBarButtonItems:
        [NSArray arrayWithObjects:reloadItem, fullScreenItem, nil]];
}

- (void) dealloc {
    [featuredPackages_ release];
    [super dealloc];
}

@end
