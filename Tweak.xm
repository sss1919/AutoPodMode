#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaRemote/MediaRemote.h>
#import <objc/runtime.h>

// MediaRemote constants (not in public header)
static NSString *const kMRNowPlayingAppPidKey = @"MRMediaRemoteNowPlayingInfoApplicationIdentifier";
static NSString *const kMRPlaybackStateKey = @"MRMediaRemoteNowPlayingInfoPlaybackState";

static NSString *const kConfigFileName = @"com.sss1919.autopodmode.config.plist";
static const NSTimeInterval kManualOverrideCooldown = 30.0;

// MRPlaybackState enum
typedef NS_ENUM(NSInteger, MRPlaybackState) {
    MRPlaybackStateStopped = 0,
    MRPlaybackStatePlaying  = 1,
    MRPlaybackStatePaused   = 2,
};

@interface AutoPodModeManager : NSObject
@property (nonatomic, retain) NSMutableArray<NSString *> *blacklist;
@property (nonatomic, assign) BOOL tweakEnabled;
@property (nonatomic, copy) NSString *currentPlayingAppBundleID;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL lastKnownPlayingState;
@property (nonatomic, retain) NSDate *lastManualOverrideTime;
@property (nonatomic, assign) BOOL isDeviceSupported;
+ (instancetype)sharedInstance;
- (void)start;
- (void)loadConfig;
- (void)saveConfig;
- (void)checkBluetoothDevice;
- (void)queryPlaybackStateAndAct;
- (void)applyListeningMode:(NSInteger)mode;
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
        _lastKnownPlayingState = NO;
        _lastManualOverrideTime = nil;
        _isDeviceSupported = NO;
        _blacklist = [[self defaultBlacklist] mutableCopy];
    }
    return self;
}

- (NSArray<NSString *> *)defaultBlacklist {
    return @[
        @"com.ss.iphone.ugc.Aweme",
        @"com.ss.iphone.ugc.Aweme.lite",
        @"com.smile.gifmaker"
    ];
}

#pragma mark - Config

- (NSString *)configPath {
    return @"/var/mobile/Library/Preferences/com.sss1919.autopodmode.config.plist";
}

- (void)loadConfig {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:[self configPath]];
    if (config) {
        NSNumber *en = config[@"enabled"];
        if (en) _tweakEnabled = [en boolValue];
        NSArray *list = config[@"blacklist"];
        if (list && [list isKindOfClass:[NSArray class]]) {
            NSMutableArray *valid = [NSMutableArray array];
            for (id item in list) {
                if ([item isKindOfClass:[NSString class]]) [valid addObject:item];
            }
            _blacklist = valid;
        }
    } else {
        _tweakEnabled = YES;
        _blacklist = [[self defaultBlacklist] mutableCopy];
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
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [[self configPath] stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        [data writeToFile:[self configPath] atomically:YES];
    }
}

#pragma mark - Bluetooth Device Check (via BluetoothManager)

- (void)checkBluetoothDevice {
    @try {
        Class btClass = NSClassFromString(@"BluetoothManager");
        if (!btClass) {
            NSLog(@"[AutoPodMode] BluetoothManager class not found");
            _isDeviceSupported = NO;
            return;
        }

        id btManager = [btClass performSelector:@selector(sharedInstance)];
        if (!btManager) {
            NSLog(@"[AutoPodMode] BluetoothManager sharedInstance is nil");
            _isDeviceSupported = NO;
            return;
        }

        NSArray *devices = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([btManager respondsToSelector:@selector(connectedDevices)]) {
            devices = [btManager performSelector:@selector(connectedDevices)];
        }
#pragma clang diagnostic pop

        _isDeviceSupported = NO;

        for (id device in devices) {
            NSString *name = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            if ([device respondsToSelector:@selector(name)]) {
                name = [device performSelector:@selector(name)];
            }
#pragma clang diagnostic pop

            NSString *lower = name.lowercaseString;
            if ([lower containsString:@"airpods pro"] || [lower containsString:@"airpods max"]) {
                _isDeviceSupported = YES;
                NSLog(@"[AutoPodMode] Supported AirPods detected: %@", name);
                return;
            }
        }

        NSLog(@"[AutoPodMode] No supported AirPods found in %lu connected devices",
              (unsigned long)devices.count);
    } @catch (NSException *e) {
        NSLog(@"[AutoPodMode] Exception in checkBluetoothDevice: %@", e);
    }
}

