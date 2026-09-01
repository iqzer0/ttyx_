#!/usr/bin/env python3
"""Compiler-driven container-API sweep.

GTK4 replaced GtkContainer.add with type-specific methods, so the correct
replacement depends on the receiver's type — which cannot be inferred from a
variable name. But the compiler reports it:

    no property `add` for `box` of type `gtk.box.Box`

so drive the rewrite off that instead of guessing. Converges because each pass
lets modules compile further and reveal more.
"""
import re, subprocess, sys, collections

# type -> replacement method for `add`
ADD_MAP = {
    'gtk.box.Box': 'append',
}
# anything Bin-like takes a single child
SETCHILD_TYPES = {
    'gtk.scrolled_window.ScrolledWindow', 'gtk.frame.Frame', 'gtk.revealer.Revealer',
    'gtk.menu_button.MenuButton', 'gtk.window.Window', 'gtk.overlay.Overlay',
    'gtk.viewport.Viewport', 'gtk.expander.Expander', 'gtk.button.Button',
    'gtk.toggle_button.ToggleButton', 'gtk.check_button.CheckButton',
    'gtk.event_box.EventBox', 'gtk.aspect_frame.AspectFrame',
}

ERR = re.compile(r'^(?P<file>source/[^(]+)\((?P<line>\d+)\): Error: no property `(?P<meth>add)` for `(?P<recv>[^`]+)` of type `(?P<type>[^`]+)`')

def failing_files():
    out = subprocess.run(['./typecheck-gtk4.sh','--all'], capture_output=True, text=True, timeout=3000).stdout
    return [l.split()[1] for l in out.splitlines() if l.strip().startswith('FAIL')]

def errors_for(f):
    out = subprocess.run(['./typecheck-gtk4.sh', f], capture_output=True, text=True, timeout=300).stdout
    return [m.groupdict() for l in out.splitlines() if (m := ERR.match(l.strip()))]

total = collections.Counter()
for it in range(6):
    edits = collections.defaultdict(list)   # file -> [(line, type)]
    for f in failing_files():
        for e in errors_for(f):
            edits[e['file']].append((int(e['line']), e['type']))
    if not edits:
        print(f"iteration {it}: no `.add` errors left"); break
    n = 0
    for f, sites in edits.items():
        lines = open(f).read().split('\n')
        for ln, ty in sites:
            i = ln - 1
            if i >= len(lines) or '.add(' not in lines[i]:
                continue
            if ty in ADD_MAP:
                repl = ADD_MAP[ty]
            elif ty in SETCHILD_TYPES:
                repl = 'setChild'
            else:
                print(f"  UNMAPPED type {ty} at {f}:{ln} — skipping"); continue
            lines[i] = lines[i].replace('.add(', f'.{repl}(', 1)
            n += 1; total[ty] += 1
        open(f, 'w').write('\n'.join(lines))
    print(f"iteration {it}: rewrote {n} site(s)")
    if n == 0:
        break

print("\ntotals by type:")
for t, c in total.most_common():
    print(f"  {c:3}  {t}")
