#import <UIKit/UIKit.h>

@interface CydiaInstalledFilesView : UIView
- (void)setFilePaths:(NSArray *)paths directories:(NSSet *)directories packageName:(NSString *)name;
@end
