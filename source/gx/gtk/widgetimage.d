/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/**
 * Rendering a live widget to a Pixbuf (session thumbnails, drag previews).
 *
 * Split out of gx.gtk.cairo during the GTK4 port. That module mixed two
 * unrelated things: pure cairo image composition, which needs no GTK4 changes
 * at all, and this — widget snapshotting, which needs a near-total rewrite.
 * Keeping them together meant the pure half could not be used until the hard
 * half was done, blocking gx.ttyx.application on work it has no stake in.
 *
 * GTK4 STATUS: NOT YET PORTED. Everything below still uses GTK3-only API and
 * will not compile against gid:gtk4. It is retained verbatim so the behaviour
 * is documented while the replacement is designed. Blockers:
 *
 *   - GtkOffscreenWindow is removed outright, so the "widget is not drawable"
 *     fallback has no direct equivalent.
 *   - gtk_widget_draw(cr) is removed; GTK4 renders through GskRenderNode via
 *     the snapshot vfunc.
 *   - gtk_events_pending / gtk_main_iteration_do are removed (WP8) — there is
 *     no app-accessible main loop to pump, so the "spin until drawn, with a
 *     100ms guard" pattern has to become genuinely asynchronous.
 *   - gdk_widget_get_window / createSimilarSurface: GdkWindow became
 *     GdkSurface and no longer offers createSimilarSurface.
 *   - the damage-event signal is gone with the offscreen window.
 *
 * Intended replacement (see docs/gtk4-migration-plan.md, WP6): GtkWidgetPaintable
 * renders a live widget, and GtkDragSource.setIcon accepts a GdkPaintable
 * directly — so the drag-preview caller gets simpler, and the thumbnail caller
 * becomes paintable -> GskRenderNode -> GdkTexture instead of
 * offscreen-window -> cairo -> Pixbuf.
 */
module gx.gtk.widgetimage;

import gx.gtk.events;

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
import cairo.global : create;
import cairo.types : Content;

import gdk.global : pixbufGetFromSurface;
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
