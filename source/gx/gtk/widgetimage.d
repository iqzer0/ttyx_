/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/**
 * Rendering a live widget to a Pixbuf (session thumbnails, drag previews).
 *
 * Split out of gx.gtk.cairo during the GTK4 port; that module's pure cairo
 * composition needs no GTK4 changes, while this needed a rewrite.
 *
 * GTK3 did this by drawing the widget into a cairo surface with
 * gtk_widget_draw(), and — for widgets not yet drawable — by reparenting them
 * into a GtkOffscreenWindow and spinning the main loop until it had painted.
 * Every piece of that is gone in GTK4: gtk_widget_draw, GtkOffscreenWindow,
 * gtk_main_iteration_do, GdkWindow.createSimilarSurface, damage-event.
 *
 * The GTK4 path is the scene graph: GtkWidgetPaintable renders a widget's
 * current snapshot, which is turned into a GskRenderNode and rendered to a
 * GdkTexture by the renderer of the widget's toplevel, then converted to a
 * Pixbuf so the callers (an Image, a drag icon) are unchanged.
 *
 * Behaviour differences, both consequences of GTK4 having no offscreen
 * rendering of unrealized widgets:
 *   - a widget that is not mapped, or has no toplevel yet, yields null rather
 *     than a rendering forced through an offscreen window. Callers must
 *     null-check (the GTK3 code returned null on failure too, so they should
 *     already).
 *   - there is no event-loop spin; the snapshot is whatever GTK has laid out
 *     right now. That is also why this is dramatically simpler.
 */
module gx.gtk.widgetimage;

import std.conv : to;
import std.experimental.logger;

import gdk.global : pixbufGetFromTexture;
import gdk.texture : Texture;

import gdkpixbuf.pixbuf : Pixbuf;

import gsk.render_node : RenderNode;
import gsk.renderer : Renderer;

import gtk.native : Native;
import gtk.snapshot : Snapshot;
import gtk.widget : Widget;
import gtk.widget_paintable : WidgetPaintable;

Pixbuf getWidgetImage(Widget widget, double factor) {
    return getWidgetImage(widget, factor, widget.getAllocatedWidth(), widget.getAllocatedHeight());
}

// Width and height may be given explicitly for widgets whose allocation is not
// meaningful yet, e.g. notebook pages that have never been shown.
Pixbuf getWidgetImage(Widget widget, double factor, int width, int height) {
    if (widget is null || width <= 0 || height <= 0) return null;

    // The renderer belongs to the toplevel (GtkNative). Without one there is
    // nothing that can rasterise a render node — this is the GTK4 analogue of
    // the old "widget is not drawable" case, minus the offscreen fallback.
    Native native = widget.getNative();
    if (native is null) {
        trace("Widget has no native toplevel, cannot render thumbnail");
        return null;
    }
    Renderer renderer = native.getRenderer();
    if (renderer is null) {
        trace("Toplevel has no renderer yet, cannot render thumbnail");
        return null;
    }

    int pw = to!int(width * factor);
    int ph = to!int(height * factor);
    if (pw <= 0 || ph <= 0) return null;
    tracef("Rendering widget snapshot: %d,%d at factor %f -> %d,%d", width, height, factor, pw, ph);

    // Snapshot the widget at the target size; the paintable scales its
    // rendering to the requested dimensions, which replaces the cr.scale()
    // the cairo path applied.
    WidgetPaintable paintable = new WidgetPaintable(widget);
    Snapshot snapshot = new Snapshot();
    paintable.snapshot(snapshot, pw, ph);
    RenderNode node = snapshot.toNode();
    if (node is null) {
        // An unmapped widget snapshots to nothing.
        trace("Widget snapshot produced no render node");
        return null;
    }

    Texture texture = renderer.renderTexture(node, null);
    if (texture is null) return null;
    return pixbufGetFromTexture(texture);
}
