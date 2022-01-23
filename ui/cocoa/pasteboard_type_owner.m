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

#include "ui/cocoa.h"
#include "qemu/main-loop.h"

@implementation QemuCocoaPasteboardTypeOwner

- (id)initWith:(QemuCocoaClipboard *)aCb
{
    COCOA_DEBUG("QemuCocoaView: initWithFrame\n");

    self = [super init];
    if (self) {
        cb = aCb;
    }
    return self;
}

- (void)pasteboard:(NSPasteboard *)sender provideDataForType:(NSPasteboardType)type
{
    if (type != NSPasteboardTypeString) {
        return;
    }

    qemu_mutex_lock_iothread();

    QemuClipboardInfo *info = qemu_clipboard_info_ref(cb->info);
    qemu_event_reset(&cb->event);
    qemu_clipboard_request(info, QEMU_CLIPBOARD_TYPE_TEXT);

    while (info == cb->info &&
           info->types[QEMU_CLIPBOARD_TYPE_TEXT].available &&
           info->types[QEMU_CLIPBOARD_TYPE_TEXT].data == NULL) {
        qemu_mutex_unlock_iothread();
        qemu_event_wait(&cb->event);
        qemu_mutex_lock_iothread();
    }

    if (info == cb->info) {
        NSData *data = [[NSData alloc] initWithBytes:info->types[QEMU_CLIPBOARD_TYPE_TEXT].data
                                       length:info->types[QEMU_CLIPBOARD_TYPE_TEXT].size];
        [sender setData:data forType:NSPasteboardTypeString];
        [data release];
    }

    qemu_clipboard_info_unref(info);

    qemu_mutex_unlock_iothread();
}

@end
