#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaRemote/MediaRemote.h>
#import <objc/runtime.h>

// Forward declarations for private classes
@class MPNowPlayingInfoCenter;
@interface MPNowPlayingInfoCenter : NSObject
+ (instancetype)defaultCenter;
@property (nonatomic, retain) NSDictionary *nowPlayingInfo;
@property (nonatomic, assign) NSInteger playbackState;
@end

// MediaRemote constants (not in public header)
extern NSString *const kMRMediaRemoteNowPlayingInfoApplicationIdentifier;

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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sharedPrefDir = @"/var/mobile/Library/Preferences/";
    if ([fm fileExistsAtPath:sharedPrefDir]) {
        return [sharedPrefDir stringByAppendingPathComponent:kAutoPodModeConfigFileName];
    }
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject;
    return [documentsDir stringByAppendingPathComponent:kAutoPodModeConfigFileName];
}

- (void)loadConfig {
    NSString *path = [self configPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:path]) {
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
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(routeChanged:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:[AVAudioSession sharedInstance]];
    
    [self checkCurrentDevice];
    [self updateNowPlayingState];
    
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
    
    NSString *bundleID = [self getCurrentPlayingAppBundleID];
    self.currentPlayingAppBundleID = bundleID;
    
    BOOL playing = [self getCurrentPlaybackState];
    BOOL stateChanged = (self.isPlaying != playing);
    self.isPlaying = playing;
    
    if (bundleID && [self.blacklist containsObject:bundleID]) {
        NSLog(@"[AutoPodMode] App %@ is in blacklist, skipping", bundleID);
        return;
    }
    
    if (!self.isDeviceSupported) {
        NSLog(@"[AutoPodMode] Device not supported, skipping");
        return;
    }
    
    if (self.lastManualOverrideTime) {
        NSTimeInterval elapsed = -[self.lastManualOverrideTime timeIntervalSinceNow];
        if (elapsed < kManualOverrideCooldown) {
            NSLog(@"[AutoPodMode] Manual override cooldown (%.0fs remaining), skipping",
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
    @try {
        Class MPNowPlayingInfoCenterClass = NSClassFromString(@"MPNowPlayingInfoCenter");
        if (MPNowPlayingInfoCenterClass) {
            id center = [MPNowPlayingInfoCenterClass performSelector:@selector(defaultCenter)];
            if (center) {
                NSDictionary *info = [center performSelector:@selector(nowPlayingInfo)];
                if (info) {
                    NSString *bid = info[@"MPNowPlayingInfoPropertyAppIdentifier"];
                    if (!bid) bid = info[@"appIdentifier"];
                    if (!bid) bid = info[kMRMediaRemoteNowPlayingInfoApplicationIdentifier];
                    if (bid) return bid;
                }
            }
        }
        
        // Use MRMediaRemoteGetNowPlayingInfo async API
        MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
            if (info) {
                NSDictionary *dict = (__bridge NSDictionary *)info;
                NSString *bid = dict[kMRMediaRemoteNowPlayingInfoApplicationIdentifier];
                if (bid) {
                    self.currentPlayingAppBundleID = [bid copy];
                }
            }
        });
    } @catch (NSException *e) {
        NSLog(@"[AutoPodMode] Exception getting playing app: %@", e);
    }
    return self.currentPlayingAppBundleID;
}

- (BOOL)getCurrentPlaybackState {
    @try {
        // Use MRMediaRemoteGetNowPlayingApplicationIsPlaying
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
            self.isPlaying = (BOOL)isPlaying;
        });
    } @catch (NSException *e) {
        NSLog(@"[AutoPodMode] Exception getting playback state: %@", e);
    }
    return self.isPlaying;
}

- (void)checkCurrentDevice {
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        AVAudioSessionRouteDescription *route = session.currentRoute;
        NSArray *outputs = route.outputs;
        
        self.isDeviceSupported = NO;
        self.btDevice = nil;
        
        if (outputs.count == 0) return;
        
        for (AVAudioSessionPortDescription *port in outputs) {
            NSString *portType = port.portType;
            NSString *portName = port.portName;
            
            if ([portType isEqualToString:AVAudioSessionPortHeadphones]) {
                self.isDeviceSupported = NO;
                NSLog(@"[AutoPodMode] Wired headphones detected, skipping");
                return;
            }
            
            if ([portType isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
                [portType isEqualToString:AVAudioSessionPortBluetoothHFP] ||
                [portType isEqualToString:AVAudioSessionPortBluetoothLE]) {
                
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
        
        if (playing) {
            targetMode = 1;
            NSLog(@"[AutoPodMode] Media playing, setting ANC mode");
        } else {
            targetMode = 2;
            NSLog(@"[AutoPodMode] Media paused, setting transparency mode");
        }
        
        if (self.currentListeningMode == targetMode) {
            return;
        }
        
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSNumber *currentMode = nil;
        
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([session respondsToSelector:@selector(currentBluetoothListeningMode)]) {
            currentMode = [session performSelector:@selector(currentBluetoothListeningMode)];
            self.currentListeningMode = [currentMode integerValue];
        }
#pragma clang diagnostic pop
        
        if (self.currentListeningMode == targetMode) {
            return;
        }
        
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
        Class btClass = NSClassFromString(@"BluetoothManager");
        if (!btClass) return;
        
        id btManager = [btClass performSelector:@selector(sharedInstance)];
        if (!btManager) return;
        
        NSArray *connectedDevices = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([btManager respondsToSelector:@selector(connectedDevices)]) {
            connectedDevices = [btManager performSelector:@selector(connectedDevices)];
        }
#pragma clang diagnostic pop
        
        for (id device in connectedDevices) {
            NSString *name = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            if ([device respondsToSelector:@selector(name)]) {
                name = [device performSelector:@selector(name)];
            }
#pragma clang diagnostic pop
            NSString *lowerName = name.lowercaseString;
            if (!([lowerName containsString:@"airpods pro"] || [lowerName containsString:@"airpods max"])) {
                continue;
            }
            
            SEL setANC = NSSelectorFromString(@"setActiveNoiseReductionMode:");
            if ([device respondsToSelector:setANC]) {
                NSNumber *modeNum = @(mode);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [device performSelector:setANC withObject:modeNum];
#pragma clang diagnostic pop
                self.currentListeningMode = mode;
                NSLog(@"[AutoPodMode] Set ANC mode via BluetoothManager fallback: %ld", (long)mode);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[AutoPodMode] BluetoothManager fallback failed: %@", e);
    }
}

@end

__attribute__((constructor))
static void initialize() {
    @autoreleasepool {
        NSLog(@"[AutoPodMode] Tweak loading in mediaremoted process");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[AutoPodModeManager sharedInstance] start];
        });
    }
}
