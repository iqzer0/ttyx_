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
- [ ] `gx/gtk/threads.d` (1)
- [ ] `gx/ttyx/terminal/spawn.d` (1)
- [ ] `gx/ttyx/terminal/types.d` (1)
- [ ] `gx/ttyx/colorschemes.d` (2)
- [ ] `gx/ttyx/preferences.d` (2)
- [ ] `gx/ttyx/terminal/context.d` (2)
- [ ] `gx/gtk/settings.d` (3, C)
- [ ] `gx/ttyx/terminal/regex.d` (4, C)
- [x] **`gx/gtk/vte.d`** (4) — ported + verified. Version via `vte.global.getMajorVersion`; keysyms `gdk.types.KEY_*`; patched-signal detection via `gobject.global.signalLookup` + `Terminal._getGType()`. **Behavioral note:** `DISABLE_BACKGROUND_DRAW` reported unavailable — giD binds only standard VTE (no patched `vte_terminal_get_disable_bg_draw`, no linker introspection); `isVTEBackgroundDrawEnabled()` falls back to the version check.
- [ ] `gx/ttyx/cmdparams.d` (4)
- [x] **`gx/gtk/dialog.d`** (5) — ported + verified (compiles/links in skeleton). First widget module: `MessageDialog.builder().build()` + property setters + `addButton` (no ctor/ButtonsType), enums PascalCase in `gtk.types`, `getMessageArea` cast to `Box`, `connectActivate`/`connectChanged`, `CheckButton.newWithLabel`.

### Mid (widgets, wrappers)
- [ ] `gx/ttyx/terminal/flatpak.d` (6, C)
- [ ] `gx/ttyx/prefeditor/bookmarkeditor.d` (6)
- [ ] `gx/ttyx/terminal/layout.d` (6)
- [ ] `gx/ttyx/terminal/exvte.d` (7, C) — VTE subclass; much of it becomes native `gid:vte2` (no hand-written C bindings)
- [ ] `gx/ttyx/prefeditor/common.d` (7)
- [ ] `gx/gtk/resource.d` (8, C)
- [ ] `gx/ttyx/shortcuts.d` (8, C)
- [x] **`gx/gtk/actions.d`** (8) — ported + verified. Accelerators via `gtk.global.acceleratorParse/GetLabel`; `ActionMap`/`SimpleAction.newStateful`; signals `connectActivate`/`connectChangeState` (delegate `void(Variant, SimpleAction)`); app re-typed via `ObjectWrap._getDObject!(Application)(def._cPtr, No.Take)` (giD re-wrap idiom, not a plain cast). Pure string helpers + tests unchanged.
- [ ] `gx/ttyx/bookmark/manager.d` (8)
- [ ] `gx/ttyx/terminal/renderer.d` (8)
- [ ] `gx/gtk/x11.d` (9, C) — or drop for `gid:xlib2`
- [ ] `gx/ttyx/bookmark/bmchooser.d` (10)
- [ ] `gx/ttyx/terminal/clipboard.d` (11, C)
- [ ] `gx/ttyx/prefeditor/titleeditor.d` (13)
- [ ] `gx/gtk/cairo.d` (14, C)
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
- [ ] `gx/gtk/util.d` (33)
- [ ] `gx/ttyx/application.d` (36, C)
- [ ] `gx/ttyx/prefeditor/profileeditor.d` (40)
- [ ] `gx/ttyx/prefeditor/prefdialog.d` (56)
- [ ] `gx/ttyx/terminal/terminal.d` (the ~3.6k-line VTE widget — the crown jewel)
- [ ] `gx/ttyx/appwindow.d`
- [ ] `app.d` (5) — entry point, wire together last

## Then: swap the build, delete GtkD, ship (Phase 2a done). Phase 2b = GTK4.
