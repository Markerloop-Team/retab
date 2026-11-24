// Retab — the Mac's Command-Tab, with one difference: every Chrome profile is its own icon.
// It looks and works like the system's app switcher — a row of app icons, hold the keys, let go
// to switch — but a browser with several profiles shows one icon per profile, labelled.
//
// One file, no dependencies. Build with ./build.sh (needs only the Xcode Command Line Tools).

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import <QuartzCore/QuartzCore.h>
#import <signal.h>

// A line in ~/Library/Logs/Retab.log. Window titles are never written there.
static void Log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static NSDateFormatter *stamp;
    static FILE *file;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stamp = [NSDateFormatter new];
        stamp.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        file = fopen([NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Retab.log"].fileSystemRepresentation, "a");
    });
    if (!file) return;
    @synchronized (stamp) {
        fprintf(file, "%s %s\n", [stamp stringFromDate:NSDate.date].UTF8String, line.UTF8String);
        fflush(file);
    }
}

#pragma mark - Private system calls

// There is no public way to list windows on other Spaces, to take a picture of one window, or to
// bring one particular window (rather than a whole app) to the front. These are the calls every
// window switcher on the Mac relies on.
typedef int CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);
extern CFArrayRef CGSCopySpacesForWindows(CGSConnectionID cid, int mask, CFArrayRef wids);
extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID cid);
extern CGError CGSSetSymbolicHotKeyEnabled(int hotKey, bool enabled);
extern CGError CGSSetWindowBackgroundBlurRadius(CGSConnectionID cid, int windowNumber, int radius);
extern bool CGSIsSymbolicHotKeyEnabled(int hotKey);
extern CGError CGSGetSymbolicHotKeyValue(int hotKey, unsigned short *keyEquivalent, unsigned short *virtualKeyCode, unsigned int *modifiers);
extern CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);
extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *wid);
extern AXUIElementRef _AXUIElementCreateWithRemoteToken(CFDataRef token);
extern CFTypeRef _LSASNCreateWithPid(CFAllocatorRef allocator, pid_t pid);
extern CFTypeRef _LSCopyApplicationInformationItem(int session, CFTypeRef asn, CFStringRef key);

enum { kSystemAppSwitcher = 1, kSystemAppSwitcherBackwards = 2 };   // the system's own Command-Tab and its reverse
enum { kKeyTab = 48, kKeyEscape = 53, kKeyReturn = 36, kKeyLeft = 123, kKeyRight = 124, kKeyDown = 125, kKeyUp = 126 };

// While Retab answers the app-switching shortcut, the system's own switcher has to stand down:
// two cannot answer one shortcut. It is given back on every way out, a crash included.
static BOOL gTookOver;
static void SetSystemSwitcherEnabled(bool on) {
    CGSSetSymbolicHotKeyEnabled(kSystemAppSwitcher, on);
    CGSSetSymbolicHotKeyEnabled(kSystemAppSwitcherBackwards, on);
}
static void OnFatalSignal(int sig) {
    if (gTookOver) SetSystemSwitcherEnabled(true);
    signal(sig, SIG_DFL);
    raise(sig);
}

#pragma mark - One window

@interface Win : NSObject
@property CGWindowID wid;
@property pid_t pid;
@property NSString *title;
@property NSString *appName;
@property NSString *profile;   // the Chrome profile, when the title names one
@property NSImage *icon;
@property BOOL minimized;
@property id ax;               // AXUIElementRef, once we have found it
@property BOOL near;           // on the current Space
@property NSString *group;     // windows of one app (one profile, for a browser) share it
@property NSInteger count;     // how many windows the icon stands for
@property NSRunningApplication *running;
@property NSString *badge;     // what the app shows on its Dock icon: unread messages and the like
@property NSImage *avatar;     // a browser profile's account picture, when it can be told
@property NSString *email;     // ... and its account
@property NSColor *tint;       // ... and its colour in the browser; ours when the browser gives none
@property NSString *place;     // "Desktop 2", "Full screen"
@property NSString *state;     // "Minimized", "Hidden"
@end
@implementation Win
@end

// Some apps carry invisible direction marks in their names; they upset comparing and measuring.
static NSString *CleanName(NSString *name) {
    NSMutableCharacterSet *junk = [NSMutableCharacterSet characterSetWithCharactersInString:@"\u200e\u200f\u202a\u202c\ufeff"];
    [junk formUnionWithCharacterSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [name ?: @"" stringByTrimmingCharactersInSet:junk];
}

// Chromium browsers title their windows "Page - Google Chrome - Profile" once there is more than
// one profile. Take the profile out of the title, so that it can be shown as a badge.
static void SplitBrowserTitle(Win *w) {
    if (!w.title.length || !w.appName.length) return;
    for (NSString *dash in @[@" - ", @" – ", @" — "]) {
        NSString *marker = [NSString stringWithFormat:@"%@%@", dash, w.appName];
        NSRange r = [w.title rangeOfString:marker options:NSBackwardsSearch];
        if (r.location == NSNotFound) continue;
        NSString *rest = [w.title substringFromIndex:NSMaxRange(r)];
        NSString *page = [w.title substringToIndex:r.location];
        for (NSString *d in @[@" - ", @" – ", @" — "]) {
            if ([rest hasPrefix:d] && rest.length > d.length) { w.profile = [rest substringFromIndex:d.length]; break; }
        }
        if (rest.length == 0 || w.profile) w.title = page;
        return;
    }
}

// An app tells accessibility only about its windows on the current Space. The others can still be
// reached by asking for its interface elements one number at a time and keeping the windows.
// Slow (a few hundred questions), so it runs off the main thread and its finds are remembered.
static NSDictionary<NSNumber *, id> *AXWindowsByBruteForce(pid_t pid, BOOL *complete) {
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    uint8_t token[20];
    int32_t p = pid, zero = 0, magic = 0x636f636f;
    memcpy(token, &p, 4); memcpy(token + 4, &zero, 4); memcpy(token + 8, &magic, 4);
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    *complete = NO;
    for (uint64_t i = 0; ; i++) {
        if (i == 1000) { *complete = YES; break; }
        if (CFAbsoluteTimeGetCurrent() - start > 0.6) break;
        memcpy(token + 12, &i, 8);
        CFDataRef data = CFDataCreate(NULL, token, sizeof(token));
        AXUIElementRef el = _AXUIElementCreateWithRemoteToken(data);
        CFRelease(data);
        if (!el) continue;
        AXUIElementSetMessagingTimeout(el, 0.15);
        CFTypeRef v = NULL;
        if (AXUIElementCopyAttributeValue(el, kAXSubroleAttribute, &v) == kAXErrorSuccess && v) {
            NSString *subrole = CFBridgingRelease(v);
            CGWindowID wid = 0;
            if (([subrole isEqual:(id)kAXStandardWindowSubrole] || [subrole isEqual:(id)kAXDialogSubrole])
                && _AXUIElementGetWindow(el, &wid) == kAXErrorSuccess && wid) found[@(wid)] = (__bridge id)el;
        }
        CFRelease(el);
    }
    return found;
}

// Windows found that way, by window id. Main thread only.
static NSMutableDictionary<NSNumber *, id> *gFarWindows;
static NSMutableSet<NSNumber *> *gUnreachedApps;   // apps with windows we cannot even name yet
// Things that look like windows on another Space but that the app itself does not count among its
// windows: hidden helpers, off-screen caches. Switching to one does nothing, so they are left out.
static NSMutableSet<NSNumber *> *gNotWindows;

static void ReadTitle(Win *w) {
    AXUIElementRef e = (__bridge AXUIElementRef)w.ax;
    CFTypeRef v = NULL;
    if (AXUIElementCopyAttributeValue(e, kAXTitleAttribute, &v) == kAXErrorSuccess && v) {
        NSString *t = CFBridgingRelease(v);
        if (t.length) { w.title = t; w.profile = nil; }
    }
    v = NULL;
    if (AXUIElementCopyAttributeValue(e, kAXMinimizedAttribute, &v) == kAXErrorSuccess && v) w.minimized = [CFBridgingRelease(v) boolValue];
}

static BOOL WindowIsOnSomeSpace(CGWindowID wid) {
    CFArrayRef spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), 7, (__bridge CFArrayRef)@[@(wid)]);
    if (!spaces) return NO;
    BOOL any = CFArrayGetCount(spaces) > 0;
    CFRelease(spaces);
    return any;
}

