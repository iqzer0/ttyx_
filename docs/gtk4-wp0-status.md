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

## Resuming

```bash
./typecheck-gtk4.sh --all                    # progress: N clean / M failing
./typecheck-gtk4.sh source/gx/gtk/util.d     # work one module
RAW=1 ./typecheck-gtk4.sh <file>             # include giD-internal noise
```

Suggested order: finish the mechanical sweep first (it is verifiable and
shrinks the surface), then WP2, since the `gdk.event_*` family blocks the
most files.
