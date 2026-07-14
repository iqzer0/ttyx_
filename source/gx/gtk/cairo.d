/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/gtk/cairo.d. The biggest translation so far, because
 * giD binds cairo procedurally rather than as GtkD's OO wrappers:
 *  - There is no ImageSurface class; image surfaces are plain cairo.surface.Surface
 *    created/queried via free functions in cairo.global (imageSurfaceCreate,
 *    imageSurfaceGetWidth/Height). Context is created via cairo.global.create.
 *  - cairo enums live in cairo.types and are PascalCase (Format.Argb32,
 *    Operator.Source, Filter.Bilinear, Extend.Repeat, Content.Color).
 *  - gdk<->cairo helpers are free functions in gdk.global (cairoSetSourcePixbuf,
 *    pixbufGetFromSurface).
 *  - cairo objects are GC/wrapper-managed in giD, so the explicit .destroy()
 *    calls are dropped (the Widget .destroy() on the offscreen window stays).
 *  - gtk.Main.eventsPending/iterationDo -> gtk.global.eventsPending/mainIterationDo.
 *  - addOnDamage -> connectDamageEvent (bool delegate(EventExpose, Widget)).
 */
module gx.gtk.cairo;
import gx.gtk.events;

import std.algorithm;
import std.conv;
static if (__VERSION__ >= 2075) {
    import std.datetime.date;
    import std.datetime.stopwatch;
} else {
    import std.datetime;
}
import std.experimental.logger;

import cairo.context : Context;
import cairo.surface : Surface;
import cairo.global : create, imageSurfaceCreate, imageSurfaceGetWidth, imageSurfaceGetHeight;
import cairo.types : Format, Operator, Filter, Extend, Content;

import gdk.global : cairoSetSourcePixbuf, pixbufGetFromSurface;
import gdk.window : Window;
import gdk.event_expose : EventExpose;

import gdkpixbuf.pixbuf : Pixbuf;

import gtk.container : Container;
import gtk.global : eventsPending, mainIterationDo;
import gtk.offscreen_window : OffscreenWindow;
import gtk.widget : Widget;

Pixbuf getWidgetImage(Widget widget, double factor) {
    return getWidgetImage(widget, factor, widget.getAllocatedWidth(), widget.getAllocatedHeight());
}

// Added support for specifying width and height explicitly in cases
// where container has been realized but widget has not been, for example
// pages added to Notebook but never shown
Pixbuf getWidgetImage(Widget widget, double factor, int width, int height) {
    StopWatch sw = StopWatch(AutoStart.yes);
    scope (exit) {
        sw.stop();
        static if (__VERSION__ >= 2075) {
            tracef("Total time getting thumbnail: %d msecs", sw.peek.total!"msecs");
        }
    }
    if (widget.isDrawable()) {
        widget.queueDraw();
        static if (__VERSION__ >= 2075) {
            while (eventsPending() && sw.peek.total!"msecs"<100) {
                mainIterationDo(false);
            }
        } else {
            while (eventsPending() && sw.peek().msecs<100) {
                mainIterationDo(false);
            }
        }
        return getDrawableWidgetImage(widget, factor, width, height);
    } else {
        trace("Widget is not drawable, using OffscreenWindow for thumbnail");
        RenderWindow window = new RenderWindow();
        Container parent = cast(Container) widget.getParent();
        if (parent is null) {
            error("Parent is not a Container, cannot draw offscreen image");
            return null;
        }
        parent.remove(widget);
        window.add(widget);
        try {
            window.setDefaultSize(width, height);
            /*
            Need to process events here until Window is drawn. Use a timer as a
            guard so we don't get caught up in an infinite loop.
            */
            static if (__VERSION__ >= 2075) {
                while (!window.canDraw && eventsPending() && sw.peek.total!"msecs"<100) {
                    mainIterationDo(false);
                }
            } else {
                while (eventsPending() && sw.peek().msecs<100) {
                    mainIterationDo(false);
                }
            }
            // While we could call getPixBuf() on OffscreenWindow, drawing it
            // ourselves gives better results when dealing with transparency.
            Pixbuf pb = getDrawableWidgetImage(widget, factor, width, height);
            if (pb is null) {
                error("Pixbuf from renderwindow is null");
                return pb;
            }
            return pb;
        } finally {
            window.remove(widget);
            parent.add(widget);
            window.destroy();
            window = null;
        }
    }
}

enum ImageLayoutMode {SCALE, TILE, CENTER, STRETCH};

