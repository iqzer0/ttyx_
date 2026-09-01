# Phase 2b — WP0 status

**Branch:** `migrate/gtk4-wp0`. **This branch does not build** and is not
intended to be merged until the port is complete — `dub build` produces
nothing while any import is unresolved. Progress is tracked per-module with
`./typecheck-gtk4.sh` instead.

## The tooling problem WP0 actually had to solve

The plan said "swap deps, capture the compiler error list as the
authoritative inventory". That does not work. D has no partial compilation:
one unresolved import and the whole build produces nothing, so there is no
intermediate state where the tree compiles. Taken literally the plan meant
porting ~20 interdependent files blind and finding out at the end.

`ldc2 -o-` type-checks a *single* module without codegen or linking, which
restores a per-file feedback loop. That is what `typecheck-gtk4.sh` wraps.

One trap it encodes, which cost real time: `gid:gtk3` and `gid:gtk4` both
provide `gtk/*.d`, so a naive `-I` over every giD package resolves imports
against **GTK3** (it sorts first) and cheerfully reports the port as already
working. The script excludes `gtk3`/`gdk3`/`vte2` deliberately.

## Baseline (2026-09-01)

```
32 clean, 35 with errors
```

**32 of 67 modules already type-check clean against GTK4** — roughly half the
tree needs no change. The 35 failures each report exactly one error, because
the fatal missing-import halts that module at its first bad line; the counts
are therefore not a difficulty measure yet, only a to-do list.

## Done so far

- deps swapped to `gid:gtk4` + `gid:vte3` (no `gid:adw1` — libadwaita is
  deliberately Phase 2c, see ROADMAP)
- `libs-linux` `gdk-3` → `gtk-4`: GTK4 has no separate libgdk
- `gx/gtk/resource.d` ported and verified clean:
  `GdkScreen`→`GdkDisplay`, `addProviderForScreen`→`addProviderForDisplay`,
  and `CssProvider.loadFromData` `ubyte[]`→`string` with `void` return
  (parse failure now arrives on `parsing-error`, noted inline as a WP4 TODO)

## What the import work list looks like

The 22 removed modules split into genuinely mechanical and semantically
entangled. **The entangled ones cannot be resolved as "just imports"** — you
cannot rename `gdk.event_key` to anything, the event model changes. So WP0
is not separable from WP2/WP3/WP6 the way the plan implied; the import pass
*is* those work packages.

Mechanical (safe to sweep):

| Removed | Replacement |
|---|---|
| `gdk.screen` | `gdk.display` (7 files) |
| `gdk.window` | `gdk.surface` (4 files) |
| `gtk.bin`, `gtk.container` | gone; plain `Widget` + `setChild` |
| `gtk.icon_info` | `gtk.icon_paintable` |
| `gdk.visual` | delete (compositor handles it) |

Entangled (do as its work package, not as an import fix):

| Removed | Package |
|---|---|
| `gdk.event_*` (7 modules, 9 files) | WP2 — EventControllers |
| `gtk.event_box` | WP2 — delete the wrappers |
| `gtk.clipboard`, `gdk.atom` | WP3 — async `Gdk.Clipboard` |
| `gtk.target_entry/target_list/selection_data`, `gdk.drag_context` | DnD rework |
| `gtk.offscreen_window` | WP6 — `WidgetPaintable` |
| `gtk.file_chooser_button` | `FileDialog` |

## Two corrections to the plan, found by doing it

### 1. Dependency leverage beats mechanical-vs-entangled

The plan (and the first version of this file) said "do the mechanical sweep
first, then WP2". That is the wrong axis. Modules cannot reach *clean* until
their dependencies do, so what matters is how many modules something gates:

| Module | Imported by | Own blockers |
|---|---:|---|
| `gx.gtk.util` | **17** | mechanical (`gtk.bin`, `gtk.container`) |
| `gx.gtk.events` | **11** | none — but WP2 deletes it |
| `gx.gtk.dialog` | 6 | none (transitive only) |
| `gx.gtk.cairo` | 5 | **WP6** (`gtk.offscreen_window`) |
| `gx.gtk.clipboard` | 2 | **WP3** (`gdk.atom`) |
| `gx.gtk.x11` | 1 | mechanical (`gdk.window`) |

Consequence: **WP6 cannot be last.** `gx.gtk.cairo` gates `application.d`,
`session.d`, `appwindow.d`, `sidebar.d` and `terminal.d` — most of the app.
Porting it early unblocks far more than its size suggests. Likewise
`gx.gtk.util` at 17 dependents is the single highest-leverage item and is
purely mechanical, so it is the correct first move.

Of the 35 failing modules: 5 blocked only by mechanical removals, 15
genuinely entangled, and **15 merely transitive** — those should resolve for
free as their dependencies land.

### 2. WP8 (new) — GTK4 removed the manual main-loop pump

Not in the original plan, and it is architectural rather than mechanical:

