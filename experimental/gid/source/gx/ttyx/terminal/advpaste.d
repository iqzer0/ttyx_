/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/terminal/advpaste.d. Differences from GtkD:
 *   - GtkD's Dialog(title, parent, flags, buttons[], responses[]) ctor wraps
 *     gtk_dialog_new_with_buttons, which is varargs and not introspectable, so
 *     giD does not bind it. use-header-bar is a construct-only property, so it
 *     cannot be set post-construction either: the dialog is created with a raw
 *     g_object_new(Dialog._getGType(), "use-header-bar", 1, null) passed to
 *     super(ptr, No.Take) — the same floating-ref treatment giD's generated
 *     widget ctors use. Modality, title and the Paste/Cancel buttons are then
 *     set with setModal/setTitle/addButton.
 *   - new TextView(buffer) → TextView.newWithBuffer(buffer);
 *     new SpinButton(min,max,step) → SpinButton.newWithRange;
 *     new CheckButton(label) → CheckButton.newWithLabel;
 *     new ScrolledWindow(view) → new ScrolledWindow() + add(view).
 *   - buffer.getText() (GtkD convenience) → getBounds(start, end) +
 *     getText(start, end, true).
 *   - addOnKeyPress(Event, Widget) + event.getKeyval(out kv) →
 *     connectKeyPressEvent with a typed gdk.event_key.EventKey parameter and
 *     direct .keyval/.state field accessors.
 *   - Enums are PascalCase in <pkg>.types (ResponseType.Apply,
 *     ShadowType.EtchedIn, PolicyType.Automatic, Align.Start,
 *     ModifierType.ControlMask, SettingsBindFlags.Default); keysyms are
 *     module-level gdk.types.KEY_* constants.
 */
module gx.ttyx.terminal.advpaste;

import std.experimental.logger;
import std.format;
import std.string;

import gid.gid : No;

import gdk.event_key : EventKey;
import gdk.types : KEY_Return, ModifierType;

import gio.settings : GSettings = Settings;
import gio.types : SettingsBindFlags;

import gobject.c.functions : g_object_new;

import gtk.box : Box;
import gtk.check_button : CheckButton;
import gtk.dialog : Dialog;
import gtk.label : Label;
import gtk.scrolled_window : ScrolledWindow;
import gtk.spin_button : SpinButton;
import gtk.text_buffer : TextBuffer;
import gtk.text_iter : TextIter;
import gtk.text_tag_table : TextTagTable;
import gtk.text_view : TextView;
import gtk.types : Align, Orientation, PolicyType, ResponseType, ShadowType;
import gtk.window : Window;

import gx.i18n.l10n;

import gx.ttyx.preferences;

string[3] getUnsafePasteMessage() {
    string[3] result = [_("This command is asking for Administrative access to your computer"),
                        _("Copying commands from the internet can be dangerous. "),
                        _("Be sure you understand what each part of this command does.")];

    return result;
}

/**
 * A dialog that is shown to support advance paste. It allows the user
 * to review and edit the content as well as performing various transformations
 * before pasting.
 */
class AdvancedPasteDialog: Dialog {

private:

    GSettings gsSettings;

    TextBuffer buffer;
    CheckButton cbTabsToSpaces;
    SpinButton sbTabWidth;

    CheckButton cbConvertCRLF;

