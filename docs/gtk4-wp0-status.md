# Phase 2b — WP0 status

**Branch:** `migrate/gtk4-wp0`. **This branch now builds** (`dub build`,
since the 68/68 checkpoint at the end of this file) but has only been
exercised to startup; it is not intended to be merged until the runtime
verification list there is worked through. Until the first build, progress was
tracked per-module with `./typecheck-gtk4.sh`, and the sections below are kept
as the record of how the port was sequenced and why.

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

## WP8 resolved — and it was smaller than the plan claimed

The plan called WP8 "the same shape of change as WP1's `dialog.run()` removal",
i.e. architectural. That was wrong on the main point:

**GLib's `MainContext.pending()` / `iteration(bool)` survive GTK4 untouched.**
GTK4 only removed the *GTK-level wrappers* `gtk_events_pending` and
`gtk_main_iteration_do`; the underlying main-context API they wrapped is still
there, with identical semantics. Any bounded event drain can be reimplemented
directly on it — no async redesign required.

And in `util.d` it did not even need that: **`processEvents` had zero callers.**
It was dead code, so the blocker was removed by deleting it (with a note
pointing at `MainContext` should the utility ever be wanted again).

The genuinely-removed items in WP8 are narrower than feared:

| Item | Resolution |
|---|---|
| `gtk_events_pending` / `gtk_main_iteration_do` | GLib `MainContext.pending()`/`iteration()`; in `util.d`, dead code — deleted |
| `gdk_error_trap_push/pop`, `gdk_flush` | **Gone from portable GDK.** X11-backend only now; declared `extern(C)` as `gdk_x11_display_error_trap_push/pop` alongside the other `gdk_x11_*` calls `x11.d` already declares. `flush` → `Display.flush()` |
| `gtk_get_current_event_time` | **No global replacement.** GTK3 returned 0 outside an event handler and `x11.d` already fell back to `gdk_x11_get_server_time`, so that fallback is now unconditional. Slightly weaker for focus-stealing prevention; thread a controller timestamp in if it matters |

### One real capability loss: theme background colour

`gtk_style_context_get_background_color()` is **removed with no replacement** —
GTK4 backgrounds are CSS-rendered and not queryable at all. `renderer.d` used it
for the shipped `use-theme-colors` profile option and for the selection colour.

`lookupColor()` does survive, so `getStyleBackgroundColor` now looks up the
conventional theme colour names (`theme_base_color`, then `theme_bg_color`) and
returns bool. Two things are genuinely lost and are documented at the function:

- **the `StateFlags` argument is now inert** — per-state background colours
  cannot be resolved, so Selected vs Active is no longer distinguishable
- a theme that defines neither name yields false, so callers must treat the
  result as best-effort

This needs a look with real themes once the tree runs. It is the first change in
the port that degrades a user-visible feature rather than relocating it.

### Cascade

**35 clean → 39 clean, 29 failing.** `util.d` and `x11.d` went clean directly;
`colorschemes.d` and `renderer.d` came free, having been transitively blocked.
Largest single jump so far, and exactly what the dependency-leverage reading
predicted — `util.d` has 17 importers.

## Compiler-driven sweeps (`sweep-container-api.py`)

`GtkContainer.add` split into type-specific methods in GTK4, so the right
replacement depends on the receiver's **type** — `Box` takes `append`, anything
Bin-like takes `setChild`. That cannot be inferred from a variable name, and the
receivers here are locals (`box`, `bContent`, `bButtons`, `sw`, …), so a
name-based sweep would be guesswork.

But the compiler states the type outright:

```
no property `add` for `box` of type `gtk.box.Box`
```

`sweep-container-api.py` drives the rewrite off that. It loops, because each
pass lets modules compile further and reveal more sites, and it **skips
unmapped types with a warning rather than guessing** — which is how
`ShortcutsGroup` was caught (GTK4 wants the typed `addShortcut`, not `setChild`).

First run: 32 sites (30 `Box`→`append`, 2 `ScrolledWindow`→`setChild`), all four
formatting assertions clean. **175 `.add(` sites remain** — they sit in modules
still blocked by earlier errors, so the compiler has not reported their types
yet. The sweep converges as blockers clear; re-run it after each batch.

This is the general technique for the rest of the port: where a rename depends
on type information, harvest it from the compiler instead of pattern-matching
source text.

### Remaining surface

| API | Sites |
|---|---:|
| `.add(` | 175 (convergent — re-run the sweep) |
| `showAll()` | 39 |
| `getToplevel()` | 29 |
| `.run()` | 26 (**WP1**, architectural) |
| `setNoShowAll` | 18 |
| `setLineWrap` | 4 |

`showAll`/`setNoShowAll` need care rather than a script: GTK4 widgets are
visible by default and `setNoShowAll` is gone, so the pair has to be read
together per site — some become `present()`, some `setVisible(false)`, many just
delete.

