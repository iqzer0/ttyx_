/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/**
 * Clipboard selection identifiers.
 *
 * GTK4 removed `GdkAtom` and the whole atom-named-selection model. There are
 * now exactly two clipboards, and they are obtained as objects from a widget or
 * display rather than looked up by an interned name:
 *
 *   - `Widget.getClipboard()`        — the CLIPBOARD selection
 *   - `Widget.getPrimaryClipboard()` — the PRIMARY selection
 *
 * So the three `Atom` constants this module used to export collapse into a
 * two-valued enum plus an accessor. `GDK_SELECTION_SECONDARY` is dropped
 * outright: GTK4 has no such clipboard, and it had no callers here anyway.
 *
 * Callers that previously threaded an `Atom` through (for example
 * `ClipboardHandler.paste(Atom source)`) should thread a `ClipboardSelection`
 * instead and resolve it against their own widget at the point of use — the
 * clipboard is per-display, so it needs a widget in the tree.
 */
module gx.gtk.clipboard;

import gdk.clipboard : Clipboard;

import gtk.widget : Widget;

/**
 * Which of GTK4's two clipboards an operation applies to.
 *
 * Replaces the GTK3 `GDK_SELECTION_CLIPBOARD` / `GDK_SELECTION_PRIMARY` atoms.
 */
enum ClipboardSelection {
    /// The CLIPBOARD selection — explicit copy/paste.
    clipboard,
    /// The PRIMARY selection — X11-style select-to-copy, middle-click paste.
    primary
}

/**
 * Resolve `selection` to the actual clipboard for `widget`'s display.
 *
 * Returns null if `widget` is null, since there is no display to ask.
 */
Clipboard selectionClipboard(Widget widget, ClipboardSelection selection) {
    if (widget is null) return null;
    return selection == ClipboardSelection.primary
        ? widget.getPrimaryClipboard()
        : widget.getClipboard();
}

unittest {
    // The enum exists to replace atoms that could not be compared or defaulted
    // meaningfully; pin the two values and the default so a reordering that
    // silently changed which clipboard is used shows up here.
    assert(ClipboardSelection.init == ClipboardSelection.clipboard,
        "default must be CLIPBOARD, not PRIMARY — a wrong default would silently "
        ~ "redirect explicit copy/paste to the select-to-copy buffer");
    assert(ClipboardSelection.clipboard != ClipboardSelection.primary);
}

unittest {
    // A null widget has no display, so there is no clipboard to return.
    assert(selectionClipboard(null, ClipboardSelection.clipboard) is null);
    assert(selectionClipboard(null, ClipboardSelection.primary) is null);
}