| Removed global | Uses | Files |
|---|---:|---|
| `gtk.global.mainIterationDo` | 12 | `gtk/cairo.d`, `gtk/util.d`, `prefeditor/profileeditor.d` |
| `gtk.global.eventsPending` | 9 | `gtk/cairo.d`, `gtk/util.d` |
| `gtk.global.getCurrentEventTime` | 11 | `gtk/x11.d`, `terminal/terminal.d`, `prefeditor/titleeditor.d` |
| `gdk.global.errorTrapPush` / `errorTrapPop` | 2+2 | `gtk/x11.d` |

`gtk_events_pending` / `gtk_main_iteration_do` are gone in GTK4 — there is no
app-accessible main loop to pump, because `GtkApplication` owns it. Every
"drain pending events then continue" pattern has to become genuinely
asynchronous. That is the same shape of change as WP1's `dialog.run()` removal
and should be planned alongside it, not discovered inside it.

`gtk_get_current_event_time()` is also gone; timestamps now come from the event
that triggered the action, which interacts with WP2 (controllers are where the
event is available). The X11 error traps are gone from the portable API too, so
`gx/gtk/x11.d` needs the backend header or the traps dropped.

## Measured: the counter barely moves until WP2 lands

After porting `resource.d`, `util.d`, `x11.d`, `application.d` and splitting
`cairo.d`, the whole-tree count went from **32 clean → 33 clean**. Only
`cairo.d` newly reached clean.

That is not a sign the ports were wasted — they are all necessary — but it does
settle the sequencing argument. `gdk.event_*` is imported directly by **10
modules**, including `appwindow.d` and `terminal/terminal.d`, which almost
everything else imports; **12 of the 35 failing modules depend on a
WP2-blocked module**. Until the event model is ported, higher-level modules
cannot reach clean no matter what else is fixed, so per-module "clean" counts
stay flat and are a misleading progress metric in the meantime.

**Revised order: WP2 first, not the mechanical sweep.** The mechanical work is
cheap and safe but unblocks almost nothing on its own. Track progress by
"removed-API call sites eliminated" rather than "modules clean" until WP2 is in.

## Resuming

```bash
./typecheck-gtk4.sh --all                    # progress: N clean / M failing
./typecheck-gtk4.sh source/gx/gtk/util.d     # work one module
RAW=1 ./typecheck-gtk4.sh <file>             # include giD-internal noise
```

Suggested order, by dependency leverage rather than by difficulty:

1. `gx.gtk.util` — 17 dependents, mechanical. **Done** (see below).
2. `gx.gtk.x11` — 1 dependent but it blocks `util`. **Done.**
3. `gx.gtk.cairo` — WP6, gates 5 of the biggest modules. Do this *early*,
   not last.
4. WP8 — the main-loop pump, since `cairo.d` and `util.d` both need it.
5. WP2 — `gdk.event_*`, and delete `gx/gtk/events.d`.
6. Everything above, which is largely transitive by then.

Verified clean: `gx/gtk/resource.d`, `gx/gtk/cairo.d`.

Ported but still transitively blocked (all on WP2):
`gx/gtk/util.d` (Bin/Container → `childWidgets` first-child/next-sibling walk),
`gx/gtk/x11.d` (GdkWindow → GdkSurface via GtkNative),
`gx/ttyx/application.d` (Screen → Display).

`gx/gtk/cairo.d` was **split**: the pure cairo image composition stays and is
GTK4-clean; widget snapshotting moved verbatim to `gx/gtk/widgetimage.d`, which
is explicitly NOT ported and carries its blocker list in the module header. The
two halves shared nothing but GTK3-only API, so keeping them together blocked
`application.d` on a rewrite it has no stake in.

## WP2 pilot: the porting rulebook

`advpaste.d` (1 event site) and `search.d` (4) are fully clean. Doing them
end-to-end produced the rules below, which generalise to the remaining modules —
worth reading before touching `appwindow.d` or `terminal.d`.

### Event model (WP2)

| GTK3 | GTK4 | Note |
|---|---|---|
| `connectGdkEvent!EventKey(w,"key-press-event",dg)` | `new EventControllerKey()` + `connectKeyPressed` + `w.addController(c)` | still returns `bool`, so consuming works the same |
| `"key-release-event"` | `connectKeyReleased` | **returns `void`** — you cannot consume a release |
| `"focus-in-event"` / `"focus-out-event"` | `EventControllerFocus` `connectEnter` / `connectLeave` | callback gets the **controller**, not the widget — capture the widget from scope |

Callback shape is `(uint keyval, uint keycode, ModifierType state, Controller c)`:
the typed `EventKey` struct is gone, so `event.keyval`/`event.state` become plain
parameters.

**Check before converting a release handler:** if it ever returns `true`, the
behaviour cannot be preserved as-is. Both handlers converted so far returned
`false` unconditionally, so nothing was lost — but that has to be verified per
site, not assumed.

### Mechanical rules (apply tree-wide)

