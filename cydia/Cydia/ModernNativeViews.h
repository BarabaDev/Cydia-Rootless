/* Cydia 1.1.24 Rootless - complete native iOS 15+ transaction UI */

#ifndef Cydia_ModernNativeViews_H
#define Cydia_ModernNativeViews_H

#import <UIKit/UIKit.h>

BOOL CydiaPrivacyConsentIsAccepted(void);

@interface CydiaModernAboutViewController : UIViewController <UITextViewDelegate> {
    UIVisualEffectView *legalNotice_;
    UITextView *legalText_;
    UIButton *closeButton_;
    NSString *legalCopy_;
}
@end

@interface CydiaModernPrivacyConsentView : UIView {
    UIStackView *privacyDetails_;
    UILabel *persistenceError_;
    UIButton *privacyButton_;
    id actionTarget_;
    SEL acceptAction_;
    SEL declineAction_;
    BOOL detailsExpanded_;
}

- (void) configureWithTarget:(id)target acceptAction:(SEL)acceptAction declineAction:(SEL)declineAction;
- (void) showPersistenceError:(NSString *)message;

@end

@interface CydiaModernHomeView : UIView <UIScrollViewDelegate>

- (void) setActionTarget:(id)target action:(SEL)action;
- (void) setQuickActionSourceCount:(NSUInteger)sources
                       updateCount:(NSUInteger)updates
                    installedCount:(NSUInteger)installed
                    availableCount:(NSUInteger)available;
- (void) setFeaturedPackages:(NSArray *)packages;
- (void) loadFeaturedArtwork;
- (void) continueFeaturedPositionFromView:(CydiaModernHomeView *)home;
- (void) setFullScreenControlsVisible:(BOOL)visible animated:(BOOL)animated target:(id)target action:(SEL)action;

@end

@interface CydiaModernEssentialView : UIView

- (void) configureWithTitle:(NSString *)title
                    message:(NSString *)message
             essentialTitle:(NSString *)essentialTitle
              completeTitle:(NSString *)completeTitle
                ignoreTitle:(NSString *)ignoreTitle
                     target:(id)target
                     action:(SEL)action;

@end

typedef NS_ENUM(NSUInteger, CydiaRestartKind) {
    CydiaRestartSpringBoard,
    CydiaRestartUserspace,
    CydiaRestartDevice
};

@interface CydiaModernProgressView : UIView

- (void) setTransactionTitle:(NSString *)title;
- (void) setStatusText:(NSString *)status;
- (void) setProgressValue:(float)value animated:(BOOL)animated;
- (void) beginInstalling;
- (void) setTransferCurrent:(double)current total:(double)total speed:(double)speed;
- (void) setDownloadProgressValue:(float)value current:(double)current total:(double)total speed:(double)speed;
- (void) appendLogMessage:(NSString *)message type:(NSString *)type;
- (void) setRunning:(BOOL)running;
- (void) setErrorState:(BOOL)error;
- (void) setCancelledState:(BOOL)cancelled;
- (void) setFinishTitle:(NSString *)title target:(id)target action:(SEL)action;
- (void) setRestartRequired:(BOOL)required;
- (void) setRestarting:(BOOL)restarting title:(NSString *)title;
- (void) setRestartingKind:(CydiaRestartKind)kind;

@end

@interface CydiaModernConfirmationView : UIView <UITableViewDataSource, UITableViewDelegate>
- (void) setOperationSymbol:(NSString *)symbol;

- (void) setSummaryTitle:(NSString *)title detail:(NSString *)detail download:(NSString *)download;
- (void) setSections:(NSArray *)sections;
- (void) setWarningText:(NSString *)warning;
- (void) setConfirmTitle:(NSString *)title destructive:(BOOL)destructive enabled:(BOOL)enabled target:(id)target action:(SEL)action;

@end

@interface CydiaModernPackageDetailView : UIView

- (void) setLoading:(BOOL)loading;
- (void) setUnavailableIdentifier:(NSString *)identifier;
- (void) configureWithIcon:(UIImage *)icon
                      name:(NSString *)name
                identifier:(NSString *)identifier
                   summary:(NSString *)summary
          availableVersion:(NSString *)availableVersion
          installedVersion:(NSString *)installedVersion
                repository:(NSString *)repository
                   section:(NSString *)section
                      size:(NSString *)size
                    author:(NSString *)author;
- (void) setActionTitle:(NSString *)title destructive:(BOOL)destructive target:(id)target action:(SEL)action;
- (void) setNavigationTarget:(id)target settingsAction:(SEL)settingsAction filesAction:(SEL)filesAction showFiles:(BOOL)showFiles;
- (void) updateHeroIcon:(UIImage *)icon;
- (UIView *) actionSourceView;

@end

#endif//Cydia_ModernNativeViews_H
