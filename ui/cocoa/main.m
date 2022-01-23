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

#include <crt_externs.h>

#include "qemu-common.h"
#include "ui/cocoa.h"
#include "ui/input.h"
#include "sysemu/sysemu.h"

#ifdef CONFIG_EGL
#include "ui/egl-context.h"
#endif

static QEMUScreen screen;
static QemuCocoaAppController *appController;

static int gArgc;
static char **gArgv;

static QemuSemaphore display_init_sem;

static NSInteger cbchangecount = -1;
static QemuCocoaClipboard qemucb;
static QemuCocoaPasteboardTypeOwner *cbowner;

#ifdef CONFIG_OPENGL

uint32_t gl_scanout_id;
DisplayGLTextureBorrower gl_scanout_borrow;
bool gl_surface_dirty;

static QEMUGLContext view_ctx;
static QemuGLShader *gls;
static GLuint cursor_texture;
static int cursor_texture_width;
static int cursor_texture_height;

#ifdef CONFIG_EGL
static EGLSurface egl_surface;
#endif

static void cocoa_gl_destroy_context(DisplayGLCtx *dgc, QEMUGLContext ctx);

#endif

@interface QemuApplication : NSApplication
@end

@implementation QemuApplication
- (void)sendEvent:(NSEvent *)event
{
    COCOA_DEBUG("QemuApplication: sendEvent\n");
    if (![[appController cocoaView] handleEvent:event]) {
        [super sendEvent: event];
    }
}
@end

static void cocoa_mouse_mode_change_notify(Notifier *notifier, void *data)
{
    static bool shared_is_absolute;

    qatomic_set(&shared_is_absolute, qemu_input_is_absolute());

    dispatch_async(dispatch_get_main_queue(), ^{
        bool is_absolute = qatomic_read(&shared_is_absolute);
        if (is_absolute == [[appController cocoaView] isAbsoluteEnabled]) {
            return;
        }

        if (is_absolute && [[appController cocoaView] isMouseGrabbed]) {
            [[appController cocoaView] ungrabMouse];
        }
        [[appController cocoaView] setAbsoluteEnabled:is_absolute];
    });
}

static Notifier mouse_mode_change_notifier = {
    .notify = cocoa_mouse_mode_change_notify
};

static void cocoa_clipboard_notify(Notifier *notifier, void *data);
static void cocoa_clipboard_request(QemuClipboardInfo *info,
                                    QemuClipboardType type);

static QemuClipboardPeer cbpeer = {
    .name = "cocoa",
    .notifier = { .notify = cocoa_clipboard_notify },
    .request = cocoa_clipboard_request
};

static void cocoa_clipboard_update_info(QemuClipboardInfo *info)
{
    if (info->owner == &cbpeer || info->selection != QEMU_CLIPBOARD_SELECTION_CLIPBOARD) {
        return;
    }

    if (info != qemucb.info) {
        NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
        qemu_clipboard_info_unref(qemucb.info);
        qemucb.info = qemu_clipboard_info_ref(info);
        cbchangecount = [[NSPasteboard generalPasteboard] declareTypes:@[NSPasteboardTypeString] owner:cbowner];
        [pool release];
    }

    qemu_event_set(&qemucb.event);
}

static void cocoa_clipboard_notify(Notifier *notifier, void *data)
{
    QemuClipboardNotify *notify = data;

    switch (notify->type) {
    case QEMU_CLIPBOARD_UPDATE_INFO:
        cocoa_clipboard_update_info(notify->info);
        return;
    case QEMU_CLIPBOARD_RESET_SERIAL:
        /* ignore */
        return;
    }
}

static void cocoa_clipboard_request(QemuClipboardInfo *info,
                                    QemuClipboardType type)
{
    NSData *text;

    switch (type) {
    case QEMU_CLIPBOARD_TYPE_TEXT:
        text = [[NSPasteboard generalPasteboard] dataForType:NSPasteboardTypeString];
        if (text) {
            qemu_clipboard_set_data(&cbpeer, info, type,
                                    [text length], [text bytes], true);
            [text release];
        }
        break;
    default:
        break;
    }
}

