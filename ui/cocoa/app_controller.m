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

#include "qemu/osdep.h"

#include "qemu-common.h"
#include "ui/cocoa.h"
#include "sysemu/sysemu.h"
#include "sysemu/runstate.h"
#include "sysemu/cpu-throttle.h"
#include "qapi/error.h"
#include "qapi/qapi-commands-block.h"
#include "qapi/qapi-commands-machine.h"
#include "qapi/qapi-commands-misc.h"
#include "sysemu/blockdev.h"
#include "qemu-version.h"
#include "qemu/cutils.h"
#include "qemu/main-loop.h"
#include "qemu/module.h"
#include "hw/core/cpu.h"

#ifndef MAC_OS_X_VERSION_10_13
#define MAC_OS_X_VERSION_10_13 101300
#endif

/* 10.14 deprecates NSOnState and NSOffState in favor of
 * NSControlStateValueOn/Off, which were introduced in 10.13.
 * Define for older versions
 */
#if MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_13
#define NSControlStateValueOn NSOnState
#define NSControlStateValueOff NSOffState
#endif

// Utility function to run specified code block with iothread lock held
static void with_iothread_lock(CodeBlock block)
{
    bool locked = qemu_mutex_iothread_locked();
    if (!locked) {
        qemu_mutex_lock_iothread();
    }
    block();
    if (!locked) {
        qemu_mutex_unlock_iothread();
    }
}

/* Displays an alert dialog box with the specified message */
static void QEMU_Alert(NSString *message)
{
    NSAlert *alert;
    alert = [NSAlert new];
    [alert setMessageText: message];
    [alert runModal];
}

/* Handles any errors that happen with a device transaction */
static void handleAnyDeviceErrors(Error * err)
{
    if (err) {
        QEMU_Alert([NSString stringWithCString: error_get_pretty(err)
                                      encoding: NSASCIIStringEncoding]);
        error_free(err);
    }
}

static void create_initial_menus(void)
{
    // Add menus
    NSMenu      *menu;
    NSMenuItem  *menuItem;

    [NSApp setMainMenu:[[NSMenu alloc] init]];

    // Application menu
    menu = [[NSMenu alloc] initWithTitle:@""];
    [menu addItemWithTitle:@"About QEMU" action:@selector(do_about_menu_item:) keyEquivalent:@""]; // About QEMU
    [menu addItem:[NSMenuItem separatorItem]]; //Separator
    [menu addItemWithTitle:@"Hide QEMU" action:@selector(hide:) keyEquivalent:@"h"]; //Hide QEMU
    menuItem = (NSMenuItem *)[menu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"]; // Hide Others
    [menuItem setKeyEquivalentModifierMask:(NSEventModifierFlagOption|NSEventModifierFlagCommand)];
    [menu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""]; // Show All
    [menu addItem:[NSMenuItem separatorItem]]; //Separator
    [menu addItemWithTitle:@"Quit QEMU" action:@selector(terminate:) keyEquivalent:@"q"];
    menuItem = [[NSMenuItem alloc] initWithTitle:@"Apple" action:nil keyEquivalent:@""];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];
    [NSApp performSelector:@selector(setAppleMenu:) withObject:menu]; // Workaround (this method is private since 10.4+)

    // Machine menu
    menu = [[NSMenu alloc] initWithTitle: @"Machine"];
    [menu setAutoenablesItems: NO];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle: @"Pause" action: @selector(pauseQEMU:) keyEquivalent: @""] autorelease]];
    menuItem = [[[NSMenuItem alloc] initWithTitle: @"Resume" action: @selector(resumeQEMU:) keyEquivalent: @""] autorelease];
    [menu addItem: menuItem];
    [menuItem setEnabled: NO];
    [menu addItem: [NSMenuItem separatorItem]];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle: @"Reset" action: @selector(restartQEMU:) keyEquivalent: @""] autorelease]];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle: @"Power Down" action: @selector(powerDownQEMU:) keyEquivalent: @""] autorelease]];
    menuItem = [[[NSMenuItem alloc] initWithTitle: @"Machine" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];

    // View menu
    menu = [[NSMenu alloc] initWithTitle:@"View"];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"Enter Fullscreen" action:@selector(doToggleFullScreen:) keyEquivalent:@"f"] autorelease]]; // Fullscreen
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"Zoom To Fit" action:@selector(zoomToFit:) keyEquivalent:@""] autorelease]];
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];

    // Speed menu
    menu = [[NSMenu alloc] initWithTitle:@"Speed"];

    // Add the rest of the Speed menu items
    int p, percentage, throttle_pct;
    for (p = 10; p >= 0; p--)
    {
        percentage = p * 10 > 1 ? p * 10 : 1; // prevent a 0% menu item

        menuItem = [[[NSMenuItem alloc]
                   initWithTitle: [NSString stringWithFormat: @"%d%%", percentage] action:@selector(adjustSpeed:) keyEquivalent:@""] autorelease];

        if (percentage == 100) {
            [menuItem setState: NSControlStateValueOn];
        }

        /* Calculate the throttle percentage */
        throttle_pct = -1 * percentage + 100;

        [menuItem setTag: throttle_pct];
        [menu addItem: menuItem];
    }
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"Speed" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];

    // Window menu
    menu = [[NSMenu alloc] initWithTitle:@"Window"];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"] autorelease]]; // Miniaturize
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];
    [NSApp setWindowsMenu:menu];

    // Help menu
    menu = [[NSMenu alloc] initWithTitle:@"Help"];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"QEMU Documentation" action:@selector(showQEMUDoc:) keyEquivalent:@"?"] autorelease]]; // QEMU Help
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];
}

