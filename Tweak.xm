#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaRemote/MediaRemote.h>
#import <objc/runtime.h>

static NSString *const kAutoPodModeConfigFileName = @"com.sss1919.autopodmode.config.plist";
static const NSTimeInterval kManualOverrideCooldown = 30.0; // 30秒保护期

@interface AutoPodModeManager : NSObject
@property (nonatomic, retain) NSMutableArray<NSString *> *blacklist;
@property (nonatomic, assign) BOOL tweakEnabled;
@property (nonatomic, copy) NSString *currentPlayingAppBundleID;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) NSInteger currentListeningMode;
@property (nonatomic, retain) NSDate *lastManualOverrideTime;
@property (nonatomic, assign) BOOL isDeviceSupported;
@property (nonatomic, retain) id btDevice;
@property (nonatomic, retain) NSNotificationCenter *notificationCenter;
@property (nonatomic, retain) id outputDeviceContext;
+ (instancetype)sharedInstance;
- (void)start;
- (void)loadConfig;
- (void)saveConfig;
- (void)checkCurrentDevice;
- (void)updateNowPlayingState;
- (void)applyListeningModeForState:(BOOL)playing;
- (NSArray<NSString *> *)defaultBlacklist;
@end

@implementation AutoPodModeManager

+ (instancetype)sharedInstance {
    static AutoPodModeManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AutoPodModeManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tweakEnabled = YES;
        _isPlaying = NO;
        _currentListeningMode = -1;
        _lastManualOverrideTime = nil;
        _isDeviceSupported = NO;
        _btDevice = nil;
        _notificationCenter = [NSNotificationCenter defaultCenter];
        _blacklist = [[self defaultBlacklist] mutableCopy];
    }
    return self;
}

- (NSArray<NSString *> *)defaultBlacklist {
    return @[
        @"com.ss.iphone.ugc.Aweme",        // 抖音
        @"com.ss.iphone.ugc.Aweme.lite",   // 抖音极速版
        @"com.smile.gifmaker"              // 快手
    ];
}

- (NSString *)configPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    // 使用共享目录：/var/mobile/Library/Preferences/ 实际位置由沙盒决定
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sharedPrefDir = @"/var/mobile/Library/Preferences/";
    if ([fm fileExistsAtPath:sharedPrefDir]) {
        return [sharedPrefDir stringByAppendingPathComponent:kAutoPodModeConfigFileName];
    }
    return [documentsDir stringByAppendingPathComponent:kAutoPodModeConfigFileName];
}

- (void)loadConfig {
    NSString *path = [self configPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:path]) {
        // 配置文件不存在，使用默认值写入
        [self saveConfig];
        return;
    }
    
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:path];
    if (config) {
        NSNumber *enabledNum = config[@"enabled"];
        if (enabledNum) {
            self.tweakEnabled = [enabledNum boolValue];
        }
        NSArray *list = config[@"blacklist"];
        if (list && [list isKindOfClass:[NSArray class]]) {
            NSMutableArray *validList = [NSMutableArray array];
            for (id item in list) {
                if ([item isKindOfClass:[NSString class]]) {
                    [validList addObject:item];
                }
            }
            self.blacklist = validList;
        }
    }
}

- (void)saveConfig {
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    config[@"enabled"] = @(self.tweakEnabled);
    config[@"blacklist"] = [self.blacklist copy];
    NSString *path = [self configPath];
    NSError *error = nil;
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:config
                                                                   format:NSPropertyListXMLFormat_v1_0
                                                                  options:0
                                                                    error:&error];
    if (plistData) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        [plistData writeToFile:path atomically:YES];
    }
}