**41 clean, 27 failing.**

## Checkpoint: 42 / 68 clean

`gx/gtk/clipboard.d` ported. GTK4 removed `GdkAtom` and the atom-named-selection
model entirely: there are exactly two clipboards, obtained as objects from a
widget or display rather than looked up by interned name. The three `Atom`
constants collapse to a two-value `ClipboardSelection` enum plus
`selectionClipboard(widget, selection)`. `GDK_SELECTION_SECONDARY` is dropped —
GTK4 has no such clipboard and it had no callers.

Consumers that thread an `Atom` through (`ClipboardHandler.paste(Atom)`) should
thread a `ClipboardSelection` and resolve it against their own widget, since the
clipboard is per-display.

### The remaining 26, by what they actually need

| Need | Modules | Nature |
|---|---:|---|
| WP2 — events → controllers | 7 | pattern known, rulebook above |
| WP3 / DnD — `gdk.atom`, `target_*`, `selection_data`, `drag_context` | 6 | **redesign**: sync → async clipboard, DnD → `DragSource`/`DropTarget` |
| `FileChooserButton` → `FileDialog` | 3 | redesign (async dialog) |
| `getCurrentEventTime` | 2 | needs a controller-supplied timestamp (couples to WP2) |
| icon column (`closedialog`, `manager`) | 2 | **decision**: `Pixbuf` → `icon-name` in the tree model |
| visibility (`showAll` / `setNoShowAll`) | 2 | per-site reading, not scriptable |
| mechanical | 2 | sweepable |
| WP1 — `dialog.run` | 1 file, 26 sites | **architectural**, and the paste path is security-critical |

### What changes from here

Everything cheap is done. Of the 26 remaining, only ~4 are mechanical or
pattern-known; the rest are genuine redesigns — async clipboard, GTK4 drag and
drop, `FileDialog`, the icon-column decision, and WP1's nested-main-loop
removal. Those need design choices, and several are user-visible.

Two consequences worth stating plainly:

1. **Progress will slow sharply and the module counter will jump in steps**, not
   smoothly — the redesigns unblock several dependents at once when they land.
2. **Type-checking clean stops being good evidence** from here. The remaining
   work changes *behaviour* — event phases, async ordering, visibility, focus,
   drag semantics — none of which the compiler checks. Nothing in this branch
   has ever been *run*, and it cannot be until the whole tree compiles. Budget
   real GUI testing before trusting any of it.

## WP2 reference: the remaining controller types

Beyond `EventControllerKey` / `EventControllerFocus` already used, the sites left
need three more. Callback shapes verified against giD 0.9.13:

| GTK3 event | GTK4 | Callback |
|---|---|---|
| `EventButton` | `GestureClick` | `void(int nPress, double x, double y, GestureClick)` |
| `EventScroll` | `EventControllerScroll` | `connectScroll` (plus begin/end/decelerate) |
| `EventCrossing` | `EventControllerMotion` | `void(double x, double y, EventControllerMotion)` |
| `EventWindowState` | `Window` properties | notify on `maximized` / `fullscreened` |

### Three behavioural traps in this group

1. **`GestureClick.pressed` returns `void`.** GTK3's `button-press-event`
   returned bool to consume the event. To consume with a gesture you must call
   `setState(EventSequenceState.Claimed)` explicitly — returning nothing is
   *not* equivalent to returning false, and silently letting a click propagate
   where it used to be consumed is a real behaviour change.
2. **Button number is not a callback parameter.** GTK3 read `event.button`;
   GTK4 reads `gesture.getCurrentButton()`, and a `GestureClick` only reports
   the button it was configured for via `setButton` (0 = any).
3. **Double-click is `nPress == 2`**, not `EventType._2buttonPress`.

`terminal.d` uses all three of these — `event.button == BUTTON_MIDDLE`,
`EventType._2buttonPress` for the maximize toggle, and coordinate hit-testing
against the menu button — so it is the site where getting this wrong is least
likely to be noticed by the compiler and most likely to be noticed by a user.

### Remaining WP2 sites (6 modules, ~24 sites)

| Module | Sites |
|---|---:|
| `terminal/terminal.d` | 9 (Button 3, Key 2, Focus 2, Scroll 1, Crossing 1) |
| `appwindow.d` | 7 (Focus 3, WindowState 1, Scroll 1, Key 1, Button 1) |
| `customtitle.d` | 4 |
| `sidebar.d` | 3 |
| `session.d` | 1 |
| `gtk/widgetimage.d` | 1 (Expose — belongs to WP6) |

`gx/gtk/events.d` is deleted once these are converted. It is imported by exactly
these six modules, and it gates 8 modules transitively — including `session.d`,
whose container `add`/`remove` calls **cannot be type-checked until events.d is
gone**, because compilation stops at the import error.