/*
 * The startup process for the OSX/Cocoa UI is complicated, because
 * OSX insists that the UI runs on the initial main thread, and so we
 * need to start a second thread which runs the vl.c qemu_main():
 *
 * Initial thread:                    2nd thread:
 * in main():
 *  create qemu-main thread
 *  wait on display_init semaphore
 *                                    call qemu_main()
 *                                    ...
 *                                    in cocoa_display_init():
 *                                     post the display_init semaphore
 *  create application, menus, etc     dispatch_sync()
 *  enter OSX run loop
 *  execute the dispatched block
 *                                    [...]
 *                                    run qemu main-loop
 *
 * We do this in two stages so that we don't do the creation of the
 * GUI application menus and so on for command line options like --help
 * where we want to just print text to stdout and exit immediately.
 */

static void *call_qemu_main(void *opaque)
{
    int status;

    COCOA_DEBUG("Second thread: calling qemu_main()\n");
    status = qemu_main(gArgc, gArgv, *_NSGetEnviron());
    COCOA_DEBUG("Second thread: qemu_main() returned, exiting\n");
    [cbowner release];
    CGImageRelease(screen.cursor_cgimage);
#ifdef CONFIG_OPENGL
    qemu_gl_fini_shader(gls);
    if (view_ctx) {
        cocoa_gl_destroy_context(NULL, view_ctx);
    }
    if (appController) {
        [appController release];
    }
#endif
    exit(status);
}

int main (int argc, char **argv) {
    QemuThread thread;

    COCOA_DEBUG("Entered main()\n");
    gArgc = argc;
    gArgv = argv;

    qemu_sem_init(&display_init_sem, 0);

    qemu_thread_create(&thread, "qemu_main", call_qemu_main,
                       NULL, QEMU_THREAD_DETACHED);

    qemu_mutex_init(&screen.draw_mutex);

    COCOA_DEBUG("Main thread: waiting for display_init_sem\n");
    qemu_sem_wait(&display_init_sem);
    COCOA_DEBUG("Main thread: initializing app\n");

    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    // Pull this console process up to being a fully-fledged graphical
    // app with a menubar and Dock icon
    ProcessSerialNumber psn = { 0, kCurrentProcess };
    TransformProcessType(&psn, kProcessTransformToForegroundApplication);

    [QemuApplication sharedApplication];

    // Create an Application controller
    appController = [[QemuCocoaAppController alloc] initWithScreen:&screen];
    [NSApp setDelegate:appController];
    [[appController cocoaView] setAbsoluteEnabled:qemu_input_is_absolute()];

    // Start the main event loop
    COCOA_DEBUG("Main thread: entering OSX run loop\n");
    [NSApp run];
    COCOA_DEBUG("Main thread: left OSX run loop, exiting\n");

    [pool release];

    return 0;
}



#pragma mark qemu
static void cocoa_update(DisplayChangeListener *dcl,
                         int x, int y, int w, int h)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    DisplaySurface *updated = screen.surface;

    COCOA_DEBUG("qemu_cocoa: cocoa_update\n");

    dispatch_async(dispatch_get_main_queue(), ^{
        qemu_mutex_lock(&screen.draw_mutex);
        if (updated != screen.surface) {
            qemu_mutex_unlock(&screen.draw_mutex);
            return;
        }
        int full_height = surface_height(screen.surface);
        qemu_mutex_unlock(&screen.draw_mutex);

        CGFloat d = [[appController cocoaView] frame].size.height / full_height;
        NSRect rect = NSMakeRect(x * d, (full_height - y - h) * d, w * d, h * d);
        [[appController cocoaView] setNeedsDisplayInRect:rect];
    });

    [pool release];
}

static void cocoa_switch(DisplayChangeListener *dcl,
                         DisplaySurface *new_surface)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    static bool updating_screen;

    COCOA_DEBUG("qemu_cocoa: cocoa_switch\n");

    [[appController cocoaView] updateUIInfo];

    qemu_mutex_lock(&screen.draw_mutex);
    screen.surface = new_surface;
    if (!updating_screen) {
        updating_screen = true;

        dispatch_async(dispatch_get_main_queue(), ^{
            qemu_mutex_lock(&screen.draw_mutex);
            updating_screen = false;
            int w = surface_width(screen.surface);
            int h = surface_height(screen.surface);
            qemu_mutex_unlock(&screen.draw_mutex);

            [[appController cocoaView] updateScreenWidth:w height:h];
        });
    }
    qemu_mutex_unlock(&screen.draw_mutex);
    [pool release];
}

