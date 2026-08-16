#import "APMPRootListController.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kAutoPodModeConfigFileName = @"com.sss1919.autopodmode.config.plist";

// LSApplicationWorkspace / LSApplicationProxy private interface
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
- (NSArray *)installedApplications;
@end

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *shortVersionString;
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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sharedPrefDir = @"/var/mobile/Library/Preferences/";
    if ([fm fileExistsAtPath:sharedPrefDir]) {
        return [sharedPrefDir stringByAppendingPathComponent:kAutoPodModeConfigFileName];
    }
    // fallback
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject;
    return [docDir stringByAppendingPathComponent:kAutoPodModeConfigFileName];
}

- (void)loadConfig {
    NSString *path = [self configPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    self.tweakEnabled = YES;
    self.blacklist = [[self defaultBlacklist] mutableCopy];
    
    if (![fm fileExistsAtPath:path]) {
        [self saveConfig];
        return;
    }
    
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:path];
    if (config) {
        NSNumber *en = config[@"enabled"];
        if (en) self.tweakEnabled = [en boolValue];
        NSArray *list = config[@"blacklist"];
        if (list && [list isKindOfClass:[NSArray class]]) {
            NSMutableArray *valid = [NSMutableArray array];
            for (id item in list) {
                if ([item isKindOfClass:[NSString class]]) {
                    [valid addObject:item];
                }
            }
            self.blacklist = valid;
        }
    }
}

- (void)saveConfig {
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    config[@"enabled"] = @(self.tweakEnabled);
    config[@"blacklist"] = [self.blacklist copy];
    NSString *path = [self configPath];
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:config
                                                               format:NSPropertyListXMLFormat_v1_0
                                                              options:0
                                                                error:&error];
    if (data) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        // 设置文件权限确保mediaremoted可读
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        [attrs setObject:[NSNumber numberWithUnsignedLong:0644] forKey:NSFilePosixPermissions];
        if (![fm fileExistsAtPath:path]) {
            [fm createFileAtPath:path contents:data attributes:attrs];
        } else {
            [data writeToFile:path atomically:YES];
            [fm setAttributes:attrs ofItemAtPath:path error:nil];
        }
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadConfig];
    [self loadApplicationList];
}

