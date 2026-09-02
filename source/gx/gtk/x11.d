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

import x11.X : Atom, ClientMessage, StructureNotifyMask, SubstructureNotifyMask, SubstructureRedirectMask, XWindow = Window;
import x11.Xlib : Display, XClientMessageEvent, XSendEvent, XEvent, XMoveResizeWindow, XFlush;

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
    // GTK4 dropped the "default display" X11 conveniences; every gdk_x11_*
    // call below takes the display explicitly.
    GdkDisplay* rawDisplay = cast(GdkDisplay*) gdkDisplay._cPtr;

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
    event.message_type = gdk_x11_get_xatom_by_name_for_display(rawDisplay, name);
    event.format = 32;
    event.data.l[0] = 1;
    event.data.l[1] = timestamp;
    event.data.l[2] = event.data.l[3] = event.data.l[4] = 0;

    Display* display = gdk_x11_display_get_xdisplay(rawDisplay);
    XWindow root = gdk_x11_display_get_xrootwindow(rawDisplay);

    // GTK4 dropped the portable gdk_error_trap_* API entirely; error trapping
    // is X11-backend-only now.
    gdk_x11_display_error_trap_push(rawDisplay);
    XSendEvent(display, root, false, StructureNotifyMask, cast(XEvent*) &event);
    gdkDisplay.flush();
    if (gdk_x11_display_error_trap_pop(rawDisplay) != 0) {
        error("Failed to focus window");
    }
}

/**
 * X11 window id of a realized surface, or 0 when not on X11.
 *
 * GtkD exposed this as gdk.X11.getXid on a GdkWindow. giD binds no X11
 * backend at all, so the raw gdk_x11_surface_get_xid is declared below and
 * wrapped here for the one caller (terminal.d, which exports WINDOWID to the
 * child process). Callers should already have checked !isWayland().
 */
ulong surfaceXid(GdkSurfaceWrap surface) {
    if (surface is null) return 0;
    return cast(ulong) gdk_x11_surface_get_xid(cast(GdkSurface*) surface._cPtr);
}

/**
 * Keep a window out of the taskbar and pager (quake mode). GTK4 removed the
 * GtkWindow skip-taskbar/pager hints; the X11 backend still has them on the
 * surface, which exists only once the window is realized. Callers must have
 * checked !isWayland(), as with surfaceXid.
 */
void setSkipTaskbarAndPager(GdkSurfaceWrap surface, bool skip) {
    if (surface is null) return;
    gdk_x11_surface_set_skip_taskbar_hint(cast(GdkSurface*) surface._cPtr, skip ? 1 : 0);
    gdk_x11_surface_set_skip_pager_hint(cast(GdkSurface*) surface._cPtr, skip ? 1 : 0);
}

/**
 * Move and resize a realized surface through the X server.
 *
 * GTK4 removed client-side positioning from the portable API on every backend
 * (gtk_window_move, gdk_window_move_resize), which is what quake mode needs.
 * Quake is X11-only in this application — the AppWindow constructor refuses it
 * under Wayland and says so — so the request goes to X directly, which is what
 * GDK itself used to do here.
 *
 * The window manager is free to adjust the request; under a reparenting WM the
 * coordinates apply to our frame. Callers must have checked !isWayland().
 */
void moveResizeSurface(GdkSurfaceWrap surface, int x, int y, int width, int height) {
    if (surface is null) return;
    GdkDisplayWrap gdkDisplay = surface.getDisplay();
    if (gdkDisplay is null) return;

    GdkDisplay* rawDisplay = cast(GdkDisplay*) gdkDisplay._cPtr;
    Display* display = gdk_x11_display_get_xdisplay(rawDisplay);
    XWindow xid = gdk_x11_surface_get_xid(cast(GdkSurface*) surface._cPtr);

    gdk_x11_display_error_trap_push(rawDisplay);
    XMoveResizeWindow(display, xid, x, y, width, height);
    XFlush(display);
    if (gdk_x11_display_error_trap_pop(rawDisplay) != 0) {
        error("Failed to move and resize window");
    }
}

/**
 * Add or remove an EWMH window state (`_NET_WM_STATE_ABOVE`,
 * `_NET_WM_STATE_STICKY`, ...) on a realized surface.
 *
 * GTK4 dropped the GtkWindow wrappers for these hints (set_keep_above,
 * stick/unstick) because they are window-manager policy rather than toolkit
 * state. The underlying EWMH message is unchanged, so the quake preferences
 * that depended on them keep working on X11. Callers must have checked
 * !isWayland(); a WM that does not implement the state simply ignores it.
 */
void setNetWmState(GdkSurfaceWrap surface, string state, bool enabled) {
    if (surface is null) return;
    GdkDisplayWrap gdkDisplay = surface.getDisplay();
    if (gdkDisplay is null) return;

    GdkDisplay* rawDisplay = cast(GdkDisplay*) gdkDisplay._cPtr;
    Display* display = gdk_x11_display_get_xdisplay(rawDisplay);
    XWindow root = gdk_x11_display_get_xrootwindow(rawDisplay);

    XClientMessageEvent event;
    event.type = ClientMessage;
    event.window = gdk_x11_surface_get_xid(cast(GdkSurface*) surface._cPtr);
    event.message_type = gdk_x11_get_xatom_by_name_for_display(rawDisplay, toStringz("_NET_WM_STATE"));
    event.format = 32;
    // _NET_WM_STATE_REMOVE = 0, _NET_WM_STATE_ADD = 1
    event.data.l[0] = enabled ? 1 : 0;
    event.data.l[1] = gdk_x11_get_xatom_by_name_for_display(rawDisplay, toStringz(state));
    event.data.l[2] = 0;
    // Source indication: 1 = normal application, per EWMH.
    event.data.l[3] = 1;
    event.data.l[4] = 0;

    gdk_x11_display_error_trap_push(rawDisplay);
    XSendEvent(display, root, false, SubstructureNotifyMask | SubstructureRedirectMask, cast(XEvent*) &event);
    XFlush(display);
    if (gdk_x11_display_error_trap_pop(rawDisplay) != 0) {
        errorf("Failed to set window state %s", state);
    }
}

private:

// GDK X11 backend helpers. giD does not bind the GDK X11 backend, so declare
// them directly; they resolve at link time from libgtk-4 (GTK4 has no separate
// libgdk).
extern(C) {
    // Quake-mode taskbar/pager hints (GtkWindow lost them in GTK4).
    void gdk_x11_surface_set_skip_taskbar_hint(GdkSurface* surface, int skips_taskbar);
    void gdk_x11_surface_set_skip_pager_hint(GdkSurface* surface, int skips_pager);
    Atom gdk_x11_get_xatom_by_name_for_display(GdkDisplay* display, const(char)* atom_name);
    void gdk_x11_display_error_trap_push(GdkDisplay* display);
    int gdk_x11_display_error_trap_pop(GdkDisplay* display);
    Display* gdk_x11_display_get_xdisplay(GdkDisplay* display);
    XWindow gdk_x11_display_get_xrootwindow(GdkDisplay* display);
    uint gdk_x11_get_server_time(GdkSurface* surface);
    XWindow gdk_x11_surface_get_xid(GdkSurface* surface);
}