## Checkpoint: 48 / 68 clean — DnD, WP6, icons, remaining WP2 done

Landed since the 44/25 checkpoint:

- **WP2 complete.** `appwindow.d`, `terminal.d`, `customtitle.d`, `sidebar.d`,
  `session.d` converted; `gx/gtk/events.d` — the Kymorphia/gid#52 workaround
  — **deleted** (no `*-event` signals in GTK4, nothing left for the bug to
  bite). `Terminal` itself extended `GtkEventBox`; it is now a `Box`.
- **WP6 complete.** `widgetimage.d` on `WidgetPaintable → Snapshot →
  RenderNode → Native.getRenderer().renderTexture → pixbufGetFromTexture`.
  Unrealized widgets yield null instead of an offscreen render.
- **DnD reworked** in `terminal.d` and `sidebar.d` on `DragSource` +
  `DropTargetAsync` with `ContentProvider.newForBytes`. The payloads stay
  mime-typed (`VTE_DND` / `SESSION_DND`), deliberately: a GType-based
  `DropTarget` with a string payload would let a dragged terminal drop into any
  text entry as its UUID. Our own mime types give the old `SameApp` semantics
  for free. Source identity for motion-time checks comes from a static
  `_draggingTerminalUUID` set in `prepare` (GTK4 has no
  `gtk_drag_get_source_widget`). "Dropped on the desktop → detach" is
  `connectDragCancel` with `DragCancelReason.NoTarget`; the new window can no
  longer be placed at the pointer (no positioning in GTK4, WP5).
- **Bookmark drag-reordering is DISABLED**, not faked. GTK4 `TreeView` keeps
  `enableModelDrag*` but has no `drag-data-received`; the model reorders its
  own rows without consulting the app, which would desync the persisted
  BookmarkManager. A half-working reorder is worse than none. Re-enable once
  the manager can observe the model or a custom `TreeDragDest` exists.
- **Bookmark and close-dialog icons** are theme *names* in the model, rendered
  by `CellRendererPixbuf`'s `icon-name`. Deletes the IconTheme probing, the
  hand-rolled symbolic recolouring, and the cache.
- **Fixed a real leak while porting:** the root/SSH indicator CSS providers
  were added to the screen once *per terminal* and never removed. Now once per
  process, on the display.
- `getToplevel()` → `getRoot()`; `showUri` → `UriLauncher`; `WINDOWID` via
  `gx.gtk.x11.surfaceXid`.

### What gates the rest

`terminal.d` has no removed-module imports left. Its whole dependency chain now
stops at **`terminal/clipboard.d`'s `gdk.atom`** — WP3. That module's paste
path also calls `dialog.run()` (WP1), so the two collide there, on the
security-critical approve-then-send invariant. ~8 modules chain through it.
It is the next target and the one to do most carefully: the callback must paste
the text it read and showed the user, never re-read the clipboard.

## Checkpoint: 68 / 68 type-check clean

```
68 clean, 0 with errors
```

Every module now type-checks against GTK4. This is the end of WP0 as a
per-module exercise; what follows is a real `dub build`, then running it.
Nothing in this branch has been executed yet — see "Verify at runtime" below.

### Landed since 48 / 68

- **WP3 — async clipboard, paste path.** `terminal/clipboard.d` reads the
  clipboard once (`readClipboard`), and everything downstream — sanitising,
  the review/unsafe dialogs, `commitPaste` (the single send point) — acts on
  that captured string. The callback never re-reads the clipboard, so what the
  user approved is what gets pasted. Auto-clear compares the clipboard content
  before clearing.
- **WP1 complete — all `dialog.run()` sites gone.** Three shapes:
  fire-and-forget (`showErrorDialog`); value-returning helpers rewritten with a
  continuation (`showInputDialog(…, then)`, `showConfirmDialog(…, then)`,
  `promptCanCloseProcesses(…, then)`, `checkAndPromptChangeShortcut(…, then)`,
  `confirmSessionCommand(…, then)`; `initTerminal` split at that boundary into
  `startTerminalProcess`); and the close-request bridge `AppWindow.deferClose`
  — `close-request` must answer synchronously, so if the prompt resolves at
  once (disabled by preference) the answer is returned, otherwise the close is
  blocked and re-issued through `closeNoPrompt()` when the user agrees. The two
  fatal version dialogs in `app.d` run before the application exists, so
  `runStartupDialog` spins a GLib `MainLoop` until dismissed.
- **Visibility.** Every `showAll`/`setNoShowAll` is gone. GTK4 widgets start
  visible, so `setNoShowAll(true)` on a "shown later" indicator became
  `setVisible(false)`, and `showAll()` calls that only compensated for GTK3's
  default-hidden state were deleted.