#pragma mark - Playback State (async, acts on callback)

- (void)queryPlaybackStateAndAct {
    if (!self.tweakEnabled) return;

    __block NSString *detectedBundleID = nil;
    __block BOOL detectedPlaying = NO;
    __block BOOL handled = NO;

    MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        if (info) {
            NSDictionary *dict = (__bridge NSDictionary *)info;
            NSString *bid = dict[kMRNowPlayingAppPidKey];
            if (!bid) bid = dict[@"MPNowPlayingInfoPropertyAppIdentifier"];
            if (!bid) bid = dict[@"appIdentifier"];
            detectedBundleID = [bid copy];

            NSNumber *stateNum = dict[kMRPlaybackStateKey];
            if (!stateNum) stateNum = dict[@"MPNowPlayingInfoPropertyPlaybackState"];
            if (stateNum) {
                MRPlaybackState state = (MRPlaybackState)[stateNum integerValue];
                detectedPlaying = (state == MRPlaybackStatePlaying);
            }
        }

        // Query playback state separately for accuracy
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
            detectedPlaying = (BOOL)isPlaying;
            handled = YES;
            [self handlePlaybackResult:detectedBundleID isPlaying:detectedPlaying];
        });

        // Fallback if second async call doesn't fire within 1s
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!handled) {
                handled = YES;
                [self handlePlaybackResult:detectedBundleID isPlaying:detectedPlaying];
            }
        });
    });

    // Ultimate fallback: if MRMediaRemoteGetNowPlayingInfo doesn't call back
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!handled) {
            handled = YES;
            NSLog(@"[AutoPodMode] MediaRemote timeout, using last known state");
            [self handlePlaybackResult:self.currentPlayingAppBundleID isPlaying:self.isPlaying];
        }
    });
}

- (void)handlePlaybackResult:(NSString *)bundleID isPlaying:(BOOL)playing {
    if (!self.tweakEnabled) return;

    self.currentPlayingAppBundleID = bundleID;

    BOOL stateChanged = (self.lastKnownPlayingState != playing);
    self.lastKnownPlayingState = playing;
    self.isPlaying = playing;

    NSLog(@"[AutoPodMode] State: app=%@ playing=%d changed=%d supported=%d",
          bundleID, playing, stateChanged, self.isDeviceSupported);

    // Blacklist check
    if (bundleID && [self.blacklist containsObject:bundleID]) {
        NSLog(@"[AutoPodMode] App %@ is in blacklist, skipping", bundleID);
        return;
    }

    // Device check
    if (!self.isDeviceSupported) {
        NSLog(@"[AutoPodMode] No supported AirPods, skipping");
        return;
    }

    // Manual override cooldown
    if (self.lastManualOverrideTime) {
        NSTimeInterval elapsed = -[self.lastManualOverrideTime timeIntervalSinceNow];
        if (elapsed < kManualOverrideCooldown) {
            NSLog(@"[AutoPodMode] Manual override cooldown (%.0fs remaining)", kManualOverrideCooldown - elapsed);
            return;
        }
        self.lastManualOverrideTime = nil;
    }

    // Only act on state change
    if (stateChanged) {
        if (playing) {
            NSLog(@"[AutoPodMode] Media started playing -> setting ANC");
            [self applyListeningMode:1]; // 1 = ANC
        } else {
            NSLog(@"[AutoPodMode] Media paused -> setting Transparency");
            [self applyListeningMode:2]; // 2 = Transparency
        }
    }
}

#pragma mark - Set Listening Mode (via BluetoothManager)