    void createUI(string text, bool unsafe) {
        with (getContentArea()) {
            setMarginLeft(18);
            setMarginRight(18);
            setMarginTop(18);
            setMarginBottom(18);
        }

        Box b = new Box(Orientation.Vertical, 6);
        if (unsafe) {
            string[3] msg = getUnsafePasteMessage();
            Label lblUnsafe = new Label("<span weight='bold' size='large'>" ~ msg[0] ~ "</span>\n" ~ msg[1] ~ "\n" ~ msg[2]);
            lblUnsafe.setUseMarkup(true);
            lblUnsafe.setLineWrap(true);
            b.add(lblUnsafe);
            getWidgetForResponse(ResponseType.Apply).getStyleContext().addClass("destructive-action");
        }

        buffer = new TextBuffer(new TextTagTable());
        buffer.setText(text);
        TextView view = TextView.newWithBuffer(buffer);
        view.connectKeyPressEvent(delegate bool(EventKey event) {
            if (event.keyval == KEY_Return && (event.state & ModifierType.ControlMask)) {
                response(ResponseType.Apply);
                return true;
            }
            return false;
        });
        ScrolledWindow sw = new ScrolledWindow();
        sw.add(view);
        sw.setShadowType(ShadowType.EtchedIn);
        sw.setPolicy(PolicyType.Automatic, PolicyType.Automatic);
        sw.setHexpand(true);
        sw.setVexpand(true);
        sw.setSizeRequest(400, 140);

        b.add(sw);

        Label lblTransform = new Label(format("<b>%s</b>", _("Transform")));
        lblTransform.setUseMarkup(true);
        lblTransform.setHalign(Align.Start);
        lblTransform.setMarginTop(6);
        b.add(lblTransform);

        //Tabs to Spaces
        Box bTabs = new Box(Orientation.Horizontal, 6);
        cbTabsToSpaces = CheckButton.newWithLabel(_("Convert spaces to tabs"));
        gsSettings.bind(SETTINGS_ADVANCED_PASTE_REPLACE_TABS_KEY, cbTabsToSpaces, "active", SettingsBindFlags.Default);
        bTabs.add(cbTabsToSpaces);

        sbTabWidth = SpinButton.newWithRange(0, 32, 1);
        gsSettings.bind(SETTINGS_ADVANCED_PASTE_SPACE_COUNT_KEY, sbTabWidth.getAdjustment(), "value", SettingsBindFlags.Default);
        gsSettings.bind(SETTINGS_ADVANCED_PASTE_REPLACE_TABS_KEY, sbTabWidth, "sensitive", SettingsBindFlags.Default);
        bTabs.add(sbTabWidth);

        b.add(bTabs);

        cbConvertCRLF = CheckButton.newWithLabel(_("Convert CRLF and CR to LF"));
        gsSettings.bind(SETTINGS_ADVANCED_PASTE_REPLACE_CRLF_KEY, cbConvertCRLF, "active", SettingsBindFlags.Default);
        b.add(cbConvertCRLF);

        getContentArea().add(b);
    }

    string transform() {
        TextIter start, end;
        buffer.getBounds(start, end);
        string text = buffer.getText(start, end, true);
        if (gsSettings.getBoolean(SETTINGS_ADVANCED_PASTE_REPLACE_TABS_KEY)) {
            text = text.detab(gsSettings.getInt(SETTINGS_ADVANCED_PASTE_SPACE_COUNT_KEY));
        }
        if (gsSettings.getBoolean(SETTINGS_ADVANCED_PASTE_REPLACE_CRLF_KEY)) {
            text = text.replace("\r\n", "\n");
            text = text.replace("\r", "\n");

        }
        return text;
    }

public:
    this(Window parent, string text, bool unsafe) {
        // gtk_dialog_new_with_buttons is varargs (not bound by giD) and
        // use-header-bar is construct-only, so construct the underlying
        // GtkDialog directly with the property set.
        super(cast(void*) g_object_new(Dialog._getGType(), cast(const(char)*) "use-header-bar", 1, cast(const(char)*) null), No.Take);
        string title = unsafe ? _("Unsafe Paste") : _("Review Paste");
        setTitle(title);
        setModal(true);
        addButton(_("Paste"), ResponseType.Apply);
        addButton(_("Cancel"), ResponseType.Cancel);
        setTransientFor(parent);
        setDefaultResponse(ResponseType.Apply);
        gsSettings = new GSettings(SETTINGS_ID);
        createUI(text, unsafe);
    }

    @property string text() {
        return transform();
    }
}
