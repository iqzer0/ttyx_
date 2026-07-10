/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD migration seed — the smallest thing that proves ttyx_'s toolkit stack
 * works on giD: a GTK3 ApplicationWindow containing a VTE terminal, built with
 * gid:gtk3 + gid:vte2 (VTE for GTK3) instead of GtkD. This is where the Phase 2
 * parallel rewrite grows from. See ../../docs/gid-migration.md.
 *
 * Note the giD idioms vs GtkD: snake_case module paths (gtk.application),
 * connectActivate for signals, ApplicationFlags from gio.types, and GTK3's
 * add()/showAll() (GTK4 would be setChild()/present()).
 */
import gtk.application;
import gtk.application_window;
import gtk.window;
import gio.types : ApplicationFlags;
import vte.terminal;

void main(string[] args)
{
    auto app = new Application("org.ttyx.gid.skeleton", ApplicationFlags.FlagsNone);
    app.connectActivate(() {
        auto win = new ApplicationWindow(app);
        win.setDefaultSize(640, 400);
        win.setTitle("ttyx_ giD skeleton");
        auto term = new Terminal();
        win.add(term);       // GTK3 Bin.add (GTK4 would be setChild)
        win.showAll();
    });
    app.run(args);
}