Surface renderImage(Pixbuf pb, bool alpha = false) {
    Format format = alpha ? Format.Argb32 : Format.Rgb24;
    Surface surface = imageSurfaceCreate(format, pb.getWidth(), pb.getHeight());
    Context cr = create(surface);
    cairoSetSourcePixbuf(cr, pb, 0, 0);
    cr.setOperator(Operator.Source);
    cr.paint();
    return surface;
}

/**
 * Renders an image onto an ImageSurface using different modes
 */
Surface renderImage(Pixbuf pbSource, int outputWidth, int outputHeight, ImageLayoutMode mode, bool alpha = false, Filter scaleMode = Filter.Bilinear) {
    Surface surface = renderImage(pbSource);
    return renderImage(surface, outputWidth, outputHeight, mode, alpha, scaleMode);
}

Surface renderImage(Surface isSource, int outputWidth, int outputHeight, ImageLayoutMode mode, bool alpha = false, Filter scaleMode = Filter.Bilinear) {
    Format format = alpha ? Format.Argb32 : Format.Rgb24;
    Surface surface = imageSurfaceCreate(format, outputWidth, outputHeight);
    Context cr = create(surface);
    if (alpha) {
        cr.setOperator(Operator.Source);
    }
    renderImage(cr, isSource, outputWidth, outputHeight, mode, scaleMode);
    return surface;
}

void renderImage(Context cr, Surface isSource, int outputWidth, int outputHeight, ImageLayoutMode mode, Filter scaleMode = Filter.Bilinear) {
    StopWatch sw = StopWatch(AutoStart.yes);
    scope (exit) {
        sw.stop();
        static if (__VERSION__ >= 2075) {
            tracef("Total time getting image: %d msecs", sw.peek.total!"msecs");
        }
    }
    int srcWidth = imageSurfaceGetWidth(isSource);
    int srcHeight = imageSurfaceGetHeight(isSource);
    final switch (mode) {
        case ImageLayoutMode.SCALE:
            double xScale = to!double(outputWidth) / to!double(srcWidth);
            double yScale = to!double(outputHeight) / to!double(srcHeight);
            double ratio = max(xScale, yScale);
            double xOffset = (outputWidth - (srcWidth * ratio)) / 2.0;
            double yOffset = (outputHeight - (srcHeight * ratio)) / 2.0;
            cr.translate(xOffset, yOffset);
            cr.scale(ratio, ratio);
            cr.setSourceSurface(isSource, 0, 0);
            cr.getSource().setFilter(scaleMode);
            cr.paint();
            break;
        case ImageLayoutMode.TILE:
            cr.setSourceSurface(isSource, 0, 0);
            cr.getSource().setExtend(Extend.Repeat);
            cr.paint();
            break;
        case ImageLayoutMode.CENTER:
            double x = (outputWidth - srcWidth)/2;
            double y = (outputHeight - srcHeight)/2;
            cr.translate(x,y);
            cr.setSourceSurface(isSource, 0, 0);
            cr.paint();
            break;
        case ImageLayoutMode.STRETCH:
            double xScale = to!double(outputWidth) / to!double(srcWidth);
            double yScale = to!double(outputHeight) / to!double(srcHeight);
            cr.scale(xScale, yScale);
            cr.setSourceSurface(isSource, 0, 0);
            cr.getSource().setFilter(scaleMode);
            cr.paint();
            break;
    }
}

private:
Pixbuf getDrawableWidgetImage(Widget widget, double factor, int width, int height) {
    int w = width;
    int h = height;
    tracef("Original: %d, %d", w, h);
    int pw = to!int(w * factor);
    int ph = to!int(h * factor);
    tracef("Factor: %f, New: %d, %d", factor, pw, ph);

    Window window = widget.getWindow();
    Surface surface = window.createSimilarSurface(Content.Color, pw, ph);
    Context cr = create(surface);
    cr.scale(factor, factor);
    widget.draw(cr);
    Pixbuf pb = pixbufGetFromSurface(surface, 0, 0, pw, ph);
    return pb;
}

class RenderWindow: OffscreenWindow {
    bool _canDraw = false;

    bool onDamage(EventExpose, Widget) {
        trace("Damage event received");
        _canDraw = true;
        return false;
    }

public:
    this() {
        super();
        connectGdkEvent!EventExpose(this, "damage-event", &onDamage);
        show();
    }

    debug(Destructors) {
        ~this() {
            import std.stdio: writeln;
            writeln("******** RenderWindow Destructor");
        }
    }

    @property bool canDraw() {
        return _canDraw;
    }
}