/* Returns a name for a given console */
static NSString * getConsoleName(QemuConsole * console)
{
    return [NSString stringWithFormat: @"%s", qemu_console_get_label(console)];
}

/* Add an entry to the View menu for each console */
static void add_console_menu_entries(void)
{
    NSMenu *menu;
    NSMenuItem *menuItem;
    int index = 0;

    menu = [[[NSApp mainMenu] itemWithTitle:@"View"] submenu];

    [menu addItem:[NSMenuItem separatorItem]];

    while (qemu_console_lookup_by_index(index) != NULL) {
        menuItem = [[[NSMenuItem alloc] initWithTitle: getConsoleName(qemu_console_lookup_by_index(index))
                                               action: @selector(displayConsole:) keyEquivalent: @""] autorelease];
        [menuItem setTag: index];
        [menu addItem: menuItem];
        index++;
    }
}

/* Make menu items for all removable devices.
 * Each device is given an 'Eject' and 'Change' menu item.
 */
static void addRemovableDevicesMenuItems(void)
{
    NSMenu *menu;
    NSMenuItem *menuItem;
    BlockInfoList *currentDevice, *pointerToFree;
    NSString *deviceName;

    currentDevice = qmp_query_block(NULL);
    pointerToFree = currentDevice;
    if(currentDevice == NULL) {
        NSBeep();
        QEMU_Alert(@"Failed to query for block devices!");
        return;
    }

    menu = [[[NSApp mainMenu] itemWithTitle:@"Machine"] submenu];

    // Add a separator between related groups of menu items
    [menu addItem:[NSMenuItem separatorItem]];

    // Set the attributes to the "Removable Media" menu item
    NSString *titleString = @"Removable Media";
    NSMutableAttributedString *attString=[[NSMutableAttributedString alloc] initWithString:titleString];
    NSColor *newColor = [NSColor blackColor];
    NSFontManager *fontManager = [NSFontManager sharedFontManager];
    NSFont *font = [fontManager fontWithFamily:@"Helvetica"
                                          traits:NSBoldFontMask|NSItalicFontMask
                                          weight:0
                                            size:14];
    [attString addAttribute:NSFontAttributeName value:font range:NSMakeRange(0, [titleString length])];
    [attString addAttribute:NSForegroundColorAttributeName value:newColor range:NSMakeRange(0, [titleString length])];
    [attString addAttribute:NSUnderlineStyleAttributeName value:[NSNumber numberWithInt: 1] range:NSMakeRange(0, [titleString length])];

    // Add the "Removable Media" menu item
    menuItem = [NSMenuItem new];
    [menuItem setAttributedTitle: attString];
    [menuItem setEnabled: NO];
    [menu addItem: menuItem];

    /* Loop through all the block devices in the emulator */
    while (currentDevice) {
        deviceName = [[NSString stringWithFormat: @"%s", currentDevice->value->device] retain];

        if(currentDevice->value->removable) {
            menuItem = [[NSMenuItem alloc] initWithTitle: [NSString stringWithFormat: @"Change %s...", currentDevice->value->device]
                                                  action: @selector(changeDeviceMedia:)
                                           keyEquivalent: @""];
            [menu addItem: menuItem];
            [menuItem setRepresentedObject: deviceName];
            [menuItem autorelease];

            menuItem = [[NSMenuItem alloc] initWithTitle: [NSString stringWithFormat: @"Eject %s", currentDevice->value->device]
                                                  action: @selector(ejectDeviceMedia:)
                                           keyEquivalent: @""];
            [menu addItem: menuItem];
            [menuItem setRepresentedObject: deviceName];
            [menuItem autorelease];
        }
        currentDevice = currentDevice->next;
    }
    qapi_free_BlockInfoList(pointerToFree);
}

