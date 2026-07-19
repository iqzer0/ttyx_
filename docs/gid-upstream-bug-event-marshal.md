# Draft upstream bug report for giD (github.com/Kymorphia/gid)

Status: **already reported upstream as
[Kymorphia/gid#52](https://github.com/Kymorphia/gid/issues/52)**
("Event delegates in gtk3 events struct incorrectly extracted from signal
handler resulting in null pointer", opened 2026-06-11 against 0.9.12, still
open with no maintainer response as of 2026-07-19). Do NOT file a duplicate —
instead post the analysis below as a COMMENT on #52: it adds the root cause
(the concrete Event classes don't derive from `gobject.boxed.Boxed`, so
`getVal` falls through to `g_value_get_pointer`), a minimal repro, a suggested
generator-level fix, and a link to a reusable drop-in workaround.
Our workaround lives in [`source/gx/gtk/events.d`](../source/gx/gtk/events.d)
and can be deleted once a fixed giD release is pinned.

The **abstract-GObject-subclass startup segfault** (bottom of this file) is a
separate, unreported bug — that one would be a NEW issue.

---

**Title:** GTK3 `connect*Event` handlers receive a null event — Event subclasses aren't Boxed, marshal falls through to `g_value_get_pointer`

**Affected version:** gid 0.9.13 (latest on code.dlang.org at time of writing), `gid:gtk3` + `gid:gdk3`, LDC 1.40.0, GTK 3.24.

## Summary

Every generated `Widget.connect<Name>Event` overload for the GdkEvent-carrying
GTK3 signals (`button-press-event`, `key-press-event`, `scroll-event`,
`focus-in/out-event`, `window-state-event`, `enter/leave-notify-event`, …)
delivers a **null** event object to the D callback at runtime. The build is
clean; the fault only appears when the signal fires and the handler
dereferences the event — typically a segfault on first field access, preceded
by:

```
GLib-GObject-CRITICAL **: g_value_get_pointer: assertion 'G_VALUE_HOLDS_POINTER (value)' failed
```

## Cause

The concrete event classes generated into `gdk3/gdk/event_button.d`,
`event_key.d`, `event_scroll.d`, `event_window_state.d`, `event_focus.d`,
`event_crossing.d`, `event_motion.d`, `event_expose.d` … are plain classes:

```d
class EventWindowState        // no base class — does NOT extend gobject.boxed.Boxed
{
  GdkEventWindowState _cInstance;
  this(void* ptr, Flag!"Take" take) nothrow { ... }
  ...
}
```

The generated signal marshal extracts parameters with
`getVal!(Parameters!T[i])`. `getVal`'s dispatch in
`glib2/gobject/value.d` has branches for `is(T : Boxed)`, `isBoxed!T`,
`is(T : ObjectWrap)` — and a fallback:

```d
else static if (is(T : Object) || isPointer!T)
  return cast(T)g_value_get_pointer(gval);
```

Since `EventButton` etc. are plain `Object`s, extraction goes through
`g_value_get_pointer`. But GTK3's event signals deliver the event as a
**boxed** `GdkEvent` (`G_VALUE_HOLDS_BOXED`), so the assertion fails, the
getter returns null, and the callback receives a null event.

Note the base `gdk.event.Event` class *does* extend `Boxed` and works; only
the concrete per-signal event classes are affected. `cairo.context.Context`
(the `draw` signal) also extends `Boxed` and is fine.

## Reproduction

```d
import gtk.application, gtk.application_window, gtk.widget;
import gdk.event_window_state;
import gio.types : ApplicationFlags;

void main(string[] args) {
    auto app = new Application("test.nullevent", ApplicationFlags.FlagsNone);
    app.connectActivate(() {
        auto win = new ApplicationWindow(app);
        win.connectWindowStateEvent((EventWindowState e, Widget w) {
            // e is ALWAYS null here; any field access segfaults
            import std.stdio; writeln(e is null ? "NULL EVENT" : "ok");
            return false;
        });
        win.showAll();
    });
    app.run(args);
}
```

Run it and unmap/remap or maximize the window: it prints `NULL EVENT`
(or segfaults if the handler reads a field), with the
`g_value_get_pointer` CRITICAL on stderr.

## Expected

The callback receives a valid `EventWindowState` wrapping the delivered
boxed `GdkEvent`.

## Suggested fix

Either:
- generate the concrete `Event*` classes deriving from `gobject.boxed.Boxed`
  (they wrap a boxed `GdkEvent`), so `getVal`'s `is(T : Boxed)` branch handles
  them; or
- special-case the event classes in `getVal`/the signal marshal to extract via
  `g_value_get_boxed` and construct with the existing `(void*, Flag!"Take")`
  constructor.

## Workaround we use

A drop-in replacement connector whose marshal extracts the event with
`g_value_get_boxed` and wraps it via the `(ptr, No.Take)` constructor:
<https://github.com/gwelr/ttyx_/blob/migrate/gid-build-swap/source/gx/gtk/events.d>

Related runtime gotcha found while migrating (report separately if useful):
`ObjectWrap.createClassMaps()` calls `_d_newclass` on every `ObjectWrap`-derived
class at startup; for an `abstract` class `_d_newclass` returns null and the
subsequent `._gType` dereference segfaults — i.e. user code cannot declare
abstract GObject subclasses.
