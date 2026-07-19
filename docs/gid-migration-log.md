# Phase 2a migration log (GtkD → giD, on GTK3)

> **Historical record.** This was the living checklist of the wholesale
> GtkD→giD port, which completed at 44/44 modules; the ports now live in
> `source/` and the `experimental/gid/` staging tree it describes has been
> deleted (its history is in git). Kept for the GtkD→giD translation
> cheat-sheet and the per-module porting notes, which remain the reference
> for future giD work (Phase 2b / GTK4). Rationale and constraints are in
> [`gid-migration.md`](gid-migration.md).

**Model:** a separate giD build (this `experimental/gid/` project) that grows
until it reaches parity with the GtkD app under `source/`, then the main build
is swapped over. The ~26 GtkD-free files under `source/` carry over **unchanged**
and are reused as-is; only the GtkD-coupled files are ported here.

**Verification:** each ported module must compile against giD and keep its unit
tests passing. `color.d` was verified with `dub test` against `gid:gdk3`.

## ▶ Resuming in a new session (start here)

**Status: 44/44 modules ported. The full giD application compiles, links, and RUNS** — verified live on X11 (window maps, terminal/session init, events processed, clean exit; no GObject criticals or segfaults). 28 modules pass `dub test`. Remaining Phase 2a tail: (1) interactive GUI smoke tests (per-module lists below / in commit messages); (2) ~~swap the main build over to giD~~ **DONE on `migrate/gid-build-swap`** (dub is the single build system; meson retired; CI/flatpak/docs/install.sh updated; GtkD + vendored secret/ deleted); (3) file the giD event-marshal bug upstream (see `source/gx/gtk/events.d`; draft in the repo owner's hands). This experimental/gid/ tree is now historical — the ports live in `source/` on the swap branch. Parallel porting now proven: independent modules go to concurrent agents in isolated worktrees, integrated + `dub test`ed centrally. Everything is on `master` of the fork
(`iqzer0/ttyx_`). The shipping GtkD app is untouched — all ports live only in
`experimental/gid/`, which is not part of the main `meson`/`dub` build.

**1. Toolchain (persistent — already installed, no setup):**
```bash
export PATH="$HOME/dlang/ldc-1.40.0/bin:$PATH"   # bundles dub
# leave DUB_HOME unset → uses ~/.dub, where giD 0.9.13 is already cached
```
If `~/dlang` is ever gone: re-extract the LDC 1.40 tarball
(`github.com/ldc-developers/ldc/releases/download/v1.40.0/ldc2-1.40.0-linux-x86_64.tar.xz`)
into `~/dlang/ldc-1.40.0`.

**2. Confirm the current ports still build (the giD skeleton compiles them all):**
```bash
cd experimental/gid && dub build --compiler=ldc2
```
Exit 0 = every ported module still compiles+links.

**3. Port the next module — the loop that has worked every time:**
   1. Pick the next unchecked box below (they're ordered low-import → high).
   2. Read the GtkD original at `source/<path>`.
   3. Recon each unfamiliar giD API from the cached bindings — grep
      `~/.dub/packages/gid/0.9.13/gid/packages/<pkg>/...` (e.g. `gtk3/gtk/`,
      `gio2/gio/`, `glib2/glib/`, `glib2/gobject/`, `gdk3/gdk/`, `vte2/vte/`).
      The cheat-sheet below has the recurring idioms.
   4. Write the port to `experimental/gid/source/<same path>`.
   5. `cd experimental/gid && dub build --compiler=ldc2 --force` → fix errors,
      repeat until clean.
   6. Tick the box here, `git commit` (`feat:`/`chore:` `Phase 2a — port X to giD`),
      `git push`. Merge to `master` at milestones (each merge is
      `experimental/gid`-only, so safe; re-runs CI on the app, which stays green).

**4. Do the NEXT modules in this order:** `threads.d` → then the `gx/ttyx`
layer starting with its low-import leaves
(`types`, `spawn`, `colorschemes`, `preferences`, `context`, ...). Heavy widgets
(`session`, `sidebar`, `application`, `prefdialog`, `appwindow`, `terminal.d`)
come last, once the shared modules exist.

**5. Reusing GtkD-free `source/` files:** add them to the build via
`sourceFiles` + `importPaths: ["source", "../../source"]` in
`experimental/gid/dub.json` (see the `x11.d` precedent — it reuses
`source/x11/*` + `libs-linux: ["X11"]`). `gx/util/*`, `gx/ttyx/common`,
`constants`, `encoding`, and the pure `terminal/*` logic carry over unchanged.

**Outstanding manual checks:**
- `x11.d`'s `_NET_ACTIVE_WINDOW` send is compile-verified only — test window
  activation on a real X11 session.
- `flatpak.d`'s HostCommand D-Bus path is compile-verified only — test inside
  a real Flatpak sandbox.
- `exvte.d`'s patched-VTE signal marshals and disable-bg-draw dlsym path are
  compile-verified only — test against a patched VTE build (e.g. Fedora). Same
  for `vte.d`'s dlsym-based DISABLE_BACKGROUND_DRAW feature probe (added at
  batch-4 integration — restores the Badge feature on patched VTE that the
  original vte.d port had dropped).
- `password.d`'s keyring create/edit/delete/lookup flows need a check against a
  live Secret Service (gnome-keyring/KWallet).

## Translation cheat-sheet (GtkD → giD)

| GtkD | giD |
|------|-----|
| `import gdk.RGBA;` (class) | `import gdk.rgba;` — `RGBA` is a **value struct** with plain `double red/green/blue/alpha` |
| `new RGBA(r,g,b,a)` | `RGBA(r,g,b,a)` (struct literal, no `new`) |
| `color.red()` (accessor) | `color.red` (field) |
| `import gtk.Application;` | `import gtk.application;` (snake_case module) |
| `addOnActivate(&cb)` | `connectActivate(&cb)` |
| `win.add(w)` / `showAll()` | same on GTK3 (GTK4: `setChild` / `present`) |
| `GApplicationFlags` | `import gio.types : ApplicationFlags;` |
| GTK enums (`MessageType`, `ResponseType`, `ButtonsType`, `DialogFlags`) | in module `gtk.types` |
| `new MessageDialog(parent, flags, type, buttons, msg, null)` | **no such ctor** — giD uses `MessageDialog.builder()...build()` + property setters (`messageType`, `text`, `secondaryText`); `ButtonsType`/flags are construct-only |
| `dialog.getMessageArea()` returns a `Box` | returns a `Widget` — cast to `Box`/`Container` to `.add()` children |
| `new Entry(str)` / `new CheckButton(str)` | `new Entry()` + `setText`; `CheckButton.newWithLabel(str)` |
| `entry.addOnActivate(&cb)` / `addOnChanged(&cb)` | `entry.connectActivate(&cb)` / `connectChanged(&cb)` |
| `new ObjectG(T.getType(), [props], [Values])` (construct props) | `T.builder().prop1(v1).prop2(v2).build()` |
| `new Dialog(title, parent, flags, buttons, responses)` / `gtk_dialog_new_with_buttons` | not bound — raw `g_object_new(Dialog._getGType(), "use-header-bar", 1, null)` + `super(ptr, No.Take)` + `setTitle`/`setModal`/`addButton` (see advpaste.d) |
| passing NULL for a nullable boxed param (e.g. `setColorBold(null)`) | inexpressible via wrapper (value-struct `RGBA` always passed by `&arg`) — call the raw C function from `<pkg>.c.functions` (see renderer.d) |
| signal giD doesn't bind (patched VTE etc.) | `signalLookup` probe + hand-written `DClosure` marshal (see exvte.d) |
| `PgCairo.showLayout(cr, layout)` | `pangocairo.global.showLayout(cr, layout)` — needs the separate `gid:pangocairo1` dep |
| `abstract class Foo : <giD widget>` | **NOT allowed** — giD's `createClassMaps()` instantiates every GObject subclass at startup via `_d_newclass` (null for abstract) then segfaults. Make GObject subclasses concrete. |
| `w.connect<Name>Event(dg)` reading the event | **giD 0.9.13 delivers a NULL event** (Event subclasses aren't Boxed → `getVal` uses `g_value_get_pointer`). Use `connectGdkEvent!EventT(w, "signal-name", dg)` from `gx.gtk.events`. Compiles fine either way; only faults at runtime when the handler reads the event. Cairo `Context` (draw) IS Boxed — `connectDraw` is fine. |
| delegate literal with unnamed typed params to `addOn*` | **name every param** in `connect*` delegate literals — `delegate(GVariant, SimpleAction sa)` parses `GVariant` as a param NAME and inference fails |
| `getIterFirst()` etc. return nullable `TreeIter` | `out TreeIter` + bool return; **the out iter is non-null even on false** — check the bool, never the iter; never alias out iters (`iterParent(parent, parent)` segfaults) |
| `renderer.setProperty("enum-prop", v)` | use giD typed property setters (`crt.ellipsize = …`) — Value-from-enum inits abstract `G_TYPE_ENUM` |
| `new TreeModelFilter(model, root)` | `cast(TreeModelFilter) model.filterNew(root)` |
| `new TreeViewColumn(title, renderer, attr, col)` | unbound varargs — no-arg ctor + `setTitle` + `packStart(r, true)` + `addAttribute` |
| `tv.getSelectedIter()` / `model.getValueString(iter, col)` | unbound GtkD conveniences — `getSelection().getSelected(out m, out i)`; `getValue(iter, col, out Value)` + `.getString()` |

**Note on the widget modules:** the three trivial leaves (color/clipboard/l10n) were near-mechanical. The next tier is real work — `dialog.d` needs the builder-pattern rework above; `vte.d`'s feature detection uses GtkD-internal linker introspection (`gtkc.Loader`) with no giD analogue and must be reimplemented; `threads.d` uses deprecated `gdk.Threads` + C-callback trampolines; `settings.d` uses low-level `gtkc.giotypes`. Port these deliberately (write → compile → fix), not in a rushed batch.

## Reusable as-is (GtkD-free — no port, just add to the giD build)

`gx/util/{array,geometry,path,proc,redact,string}`, `gx/ttyx/common`,
`gx/ttyx/constants`, `gx/ttyx/encoding`, `gx/ttyx/terminal/{actions,activeprocess,monitor,process,state,util}`.
(The vendored `secret/`, `secretc/`, `x11/` are **replaced** by giD's libsecret / xlib bindings, not reused.)

## Modules to port (~44), leaves first

`C` = uses low-level `gtkc.*` C bindings (trickier — giD exposes C differently).
Number = count of GtkD imports (rough difficulty).

### Leaves (start here)
- [x] **`gx/gtk/color.d`** (1) — ported + verified (`dub test` vs `gid:gdk3`). `gdk.RGBA` class → `gdk.rgba.RGBA` value struct.
- [x] **`gx/gtk/clipboard.d`** (1) — ported + verified (compiles in skeleton). `gdk.Atom`/`intern` → `gdk.atom.Atom` class + `Atom.intern`.
- [x] **`gx/i18n/l10n.d`** (1) — ported + verified (compiles in skeleton). `glib.Internationalization.*` → free functions in `glib.global` (`dgettext`, `dpgettext2`).
- [x] **`gx/gtk/threads.d`** (1) — ported + verified (probe-instantiated all caller shapes). Big simplification: giD's `gdk.global.threadsAddIdle/threadsAddTimeout` take D delegates directly (internal `freezeDelegate`/`thawDelegate` handles GC rooting), so the grestful `DelegatePointer` + C-trampoline machinery is gone; public API unchanged. Priorities passed explicitly (`PRIORITY_DEFAULT_IDLE` / `PRIORITY_DEFAULT` from `glib.types`) since giD only binds the `*_full` variants.
- [x] **`gx/ttyx/terminal/spawn.d`** (1) — ported + verified (`dub test`: proxy-URL suite passes). Mechanical `gio.settings` import swap. Reuses `gx/ttyx/terminal/util.d` (added to dub.json).
- [x] **`gx/ttyx/terminal/types.d`** (1) — ported + verified (`dub test`: SumType sync events, TerminalSnapshot golden roundtrip, trigger tests all pass). Mechanical: `gdk.Event` → `gdk.event : Event` (Boxed class, still nullable — in-contracts unchanged).
- [x] **`gx/ttyx/colorschemes.d`** (2) — ported + verified (`dub test`: full suite passes — JSON roundtrip, parse, matching). **Gotcha: giD `RGBA` struct fields default-init to NaN** (bare `double`s) vs GtkD’s zeroed `new RGBA()` — every former `new RGBA()` is now explicit `RGBA(0,0,0,0)`; `parseColor` takes `ref RGBA`; `glib.Util.*` → `glib.global` free functions.
- [x] **`gx/ttyx/preferences.d`** (2) — ported + verified (`dub test` in skeleton: clamp/ProfileInfo/prctl tests pass). Near-mechanical: `gio.settings`/`glib.variant` imports, `new GSettings(id, path)` → static `GSettings.newWithPath(id, path)`; everything else unchanged. First `gx/ttyx` module: pulled reusable GtkD-free `gx/util/array.d`, `gx/ttyx/common.d`, `gx/ttyx/constants.d` into the build via dub.json `sourceFiles`. **`dub test` works on the skeleton** (test runner skips `main`) — use it as the verify step from now on.
- [x] **`gx/ttyx/terminal/context.d`** (2) — ported + verified (`dub test`: PreferenceRegistry suite passes). Mechanical import swap. Reuses `gx/ttyx/terminal/state.d` (added to dub.json).
- [x] **`gx/gtk/settings.d`** (3) — ported + verified. `GSettingsBindFlags` → `gio.types.SettingsBindFlags`; `gobject.ObjectG` → `gobject.object.ObjectWrap`; `Settings.unbind` is **static** in giD; wrapper-validity probe `getObjectGStruct()` → `_cPtr`.
- [x] **`gx/ttyx/terminal/regex.d`** (4, C) — ported + verified (`dub test`: full gnome-terminal match corpus passes; compile templates probe-exercised). Raw `gtkc.glibtypes` enums → `glib.types.RegexCompileFlags/RegexMatchFlags` (PascalCase; **bitwise-OR of giD enums needs a `cast` back to the enum type**). GtkD `VRegex.newMatch(pattern, -1, flags)` → static `VRegex.newForMatch(pattern, flags)`, throws `ErrorWrap` on bad patterns. **Fixed an upstream precedence bug: `OPTIMIZE | caseless ? CASELESS : 0` made every trigger GRegex caseless and never applied OPTIMIZE** — triggers are now genuinely case-sensitive unless caseless is set (user-visible change; note for release notes).
- [x] **`gx/gtk/vte.d`** (4) — ported + verified. Version via `vte.global.getMajorVersion`; keysyms `gdk.types.KEY_*`; patched-signal detection via `gobject.global.signalLookup` + `Terminal._getGType()`. **Behavioral note:** `DISABLE_BACKGROUND_DRAW` reported unavailable — giD binds only standard VTE (no patched `vte_terminal_get_disable_bg_draw`, no linker introspection); `isVTEBackgroundDrawEnabled()` falls back to the version check.
- [x] **`gx/ttyx/cmdparams.d`** (4) — ported + verified (`dub test`: all parseGeometry/clear tests pass). Near-mechanical. Only real API delta: **`Variant.getString()` takes no out-length param in giD**. Reuses GtkD-free `gx/util/path.d` (added to dub.json).
- [x] **`gx/gtk/dialog.d`** (5) — ported + verified (compiles/links in skeleton). First widget module: `MessageDialog.builder().build()` + property setters + `addButton` (no ctor/ButtonsType), enums PascalCase in `gtk.types`, `getMessageArea` cast to `Box`, `connectActivate`/`connectChanged`, `CheckButton.newWithLabel`.

### Mid (widgets, wrappers)
- [x] **`gx/ttyx/terminal/flatpak.d`** (6, C) — ported + verified (compiles/links; **Flatpak D-Bus path needs a runtime check inside a real sandbox**). All raw C is gone: `g_variant_new` varargs → typed `Variant.newBytestring/newBytestringArray/newDictEntry/newHandle/newTuple` (VariantBuilders kept so empty `a{uh}`/`a{ss}` stay correctly typed); extern(C) signal callback + `GC.addRoot` → D-delegate `signalSubscribe` closure over a heap state struct; `callWithUnixFdListSync` **throws `ErrorWrap`** instead of returning null; dropped GtkD’s manual `doref()`. Also fixed an upstream bug: `scope(exit) pipe.close()` closed a fresh pipe, not `output`.
- [x] **`gx/ttyx/prefeditor/bookmarkeditor.d`** (6) — ported + verified (`dub test`; GUI smoke test inside prefs). Near-mechanical Box subclass; third local copy of `getSelectedIter` (**hoist to gx.gtk.util with prefdialog/profileeditor**); guarded a latent null-iter pass to `unselectIter`.
- [x] **`gx/ttyx/terminal/layout.d`** (6) — ported + verified (`dub test`; dialog needs GUI smoke test). advpaste-pattern dialog; `getContentArea()` returns `Box` directly in giD gtk3. **Gotcha: giD `Window` has a `nothrow title` property pair GtkD lacked — a subclass `title` property must be `override nothrow`** (and now virtually dispatches through base refs). Badge row works again thanks to the vte.d dlsym fix (below).
- [x] **`gx/ttyx/terminal/exvte.d`** (7, C) — ported + verified (compiles/links; enum-converter tests pass. **Patched-VTE signals + disable-bg-draw need a runtime check on a patched VTE build**). `vtePasteText` is native `Terminal.pasteText` in giD (GtkD-3.10 shim gone). Patched-VTE signals use hand-written closure marshals mirroring giD generated `connect*` code (`DClosure` + `connectSignalClosure` + `signalLookup` probe; **pattern for any unbound signal**). `vte_terminal_get/set_disable_bg_draw` resolved via `dlsym(RTLD_DEFAULT)` with null-guards (link-time extern(C) would fail on standard VTE). VTE enums: `vte.types` PascalCase.
- [x] **`gx/ttyx/prefeditor/common.d`** (7) — ported + verified (`dub test`). Shared prefs helpers, signatures unchanged for profileeditor/prefdialog. `gtk.global.checkVersion` returns null (not "") when compatible — `.length == 0` still works; `getToplevel()` returns most-derived wrapper so `cast(Window)` carries over.
- [x] **`gx/gtk/resource.d`** (8) — ported + verified. `GException` → `glib.error.ErrorWrap`; `Util.getSystemDataDirs` → `glib.global.getSystemDataDirs`; `Resource.register`/`resourcesLookupData` (GtkD statics) → free funcs `gio.global.resourcesRegister`/`resourcesLookupData` (`Resource.load` stays static); `Bytes.getData` → `ubyte[]`; `CssProvider.loadFromData(ubyte[])`; `ResourceLookupFlags.None`.
- [x] **`gx/ttyx/shortcuts.d`** (8, C) — ported + verified (compiles/links in test build). Raw `gtkc.gobject` construct-property `new ObjectG(getType(), [props], [Values])` → giD fluent **`ShortcutsShortcut.builder().title(t).accelerator(a).build()`** (the pattern for construct-time properties). `Builder.addFromResource` throws `ErrorWrap` (caught → log + return null, matching intent of the original bool check). `Builder.getObject` returns most-derived wrapper, so plain D downcasts carry over.
- [x] **`gx/gtk/actions.d`** (8) — ported + verified. Accelerators via `gtk.global.acceleratorParse/GetLabel`; `ActionMap`/`SimpleAction.newStateful`; signals `connectActivate`/`connectChangeState` (delegate `void(Variant, SimpleAction)`); app re-typed via `ObjectWrap._getDObject!(Application)(def._cPtr, No.Take)` (giD re-wrap idiom, not a plain cast). Pure string helpers + tests unchanged.
- [x] **`gx/ttyx/bookmark/manager.d`** (8) — ported + verified (`dub test`: JSON roundtrip passes). ~90% pure D unchanged. `gdk.Pixbuf` → `gdkpixbuf.pixbuf.Pixbuf`. **Gotcha: `IconInfo.loadSymbolic(fg, null, null, null, …)` inexpressible in giD** (RGBA value struct → wrapper always passes `&arg`, no way to say NULL); replaced with `loadSymbolicForContext(styleContext, wasSymbolic)` — same defaults, tint colors now derive from the style context (no visible difference for the fg-only icons used).
- [x] **`gx/ttyx/terminal/renderer.d`** (8) — ported + verified (probe-instantiated `connectDraw` caller shapes incl. `Yes.After`). `initColors` explicit `RGBA(0,0,0,0)` everywhere (NaN gotcha); `dimColor` out-param → `ref RGBA`. **NULL color resets inexpressible through giD wrappers** (`setColorBold(null)` etc.) — reset paths call raw `vte.c.functions` C directly (the pattern for semantically-nullable boxed params). **pangocairo is its own subpackage**: `PgCairo.showLayout` → `pangocairo.global.showLayout`, `gid:pangocairo1` added to dub.json. `PANGO_SCALE` → `pango.types : SCALE`; draw callbacks are `bool (Context, Widget)` (no `Scoped!`). **Caller note: `vteBG` returns a value snapshot, not a live shared reference** — the terminal.d port must re-read it after color changes.
- [x] **`gx/gtk/x11.d`** (9) — ported + verified (compiles+links; **X11 runtime behavior untested headlessly — verify _NET_ACTIVE_WINDOW on a real X11 session**). giD binds neither the GDK X11 backend nor raw Xlib events, so: reuse the vendored GtkD-free `x11.X`/`x11.Xlib` bindings (wired via `sourceFiles`+`importPaths ../../source`+`libs X11` in dub.json — the **reuse-vendored-source pattern** for later modules); declare `gdk_x11_*` helpers as plain `extern(C)` (resolve from libgdk-3 at link, no runtime Linker); `gtk.global.getCurrentEventTime`, `gdk.global.errorTrapPush/Pop/flush`, GdkWindow* via `_cPtr`.
- [x] **`gx/ttyx/bookmark/bmchooser.d`** (10) — ported + verified (`dub test`; GUI smoke test with bookmark UI). advpaste-pattern dialog; `connectKeyPressEvent(bool delegate(EventKey))` + `.keyval`; zero-param delegate literals for cursor/row/search signals (arity-reduction sidesteps the name-every-param pitfall); `response(X)` call instead of GtkD property sugar.
- [x] **`gx/ttyx/terminal/clipboard.d`** (11, C) — ported + verified (`dub test`: paste-safety suites pass). Raw C gone: `g_source_remove` → `glib.source.Source.remove(tag)`; `markupEscapeText` → `glib.global`. **API note: `paste`/`advancedPaste` take `gdk.atom.Atom` (class) now** — callers using `GDK_SELECTION_*` from the ported gx/gtk/clipboard are unaffected. UnsafePasteDialog (MessageDialog subclass) via raw-construct + post-set `messageType`; `getMessageArea()` cast to Box.
- [x] **`gx/ttyx/prefeditor/titleeditor.d`** (13) — ported + verified (`dub test`). Menu/popover module: `Editable.insertText` drops the length param, takes position by `ref`; `Image.newFromIconName`; `MountOperation.showUri` → `gtk.global.showUri(null, uri, getCurrentEventTime())`; `ConnectFlags.AFTER` → `Yes.After`. **Gotcha (also hit by search.d): delegate literals passed to giD `connect*` templates must name EVERY parameter** — an unnamed typed param (`delegate(GVariant, SimpleAction sa)`) parses as an untyped param *named* `GVariant` and inference dies.
- [x] **`gx/gtk/cairo.d`** (14) — ported + verified. giD binds cairo *procedurally*: no `ImageSurface` class (use `cairo.surface.Surface` + `cairo.global.imageSurfaceCreate/GetWidth/GetHeight`, `cairo.global.create` for a Context); enums `cairo.types.Format.Argb32`/`Operator.Source`/`Filter.Bilinear`/`Extend.Repeat`/`Content.Color`; gdk↔cairo via `gdk.global.cairoSetSourcePixbuf`/`pixbufGetFromSurface`; cairo objects are GC-managed (dropped explicit `.destroy()`); `gtk.Main` → `gtk.global.eventsPending`/`mainIterationDo`; `addOnDamage` → `connectDamageEvent(bool delegate(EventExpose, Widget))`.
- [x] **`gx/ttyx/terminal/advpaste.d`** (14) — ported + verified (compiles/links; first Dialog subclass). **Key pattern: giD binds no `gtk_dialog_new_with_buttons` and `use-header-bar` is construct-only** → raw `g_object_new(Dialog._getGType(), "use-header-bar", 1, null)` passed to `super(ptr, No.Take)`, then `setTitle`/`setModal`/`addButton(label, ResponseType.X)`. Use this for closedialog/bmeditor/advdialog/password. Also: `TextView.newWithBuffer`, `SpinButton.newWithRange`, no-arg `ScrolledWindow` + `add`, buffer `getBounds(out s, out e)` + `getText(s, e, true)`, `connectKeyPressEvent(bool delegate(EventKey))` with `.keyval`/`.state` field access, keysyms `gdk.types.KEY_*`.
- [x] **`gx/ttyx/customtitle.d`** (15, C) — ported + verified (`dub test`; click-to-edit headerbar title needs GUI smoke test with CSD). `g_timeout_add` + trampoline → `glib.global.timeoutAdd(PRIORITY_DEFAULT, ms, delegate)` + `Source.remove(tag)`; `Signals.handlerBlock/Unblock` → `gobject.global.signalHandlerBlock/Unblock`; typed event structs (`EventButton.button/.state/.type`, `EventKey.keyval`) replace generic `gdk.Event` out-param getters; `getSettings().gtkDoubleClickTime` typed property replaces the Value dance.
- [x] **`gx/ttyx/bookmark/bmtreeview.d`** (17) — ported + verified (`dub test`; DnD + filter need GUI smoke test with the bookmark UI). First TreeModelFilter/DnD module: `new TreeModelFilter(ts, null)` → `cast(TreeModelFilter) ts.filterNew(null)`. **Two critical TreeIter gotchas for all remaining tree code:** (1) giD `out TreeIter` is ALWAYS non-null even when the call returns false — convert every GtkD null-check to a bool-return check; (2) never alias an `out` iter with its own input (`iterParent(parent, parent)` zeroes the arg before the C call reads it — segfault); use a temp per step. DnD: `connectDragDataGet/Received`, `SelectionData.getData()` returns length-sliced `ubyte[]` (cast to `char[]` before `to!string`), `TreePath.toString_()`, `expandRow(path, openAll)`.
- [x] **`gx/ttyx/bookmark/bmeditor.d`** (18) — ported + verified (`dub test`; GUI smoke test). **`addOnNotify(dg, "detail", AFTER)` → `connectNotify("detail", dg, Yes.After)` — detail string comes FIRST**; `(ParamSpec, ObjectWrap)` delegate params all named. `Button.newFromIconName`; `SpinButton.newWithRange`; `FileChooserButton(title, action)` bound as-is; `glib.global.getHomeDir`.
- [x] **`gx/ttyx/closedialog.d`** (18) — ported + verified (`dub test`). Second Dialog on the advpaste pattern (`run()`/`response`/`setDefaultResponse` all bound, plain int). **Enum-typed GObject properties: use giD typed setters** (`crt.ellipsize = EllipsizeMode.End`) — a `Value` built from a D enum inits abstract `G_TYPE_ENUM` and warns. `IconInfo.loadIcon()` throws `ErrorWrap` where GtkD returned null (caught → warning, empty icon cell). Pixbuf column type via `Pixbuf._getGType()` in `TreeStore.new_`.
- [x] **`gx/ttyx/prefeditor/advdialog.d`** (19) — ported + verified (`dub test`). Both dialogs on the advpaste raw-`g_object_new` header-bar pattern. `TreeViewColumn` varargs ctor unbound → no-arg + `setTitle`/`packStart`/`addAttribute`; GtkD conveniences `getSelectedIter`/`getValueString` unbound → local helpers (**hoist into gx.gtk.util when prefdialog/profileeditor need them**); `TreePath.newFromString`; **CellRendererCombo config via typed properties** (`crt.model`/`editable`/`hasEntry`/`textColumn` — no raw `g_object_set`); renderer signals `connectEdited`/`connectToggled`/`connectChanged`; OR-ed `SettingsBindFlags` need a cast back. Reuses `gx/util/string.d` (added to dub.json).
- [x] **`gx/ttyx/terminal/search.d`** (24) — ported + verified (`dub test`; search UI needs GUI smoke test). `Popover.newFromModel`; `VRegex.newForSearch(p, flags)` throws `ErrorWrap`; `GSettings.connectChanged(null, cb)` (detail first, null = all keys); `ActionGroupIF` → `gio.action_group.ActionGroup`. **Fixed an upstream copy-paste bug: `onSearchEntryFocusOut` was wired to a second focus-IN connect, so it fired on focus-in and never on focus-out** — now connected to the real focus-out event (terminal.d will see correct in/out pairs). Reuses `gx/ttyx/terminal/actions.d` (added to dub.json).
- [x] **`gx/ttyx/terminal/password.d`** (27) — ported + verified (`dub test`: removeRowById suite passes; **keyring flows need a runtime check against a live Secret Service**). **Vendored `secret/`+`secretc/` retired — replaced by `gid:secret1` (new dub dep)**: attributes are `string[string]` end-to-end, `getItems()` returns `Item[]`, async callbacks are D delegates, `Service.disconnect()` is static, `new SecretValue(pwd, "text/plain")`. **Three gid:secret1 generation gaps filled with local raw-C helpers** (`secret.c.functions`): Schema construction (`secret_schema_newv` + GHashTable), async `secret_password_storev` (giD binds only sync; helper mirrors giD trampoline pattern), non-pageable password lookup (giD binds only pageable). GTK side all established patterns.

### Heavy (the core widgets — port last, once patterns are solid)
- [x] **`gx/ttyx/session.d`** (28) — ported + verified (`dub test` + live run). Session/pane container; `Session.name` & `SessionProperties.name` are `override @property … nothrow` (giD Widget defines a `name` property pair); `SessionProperties` on the raw-`g_object_new` header-bar pattern; onDraw uses `connectDraw(bool delegate(Context, Widget))` (Context is Boxed — fine); cairo child surface GC-managed.
- [x] **`gx/ttyx/sidebar.d`** (29) — ported + verified. `Revealer.setRevealChild` override is `override … nothrow`; typed event structs; `Image.newFromPixbuf`; DnD via `connectDragDataGet/Received`.
- [x] **`gx/gtk/util.d`** (33) — ported + verified (incl. force-instantiating every template via a temp probe file). `File.parseName` native in giD; `Container.getChildren` → `Widget[]`; tree stores `append(out iter)` + `setValue(iter, col, new Value(v))` (templated `Value` ctor); `ComboBox.newWithModel` + CellLayout `packStart`/`addAttribute`; `Settings.getDefault().gtkThemeName` typed property; `isWayland` via extern(C) `gdk_x11_window_get_type` + `gobject.global.typeCheckInstanceIsA` on a `TypeInstance(No.Take)`; **RGBA is a value struct → `equal(RGBA, RGBA)` lost null handling — callers must compare directly**; combo-factory tail deduped into `wireNameValueCombo`.
- [x] **`gx/ttyx/application.d`** (36, C) — ported + verified (all 9 migrate* tests pass; links; runs). Signals `connectActivate/Startup/Shutdown/CommandLine`; disabled-shortcut hack → `super.setAccelsForAction(name, [])`; `setAccelsForAction` override is `nothrow`; gtk.Settings Value dance → typed props; `getBackgroundImage()` returns `cairo.surface.Surface`; **dub.json gained `gdk-3` in libs-linux** (x11.d’s `gdk_x11_*` externs go live once `activateWindow` is reachable — dead-stripped before).
- [x] **`gx/ttyx/prefeditor/profileeditor.d`** (40) — ported + verified. `FileChooserDialog.builder()…build()` + `addButton`; `signalHandlerBlock/Unblock`; `ComboBoxText()`; `ColorButton.getRgba(out RGBA)` value-struct; local `getSelectedIter`/`getValueString`. Reuses `gx/ttyx/encoding.d`.
- [x] **`gx/ttyx/prefeditor/prefdialog.d`** (56) — ported + verified. `cast(TreeModelFilter) ts.filterNew(null)`; `setVisibleFunc(bool delegate(TreeModel, TreeIter))`; `CellRendererAccel` typed props + `connectAccelEdited/Cleared`; accelerators via `gtk.global.accelerator*`; markup parse via raw `g_markup_parse_context_*`; `MessageDialog.builder().buttons(ButtonsType.OkCancel)`. **Do not use `with (window)` — giD `Window.title`/`Widget.name` shadow locals.**
- [x] **`gx/ttyx/terminal/terminal.d`** (~3.6k-line VTE widget — the crown jewel) — ported + verified (`dub test` + live run). Real event needed → `gtk.global.getCurrentEvent()` inside handler; VTE class-handler invoke via `GTypeInstance.gClass`; boxed-event mutation (sync replay) pokes `(cast(GdkEvent*)ev._cPtr).key.sendEvent`; `vte_terminal_get_text_range` + `gdk_drag_context_list_targets` unbound → raw C; `feedChild` takes `ubyte[]`; `getUserShell` free func; INSERT_PASSWORD gated by `dlopen("libsecret-1.so.0")`; bell timer via `timeoutAdd` delegate. Companion `terminal/monitor.d` ported (`vtec.vtetypes` → `glib.types.Pid`). GUI smoke: right-click selection-preserve, URL/hyperlink click, DnD (Wayland cursor!), color drop, sync input, bell, triggers, Save Output, password insert.
- [x] **`gx/ttyx/appwindow.d`** — ported + verified (`dub test` + live run). ApplicationWindow subclass; `this(Application)` direct; `FileChooserDialog` raw-`g_object_new`; typed event structs; `Session.name`/`hide`/`present` overrides `nothrow`; quake geometry via deprecated Screen/Display APIs. Fixed upstream bug: `addEvents(EventType.SCROLL)` → `EventMask.ScrollMask`.
- [x] **`app.d`** (5) — ported + verified (`dub build`; `./ttyx --version` correct; **replaces the POC skeleton**). `glib.Util`/`FileUtils` → `glib.global`; giD has no `gtk.Main.init` wrapper → hand-marshal argc/argv to raw `gtk_init` and rebuild `args`; pre-run error dialogs on the builder pattern.

## Then: swap the build, delete GtkD, ship (Phase 2a done). Phase 2b = GTK4.