// Every window worth switching to, front to back as the system reports them.
static NSArray<Win *> *ListWindows(void) {
    NSArray *info = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    pid_t me = getpid();
    NSMutableDictionary<NSNumber *, id> *apps = [NSMutableDictionary dictionary];        // pid -> NSRunningApplication or NSNull
    NSMutableDictionary<NSNumber *, NSDictionary *> *axByPid = [NSMutableDictionary dictionary];  // pid -> {wid -> AX element}
    NSMutableArray<Win *> *out = [NSMutableArray array];

    for (NSDictionary *d in info) {
        if ([d[(id)kCGWindowLayer] intValue] != 0) continue;
        if ([d[(id)kCGWindowAlpha] doubleValue] <= 0) continue;
        pid_t pid = [d[(id)kCGWindowOwnerPID] intValue];
        if (pid == me) continue;
        CGRect bounds = CGRectZero;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &bounds);
        if (bounds.size.width < 120 || bounds.size.height < 80) continue;

        id app = apps[@(pid)];
        if (!app) {
            NSRunningApplication *r = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            app = (r && r.activationPolicy == NSApplicationActivationPolicyRegular) ? r : (id)NSNull.null;
            apps[@(pid)] = app;
        }
        if (app == NSNull.null) continue;
        NSRunningApplication *running = app;

        NSDictionary *ax = axByPid[@(pid)];
        if (!ax) {
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            AXUIElementRef axApp = AXUIElementCreateApplication(pid);
            AXUIElementSetMessagingTimeout(axApp, 0.15);   // a hung app must not hang the switcher
            CFTypeRef wins = NULL;
            if (AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute, &wins) == kAXErrorSuccess && wins) {
                for (id el in (__bridge NSArray *)wins) {
                    CGWindowID awid = 0;
                    if (_AXUIElementGetWindow((__bridge AXUIElementRef)el, &awid) == kAXErrorSuccess && awid) m[@(awid)] = el;
                }
            }
            if (wins) CFRelease(wins);
            CFRelease(axApp);
            ax = axByPid[@(pid)] = m;
        }

        CGWindowID wid = [d[(id)kCGWindowNumber] unsignedIntValue];
        BOOL onScreen = [d[(id)kCGWindowIsOnscreen] boolValue];
        id el = ax[@(wid)];
        Win *w = [Win new];

        if (el) {
            CFTypeRef v = NULL;
            if (AXUIElementCopyAttributeValue((__bridge AXUIElementRef)el, kAXSubroleAttribute, &v) == kAXErrorSuccess && v) {
                NSString *subrole = CFBridgingRelease(v);
                if (![subrole isEqual:(id)kAXStandardWindowSubrole] && ![subrole isEqual:(id)kAXDialogSubrole]) continue;
            }
            w.ax = el;
            w.near = YES;
        } else {
            // Not known to the app's accessibility on this Space: either a window on another Space
            // (real, and it has a title), or one of the invisible helper windows apps keep around.
            if (onScreen && ax.count) continue;
            w.ax = gFarWindows[@(wid)];
            if (!w.ax && [gNotWindows containsObject:@(wid)]) continue;
            if (!w.ax) {
                // Retab never looks at the screen, so the system gives it no titles of other apps'
                // windows. A window on another Space is shown once accessibility has reached it;
                // until then its app is noted for the search.
                if (WindowIsOnSomeSpace(wid)) [gUnreachedApps addObject:@(pid)];
                continue;
            }
        }
        if (w.ax) ReadTitle(w);
        w.wid = wid;
        w.pid = pid;
        w.appName = CleanName(running.localizedName);
        w.icon = running.icon;
        w.running = running;
        SplitBrowserTitle(w);
        if (!w.title.length) w.title = w.appName;
        [out addObject:w];
    }
    return out;
}

static void FocusWindow(Win *w) {
    ProcessSerialNumber psn;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (GetProcessForPID(w.pid, &psn) != noErr) return;
#pragma clang diagnostic pop
    if (w.ax && w.minimized) AXUIElementSetAttributeValue((__bridge AXUIElementRef)w.ax, kAXMinimizedAttribute, kCFBooleanFalse);
    // Bring this one window forward (the system moves to its Space by itself) ...
    _SLPSSetFrontProcessWithOptions(&psn, w.wid, 0x200);
    // ... and make it the window that takes the keys.
    uint8_t bytes[0xf8] = {0};
    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;
    CGWindowID wid = w.wid;
    memcpy(bytes + 0x3c, &wid, sizeof(wid));
    memset(bytes + 0x20, 0xff, 0x10);
    bytes[0x08] = 0x01;
    SLPSPostEventRecordTo(&psn, bytes);
    bytes[0x08] = 0x02;
    SLPSPostEventRecordTo(&psn, bytes);
    if (w.ax) AXUIElementPerformAction((__bridge AXUIElementRef)w.ax, kAXRaiseAction);
}

// The red label an app puts on its Dock icon — "3" unread, say. The Dock's own switcher shows it too.
static NSString *DockBadge(pid_t pid) {
    CFTypeRef asn = _LSASNCreateWithPid(NULL, pid);
    if (!asn) return nil;
    NSDictionary *status = CFBridgingRelease(_LSCopyApplicationInformationItem(-2, asn, CFSTR("StatusLabel")));
    CFRelease(asn);
    if (![status isKindOfClass:NSDictionary.class]) return nil;
    id label = status[@"label"];
    NSString *text = [label isKindOfClass:NSString.class] ? label : [label respondsToSelector:@selector(stringValue)] ? [label stringValue] : nil;
    return text.length ? text : nil;
}

// What Chrome keeps about its profiles: the account, its picture, the colour chosen for it.
@interface BrowserProfile : NSObject
@property NSString *dir;        // its folder: the one thing no two profiles share
@property NSString *name;       // the name the user gave the profile
@property NSString *givenName;  // the account's first name
@property NSString *fullName;   // the account's full name
@property NSString *email;
@property NSImage *picture;     // the account's picture, when the profile is set to show it
@property NSColor *color;       // the colour the profile is given in the browser itself
@end
@implementation BrowserProfile
@end

