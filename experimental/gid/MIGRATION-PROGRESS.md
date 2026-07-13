# Phase 2a migration progress (GtkD → giD, on GTK3)

Living checklist for the wholesale GtkD→giD port. Rationale, constraints, and
the reason this must be wholesale (giD and GtkD cannot coexist in one build)
are in [`../../docs/gid-migration.md`](../../docs/gid-migration.md).

**Model:** a separate giD build (this `experimental/gid/` project) that grows
until it reaches parity with the GtkD app under `source/`, then the main build
is swapped over. The ~26 GtkD-free files under `source/` carry over **unchanged**
and are reused as-is; only the GtkD-coupled files are ported here.

**Verification:** each ported module must compile against giD and keep its unit
tests passing. `color.d` was verified with `dub test` against `gid:gdk3`.

## ▶ Resuming in a new session (start here)

**Status:** 19 of ~44 modules ported. Everything is on `master` of the fork
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
  compile-verified only — test against a patched VTE build (e.g. Fedora).

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
- [ ] `gx/ttyx/terminal/regex.d` (4, C)
- [x] **`gx/gtk/vte.d`** (4) — ported + verified. Version via `vte.global.getMajorVersion`; keysyms `gdk.types.KEY_*`; patched-signal detection via `gobject.global.signalLookup` + `Terminal._getGType()`. **Behavioral note:** `DISABLE_BACKGROUND_DRAW` reported unavailable — giD binds only standard VTE (no patched `vte_terminal_get_disable_bg_draw`, no linker introspection); `isVTEBackgroundDrawEnabled()` falls back to the version check.
- [ ] `gx/ttyx/cmdparams.d` (4)
- [x] **`gx/gtk/dialog.d`** (5) — ported + verified (compiles/links in skeleton). First widget module: `MessageDialog.builder().build()` + property setters + `addButton` (no ctor/ButtonsType), enums PascalCase in `gtk.types`, `getMessageArea` cast to `Box`, `connectActivate`/`connectChanged`, `CheckButton.newWithLabel`.

