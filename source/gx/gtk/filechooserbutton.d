/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/**
 * A GtkFileChooserButton replacement for GTK4.
 *
 * GTK4 removed `GtkFileChooserButton` outright and offers no composite
 * equivalent: `GtkFileDialog` is a modal, asynchronous dialog, not a widget you
 * can drop into a grid. The old widget was a button that displayed the current
 * selection and opened a chooser when clicked, so that is rebuilt here.
 *
 * The point of doing it once, here, rather than inline at each call site is
 * that GTK4's chooser is **async**: the result arrives in a callback rather than
 * being returned. Spreading that plumbing across call sites would mean each one
 * separately reasoning about "what is the filename between the click and the
 * callback". This keeps `getFilename()` synchronous and always meaningful — it
 * returns the last *confirmed* selection — and confines the async part to one
 * place.
 *
 * The API deliberately mirrors the GTK3 widget (`setFilename`, `getFilename`,
 * `addFilter`, `unselectAll`, and a file-set callback) so call sites port with
 * near-zero change.
 *
 * Known differences from the GTK3 widget:
 *   - the chooser is modal, because GTK4's FileDialog is always modal
 *   - the button label shows the base name, not GTK3's shortened path
 *   - `addFilter` must be called before the first click to take effect
 */
module gx.gtk.filechooserbutton;

import std.path : baseName;

import gio.file : File;
import gio.list_store : ListStore;
import gio.types : AsyncReadyCallback;

import gobject.object : ObjectWrap;
import gobject.types : GTypeEnum, GType;

import gtk.button : Button;
import gtk.file_dialog : FileDialog;
import gtk.file_filter : FileFilter;
import gtk.types : FileChooserAction;
import gtk.window : Window;

import gio.async_result : AsyncResult;

/**
 * Button that opens a GTK4 FileDialog and remembers the chosen path.
 */
class FileChooserButton : Button {

private:
    string _title;
    FileChooserAction _action;
    string _filename;
    FileFilter[] _filters;
    void delegate() _onFileSet;

    /// Keep the label in step with the selection, matching GTK3's behaviour of
    /// showing the title when nothing is chosen.
    void refreshLabel() {
        setLabel(_filename.length > 0 ? baseName(_filename) : _title);
    }

    Window parentWindow() {
        return cast(Window) getRoot();
    }

    void openDialog() {
        FileDialog dialog = new FileDialog();
        dialog.setTitle(_title);

        if (_filters.length > 0) {
            ListStore store = new ListStore(cast(GType) FileFilter._getGType());
            foreach (f; _filters) {
                store.append(f);
            }
            dialog.setFilters(store);
        }

        if (_filename.length > 0) {
            File initial = File.newForPath(_filename);
            if (_action == FileChooserAction.SelectFolder) {
                dialog.setInitialFolder(initial);
            } else {
                dialog.setInitialFile(initial);
            }
        }

        // The two flavours have separate async pairs in GTK4; there is no
        // single "run the chooser" entry point.
        if (_action == FileChooserAction.SelectFolder) {
            dialog.selectFolder(parentWindow(), null,
                delegate(ObjectWrap source, AsyncResult res) {
                    try {
                        File chosen = dialog.selectFolderFinish(res);
                        if (chosen !is null) applySelection(chosen);
                    } catch (Exception) {
                        // Dismissed, or no permission — leave the previous
                        // selection intact rather than clearing it.
                    }
                });
        } else {
            dialog.open(parentWindow(), null,
                delegate(ObjectWrap source, AsyncResult res) {
                    try {
                        File chosen = dialog.openFinish(res);
                        if (chosen !is null) applySelection(chosen);
                    } catch (Exception) {
                    }
                });
        }
    }

    void applySelection(File chosen) {
        string path = chosen.getPath();
        if (path.length == 0) return;   // non-local URI; not supported here
        _filename = path;
        refreshLabel();
        if (_onFileSet !is null) _onFileSet();
    }

public:

    this(string title, FileChooserAction action) {
        super();
        _title = title;
        _action = action;
        refreshLabel();
        connectClicked(delegate() { openDialog(); });
    }

    /// The last confirmed selection, or an empty string. Always synchronous.
    string getFilename() {
        return _filename;
    }

    /// Set the selection without opening the chooser. Does NOT fire the
    /// file-set callback, matching GTK3, so callers can seed it from settings
    /// without triggering a save.
    void setFilename(string filename) {
        _filename = filename;
        refreshLabel();
    }

    /// Clear the selection. Does not fire the file-set callback.
    void unselectAll() {
        _filename = null;
        refreshLabel();
    }

    /// Filters offered by the chooser. Must be added before the first click.
    void addFilter(FileFilter filter) {
        if (filter !is null) _filters ~= filter;
    }

    /// Called when the user confirms a new selection.
    void connectFileSet(void delegate() callback) {
        _onFileSet = callback;
    }
}