static NSArray<BrowserProfile *> *ChromeProfiles(void) {
    static NSArray<BrowserProfile *> *cache;
    static CFAbsoluteTime read;
    if (cache && CFAbsoluteTimeGetCurrent() - read < 60) return cache;
    read = CFAbsoluteTimeGetCurrent();
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Google/Chrome"];
    NSData *data = [NSData dataWithContentsOfFile:[base stringByAppendingPathComponent:@"Local State"]];
    NSDictionary *state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *profiles = [state isKindOfClass:NSDictionary.class] ? state[@"profile"][@"info_cache"] : nil;
    NSMutableArray<BrowserProfile *> *all = [NSMutableArray array];
    if ([profiles isKindOfClass:NSDictionary.class]) {
        for (NSString *dir in profiles) {
            NSDictionary *info = profiles[dir];
            if (![info isKindOfClass:NSDictionary.class]) continue;
            NSString *(^text)(NSString *) = ^NSString *(NSString *key) {
                id v = info[key];
                return ([v isKindOfClass:NSString.class] && [v length]) ? v : nil;
            };
            BrowserProfile *profile = [BrowserProfile new];
            profile.dir = dir;
            NSColor *(^colour)(NSString *) = ^NSColor *(NSString *key) {
                NSNumber *n = info[key];   // a signed ARGB number
                if (![n isKindOfClass:NSNumber.class]) return nil;
                uint32_t argb = (uint32_t)n.intValue;
                return [NSColor colorWithSRGBRed:((argb >> 16) & 255) / 255.0 green:((argb >> 8) & 255) / 255.0 blue:(argb & 255) / 255.0 alpha:1];
            };
            profile.name = text(@"name");
            profile.givenName = text(@"gaia_given_name");
            profile.fullName = text(@"gaia_name");
            profile.email = text(@"user_name");
            // The account's picture, by Chrome's own rule: when the profile is set to use it, and also
            // when the profile's avatar was never chosen — Chrome then prefers the account's picture
            // to its grey placeholder. A stock avatar picked on purpose is left alone.
            NSString *file = text(@"gaia_picture_file_name");
            BOOL usesPicture = [info[@"use_gaia_picture"] boolValue] || [info[@"is_using_default_avatar"] boolValue];
            if (usesPicture && file && ![file containsString:@"/"])
                profile.picture = [[NSImage alloc] initWithContentsOfFile:[[base stringByAppendingPathComponent:dir] stringByAppendingPathComponent:file]];
            profile.color = colour(@"profile_color_seed");   // the theme colour chosen for the profile
            [all addObject:profile];
        }
    }
    return cache = all;
}

// The profiles a window's title may mean. Chrome writes the profile's own name, or the account's
// name, or "Account (profile)", depending on what tells its profiles apart. Two profiles with one
// name get the very same label, and then both come back.
static NSArray<BrowserProfile *> *ChromeProfilesNamed(NSString *label) {
    NSArray<BrowserProfile *> *all = ChromeProfiles();
    NSString *inner = nil;
    NSRange open = [label rangeOfString:@" (" options:NSBackwardsSearch];
    if (open.location != NSNotFound && [label hasSuffix:@")"])
        inner = [label substringWithRange:NSMakeRange(NSMaxRange(open), label.length - NSMaxRange(open) - 1)];
    NSArray<NSArray<BrowserProfile *> *> *tries = @[
        [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(BrowserProfile *p, id b) { return inner && [p.name isEqual:inner]; }]],
        [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(BrowserProfile *p, id b) { return [p.name isEqual:label]; }]],
        [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(BrowserProfile *p, id b) { return [p.givenName isEqual:label] || [p.fullName isEqual:label]; }]]];
    for (NSArray<BrowserProfile *> *found in tries) if (found.count) return found;
    return @[];
}

// The profile a browser window belongs to. Two profiles with the same name get the very same title,
// and Retab does not look at the window itself, so for those there is no telling: nil.
static BrowserProfile *ChromeProfileOfWindow(Win *w) {
    NSArray<BrowserProfile *> *candidates = ChromeProfilesNamed(w.profile);
    return candidates.count == 1 ? candidates.firstObject : nil;
}

// Where a window is: which desktop, or a full-screen space of its own; and on which display, when
// there is more than one.
static NSString *PlaceOfWindow(CGWindowID wid, NSArray *displays) {
    NSArray *spaces = CFBridgingRelease(CGSCopySpacesForWindows(CGSMainConnectionID(), 7, (__bridge CFArrayRef)@[@(wid)]));
    NSNumber *space = spaces.firstObject;
    if (!space) return nil;
    for (NSDictionary *display in displays) {
        NSInteger desktop = 0;
        for (NSDictionary *sp in display[@"Spaces"]) {
            BOOL plain = [sp[@"type"] intValue] == 0;
            if (plain) desktop++;
            if (![sp[@"ManagedSpaceID"] isEqual:space] && ![sp[@"id64"] isEqual:space]) continue;
            NSString *place = plain ? [NSString stringWithFormat:@"Desktop %ld", (long)desktop] : @"Full screen";
            if (displays.count < 2) return place;
            for (NSScreen *screen in NSScreen.screens) {
                CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
                NSString *identifier = uuid ? CFBridgingRelease(CFUUIDCreateString(NULL, uuid)) : nil;
                if (uuid) CFRelease(uuid);
                if ([identifier isEqual:display[@"Display Identifier"]]) return [NSString stringWithFormat:@"%@, %@", place, screen.localizedName];
            }
            return place;
        }
    }
    return nil;
}

#pragma mark - The panel

static NSColor *ProfileColor(NSString *name) {
    static NSArray<NSColor *> *palette;
    if (!palette) palette = @[
        [NSColor colorWithSRGBRed:0.24 green:0.52 blue:0.96 alpha:1], [NSColor colorWithSRGBRed:0.20 green:0.66 blue:0.42 alpha:1],
        [NSColor colorWithSRGBRed:0.90 green:0.45 blue:0.18 alpha:1], [NSColor colorWithSRGBRed:0.66 green:0.36 blue:0.90 alpha:1],
        [NSColor colorWithSRGBRed:0.88 green:0.30 blue:0.42 alpha:1], [NSColor colorWithSRGBRed:0.12 green:0.62 blue:0.68 alpha:1],
        [NSColor colorWithSRGBRed:0.80 green:0.62 blue:0.10 alpha:1], [NSColor colorWithSRGBRed:0.45 green:0.50 blue:0.58 alpha:1]];
    static NSMutableDictionary<NSString *, NSNumber *> *given;
    if (!given) given = [NSMutableDictionary dictionary];
    if (!given[name]) given[name] = @(given.count % palette.count);
    return palette[given[name].unsignedIntegerValue];
}

// What a music app is playing, by the app's bundle id. The apps announce it themselves whenever it
// changes, to anyone listening; nothing is asked of them, so nothing is known until the first change.
static NSMutableDictionary<NSString *, NSString *> *gNowPlaying;

static NSColor *TintOf(Win *w) { return w.tint ?: ProfileColor(w.profile); }

// Black or white, whichever reads on the colour: a browser's profile colours are often pale.
static NSColor *TextOn(NSColor *fill) {
    NSColor *c = [fill colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent;
    return luminance > 0.6 ? [NSColor colorWithWhite:0.08 alpha:1] : NSColor.whiteColor;
}

@class SwitcherView;
@protocol SwitcherViewDelegate
- (void)switcherView:(SwitcherView *)view hovered:(NSInteger)index;
- (void)switcherView:(SwitcherView *)view clicked:(NSInteger)index;
@end

@interface SwitcherView : NSView
@property (nonatomic) NSArray<Win *> *items;
@property (nonatomic) NSInteger selected;
@property (nonatomic) NSInteger columns;
@property (nonatomic) CGFloat scale;
@property (readonly) CGFloat headerHeight;
@property BOOL backdrop;   // paint an opaque background: for the saved demo picture, which has no screen behind it
@property (weak) id<SwitcherViewDelegate> delegate;
@end

static const CGFloat kCellW = 90, kCellH = 90, kIcon = 66;      // at scale 1; the panel starts at 1.7
static const CGFloat kSide = 30, kTop = 30, kBottom = 20;       // room around the title and the row
static const CGFloat kTitleSize = 34, kSubtitleSize = 16, kPaneRadius = 30;

// The panel: a title and a subtitle about the selected icon, and under them a row of icons, as in
// the system's switcher. The row wraps to more rows when there are too many icons. The pane itself
// is painted here — a thin dark wash over the screen, which the window server blurs behind it.
@implementation SwitcherView {
    NSRect _glideFrom, _glideTo, _glide;   // the selection on its way from one icon to the next
    CFAbsoluteTime _glideStart;
    NSTimer *_glideTimer;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas.copy) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}

- (NSRect)selectionRect:(NSInteger)i { return NSInsetRect([self cellRect:i], 3 * _scale, 3 * _scale); }

- (void)stopGlide { [_glideTimer invalidate]; _glideTimer = nil; }

