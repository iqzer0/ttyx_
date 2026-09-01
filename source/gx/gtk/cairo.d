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
 *    calls are dropped.
 *
 * Widget snapshotting (getWidgetImage and the offscreen RenderWindow) moved to
 * gx.gtk.widgetimage during the GTK4 port. It shared nothing with these
 * functions but every GTK3-only API in the module, so keeping them together
 * blocked callers that only compose images — gx.ttyx.application among them —
 * on a rewrite they have no stake in. What remains here uses only cairo and
 * GdkPixbuf and is GTK4-clean as-is.
 */
module gx.gtk.cairo;

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

import gdk.global : cairoSetSourcePixbuf;

import gdkpixbuf.pixbuf : Pixbuf;

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