| GTK3 | GTK4 |
|---|---|
| `setMarginLeft/Right` | `setMarginStart/End` (RTL-aware) |
| `Label.setLineWrap` | `setWrap` |
| `Box.add` | `append` (or `prepend`) |
| `Box.packEnd(c,exp,fill,pad)` | no equivalent — `c.setHalign(Align.End); c.setHexpand(true); box.append(c)` |
| `Bin.add` (Frame, Revealer, ScrolledWindow, MenuButton, …) | `setChild` |
| `Image.newFromIconName(n, IconSize.X)` | `newFromIconName(n)` — **size argument is gone**, sizing is CSS |
| `Button.newFromIconName(n, IconSize.X)` | `newFromIconName(n)` |
| `setRelief(ReliefStyle.None)` | `setHasFrame(false)` |
| `ScrolledWindow.setShadowType(EtchedIn)` | `setHasFrame(true)` |
| `Frame.setShadowType(None)` | delete — GTK4 frames have no shadow |
| `Popover.newFromModel(w, model)` | `PopoverMenu.newFromModel(model)` — widget association moves to `MenuButton.setPopover` |

`IconSize` is the largest single category (72 hits) and reduces to deleting an
argument, so it is a good candidate for a scripted sweep — but note `IconSize`
must then come out of the `gtk.types` import list too, or the module fails on an
unused-import error.

### Progress

33 clean → **35 clean, 33 failing**. The two pilot modules moved, and nothing
regressed.

## IconSize sweep, and a lesson about the progress metric

Scripted across 11 files: **38 `IconSize` arguments deleted** and 11
`gtk.types` import lists pruned. `IconSize` is now **0** tree-wide, as are
`setMarginLeft`/`Right`.

The module counter did **not** move — still 35 clean, 33 failing. That is the
predicted behaviour, not a failure: `IconSize` was never the *first* error in
any of those files, so per-module "clean" cannot see the work. It is concrete
confirmation of the metric warning above.

**Track this table instead.** Remaining removed-API surface, tree-wide,
excluding comments:

| API | Sites left |
|---|---:|
| `showAll()` | 39 |
| `connectGdkEvent` | 34 |
| `ShadowType` | 25 |
| `EventBox` | 16 |
| `ReliefStyle` | 11 |
| `IconSize` | **0** ✓ |
| `setMarginLeft/Right` | **0** ✓ |

### Scripted-sweep cautions, learned the hard way

The first two attempts at this sweep introduced damage that type-checking does
not catch, so it went in three times before it was right:

1. Re-joining wrapped `import gtk.types : ...` statements into single 200+
   character lines, violating the project's own 160 soft / 170 hard limit.
2. A `\n\n\n+` → `\n\n` "tidy-up" that silently deleted **14** legitimate
   blank lines separating unrelated statements.
3. Removing `IconSize,` from the end of a wrapped line without keeping the
   newline, leaving `FileChooserAction,     MessageType` joined inline.

Any future sweep should assert all four afterwards: zero live uses remaining,
zero lines over 171 chars added, zero blank lines removed, and zero
`,\s{2,}[A-Z]` joins. Those checks are what caught all three.

## WP2 continued: three more event modules

`closedialog.d`, `bmchooser.d` and `password.d` had their event handlers
converted. All three controller ports succeeded on the first attempt using the
rulebook above — the pattern generalises, which was the point of piloting it.

Notes worth keeping:

- **`bmchooser.d` shares one named handler between two widgets.** GTK4
  controllers are per-widget, so each gets its own `EventControllerKey` wired to
  the same method; the method's signature changes from `bool(EventKey)` to
  `bool(uint, uint, ModifierType, EventControllerKey)`.
- **`closedialog.d` is NOT finished** and needs a design decision, not a
  rename. It stores a `Pixbuf` in a `TreeStore` column for the process-list
  icons, obtained via `IconTheme.lookupIcon(...).loadIcon()`. In GTK4
  `lookupIcon` returns a `GtkIconPaintable` with **no `loadIcon()`** — icons are
  no longer Pixbufs. The clean fix is to store the icon *name* in the column and
  let `CellRendererPixbuf`'s `icon-name` property do the work, which changes the
  column type and renderer wiring. Deliberately left undone rather than guessed
  at, since this is the close-confirmation dialog.

## Critical path moved again: WP8, not WP2

`password.d` now type-checks except for its dependencies, and those dependencies
are `gx/gtk/util.d` and `gx/gtk/x11.d` — both blocked on WP8
(`eventsPending`, `mainIterationDo`, `getCurrentEventTime`, the GDK error
traps). **7 of the 33 remaining failures trace to those two files.**

Since `util.d` alone is imported by 17 modules, WP8 has become the top-leverage
item, ahead of the rest of WP2. Revised order:

1. **WP8** — replace the main-loop pump and the removed globals. Unblocks
   `util.d`, therefore much of the tree.
2. WP2 remainder — `customtitle.d`, then `appwindow.d` / `terminal.d`.
3. DnD rework — `sidebar.d`, `bmtreeview.d` (`gdk.atom`, `target_entry`,
   `selection_data`, `drag_context`).
4. WP6 — `widgetimage.d`.
5. `closedialog.d`'s icon-column decision.

This is the third time the critical path has moved after contact with the code.
The pattern is consistent: leverage lives in the low-level `gx/gtk/*` modules,
not in the big obvious ones.