- (NSRect)cellRect:(NSInteger)i {
    CGFloat w = kCellW * _scale, h = kCellH * _scale;
    return NSMakeRect(kSide + (i % _columns) * w, kTop + self.headerHeight + (i / _columns) * h, w, h);
}

- (NSInteger)indexAt:(NSPoint)p {
    for (NSInteger i = 0; i < (NSInteger)_items.count; i++) if (NSPointInRect(p, [self cellRect:i])) return i;
    return -1;
}

- (void)mouseMoved:(NSEvent *)e {
    NSInteger i = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i >= 0 && i != _selected) [_delegate switcherView:self hovered:i];
}

- (void)mouseDown:(NSEvent *)e {
    NSInteger i = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i >= 0) [_delegate switcherView:self clicked:i];
}

- (CGFloat)headerHeight { return kTitleSize * 1.22 + kSubtitleSize * 1.3 + 16; }

// The selection does not jump: it glides to the next icon, quickly, slowing as it arrives.
- (void)setSelected:(NSInteger)selected {
    NSInteger old = _selected, n = _items.count;
    _selected = selected;
    self.needsDisplay = YES;
    if (old == selected || old < 0 || old >= n || selected < 0 || selected >= n || !self.window.isVisible) { [self stopGlide]; return; }
    _glideFrom = _glideTimer ? _glide : [self selectionRect:old];
    _glideTo = [self selectionRect:selected];
    _glide = _glideFrom;
    _glideStart = CFAbsoluteTimeGetCurrent();
    if (_glideTimer) return;
    __weak SwitcherView *weak = self;
    _glideTimer = [NSTimer timerWithTimeInterval:1.0 / 120 repeats:YES block:^(NSTimer *t) {
        SwitcherView *me = weak;
        if (!me) { [t invalidate]; return; }
        CGFloat p = (CFAbsoluteTimeGetCurrent() - me->_glideStart) / 0.10;
        if (p >= 1) { [me stopGlide]; me.needsDisplay = YES; return; }
        CGFloat e = 1 - pow(1 - p, 3);
        me->_glide = NSMakeRect(me->_glideFrom.origin.x + (me->_glideTo.origin.x - me->_glideFrom.origin.x) * e,
                                me->_glideFrom.origin.y + (me->_glideTo.origin.y - me->_glideFrom.origin.y) * e,
                                me->_glideTo.size.width, me->_glideTo.size.height);
        me.needsDisplay = YES;
    }];
    [NSRunLoop.mainRunLoop addTimer:_glideTimer forMode:NSRunLoopCommonModes];
}

// A large title with a subtitle under it, left-aligned above the icons, in the system's own type.
- (void)drawHeader {
    if (_selected < 0 || _selected >= (NSInteger)_items.count) return;
    Win *w = _items[_selected];
    NSMutableParagraphStyle *tail = [NSMutableParagraphStyle new];
    tail.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableParagraphStyle *centered = [tail mutableCopy];
    centered.alignment = NSTextAlignmentCenter;
    NSDictionary *titleAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:kTitleSize weight:NSFontWeightBold],
                                 NSForegroundColorAttributeName: NSColor.labelColor, NSParagraphStyleAttributeName: tail};
    CGFloat subSize = kSubtitleSize;
    NSDictionary *subAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:subSize weight:NSFontWeightRegular],
                               NSForegroundColorAttributeName: NSColor.secondaryLabelColor, NSParagraphStyleAttributeName: tail};
    NSDictionary *pillAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:subSize - 1 weight:NSFontWeightSemibold],
                                NSForegroundColorAttributeName: NSColor.whiteColor, NSParagraphStyleAttributeName: centered};
    // The text starts where the first icon's picture starts. An icon's artwork sits a little inside
    // its square, hence the extra step. The selection reaches further out, into the side margin.
    NSRect first = [self cellRect:0];
    CGFloat side = kIcon * _scale;
    CGFloat x = first.origin.x + (first.size.width - side) / 2 + side * 0.085, room = self.bounds.size.width - 2 * x, y = kTop;
    NSSize ts = [w.appName sizeWithAttributes:titleAttrs];
    CGFloat tw = MIN(ts.width + 1, room);
    [w.appName drawInRect:NSMakeRect(x, y, tw, ts.height) withAttributes:titleAttrs];
    if (w.profile) {
        CGFloat ph = round(subSize * 1.7), pw = [w.profile sizeWithAttributes:pillAttrs].width + ph;
        if (tw + 14 + pw <= room) DrawPill(w.profile, NSMakeRect(x + tw + 14, y + ts.height / 2 - ph / 2 + 2, pw, ph), TintOf(w), pillAttrs);
    }
    // The subtitle says where this icon leads: the window, whose it is, how many more there are,
    // what state it is in and where it is.
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *playing = gNowPlaying[w.running.bundleIdentifier ?: @""];
    if (playing.length) [parts addObject:playing];
    else if (w.wid && w.title.length && ![CleanName(w.title) isEqual:w.appName]) [parts addObject:w.title];
    if (w.email.length) [parts addObject:w.email];
    if (w.count > 1) [parts addObject:[NSString stringWithFormat:@"%ld windows", (long)w.count]];
    if (w.state.length) [parts addObject:w.state];
    if (w.place.length) [parts addObject:w.place];
    if (w.badge.length) [parts addObject:[NSString stringWithFormat:@"%@ new", w.badge]];
    if (!w.wid) [parts addObject:@"No windows"];
    else if (!parts.count) [parts addObject:@"1 window"];
    NSString *sub = [parts componentsJoinedByString:@"  ·  "];
    [sub drawInRect:NSMakeRect(x, y + ts.height + 2, room, subSize * 1.3) withAttributes:subAttrs];
}
- (void)setItems:(NSArray<Win *> *)items { [self stopGlide]; _items = items; self.needsDisplay = YES; }

static void DrawPill(NSString *text, NSRect pill, NSColor *fill, NSDictionary *attrs) {
    NSMutableDictionary *readable = [attrs mutableCopy];
    readable[NSForegroundColorAttributeName] = TextOn(fill);
    attrs = readable;
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:pill.size.height / 2 yRadius:pill.size.height / 2] fill];
    CGFloat h = [text sizeWithAttributes:attrs].height;
    [text drawInRect:NSMakeRect(pill.origin.x, NSMidY(pill) - h / 2, pill.size.width, h) withAttributes:attrs];
}