static void cocoa_refresh(DisplayChangeListener *dcl)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    COCOA_DEBUG("qemu_cocoa: cocoa_refresh\n");
    graphic_hw_update(NULL);

    if (cbchangecount != [[NSPasteboard generalPasteboard] changeCount]) {
        qemu_clipboard_info_unref(qemucb.info);
        qemucb.info = qemu_clipboard_info_new(&cbpeer, QEMU_CLIPBOARD_SELECTION_CLIPBOARD);
        if ([[NSPasteboard generalPasteboard] availableTypeFromArray:@[NSPasteboardTypeString]]) {
            qemucb.info->types[QEMU_CLIPBOARD_TYPE_TEXT].available = true;
        }
        qemu_clipboard_update(qemucb.info);
        cbchangecount = [[NSPasteboard generalPasteboard] changeCount];
        qemu_event_set(&qemucb.event);
    }

    [pool release];
}

static void cocoa_mouse_set(DisplayChangeListener *dcl, int x, int y, int on)
{
    qemu_mutex_lock(&screen.draw_mutex);
    int full_height = surface_height(screen.surface);
    size_t cursor_width = CGImageGetWidth(screen.cursor_cgimage);
    size_t cursor_height = CGImageGetHeight(screen.cursor_cgimage);
    int old_x = screen.mouse_x;
    int old_y = screen.mouse_y;
    int old_on = screen.mouse_on;
    screen.mouse_x = x;
    screen.mouse_y = y;
    screen.mouse_on = on;
    qemu_mutex_unlock(&screen.draw_mutex);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (old_on) {
            [[appController cocoaView] setNeedsDisplayForCursorX:old_x
                                                               y:old_y
                                                           width:cursor_width
                                                           height:cursor_height
                                                     screenHeight:full_height];
        }

        if (on) {
            [[appController cocoaView] setNeedsDisplayForCursorX:x
                                                               y:y
                                                           width:cursor_width
                                                           height:cursor_height
                                                     screenHeight:full_height];
        }
    });
}

static void cocoa_cursor_define(DisplayChangeListener *dcl, QEMUCursor *cursor)
{
    int width = cursor->width;
    int height = cursor->height;

    CGDataProviderRef dataProviderRef = CGDataProviderCreateWithData(
        NULL,
        cursor->data,
        width * height * 4,
        NULL
    );

    CGImageRef imageRef = CGImageCreate(
        width, //width
        height, //height
        8, //bitsPerComponent
        32, //bitsPerPixel
        width * 4, //bytesPerRow
        CGColorSpaceCreateWithName(kCGColorSpaceSRGB), //colorspace
        kCGBitmapByteOrder32Little | kCGImageAlphaFirst, //bitmapInfo
        dataProviderRef, //provider
        NULL, //decode
        0, //interpolate
        kCGRenderingIntentDefault //intent
    );

    qemu_mutex_lock(&screen.draw_mutex);
    int full_height = surface_height(screen.surface);
    int x = screen.mouse_x;
    int y = screen.mouse_y;
    int on = screen.mouse_on;
    size_t old_width;
    size_t old_height;
    if (screen.cursor_cgimage) {
        old_width = CGImageGetWidth(screen.cursor_cgimage);
        old_height = CGImageGetHeight(screen.cursor_cgimage);
    } else {
        old_width = 0;
        old_height = 0;
    }
    screen.cursor_cgimage = CGImageCreateCopy(imageRef);
    qemu_mutex_unlock(&screen.draw_mutex);

    CGImageRelease(imageRef);
    CGDataProviderRelease(dataProviderRef);

    if (on) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CGFloat d = [[appController cocoaView] frame].size.height / full_height;
            NSRect rect;

            rect.origin.x = d * x;
            rect.origin.y = d * (full_height - y - old_height);
            rect.size.width = d * old_width;
            rect.size.height = d * old_height;
            [[appController cocoaView] setNeedsDisplayInRect:rect];

            rect.origin.x = d * x;
            rect.origin.y = d * (full_height - y - height);
            rect.size.width = d * width;
            rect.size.height = d * height;
            [[appController cocoaView] setNeedsDisplayInRect:rect];
       });
    }
}

