// Posters for Retab: the real panel (Retab's own drawing code, with made-up windows and profiles)
// over a coloured desktop, with the glass done as on screen — what is under the panel blurred and
// brighter — plus the logo and one line. Run tools/make_posters.sh from the repository's root.
//   poster <out dir>
#define main retab_main
#include "../Sources/main.m"
#undef main
#import <CoreImage/CoreImage.h>

static NSColor *C(int hex) { return [NSColor colorWithSRGBRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:1]; }
static NSColor *CA(int hex, CGFloat a) { return [C(hex) colorWithAlphaComponent:a]; }

static Win *Make(NSString *path, NSString *name, NSString *title) {
    Win *w = [Win new];
    w.icon = [NSWorkspace.sharedWorkspace iconForFile:path];
    w.appName = name; w.title = title; w.wid = 1; w.count = 1;
    return w;
}

static NSArray<Win *> *Items(NSInteger n) {
    NSString *chrome = @"/Applications/Google Chrome.app";
    Win *work = Make(chrome, @"Google Chrome", @"Q4 roadmap — Google Docs");
    work.profile = @"Work"; work.tint = C(0x3B82F6); work.email = @"you@company.com"; work.count = 3; work.place = @"Desktop 2";
    Win *personal = Make(chrome, @"Google Chrome", @"YouTube"); personal.profile = @"Personal"; personal.tint = C(0xF2B233);
    Win *client = Make(chrome, @"Google Chrome", @"Dashboard"); client.profile = @"Client"; client.tint = C(0x3DBE8B);
    Win *incognito = Make(chrome, @"Google Chrome", @"New Incognito Tab"); incognito.privateMode = @"Incognito"; incognito.tint = kPrivateGrey;
    Win *slack = Make(@"/Applications/Slack.app", @"Slack", @"general"); slack.badge = @"3";
    Win *telegram = Make(@"/Applications/Telegram.app", @"Telegram", @"Telegram"); telegram.badge = @"12";
    NSArray *all = @[Make(@"/Applications/Figma.app", @"Figma", @"Design"), work, personal, client, incognito, slack, telegram,
                     Make(@"/System/Library/CoreServices/Finder.app", @"Finder", @"Downloads"), Make(@"/System/Applications/Notes.app", @"Notes", @"Notes"),
                     Make(@"/System/Applications/Music.app", @"Music", @"Music")];
    return [all subarrayWithRange:NSMakeRange(0, MIN(n, (NSInteger)all.count))];
}

// The desktop: a deep night sky with soft coloured light, and a few windows on it, so that the
// glass has something to show through.
static void DrawDesktop(NSRect r) {
    [[[NSGradient alloc] initWithColors:@[C(0x081426), C(0x0D2240), C(0x12142E)]] drawInRect:r angle:-70];
    struct { CGFloat x, y, rad; int col; CGFloat a; } blobs[] = {
        {0.12, 0.85, 0.55, 0x1AA3E0, 0.75}, {0.85, 0.80, 0.50, 0x7F5AF0, 0.65}, {0.70, 0.12, 0.55, 0xF2994A, 0.55},
        {0.20, 0.15, 0.45, 0x3DBE8B, 0.40}, {0.50, 0.50, 0.35, 0xE8645A, 0.30}};
    CGFloat side = MAX(r.size.width, r.size.height);
    for (int i = 0; i < 5; i++) {
        NSRect b = NSMakeRect(r.origin.x + blobs[i].x * r.size.width - blobs[i].rad * side, r.origin.y + blobs[i].y * r.size.height - blobs[i].rad * side,
                              2 * blobs[i].rad * side, 2 * blobs[i].rad * side);
        NSPoint c = NSMakePoint(NSMidX(b), NSMidY(b));
        [[[NSGradient alloc] initWithStartingColor:CA(blobs[i].col, blobs[i].a) endingColor:CA(blobs[i].col, 0)] drawFromCenter:c radius:0 toCenter:c radius:b.size.width / 2 options:0];
    }
}