- (void)drawRect:(NSRect)dirty {
    if (_backdrop) { [[NSColor colorWithWhite:0.13 alpha:1] setFill]; NSRectFill(self.bounds); }
    // The pane: a wash of near-black, thin enough for the blurred screen to show through, and a
    // faint hairline along the rim.
    NSBezierPath *pane = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:kPaneRadius yRadius:kPaneRadius];
    [[NSColor colorWithWhite:0.06 alpha:0.38] setFill];
    [pane fill];
    [[NSColor colorWithWhite:1 alpha:0.10] setStroke];
    pane.lineWidth = 1;
    [pane stroke];

    CGFloat s = _scale;
    NSMutableParagraphStyle *centered = [NSMutableParagraphStyle new];
    centered.lineBreakMode = NSLineBreakByTruncatingTail;
    centered.alignment = NSTextAlignmentCenter;
    NSDictionary *badgeAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:9.5 * s weight:NSFontWeightSemibold],
                                 NSForegroundColorAttributeName: NSColor.whiteColor, NSParagraphStyleAttributeName: centered};
    NSDictionary *letterAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11 * s weight:NSFontWeightBold],
                                  NSForegroundColorAttributeName: NSColor.whiteColor, NSParagraphStyleAttributeName: centered};

    for (NSInteger i = 0; i < (NSInteger)_items.count; i++) {
        Win *w = _items[i];
        NSRect cell = [self cellRect:i];
        if (i == _selected) {
            [[NSColor colorWithWhite:1 alpha:0.14] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:_glideTimer ? _glide : [self selectionRect:i] xRadius:18 * s yRadius:18 * s] fill];
        }
        CGFloat side = kIcon * s;
        NSRect icon = NSMakeRect(NSMidX(cell) - side / 2, NSMidY(cell) - side / 2, side, side);
        [w.icon drawInRect:icon fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];

        // An icon's artwork sits a little inside its square; the marks hug the artwork, not the square.
        CGFloat inset = side * 0.11;
        // A browser profile, on the lower corner: the account's picture, or a coloured disc with
        // the profile's first letter.
        if (w.profile.length) {
            CGFloat d = 24 * s;
            NSRect disc = NSMakeRect(NSMaxX(icon) - inset - d * 0.62, NSMaxY(icon) - inset - d * 0.62, d, d);
            [[NSColor colorWithWhite:0 alpha:0.35] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(disc, -1.5 * s, -1.5 * s)] fill];
            if (w.avatar) {
                [NSGraphicsContext saveGraphicsState];
                [[NSBezierPath bezierPathWithOvalInRect:disc] addClip];
                [w.avatar drawInRect:disc fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
                      respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
                [NSGraphicsContext restoreGraphicsState];
                [TintOf(w) setStroke];
                NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(disc, 0.75 * s, 0.75 * s)];
                ring.lineWidth = 1.5 * s;
                [ring stroke];
            } else {
                NSString *letter = [w.profile substringWithRange:[w.profile rangeOfComposedCharacterSequenceAtIndex:0]].localizedUppercaseString;
                DrawPill(letter, disc, TintOf(w), letterAttrs);
            }
        }
        // What the app shows on its Dock icon, on the upper corner, as the Dock has it.
        if (w.badge.length) {
            NSString *text = w.badge.length > 4 ? [[w.badge substringToIndex:3] stringByAppendingString:@"…"] : w.badge;
            CGFloat bh = 16 * s, bw = MAX(bh, [text sizeWithAttributes:badgeAttrs].width + 10 * s);
            DrawPill(text, NSMakeRect(NSMaxX(icon) - inset - bw * 0.62, icon.origin.y + inset - bh * 0.38, bw, bh),
                     [NSColor colorWithSRGBRed:0.96 green:0.26 blue:0.21 alpha:1], badgeAttrs);
        }
    }

    [self drawHeader];
}
@end

@interface SwitcherPanel : NSPanel
@end
@implementation SwitcherPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

#pragma mark - The app

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, SwitcherViewDelegate>
- (void)hotKey:(UInt32)which;
@end

// Retab does not listen to the keyboard. It asks the system for a handful of shortcuts — the
// same way any app gets a global shortcut — and the system calls back when one is pressed. Every
// other key and shortcut goes its usual way and never passes through this app.
enum { kHotNext = 1, kHotPrevious, kHotEscape, kHotReturn, kHotLeft, kHotRight, kHotUp, kHotDown };

static OSStatus HotKeyPressed(EventHandlerCallRef next, EventRef event, void *refcon) {
    EventHotKeyID hot;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hot), NULL, &hot) == noErr)
        [(__bridge AppDelegate *)refcon hotKey:hot.id];
    return noErr;
}

@implementation AppDelegate {
    NSStatusItem *_statusItem;
    BOOL _trusted;       // Accessibility is allowed
    UInt32 _key, _carbonModifiers;   // the shortcut in use: the key, and its modifiers the way Carbon counts them
    CGEventFlags _heldFlags;         // ... and the way key state counts them: the switch ends when they are let go
    EventHotKeyRef _nextKey, _previousKey;
    BOOL _testing, _testFired;
    BOOL _demo;
    NSMutableArray<NSValue *> *_navKeys;   // the shortcuts that exist only while the panel is up
    NSTimer *_releaseTimer;
    CFAbsoluteTime _lastReach;
    SwitcherPanel *_panel;
    SwitcherView *_view;
    NSArray<Win *> *_items;
    NSInteger _selected;
    BOOL _active;        // the modifier is held and a list is built
    BOOL _shown;         // ... and the panel is on screen
    NSUInteger _round;   // tells a late "show" or "hide" that its switch is over
    NSMutableArray<NSNumber *> *_recent;                   // window ids, most recently used first
    NSMutableSet<NSNumber *> *_searching;                  // apps being searched for far windows right now
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    _recent = [NSMutableArray array];
    // `Retab --dump <file>` asks this running copy to write its diagnostics there. For debugging;
    // the file holds window titles, so whoever asks for it should also delete it.
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"app.retab.mac.dump" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:NSString.class]) [[self diagnostics] writeToFile:note.object atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }];
    gNowPlaying = [NSMutableDictionary dictionary];
    for (NSArray<NSString *> *player in @[@[@"com.apple.Music.playerInfo", @"com.apple.Music"], @[@"com.spotify.client.PlaybackStateChanged", @"com.spotify.client"]]) {
        [NSDistributedNotificationCenter.defaultCenter addObserverForName:player[0] object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            NSString *state = note.userInfo[@"Player State"], *name = note.userInfo[@"Name"], *artist = note.userInfo[@"Artist"];
            if (![name isKindOfClass:NSString.class] || !name.length || [state isEqual:@"Stopped"]) { [gNowPlaying removeObjectForKey:player[1]]; return; }
            NSString *track = ([artist isKindOfClass:NSString.class] && artist.length) ? [NSString stringWithFormat:@"%@ — %@", name, artist] : name;
            gNowPlaying[player[1]] = [state isEqual:@"Playing"] ? [@"♪  " stringByAppendingString:track] : [@"Paused:  " stringByAppendingString:track];
        }];
    }
    _searching = [NSMutableSet set];
    gFarWindows = [NSMutableDictionary dictionary];
    gUnreachedApps = [NSMutableSet set];
    gNotWindows = [NSMutableSet set];

    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    _statusItem.menu = menu;
    [self refreshIcon];

    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(appActivated:)
                                                           name:NSWorkspaceDidActivateApplicationNotification object:nil];

    // No app may keep us waiting for long, hung or not.
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(systemWide, 0.25);
    CFRelease(systemWide);
    Log(@"Retab %@ started; accessibility %@", [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        AXIsProcessTrusted() ? @"allowed" : @"not allowed");

    // `Retab --demo <file.png>` shows the panel once without touching the keyboard, saves a
    // picture of it and quits. For checking the look without granting anything.
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    if (args.count > 2 && [args[1] isEqual:@"--demo"]) {
        _demo = YES;
        [self beginSwitch:NO];
        for (NSInteger i = 0; i < (NSInteger)_items.count; i++) if (_items[i].profile) { _selected = i; break; }   // one with something to say
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_view.backdrop = YES;   // the saved picture has no screen behind it
            NSBitmapImageRep *rep = [self->_view bitmapImageRepForCachingDisplayInRect:self->_view.bounds];
            [self->_view cacheDisplayInRect:self->_view.bounds toBitmapImageRep:rep];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:args[2] atomically:YES];
            [NSApp terminate:nil];
        });
        return;
    }

    // Ask for the one permission the first time; macOS shows its own dialog. (Not in the demo: run
    // from a terminal, the request would be made in the terminal's name.)
    if (!AXIsProcessTrusted()) AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt: @YES});

    EventTypeSpec pressed = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallEventHandler(GetApplicationEventTarget(), HotKeyPressed, 1, &pressed, (__bridge void *)self, NULL);
    _navKeys = [NSMutableArray array];
    for (NSNumber *sig in @[@(SIGINT), @(SIGTERM), @(SIGHUP), @(SIGSEGV), @(SIGABRT), @(SIGBUS), @(SIGILL)]) signal(sig.intValue, OnFatalSignal);
    [self useOptionTab];   // until Accessibility is allowed and the system's shortcut is proven to reach us

    [self syncPermissions];
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) { [self syncPermissions]; }];
}

