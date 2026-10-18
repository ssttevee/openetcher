// A minimal AppKit shell for a fabrum app: one window whose view draws with
// Core Graphics and forwards the mouse, plus a file picker and the cursor.
//
// Everything app-specific stays on the Zig side behind `fabrum_shell_host`,
// so this file can move into a fabrum platform package unchanged.
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdatomic.h>

typedef struct {
    void *ctx;
    // Draws a frame into `cg`, whose origin is the bottom left, in points.
    void (*draw)(void *ctx, CGContextRef cg, double width, double height);
    // Pointer position from the top left of the view, in points.
    void (*mouse)(void *ctx, double x, double y, unsigned buttons, double scroll_x, double scroll_y);
    // Why quitting now needs the user's confirmation, or NULL.
    const char *(*busy)(void *ctx);
    // Called once before the app exits.
    void (*will_terminate)(void *ctx);
} fabrum_shell_host;

typedef struct {
    const char *title;
    double width;
    double height;
    double min_width;
    double min_height;
} fabrum_shell_options;

typedef void (*fabrum_shell_file_callback)(void *ctx, const char *path, size_t len);

static fabrum_shell_host host;
static NSView *shared_view;
static atomic_bool frame_requested;

@interface FabrumView : NSView
@end

@implementation FabrumView {
    NSTrackingArea *_tracking;
    unsigned _buttons;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                     NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect |
                                                     NSTrackingCursorUpdate
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)forward:(NSEvent *)event scrollX:(double)sx scrollY:(double)sy {
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    host.mouse(host.ctx, p.x, self.bounds.size.height - p.y, _buttons, sx, sy);
}

- (void)mouseMoved:(NSEvent *)event { [self forward:event scrollX:0 scrollY:0]; }
- (void)mouseDragged:(NSEvent *)event { [self forward:event scrollX:0 scrollY:0]; }
- (void)mouseEntered:(NSEvent *)event { [self forward:event scrollX:0 scrollY:0]; }

- (void)mouseExited:(NSEvent *)event {
    // far outside, so nothing stays hovered
    host.mouse(host.ctx, -1e6, -1e6, _buttons, 0, 0);
    [[NSCursor arrowCursor] set];
}

- (void)mouseDown:(NSEvent *)event {
    _buttons |= 1;
    [self forward:event scrollX:0 scrollY:0];
}

- (void)mouseUp:(NSEvent *)event {
    _buttons &= ~1u;
    [self forward:event scrollX:0 scrollY:0];
}

- (void)scrollWheel:(NSEvent *)event {
    [self forward:event scrollX:-[event scrollingDeltaX] scrollY:-[event scrollingDeltaY]];
}

- (void)cursorUpdate:(NSEvent *)event {
    // the host sets the cursor from its own hover state
    [self forward:event scrollX:0 scrollY:0];
}

- (void)drawRect:(NSRect)dirty {
    atomic_store(&frame_requested, false);
    CGContextRef cg = [[NSGraphicsContext currentContext] CGContext];
    host.draw(host.ctx, cg, self.bounds.size.width, self.bounds.size.height);
}
@end

static BOOL confirmQuit(void) {
    const char *reason = host.busy(host.ctx);
    if (!reason) return YES;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Quit while flashing?";
    alert.informativeText = [NSString stringWithUTF8String:reason];
    [alert addButtonWithTitle:@"Keep Flashing"];
    [alert addButtonWithTitle:@"Quit"];
    return [alert runModal] == NSAlertSecondButtonReturn;
}

@interface FabrumAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@end

@implementation FabrumAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // closing the window has already asked
    if (!self.window.isVisible) return NSTerminateNow;
    return confirmQuit() ? NSTerminateNow : NSTerminateCancel;
}

- (BOOL)windowShouldClose:(NSWindow *)window {
    return confirmQuit();
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    host.will_terminate(host.ctx);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activate];
}
@end

