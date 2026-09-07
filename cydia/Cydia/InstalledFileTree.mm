#import "InstalledFileTree.h"

@implementation CYInstalledFileTree
@synthesize nodes = nodes_, roots = roots_, itemCount = itemCount_;

- (instancetype)initWithPaths:(NSArray *)paths directories:(NSSet *)directories {
    if ((self = [super init])) {
        NSMutableDictionary *nodes = [NSMutableDictionary dictionary];
        NSMutableSet *listed = [NSMutableSet set];
        for (id input in paths) {
            if (![input isKindOfClass:NSString.class] || ![input hasPrefix:@"/"]) continue;
            NSArray *parts = [input componentsSeparatedByString:@"/"];
            // Reject traversal, but accept dpkg's conventional leading /./.
            if ([parts containsObject:@".."]) continue;
            NSString *path = @"";
            for (NSString *part in parts) {
                if (part.length == 0 || [part isEqualToString:@"."]) continue;
                NSString *parent = path;
                path = [path stringByAppendingFormat:@"/%@", part];
                if (!nodes[path]) {
                    nodes[path] = [NSMutableDictionary dictionaryWithDictionary:@{
                        @"path":path, @"name":part, @"parent":parent,
                        @"children":[NSMutableArray array], @"directory":@NO
                    }];
                    if (parent.length) [nodes[parent][@"children"] addObject:path];
                }
                if (parent.length) nodes[parent][@"directory"] = @YES;
            }
            if (!path.length) continue;
            [listed addObject:path];
            if ([directories containsObject:input] || [directories containsObject:path] || [input hasSuffix:@"/"])
                nodes[path][@"directory"] = @YES;
        }
        NSComparator order = ^NSComparisonResult(NSString *a, NSString *b) {
            BOOL aFolder = [nodes[a][@"directory"] boolValue], bFolder = [nodes[b][@"directory"] boolValue];
            if (aFolder != bFolder) return aFolder ? NSOrderedAscending : NSOrderedDescending;
            NSComparisonResult result = [nodes[a][@"name"] localizedStandardCompare:nodes[b][@"name"]];
            return result == NSOrderedSame ? [a compare:b] : result;
        };
        NSMutableArray *roots = [NSMutableArray array];
        for (NSString *path in nodes) {
            [nodes[path][@"children"] sortUsingComparator:order];
            if (![nodes[path][@"parent"] length]) [roots addObject:path];
        }
        [roots sortUsingComparator:order];
        // Show the useful common folder, retaining its complete path as context.
        // This removes rows used only to spell out /var/jb/Applications/….
        while (roots.count == 1) {
            NSArray *children = nodes[roots[0]][@"children"];
            if (children.count != 1 || ![nodes[children[0]][@"directory"] boolValue]) break;
            [roots setArray:children];
        }
        nodes_ = [nodes copy];
        roots_ = [roots copy];
        itemCount_ = listed.count;
    }
    return self;
}

- (NSArray *)visibleRowsWithExpandedPaths:(NSSet *)expanded {
    NSMutableArray *rows = [NSMutableArray array], *pending = [NSMutableArray array];
    for (NSString *path in [roots_ reverseObjectEnumerator])
        [pending addObject:@{@"path":path, @"depth":@0}];
    while (pending.count) {
        NSDictionary *position = [[[pending lastObject] retain] autorelease];
        [pending removeLastObject];
        NSDictionary *node = nodes_[position[@"path"]];
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:node];
        row[@"depth"] = position[@"depth"];
        [rows addObject:row];
        if ([expanded containsObject:position[@"path"]]) {
            for (NSString *child in [node[@"children"] reverseObjectEnumerator])
                [pending addObject:@{@"path":child, @"depth":@([position[@"depth"] unsignedIntegerValue] + 1)}];
        }
    }
    return rows;
}

- (void)dealloc {
    [nodes_ release]; [roots_ release]; [super dealloc];
}
@end