- (void)applicationWillTerminate:(NSNotification *)n {
    if (gTookOver) SetSystemSwitcherEnabled(true);
}

#pragma mark Keys

static UInt32 CarbonModifiers(CGEventFlags flags) {
    return ((flags & kCGEventFlagMaskCommand) ? cmdKey : 0) | ((flags & kCGEventFlagMaskShift) ? shiftKey : 0)
         | ((flags & kCGEventFlagMaskAlternate) ? optionKey : 0) | ((flags & kCGEventFlagMaskControl) ? controlKey : 0);
}

static NSString *ShortcutName(UInt32 key, CGEventFlags flags) {
    return [NSString stringWithFormat:@"%@%@%@%@%@", (flags & kCGEventFlagMaskControl) ? @"Control-" : @"", (flags & kCGEventFlagMaskAlternate) ? @"Option-" : @"",
            (flags & kCGEventFlagMaskShift) ? @"Shift-" : @"", (flags & kCGEventFlagMaskCommand) ? @"Command-" : @"",
            key == kKeyTab ? @"Tab" : [NSString stringWithFormat:@"key %u", (unsigned)key]];
}

- (void)setShortcut:(UInt32)key flags:(CGEventFlags)flags {
    if (_nextKey) UnregisterEventHotKey(_nextKey);
    if (_previousKey) UnregisterEventHotKey(_previousKey);
    _key = key;
    _heldFlags = flags;
    _carbonModifiers = CarbonModifiers(flags);
    _nextKey = [self registerKey:key modifiers:_carbonModifiers which:kHotNext];
    _previousKey = [self registerKey:key modifiers:_carbonModifiers | shiftKey which:kHotPrevious];
    Log(@"shortcut: %@ %@", ShortcutName(key, flags), _nextKey ? @"registered" : @"could NOT be registered");
}

- (void)useOptionTab {
    if (gTookOver) { SetSystemSwitcherEnabled(true); gTookOver = NO; }
    [self setShortcut:kKeyTab flags:kCGEventFlagMaskAlternate];
}

// Takes the shortcut this Mac uses for switching apps — whatever it is set to — instead of making
// the user learn another one. The system's switcher is switched off for as long as we run. Then we
// check that the shortcut really reaches us, by pressing it ourselves once: if the system does not
// hand it over, everything is put back and Retab stays on Option-Tab.
- (void)adoptSystemShortcut {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"keepOptionTab"]) return;
    unsigned short equivalent = 0, key = 0;
    unsigned int flags = 0;
    if (CGSGetSymbolicHotKeyValue(kSystemAppSwitcher, &equivalent, &key, &flags) != kCGErrorSuccess || !(flags & 0x1E0000)) {
        key = kKeyTab;
        flags = kCGEventFlagMaskCommand;
    }
    flags &= kCGEventFlagMaskCommand | kCGEventFlagMaskShift | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl;
    Log(@"the system switches apps with %@; taking it over", ShortcutName(key, flags));
    SetSystemSwitcherEnabled(false);
    gTookOver = YES;
    [self setShortcut:key flags:flags];

    _testing = YES;
    _testFired = NO;
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key, true), up = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key, false);
    CGEventSetFlags(down, flags);
    CGEventSetFlags(up, flags);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_testing = NO;
        if (self->_testFired) { Log(@"shortcut test: the system handed it over"); return; }
        Log(@"shortcut test: FAILED, the system keeps it; back to Option-Tab");
        [self useOptionTab];
    });
}

- (EventHotKeyRef)registerKey:(UInt32)key modifiers:(UInt32)modifiers which:(UInt32)which {
    EventHotKeyRef ref = NULL;
    EventHotKeyID hot = {'RTAB', which};
    RegisterEventHotKey(key, modifiers, hot, GetApplicationEventTarget(), 0, &ref);
    return ref;
}

- (void)syncPermissions {
    BOOL trusted = AXIsProcessTrusted();
    if (trusted == _trusted) return;
    _trusted = trusted;
    Log(@"accessibility %@", trusted ? @"allowed" : @"not allowed");
    [self refreshIcon];
    if (trusted) {
        [self reachFarWindows:ListWindows()];   // warm up, so the first switch already has it all
        [self adoptSystemShortcut];
    } else if (gTookOver) {
        [self useOptionTab];
    }
}

- (void)hotKey:(UInt32)which {
    if (_testing) { _testFired = YES; return; }
    if (!_active) {
        if (which == kHotNext || which == kHotPrevious) [self beginSwitch:which == kHotPrevious];
        return;
    }
    switch (which) {
        case kHotNext:     [self step:1]; break;
        case kHotPrevious: [self step:-1]; break;
        case kHotRight:    [self step:1]; break;
        case kHotLeft:     [self step:-1]; break;
        case kHotDown:     [self step:_view.columns]; break;
        case kHotUp:       [self step:-_view.columns]; break;
        case kHotReturn:   [self commit]; break;
        case kHotEscape:   [self endSwitch]; break;
    }
}

#pragma mark Switching

- (void)appActivated:(NSNotification *)n {
    NSRunningApplication *app = n.userInfo[NSWorkspaceApplicationKey];
    if (!app || app.processIdentifier == getpid()) return;
    if (_trusted && !_active && CFAbsoluteTimeGetCurrent() - _lastReach > 5) {
        _lastReach = CFAbsoluteTimeGetCurrent();
        [self reachFarWindows:ListWindows()];
    }
    // The front window of the app that just came forward is the most recently used one.
    NSArray *info = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *d in info) {
        if ([d[(id)kCGWindowLayer] intValue] != 0 || [d[(id)kCGWindowOwnerPID] intValue] != app.processIdentifier) continue;
        [self touch:[d[(id)kCGWindowNumber] unsignedIntValue]];
        break;
    }
}

- (void)touch:(CGWindowID)wid {
    [_recent removeObject:@(wid)];
    [_recent insertObject:@(wid) atIndex:0];
}

