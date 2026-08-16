#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaRemote/MediaRemote.h>
#import <objc/runtime.h>

static NSString *const kMRNowPlayingAppPidKey = @"MRMediaRemoteNowPlayingInfoApplicationIdentifier";
static NSString *const kConfigPath = @"/var/mobile/Library/Preferences/com.sss1919.autopodmode.config.plist";
static const NSTimeInterval kManualOverrideCooldown = 30.0;

typedef NS_ENUM(NSInteger, APMPMode) {
    APMPModeNormal = 0,
    APMPModeANC = 1,
    APMPModeTransparency = 2
};

@interface APMPManager : NSObject
@property (nonatomic, retain) NSMutableArray<NSString *> *blacklist;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSString *nowPlayingBundleID;
@property (nonatomic, assign) BOOL lastPlaying;
@property (nonatomic, retain) NSDate *lastManual;
@property (nonatomic, assign) BOOL deviceOK;
@end

@implementation APMPManager

+ (instancetype)shared {
    static APMPManager *inst = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ inst = [[APMPManager alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _enabled = YES;
        _lastPlaying = NO;
        _deviceOK = NO;
        _blacklist = [@[@"com.ss.iphone.ugc.Aweme",
                        @"com.ss.iphone.ugc.Aweme.lite",
                        @"com.smile.gifmaker"] mutableCopy];
    }
    return self;
}

#pragma mark - Config

- (void)loadConfig {
    @try {
        NSDictionary *c = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
        if (!c) { [self saveConfig]; return; }
        NSNumber *e = c[@"enabled"];
        if (e) _enabled = e.boolValue;
        NSArray *l = c[@"blacklist"];
        if ([l isKindOfClass:[NSArray class]]) {
            NSMutableArray *v = [NSMutableArray array];
            for (id i in l) if ([i isKindOfClass:[NSString class]]) [v addObject:i];
            _blacklist = v;
        }
    } @catch (NSException *ex) {
        NSLog(@"[APMP] loadConfig error: %@", ex);
    }
}

- (void)saveConfig {
    NSMutableDictionary *c = [NSMutableDictionary dictionary];
    c[@"enabled"] = @(_enabled);
    c[@"blacklist"] = [_blacklist copy];
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:c
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (d) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = [kConfigPath stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:dir])
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [d writeToFile:kConfigPath atomically:YES];
    }
}

#pragma mark - BluetoothManager helpers