- **Box packing.** `packStart` → `append`; `packEnd` → `insertChildAfter(child,
  anchor)`, which reproduces GTK3's pack-end order (first packed ends up
  rightmost). The title button takes the spare width with `hexpand` +
  `halign(Start)` so it is not stretched.
- **WP4, partially.** Draw handlers became `DrawingArea` overlays: `vteDecor`
  over the terminal paints the badge and drag highlight and, since an overlay
  child is allocated the terminal's size and `DrawingArea` keeps a `resize`
  signal, also stands in for the removed `size-allocate`; `badgeArea` over the
  sidebar toggle paints the notification count. `redrawTerminal()` queues both
  the VTE and the decor, because GTK4 caches render nodes per widget and a
  redraw of the VTE no longer repaints what sits above it. The transparent
  scrollbar draw hack was deleted (a Box paints nothing of its own).
  **Removed, tracked as WP4-bg:** `session.d`'s `onDraw` that painted the
  background image behind the pane tree and composited the children over it
  (`propagateDraw` has no GTK4 equivalent). It needs a `Picture` behind the
  tree in an `Overlay`; until then the background-image setting is inert.
- **Size-allocate replacements:** `DrawingArea.resize` (terminal),
  `notify::default-width/height` (window), `notify::max-position` (paned —
  GTK recomputes it from the allocation on every resize).
- **WP5 — quake and window management.** No client-side placement:
  `move`/`setGravity`/`--geometry` x,y are gone (`handleGeometry` keeps only
  the size path); no `stick`/`setKeepAbove`/`setRole`; `iconify` →
  `minimize`; `activateFocus` removed. Skip-taskbar/pager hints survive as X11
  surface hints set on realize (`gx.gtk.x11.setSkipTaskbarAndPager`).
- **Menus/popovers.** `PopoverMenu.newFromModel` + `setMenuModel`; the context
  popover is parented to the VTE with `setParent`/`setAutohide` and unparented
  in `finalizeTerminal`. The `popup-menu` keybinding signal is gone; Menu key
  and Shift+F10 are handled in the VTE key controller.
- **HeaderBar** has no title: `prefdialog.d` uses `Label` title widgets with
  the `title` CSS class; the app window shows the window title unless the
  custom title widget is set. `setShowCloseButton` → `setShowTitleButtons`.
- **Paned:** start/end child API with per-child resize/shrink setters
  (`childSetProperty` is gone); the handle size is derived from the allocation
  (no style properties). **Notebook:** `create-window` lost its x/y; `remove`
  → `removePage`. **Label:** `setAngle` is gone — side tabs keep horizontal
  text.
- **File choosers** use `GFile`: `setCurrentFolder(File)`, `getFile()`,
  `getFiles()` as a `ListModel`; GTK4 always confirms overwrites.
- **Application:** `addAccelerator`/`removeAccelerator` reimplemented on
  `setAccelsForAction` + `Action.printDetailedName`; `executeAction` uses
  `Widget.activateAction`, which walks the ancestors itself; the
  `gtk-menu-bar-accel` setting no longer exists (preference kept, inert);
  `AboutDialog` is a plain `Window`; `hasToplevelFocus` → `isActive`.
- **Entry paste from the terminal's paste action:** GTK4 focus lands on the
  inner `GtkText`, so the check tests `Editable` and pastes via
  `activateAction("clipboard.paste")`.
- **VTE:** the patched `text-deleted` signal is not in the vte3 binding, so a
  cleared buffer no longer resets prompt positions; `getWindow().beep()` →
  `getNative().getSurface().beep()`. `Mod1Mask` → `AltMask`.
- **The `.destroy()` audit** (see rulebook 2 below).

### Rulebook additions

1. **A failing `static assert` is fatal to the module.** DMD/LDC stop
   analysing after it, so every later error in that module is hidden.
   `session.d` reported 6 errors until one such assert was fixed, then 32.
   When a module's error list looks suspiciously short, look for
   `instantiated from here` lines in the raw output.