- (void)beginSwitch:(BOOL)backwards {
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    NSArray<Win *> *all = ListWindows();
    Log(@"switch: %lu windows listed in %.0f ms", (unsigned long)all.count, (CFAbsoluteTimeGetCurrent() - t0) * 1000);
    // The window in front right now is where we are; it goes first whatever the history says.
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    Win *here = nil;
    for (Win *w in all) if (w.pid == front.processIdentifier && (w.near || !here)) { here = w; if (w.near) break; }
    if (here) [self touch:here.wid];

    // Most recently used first; windows we have never seen follow in the system's own order.
    NSMutableArray<Win *> *sorted = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, Win *> *byId = [NSMutableDictionary dictionary];
    for (Win *w in all) byId[@(w.wid)] = w;
    for (NSNumber *wid in _recent.copy) {
        Win *w = byId[wid];
        if (w) { [sorted addObject:w]; [byId removeObjectForKey:wid]; }
        else { [_recent removeObject:wid]; [gFarWindows removeObjectForKey:wid]; }
    }
    for (Win *w in all) if (byId[@(w.wid)]) [sorted addObject:w];

    if (_demo) {   // the demo cannot read real profiles; pretend, so that their labels can be seen
        NSArray<NSString *> *sample = @[@"Personal", @"Work", @"Client"];
        NSUInteger k = 0;
        for (Win *w in sorted) if ([w.appName isEqual:@"Google Chrome"]) w.profile = sample[k++ % sample.count];
    }

    // One icon per app — and per profile, for a browser. It stands for the most recently used
    // window of that app or profile, so the icons come in the order their windows were used.
    NSMutableArray<Win *> *icons = [NSMutableArray array];
    NSArray *displays = CFBridgingRelease(CGSCopyManagedDisplaySpaces(CGSMainConnectionID()));
    NSMutableDictionary<NSString *, Win *> *byGroup = [NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *withWindows = [NSMutableSet set];
    for (Win *w in sorted) {
        BrowserProfile *profile = (w.profile && [w.running.bundleIdentifier isEqual:@"com.google.Chrome"]) ? ChromeProfileOfWindow(w) : nil;
        if (profile) {
            w.avatar = profile.picture;
            w.email = profile.email;
            w.tint = profile.color;
            if (profile.name.length) w.profile = profile.name;   // the profile's own name: shorter than "Account (profile)"
        }
        NSString *key = [NSString stringWithFormat:@"%d|%@|%@", w.pid, w.profile ?: @"", profile.dir ?: @""];
        [withWindows addObject:@(w.pid)];
        if (byGroup[key]) { byGroup[key].count++; continue; }
        w.group = key;
        w.count = 1;
        w.badge = DockBadge(w.pid);
        w.place = PlaceOfWindow(w.wid, displays);
        w.state = w.running.hidden ? @"Hidden" : w.minimized ? @"Minimized" : nil;
        byGroup[key] = w;
        [icons addObject:w];
    }
    // Apps that run without a single window are left out: there is nothing in them to switch to,
    // and they only make the row longer. `defaults write app.retab.mac showWindowless -bool YES`
    // brings them back, as in the system's switcher.
    BOOL windowless = [NSUserDefaults.standardUserDefaults boolForKey:@"showWindowless"];
    for (NSRunningApplication *app in windowless ? NSWorkspace.sharedWorkspace.runningApplications : @[]) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular || app.processIdentifier == getpid()) continue;
        if ([withWindows containsObject:@(app.processIdentifier)]) continue;
        Win *w = [Win new];
        w.pid = app.processIdentifier;
        w.appName = CleanName(app.localizedName);
        w.title = w.appName;
        w.icon = app.icon;
        w.running = app;
        w.badge = DockBadge(w.pid);
        [icons addObject:w];
    }
    sorted = icons;
    Win *previous = sorted.count > 1 ? sorted[1] : nil;
    _items = sorted;
    _active = YES;
    _shown = NO;
    // A quick tap goes to the app (or profile) used before this one, as in the system's switcher.
    _selected = backwards ? (NSInteger)sorted.count - 1 : (previous ? (NSInteger)[sorted indexOfObject:previous] : 0);
    NSUInteger round = ++_round;
    [self reachFarWindows:sorted];

    // While the modifier is down, a few more shortcuts move around the panel. They are gone the moment
    // the switch ends.
    if (!_demo) {
        UInt32 keys[][2] = {{kKeyEscape, kHotEscape}, {kKeyReturn, kHotReturn}, {kKeyLeft, kHotLeft}, {kKeyRight, kHotRight}, {kKeyUp, kHotUp}, {kKeyDown, kHotDown}};
        for (int i = 0; i < 6; i++) {
            EventHotKeyRef ref = [self registerKey:keys[i][0] modifiers:_carbonModifiers which:keys[i][1]];
            if (ref) [_navKeys addObject:[NSValue valueWithPointer:ref]];
        }
        // Letting go of the modifier makes the switch. We look at the state of the key, not at key presses.
        _releaseTimer = [NSTimer timerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *t) {
            if ((CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & self->_heldFlags) != self->_heldFlags) [self commit];
        }];
        [NSRunLoop.mainRunLoop addTimer:_releaseTimer forMode:NSRunLoopCommonModes];
    }

    // A quick tap switches to the previous window without the panel ever flashing up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.09 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_active && self->_round == round) [self showPanel];
    });
}

- (void)step:(NSInteger)delta {
    NSInteger n = _items.count;
    if (!n) return;
    _selected = ((_selected + delta) % n + n) % n;
    if (!_shown) [self showPanel];
    _view.selected = _selected;
}

- (void)commit {
    Win *w = (_selected >= 0 && _selected < (NSInteger)_items.count) ? _items[_selected] : nil;
    BOOL was = _active;
    [self endSwitch];
    if (!w || !was) return;
    if (w.wid) [self touch:w.wid];
    Log(@"switch: to window %u of %@ (%@)", w.wid, w.appName, w.near ? @"this space" : (w.ax ? @"other space" : @"other space, not reached"));
    if (w.wid) FocusWindow(w);
    // An app without a window is simply brought forward — and so is one whose window would not come.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((w.wid ? 0.25 : 0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == w.pid) return;
        if (w.wid) Log(@"switch: window %u did not come forward; activating %@ instead", w.wid, w.appName);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [w.running activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
    });
}

- (void)endSwitch {
    [_releaseTimer invalidate];
    _releaseTimer = nil;
    for (NSValue *v in _navKeys) UnregisterEventHotKey(v.pointerValue);
    [_navKeys removeAllObjects];
    _active = NO;
    _shown = NO;
    _round++;
    _items = nil;
    if (!_panel.isVisible) return;
    NSUInteger round = _round;
    CALayer *layer = _panel.contentView.layer;
    if (!layer) { [_panel orderOut:nil]; return; }
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        if (self->_round != round) return;   // the next switch has already begun: the panel is its business now
        [self->_panel orderOut:nil];
        [layer removeAllAnimations];
    }];
    CABasicAnimation *leave = [CABasicAnimation animationWithKeyPath:@"opacity"];
    leave.fromValue = @1;
    leave.toValue = @0;
    leave.duration = 0.07;
    leave.fillMode = kCAFillModeForwards;   // stays faded until the window is really gone
    leave.removedOnCompletion = NO;
    [layer addAnimation:leave forKey:@"leave"];
    [CATransaction commit];
}

- (void)switcherView:(SwitcherView *)view hovered:(NSInteger)index { _selected = index; view.selected = index; }
- (void)switcherView:(SwitcherView *)view clicked:(NSInteger)index { _selected = index; [self commit]; }

- (void)showPanel {
    if (!_panel) {
        _panel = [[SwitcherPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 200)
                                                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                    backing:NSBackingStoreBuffered defer:NO];
        _panel.level = NSPopUpMenuWindowLevel;
        _panel.opaque = NO;
        _panel.backgroundColor = NSColor.clearColor;
        _panel.hasShadow = NO;   // a shadow would show through the see-through pane as a dark ring around it
        _panel.hidesOnDeactivate = NO;
        _panel.acceptsMouseMovedEvents = YES;
        _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
        // The pane is our own rather than the system's glass: how much the screen shows through and
        // how much it is blurred are then ours to choose, which the system's glass does not allow.
        // The view paints the pane; the window server blurs what is behind the window.
        NSView *content = [NSView new];
        content.wantsLayer = YES;
        content.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];   // light text on the dark pane, whatever the system's mode
        _view = [SwitcherView new];
        _view.delegate = self;
        _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [content addSubview:_view];
        _panel.contentView = content;
    }

    // On the screen the pointer is on: with two monitors that is the one you are looking at.
    NSPoint mouse = NSEvent.mouseLocation;
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *s in NSScreen.screens) if (NSPointInRect(mouse, s.frame)) { screen = s; break; }
    NSRect vis = screen.visibleFrame;

    // Adapts to the screen: the icons shrink until they fit in one row, and wrap to more rows when
    // even the smallest would not.
    NSInteger n = _items.count;
    // Starts at the size of the system's switcher (icons of about 110 points) and gives way from there.
    CGFloat scale = 1.7, maxW = vis.size.width * 0.94 - 2 * kSide;
    while (n * kCellW * scale > maxW && scale > 0.7) scale -= 0.05;
    NSInteger cols = MAX(1, MIN(n, (NSInteger)floor(maxW / (kCellW * scale))));
    NSInteger rows = (n + cols - 1) / cols;
    NSSize size = NSMakeSize(MAX(cols * kCellW * scale, 420) + 2 * kSide, kTop + _view.headerHeight + rows * kCellH * scale + kBottom);
    _view.columns = cols;
    _view.scale = scale;
    _view.items = _items;
    _view.selected = _selected;
    NSRect frame = NSMakeRect(NSMidX(vis) - size.width / 2, NSMidY(vis) - size.height / 2, size.width, size.height);
    [_panel setFrame:frame display:YES];
    _view.frame = _panel.contentView.bounds;
    CGSSetWindowBackgroundBlurRadius(CGSMainConnectionID(), (int)_panel.windowNumber, 22);
    // It arrives rather than appears: a short fade, rising a few points into place. The animation is
    // on the layer and leaves nothing behind: the window itself is always fully there, so whatever
    // happens to an animation — cut short, overtaken by the next switch — the panel cannot end up
    // invisible.
    CALayer *layer = _panel.contentView.layer;
    [layer removeAllAnimations];
    [_panel orderFrontRegardless];
    if (!_demo) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @0;
        fade.toValue = @1;
        CABasicAnimation *rise = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        rise.fromValue = @(-10);
        rise.toValue = @0;
        CAAnimationGroup *arrive = [CAAnimationGroup animation];
        arrive.animations = @[fade, rise];
        arrive.duration = 0.10;
        arrive.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [layer addAnimation:arrive forKey:@"arrive"];
    }
    _shown = YES;
}

