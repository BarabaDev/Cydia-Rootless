#pragma once

#import <Foundation/Foundation.h>
#import "ModernLocalization.h"

// Keep presentation separate from APT's resolver. The resolver supplies the
// failed OR groups; metadata may name a known source, never infer an absent one.
static NSString *CYConfirmationString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *CYConfirmationPackageName(NSString *identifier, NSDictionary *info) {
    NSString *name(CYConfirmationString([info objectForKey:@"name"]));
    if ([name length] == 0 || [name isEqualToString:identifier])
        return identifier;
    return [NSString stringWithFormat:@"%@ (%@)", name, identifier];
}

static NSArray *CYConfirmationIssueSections(NSArray *issues, NSDictionary *(^packageInfo)(NSString *)) {
    NSMutableArray *items([NSMutableArray array]);
    for (NSDictionary *issue in issues) {
        NSString *parent(CYConfirmationString([issue objectForKey:@"package"]));
        NSDictionary *parentInfo([parent length] == 0 ? nil : packageInfo(parent));
        NSString *parentName(CYConfirmationString([parentInfo objectForKey:@"name"]));
        if ([parentName length] == 0)
            parentName = parent;
        NSArray *reasons([issue objectForKey:@"reasons"]);
        NSUInteger initialCount([items count]);
        for (NSDictionary *reason in reasons) {
            NSString *relationship(CYConfirmationString([reason objectForKey:@"relationship"]));
            BOOL requires([relationship isEqualToString:@"Depends"] || [relationship isEqualToString:@"PreDepends"]);
            BOOL conflict([relationship isEqualToString:@"Conflicts"] || [relationship isEqualToString:@"Breaks"]);
            NSString *relation(requires ? CYLocalize(@"Requires") : (conflict ? CYLocalize(@"Conflicts with") : relationship));
            if ([relation length] == 0)
                relation = CYLocalize(@"Package requirement");
            NSArray *clauses([reason objectForKey:@"clauses"]);
            NSMutableArray *options([NSMutableArray array]);
            NSMutableArray *requirements([NSMutableArray array]);
            NSString *singleRequirement(nil);
            for (NSDictionary *clause in clauses) {
                NSString *identifier(CYConfirmationString([clause objectForKey:@"package"]));
                if ([identifier length] == 0)
                    continue;
                NSDictionary *info(packageInfo(identifier));
                NSString *requirement(CYConfirmationPackageName(identifier, info));
                NSString *versionText(nil);
                id version([clause objectForKey:@"version"]);
                if ([version isKindOfClass:[NSDictionary class]]) {
                    NSString *value(CYConfirmationString([version objectForKey:@"value"]));
                    NSString *comparison(CYConfirmationString([version objectForKey:@"operator"]));
                    if ([value length] != 0) {
                        versionText = [NSString stringWithFormat:@"%@ %@", comparison ?: @"=", value];
                        requirement = [requirement stringByAppendingFormat:@" (%@ %@)", comparison ?: @"=", value];
                    }
                }
                singleRequirement = requirement;
                NSString *state(CYConfirmationString([clause objectForKey:@"reason"]));
                NSString *selected(CYConfirmationString([clause objectForKey:@"installed"]));
                NSString *source(CYConfirmationString([info objectForKey:@"source"]));
                BOOL systemPackage([identifier isEqualToString:@"firmware"] || [identifier hasPrefix:@"gsc."] || [identifier hasPrefix:@"cy+"]);
                NSString *explanation;
                if ([parent length] == 0)
                    explanation = CYLocalize(@"These changes would remove a package required by the system.");
                else if (conflict)
                    explanation = [selected length] == 0 ? CYLocalize(@"This package conflicts with the requested changes.") :
                        [NSString stringWithFormat:CYLocalize(@"Selected version %@ conflicts with the requested changes."), selected];
                else if ([state isEqualToString:@"removed"])
                    explanation = CYLocalize(@"This package is scheduled for removal, but is still required. Keep it installed or also remove the packages that require it.");
                else if ([state isEqualToString:@"installed"])
                    explanation = [selected length] == 0 ? CYLocalize(@"The selected version does not satisfy this requirement.") :
                        [NSString stringWithFormat:CYLocalize(@"Selected version %@ does not satisfy this requirement."), selected];
                else if (systemPackage)
                    explanation = CYLocalize(@"The required system version or capability is not available on this device.");
                else if ([state isEqualToString:@"uninstallable"])
                    explanation = [source length] == 0 ?
                        CYLocalize(@"Unavailable in your sources. Refresh Sources or add the repository that provides this package.") :
                        CYLocalize(@"No installable version found. Refresh this source or check for a compatible version.");
                else if ([state isEqualToString:@"uninstalled"])
                    explanation = CYLocalize(@"An available version could not be selected. Check its version requirements and other package issues.");
                else if ([state isEqualToString:@"missing"] || [state isEqualToString:@"virtual"])
                    explanation = CYLocalize(@"No compatible provider is selected for this dependency. Check your sources and the provider's requirements.");
                else
                    explanation = CYLocalize(@"This requirement could not be satisfied.");
                NSString *sourceLine([state isEqualToString:@"removed"] ? @"" : [source length] != 0 ? [NSString stringWithFormat:CYLocalize(@"Known source: %@"), source] :
                    (systemPackage || conflict || [parent length] == 0 ? @"" : CYLocalize(@"Source unknown")));
                [requirements addObject:@{
                    @"name": CYConfirmationString([info objectForKey:@"name"]) ?: identifier,
                    @"identifier": identifier,
                    @"version": versionText ?: @"",
                    @"source": sourceLine,
                    @"explanation": explanation
                }];
                if ([sourceLine length] != 0)
                    explanation = [explanation stringByAppendingFormat:@"\n%@", sourceLine];
                // Alternatives must remain one OR group, not independent
                // missing dependencies that appear to require every option.
                [options addObject:[clauses count] == 1 ? explanation :
                    [NSString stringWithFormat:@"%@\n%@", requirement, explanation]];
            }
            if ([options count] == 0)
                continue;
            NSString *title([clauses count] == 1 ?
                [NSString stringWithFormat:@"%@: %@", [parent length] == 0 ? CYLocalize(@"Cannot remove") : relation, singleRequirement] :
                [NSString stringWithFormat:CYLocalize(@"%@ one of:"), relation]);
            NSString *detail([options componentsJoinedByString:[NSString stringWithFormat:@"\n\n%@\n\n", [CYLocalize(@"OR") localizedLowercaseString]]]);
            if ([parentName length] != 0)
                detail = [NSString stringWithFormat:@"%@: %@\n%@", requires ? CYLocalize(@"Required by") : CYLocalize(@"Package"), parentName, detail];
            [items addObject:@{
                @"name": title, @"detail": detail,
                @"heading": [parent length] == 0 ? CYLocalize(@"Cannot remove system package") :
                    (requires ? ([requirements count] == 1 ? CYLocalize(@"Required dependency") : CYLocalize(@"Requires one of these packages")) : relation),
                @"context": [parentName length] == 0 ? @"" :
                    [NSString stringWithFormat:@"%@: %@", requires ? CYLocalize(@"Required by") : CYLocalize(@"Package"), parentName],
                @"requirements": requirements
            }];
        }
        if ([items count] == initialCount) {
            // APT can report a broken package without a usable install version.
            // Never reduce that case to a count with no visible explanation.
            [items addObject:@{
                @"name": parentName ?: CYLocalize(@"Package issue"),
                @"detail": CYLocalize(@"The requested changes cannot be resolved. Refresh Sources and check that compatible versions of this package and its dependencies are available.")
            }];
        }
    }
    if ([items count] == 0)
        return @[];
    return @[@{@"title": CYLocalize(@"PACKAGE ISSUES"), @"items": items, @"issue": @YES}];
}