- (void)start {
    [self loadConfig];
    
    // 监听当前播放状态变化
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(nowPlayingInfoDidChange:)
                                                 name:@"MRNowPlayingPlaybackStateChangedNotification"
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(nowPlayingInfoDidChange:)
                                                 name:@"MPNowPlayingInfoDidChangeNotification"
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(nowPlayingAppDidChange:)
                                                 name:@"MRNowPlayingApplicationDidChangeNotification"
                                               object:nil];
    
    // 监听输出设备变化（蓝牙连接/断开）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(routeChanged:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:[AVAudioSession sharedInstance]];
    
    // 检测当前设备状态
    [self checkCurrentDevice];
    [self updateNowPlayingState];
    
    // 启动配置文件监听
    NSTimeInterval refreshInterval = 5.0;
    [NSTimer scheduledTimerWithTimeInterval:refreshInterval
                                     target:self
                                   selector:@selector(periodicRefresh:)
                                   userInfo:nil
                                    repeats:YES];
    
    NSLog(@"[AutoPodMode] Tweak initialized in mediaremoted");
}

- (void)periodicRefresh:(NSTimer *)timer {
    [self loadConfig];
    [self checkCurrentDevice];
    [self updateNowPlayingState];
}

- (void)nowPlayingInfoDidChange:(NSNotification *)note {
    NSLog(@"[AutoPodMode] nowPlayingInfoDidChange");
    [self updateNowPlayingState];
}

- (void)nowPlayingAppDidChange:(NSNotification *)note {
    NSLog(@"[AutoPodMode] nowPlayingAppDidChange");
    [self updateNowPlayingState];
}

- (void)routeChanged:(NSNotification *)note {
    NSLog(@"[AutoPodMode] route changed");
    [self checkCurrentDevice];
    [self updateNowPlayingState];
}

- (void)updateNowPlayingState {
    if (!self.tweakEnabled) return;
    
    // 获取当前播放App的bundleID
    NSString *bundleID = [self getCurrentPlayingAppBundleID];
    self.currentPlayingAppBundleID = bundleID;
    
    // 获取播放状态
    BOOL playing = [self getCurrentPlaybackState];
    BOOL stateChanged = (self.isPlaying != playing);
    self.isPlaying = playing;
    
    // 检查黑名单
    if (bundleID && [self.blacklist containsObject:bundleID]) {
        NSLog(@"[AutoPodMode] App %@ is in blacklist, skipping", bundleID);
        return;
    }
    
    // 检查设备是否支持
    if (!self.isDeviceSupported) {
        NSLog(@"[AutoPodMode] Device not supported (wired or non-Pro/Max), skipping");
        return;
    }
    
    // 检查30秒保护期
    if (self.lastManualOverrideTime) {
        NSTimeInterval elapsed = -[self.lastManualOverrideTime timeIntervalSinceNow];
        if (elapsed < kManualOverrideCooldown) {
            NSLog(@"[AutoPodMode] Manual override cooldown active (%.0fs remaining), skipping",
                  kManualOverrideCooldown - elapsed);
            return;
        }
        self.lastManualOverrideTime = nil;
    }
    
    if (stateChanged) {
        [self applyListeningModeForState:playing];
    }
}

- (NSString *)getCurrentPlayingAppBundleID {
    // 使用MediaRemote框架获取当前播放App
    @try {
        // MRNowPlayingAppGetDisplayID or similar private API
        // Fallback: try to get from NowPlayingInfoCenter
        Class MPNowPlayingInfoCenterClass = NSClassFromString(@"MPNowPlayingInfoCenter");
        if (MPNowPlayingInfoCenterClass) {
            MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenterClass defaultCenter];
            NSDictionary *info = center.nowPlayingInfo;
            if (info) {
                NSString *bid = info[@"MPNowPlayingInfoPropertyAppIdentifier"];
                if (bid) return bid;
                bid = info[@"appIdentifier"];
                if (bid) return bid;
            }
        }
        
        // Try MRMediaRemoteGetNowPlayingInfo
        if (MRMediaRemoteGetNowPlayingInfo != NULL) {
            void (^handler)(CFDictionaryRef) = ^(CFDictionaryRef info) {
                NSDictionary *dict = (__bridge NSDictionary *)info;
                if (dict) {
                    NSString *bid = dict[(__bridge NSString *)kMRMediaRemoteNowPlayingInfoApplicationIdentifier];
                    if (bid) {
                        self.currentPlayingAppBundleID = bid;
                    }
                }
            };
            MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), handler);
        }
    } @catch (NSException *e) {
        NSLog(@"[AutoPodMode] Exception getting playing app: %@", e);
    }
    return self.currentPlayingAppBundleID;
}

