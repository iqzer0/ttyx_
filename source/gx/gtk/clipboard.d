/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/gtk/clipboard.d.
 *
 * GtkD used `gdk.Atom` with a free `intern()` returning `GdkAtom`; giD models
 * it as a `gdk.atom.Atom` class with a static `Atom.intern(name, onlyIfExists)`.
 * The stored selection atoms are typed `Atom` (was `GdkAtom`); giD's
 * `gtk.clipboard.Clipboard.get` takes a `gdk.atom.Atom`, so consumers pass
 * these straight through.
 */
module gx.gtk.clipboard;

import gdk.atom : Atom;

/* Clipboard Atoms */
Atom GDK_SELECTION_CLIPBOARD;
Atom GDK_SELECTION_PRIMARY;
Atom GDK_SELECTION_SECONDARY;

static this() {
    GDK_SELECTION_CLIPBOARD = Atom.intern("CLIPBOARD", true);
    GDK_SELECTION_PRIMARY = Atom.intern("PRIMARY", true);
    GDK_SELECTION_SECONDARY = Atom.intern("SECONDARY", true);
}
