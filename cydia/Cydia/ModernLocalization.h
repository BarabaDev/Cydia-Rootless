#ifndef Cydia_ModernLocalization_H
#define Cydia_ModernLocalization_H
#import <Foundation/Foundation.h>

// Translate display copy only. State tokens, repository fields, package names,
// and diagnostic messages retain their original values.
static inline NSString *CYLocalize(NSString *source) {
    if ([source length] == 0) return source;
    return [[NSBundle mainBundle] localizedStringForKey:[@"Modern." stringByAppendingString:source]
        value:source table:nil];
}

// Percent symbols, digits, and spacing follow the user's locale.
static inline NSString *CYLocalizedPercent(double value) {
    NSNumberFormatter *formatter([[[NSNumberFormatter alloc] init] autorelease]);
    [formatter setNumberStyle:NSNumberFormatterPercentStyle];
    [formatter setMaximumFractionDigits:0];
    [formatter setLocale:[NSLocale currentLocale]];
    return [formatter stringFromNumber:@(value)];
}

// A label and formatted count avoid constructing English plurals with "s".
static inline NSString *CYLocalizedMetric(NSString *label, NSUInteger count) {
    NSNumberFormatter *formatter([[[NSNumberFormatter alloc] init] autorelease]);
    [formatter setNumberStyle:NSNumberFormatterDecimalStyle];
    [formatter setLocale:[NSLocale currentLocale]];
    return [NSString stringWithFormat:CYLocalize(@"%@ · %@"), label,
        [formatter stringFromNumber:@(count)]];
}
#endif
