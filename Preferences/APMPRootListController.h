#import <Preferences/Preferences.h>

@interface APMPRootListController : PSListController
@property (nonatomic, retain) NSMutableArray *appList;
@property (nonatomic, retain) NSMutableArray *blacklist;
@property (nonatomic, assign) BOOL tweakEnabled;
@end
