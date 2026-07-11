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

import gio.settings : GSettings = Settings;

import gtk.box : Box;
import gtk.check_button : CheckButton;
import gtk.dialog : Dialog;
import gtk.entry : Entry;
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
    scope (exit) {
        dialog.destroy();
    }
    dialog.messageType = mt;
    dialog.text = message;
    dialog.addButton(_("_OK"), ResponseType.Ok);
    dialog.setModal(true);
    dialog.setTransientFor(parent);
    if (title.length > 0)
        dialog.setTitle(title);
    dialog.run();
}

alias OnValidate = bool delegate(string value);

/**
 * Show an input dialog with a single entry for input
 */
bool showInputDialog(Window parent, out string value, string initialValue = "", string title = "", string message = "", OnValidate validate = null) {
    MessageDialog dialog = MessageDialog.builder().build();
    scope (exit) {
        dialog.destroy();
    }
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
    (cast(Box) dialog.getMessageArea()).add(entry);
    entry.showAll();
    dialog.setDefaultResponse(ResponseType.Ok);
    if (dialog.run() == ResponseType.Ok) {
        value = entry.getText();
        return true;
    } else {
        return false;
    }
}

/**
 * Shows a confirmation dialog with the optional ability to include an ignore
 * checkbox tied to gio.Settings so the user no longer has to see the dialog.
 */
bool showConfirmDialog(Window parent, string message, GSettings settings = null, string promptKey = "") {
    if (settings !is null && !settings.getBoolean(promptKey)) return true;

    MessageDialog dialog = MessageDialog.builder().build();
    dialog.messageType = MessageType.Question;
    dialog.text = message;
    dialog.addButton(_("_OK"), ResponseType.Ok);
    dialog.addButton(_("_Cancel"), ResponseType.Cancel);
    dialog.setModal(true);
    dialog.setTransientFor(parent);
    CheckButton cbPrompt = CheckButton.newWithLabel(_("Do not show this again"));
    cbPrompt.setMarginStart(12);
    dialog.getContentArea().add(cbPrompt);
    dialog.setDefaultResponse(ResponseType.Cancel);
    scope (exit) {
        dialog.destroy();
    }
    dialog.showAll();
    bool result = true;
    if (dialog.run() != ResponseType.Ok) {
        result = false;
    }
    settings.setBoolean(promptKey, !cbPrompt.getActive());
    return result;
}