- (void)enableBluetoothManager {
    @try {
        Class c = NSClassFromString(@"BluetoothManager");
        if (!c) { NSLog(@"[APMP] BluetoothManager class not found"); return; }
        id m = [c performSelector:@selector(sharedInstance)];
        if (!m) { NSLog(@"[APMP] BluetoothManager sharedInstance nil"); return; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([m respondsToSelector:@selector(enable)]) [m performSelector:@selector(enable)];
        if ([m respondsToSelector:@selector(setPowered:)])
            [m performSelector:@selector(setPowered:) withObject:@(YES)];
#pragma clang diagnostic pop
        NSLog(@"[APMP] BluetoothManager enabled");
    } @catch (NSException *e) {
        NSLog(@"[APMP] enableBluetoothManager error: %@", e);
    }
}

- (void)scanDevices {
    _deviceOK = NO;
    @try {
        Class c = NSClassFromString(@"BluetoothManager");
        if (!c) return;
        id m = [c performSelector:@selector(sharedInstance)];
        if (!m) return;
        NSArray *devs = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([m respondsToSelector:@selector(connectedDevices)])
            devs = [m performSelector:@selector(connectedDevices)];
#pragma clang diagnostic pop
        NSLog(@"[APMP] connected BT devices count: %lu", (unsigned long)devs.count);
        for (id d in devs) {
            NSString *n = nil;
            BOOL ancSupported = NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            if ([d respondsToSelector:@selector(name)]) n = [d performSelector:@selector(name)];
            if ([d respondsToSelector:@selector(isActiveNoiseReductionSupported)]) {
                NSNumber *s = [d performSelector:@selector(isActiveNoiseReductionSupported)];
                if (s) ancSupported = s.boolValue;
            }
#pragma clang diagnostic pop
            NSString *l = n.lowercaseString;
            BOOL nameMatch = [l containsString:@"airpods pro"] || [l containsString:@"airpods max"];
            NSLog(@"[APMP] BT device: %@, nameMatch=%d, ancSupported=%d", n, nameMatch, ancSupported);
            if (nameMatch || ancSupported) {
                _deviceOK = YES;
                return;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[APMP] scanDevices error: %@", e);
    }
}

- (void)setMode:(APMPMode)mode {
    NSLog(@"[APMP] setMode:%ld", (long)mode);
    BOOL success = NO;

    // Strategy 1: AVAudioSession setBluetoothListeningMode:error: (most modern, works in SpringBoard)
    @try {
        AVAudioSession *ses = [AVAudioSession sharedInstance];
        SEL s4 = NSSelectorFromString(@"setBluetoothListeningMode:error:");
        if ([ses respondsToSelector:s4]) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[ses methodSignatureForSelector:s4]];
            inv.selector = s4;
            inv.target = ses;
            NSNumber *mn = @(mode);
            NSError *e = nil;
            [inv setArgument:&mn atIndex:2];
            [inv setArgument:&e atIndex:3];
            [inv invoke];
            BOOL ok = NO;
            [inv getReturnValue:&ok];
            if (ok) {
                NSLog(@"[APMP] AVAudioSession setBluetoothListeningMode:%ld SUCCESS", (long)mode);
                success = YES;
            } else {
                NSLog(@"[APMP] AVAudioSession setBluetoothListeningMode returned NO, error=%@", e);
            }
        } else {
            NSLog(@"[APMP] AVAudioSession does NOT respondTo setBluetoothListeningMode");
        }
    } @catch (NSException *e) {
        NSLog(@"[APMP] AVAudioSession setMode error: %@", e);
    }

    // Strategy 2: BluetoothManager device setters (fallback)
    if (!success) {
        @try {
            Class c = NSClassFromString(@"BluetoothManager");
            if (!c) return;
            id m = [c performSelector:@selector(sharedInstance)];
            if (!m) return;
            NSArray *devs = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            if ([m respondsToSelector:@selector(connectedDevices)])
                devs = [m performSelector:@selector(connectedDevices)];
#pragma clang diagnostic pop
            NSNumber *mn = @(mode);
            for (id d in devs) {
                NSString *n = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                if ([d respondsToSelector:@selector(name)]) n = [d performSelector:@selector(name)];
#pragma clang diagnostic pop
                SEL s1 = NSSelectorFromString(@"setActiveNoiseReductionMode:");
                if ([d respondsToSelector:s1]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [d performSelector:s1 withObject:mn];
#pragma clang diagnostic pop
                    NSLog(@"[APMP] %@ setActiveNoiseReductionMode:%ld", n, (long)mode);
                    success = YES;
                }
                SEL s2 = NSSelectorFromString(@"setBluetoothListeningMode:");
                if ([d respondsToSelector:s2]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [d performSelector:s2 withObject:mn];
#pragma clang diagnostic pop
                    NSLog(@"[APMP] %@ setBluetoothListeningMode:%ld", n, (long)mode);
                    success = YES;
                }
                SEL s3 = NSSelectorFromString(@"setListeningMode:");
                if ([d respondsToSelector:s3]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [d performSelector:s3 withObject:mn];
#pragma clang diagnostic pop
                    NSLog(@"[APMP] %@ setListeningMode:%ld", n, (long)mode);
                    success = YES;
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[APMP] BT device setMode error: %@", e);
        }
    }

    if (!success) NSLog(@"[APMP] WARNING: All mode-setting strategies failed!");
}

#pragma mark - Playback state via MediaRemote

- (void)check {
    [self loadConfig];
    if (!_enabled) return;
    [self enableBluetoothManager];
    [self scanDevices];

    __block NSString *bid = [_nowPlayingBundleID copy];
    __block BOOL playing = _lastPlaying;
    __block BOOL done = NO;

    void (^applyNow)(void) = ^{
        if (!done) { done = YES; [self apply:bid playing:playing]; }
    };

    dispatch_queue_t q = dispatch_get_main_queue();

    // Query NowPlaying info for bundle ID + playback state
    MRMediaRemoteGetNowPlayingInfo(q, ^(CFDictionaryRef info) {
        if (info) {
            NSDictionary *d = (__bridge NSDictionary *)info;
            NSString *b = d[kMRNowPlayingAppPidKey];
            if (!b) b = d[@"MPNowPlayingInfoPropertyAppIdentifier"];
            if (!b) b = d[@"kMRMediaRemoteNowPlayingInfoClientIdentifierKey"];
            if (b) bid = b;
            NSNumber *st = d[@"MRMediaRemoteNowPlayingInfoPlaybackState"];
            if (!st) st = d[@"MPNowPlayingInfoPropertyPlaybackState"];
            if (st) playing = (st.integerValue == 1);
        }
        // Follow-up: direct isPlaying query (most reliable)
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(q, ^(Boolean p) {
            playing = (BOOL)p;
            applyNow();
        });
    });

    // Safety timeout: 2 seconds
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2*NSEC_PER_SEC)), q, applyNow);
}

