/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/bookmark/bmchooser.d. GtkD -> giD:
 *  - Dialog(title, parent, flags, buttons[], responses[]) wraps the varargs
 *    gtk_dialog_new_with_buttons, which giD does not bind, and use-header-bar
 *    is construct-only: constructed via raw
 *    g_object_new(Dialog._getGType(), "use-header-bar", 1, null) passed to
 *    super(ptr, No.Take), then setTitle/setModal/setTransientFor/addButton
 *    (the advpaste.d / closedialog.d pattern). GtkDialogFlags.MODAL ->
 *    setModal(true).
 *  - addOnKeyPress(Event, Widget) + event.getKeyval(out kv) ->
 *    connectKeyPressEvent(bool delegate(EventKey)) with direct .keyval field
 *    access; keysyms are module-level gdk.types.KEY_* constants
 *    (GdkKeysyms.GDK_Escape -> KEY_Escape).
 *  - addOnCursorChanged/addOnRowActivated/addOnSearchChanged ->
 *    connectCursorChanged/connectRowActivated/connectSearchChanged with
 *    zero-parameter delegate literals (giD accepts arity-reduced callbacks;
 *    avoids the name-every-param pitfall).
 *  - new ScrolledWindow(tv) -> new ScrolledWindow() + add(tv);
 *    new CheckButton(label) -> CheckButton.newWithLabel(label).
 *  - GSettingsBindFlags.DEFAULT -> gio.types.SettingsBindFlags.Default.
 *  - `response = ResponseType.X` (GtkD property-call sugar) -> response(X).
 *  - Enums PascalCase in gtk.types: SelectionMode.Browse, ShadowType.EtchedIn,
 *    PolicyType.Never/Automatic, Orientation.Vertical, ResponseType.Ok/Cancel.
 * Behavior is unchanged.
 */
module gx.ttyx.bookmark.bmchooser;

import gid.gid : No;

import gdk.event_key : EventKey;
import gdk.types : KEY_Escape, KEY_Return;

import gio.settings : GSettings = Settings;
import gio.types : SettingsBindFlags;

import gobject.c.functions : g_object_new;

import gtk.box : Box;
import gtk.check_button : CheckButton;
import gtk.dialog : Dialog;
import gtk.scrolled_window : ScrolledWindow;
import gtk.search_entry : SearchEntry;
import gtk.types : Orientation, PolicyType, ResponseType, SelectionMode, ShadowType;
import gtk.window : Window;

import gx.gtk.util;

import gx.i18n.l10n;

import gx.ttyx.bookmark.bmtreeview;
import gx.ttyx.bookmark.manager;
import gx.ttyx.preferences;

/**
 * Selection mode dialog should used
 */
enum BMSelectionMode {ANY, LEAF, FOLDER}

/**
 * Dialog that allows the user to select a bookmark. Not actually used
 * at the moment as the GTK TreeModelFilter is too limited when dealing with
 * heirarchal data.
 */
class BookmarkChooser: Dialog {
private:
    BMTreeView tv;
    BMSelectionMode mode;

    GSettings gsSettings;

    void createUI() {
        tv = new BMTreeView(true, mode == BMSelectionMode.FOLDER);
        tv.setActivateOnSingleClick(false);
        tv.setHeadersVisible(false);
        tv.getSelection().setMode(SelectionMode.Browse);
        tv.connectCursorChanged(() {
            updateUI();
        });
        tv.connectRowActivated(() {
            response(ResponseType.Ok);
        });
        tv.connectKeyPressEvent(&checkKeyPress);

        ScrolledWindow sw = new ScrolledWindow();
        sw.add(tv);
        sw.setShadowType(ShadowType.EtchedIn);
        sw.setPolicy(PolicyType.Never, PolicyType.Automatic);
        sw.setHexpand(true);
        sw.setVexpand(true);
        sw.setSizeRequest(-1, 200);

        SearchEntry se = new SearchEntry();
        se.connectSearchChanged(() {
            tv.filterText = se.getText();
            updateUI();
        });
        se.connectKeyPressEvent(&checkKeyPress);

        Box box = new Box(Orientation.Vertical, 6);
        setAllMargins(box, 18);
        box.add(se);
        box.add(sw);

        if (mode != BMSelectionMode.FOLDER) {
            gsSettings = new GSettings(SETTINGS_ID);
            CheckButton cbIncludeEnter = CheckButton.newWithLabel(_("Include return character with bookmark"));
            gsSettings.bind(SETTINGS_BOOKMARK_INCLUDE_RETURN_KEY, cbIncludeEnter, "active", SettingsBindFlags.Default);
            box.add(cbIncludeEnter);
        }

        getContentArea().add(box);
    }

    void updateUI() {
        setResponseSensitive(ResponseType.Ok, isSelectEnabled());
    }

    bool isSelectEnabled() {
        Bookmark bm = tv.getSelectedBookmark();
        bool enabled = bm !is null;
        switch (mode) {
            case BMSelectionMode.FOLDER:
                enabled = enabled && (cast(FolderBookmark)bm !is null);
                break;
            case BMSelectionMode.LEAF:
                enabled = enabled && (cast(FolderBookmark)bm is null);
                break;
            default:
                break;
        }
        return enabled;
    }

    bool checkKeyPress(EventKey event) {
        if (event.keyval == KEY_Escape) {
            response(ResponseType.Cancel);
            return true;
        }
        if (event.keyval == KEY_Return) {
            if (isSelectEnabled()) {
                response(ResponseType.Ok);
                return true;
            }
        }
        return false;
    }

public:
    this(Window parent, BMSelectionMode mode) {
        // gtk_dialog_new_with_buttons is varargs (not bound by giD) and
        // use-header-bar is construct-only, so construct the underlying
        // GtkDialog directly with the property set (see advpaste.d).
        super(cast(void*) g_object_new(Dialog._getGType(), cast(const(char)*) "use-header-bar", 1, cast(const(char)*) null), No.Take);
        string title = mode == BMSelectionMode.FOLDER? _("Select Folder"):_("Select Bookmark");
        setTitle(title);
        setModal(true);
        setTransientFor(parent);
        addButton(_("OK"), ResponseType.Ok);
        addButton(_("Cancel"), ResponseType.Cancel);
        setDefaultResponse(ResponseType.Ok);
        this.mode = mode;
        createUI();
        updateUI();
    }

    @property Bookmark bookmark() {
        return tv.getSelectedBookmark();
    }
}
