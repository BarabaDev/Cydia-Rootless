#pragma once

#import <Foundation/Foundation.h>

enum CYTransactionPhase { CYTransactionPreparing, CYTransactionDownloading, CYTransactionInstalling };

// APT transfer callbacks and dpkg percentages describe separate phases.
// Ignore late transfer callbacks once installation has started.
struct CYTransactionProgressState {
    CYTransactionPhase phase;
    CYTransactionProgressState() : phase(CYTransactionPreparing) {}
    bool advance(CYTransactionPhase next) {
        if (next <= phase)
            return false;
        phase = next;
        return true;
    }
    void reset() { phase = CYTransactionPreparing; }
};

static inline NSString *CYTransactionVersionDetail(NSString *installed, NSString *selected, NSString *action) {
    if ([installed length] != 0 && [selected length] != 0 && ![installed isEqualToString:selected])
        return [NSString stringWithFormat:@"%@ → %@", installed, selected];
    NSString *version([selected length] == 0 ? installed : selected);
    return [action length] == 0 ? (version ?: @"") :
        ([version length] == 0 ? action : [NSString stringWithFormat:@"%@ · %@", action, version]);
}

static inline NSUInteger CYTransactionPackageCount(NSDictionary *changes) {
    NSUInteger count(0);
    for (NSString *key in @[@"installs", @"reinstalls", @"upgrades", @"dependencies", @"downgrades", @"removes"])
        count += [[changes objectForKey:key] count];
    return count;
}

static inline BOOL CYTransactionCanConfirm(NSDictionary *changes, NSArray *issues, BOOL started) {
    return !started && [issues count] == 0 && CYTransactionPackageCount(changes) != 0;
}