static void buildMenu(NSString *name) {
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *app_item = [[NSMenuItem alloc] init];
    [bar addItem:app_item];
    NSMenu *app_menu = [[NSMenu alloc] init];
    [app_menu addItemWithTitle:[@"Hide " stringByAppendingString:name] action:@selector(hide:) keyEquivalent:@"h"];
    [app_menu addItem:[NSMenuItem separatorItem]];
    [app_menu addItemWithTitle:[@"Quit " stringByAppendingString:name] action:@selector(terminate:) keyEquivalent:@"q"];
    app_item.submenu = app_menu;

    NSMenuItem *window_item = [[NSMenuItem alloc] init];
    [bar addItem:window_item];
    NSMenu *window_menu = [[NSMenu alloc] initWithTitle:@"Window"];
    [window_menu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [window_menu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    window_item.submenu = window_menu;
    NSApp.mainMenu = bar;
    NSApp.windowsMenu = window_menu;
}

// Runs the app until it quits. Never returns.
void fabrum_shell_run(fabrum_shell_options options, fabrum_shell_host new_host) {
    host = new_host;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSString *title = [NSString stringWithUTF8String:options.title];
        buildMenu(title);

        FabrumAppDelegate *delegate = [[FabrumAppDelegate alloc] init];
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, options.width, options.height)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                                NSWindowStyleMaskFullSizeContentView
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = title;
        window.titleVisibility = NSWindowTitleHidden;
        window.titlebarAppearsTransparent = YES;
        window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        window.contentMinSize = NSMakeSize(options.min_width, options.min_height);
        window.delegate = delegate;
        window.releasedWhenClosed = NO;

        FabrumView *view = [[FabrumView alloc] initWithFrame:NSMakeRect(0, 0, options.width, options.height)];
        window.contentView = view;
        [window center];
        shared_view = view;
        delegate.window = window;
        app.delegate = delegate;
        [app run];
    }
    exit(0);
}

// Asks for a frame soon. Safe from any thread; requests made before the
// frame is drawn are coalesced.
void fabrum_shell_request_frame(void) {
    if (atomic_exchange(&frame_requested, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [shared_view setNeedsDisplay:YES];
    });
}

// 0: arrow, 1: pointing hand. Main thread only.
void fabrum_shell_set_cursor(int cursor) {
    if (cursor == 1) {
        [[NSCursor pointingHandCursor] set];
    } else {
        [[NSCursor arrowCursor] set];
    }
}

// Shows an open panel as a sheet once the current event is handled, and
// calls `done` on the main thread with the chosen path, or NULL.
void fabrum_shell_choose_file(const char *message, const char *const *extensions, size_t extension_count,
                              fabrum_shell_file_callback done, void *ctx) {
    NSString *prompt = [NSString stringWithUTF8String:message];
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (size_t i = 0; i < extension_count; i++) {
        UTType *type = [UTType typeWithFilenameExtension:[NSString stringWithUTF8String:extensions[i]]];
        if (type) [types addObject:type];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        panel.resolvesAliases = YES;
        panel.message = prompt;
        if (types.count > 0) panel.allowedContentTypes = types;
        [panel beginSheetModalForWindow:shared_view.window
                      completionHandler:^(NSModalResponse result) {
                        if (result == NSModalResponseOK && panel.URLs.count > 0) {
                            const char *path = panel.URLs.firstObject.fileSystemRepresentation;
                            done(ctx, path, strlen(path));
                        } else {
                            done(ctx, NULL, 0);
                        }
                      }];
    });
}

// Runs `callback(ctx)` on the main thread, after the current event. Safe
// from any thread.
void fabrum_shell_run_on_main(void (*callback)(void *ctx), void *ctx) {
    dispatch_async_f(dispatch_get_main_queue(), ctx, callback);
}

// Draws the window's content into a bitmap at the screen's scale and saves
// it as a PNG at `path`. Main thread only. Returns whether it was written.
bool fabrum_shell_snapshot(const char *path) {
    NSView *view = shared_view;
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    if (!bitmap) return false;
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:[NSString stringWithUTF8String:path] atomically:YES];
}

// Quits as the Quit menu item does, asking first if the host is busy.
void fabrum_shell_quit(void) {
    [NSApp terminate:nil];
}

// Clicks at (x, y), in points from the top left of the content, by sending
// mouse-down and mouse-up events through the window as AppKit would
// deliver them. For tests. Main thread only.
void fabrum_shell_synthesize_click(double x, double y) {
    NSWindow *window = shared_view.window;
    NSPoint point = [shared_view convertPoint:NSMakePoint(x, shared_view.bounds.size.height - y) toView:nil];
    NSEventType types[] = {NSEventTypeMouseMoved, NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp};
    for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); i++) {
        NSEvent *event = [NSEvent mouseEventWithType:types[i]
                                            location:point
                                       modifierFlags:0
                                           timestamp:[[NSProcessInfo processInfo] systemUptime]
                                        windowNumber:window.windowNumber
                                             context:nil
                                         eventNumber:0
                                          clickCount:1
                                            pressure:types[i] == NSEventTypeLeftMouseDown ? 1 : 0];
        if (types[i] == NSEventTypeMouseMoved) {
            // moves go to tracking areas, not through sendEvent's hit test
            [shared_view mouseMoved:event];
        } else {
            [window sendEvent:event];
        }
    }
}