// A window lying on the desktop: a title bar with the three lights, and a few lines of content.
static void DrawWindow(NSRect r, BOOL dark, int accent) {
    CGFloat rad = r.size.width * 0.025;
    NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.35]; sh.shadowBlurRadius = r.size.width * 0.04; sh.shadowOffset = NSMakeSize(0, -r.size.width * 0.01);
    [NSGraphicsContext saveGraphicsState]; [sh set];
    [(dark ? C(0x1E2530) : C(0xF4F6F8)) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad] fill];
    [NSGraphicsContext restoreGraphicsState];
    CGFloat bar = r.size.height * 0.11, dot = bar * 0.32;
    int lights[] = {0xFF5F57, 0xFEBC2E, 0x28C840};
    for (int i = 0; i < 3; i++) { [C(lights[i]) setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMinX(r) + bar * 0.5 + i * dot * 1.7, NSMaxY(r) - bar / 2 - dot / 2, dot, dot)] fill]; }
    NSRect body = NSInsetRect(NSMakeRect(r.origin.x, r.origin.y, r.size.width, r.size.height - bar), r.size.width * 0.06, r.size.height * 0.08);
    [CA(accent, 0.9) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(body.origin.x, NSMaxY(body) - body.size.height * 0.45, body.size.width * 0.45, body.size.height * 0.45) xRadius:rad yRadius:rad] fill];
    for (int i = 0; i < 4; i++) {
        [(dark ? [NSColor colorWithWhite:1 alpha:0.18] : [NSColor colorWithWhite:0 alpha:0.12]) setFill];
        CGFloat lw = body.size.width * (i % 2 ? 0.7 : 0.9);
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(body.origin.x, body.origin.y + i * body.size.height * 0.12, lw, body.size.height * 0.05) xRadius:3 yRadius:3] fill];
    }
}

static CGImageRef Snapshot(NSBitmapImageRep *rep) { return rep.CGImage; }

static NSBitmapImageRep *Canvas(NSSize size) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:size.width pixelsHigh:size.height bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = size;
    return rep;
}

// The panel at rect r on a canvas whose picture so far is `under`: the part of `under` behind the
// panel, blurred and brightened like the system's glass, then Retab's own drawing on top.
static void DrawPanel(NSRect r, NSArray<Win *> *items, NSInteger selected, CGImageRef under, NSSize canvas) {
    NSInteger n = items.count;
    // the panel's own layout at the size that fills r
    CGFloat scale = (r.size.width - 2 * kSide) / (n * kCellW);
    SwitcherView *view = [SwitcherView new];
    view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    view.columns = n; view.scale = scale; view.items = items; view.selected = selected;
    NSSize size = NSMakeSize(r.size.width, kTop + view.headerHeight + kCellH * scale + kBottom);
    view.frame = NSMakeRect(0, 0, size.width, size.height);
    r.origin.y -= (size.height - r.size.height) / 2; r.size.height = size.height;

    // the glass
    CIImage *bg = [CIImage imageWithCGImage:under];
    CGFloat k = CGImageGetWidth(under) / canvas.width;
    CIImage *blurred = [[bg imageByClampingToExtent] imageByApplyingFilter:@"CIGaussianBlur" withInputParameters:@{kCIInputRadiusKey: @(28 * k)}];
    blurred = [blurred imageByApplyingFilter:@"CIColorControls" withInputParameters:@{kCIInputSaturationKey: @1.5, kCIInputBrightnessKey: @0.02}];
    blurred = [blurred imageByCroppingToRect:bg.extent];
    CGImageRef glass = [[CIContext context] createCGImage:blurred fromRect:bg.extent];
    NSBezierPath *pane = [NSBezierPath bezierPathWithRoundedRect:r xRadius:kPaneRadius yRadius:kPaneRadius];
    NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.45]; sh.shadowBlurRadius = 40; sh.shadowOffset = NSMakeSize(0, -14);
    [NSGraphicsContext saveGraphicsState]; [sh set]; [[NSColor colorWithWhite:0 alpha:0.5] setFill]; [pane fill]; [NSGraphicsContext restoreGraphicsState];
    [NSGraphicsContext saveGraphicsState];
    [pane addClip];
    CGContextDrawImage(NSGraphicsContext.currentContext.CGContext, CGRectMake(0, 0, canvas.width, canvas.height), glass);
    CGImageRelease(glass);
    // Retab's drawing, in its own flipped coordinates
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    CGContextTranslateCTM(cg, r.origin.x, NSMaxY(r));
    CGContextScaleCTM(cg, 1, -1);
    NSGraphicsContext *flipped = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES];
    NSGraphicsContext *saved = NSGraphicsContext.currentContext;
    NSGraphicsContext.currentContext = flipped;
    [view.appearance performAsCurrentDrawingAppearance:^{ [view drawRect:view.bounds]; }];
    NSGraphicsContext.currentContext = saved;
    [NSGraphicsContext restoreGraphicsState];
}