// Finds the windows on other Spaces that accessibility has not told us about, so that they get
// their full title (and with it the Chrome profile) and can be raised properly.
- (void)reachFarWindows:(NSArray<Win *> *)windows {
    if (!AXIsProcessTrusted()) return;
    NSMutableSet<NSNumber *> *pids = [NSMutableSet set];
    for (Win *w in windows) if (!w.ax) [pids addObject:@(w.pid)];
    [pids unionSet:gUnreachedApps];
    [gUnreachedApps removeAllObjects];
    for (NSNumber *pid in pids) {
        if ([_searching containsObject:pid]) continue;
        [_searching addObject:pid];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL complete = NO;
            NSDictionary<NSNumber *, id> *found = AXWindowsByBruteForce(pid.intValue, &complete);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_searching removeObject:pid];
                [gFarWindows addEntriesFromDictionary:found];
                // Having asked the app about everything it has: what it did not name is not a window.
                if (complete) for (Win *w in windows) if (w.pid == pid.intValue && !w.ax && !found[@(w.wid)]) {
                    [gNotWindows addObject:@(w.wid)];
                    Log(@"window %u of %@ is not a real window; leaving it out", w.wid, w.appName);
                }
                for (Win *w in self->_items) {
                    if (w.ax || !found[@(w.wid)]) continue;
                    w.ax = found[@(w.wid)];
                    ReadTitle(w);
                    SplitBrowserTitle(w);
                    self->_view.needsDisplay = YES;
                }
            });
        });
    }
}

#pragma mark Menu

- (void)refreshIcon {
    NSString *symbol = _trusted ? @"macwindow.on.rectangle" : @"exclamationmark.triangle";
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"Retab"];
    image.template = YES;
    _statusItem.button.image = image;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev";
    [menu addItemWithTitle:[NSString stringWithFormat:@"Retab %@", version] action:nil keyEquivalent:@""];
    [menu addItemWithTitle:_trusted ? [NSString stringWithFormat:@"%@ switches apps", ShortcutName(_key, _heldFlags)] : @"Not working yet — see below" action:nil keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];

    BOOL ax = AXIsProcessTrusted();
    NSMenuItem *a = [menu addItemWithTitle:ax ? @"Accessibility: allowed" : @"Allow Accessibility…" action:ax ? nil : @selector(openAccessibility:) keyEquivalent:@""];
    a.target = self;
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *login = [menu addItemWithTitle:@"Open at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *diag = [menu addItemWithTitle:@"Copy Diagnostics" action:@selector(copyDiagnostics:) keyEquivalent:@""];
    diag.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit Retab" action:@selector(terminate:) keyEquivalent:@"q"];
}

- (void)openAccessibility:(id)sender {
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt: @YES});
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

// What Retab sees, for a bug report: put on the clipboard, never written to a file. It includes
// window titles, so it is the user who decides where it goes.
- (void)copyDiagnostics:(id)sender {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[self diagnostics] forType:NSPasteboardTypeString];
}

// The buttons of a window that carry any text, a few levels deep: this is where a browser says
// whose window it is.
static void DescribeControls(AXUIElementRef element, int depth, int *budget, NSMutableString *out) {
    if (depth > 9 || *budget <= 0) return;
    (*budget)--;
    NSString *(^text)(CFStringRef) = ^NSString *(CFStringRef attribute) {
        CFTypeRef v = NULL;
        if (AXUIElementCopyAttributeValue(element, attribute, &v) != kAXErrorSuccess || !v) return nil;
        id value = CFBridgingRelease(v);
        return ([value isKindOfClass:NSString.class] && [value length]) ? value : nil;
    };
    NSString *role = text(kAXRoleAttribute);
    if ([role isEqual:@"AXWebArea"] || [role isEqual:@"AXTabGroup"] || [role isEqual:@"AXScrollArea"]) return;   // the page and the tabs are not it
    if ([role hasSuffix:@"Button"]) {
        NSString *title = text(kAXTitleAttribute), *desc = text(kAXDescriptionAttribute), *help = text(kAXHelpAttribute);
        if (title || desc || help) [out appendFormat:@"      %@ | title: %@ | description: %@ | help: %@\n", role, title ?: @"-", desc ?: @"-", [help stringByReplacingOccurrencesOfString:@"\n" withString:@" / "] ?: @"-"];
    }
    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) != kAXErrorSuccess || !children) return;
    for (id child in (__bridge NSArray *)children) DescribeControls((__bridge AXUIElementRef)child, depth + 1, budget, out);
    CFRelease(children);
}

- (NSString *)diagnostics {
    NSMutableString *out = [NSMutableString stringWithFormat:@"Retab %@, macOS %@\naccessibility %d\n\n",
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"], NSProcessInfo.processInfo.operatingSystemVersionString,
        AXIsProcessTrusted()];
    for (Win *w in ListWindows()) {
        NSString *axTitle = @"-";
        int err = -1;
        if (w.ax) {
            CFTypeRef v = NULL;
            err = AXUIElementCopyAttributeValue((__bridge AXUIElementRef)w.ax, kAXTitleAttribute, &v);
            if (v) axTitle = CFBridgingRelease(v);
        }
        [out appendFormat:@"%u  %@  %@\n    shown: %@ | profile: %@\n    accessibility title (error %d): %@\n",
            w.wid, w.appName, w.near ? @"this space" : (w.ax ? @"other space" : @"other space, NOT reached"),
            w.title, w.profile ?: @"-", err, axTitle];
        if (w.ax && [w.running.bundleIdentifier hasPrefix:@"com.google.Chrome"]) {
            int budget = 600;
            DescribeControls((__bridge AXUIElementRef)w.ax, 0, &budget, out);
        }
    }
    return out;
}

- (void)toggleLogin:(id)sender {
    NSError *err = nil;
    if (SMAppService.mainAppService.status == SMAppServiceStatusEnabled) [SMAppService.mainAppService unregisterAndReturnError:&err];
    else [SMAppService.mainAppService registerAndReturnError:&err];
    if (err) NSLog(@"Open at Login: %@", err);
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // `Retab --list` prints the windows it would offer, for debugging.
        if (argc > 1 && strcmp(argv[1], "--list") == 0) {
            for (Win *w in ListWindows())
                printf("%u\tpid %d\t%s\t[%s]\t%s%s\n", w.wid, w.pid, w.appName.UTF8String, (w.profile ?: @"").UTF8String,
                       w.title.UTF8String, w.near ? "" : (w.ax ? "\t(other space)" : "\t(other space, not reached yet)"));
            return 0;
        }
        if (argc > 2 && strcmp(argv[1], "--dump") == 0) {
            [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"app.retab.mac.dump" object:@(argv[2]) userInfo:nil deliverImmediately:YES];
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