### Mid (widgets, wrappers)
- [x] **`gx/ttyx/terminal/flatpak.d`** (6, C) — ported + verified (compiles/links; **Flatpak D-Bus path needs a runtime check inside a real sandbox**). All raw C is gone: `g_variant_new` varargs → typed `Variant.newBytestring/newBytestringArray/newDictEntry/newHandle/newTuple` (VariantBuilders kept so empty `a{uh}`/`a{ss}` stay correctly typed); extern(C) signal callback + `GC.addRoot` → D-delegate `signalSubscribe` closure over a heap state struct; `callWithUnixFdListSync` **throws `ErrorWrap`** instead of returning null; dropped GtkD’s manual `doref()`. Also fixed an upstream bug: `scope(exit) pipe.close()` closed a fresh pipe, not `output`.
- [ ] `gx/ttyx/prefeditor/bookmarkeditor.d` (6)
- [ ] `gx/ttyx/terminal/layout.d` (6)
- [x] **`gx/ttyx/terminal/exvte.d`** (7, C) — ported + verified (compiles/links; enum-converter tests pass. **Patched-VTE signals + disable-bg-draw need a runtime check on a patched VTE build**). `vtePasteText` is native `Terminal.pasteText` in giD (GtkD-3.10 shim gone). Patched-VTE signals use hand-written closure marshals mirroring giD generated `connect*` code (`DClosure` + `connectSignalClosure` + `signalLookup` probe; **pattern for any unbound signal**). `vte_terminal_get/set_disable_bg_draw` resolved via `dlsym(RTLD_DEFAULT)` with null-guards (link-time extern(C) would fail on standard VTE). VTE enums: `vte.types` PascalCase.
- [ ] `gx/ttyx/prefeditor/common.d` (7)
- [x] **`gx/gtk/resource.d`** (8) — ported + verified. `GException` → `glib.error.ErrorWrap`; `Util.getSystemDataDirs` → `glib.global.getSystemDataDirs`; `Resource.register`/`resourcesLookupData` (GtkD statics) → free funcs `gio.global.resourcesRegister`/`resourcesLookupData` (`Resource.load` stays static); `Bytes.getData` → `ubyte[]`; `CssProvider.loadFromData(ubyte[])`; `ResourceLookupFlags.None`.
- [ ] `gx/ttyx/shortcuts.d` (8, C)
- [x] **`gx/gtk/actions.d`** (8) — ported + verified. Accelerators via `gtk.global.acceleratorParse/GetLabel`; `ActionMap`/`SimpleAction.newStateful`; signals `connectActivate`/`connectChangeState` (delegate `void(Variant, SimpleAction)`); app re-typed via `ObjectWrap._getDObject!(Application)(def._cPtr, No.Take)` (giD re-wrap idiom, not a plain cast). Pure string helpers + tests unchanged.
- [ ] `gx/ttyx/bookmark/manager.d` (8)
- [ ] `gx/ttyx/terminal/renderer.d` (8)
- [x] **`gx/gtk/x11.d`** (9) — ported + verified (compiles+links; **X11 runtime behavior untested headlessly — verify _NET_ACTIVE_WINDOW on a real X11 session**). giD binds neither the GDK X11 backend nor raw Xlib events, so: reuse the vendored GtkD-free `x11.X`/`x11.Xlib` bindings (wired via `sourceFiles`+`importPaths ../../source`+`libs X11` in dub.json — the **reuse-vendored-source pattern** for later modules); declare `gdk_x11_*` helpers as plain `extern(C)` (resolve from libgdk-3 at link, no runtime Linker); `gtk.global.getCurrentEventTime`, `gdk.global.errorTrapPush/Pop/flush`, GdkWindow* via `_cPtr`.
- [ ] `gx/ttyx/bookmark/bmchooser.d` (10)
- [ ] `gx/ttyx/terminal/clipboard.d` (11, C)
- [ ] `gx/ttyx/prefeditor/titleeditor.d` (13)
- [x] **`gx/gtk/cairo.d`** (14) — ported + verified. giD binds cairo *procedurally*: no `ImageSurface` class (use `cairo.surface.Surface` + `cairo.global.imageSurfaceCreate/GetWidth/GetHeight`, `cairo.global.create` for a Context); enums `cairo.types.Format.Argb32`/`Operator.Source`/`Filter.Bilinear`/`Extend.Repeat`/`Content.Color`; gdk↔cairo via `gdk.global.cairoSetSourcePixbuf`/`pixbufGetFromSurface`; cairo objects are GC-managed (dropped explicit `.destroy()`); `gtk.Main` → `gtk.global.eventsPending`/`mainIterationDo`; `addOnDamage` → `connectDamageEvent(bool delegate(EventExpose, Widget))`.
- [ ] `gx/ttyx/terminal/advpaste.d` (14)
- [ ] `gx/ttyx/customtitle.d` (15, C)
- [ ] `gx/ttyx/bookmark/bmtreeview.d` (17)
- [ ] `gx/ttyx/bookmark/bmeditor.d` (18)
- [ ] `gx/ttyx/closedialog.d` (18)
- [ ] `gx/ttyx/prefeditor/advdialog.d` (19)
- [ ] `gx/ttyx/terminal/search.d` (24)
- [ ] `gx/ttyx/terminal/password.d` (27) — also swap vendored `secret/` for `gid` libsecret

### Heavy (the core widgets — port last, once patterns are solid)
- [ ] `gx/ttyx/session.d` (28)
- [ ] `gx/ttyx/sidebar.d` (29)
- [x] **`gx/gtk/util.d`** (33) — ported + verified (incl. force-instantiating every template via a temp probe file). `File.parseName` native in giD; `Container.getChildren` → `Widget[]`; tree stores `append(out iter)` + `setValue(iter, col, new Value(v))` (templated `Value` ctor); `ComboBox.newWithModel` + CellLayout `packStart`/`addAttribute`; `Settings.getDefault().gtkThemeName` typed property; `isWayland` via extern(C) `gdk_x11_window_get_type` + `gobject.global.typeCheckInstanceIsA` on a `TypeInstance(No.Take)`; **RGBA is a value struct → `equal(RGBA, RGBA)` lost null handling — callers must compare directly**; combo-factory tail deduped into `wireNameValueCombo`.
- [ ] `gx/ttyx/application.d` (36, C)
- [ ] `gx/ttyx/prefeditor/profileeditor.d` (40)
- [ ] `gx/ttyx/prefeditor/prefdialog.d` (56)
- [ ] `gx/ttyx/terminal/terminal.d` (the ~3.6k-line VTE widget — the crown jewel)
- [ ] `gx/ttyx/appwindow.d`
- [ ] `app.d` (5) — entry point, wire together last

## Then: swap the build, delete GtkD, ship (Phase 2a done). Phase 2b = GTK4.