- (void)loadApplicationList {
    self.appList = [NSMutableArray array];
    
    @try {
        Class LSApplicationWorkspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!LSApplicationWorkspaceClass) {
            return;
        }
        
        LSApplicationWorkspace *workspace = [LSApplicationWorkspaceClass performSelector:@selector(defaultWorkspace)];
        if (!workspace) return;
        
        NSArray *apps = nil;
        if ([workspace respondsToSelector:@selector(allApplications)]) {
            apps = [workspace performSelector:@selector(allApplications)];
        } else if ([workspace respondsToSelector:@selector(installedApplications)]) {
            apps = [workspace performSelector:@selector(installedApplications)];
        }
        
        if (!apps) return;
        
        for (id proxy in apps) {
            @try {
                NSString *bid = nil;
                NSString *name = nil;
                
                if ([proxy respondsToSelector:@selector(applicationIdentifier)]) {
                    bid = [proxy performSelector:@selector(applicationIdentifier)];
                }
                if ([proxy respondsToSelector:@selector(localizedName)]) {
                    name = [proxy performSelector:@selector(localizedName)];
                }
                
                if (!bid || bid.length == 0) continue;
                
                // 过滤掉系统App（可选，但保留用户App为主）
                if (!name || name.length == 0) {
                    name = bid;
                }
                
                NSMutableDictionary *appInfo = [NSMutableDictionary dictionary];
                appInfo[@"bundleID"] = bid;
                appInfo[@"name"] = name;
                
                // 获取应用版本（可选显示）
                if ([proxy respondsToSelector:@selector(shortVersionString)]) {
                    NSString *ver = [proxy performSelector:@selector(shortVersionString)];
                    if (ver) appInfo[@"version"] = ver;
                }
                
                // 获取App图标
                if ([proxy respondsToSelector:@selector(iconDataForVariant:)]) {
                    @try {
                        NSData *iconData = [proxy performSelector:@selector(iconDataForVariant:) withObject:@(2)];
                        if (iconData && [iconData isKindOfClass:[NSData class]] && iconData.length > 0) {
                            UIImage *icon = [UIImage imageWithData:iconData scale:2.0];
                            if (icon) {
                                appInfo[@"icon"] = icon;
                            }
                        }
                    } @catch (NSException *e) {}
                }
                
                [self.appList addObject:appInfo];
            } @catch (NSException *e) {
                continue;
            }
        }
        
        // 按App名称排序
        [self.appList sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSString *nameA = a[@"name"] ?: a[@"bundleID"];
            NSString *nameB = b[@"name"] ?: b[@"bundleID"];
            return [nameA.localizedCaseInsensitiveCompare compare:nameB.localizedCaseInsensitiveCompare];
        }];
        
    } @catch (NSException *e) {
        NSLog(@"[AutoPodModePrefs] Failed to load app list: %@", e);
    }
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];
        
        // 标题组
        PSSpecifier *headerGroup = [PSSpecifier specifierWithProperty:nil];
        headerGroup.name = @"AutoPodMode";
        [headerGroup setProperty:@"PSGroupSpecifier" forKey:@"cellClass"];
        [headerGroup setProperty:@"AirPods Pro/Max 自动切换聆听模式" forKey:@"footerText"];
        [specs addObject:headerGroup];
        
        // 总开关
        PSSpecifier *enabledSpec = [PSSpecifier preferenceSpecifierNamed:@"启用插件"
                                                                   target:self
                                                                      set:@selector(setTweakEnabledValue:specifier:)
                                                                      get:@selector(tweakEnabledValue:)
                                                                   detail:nil
                                                                     cell:PSSwitchCell
                                                                     edit:nil];
        [enabledSpec setProperty:@"启用后，媒体播放时自动降噪，暂停时自动通透" forKey:@"detail"];
        [specs addObject:enabledSpec];
        
        // 黑名单说明组
        PSSpecifier *infoGroup = [PSSpecifier specifierWithProperty:nil];
        [infoGroup setProperty:@"PSGroupSpecifier" forKey:@"cellClass"];
        [infoGroup setProperty:@"黑名单应用不会触发自动模式切换。以下应用默认已加入（抖音、抖音极速版、快手）。"
                          forKey:@"footerText"];
        [specs addObject:infoGroup];
        
        // 重置黑名单按钮
        PSSpecifier *resetSpec = [PSSpecifier preferenceSpecifierNamed:@"重置黑名单默认值"
                                                                 target:self
                                                                    set:nil
                                                                    get:nil
                                                                 detail:nil
                                                                   cell:PSButtonCell
                                                                   edit:nil];
        [resetSpec setProperty:@selector(resetBlacklist) forKey:@"action"];
        [resetSpec setProperty:[UIColor systemRedColor] forKey:@"cellTintColor"];
        [specs addObject:resetSpec];
        
        // App列表组标题
        PSSpecifier *appGroup = [PSSpecifier specifierWithProperty:nil];
        [appGroup setProperty:@"PSGroupSpecifier" forKey:@"cellClass"];
        [appGroup setProperty:[NSString stringWithFormat:@"已安装应用（共%lu个）", (unsigned long)self.appList.count]
                        forKey:@"headerText"];
        [appGroup setProperty:@"勾选加入黑名单，不触发自动模式切换" forKey:@"footerText"];
        [specs addObject:appGroup];
        
        // App 复选列表
        for (NSDictionary *appInfo in self.appList) {
            NSString *bid = appInfo[@"bundleID"];
            NSString *name = appInfo[@"name"] ?: bid;
            BOOL isBlacklisted = [self.blacklist containsObject:bid];
            
            PSSpecifier *appSpec = [PSSpecifier preferenceSpecifierNamed:name
                                                                   target:self
                                                                      set:@selector(setAppBlacklist:specifier:)
                                                                      get:@selector(appIsBlacklisted:)
                                                                   detail:nil
                                                                     cell:PSMultiValueCell
                                                                     edit:nil];
            [appSpec setProperty:bid forKey:@"bundleID"];
            [appSpec setProperty:bid forKey:@"key"];
            [appSpec setProperty:@(isBlacklisted) forKey:@"defaultValue"];
            [appSpec setProperty:name forKey:@"label"];
            
            // 设置App图标
            UIImage *icon = appInfo[@"icon"];
            if (icon) {
                [appSpec setProperty:icon forKey:@"iconImage"];
            }
            
            // 使用CheckmarkCell样式
            [appSpec setProperty:@"PSCheckmarkCell" forKey:@"cellClass"];
            [appSpec setProperty:@"PSListItemCell" forKey:@"cellClass"];
            
            [specs addObject:appSpec];
        }
        
        // 关于组
        PSSpecifier *aboutGroup = [PSSpecifier specifierWithProperty:nil];
        [aboutGroup setProperty:@"PSGroupSpecifier" forKey:@"cellClass"];
        [aboutGroup setProperty:@"AutoPodMode v1.0.0\nby sss1919" forKey:@"footerText"];
        [specs addObject:aboutGroup];
        
        _specifiers = [specs copy];
    }
    return _specifiers;
}

