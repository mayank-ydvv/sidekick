// A tiny helper loaded by the system perl (/usr/bin/perl), which macOS still lets use MediaRemote.
// Sidekick runs `perl nowplaying.pl <this dylib> stream|get|send` and reads JSON lines from stdout.
//   stream: prints the now-playing state whenever it changes (forever)
//   get:    prints the state once
//   send:   performs SIDEKICK_MR_CMD = toggle | play | pause | next | previous | seek:<seconds>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientBundleFn)(id);
typedef CFStringRef (*ClientParentBundleFn)(id);
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);

static void *MR;
static NSString *lastLine;

static void *sym(const char *name) {
    if (!MR) MR = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return MR ? dlsym(MR, name) : NULL;
}

static NSString *str(NSDictionary *d, NSString *k) { id v = d[k]; return [v isKindOfClass:NSString.class] ? v : nil; }
static NSNumber *num(NSDictionary *d, NSString *k) { id v = d[k]; return [v isKindOfClass:NSNumber.class] ? v : nil; }

/// Small PNG thumbnail (≤ 160 px) of the artwork, base64.
static NSString *artwork(NSData *data) {
    if (!data.length) return nil;
    NSImage *img = [[NSImage alloc] initWithData:data];
    if (!img) return nil;
    NSSize s = img.size; CGFloat k = MIN(1.0, 160.0 / MAX(s.width, s.height));
    NSSize t = NSMakeSize(MAX(1, round(s.width * k)), MAX(1, round(s.height * k)));
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:t.width pixelsHigh:t.height
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [img drawInRect:NSMakeRect(0, 0, t.width, t.height)];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor: @0.8}];
    return [png base64EncodedStringWithOptions:0];
}

static void emit(void) {
    GetInfoFn getInfo = sym("MRMediaRemoteGetNowPlayingInfo");
    GetIsPlayingFn isPlaying = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    GetClientFn getClient = sym("MRMediaRemoteGetNowPlayingClient");
    ClientBundleFn bundleOf = sym("MRNowPlayingClientGetBundleIdentifier");
    ClientParentBundleFn parentOf = sym("MRNowPlayingClientGetParentAppBundleIdentifier");
    if (!getInfo || !isPlaying) { printf("{\"error\":\"mediaremote unavailable\"}\n"); fflush(stdout); return; }
    dispatch_queue_t q = dispatch_get_main_queue();
    __block NSMutableDictionary *out = [NSMutableDictionary dictionary];
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_enter(g);
    getInfo(q, ^(CFDictionaryRef ref) {
        NSDictionary *d = (__bridge NSDictionary *)ref;
        if (d) {
            if (str(d, @"kMRMediaRemoteNowPlayingInfoTitle")) out[@"title"] = str(d, @"kMRMediaRemoteNowPlayingInfoTitle");
            if (str(d, @"kMRMediaRemoteNowPlayingInfoArtist")) out[@"artist"] = str(d, @"kMRMediaRemoteNowPlayingInfoArtist");
            if (str(d, @"kMRMediaRemoteNowPlayingInfoAlbum")) out[@"album"] = str(d, @"kMRMediaRemoteNowPlayingInfoAlbum");
            if (num(d, @"kMRMediaRemoteNowPlayingInfoDuration")) out[@"duration"] = num(d, @"kMRMediaRemoteNowPlayingInfoDuration");
            if (num(d, @"kMRMediaRemoteNowPlayingInfoElapsedTime")) out[@"elapsed"] = num(d, @"kMRMediaRemoteNowPlayingInfoElapsedTime");
            if (num(d, @"kMRMediaRemoteNowPlayingInfoPlaybackRate")) out[@"rate"] = num(d, @"kMRMediaRemoteNowPlayingInfoPlaybackRate");
            id ts = d[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([ts isKindOfClass:NSDate.class]) out[@"timestamp"] = @([(NSDate *)ts timeIntervalSince1970]);
            id art = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if ([art isKindOfClass:NSData.class]) { NSString *a = artwork(art); if (a) out[@"artwork"] = a; }
        }
        dispatch_group_leave(g);
    });
    dispatch_group_enter(g);
    isPlaying(q, ^(Boolean p) { out[@"playing"] = @(p); dispatch_group_leave(g); });
    if (getClient && bundleOf) {
        dispatch_group_enter(g);
        getClient(q, ^(id client) {
            if (client) {
                NSString *b = (__bridge NSString *)bundleOf(client);
                NSString *p = parentOf ? (__bridge NSString *)parentOf(client) : nil;
                if (p.length) b = p;   // e.g. a browser tab's parent app
                if (b) out[@"bundle"] = b;
            }
            dispatch_group_leave(g);
        });
    }
    dispatch_group_notify(g, q, ^{
        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        // Elapsed time changes on every query; only skip exact duplicates.
        if (![line isEqualToString:lastLine]) { lastLine = line; printf("%s\n", line.UTF8String); fflush(stdout); }
    });
}

static void runLoopFor(double seconds) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false); }

void sidekick_get(void *perl, void *cv) {
    @autoreleasepool { emit(); runLoopFor(1.5); }
}

void sidekick_stream(void *perl, void *cv) {
    @autoreleasepool {
        RegisterFn reg = sym("MRMediaRemoteRegisterForNowPlayingNotifications");
        if (reg) reg(dispatch_get_main_queue());
        NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange"];
        for (NSString *n in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) { emit(); }];
        }
        emit();
        // Exit when Sidekick goes away (stdin closes).
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(src, ^{
            char buf[64]; if (read(STDIN_FILENO, buf, sizeof buf) <= 0) exit(0);
        });
        dispatch_resume(src);
        CFRunLoopRun();
    }
}

void sidekick_send(void *perl, void *cv) {
    @autoreleasepool {
        const char *c = getenv("SIDEKICK_MR_CMD");
        NSString *cmd = c ? [NSString stringWithUTF8String:c] : @"toggle";
        SendCommandFn send = sym("MRMediaRemoteSendCommand");
        if ([cmd hasPrefix:@"seek:"]) {
            SetElapsedFn set = sym("MRMediaRemoteSetElapsedTime");
            if (set) set([[cmd substringFromIndex:5] doubleValue]);
        } else if (send) {
            // MRMediaRemoteCommand: 0 play, 1 pause, 2 togglePlayPause, 4 nextTrack, 5 previousTrack
            int code = [cmd isEqualToString:@"play"] ? 0 : [cmd isEqualToString:@"pause"] ? 1 :
                       [cmd isEqualToString:@"next"] ? 4 : [cmd isEqualToString:@"previous"] ? 5 : 2;
            send(code, NULL);
        }
        runLoopFor(0.3);
    }
}