static const DisplayChangeListenerOps dcl_ops = {
    .dpy_name          = "cocoa",
    .dpy_gfx_update = cocoa_update,
    .dpy_gfx_switch = cocoa_switch,
    .dpy_refresh = cocoa_refresh,
    .dpy_mouse_set = cocoa_mouse_set,
    .dpy_cursor_define = cocoa_cursor_define,
};

#ifdef CONFIG_OPENGL

static void with_view_ctx(CodeBlock block)
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        eglMakeCurrent(qemu_egl_display, egl_surface, egl_surface, view_ctx);
        block();
        return;
    }
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [(NSOpenGLContext *)view_ctx lock];
    [(NSOpenGLContext *)view_ctx makeCurrentContext];
    block();
    [(NSOpenGLContext *)view_ctx unlock];
#pragma clang diagnostic pop
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSOpenGLContext *cocoa_gl_create_context_ns(NSOpenGLContext *share_context,
                                                   int bpp)
{
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAOpenGLProfile,
        NSOpenGLProfileVersion4_1Core,
        NSOpenGLPFAColorSize,
        bpp,
        NSOpenGLPFADoubleBuffer,
        0,
    };
    NSOpenGLPixelFormat *format;
    NSOpenGLContext *ctx;

    format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    ctx = [[NSOpenGLContext alloc] initWithFormat:format shareContext:share_context];
    [format release];

    [ctx retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [ctx setView:[appController cocoaView]];
        [ctx release];
    });

    return (QEMUGLContext)ctx;
}
#pragma clang diagnostic pop

static int cocoa_gl_make_context_current(DisplayGLCtx *dgc, QEMUGLContext ctx)
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        EGLSurface surface = ctx == EGL_NO_CONTEXT ? EGL_NO_SURFACE : egl_surface;
        return eglMakeCurrent(qemu_egl_display, surface, surface, ctx);
    }
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (ctx) {
        [(NSOpenGLContext *)ctx makeCurrentContext];
    } else {
        [NSOpenGLContext clearCurrentContext];
    }
#pragma clang diagnostic pop

    return 0;
}

static QEMUGLContext cocoa_gl_create_context(DisplayGLCtx *dgc,
                                             QEMUGLParams *params)
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        eglMakeCurrent(qemu_egl_display, egl_surface, egl_surface, view_ctx);
        return qemu_egl_create_context(dgc, params);
    }
#endif

    int bpp = PIXMAN_FORMAT_BPP(surface_format(screen.surface));
    return cocoa_gl_create_context_ns(view_ctx, bpp);
}

static void cocoa_gl_destroy_context(DisplayGLCtx *dgc, QEMUGLContext ctx)
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        eglDestroyContext(qemu_egl_display, ctx);
        return;
    }
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [(NSOpenGLContext *)ctx release];
#pragma clang diagnostic pop
}

static void cocoa_gl_flush()
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        eglSwapBuffers(qemu_egl_display, egl_surface);
        return;
    }
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[NSOpenGLContext currentContext] flushBuffer];

    dispatch_async(dispatch_get_main_queue(), ^{
        [(NSOpenGLContext *)view_ctx update];
    });
#pragma clang diagnostic pop
}

static void cocoa_scanout_disable(DisplayChangeListener *dcl)
{
    gl_scanout_id = 0;

    if (screen.surface) {
        surface_gl_destroy_texture(gls, screen.surface);
        surface_gl_create_texture(gls, screen.surface);
    }
}

static void cocoa_gl_render_cursor()
{
    if (!screen.mouse_on) {
        return;
    }

    QemuCocoaView *cocoaView = [appController cocoaView];
    NSSize size = [cocoaView convertSizeToBacking:[cocoaView frame].size];
    int full_height = surface_height(screen.surface);
    CGFloat d = size.height / full_height;

    glViewport(
        d * screen.mouse_x,
        d * (full_height - screen.mouse_y - cursor_texture_height),
        d * cursor_texture_width,
        d * cursor_texture_height
    );
    glBindTexture(GL_TEXTURE_2D, cursor_texture);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    qemu_gl_run_texture_blit(gls, false);
    glDisable(GL_BLEND);
}

