/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * Correct GdkEvent signal connection — a workaround for a giD 0.9.13 bug.
 *
 * giD 0.9.13 generates the concrete GdkEvent structs (EventButton, EventKey,
 * EventScroll, EventWindowState, EventFocus, EventCrossing, EventMotion, ...)
 * as plain classes that do NOT derive from its `gobject.boxed.Boxed` base.
 * Its generated `Widget.connect*Event` marshals extract the event with
 * `getVal!EventT`, which for a non-Boxed / non-ObjectWrap class falls through
 * to `g_value_get_pointer`. But the GTK3 event signals deliver the event as a
 * boxed GdkEvent (G_TYPE_BOXED), so `g_value_get_pointer` asserts
 * `G_VALUE_HOLDS_POINTER`, returns null, and every handler connected through
 * giD's own `connect*Event` receives a NULL event — segfaulting on first field
 * access. (The build compiles fine; the fault only appears when the event
 * fires at runtime.)
 *
 * `connectEvent` below connects the same signals with a marshal that extracts
 * the event via `g_value_get_boxed` (correct for a boxed GdkEvent) and wraps it
 * with the event struct's `(void*, No.Take)` borrow constructor. The emitting
 * widget (a normal GObject) is extracted with giD's own `getVal!Widget`, which
 * works. Behavior otherwise mirrors giD's generated marshal exactly, including
 * `setVal!bool` on the return GValue and `connectSignalClosure`.
 *
 * This keeps stock, pinnable giD 0.9.13 as the dependency (no fork to rebase on
 * upgrades). If a future giD release fixes the generation (the Event subclasses
 * should extend Boxed, or getVal should g_value_get_boxed them), this module can
 * be deleted and the call sites reverted to `w.connect<Name>Event(dg)`.
 * Reported upstream: <giD Event-subclass boxed-marshal bug>.
 */
module gx.gtk.events;

import std.typecons : Flag, No;

import gid.basictypes : gulong;
import gid.gid : gidInvokeCallbackExceptionHandler;

import gobject.dclosure : DClosure, DGClosure;
import gobject.value : getVal, setVal;
import gobject.c.functions : g_value_get_boxed;
import gobject.c.types : GClosure, GValue;

import gtk.widget : Widget;

// Re-export the GdkEvent struct types so any module using connectGdkEvent!EventX
// gets the type by importing this module (some call sites previously used a
// zero-arg handler and never imported the event type themselves).
public import gdk.event_button : EventButton;
public import gdk.event_key : EventKey;
public import gdk.event_scroll : EventScroll;
public import gdk.event_focus : EventFocus;
public import gdk.event_crossing : EventCrossing;
public import gdk.event_expose : EventExpose;
public import gdk.event_window_state : EventWindowState;

/**
 * Connect a GdkEvent-carrying signal (`signalName`, e.g. "button-press-event")
 * on `widget`, delivering a correctly-unboxed `EventT` plus the emitting Widget
 * to `dg`. Drop-in replacement for giD's broken `Widget.connect<Name>Event`.
 *
 * The event is null only if GTK itself delivered no event (it does not for
 * these signals); handlers may still defensively null-check.
 */
gulong connectGdkEvent(EventT)(Widget widget, string signalName,
        bool delegate(EventT, Widget) dg, Flag!"After" after = No.After) {
    alias T = bool delegate(EventT, Widget);

    extern(C) void _cmarshal(GClosure* _closure, GValue* _returnValue, uint _nParams,
            const(GValue)* _paramVals, void* _invocHint, void* _marshalData) nothrow {
        assert(_nParams == 2, "Unexpected number of signal parameters");
        auto _dClosure = cast(DGClosure!T*) _closure;
        bool _retval;

        EventT event;
        auto _boxed = g_value_get_boxed(cast(const(GValue)*) &_paramVals[1]);
        if (_boxed !is null)
            event = new EventT(_boxed, No.Take);

        auto widgetArg = getVal!(Widget)(&_paramVals[0]);

        try {
            _retval = _dClosure.cb(event, widgetArg);
        }
        catch (Exception e) {
            gidInvokeCallbackExceptionHandler(e, "gx.gtk.events.connectEvent");
        }

        setVal!(bool)(_returnValue, _retval);
    }

    auto closure = new DClosure(dg, &_cmarshal);
    return widget.connectSignalClosure(signalName, closure, after);
}

/**
 * Arity-reduced overload for handlers that do not need the emitting widget.
 */
gulong connectGdkEvent(EventT)(Widget widget, string signalName,
        bool delegate(EventT) dg, Flag!"After" after = No.After) {
    return connectGdkEvent!(EventT)(widget, signalName,
        (EventT e, Widget w) => dg(e), after);
}

/**
 * Arity-reduced overload for handlers that use neither the event nor the widget
 * (these were never affected by the giD bug, but are converted uniformly so the
 * call sites read consistently).
 */
gulong connectGdkEvent(EventT)(Widget widget, string signalName,
        bool delegate() dg, Flag!"After" after = No.After) {
    return connectGdkEvent!(EventT)(widget, signalName,
        (EventT e, Widget w) => dg(), after);
}
