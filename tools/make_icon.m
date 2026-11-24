// Renders tools/icon.svg into every image the project needs: the app icon set and the pictures
// for the README. Run it with tools/make_icon.sh after changing the design.
//
//   make_icon <icon.svg> <iconset dir> <docs dir>

#import <Cocoa/Cocoa.h>

static void WritePNG(NSImage *svg, NSString *path, int px) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    [svg drawInRect:NSMakeRect(0, 0, px, px)];
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 4) { fprintf(stderr, "usage: make_icon <icon.svg> <iconset dir> <docs dir>\n"); return 1; }
        NSImage *svg = [[NSImage alloc] initWithContentsOfFile:@(argv[1])];
        if (!svg) { fprintf(stderr, "cannot read %s\n", argv[1]); return 1; }
        NSString *iconset = @(argv[2]), *docs = @(argv[3]);
        for (NSNumber *n in @[@16, @32, @128, @256, @512]) {
            WritePNG(svg, [iconset stringByAppendingFormat:@"/icon_%@x%@.png", n, n], n.intValue);
            WritePNG(svg, [iconset stringByAppendingFormat:@"/icon_%@x%@@2x.png", n, n], n.intValue * 2);
        }
        WritePNG(svg, [docs stringByAppendingString:@"/icon.png"], 512);
        WritePNG(svg, [docs stringByAppendingString:@"/favicon.png"], 64);
    }
    return 0;
}