- (BOOL)getCurrentPlaybackState {
    @try {
        Class MPNowPlayingInfoCenterClass = NSClassFromString(@"MPNowPlayingInfoCenter");
        if (MPNowPlayingInfoCenterClass) {
            MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenterClass defaultCenter];
            // playbackState property
            if ([center respondsToSelector:@selector(playbackState)]) {
                NSInteger state = (NSInteger)[center performSelector:@selector(playbackState)];
                // MPNowPlayingPlaybackStatePlaying = 1
                return (state == 1);
            }
        }
        
        // Try MRMediaRemoteGetNowPlayingApplicationPlaybackState
        if (MRMediaRemoteGetNowPlayingApplicationPlaybackState != NULL) {
            void (^handler)(NSInteger) = ^(NSInteger state) {
                self.isPlaying = (state == 1);
            };
            MRMediaRemoteGetNowPlayingApplicationPlaybackState(dispatch_get_main_queue(), handler);
        }
    } @catch (NSException *e) {
        NSLog(@"[AutoPodMode] Exception getting playback state: %@", e);
    }
    return self.isPlaying;
}

- (void)checkCurrentDevice {
    @try {
        // 检查 AVAudioSession 输出端口类型
        AVAudioSession *session = [AVAudioSession sharedInstance];
        AVAudioSessionRouteDescription *route = session.currentRoute;
        NSArray *outputs = route.outputs;
        
        self.isDeviceSupported = NO;
        self.btDevice = nil;
        
        if (outputs.count == 0) return;
        
        for (AVAudioSessionPortDescription *port in outputs) {
            NSString *portType = port.portType;
            NSString *portName = port.portName;
            
            // 有线耳机直接忽略
            if ([portType isEqualToString:AVAudioSessionPortHeadphones]) {
                self.isDeviceSupported = NO;
                NSLog(@"[AutoPodMode] Wired headphones detected, skipping");
                return;
            }
            
            // 蓝牙设备检查
            if ([portType isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
                [portType isEqualToString:AVAudioSessionPortBluetoothHFP] ||
                [portType isEqualToString:AVAudioSessionPortBluetoothLE]) {
                
                // 通过设备名判断是否是 AirPods Pro / AirPods Max
                NSString *lowerName = portName.lowercaseString;
                BOOL isAirPodsPro = [lowerName containsString:@"airpods pro"];
                BOOL isAirPodsMax = [lowerName containsString:@"airpods max"];
                
                if (isAirPodsPro || isAirPodsMax) {
                    self.isDeviceSupported = YES;
                    self.btDevice = port;
                    NSLog(@"[AutoPodMode] Supported device detected: %@", portName);
                } else {
                    NSLog(@"[AutoPodMode] Bluetooth device not supported: %@", portName);
                }
                break;
            }
        }
        
        // 监听蓝牙设备聆听模式变化（用户手动切换）
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(listeningModeChanged:)
                                                     name:@"AVAudioSessionBluetoothDeviceListeningModeChangedNotification"
                                                   object:nil];
        
    } @catch (NSException *e) {
        NSLog(@"[AutoPodMode] Exception checking device: %@", e);
    }
}

- (void)listeningModeChanged:(NSNotification *)note {
    @try {
        NSDictionary *userInfo = note.userInfo;
        NSLog(@"[AutoPodMode] Listening mode changed manually: %@", userInfo);
        // 用户手动修改了，记录保护期开始时间
        self.lastManualOverrideTime = [NSDate date];
    } @catch (NSException *e) {
        NSLog(@"[AutoPodMode] Exception in listeningModeChanged: %@", e);
    }
}