2. **UFCS rebinding is the compiler-invisible hazard of this port.** Two
   forms. `x.remove(w)` on a widget whose type lost `Container.remove`
   (Notebook, Paned, plain Widget) rebinds to `std.algorithm.remove` and
   fails loudly with "Range must be bidirectional" — fine. `x.destroy()` on
   anything that is not a `Window` rebinds to druntime's `destroy(x)`, which
   **compiles**, runs the wrapper's destructor and invalidates a wrapper that
   giD may share with every other holder. Rule: `Window`/`Dialog` keep
   `.destroy()`; a parented widget is removed from its parent (or unparented);
   a GObject reference is dropped (`x = null`). The one deliberate druntime
   destroy (`onCommandLine`'s eager unref) is written as `destroy(acl)` so it
   does not read as a GTK call.
3. **Scope tree-wide renames.** `\bMod1Mask\b → AltMask` reached into
   `source/x11/X.d` and renamed the X11 binding's own constant. Renames must
   be restricted to GTK-facing sources, and the list of files touched is the
   fifth assertion after the four formatting checks.
4. **Anchor hygiene for scripted edits.** An 8-space-indented anchor is a
   substring of the same statement at 12 spaces; use `^(\s*)`-anchored regexes
   with an expected count, or include the previous line. Count regex matches
   *after* the literal edits of the same batch. Keep edits all-or-nothing per
   file, but let the batch continue past a failed file and report at the end —
   one bad anchor blocked seven files three times before that change.
5. **Sync-or-deferred continuations.** A prompt disabled by preference resolves
   its continuation *before the helper returns*. Code that must answer
   synchronously (`close-request`, the sidebar's `CumulativeResult`) has to
   detect that case (`deferClose`, `onUserSessionClose`) and must never call
   `close()` re-entrantly from inside the handler.
6. **Per-widget render-node caching.** `queueDraw()` on a widget does not
   repaint overlays above it; queue them explicitly.

### Behaviour changes to verify at runtime

Nothing here has run. Items that compiled but whose semantics the compiler
cannot check, roughly in order of user visibility:

- background image disabled (WP4-bg); side tab labels no longer rotated;
  `--geometry` position, quake keep-on-top / all-workspaces, window role: inert
- close/quit/delete confirmations are asynchronous (`deferClose` path)
- title bar indicator order (`insertChildAfter`) and the title button's width
- sidebar badge is drawn over the button *content*, so it sits slightly inside
  the GTK3 position; refreshed via `badgeArea.queueDraw()`
- terminal resize → title tokens (`vteDecor.resize`); paned ratio kept via
  `notify::max-position`; window size via `notify::default-width/height`
- clipboard async paste, unsafe/review dialogs, auto-clear comparison
- DnD (`DragSource`/`DropTargetAsync`), detach-on-desktop via drag-cancel
- `activateAction("clipboard.paste")` on the focused `GtkText`
- Menu key / Shift+F10 context menu; Alt modifier via `AltMask`
- X11 skip-taskbar/pager hints; `runStartupDialog` main-loop spin
- giD callback parameter orders (`setDrawFunc`, `connectNotify`, `connectResize`)
  — accepted by the compiler, unverified in practice
- session/terminal disposal now follows refcounts (no `gtk_widget_destroy`);
  D-side references delay dispose until they are dropped

### Still open (tracked)

Bookmark drag-reorder, `use-theme-colors` background lookup, `text-deleted`
prompt reset, terminal transparency *without* a background image (see below),
and quake mode under Wayland (never supported here — see WP5 below).

Resolved after the first build: the saved window state now lives under its
own GTK4 key (`toplevel-state`) so GTK3-written `window-state` bits are never
misread — **the schema must be recompiled/reinstalled** for the GTK4 binary;
and the sidebar's click-outside dismissal is back via a capture-phase
`GestureClick` on the window (GTK4 has no `gtk_grab_add`).

### First build, first run

`dub build` compiled the whole tree on the first attempt and failed only at
link time, on three `gdk_x11_*` "default display" conveniences that GTK4
removed (`gdk_x11_get_xatom_by_name`, `gdk_x11_get_default_xdisplay`,
`gdk_x11_get_default_root_xwindow`). Their GTK4 forms take the `GdkDisplay*`
explicitly (`…_for_display`, `gdk_x11_display_get_xdisplay/xrootwindow`);
`x11.d` now passes the display it already had. **The branch links.**

The binary starts. giD resolves its C libraries at load time and its very
first report is environmental: `libvte-2.91-gtk4.so.0` — the GTK4 flavour of
VTE — is not installed on the development machine, so the first VTE call threw
`Attempt to execute an unresolved giD function`. Nothing past that point has
run yet. giD's report also lists a handful of non-VTE symbols absent from the
installed libraries (`g_thread_init`, `hb_shape_justify`, the cairo-gobject
type getters, …); those are informational and only matter if called.

With `vte4` installed the binary **runs** (X11, GTK 4.22.4 / VTE 0.84.1).
Two startup faults were fixed on the way. The GTK 3.18 minimum-version
constants are now 4.10 (`FileDialog`/`UriLauncher`), and the 26
`checkVersion(3, x, 0).length == 0` feature gates — which on GTK4 report a
*major mismatch* and so all took the legacy branch — became
`gtkAtLeast(3, x, 0)`, a plain numeric comparison. Then a stack overflow: the
sweep regex that turned `vte.queueDraw()` into `redrawTerminal()` also rewrote
the `vte.queueDraw()` inside `redrawTerminal()` itself (rulebook 7: a sweep
must exclude the definition it introduces; run regexes before adding the
helper, or anchor them away from it). Note that a running GTK3 ttyx is the
primary instance on the session bus — a GTK4 binary launched without
`--new-process` forwards its command line to it and exits 0.

The four CSS parser warnings at startup were GTK3-only constructs:
`-gtk-gradient(radial …)` on the two badge classes is now standard
`radial-gradient(circle closest-side, …)`, and the `@binding-set` tree-view
navigation from `ttyx.base320.css` (Left collapses or moves to the parent,
Right expands) is `gx.gtk.util.addTreeViewNavigation()` — a
`ShortcutController` attached to the bookmark, shortcut and close-dialog
trees. Startup is now silent.

### First look (rendering verified, interaction not)

Captured with `import -window` under `GSK_RENDERER=cairo` (the default GL
renderer hands `XGetImage` a frozen first frame): the window renders
correctly — header bar with session counter, custom title, add-terminal
buttons, search and menu, window controls; terminal title row with maximize
and close in the GTK3 order; a live shell prompt. Startup is silent and
`dub test` passes 33 modules.

Three fixes came out of it:

- The two app icons showed the missing-icon glyph. Two causes: the gresource
  stored them with `preprocess="to-pixdata"`, which GTK4 cannot load (now plain
  PNG), and GtkApplication registers `<base-path>/icons/` with the icon theme
  at its own startup, *before* `loadResources()` registers the bundle — the
  theme enumerates resource directories when it loads, so the path was
  recorded empty. `loadResources()` now re-adds the path after registration.
- **Rulebook 8: GTK4 `can-focus` covers the whole subtree.** GTK3's
  `nb.setCanFocus(false)` on the Notebook meant "tabs are not focusable"; in
  GTK4 it means no descendant — no terminal — can take focus. The per-widget
  property is `focusable`. Audit every `setCanFocus(false)` on a container.
- ~~`XTEST` input from `xdotool` does not reach GTK4 windows~~ — **wrong, and
  the `can-focus` bug above was the reason.** With no widget able to take
  focus, key events had nowhere to go; the stock python probe I checked
  against had no focused widget either, so it agreed for a different reason.
  Once focus worked, `xdotool` drove the application fine, and the interaction
  list below has now been exercised (see "Driven verification").

### Running a development build

The installed GTK3 ttyx owns both the system schema and the system gresource
(`/usr/share/ttyx/resources/ttyx.gresource`), and is the primary instance on
the session bus while it runs. A development run therefore compiles its own
copies and puts them first:

```bash
dub build --compiler=ldc2
glib-compile-schemas --targetdir=build/schemas data/gsettings
mkdir -p build/share/ttyx/resources
glib-compile-resources --sourcedir=data/resources \
    --target=build/share/ttyx/resources/ttyx.gresource data/resources/ttyx.gresource.xml
XDG_DATA_DIRS=$PWD/build/share:/usr/local/share:/usr/share \
GSETTINGS_SCHEMA_DIR=$PWD/build/schemas ./ttyx --new-process
```

## WP4-bg resolved: the background image is CSS, and VTE has to get out of the way

The GTK3 build painted the image in `Session.onDraw`: a cairo surface, cached
per window, re-rendered on resize, with the children composited over it via
`propagateDraw`. None of that exists in GTK4. The image is now a **CSS
background** on the same `.ttyx-background` node, installed once display-wide
by `Tilix.loadBackgroundImage()`, and the four layout modes map onto standard
CSS:

| Mode | CSS |
|---|---|
| `scale` | `background-size: cover; no-repeat; center` |
| `tile` | `background-size: auto; repeat; left top` |
| `center` | `background-size: auto; no-repeat; center` |
| `stretch` | `background-size: 100% 100%; no-repeat; left top` |

All four were verified by sampling pixels inside the terminal: centring leaves
the corners imageless, tiling repeats the image's marker bands, scale and
stretch fill the box. Whole subsystems went away with this — the per-window
`Surface` cache, its resize invalidation, `AppWindow.getBackgroundImage`,
`updateBackgroundImage`, `Tilix.getBackgroundImage`, and the 3840×2160
pre-scale. **One preference is now inert:** `background-image-scale` chose a
cairo filter, which CSS does not expose (it has no UI control; the schema key
stays for compatibility).

### The part that could not be done in CSS

With the image installed, the terminal body stayed exactly as dark as before.
The measurement that settled it: sample the same pixel with and without an
image configured, at 70% transparency.

| Sample | With image | Without |
|---|---|---|
| title row (above the terminal) | `srgb(252,137,29)` | `srgb(53,53,53)` |
| terminal body | `srgb(34,34,34)` | `srgb(34,34,34)` |

The title row changed, so the image *was* painted behind the terminal's whole
subtree; the body did not, so **VTE 0.84 under GTK4 paints its background
fully opaque and ignores the alpha passed to `setColors`** — the compositing
GTK3 relied on is gone. VTE's own documentation points at the fix: the one
listed use of `vte_terminal_set_clear_background(false)` is "to add a
background image to the terminal".

So `Terminal.updateVTEBackground()` now, *only when an image is configured*,
tells VTE not to paint its background and paints the profile's background
colour at its configured alpha with a CSS provider on the VTE node (the
per-widget provider pattern already used for `sbProvider`). The body then
samples `srgb(153,97,89)` / `srgb(51,127,88)` at two points — the image
showing through, tinted, with the prompt legible over it.

Limiting it to the image case is deliberate: with no image there is nothing to
reveal, and leaving VTE's painting alone keeps the default path byte-for-byte
as it was (re-measured: `srgb(34,34,34)`, unchanged). The consequence is that
**a transparent terminal with no image still renders opaque under GTK4** —
that needs the toplevel itself to be transparent, since `.ttyx-background`
paints an opaque `@theme_bg_color`, and it is now tracked as its own item
rather than folded in here.

## WP9 resolved: synchronized input moves to VTE's commit signal

The GTK3 mechanism was keystroke replay: forge a copy of the `GdkEventKey`,
set `send_event = SYNC` so the receiver would not re-broadcast it, and inject
it into each synchronized terminal with `gtk_widget_event()`. GTK4 removed
that function and made events immutable, so neither half survives.

The replacement was already half-built in the tree. `USE_COMMIT_SYNCHRONIZATION`
— upstream's alternative mechanism, off by default — is **now on, and on GTK4
it is not a choice**. VTE's `commit` signal carries the exact bytes the
terminal is about to send to the child, so typed text, encoded keys (arrows,
Enter, Tab, Ctrl+C) and IME input all synchronize as plain text with no event
forging at all. It is also *why the SYNC flag is unnecessary*: replaying into
a receiver goes through `feedChild()`, which brackets the write with
`signalHandlerBlock`/`Unblock` on the commit handler, so a receiver cannot
echo the text back. The paste, password and bookmark paths already carried
`static if (!USE_COMMIT_SYNCHRONIZATION)` guards around their explicit
`SyncTextEvent` emissions, because commit covers them once it is on.

What commit does *not* cover is the keys VTE consumes itself: Shift+Page
Up/Down, Shift+Home/End and Ctrl+Shift+Up/Down scroll the view and send
nothing to the child. Those were the whole reason for replay. They now travel
as a **`SyncScrollEvent`** carrying a `SyncScrollAction`
(`lineUp`/`lineDown`/`pageUp`/`pageDown`/`top`/`bottom`), which the receiver
applies to its own adjustment — deliberately its own, so a smaller pane
scrolls by its own page, which is what pressing the key in that pane does.
`SyncKeyPressEvent` is gone from the sum type, and with it the last use of a
`GdkEvent` as a payload.

`gx.gtk.vte.vteScrollAction()` does the keyval→action mapping, next to
`isVTEHandledKeystroke()` because the two encode the same knowledge, and it
returns false for anything that function does not claim so the two cannot
drift. It carries **unit tests, which do run here** — including that
unmodified Page Up must *not* scroll the other terminals, since that one goes
to the child and commit already handles it. The tests were verified to
actually execute by breaking an assertion on purpose and watching it fail
(`AssertError@vte.d(122)`), then restoring it.

Not verifiable from this machine: whether two synchronized terminals agree in
practice needs typing into one of them, and XTEST input does not reach GTK4
windows here. Manual test: split a terminal, enable Synchronize Input on both,
type, paste, then Shift+Page Up.

## WP5 resolved for X11: quake placement, keep-on-top and all-workspaces

GTK4 removed client-side window positioning from the portable API on every
backend, which took quake mode's whole geometry with it: `gtk_window_move`,
`set_keep_above`, `stick`/`unstick`, the window role and the taskbar hints.
The earlier checkpoint left the window sized but placed by the compositor.

None of that needed a protocol-level answer, because **quake mode here has
always been X11-only** — the `AppWindow` constructor refuses it under Wayland
and says so in a notification. So the requests go to X11 directly, where they
worked all along:

| Feature | GTK3 | Now |
|---|---|---|
| placement | `gtk_window_move` | `XMoveResizeWindow` on the surface's xid |
| keep on top | `set_keep_above` | `_NET_WM_STATE_ABOVE` client message |
| all workspaces | `stick`/`unstick` | `_NET_WM_STATE_STICKY` client message |
| taskbar/pager | GtkWindow hints | `gdk_x11_surface_set_skip_*_hint` |

`gx.gtk.x11` gained `moveResizeSurface()` and `setNetWmState()`, both
error-trapped like the existing `activateX11Window`.

**Verified by launching `--quake` and reading the window back** (monitor 0 is
1920×1080 at +1920+0):

| Settings | Expected | Got |
|---|---|---|
| top, 100%, 40% | 1920×432 at 1920,0 | ✅ same |
| bottom, 25% | 1920×270 at 1920,810 | 1920×270 at 1920,**770** |
| 50% wide, right | 960×… at 2880 | ✅ same |
| 50% wide, centre | 960×… at 2400 | ✅ same |
| monitor 2 (+0+0) | at 0,0 | ✅ same |
| monitor 1 (+3840+0) | at 3840,0 | ✅ same |

with `_NET_WM_STATE` reporting `SKIP_PAGER, SKIP_TASKBAR, ABOVE, STICKY`. The
bottom case sits 40px higher than requested because the window manager keeps
it clear of its panel — GTK3 got that for free from the workarea API, which
GTK4 does not have, so the WM does it for us instead.

### Two ordering rules this uncovered

7. **An EWMH `_NET_WM_STATE` client message is ignored before the window is
   mapped.** Sticky was applied at realize and silently did nothing; moved to
   the show handler it works. GDK's own hint setters (skip taskbar/pager) write
   the property directly and are fine at realize — so the two groups belong in
   different handlers, which is why they now are.
8. Preferences that reach X11 cannot be applied from the constructor at all;
   there is no surface yet, and the call is a silent no-op.

Still unavailable, and unchanged from the GTK3 build's own limits: quake under
Wayland, and "open on the monitor the mouse is on" (GTK4 has no pointer query,
so it falls back to the configured monitor — a `--quake` run with
`quake-active-monitor` left on lands on monitor 0).

## Driven verification, and two bugs it caught

With focus fixed, `xdotool` does drive the application, so the interaction list
was actually exercised. Two real defects turned up, both now fixed.

### Terminal shortcuts did nothing (a regression from the version-gate sweep)

Every terminal-scoped accelerator — paste, copy, find, zoom, close — was
dead, while session ones (split, synchronize input) worked. A probe on
accelerator registration showed `terminal.paste = ["<Ctrl><Shift>v"]`
registered correctly, and the action never activating.

The cause is a GTK4 dispatch rule: an application accelerator is handled by a
shortcut controller on the **window**, and its action is resolved against the
window's action muxer, which cannot see a group inserted on a descendant
widget. `Terminal` inserts its actions on itself, so they are unreachable by
keyboard (menus still work — a menu item resolves from the widget it pops
over). `AppWindow.createDelegatedTerminalActions()` already existed to mirror
those actions on the window, as a workaround for the same limitation in
GTK+ < 3.15.3 — and it was guarded by a version check that GTK4 satisfies, so
it switched itself off exactly where it is needed again.

**This was self-inflicted.** Before the `checkVersion` → `gtkAtLeast` sweep,
the guard read `checkVersion(3, 15, 3).length != 0`, which on GTK4 is "true"
because a major-version mismatch reports an error — so the workaround ran *by
accident* and terminal shortcuts worked. Rulebook 9: **when a version gate
turns a workaround off, check whether the new toolkit needs it again**; a
mechanical "the version is satisfied now" reading is not enough. All four
inverted gates were audited: this one was wrong, the search-entry CSS and
overlay-scrollbar ones are right, and the preferences-list one was actually
*fixing* a bug (every version-gated shortcut had been hidden from the list).

### Session thumbnails collapsed the sidebar

The sidebar revealed as a ~40px strip. `GtkImage` in GTK4 renders at **icon**
size, so the session thumbnail became a stub and took the row's width with it;
`GtkPicture` is the widget for arbitrary images and takes its natural size
from the pixbuf, as the GTK3 `GtkImage` did. With that swap the sidebar shows
real session previews again.

### What is now verified by driving the UI

| Feature | Evidence |
|---|---|
| typing, splits | shell side effects; two panes render |
| **synchronized input** | 1 shell ran the command before the toggle, 2 distinct PIDs after |
| **synchronized scrollback** | after Shift+Page Up both panes show lines 255-278, not the tail |
| paste | `Ctrl+Shift+V` runs the pasted command |
| **paste review dialog** | multi-line paste opens "Review Paste"; nothing runs while it is up; Escape cancels |
| **the WP3 invariant** | text edited *inside* the dialog is what reaches the prompt; the original clipboard text never appears |
| close confirmation | a running process opens "Close Session"; the app stays alive; Escape cancels (the `deferClose` bridge) |
| context menu | right-click and the Menu key both open the popover, with accelerator labels |
| find bar | `Ctrl+Shift+F` reveals it |
| zoom | `Ctrl++` changes the font |
| sidebar | opens with thumbnails, and a click outside dismisses it (the capture-phase gesture) |
| background image | shows through the terminal at the profile's transparency |
| quake mode | placement, monitor choice, alignment, EWMH states |

Still unexercised: drag and drop (terminal and session), the advanced paste
dialog, bookmarks, preferences editing, and session save/load.