- (void)applyListeningMode:(NSInteger)mode {
    @try {
        Class btClass = NSClassFromString(@"BluetoothManager");
        if (!btClass) {
            NSLog(@"[AutoPodMode] BluetoothManager not available");
            return;
        }

        id btManager = [btClass performSelector:@selector(sharedInstance)];
        if (!btManager) return;

        NSArray *devices = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([btManager respondsToSelector:@selector(connectedDevices)]) {
            devices = [btManager performSelector:@selector(connectedDevices)];
        }
#pragma clang diagnostic pop

        BOOL success = NO;

        for (id device in devices) {
            NSString *name = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            if ([device respondsToSelector:@selector(name)]) {
                name = [device performSelector:@selector(name)];
            }
#pragma clang diagnostic pop

            NSString *lower = name.lowercaseString;
            if (!([lower containsString:@"airpods pro"] || [lower containsString:@"airpods max"])) {
                continue;
            }

            NSLog(@"[AutoPodMode] Setting mode %ld on device: %@", (long)mode, name);

            // Try setBluetoothListeningMode: (newer API)
            SEL setModeSel = NSSelectorFromString(@"setBluetoothListeningMode:");
            if ([device respondsToSelector:setModeSel]) {
                NSNumber *modeNum = @(mode);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [device performSelector:setModeSel withObject:modeNum];
#pragma clang diagnostic pop
                success = YES;
                NSLog(@"[AutoPodMode] Set mode via setBluetoothListeningMode:");
            }

            // Try setActiveNoiseReductionMode: (older API)
            SEL setANCSel = NSSelectorFromString(@"setActiveNoiseReductionMode:");
            if ([device respondsToSelector:setANCSel]) {
                NSNumber *modeNum = @(mode);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [device performSelector:setANCSel withObject:modeNum];
#pragma clang diagnostic pop
                success = YES;
                NSLog(@"[AutoPodMode] Set mode via setActiveNoiseReductionMode:");
            }

            // Try setListeningMode: (another variant)
            SEL setListeningSel = NSSelectorFromString(@"setListeningMode:");
            if ([device respondsToSelector:setListeningSel]) {
                NSNumber *modeNum = @(mode);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [device performSelector:setListeningSel withObject:modeNum];
#pragma clang diagnostic pop
                success = YES;
                NSLog(@"[AutoPodMode] Set mode via setListeningMode:");
            }
        }

        if (!success) {
            NSLog(@"[AutoPodMode] No compatible method found on any AirPods device");
        }
    } @catch (NSException *e) {
        NSLog(@"[AutoPodMode] Exception in applyListeningMode: %@", e);
    }
}

#pragma mark - Start / Periodic

- (void)start {
    [self loadConfig];

    // Register for MediaRemote notifications
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onMediaNotification:)
                                                 name:@"MRMediaRemoteNowPlayingInfoDidChangeNotification"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onMediaNotification:)
                                                 name:@"MRMediaRemotePlaybackStateChangedNotification"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onMediaNotification:)
                                                 name:@"MRNowPlayingApplicationDidChangeNotification"
                                               object:nil];

    // Check device
    [self checkBluetoothDevice];

    // Query initial state
    [self queryPlaybackStateAndAct];

    // Periodic refresh: check device + playback state every 10 seconds
    [NSTimer scheduledTimerWithTimeInterval:10.0
                                     target:self
                                   selector:@selector(periodicRefresh:)
                                   userInfo:nil
                                    repeats:YES];

    NSLog(@"[AutoPodMode] Tweak started in mediaremoted, enabled=%d", self.tweakEnabled);
}

- (void)periodicRefresh:(NSTimer *)timer {
    [self loadConfig];
    [self checkBluetoothDevice];
    [self queryPlaybackStateAndAct];
}

- (void)onMediaNotification:(NSNotification *)note {
    NSLog(@"[AutoPodMode] Notification: %@", note.name);
    [self queryPlaybackStateAndAct];
}

@end

__attribute__((constructor))
static void AutoPodModeInit() {
    @autoreleasepool {
        NSLog(@"[AutoPodMode] Loading in mediaremoted...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[AutoPodModeManager sharedInstance] start];
        });
    }
}
