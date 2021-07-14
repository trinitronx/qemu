/*
 * QEMU Cocoa CG display driver
 *
 * Copyright (c) 2008 Mike Kronenberg
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#ifndef UI_COCOA_H
#define UI_COCOA_H

#import <Cocoa/Cocoa.h>

#include "ui/clipboard.h"
#include "ui/console.h"
#include "ui/kbd-state.h"
#include "qemu/thread.h"

//#define DEBUG

#ifdef DEBUG
#define COCOA_DEBUG(...)  { (void) fprintf (stdout, __VA_ARGS__); }
#else
#define COCOA_DEBUG(...)  ((void) 0)
#endif

typedef void (^CodeBlock)(void);
typedef bool (^BoolCodeBlock)(void);

typedef struct {
    DisplayChangeListener dcl;
    DisplaySurface *surface;
    QemuMutex draw_mutex;
    int mouse_x;
    int mouse_y;
    int mouse_on;
    CGImageRef cursor_cgimage;
    int cursor_show;
    bool swap_option_command;
    bool inited;
} QEMUScreen;

typedef struct {
    QemuClipboardInfo *info;
    QemuEvent event;
} QemuCocoaClipboard;

@interface QemuCocoaView : NSView
{
    NSTextField *pauseLabel;
    NSTrackingArea *trackingArea;
    QEMUScreen *screen;
    int screen_width;
    int screen_height;
    QKbdState *kbd;
    BOOL isMouseGrabbed;
    BOOL isAbsoluteEnabled;
    CFMachPortRef eventsTap;
}
- (id)initWithFrame:(NSRect)frameRect
             screen:(QEMUScreen *)given_screen;
- (void) frameUpdated;
- (NSSize) computeUnzoomedSize;
- (NSSize) fixZoomedFullScreenSize:(NSSize)proposedSize;
- (void) resizeWindow;
- (void) updateUIInfo;
- (void) updateScreenWidth:(int)w height:(int)h;
- (void) grabMouse;
- (void) ungrabMouse;
- (void) setFullGrab:(id)sender;
- (bool) handleEvent:(NSEvent *)event;
- (void) setAbsoluteEnabled:(BOOL)tIsAbsoluteEnabled;
/* The state surrounding mouse grabbing is potentially confusing.
 * isAbsoluteEnabled tracks qemu_input_is_absolute() [ie "is the emulated
 *   pointing device an absolute-position one?"], but is only updated on
 *   next refresh.
 * isMouseGrabbed tracks whether GUI events are directed to the guest;
 *   it controls whether special keys like Cmd get sent to the guest,
 *   and whether we capture the mouse when in non-absolute mode.
 */
- (BOOL) isMouseGrabbed;
- (BOOL) isAbsoluteEnabled;
- (void) setNeedsDisplayForCursorX:(int)x
                                 y:(int)y
                             width:(int)width
                            height:(int)height
                      screenHeight:(int)screen_height;
- (void)displayPause;
- (void)removePause;
@end

@interface QemuCocoaAppController : NSObject
                                       <NSWindowDelegate, NSApplicationDelegate>
{
    NSArray * supportedImageFileTypes;
    QemuCocoaView *cocoaView;
}
- (id) initWithScreen:(QEMUScreen *)screen;
- (QemuCocoaView *)cocoaView;
@end

@interface QemuCocoaPasteboardTypeOwner : NSObject<NSPasteboardTypeOwner>
{
    QemuCocoaClipboard *cb;
}
- (id) initWith:(QemuCocoaClipboard *)aCb;
@end

#endif
