/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/gtk/dialog.d — the first widget module.
 *
 * Main divergence from GtkD: giD has no multi-arg MessageDialog constructor
 * (GTK's is varargs, not introspectable). Construct via MessageDialog.builder()
 * .build() and set message-type/text via property setters; add buttons with
 * Dialog.addButton (avoiding construct-only ButtonsType); enums live in
 * gtk.types and are PascalCase (MessageType.Error, ResponseType.Ok). Signals
 * use connectX. getMessageArea returns a Widget (cast to a container to add).
 */
module gx.gtk.dialog;

import std.experimental.logger;

import gio.async_result : AsyncResult;
import gio.file : File;
import gio.list_model : ListModel;
import gio.list_store : ListStore;
import gio.settings : GSettings = Settings;

import gobject.object : ObjectWrap;
import gobject.types : GType;
import gtk.box : Box;
import gtk.check_button : CheckButton;
import gtk.dialog : Dialog;
import gtk.entry : Entry;
import gtk.file_dialog : FileDialog;
import gtk.file_filter : FileFilter;
import gtk.message_dialog : MessageDialog;
import gtk.widget : Widget;
import gtk.window : Window;
import gtk.types : MessageType, ResponseType;

import gx.i18n.l10n;

/**
 * Displays an error message in a dialog
 */
void showErrorDialog(Window parent, string message, string title = null) {
    showMessageDialog(MessageType.Error, parent, message, title);
}

/**
 * Displays a message dialog of the specified type
 */
void showMessageDialog(MessageType mt, Window parent, string message, string title = null) {
    MessageDialog dialog = MessageDialog.builder().build();
    dialog.messageType = mt;
    dialog.text = message;
    dialog.addButton(_("_OK"), ResponseType.Ok);
    dialog.setModal(true);
    dialog.setTransientFor(parent);
    if (title.length > 0)
        dialog.setTitle(title);
    // GTK4: no Dialog.run(); every caller treats this as fire-and-forget.
    dialog.connectResponse(delegate(int response, Dialog d) {
        dialog.destroy();
    });
    dialog.present();
}

alias OnValidate = bool delegate(string value);

/**
 * Show an input dialog with a single entry for input.
 *
 * GTK4 dialogs are asynchronous: the entered value is delivered to `then`,
 * which is called only when the user confirms.
 */
void showInputDialog(Window parent, string initialValue, string title, string message, OnValidate validate, void delegate(string value) then) {
    MessageDialog dialog = MessageDialog.builder().build();
    dialog.messageType = MessageType.Question;
    dialog.text = message;
    dialog.addButton(_("_OK"), ResponseType.Ok);
    dialog.addButton(_("_Cancel"), ResponseType.Cancel);
    dialog.setModal(true);
    dialog.setTransientFor(parent);
    dialog.setTitle(title);
    Entry entry = new Entry();
    if (initialValue.length > 0) {
        entry.setText(initialValue);
    }
    entry.connectActivate(() {
        dialog.response(ResponseType.Ok);
    });
    if (validate !is null) {
        entry.connectChanged(() {
            if (validate(entry.getText)) {
                entry.getStyleContext().removeClass("error");
                dialog.setResponseSensitive(ResponseType.Ok, true);
            } else {
                entry.getStyleContext().addClass("error");
                dialog.setResponseSensitive(ResponseType.Ok, false);
            }
        });
    }
    (cast(Box) dialog.getMessageArea()).append(entry);
    dialog.setDefaultResponse(ResponseType.Ok);
    dialog.connectResponse(delegate(int response, Dialog d) {
        string value = entry.getText();
        dialog.destroy();
        if (response == ResponseType.Ok) then(value);
    });
    dialog.present();
}

/**
 * Shows a confirmation dialog with the optional ability to include an ignore
 * checkbox tied to gio.Settings so the user no longer has to see the dialog.
 */
void showConfirmDialog(Window parent, string message, GSettings settings, string promptKey, void delegate(bool confirmed) then) {
    if (settings !is null && !settings.getBoolean(promptKey)) { then(true); return; }

    MessageDialog dialog = MessageDialog.builder().build();
    dialog.messageType = MessageType.Question;
    dialog.text = message;
    dialog.addButton(_("_OK"), ResponseType.Ok);
    dialog.addButton(_("_Cancel"), ResponseType.Cancel);
    dialog.setModal(true);
    dialog.setTransientFor(parent);
    CheckButton cbPrompt = CheckButton.newWithLabel(_("Do not show this again"));
    cbPrompt.setMarginStart(12);
    dialog.getContentArea().append(cbPrompt);
    dialog.setDefaultResponse(ResponseType.Cancel);
    // GTK4: no Dialog.run(); the answer goes through the continuation.
    dialog.connectResponse(delegate(int response, Dialog d) {
        bool result = response == ResponseType.Ok;
        if (settings !is null) settings.setBoolean(promptKey, !cbPrompt.getActive());
        dialog.destroy();
        then(result);
    });
    dialog.present();
}

/**
 * File-selection helpers over GTK4's FileDialog.
 *
 * GtkFileChooserDialog is deprecated in GTK4 and, worse, no longer usable for
 * this: GTK4 removed its `file-activated` signal, so double-clicking a file or
 * pressing Return in the location bar does not confirm the dialog — only the
 * accept button does, which is a surprising thing to hand a user. GtkFileDialog
 * is the modern replacement and its dialog handles activation itself.
 *
 * It is asynchronous, so each helper takes a continuation that runs only when
 * the user confirms; dismissal throws inside the finish call and is swallowed.
 * The continuation receives local filesystem paths, since every caller here
 * writes or reads with std.file.
 */
/**
 * A file dialog reports the user dismissing it as an error, so that case is
 * routine and stays at trace level; anything else means we asked for a file
 * and did not get one, which is a fault worth seeing.
 */
private void reportDialogFailure(string what, Exception e) {
    import std.algorithm : canFind;
    if (e.msg.canFind("ismiss") || e.msg.canFind("ancel")) {
        tracef("File %s dialog dismissed: %s", what, e.msg);
    } else {
        warningf("File %s dialog returned no file: %s", what, e.msg);
    }
}

private ListStore filterStore(FileFilter[] filters) {
    if (filters.length == 0) return null;
    ListStore store = new ListStore(cast(GType) FileFilter._getGType());
    foreach (f; filters) store.append(f);
    return store;
}

private FileDialog buildFileDialog(string title, string acceptLabel, string initialFolder, FileFilter[] filters) {
    FileDialog dialog = new FileDialog();
    dialog.setTitle(title);
    if (acceptLabel.length > 0) dialog.setAcceptLabel(acceptLabel);
    dialog.setModal(true);
    ListStore store = filterStore(filters);
    if (store !is null) dialog.setFilters(store);
    if (initialFolder.length > 0) dialog.setInitialFolder(File.newForPath(initialFolder));
    return dialog;
}

/// One existing file. `then` is called with its path only if the user confirms.
void showOpenFileDialog(Window parent, string title, string acceptLabel, string initialFolder,
        FileFilter[] filters, void delegate(string path) then) {
    FileDialog dialog = buildFileDialog(title, acceptLabel, initialFolder, filters);
    dialog.open(parent, null, delegate(ObjectWrap source, AsyncResult res) {
        try {
            File chosen = dialog.openFinish(res);
            if (chosen is null) return;
            string path = chosen.getPath();
            if (path.length > 0) then(path);
        } catch (Exception e) {
            reportDialogFailure("open", e);
        }
    });
}

/// Several existing files. `then` gets the local paths, never an empty array.
void showOpenFilesDialog(Window parent, string title, string acceptLabel, string initialFolder,
        FileFilter[] filters, void delegate(string[] paths) then) {
    FileDialog dialog = buildFileDialog(title, acceptLabel, initialFolder, filters);
    dialog.openMultiple(parent, null, delegate(ObjectWrap source, AsyncResult res) {
        try {
            ListModel files = dialog.openMultipleFinish(res);
            if (files is null) return;
            string[] paths;
            foreach (i; 0 .. files.getNItems()) {
                // giD's templated getItem!T is required for an interface type:
                // the plain getItem returns a base wrapper, and GFile's concrete
                // class (GLocalFile) has no D counterpart, so casting that to
                // the File *interface* yields null and the selection vanishes.
                File f = files.getItem!File(i);
                if (f !is null && f.getPath().length > 0) paths ~= f.getPath();
            }
            if (paths.length > 0) then(paths);
        } catch (Exception e) {
            reportDialogFailure("open-multiple", e);
        }
    });
}

/// Where to save. `initialName` seeds the name entry; `then` gets the path.
void showSaveFileDialog(Window parent, string title, string acceptLabel, string initialFolder,
        string initialName, FileFilter[] filters, void delegate(string path) then) {
    FileDialog dialog = buildFileDialog(title, acceptLabel, initialFolder, filters);
    if (initialName.length > 0) dialog.setInitialName(initialName);
    dialog.save(parent, null, delegate(ObjectWrap source, AsyncResult res) {
        try {
            File chosen = dialog.saveFinish(res);
            if (chosen is null) return;
            string path = chosen.getPath();
            if (path.length > 0) then(path);
        } catch (Exception e) {
            reportDialogFailure("save", e);
        }
    });
}

/// The text/all-files pair used when saving terminal output.
FileFilter[] textFileFilters() {
    FileFilter text = new FileFilter();
    text.addPattern("*.txt");
    text.setName(_("All Text Files"));
    FileFilter all = new FileFilter();
    all.addPattern("*");
    all.setName(_("All Files"));
    return [text, all];
}

/// The JSON/all-files pair used by the session dialogs and the scheme export.
FileFilter[] jsonFileFilters() {
    FileFilter json = new FileFilter();
    json.addPattern("*.json");
    json.setName(_("All JSON Files"));
    FileFilter all = new FileFilter();
    all.addPattern("*");
    all.setName(_("All Files"));
    return [json, all];
}
