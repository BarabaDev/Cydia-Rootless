#import <Foundation/Foundation.h>

// A presentation of the package manifest. It never enumerates directories,
// follows links, reads file contents, or changes files on the device.
@interface CYInstalledFileTree : NSObject
@property(nonatomic, readonly) NSDictionary *nodes;
@property(nonatomic, readonly) NSArray *roots;
@property(nonatomic, readonly) NSUInteger itemCount;
- (instancetype)initWithPaths:(NSArray *)paths directories:(NSSet *)directories;
- (NSArray *)visibleRowsWithExpandedPaths:(NSSet *)expanded;
@end
