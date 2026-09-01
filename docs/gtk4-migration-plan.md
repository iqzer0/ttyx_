# Phase 2b — GTK3 → GTK4 + libadwaita: scoping pass

**Status:** planning only. No code has been migrated. Scoped 2026-09-01 against
`master` at the 1.3.0-beta.1 line.

Prerequisites are already cleared: the GTK4 stack (`gid:gtk4` + `gid:vte3` +
`gid:adw1`) compiles and runs (re-spike 2026-08-09), and we can regenerate giD
ourselves if upstream stalls (bus-factor spike 2026-09-01 — see ROADMAP). This
document sizes the actual work in *this* codebase rather than restating generic
GTK4 porting advice.

---

## Measured API surface

Counts are matching lines in `source/`, comments excluded. They measure
**exposure**, not effort — a hundred mechanical `.add()` calls are cheaper than
one `dialog.run()`.

| Area | Hits | GTK4 disposition |
|---|---:|---|
| `.add(` | 226 | mechanical → `setChild` / `append` |
| `IconSize` | 72 | mechanical → removed/pixel sizes |
| `Screen` | 66 | mostly mechanical → `Display` / `Monitor` |
| `connectGdkEvent` | 42 | **structural** → EventControllers |
| `showAll()` | 39 | mechanical → widgets visible by default |
| `ShadowType` | 37 | mechanical → removed, CSS |
| `packStart/packEnd` | 36 | mechanical → `append` / `prepend` |
| `.run()` | 26 | **structural** → no nested main loops |
| `TargetEntry/TargetList` | 17 | **structural** → `DragSource`/`DropTarget` |
| `EventBox` | 16 | mechanical → removed, widgets take events |
| `Clipboard.get` | 16 | **structural** → async `Gdk.Clipboard` |
| `ReliefStyle` | 14 | mechanical → CSS classes |
| `drag*()` | 11 | **structural** (same item as TargetEntry) |
| `getChildren()` | 10 | mechanical → child iteration API |
| `connectDraw` | 7 | **structural** → snapshot / `DrawingArea` |
| `pack1/pack2` | 4 | mechanical → `setStartChild`/`setEndChild` |
| `addProviderForScreen` | 2 | mechanical → `…ForDisplay` |

The mechanical rows are the bulk of the line count and near-zero risk. Five
structural items carry essentially all the risk, and they are what the work
packages below are organised around.

---

## Two findings that *reduce* scope

**1. `gx/gtk/events.d` and Kymorphia/gid#52 disappear.** The workaround exists
because giD 0.9.13 generates GDK event structs as non-`Boxed` classes, so its
generated `connect*Event` marshals extract a boxed `GdkEvent` with
`g_value_get_pointer` and hand every handler a NULL. **GTK4 has no `*-event`
signals at all** — input arrives through EventControllers. So the module, the
42 `connectGdkEvent` call sites' dependence on it, and our exposure to an
unanswered upstream bug all go away together. The ROADMAP's "budget for
carrying local workarounds" caveat does not apply to this one past 2b.

**2. Every VTE feature gate becomes unconditional.** `gx/gtk/vte.d` gates on
VTE 0.46 (minimum) through 0.53 (`BACKGROUND_GET_COLOR`). VTE 3.91 — the GTK4
build — is 0.76+, so all of these are always true. The version-check machinery
and its branches can be deleted rather than ported. Same for the GTK version
gates (`checkVersion(3, 16/19/20, 0)`), which are all satisfied by GTK4.

Both mean the post-2b codebase is smaller than the pre-2b one in these areas.

---

## VTE 3.91 removes seven signals — this costs us two features

Diffing the GIRs giD vendors (`Vte-2.91.gir` → `Vte-3.91.gir`), these signals
are gone in the GTK4 build:

```
notification-received   shell-precmd   shell-preexec
text-deleted   text-inserted   text-modified   text-scrolled
```

ttyx_ touches two of them, and they fail in **different ways**:

| Signal | How it is used | Failure mode on vte3 |
|---|---|---|
| `text-deleted` | `terminal.d:1215`, prompt-buffer tracking | **compile error** |
| `notification-received` | `exvte.d`, hand-written closure | silent feature loss |

- **`text-deleted` is a hard compile error, not a graceful degradation.**
  Confirmed directly: `gid:vte3` generates no `connectTextDeleted`, while
  `gid:vte2` does. The call site *is* guarded — but by
  `checkVTEFeature(EVENT_SCREEN_CHANGED)` at **runtime**, which does nothing for
  compilation. This is the first known concrete item on the WP0 error list.
- **`notification-received` degrades quietly.** It is connected through a
  hand-written closure in `exvte.d` behind a `signalLookup` probe, so it
  compiles and simply reports the feature as unavailable. Practical effect:
  **process-completion notifications go permanently off on stock VTE 3.91.**

Separately, `terminal-screen-changed` — which gates the whole triggers feature
— was **never in stock VTE at all**; it is a Tilix-patched-VTE signal, already
runtime-probed. So triggers are conditional today too. The open question is not
whether upstream vte3 has it (it does not, and never did) but whether a patched
*vte3* exists downstream at all. If not, triggers and prompt navigation are
GTK3-only features and that needs saying out loud rather than discovering it
after the port.

Net: the port does not silently break these, but **feature parity with 1.3.0 is
not achievable on stock VTE 3.91**, and that is a product decision to take
before WP0, not a surprise to absorb during it.

---

## WP0 dry run: 22 of 112 imported modules are removed

The dependency swap was tried on a throwaway branch. **The compiler error list
cannot be captured in one pass** — the first failure is
`unable to read module 'bin'` (`GtkBin` is gone), and missing-module errors are
fatal, so each removed import has to be resolved before the next layer of
semantic errors is even visible. Plan WP0 as iterative, not as one build.

A static inventory gets the same answer immediately. Of the 112 distinct
`gtk.*` / `gdk.*` / `vte.*` modules imported by `source/`, these 22 exist in
the GTK3 stack and **not** in the GTK4 one:

```
gdk.atom          gdk.drag_context   gdk.event_button   gdk.event_crossing
gdk.event_expose  gdk.event_focus    gdk.event_key      gdk.event_scroll
gdk.event_window_state               gdk.screen         gdk.visual
gdk.window        gtk.bin            gtk.clipboard      gtk.container
gtk.event_box     gtk.file_chooser_button                gtk.icon_info
gtk.offscreen_window                 gtk.selection_data gtk.target_entry
gtk.target_list
```

Most map onto work packages already identified (the `gdk.event_*` family → WP2,
`gtk.clipboard` → WP3, `target_*`/`selection_data`/`drag_context` → drag and
drop, `gtk.bin`/`gtk.container` → the mechanical sweep). **Two were not
predicted by the grep pass and need their own package.**

### WP6 — offscreen rendering (`gtk.offscreen_window`)

`gx/gtk/cairo.d` renders widgets offscreen via `class RenderWindow :
OffscreenWindow`. GTK4 removed `GtkOffscreenWindow` outright. Two user-visible
features depend on it:

- **Session sidebar thumbnails** — `sidebar.d:539,623,650`, the scaled preview
  of each session. A headline feature of the sidebar.
- **Drag-and-drop terminal preview** — `terminal.d:2956,2959`, the image shown
  while dragging a terminal.

Good news: the GTK4 replacement is cleaner than what is there now.
`gtk.widget_paintable.WidgetPaintable` renders a live widget, and
`gtk.drag_source.DragSource.setIcon(gdk.paintable.Paintable, int, int)` takes a
paintable directly — both confirmed present in `gid:gtk4`. So the drag-icon path
gets *simpler*, and the thumbnail path becomes paintable→texture instead of
offscreen-window→pixbuf. This is a rewrite of `cairo.d`'s core rather than a
mechanical swap, but it is a rewrite toward a better API — and it may retire the
event-handling fragility that `appwindow.d:555` warns about
("populate sessions does some weird shit with event handling").