- (void)apply:(NSString *)bid playing:(BOOL)playing {
    if (!_enabled) return;

    BOOL changed = (_lastPlaying != playing);
    _lastPlaying = playing;
    if (bid) _nowPlayingBundleID = bid;

    NSLog(@"[APMP] app=%@ playing=%d changed=%d deviceOK=%d enabled=%d",
          bid, playing, changed, _deviceOK, _enabled);

    if (bid && [_blacklist containsObject:bid]) {
        NSLog(@"[APMP] blacklist hit: %@, skip", bid);
        return;
    }
    if (!_deviceOK) {
        NSLog(@"[APMP] no supported ANC device, skip");
        return;
    }

    if (_lastManual) {
        NSTimeInterval elapsed = -[_lastManual timeIntervalSinceNow];
        if (elapsed < kManualOverrideCooldown) {
            NSLog(@"[APMP] manual override cooldown: %.0fs left, skip", kManualOverrideCooldown - elapsed);
            return;
        }
        _lastManual = nil;
    }

    if (!changed) {
        NSLog(@"[APMP] no state change, skip");
        return;
    }

    if (playing) {
        NSLog(@"[APMP] => PLAYING, set ANC");
        [self setMode:APMPModeANC];
    } else {
        NSLog(@"[APMP] => PAUSED, set Transparency");
        [self setMode:APMPModeTransparency];
    }
}

#pragma mark - Entry

- (void)start {
    NSLog(@"[APMP] ===== starting up in SpringBoard =====");
    [self loadConfig];
    [self enableBluetoothManager];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // MediaRemote notifications (distributed, SpringBoard receives them)
    [nc addObserver:self selector:@selector(onNote:)
           name:@"MRMediaRemoteNowPlayingInfoDidChangeNotification" object:nil];
    [nc addObserver:self selector:@selector(onNote:)
           name:@"MRMediaRemotePlaybackStateChangedNotification" object:nil];
    [nc addObserver:self selector:@selector(onNote:)
           name:@"MRNowPlayingApplicationDidChangeNotification" object:nil];
    [nc addObserver:self selector:@selector(onNote:)
           name:@"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification" object:nil];

    // Audio route changes (AirPods connect/disconnect)
    [nc addObserver:self selector:@selector(onNote:)
           name:AVAudioSessionRouteChangeNotification object:nil];

    // User manual listening mode change -> cooldown
    NSString *modeChangeNote = @"AVAudioSessionBluetoothDeviceListeningModeChangedNotification";
    [nc addObserver:self selector:@selector(onListeningChange:)
           name:modeChangeNote object:nil];
    // Also listen on a few other possible notification names
    [nc addObserver:self selector:@selector(onListeningChange:)
           name:@"BluetoothDeviceListeningModeDidChangeNotification" object:nil];

    // Initial check (delayed so services are up)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self check]; });

    // Periodic safety check every 15s
    [NSTimer scheduledTimerWithTimeInterval:15.0 target:self selector:@selector(check) userInfo:nil repeats:YES];

    NSLog(@"[APMP] start completed, observers registered");
}

- (void)onNote:(NSNotification *)n {
    NSLog(@"[APMP] notification: %@", n.name);
    dispatch_async(dispatch_get_main_queue(), ^{ [self check]; });
}

- (void)onListeningChange:(NSNotification *)n {
    NSLog(@"[APMP] user changed listening mode manually (note: %@), cooldown activated", n.name);
    _lastManual = [NSDate date];
}

@end

__attribute__((constructor))
static void APMPInit(void) {
    @autoreleasepool {
        NSLog(@"[APMP] constructor fired");
        NSString *procName = [[NSProcessInfo processInfo] processName];
        NSLog(@"[APMP] current process: %@", procName);

        // Safety: only start in SpringBoard.
        // (Filter in plist already ensures injection into SpringBoard,
        //  this extra check is defensive.)
        if (procName && ![procName isEqualToString:@"SpringBoard"]) {
            NSLog(@"[APMP] skip: not SpringBoard, proc=%@", procName);
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[APMPManager shared] start];
                        });
    }
}