static void cocoa_gl_render_surface(DisplayChangeListener *dcl)
{
    cocoa_scanout_disable(dcl);

    QemuCocoaView *cocoaView = [appController cocoaView];
    NSSize size = [cocoaView convertSizeToBacking:[cocoaView frame].size];

    surface_gl_setup_viewport(gls, screen.surface, size.width, size.height);
    glBindTexture(GL_TEXTURE_2D, screen.surface->texture);
    surface_gl_render_texture(gls, screen.surface);

    cocoa_gl_render_cursor();

    cocoa_gl_flush();
}

static void cocoa_gl_update(DisplayChangeListener *dcl,
                            int x, int y, int w, int h)
{
    with_view_ctx(^{
        surface_gl_update_texture(gls, screen.surface, x, y, w, h);
        gl_surface_dirty = true;
    });
}

static void cocoa_gl_switch(DisplayChangeListener *dcl,
                            DisplaySurface *new_surface)
{
    with_view_ctx(^{
        surface_gl_destroy_texture(gls, screen.surface);
        surface_gl_create_texture(gls, new_surface);
    });

    gl_scanout_id = 0;
    cocoa_switch(dcl, new_surface);
}

static void cocoa_gl_refresh(DisplayChangeListener *dcl)
{
    cocoa_refresh(dcl);

    with_view_ctx(^{
        if (gl_surface_dirty && screen.surface) {
            gl_surface_dirty = false;
            cocoa_gl_render_surface(dcl);
        }
    });
}

static void cocoa_gl_scanout_disable(DisplayChangeListener *dcl)
{
    with_view_ctx(^{
        cocoa_scanout_disable(dcl);
    });
}

static void cocoa_gl_scanout_texture(DisplayChangeListener *dcl,
                                     uint32_t backing_id,
                                     DisplayGLTextureBorrower backing_borrow,
                                     uint32_t x, uint32_t y,
                                     uint32_t w, uint32_t h)
{
    gl_scanout_id = backing_id;
    gl_scanout_borrow = backing_borrow;
}

static void cocoa_gl_scanout_flush(DisplayChangeListener *dcl,
                                   uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
    bool y0_top;

    if (!gl_scanout_id) {
        return;
    }

    GLint texture = gl_scanout_borrow(gl_scanout_id, &y0_top, NULL, NULL);
    if (!texture) {
        return;
    }

    with_view_ctx(^{
        QemuCocoaView *cocoaView = [appController cocoaView];
        NSSize size = [cocoaView convertSizeToBacking:[cocoaView frame].size];

        glBindFramebuffer(GL_FRAMEBUFFER_EXT, 0);
        glViewport(0, 0, size.width, size.height);
        glBindTexture(GL_TEXTURE_2D, texture);
        qemu_gl_run_texture_blit(gls, y0_top);

        cocoa_gl_render_cursor();

        cocoa_gl_flush();
    });
}

static void cocoa_gl_mouse_set(DisplayChangeListener *dcl, int x, int y, int on)
{
    screen.mouse_x = x;
    screen.mouse_y = y;
    screen.mouse_on = on;

    if (gl_scanout_id) {
        cocoa_gl_scanout_flush(dcl, 0, 0, 0, 0);
    } else {
        with_view_ctx(^{
            cocoa_gl_render_surface(dcl);
        });
    }
}

static void cocoa_gl_cursor_define(DisplayChangeListener *dcl, QEMUCursor *cursor)
{
    cursor_texture_width = cursor->width;
    cursor_texture_height = cursor->height;

    with_view_ctx(^{
        glBindTexture(GL_TEXTURE_2D, cursor_texture);
        glPixelStorei(GL_UNPACK_ROW_LENGTH_EXT, cursor->width);
        glTexImage2D(GL_TEXTURE_2D, 0,
                     epoxy_is_desktop_gl() ? GL_RGBA : GL_BGRA,
                     cursor->width,
                     cursor->height,
                     0, GL_BGRA, GL_UNSIGNED_BYTE,
                     cursor->data);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    });
}

static const DisplayChangeListenerOps dcl_gl_ops = {
    .dpy_name               = "cocoa-gl",
    .dpy_gfx_update         = cocoa_gl_update,
    .dpy_gfx_switch         = cocoa_gl_switch,
    .dpy_gfx_check_format   = console_gl_check_format,
    .dpy_refresh            = cocoa_gl_refresh,
    .dpy_mouse_set           = cocoa_gl_mouse_set,
    .dpy_cursor_define       = cocoa_gl_cursor_define,

    .dpy_gl_scanout_disable = cocoa_gl_scanout_disable,
    .dpy_gl_scanout_texture = cocoa_gl_scanout_texture,
    .dpy_gl_update          = cocoa_gl_scanout_flush,
};

