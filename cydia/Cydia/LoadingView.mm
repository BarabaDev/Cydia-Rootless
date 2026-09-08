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
#include "CyteKit/Localize.h"
#include "CyteKit/ModernAppearance.h"

#include "Cydia/LoadingView.h"

@implementation CydiaLoadingView

- (void) layoutSubviews {
    [super layoutSubviews];

    CGSize viewsize([self bounds].size);
    CGSize spinnersize([spinner_ bounds].size);
    CGFloat maximumTextWidth(MAX(120.0f, viewsize.width - 64.0f));
    CGSize textsize([label_ sizeThatFits:CGSizeMake(maximumTextWidth, CGFLOAT_MAX)]);
    CGFloat spacing(12.0f);
    CGFloat contentWidth(MAX(spinnersize.width, textsize.width));
    CGFloat contentHeight(spinnersize.height + spacing + textsize.height);

    CGRect containrect = {
        CGPointMake(
            floorf((viewsize.width - contentWidth) / 2.0f),
            floorf((viewsize.height - contentHeight) / 2.0f)
        ),
        CGSizeMake(contentWidth, contentHeight)
    };

    CGRect spinrect = {
        CGPointMake(floorf((contentWidth - spinnersize.width) / 2.0f), 0.0f),
        spinnersize
    };

    CGRect textrect = {
        CGPointMake(floorf((contentWidth - textsize.width) / 2.0f), spinnersize.height + spacing),
        CGSizeMake(textsize.width, textsize.height)
    };

    [container_ setFrame:containrect];
    [spinner_ setFrame:spinrect];
    [label_ setFrame:textrect];
}

- (id) initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame]) != nil) {
        container_ = [[[UIView alloc] init] autorelease];
        [container_ setAutoresizingMask:UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin];
        [container_ setBackgroundColor:[UIColor clearColor]];

        spinner_ = [[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge] autorelease];
        [spinner_ setColor:CYModernAccentColor()];
        [spinner_ setHidesWhenStopped:YES];
        [spinner_ startAnimating];
        [container_ addSubview:spinner_];

        label_ = [[[UILabel alloc] init] autorelease];
        [label_ setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
        [label_ setAdjustsFontForContentSizeCategory:YES];
        [label_ setBackgroundColor:[UIColor clearColor]];
        [label_ setTextColor:CYModernSecondaryLabelColor()];
        [label_ setTextAlignment:NSTextAlignmentCenter];
        [label_ setNumberOfLines:0];
        [label_ setText:[NSString stringWithFormat:Elision_, UCLocalize("LOADING"), nil]];
        [container_ addSubview:label_];
        [self addSubview:container_];
        [self setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
        [self setAccessibilityViewIsModal:YES];
        [self setAccessibilityLabel:UCLocalize("LOADING")];
        [self setNeedsLayout];
    } return self;
}

- (void) setText:(NSString *)text {
    NSString *value(text != nil ? text : UCLocalize("LOADING"));
    [label_ setText:value];
    [self setAccessibilityLabel:value];
    [self setNeedsLayout];
}

- (void) showInView:(UIView *)view {
    if (view == nil)
        return;
    [self setFrame:[view bounds]];
    [self setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [self setBackgroundColor:[[UIColor systemGroupedBackgroundColor] colorWithAlphaComponent:0.88f]];
    [self setHidden:NO];
    [spinner_ startAnimating];
    [view addSubview:self];
    [view bringSubviewToFront:self];
    [self setNeedsLayout];
}

- (void) hide {
    [spinner_ stopAnimating];
    [self setHidden:YES];
}

@end
