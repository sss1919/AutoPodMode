#import "APMPRootListController.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@class PSSwitchCell;
@class PSButtonCell;
@class PSTitleValueCell;

@interface PSSpecifier (Private)
+ (id)groupSpecifier;
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(Class)cell edit:(SEL)edit;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setName:(NSString *)name;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
@end

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
- (id)iconDataForVariant:(int)variant;
@end

@implementation APMPRootListController

- (NSArray *)defaultBlacklist {
    return @[
        @"com.ss.iphone.ugc.Aweme",
        @"com.ss.iphone.ugc.Aweme.lite",
        @"com.smile.gifmaker"
    ];
}

- (NSString *)configPath {
    return @"/var/mobile/Library/Preferences/com.sss1919.autopodmode.config.plist";
}

- (void)loadConfig {
    NSString *path = [self configPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    self.tweakEnabled = YES;
    self.blacklist = [[self defaultBlacklist] mutableCopy];

    if ([fm fileExistsAtPath:path]) {
        NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:path];
        if (config) {
            NSNumber *en = config[@"enabled"];
            if (en) self.tweakEnabled = [en boolValue];
            NSArray *list = config[@"blacklist"];
            if ([list isKindOfClass:[NSArray class]]) {
                NSMutableArray *valid = [NSMutableArray array];
                for (id item in list) {
                    if ([item isKindOfClass:[NSString class]]) [valid addObject:item];
                }
                self.blacklist = valid;
            }
        }
    } else {
        [self saveConfig];
    }
}

- (void)saveConfig {
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    config[@"enabled"] = @(self.tweakEnabled);
    config[@"blacklist"] = [self.blacklist copy];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:config
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (data) {
        NSString *path = [self configPath];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        [data writeToFile:path atomically:YES];
    }
}

- (void)loadApplications {
    self.appList = [NSMutableArray array];
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!workspaceClass) return;

        id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
        NSArray *apps = [workspace performSelector:@selector(allApplications)];
        if (![apps isKindOfClass:[NSArray class]]) return;

        for (id proxy in apps) {
            @try {
                NSString *bid = [proxy performSelector:@selector(applicationIdentifier)];
                NSString *name = [proxy performSelector:@selector(localizedName)];
                if (bid.length == 0) continue;
                if (name.length == 0) name = bid;

                NSMutableDictionary *info = [NSMutableDictionary dictionary];
                info[@"bundleID"] = bid;
                info[@"name"] = name;

                NSData *iconData = [proxy performSelector:@selector(iconDataForVariant:) withObject:@2];
                if (iconData.length > 0) {
                    info[@"icon"] = [UIImage imageWithData:iconData];
                }

                [self.appList addObject:info];
            } @catch (NSException *e) {}
        }

        [self.appList sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
    } @catch (NSException *e) {
        NSLog(@"[AutoPodModePrefs] loadApplications error: %@", e);
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadConfig];
    [self loadApplications];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadConfig];
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    NSMutableArray *specs = [NSMutableArray array];

    // Section: Enable toggle
    PSSpecifier *group1 = [PSSpecifier groupSpecifier];
    [group1 setProperty:@"AirPods Pro/Max 自动切换聆听模式" forKey:@"headerText"];
    [specs addObject:group1];

    PSSpecifier *enableSpec = [PSSpecifier preferenceSpecifierNamed:@"启用插件"
                                                             target:self
                                                                set:@selector(setEnabled:specifier:)
                                                                get:@selector(enabled)
                                                             detail:Nil
                                                               cell:[PSSwitchCell class]
                                                               edit:Nil];
    [enableSpec setProperty:@"媒体播放时自动降噪，暂停时自动通透" forKey:@"footerText"];
    [specs addObject:enableSpec];

    // Section: Blacklist info + reset
    PSSpecifier *group2 = [PSSpecifier groupSpecifier];
    [group2 setProperty:@"黑名单中的 App 不会触发自动切换。默认包含：抖音、抖音极速版、快手。" forKey:@"footerText"];
    [specs addObject:group2];

    PSSpecifier *resetSpec = [PSSpecifier preferenceSpecifierNamed:@"重置黑名单默认值"
                                                             target:self
                                                                set:Nil
                                                                get:Nil
                                                             detail:Nil
                                                               cell:[PSButtonCell class]
                                                               edit:Nil];
    [resetSpec setProperty:NSStringFromSelector(@selector(resetBlacklist)) forKey:@"action"];
    [resetSpec setProperty:[UIColor systemRedColor] forKey:@"cellTintColor"];
    [specs addObject:resetSpec];

    // Section: App list
    PSSpecifier *group3 = [PSSpecifier groupSpecifier];
    [group3 setProperty:[NSString stringWithFormat:@"已安装应用（%lu个）。勾选加入黑名单", (unsigned long)self.appList.count] forKey:@"headerText"];
    [specs addObject:group3];

    for (NSDictionary *app in self.appList) {
        NSString *bid = app[@"bundleID"];
        NSString *name = app[@"name"];

        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
                                                          target:self
                                                             set:@selector(setApp:specifier:)
                                                             get:@selector(appBlacklisted:)
                                                          detail:Nil
                                                            cell:[PSTitleValueCell class]
                                                            edit:Nil];
        [spec setProperty:bid forKey:@"bundleID"];
        [spec setProperty:bid forKey:@"key"];

        UIImage *icon = app[@"icon"];
        if (icon) [spec setProperty:icon forKey:@"iconImage"];

        [specs addObject:spec];
    }

    _specifiers = [specs copy];
    return _specifiers;
}

#pragma mark - Switch toggle

- (id)enabled {
    return @(self.tweakEnabled);
}

- (void)setEnabled:(id)value specifier:(PSSpecifier *)spec {
    self.tweakEnabled = [value boolValue];
    [self saveConfig];
}

#pragma mark - App checkbox

- (id)appBlacklisted:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"];
    return @([self.blacklist containsObject:bid]);
}

- (void)setApp:(id)value specifier:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"];
    BOOL blacklisted = [value boolValue];

    if (blacklisted) {
        if (![self.blacklist containsObject:bid]) [self.blacklist addObject:bid];
    } else {
        [self.blacklist removeObject:bid];
    }
    [self saveConfig];
    [self.tableView reloadData];
}

#pragma mark - Reset

- (void)resetBlacklist {
    self.blacklist = [[self defaultBlacklist] mutableCopy];
    [self saveConfig];
    _specifiers = nil;
    [self reloadSpecifiers];
}

#pragma mark - Table view

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *bid = [spec propertyForKey:@"bundleID"];

    if (bid) {
        BOOL checked = [self.blacklist containsObject:bid];
        cell.accessoryType = checked ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        if (cell.detailTextLabel) {
            cell.detailTextLabel.text = bid;
            cell.detailTextLabel.textColor = [UIColor systemGrayColor];
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *bid = [spec propertyForKey:@"bundleID"];

    if (bid) {
        BOOL isIn = [self.blacklist containsObject:bid];
        [self setApp:@(!isIn) specifier:spec];
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

@end
