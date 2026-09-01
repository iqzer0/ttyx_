/*-
 * Copyright (c) 2005-2007 Benedikt Meurer <benny@xfce.org>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 2 of the License, or (at your option)
 * any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * giD port of source/gx/gtk/x11.d.
 *
 * giD does not bind the GDK X11 backend, and its xlib2 binding lacks the raw
 * event types (XClientMessageEvent / XSendEvent). So this port:
 *   - reuses ttyx_'s vendored, GtkD-free x11.X / x11.Xlib bindings for raw Xlib;
 *   - declares the four gdk_x11_* backend helpers (plus gdk_x11_surface_get_xid)
 *     directly as extern(C) — they resolve at link time from libgdk-3, so no
 *     runtime Linker is needed (GtkD had to dlsym them);
 *   - uses giD's gtk.global / gdk.global for the current-event-time and error
 *     trap / flush calls, and reaches the underlying GdkSurface* via _cPtr.
 *
 * NOTE: the raw _NET_ACTIVE_WINDOW event send cannot be exercised in a headless
 * build; verify window activation on a real X11 session.
 */
module gx.gtk.x11;

import std.experimental.logger;
import std.string;

import gdk.display : GdkDisplayWrap = Display;
import gdk.surface : GdkSurfaceWrap = Surface;
import gdk.c.types : GdkDisplay, GdkSurface;

import gtk.window : GtkWindow = Window;

import x11.X : Atom, ClientMessage, StructureNotifyMask, XWindow = Window;
import x11.Xlib : Display, XClientMessageEvent, XSendEvent, XEvent;

/**
 * This function activates an X11 window using the _NET_ACTIVE_WINDOW
 * event for X11. Works around some edge cases with respect to window focus.
 *
 * Code was translated from a C version in xfce4_terminal, see original here:
 * http://bazaar.launchpad.net/~vcs-imports/xfce4-terminal/trunk/view/head:/terminal/terminal-util.c
 *
 * The original xfce code was licensed under GPL and that license remains in
 * effect for this method only, since code translations are considered a
 * derived work under GPL.
 */
void activateX11Window(GtkWindow window) {
    // GTK4: GdkWindow became GdkSurface, reached via the GtkNative interface
    // that GtkWindow implements, rather than gtk_widget_get_window().
    GdkSurfaceWrap gdkWindow = window.getSurface();
    GdkDisplayWrap gdkDisplay = gdkWindow.getDisplay();

    // GTK4 removed gtk_get_current_event_time(); there is no global "time of
    // the event being handled" any more (it now comes from the specific event
    // or controller, which this function has no access to). The GTK3 code
    // already fell back to the X server time whenever it was outside an event
    // handler, so use that unconditionally. A real event timestamp is
    // marginally better for focus-stealing prevention, so if this ever needs
    // tightening, thread the time in from the caller's controller.
    uint timestamp = gdk_x11_get_server_time(cast(GdkSurface*) gdkWindow._cPtr);

    XClientMessageEvent event;
    event.type = ClientMessage;
    event.window = gdk_x11_surface_get_xid(cast(GdkSurface*) gdkWindow._cPtr);
    const(char*) name = toStringz("_NET_ACTIVE_WINDOW");
    event.message_type = gdk_x11_get_xatom_by_name(name);
    event.format = 32;
    event.data.l[0] = 1;
    event.data.l[1] = timestamp;
    event.data.l[2] = event.data.l[3] = event.data.l[4] = 0;

    Display* display = gdk_x11_get_default_xdisplay();
    XWindow root = gdk_x11_get_default_root_xwindow();

    // GTK4 dropped the portable gdk_error_trap_* API entirely; error trapping
    // is X11-backend-only now and takes the display explicitly.
    GdkDisplay* rawDisplay = cast(GdkDisplay*) gdkDisplay._cPtr;
    gdk_x11_display_error_trap_push(rawDisplay);
    XSendEvent(display, root, false, StructureNotifyMask, cast(XEvent*) &event);
    gdkDisplay.flush();
    if (gdk_x11_display_error_trap_pop(rawDisplay) != 0) {
        error("Failed to focus window");
    }
}

private:

// GDK X11 backend helpers. giD does not bind the GDK X11 backend, so declare
// them directly; they resolve at link time from libgtk-4 (GTK4 has no separate
// libgdk).
extern(C) {
    Atom gdk_x11_get_xatom_by_name(const(char)* atom_name);
    void gdk_x11_display_error_trap_push(GdkDisplay* display);
    int gdk_x11_display_error_trap_pop(GdkDisplay* display);
    Display* gdk_x11_get_default_xdisplay();
    XWindow gdk_x11_get_default_root_xwindow();
    uint gdk_x11_get_server_time(GdkSurface* surface);
    XWindow gdk_x11_surface_get_xid(GdkSurface* surface);
}