// ============ Getter / Setter for enabled switch ============
- (id)tweakEnabledValue:(PSSpecifier *)spec {
    return @(self.tweakEnabled);
}

- (void)setTweakEnabledValue:(id)value specifier:(PSSpecifier *)spec {
    BOOL enabled = [value boolValue];
    self.tweakEnabled = enabled;
    [self saveConfig];
    NSLog(@"[AutoPodModePrefs] Tweak enabled: %d", enabled);
}

// ============ Getter / Setter for app blacklist checkbox ============
- (id)appIsBlacklisted:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"] ?: [spec propertyForKey:@"key"];
    BOOL isIn = [self.blacklist containsObject:bid];
    return @(isIn);
}

- (void)setAppBlacklist:(id)value specifier:(PSSpecifier *)spec {
    NSString *bid = [spec propertyForKey:@"bundleID"] ?: [spec propertyForKey:@"key"];
    BOOL shouldBlacklist = [value boolValue];
    
    if (shouldBlacklist) {
        if (![self.blacklist containsObject:bid]) {
            [self.blacklist addObject:bid];
        }
    } else {
        [self.blacklist removeObject:bid];
    }
    
    [self saveConfig];
    NSLog(@"[AutoPodModePrefs] App %@ blacklist=%d", bid, shouldBlacklist);
    
    // 刷新界面（cell checkmark显示）
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

// ============ Reset button action ============
- (void)resetBlacklist {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置黑名单"
                                                                   message:@"确定要将黑名单恢复为默认设置吗？（抖音、抖音极速版、快手）"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消"
                                                     style:UIAlertActionStyleCancel
                                                   handler:nil];
    
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"重置"
                                                      style:UIAlertActionStyleDestructive
                                                    handler:^(UIAlertAction * _Nonnull action) {
        self.blacklist = [[self defaultBlacklist] mutableCopy];
        [self saveConfig];
        
        // 刷新specifiers和界面
        _specifiers = nil;
        [self reloadSpecifiers];
        [self.tableView reloadData];
        
        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"已重置"
                                                                      message:@"黑名单已恢复默认值"
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:done animated:YES completion:nil];
    }];
    
    [alert addAction:cancel];
    [alert addAction:confirm];
    [self presentViewController:alert animated:YES completion:nil];
}

// ============ Table view data source overrides for custom checkmark display ============
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *bid = [spec propertyForKey:@"bundleID"];
    
    if (bid) {
        BOOL isBlacklisted = [self.blacklist containsObject:bid];
        cell.accessoryType = isBlacklisted ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        
        // 设置副标题为bundleID
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
        // 切换黑名单状态
        BOOL isIn = [self.blacklist containsObject:bid];
        [self setAppBlacklist:@(!isIn) specifier:spec];
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [super tableView:tableView numberOfRowsInSection:section];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadConfig];
    _specifiers = nil;
    [self reloadSpecifiers];
    [self.tableView reloadData];
}

@end