- (void)applyListeningModeForState:(BOOL)playing {
    @try {
        NSInteger targetMode = -1;
        // 降噪模式 = 1 (noise cancellation)
        // 通透模式 = 2 (transparency)
        // 关闭/自适应 = 0 (off/auto)
        
        if (playing) {
            // 播放中：降噪模式
            targetMode = 1;
            NSLog(@"[AutoPodMode] Media playing, setting ANC mode");
        } else {
            // 暂停：通透模式
            targetMode = 2;
            NSLog(@"[AutoPodMode] Media paused, setting transparency mode");
        }
        
        // 如果当前已经是目标模式，跳过
        if (self.currentListeningMode == targetMode) {
            return;
        }
        
        // 尝试通过 AVAudioSession 设置蓝牙设备聆听模式
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSArray *availableModes = nil;
        NSNumber *currentMode = nil;
        
        // Private API: 获取可用聆听模式
        if ([session respondsToSelector:@selector(currentBluetoothListeningMode)]) {
            currentMode = [session performSelector:@selector(currentBluetoothListeningMode)];
            self.currentListeningMode = [currentMode integerValue];
        }
        
        if (self.currentListeningMode == targetMode) {
            return;
        }
        
        // 尝试设置聆听模式
        // -[AVAudioSession setBluetoothListeningMode:error:] 私有 API
        SEL setModeSel = NSSelectorFromString(@"setBluetoothListeningMode:error:");
        if ([session respondsToSelector:setModeSel]) {
            NSNumber *modeNum = @(targetMode);
            NSError *error = nil;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                                 [session methodSignatureForSelector:setModeSel]];
            [inv setSelector:setModeSel];
            [inv setTarget:session];
            [inv setArgument:&modeNum atIndex:2];
            [inv setArgument:&error atIndex:3];
            [inv invoke];
            
            BOOL result = NO;
            [inv getReturnValue:&result];
            
            if (result && !error) {
                self.currentListeningMode = targetMode;
                NSLog(@"[AutoPodMode] Successfully set listening mode to: %ld", (long)targetMode);
            } else {
                NSLog(@"[AutoPodMode] Failed to set listening mode: %@", error);
                // Fallback: 使用私有 BluetoothManager 框架
                [self setBluetoothModeFallback:targetMode];
            }
        } else {
            [self setBluetoothModeFallback:targetMode];
        }
        
    } @catch (NSException *e) {
        NSLog(@"[AutoPodMode] Exception applying listening mode: %@", e);
    }
}

- (void)setBluetoothModeFallback:(NSInteger)mode {
    @try {
        // BluetoothManager 私有框架方式
        // 注意：这个在不同iOS版本变化较大，尽力尝试
        Class btClass = NSClassFromString(@"BluetoothManager");
        if (!btClass) return;
        
        id btManager = [btClass sharedInstance];
        if (!btManager) return;
        
        NSArray *connectedDevices = nil;
        if ([btManager respondsToSelector:@selector(connectedDevices)]) {
            connectedDevices = [btManager performSelector:@selector(connectedDevices)];
        }
        
        for (id device in connectedDevices) {
            NSString *name = nil;
            if ([device respondsToSelector:@selector(name)]) {
                name = [device performSelector:@selector(name)];
            }
            NSString *lowerName = name.lowercaseString;
            if (!([lowerName containsString:@"airpods pro"] || [lowerName containsString:@"airpods max"])) {
                continue;
            }
            
            // 尝试设置聆听模式
            SEL setANC = NSSelectorFromString(@"setActiveNoiseReductionMode:");
            if ([device respondsToSelector:setANC]) {
                NSNumber *modeNum = @(mode);
                [device performSelector:setANC withObject:modeNum];
                self.currentListeningMode = mode;
                NSLog(@"[AutoPodMode] Set ANC mode via BluetoothManager fallback: %ld", (long)mode);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[AutoPodMode] BluetoothManager fallback failed: %@", e);
    }
}

@end

// 构造函数：Tweak 加载时执行
__attribute__((constructor))
static void initialize() {
    @autoreleasepool {
        NSLog(@"[AutoPodMode] Tweak loading in mediaremoted process");
        
        // 延迟启动，确保进程初始化完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[AutoPodModeManager sharedInstance] start];
        });
    }
}