### Transparency setup (`gdk.visual`) mostly deletes

`appwindow.d:updateVisual()` fetches an RGBA visual from the screen and calls
`setVisual()` so terminal transparency works. GTK4 has no `GdkVisual`;
compositing is the compositor's business and windows are transparency-capable
without setup. Expect this function to be **deleted rather than ported** — but
verify transparency still behaves, since it is a shipped profile feature.

---

## Work packages

Ordered by risk, not by size. WP1 is the one that can genuinely go wrong.

### WP1 — Dialogs: remove nested main loops (26 sites)

GTK4 removes `gtk_dialog_run`. Every site is currently written in a blocking
style that reads top-to-bottom:

```d
dialog.showAll();
if (dialog.run() == ResponseType.Apply) {
    pasteText = dialog.text;
    vtePasteText(_ctx.contextVte(), pasteText);   // continues inline
}
```

and must become response-callback driven, inverting control flow at each site.

Distribution: `terminal/terminal.d` 6, `terminal/clipboard.d` 3, `gtk/dialog.d`
3, `terminal/password.d` 2, `prefeditor/common.d` 2,
`prefeditor/bookmarkeditor.d` 2, `app.d` 2, and one each in six other modules.

**Why this is the risky one, not just the biggest:** three of the sites are in
`clipboard.d` and sit directly on the paste path, which is security-critical.
Today the "did the user approve this paste?" decision and the "send it to VTE"
action are the same synchronous block, so they cannot desynchronise. Made
async, the approved text has to be carried to a callback that fires later —
introducing, for the first time, a window in which the clipboard can change
between approval and send. **The dialog must paste the text it displayed, not
re-read the clipboard.** Note `advancedPaste` already re-reads the clipboard on
its single-line fast path today; that latent TOCTOU becomes a real one under
async and should be fixed as part of this package.

Recommendation: do `gtk/dialog.d` first (3 sites, shared helpers — likely
collapses several call sites into a common async helper), then `clipboard.d`
with tests, then the rest.

### WP2 — Input: `connectGdkEvent` → EventControllers (42 sites)

Event types actually used, which bounds the controller set needed:

| Event | Sites | GTK4 controller |
|---|---:|---|
| `EventKey` | 16 | `EventControllerKey` |
| `EventFocus` | 8 | `EventControllerFocus` |
| `EventButton` | 8 | `GestureClick` |
| `EventScroll` | 2 | `EventControllerScroll` |
| `EventCrossing` | 1 | `EventControllerMotion` |
| `EventWindowState` | 1 | `Window` state properties |
| `EventExpose` | 1 | folds into WP4 |
| `EventX` | 1 | see WP5 |

Only six controller types for 36 real call sites, so this is repetitive rather
than deep. The `EventBox` removals (16) belong here: in GTK4 any widget can take
a controller, so the wrapper boxes are deleted outright rather than ported.

Two behavioural traps to watch: GTK4 controllers have capture/bubble phases with
no GTK3 equivalent, and key handling ordering versus VTE's own input handling
will need checking on the terminal widget specifically.

### WP3 — Clipboard: sync → async (16 sites)

`Gdk.Clipboard` in GTK4 is async-only; `waitForText()` has no equivalent. Every
read becomes a callback. Interacts with WP1 — several clipboard reads are inside
dialogs that are themselves becoming async, so sequence WP1 first and this gets
easier.

Specific attention: `scheduleAutoClear` currently reads the clipboard
synchronously inside a timeout to compare against what it copied, before
clearing. That comparison is the safeguard that stops us wiping another app's
clipboard content, so it must survive the async rewrite intact.

### WP4 — Drawing: `connectDraw` → snapshot (5 real sites)