static CGFloat DrawText(NSString *s, NSPoint p, CGFloat size, NSFontWeight weight, NSColor *color, CGFloat kern, NSTextAlignment align, CGFloat width) {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = align; ps.lineHeightMultiple = 0.95;
    NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight], NSForegroundColorAttributeName: color, NSKernAttributeName: @(kern), NSParagraphStyleAttributeName: ps};
    NSRect box = [s boundingRectWithSize:NSMakeSize(width, 10000) options:NSStringDrawingUsesLineFragmentOrigin attributes:a];
    [s drawWithRect:NSMakeRect(p.x, p.y - box.size.height, width, box.size.height) options:NSStringDrawingUsesLineFragmentOrigin attributes:a];
    return box.size.height;
}

// The logo: Retab's icon and its name, and Markerloop's under it, small.
static void DrawLogo(NSPoint topLeft, CGFloat h) {
    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:@"docs/icon.png"];
    // the icon file carries Apple's margin around the plate; draw it so the plate itself is h tall
    CGFloat full = h / 0.805;
    [icon drawInRect:NSMakeRect(topLeft.x - full * 0.0977, topLeft.y - h - full * 0.0977, full, full)];
    DrawText(@"Retab", NSMakePoint(topLeft.x + h * 1.25, topLeft.y + h * 0.02), h * 0.62, NSFontWeightBold, NSColor.whiteColor, -h * 0.01, NSTextAlignmentLeft, 1000);
    DrawText(@"by Markerloop", NSMakePoint(topLeft.x + h * 1.27, topLeft.y - h * 0.62), h * 0.28, NSFontWeightMedium, [NSColor colorWithWhite:1 alpha:0.7], 0, NSTextAlignmentLeft, 1000);
}

typedef struct { const char *name; CGFloat w, h; NSInteger icons; BOOL text; } Format;

int main(int argc, const char *argv[]) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSString *dir = @(argv[1]);
    NSString *headline = @"Command-Tab that knows\nyour Chrome profiles.";
    NSString *sub = @"Every profile its own icon, with your account's picture. Free and open source for macOS.";
    Format formats[] = {
        {"wide-1600x900", 1600, 900, 8, YES}, {"github-1280x640", 1280, 640, 7, YES}, {"square-1080x1080", 1080, 1080, 5, YES},
        {"linkedin-1200x627", 1200, 627, 7, YES}, {"card-1200x750", 1200, 750, 8, NO}};
    for (int f = 0; f < 5; f++) {
        Format F = formats[f];
        NSSize size = NSMakeSize(F.w, F.h);
        NSBitmapImageRep *rep = Canvas(size);
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        NSRect all = NSMakeRect(0, 0, F.w, F.h);
        DrawDesktop(all);
        [NSGraphicsContext restoreGraphicsState];
        CGImageRef under = CGImageCreateCopy(Snapshot(rep));

        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        CGFloat margin = F.w * 0.06;
        BOOL square = F.h >= F.w * 0.9;
        CGFloat panelW = F.w - 2 * margin;
        if (F.text) {
            CGFloat logoH = F.h * (square ? 0.065 : 0.08);
            CGFloat y = F.h - margin * (square ? 0.9 : 0.65);
            DrawLogo(NSMakePoint(margin, y), logoH);
            y -= logoH + F.h * (square ? 0.07 : 0.07);
            CGFloat hs = square ? F.w * 0.088 : F.h * 0.082;
            y -= DrawText(headline, NSMakePoint(margin, y), hs, NSFontWeightHeavy, NSColor.whiteColor, -hs * 0.025, NSTextAlignmentLeft, F.w - 2 * margin);

            // the panel in the middle of what is left below
            DrawPanel(NSMakeRect(margin, y / 2, panelW, 0), Items(F.icons), 1, under, size);
        } else {
            DrawPanel(NSMakeRect(margin, F.h * 0.42, panelW, 0), Items(F.icons), 1, under, size);
            DrawLogo(NSMakePoint(margin, F.h - margin * 0.7), F.h * 0.075);
        }
        [NSGraphicsContext restoreGraphicsState];
        CGImageRelease(under);
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingFormat:@"/retab-%s.png", F.name] atomically:YES];
    }
} return 0; }