@implementation QemuCocoaAppController
- (id) initWithScreen:(QEMUScreen *)screen
{
    COCOA_DEBUG("%s\n", __func__);

    self = [super init];
    if (self) {
        create_initial_menus();

        /*
         * Create the menu entries which depend on QEMU state (for consoles
         * and removeable devices). These make calls back into QEMU functions,
         * which is OK because at this point we know that the second thread
         * holds the iothread lock and is synchronously waiting for us to
         * finish.
         */
        add_console_menu_entries();
        addRemovableDevicesMenuItems();

        // create a view and add it to the window
        cocoaView = [[QemuCocoaView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 640.0, 480.0)
                                                  screen:screen];
        if(!cocoaView) {
            error_report("(cocoa) can't create a view");
            exit(1);
        }

        // create a window
        NSWindow *normalWindow = [[NSWindow alloc] initWithContentRect:[cocoaView frame]
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        if(!normalWindow) {
            error_report("(cocoa) can't create window");
            exit(1);
        }
        [normalWindow setAcceptsMouseMovedEvents:YES];
        [normalWindow setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
        [normalWindow setTitle:qemu_name ? [NSString stringWithFormat:@"QEMU %s", qemu_name] : @"QEMU"];
        [normalWindow setContentView:cocoaView];
        [normalWindow makeKeyAndOrderFront:self];
        [normalWindow center];
        [normalWindow setDelegate: self];
        [normalWindow release];

        // set the supported image file types that can be opened
        supportedImageFileTypes = [NSArray arrayWithObjects: @"img", @"iso", @"dmg",
                                 @"qcow", @"qcow2", @"cloop", @"vmdk", @"cdr",
                                  @"toast", nil];
    }
    return self;
}

- (void) dealloc
{
    COCOA_DEBUG("QemuCocoaAppController: dealloc\n");

    if (cocoaView)
        [cocoaView release];
    [super dealloc];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    COCOA_DEBUG("QemuCocoaAppController: applicationWillTerminate\n");

    qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST_UI);

    /*
     * Sleep here, because returning will cause OSX to kill us
     * immediately; the QEMU main loop will handle the shutdown
     * request and terminate the process.
     */
    [NSThread sleepForTimeInterval:INFINITY];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:
                                                         (NSApplication *)sender
{
    COCOA_DEBUG("QemuCocoaAppController: applicationShouldTerminate\n");
    return [self verifyQuit];
}

- (void)windowDidChangeScreen:(NSNotification *)notification
{
    [cocoaView updateUIInfo];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
    [cocoaView grabMouse];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
    [cocoaView resizeWindow];
    [cocoaView ungrabMouse];
}

- (void)windowDidResize:(NSNotification *)notification
{
    [cocoaView frameUpdated];
}

- (void)windowDidResignKey:(NSNotification *)notification
{
    [cocoaView ungrabMouse];
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    /* If we became key and are fullscreen there is no point in waiting for
     * a click to grab the mouse.
     */
    if (([[cocoaView window] styleMask] & NSWindowStyleMaskFullScreen) != 0) {
        [cocoaView grabMouse];
    }
}

/* Called when the user clicks on a window's close button */
- (BOOL)windowShouldClose:(id)sender
{
    COCOA_DEBUG("QemuCocoaAppController: windowShouldClose\n");
    [NSApp terminate: sender];
    /* If the user allows the application to quit then the call to
     * NSApp terminate will never return. If we get here then the user
     * cancelled the quit, so we should return NO to not permit the
     * closing of this window.
     */
    return NO;
}

- (NSSize) window:(NSWindow *)window willUseFullScreenContentSize:(NSSize)proposedSize
{
    if (([[cocoaView window] styleMask] & NSWindowStyleMaskResizable) == 0) {
        return [cocoaView computeUnzoomedSize];
    }

    return [cocoaView fixZoomedFullScreenSize:proposedSize];
}

- (NSApplicationPresentationOptions) window:(NSWindow *)window
                                     willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions;

{
    return (proposedOptions & ~(NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar)) |
           NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
}

/* We abstract the method called by the Enter Fullscreen menu item
 * because Mac OS 10.7 and higher disables it. This is because of the
 * menu item's old selector's name toggleFullScreen:
 */
- (void) doToggleFullScreen:(id)sender
{
    [[cocoaView window] toggleFullScreen:sender];
}

/* Tries to find then open the specified filename */
- (void) openDocumentation: (NSString *) filename
{
    /* Where to look for local files */
    NSString *path_array[] = {@"../share/doc/qemu/", @"../doc/qemu/", @"docs/"};
    NSString *full_file_path;
    NSURL *full_file_url;

    /* iterate thru the possible paths until the file is found */
    int index;
    for (index = 0; index < ARRAY_SIZE(path_array); index++) {
        full_file_path = [[NSBundle mainBundle] executablePath];
        full_file_path = [full_file_path stringByDeletingLastPathComponent];
        full_file_path = [NSString stringWithFormat: @"%@/%@%@", full_file_path,
                          path_array[index], filename];
        full_file_url = [NSURL fileURLWithPath: full_file_path
                                   isDirectory: false];
        if ([[NSWorkspace sharedWorkspace] openURL: full_file_url] == YES) {
            return;
        }
    }

    /* If none of the paths opened a file */
    NSBeep();
    QEMU_Alert(@"Failed to open file");
}

- (void)showQEMUDoc:(id)sender
{
    COCOA_DEBUG("QemuCocoaAppController: showQEMUDoc\n");

    [self openDocumentation: @"index.html"];
}

/* Toggles the flag which stretches video to fit host window size */
- (void)zoomToFit:(id) sender
{
    if (([[cocoaView window] styleMask] & NSWindowStyleMaskResizable) == 0) {
        [[cocoaView window] setStyleMask:[[cocoaView window] styleMask] | NSWindowStyleMaskResizable];
        [sender setState: NSControlStateValueOn];
    } else {
        [[cocoaView window] setStyleMask:[[cocoaView window] styleMask] & ~NSWindowStyleMaskResizable];
        [cocoaView resizeWindow];
        [sender setState: NSControlStateValueOff];
    }
}

/* Displays the console on the screen */
- (void)displayConsole:(id)sender
{
    with_iothread_lock(^{
        console_select([sender tag]);
    });
}

/* Pause the guest */
- (void)pauseQEMU:(id)sender
{
    with_iothread_lock(^{
        qmp_stop(NULL);
    });
    [sender setEnabled: NO];
    [[[sender menu] itemWithTitle: @"Resume"] setEnabled: YES];
    [cocoaView displayPause];
}

/* Resume running the guest operating system */
- (void)resumeQEMU:(id) sender
{
    with_iothread_lock(^{
        qmp_cont(NULL);
    });
    [sender setEnabled: NO];
    [[[sender menu] itemWithTitle: @"Pause"] setEnabled: YES];
    [cocoaView removePause];
}

/* Restarts QEMU */
- (void)restartQEMU:(id)sender
{
    with_iothread_lock(^{
        qmp_system_reset(NULL);
    });
}

/* Powers down QEMU */
- (void)powerDownQEMU:(id)sender
{
    with_iothread_lock(^{
        qmp_system_powerdown(NULL);
    });
}

/* Ejects the media.
 * Uses sender's tag to figure out the device to eject.
 */
- (void)ejectDeviceMedia:(id)sender
{
    NSString * drive;
    drive = [sender representedObject];
    if(drive == nil) {
        NSBeep();
        QEMU_Alert(@"Failed to find drive to eject!");
        return;
    }

    __block Error *err = NULL;
    with_iothread_lock(^{
        qmp_eject(true, [drive cStringUsingEncoding: NSASCIIStringEncoding],
                  false, NULL, false, false, &err);
    });
    handleAnyDeviceErrors(err);
}

/* Displays a dialog box asking the user to select an image file to load.
 * Uses sender's represented object value to figure out which drive to use.
 */
- (void)changeDeviceMedia:(id)sender
{
    /* Find the drive name */
    NSString * drive;
    drive = [sender representedObject];
    if(drive == nil) {
        NSBeep();
        QEMU_Alert(@"Could not find drive!");
        return;
    }

    /* Display the file open dialog */
    NSOpenPanel * openPanel;
    openPanel = [NSOpenPanel openPanel];
    [openPanel setCanChooseFiles: YES];
    [openPanel setAllowsMultipleSelection: NO];
    [openPanel setAllowedFileTypes: supportedImageFileTypes];
    if([openPanel runModal] == NSModalResponseOK) {
        NSString * file = [[[openPanel URLs] objectAtIndex: 0] path];
        if(file == nil) {
            NSBeep();
            QEMU_Alert(@"Failed to convert URL to file path!");
            return;
        }

        __block Error *err = NULL;
        with_iothread_lock(^{
            qmp_blockdev_change_medium(true,
                                       [drive cStringUsingEncoding:
                                                  NSASCIIStringEncoding],
                                       false, NULL,
                                       [file cStringUsingEncoding:
                                                 NSASCIIStringEncoding],
                                       true, "raw",
                                       false, 0,
                                       &err);
        });
        handleAnyDeviceErrors(err);
    }
}

/* Verifies if the user really wants to quit */
- (BOOL)verifyQuit
{
    NSAlert *alert = [NSAlert new];
    [alert autorelease];
    [alert setMessageText: @"Are you sure you want to quit QEMU?"];
    [alert addButtonWithTitle: @"Cancel"];
    [alert addButtonWithTitle: @"Quit"];
    if([alert runModal] == NSAlertSecondButtonReturn) {
        return YES;
    } else {
        return NO;
    }
}

/* The action method for the About menu item */
- (IBAction) do_about_menu_item: (id) sender
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    char *icon_path_c = get_relocated_path(CONFIG_QEMU_ICONDIR "/hicolor/512x512/apps/qemu.png");
    NSString *icon_path = [NSString stringWithUTF8String:icon_path_c];
    g_free(icon_path_c);
    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:icon_path];
    NSString *version = @"QEMU emulator version " QEMU_FULL_VERSION;
    NSString *copyright = @QEMU_COPYRIGHT;
    NSDictionary *options;
    if (icon) {
        options = @{
            NSAboutPanelOptionApplicationIcon : icon,
            NSAboutPanelOptionApplicationVersion : version,
            @"Copyright" : copyright,
        };
        [icon release];
    } else {
        options = @{
            NSAboutPanelOptionApplicationVersion : version,
            @"Copyright" : copyright,
        };
    }
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
    [pool release];
}

/* Used by the Speed menu items */
- (void)adjustSpeed:(id)sender
{
    int throttle_pct; /* throttle percentage */
    NSMenu *menu;

    menu = [sender menu];
    if (menu != nil)
    {
        /* Unselect the currently selected item */
        for (NSMenuItem *item in [menu itemArray]) {
            if (item.state == NSControlStateValueOn) {
                [item setState: NSControlStateValueOff];
                break;
            }
        }
    }

    // check the menu item
    [sender setState: NSControlStateValueOn];

    // get the throttle percentage
    throttle_pct = [sender tag];

    with_iothread_lock(^{
        cpu_throttle_set(throttle_pct);
    });
    COCOA_DEBUG("cpu throttling at %d%c\n", cpu_throttle_get_percentage(), '%');
}

- (QemuCocoaView *)cocoaView
{
    return cocoaView;
}

@end