| Site | What it draws |
|---|---|
| `terminal.d:2912` | badge over VTE |
| `terminal.d:2914` | drag highlight over VTE |
| `terminal.d:1303` | transparent scrollbar background |
| `session.d:1186` | session background image |
| `appwindow.d:403` | sidebar notification badge |

The two that draw *over the VTE widget* are the interesting ones — GTK4 has no
`draw` signal to connect after. Likely path: the terminal already has a
`terminalOverlay` (`Gtk.Overlay`, which survives in GTK4), so badge and drag
highlight can move into an overlaid `DrawingArea` with a draw function rather
than being reimplemented as snapshot vfuncs. Worth prototyping early — it is the
one place where the GTK4 model might force a visible behaviour change.

Note the transparent-scrollbar site at `terminal.d:1303` is currently reached
only when a scrollbar CSS provider loaded, which was broken until the
`css/tilix.*` → `css/ttyx.*` fix; re-verify it works on GTK3 before porting it,
or you will be porting a path that has never actually run.

### WP5 — X11, quake mode and Wayland

Smaller than it looks. The vendored `source/x11/` plus `gx/gtk/x11.d` exist to
provide **one** function — `activateX11Window`, called from
`gx/gtk/util.d:activateWindow`. Under GTK4:

- `gdk_x11_window_*` becomes `gdk_x11_surface_*`; giD binds no X11 backend
  either way, so the `extern(C)` declarations get updated rather than replaced.
- The code already branches on `isWayland()`, so the structure is in place.
- Quake mode positioning is the real exposure: GTK4 removed client-side window
  positioning, and the ROADMAP already notes wlroots needs `wlr-layer-shell`.
  **Quake mode should be treated as its own decision, not a port task.**

---

## Sequencing

1. **WP0 — dependency swap on a branch.** Already dry-run: see the 22-module
   inventory above. Resolving imports is iterative (missing-module errors are
   fatal), so budget for peeling them off in layers rather than one error dump.
2. **WP2 (input) + EventBox removal.** Largest mechanical win, deletes
   `events.d`, unblocks compiling large parts of the tree.
3. **WP1 (dialogs).** The risky one; do it with the paste-path tests green.
4. **WP3 (clipboard)**, which WP1 has now made tractable.
5. **WP4 (drawing).** Prototype the VTE overlay first.
6. **Mechanical sweep** — `add`/`showAll`/`packStart`/enums/`Screen`.
7. **WP6 (offscreen rendering).** Independent of the others — can be done in
   parallel by a second pair of hands if there is one.
8. **WP5 (X11/quake)** and the libadwaita adoption pass last, as they are
   product decisions rather than ports.

Deleting the VTE/GTK version gates can happen at any point after WP0 and will
shrink several of the above.

---

## Open questions

- **libadwaita vs. the CSD modes.** ttyx_ supports `disable-csd`,
  `disable-csd-hide-toolbar` and `borderless` window styles, plus an embedded
  headerbar for quake. `AdwHeaderBar` assumes CSD. Whether these modes survive,
  and in what form, is a product decision that should be settled before WP0.
- ~~**Does VTE 3.91 still expose everything used?**~~ **Answered** — see the
  VTE signals section above. It does not: `text-deleted` is a compile error and
  `notification-received` is a silent feature loss. The remaining sub-question
  is whether a *patched vte3* exists downstream to carry
  `terminal-screen-changed`; if not, triggers and prompt navigation are
  GTK3-only and the feature list needs updating before, not after, the port.
- **Runtime dependency documentation.** The 2026-08-09 spike found giD dlopens
  its C libraries, so the binary has no direct link deps — `vte4` and
  `libadwaita` become undeclared runtime requirements that packaging must state
  explicitly.

---

## What this pass did *not* do

No code was changed. The counts come from pattern matching, so treat them as
order-of-magnitude: they will be off in both directions (some `.add(` hits are
not container adds; some GTK4 breakage is invisible to grep, notably behavioural
changes in focus, measurement and sizing). The authoritative inventory is the
WP0 compiler error list.