static const DisplayGLCtxOps gl_ctx_ops = {
    .compatible_dcl          = &dcl_gl_ops,

    .dpy_gl_ctx_create       = cocoa_gl_create_context,
    .dpy_gl_ctx_destroy      = cocoa_gl_destroy_context,
    .dpy_gl_ctx_make_current = cocoa_gl_make_context_current,
};

static DisplayGLCtx gl_ctx = { .ops = &gl_ctx_ops };

#endif

static void cocoa_display_early_init(DisplayOptions *o)
{
    assert(o->type == DISPLAY_TYPE_COCOA);
    if (o->has_gl && o->gl) {
        display_opengl = 1;
    }
}

static void cocoa_display_init(DisplayState *ds, DisplayOptions *opts)
{
    COCOA_DEBUG("qemu_cocoa: cocoa_display_init\n");

    screen.cursor_show = opts->has_show_cursor && opts->show_cursor;
    screen.swap_option_command = opts->u.cocoa.has_swap_option_command &&
        opts->u.cocoa.swap_option_command;

    /* Tell main thread to go ahead and create the app and enter the run loop */
    qemu_sem_post(&display_init_sem);

    qemu_add_mouse_mode_change_notifier(&mouse_mode_change_notifier);

    qemu_event_init(&qemucb.event, false);
    cbowner = [[QemuCocoaPasteboardTypeOwner alloc] initWith:&qemucb];
    qemu_clipboard_peer_register(&cbpeer);

    dispatch_sync(dispatch_get_main_queue(), ^{
        QemuCocoaAppController* controller = (QemuCocoaAppController*)[[NSApplication sharedApplication] delegate];
        /* if fullscreen mode is to be used */
        if (opts->has_full_screen && opts->full_screen) {
            [[[appController cocoaView] window] toggleFullScreen: nil];
        }
        if (opts->u.cocoa.has_full_grab && opts->u.cocoa.full_grab) {
            [[appController cocoaView] setFullGrab: nil];
        }

        if (display_opengl) {
#ifdef CONFIG_OPENGL
            for (unsigned int i = 0; ; i++) {
                QemuConsole *con = qemu_console_lookup_by_index(i);
                if (!con) {
                    break;
                }
                qemu_console_set_display_gl_ctx(con, &gl_ctx);
            }

            if (opts->gl == DISPLAYGL_MODE_ES) {
#ifdef CONFIG_EGL
                if (qemu_egl_init_dpy_cocoa(DISPLAYGL_MODE_ES)) {
                    exit(1);
                }
                view_ctx = qemu_egl_init_ctx();
                if (!view_ctx) {
                    exit(1);
                }
                CALayer *layer = [[appController cocoaView] layer];
                egl_surface = qemu_egl_init_surface(view_ctx, layer);
#else
                error_report("OpenGLES without EGL is not supported - exiting");
                exit(1);
#endif
            } else {
                view_ctx = cocoa_gl_create_context_ns(nil, 32);
#ifdef CONFIG_EGL
                egl_surface = EGL_NO_SURFACE;
#endif
                cocoa_gl_make_context_current(NULL, view_ctx);
            }

            gls = qemu_gl_init_shader();
            glGenTextures(1, &cursor_texture);

            // register vga output callbacks
            screen.dcl.ops = &dcl_gl_ops;
#else
            error_report("OpenGL is not enabled - exiting");
            exit(1);
#endif
        } else {
            // register vga output callbacks
            screen.dcl.ops = &dcl_ops;
        }

        screen.inited = true;
    });

    register_displaychangelistener(&screen.dcl);
}

static QemuDisplay qemu_display_cocoa = {
    .type       = DISPLAY_TYPE_COCOA,
    .early_init = cocoa_display_early_init,
    .init       = cocoa_display_init,
};

static void register_cocoa(void)
{
    qemu_display_register(&qemu_display_cocoa);
}

type_init(register_cocoa);

#ifdef CONFIG_OPENGL
module_dep("ui-opengl");
#endif
