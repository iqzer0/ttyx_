/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/terminal/password.d. Differences from GtkD:
 *
 *   VENDORED libsecret → gid:secret1 (the headline change of this port):
 *   - The original used ttyx_'s vendored GtkD-style bindings (import secret.* /
 *     secretc.* from source/secret{,c}/). Those are NOT reused; this port uses
 *     giD's native libsecret binding (dub dependency gid:secret1), whose
 *     secret.* module names shadow the vendored ones by coincidence only.
 *   - Attributes are D associative arrays (string[string]) end to end: no more
 *     glib.HashTable, no immutable(char*) fields kept alive for C async calls,
 *     and item.getAttributes().lookup(ptr) → item.getAttributes() returning
 *     string[string]. The never-read EMPTY_ATTRIBUTES field was dropped.
 *   - Async callbacks are D delegates (gio.types.AsyncReadyCallback) closing
 *     over `this` — the three extern(C) static callbacks + userData =
 *     getDialogStruct() + ObjectG.getDObject round-trip machinery is gone.
 *   - Service.get / Service.getFinish / Collection.forAlias /
 *     Collection.forAliasFinish are bound with the same shapes;
 *     service.disconnect() is a *static* method in giD (Service.disconnect()).
 *   - collection.getItems() returns Item[] directly (no ListG.toArray!Item).
 *   - new Value(pwd, pwd.length, "text/plain") → new SecretValue(pwd,
 *     "text/plain") (length is implicit; secret.value.Value aliased to
 *     SecretValue to avoid clashing with gobject.value.Value).
 *   - giD does NOT wrap three C entry points this module needs; each is a
 *     small local helper over secret.c.functions (see bottom of module):
 *       secret_schema_newv            → newSchema() (giD's Schema boxed class
 *                                       has no constructor at all)
 *       secret_password_storev async  → passwordStoreAsync() (giD only binds
 *                                       the sync variants; helper mirrors the
 *                                       generated freezeDelegate/trampoline
 *                                       pattern so the callback is a D delegate)
 *       secret_password_lookupv_nonpageable_sync
 *                                     → passwordLookupNonpageableSync() (giD
 *                                       only binds the pageable lookup; the
 *                                       original deliberately used the
 *                                       non-pageable one)
 *   - Secret.passwordStoreFinish → free function secret.global
 *     .passwordStoreFinish(AsyncResult); errors are glib.error.ErrorWrap
 *     (was glib.GException).
 *   - Enums: SecretSchemaFlags.NONE → secret.types.SchemaFlags.None,
 *     SecretServiceFlags.OPEN_SESSION → ServiceFlags.OpenSession,
 *     SecretCollectionFlags.LOAD_ITEMS → CollectionFlags.LoadItems.
 *
 *   GTK side (established patterns from advpaste/closedialog/advdialog):
 *   - Dialog(title, parent, flags, buttons[], responses[]) → raw
 *     g_object_new(Dialog._getGType(), "use-header-bar", 1, null) +
 *     super(ptr, No.Take) + setTitle/setModal/setTransientFor/addButton.
 *   - new ListStore([GType.STRING, ...]) → ListStore.new_([cast(GType)
 *     GTypeEnum.String, ...]); createIter() → append(out iter); setValue takes
 *     a gobject.value.Value.
 *   - new TreeViewColumn(title, renderer, "text", col) → no-arg ctor +
 *     setTitle/packStart/addAttribute; new TreeView(model) →
 *     TreeView.newWithModel.
 *   - tv.getSelectedIter()/ls.getValueString() (GtkD conveniences) → local
 *     helpers over getSelection().getSelected(out m, out i) (bool return —
 *     giD out iters are non-null even on false) and getValue + Value.getString.
 *   - addOnSearchChanged/addOnCursorChanged/addOnRowActivated/addOnClicked/
 *     addOnDestroy/addOnChanged → connect* equivalents; addOnKeyPress(Event,
 *     Widget) → connectGdkEvent!EventKey(this, "key-press-event", bool delegate(EventKey)) with direct
 *     .keyval access; keysyms are gdk.types.KEY_* constants.
 *   - new Button(label) → Button.newWithLabel; new CheckButton(label) →
 *     CheckButton.newWithLabel; new ScrolledWindow(tv) → no-arg + add(tv).
 *   - Enums PascalCase in <pkg>.types (ResponseType.Apply/Cancel/Ok,
 *     Orientation.Vertical, ShadowType.EtchedIn, PolicyType.Never/Automatic,
 *     Align.End/Center, SettingsBindFlags.Default).
 */
module gx.ttyx.terminal.password;

import std.algorithm;
import std.array;
import std.conv;
import std.experimental.logger;
import std.string;
import std.uuid;

import gid.gid;

import gdk.event_key : EventKey;
import gdk.types : KEY_Escape, KEY_Return;

import gio.async_result : AsyncResult;
import gio.cancellable : Cancellable;
import gio.settings : GSettings = Settings;
import gio.types : AsyncReadyCallback, SettingsBindFlags;

import glib.c.functions : g_hash_table_insert, g_hash_table_new, g_hash_table_unref, g_str_equal, g_str_hash;
import glib.error : ErrorWrap;

import gobject.c.functions : g_object_new;
import gobject.object : ObjectWrap;
import gobject.types : GType, GTypeEnum;
import gobject.value : Value;

import gtk.box : Box;
import gtk.button : Button;
import gtk.cell_renderer_text : CellRendererText;
import gtk.check_button : CheckButton;
import gtk.dialog : Dialog;
import gtk.editable : Editable;
import gtk.entry : Entry;
import gtk.grid : Grid;
import gtk.label : Label;
import gtk.list_store : ListStore;
import gtk.scrolled_window : ScrolledWindow;
import gtk.search_entry : SearchEntry;
import gtk.tree_iter : TreeIter;
import gtk.tree_model : TreeModel;
import gtk.tree_view : TreeView;
import gtk.tree_view_column : TreeViewColumn;
import gtk.types : Align, Orientation, PolicyType, ResponseType, ShadowType;
import gtk.window : Window;

import secret.c.functions;
import secret.c.types;
import secret.collection : Collection;
import secret.global : passwordStoreFinish;
import secret.item : Item;
import secret.schema : Schema;
import secret.service : Service;
import secret.types : CollectionFlags, SchemaAttributeType, SchemaFlags, ServiceFlags;
import secret.value : SecretValue = Value;

import gx.gtk.dialog: showErrorDialog;
import gx.gtk.util;
import gx.gtk.events;
import gx.i18n.l10n;

import gx.ttyx.preferences;

// Pure helper — isolated from GTK/libsecret so the array mutation is unit-testable.
package string[][] removeRowById(string[][] rows, string id) {
    foreach (i, row; rows) {
        if (row.length >= 2 && row[1] == id) {
            return rows[0 .. i] ~ rows[i + 1 .. $];
        }
    }
    return rows;
}

unittest {
    string[][] rows = [["alice", "id-1"], ["bob", "id-2"], ["carol", "id-3"]];
    assert(removeRowById(rows, "id-2") == [["alice", "id-1"], ["carol", "id-3"]]);
}

unittest {
    string[][] rows = [["alice", "id-1"], ["bob", "id-2"]];
    assert(removeRowById(rows, "id-1") == [["bob", "id-2"]]);
    assert(removeRowById(rows, "id-2") == [["alice", "id-1"]]);
}

unittest {
    string[][] rows = [["only", "id-1"]];
    assert(removeRowById(rows, "id-1") == []);
}

unittest {
    string[][] rows = [["alice", "id-1"]];
    assert(removeRowById(rows, "missing") == rows);
    string[][] empty;
    assert(removeRowById(empty, "id-1") == empty);
}

unittest {
    // Only the first match is removed (guards the contract; UUIDs make duplicates vanishingly unlikely in practice).
    string[][] rows = [["a", "dup"], ["b", "dup"], ["c", "other"]];
    assert(removeRowById(rows, "dup") == [["b", "dup"], ["c", "other"]]);
}

class PasswordManagerDialog: Dialog {

private:

    enum COLUMN_NAME = 0;
    enum COLUMN_ID = 1;

    enum SCHEMA_NAME = "io.github.gwelr.ttyx.Password";
    enum LEGACY_SCHEMA_NAME = "com.gexperts.tilix.Password";

    enum ATTRIBUTE_ID = "id";
    enum ATTRIBUTE_DESCRIPTION = "description";

    enum PENDING_COLLECTION = "collection";
    enum PENDING_SERVICE = "service";

    enum DEFAULT_COLLECTION = "default";

    enum DESCRIPTION_VALUE = "ttyx_ Password";

    SearchEntry se;
    TreeView tv;
    ListStore ls;

    GSettings gsSettings;

    Schema schema;
    // These are populated asynchronously
    Service service;
    Collection collection;

    // Keep a list of pending async operations so we can cancel them
    // if the user closes the app
    Cancellable[string] pending;

    // List of items
    string[][] rows;

    void createUI() {
        with (getContentArea()) {
            setMarginLeft(18);
            setMarginRight(18);
            setMarginTop(18);
            setMarginBottom(18);
        }

        Box b = new Box(Orientation.Vertical, 6);

        se = new SearchEntry();
        se.connectSearchChanged(delegate() {
            filterEntries();
        });
        connectGdkEvent!EventKey(se, "key-press-event", delegate bool(EventKey event) {
            if (event.keyval == KEY_Escape) {
                response(ResponseType.Cancel);
                return true;
            }
            if (event.keyval == KEY_Return) {
                response(ResponseType.Apply);
                return true;
            }
            return false;
        });
        b.add(se);

        Box bList = new Box(Orientation.Horizontal, 6);

        ls = ListStore.new_([cast(GType) GTypeEnum.String, cast(GType) GTypeEnum.String]);

        tv = TreeView.newWithModel(ls);
        tv.setHeadersVisible(false);
        CellRendererText crtName = new CellRendererText();
        TreeViewColumn column = new TreeViewColumn();
        column.setTitle(_("Name"));
        column.packStart(crtName, true);
        column.addAttribute(crtName, "text", COLUMN_NAME);
        column.setMinWidth(300);
        tv.appendColumn(column);
        CellRendererText crtID = new CellRendererText();
        column = new TreeViewColumn();
        column.setTitle(_("ID"));
        column.packStart(crtID, true);
        column.addAttribute(crtID, "text", COLUMN_NAME);
        column.setVisible(false);
        tv.appendColumn(column);

        tv.connectCursorChanged(delegate() {
            updateUI();
        });
        tv.connectRowActivated(delegate() {
            response(ResponseType.Apply);
        });

        ScrolledWindow sw = new ScrolledWindow();
        sw.add(tv);
        sw.setShadowType(ShadowType.EtchedIn);
        sw.setPolicy(PolicyType.Never, PolicyType.Automatic);
        sw.setHexpand(true);
        sw.setVexpand(true);
        sw.setSizeRequest(-1, 200);

        bList.add(sw);

        Box bButtons = new Box(Orientation.Vertical, 6);
        Button btnNew = Button.newWithLabel(_("New"));
        btnNew.connectClicked(delegate() {
            PasswordDialog pd = new PasswordDialog(this);
            scope (exit) {pd.clearSensitiveFields(); pd.destroy();}
            pd.showAll();
            if (pd.run() == ResponseType.Ok) {
                trace("Schema name is " ~ schema.name);
                tracef("Storing password, label=%s",pd.label);
                Cancellable c = new Cancellable();
                //We could potentially have many password operations on the go, use random key
                string uuid = randomUUID().toString();
                pending[uuid] = c;
                string[string] attributes = [ATTRIBUTE_ID: uuid, ATTRIBUTE_DESCRIPTION: DESCRIPTION_VALUE];
                passwordStoreAsync(schema, attributes, DEFAULT_COLLECTION, pd.label, pd.password, c,
                    delegate(ObjectWrap sourceObject, AsyncResult res) {
                        trace("passwordCallback called");
                        try {
                            passwordStoreFinish(res);
                            pending.remove(uuid);
                            trace("Re-loading entries");
                            reload();
                        } catch (ErrorWrap ge) {
                            trace("Error occurred: " ~ ge.msg);
                        }
                    });
            }
        });
        bButtons.add(btnNew);

        Button btnEdit = Button.newWithLabel(_("Edit"));
        btnEdit.connectClicked(delegate() {
            TreeIter selected = getSelectedIter(tv);
            if (selected !is null) {
                string id = getValueString(ls, selected, COLUMN_ID);
                PasswordDialog pd = new PasswordDialog(this, getValueString(ls, selected, COLUMN_NAME), "");
                scope(exit) {pd.clearSensitiveFields(); pd.destroy();}
                pd.showAll();
                if (pd.run() == ResponseType.Ok) {
                    Item[] items = collection.getItems();
                    foreach (item; items) {
                        if (item.getSchemaName() == SCHEMA_NAME || item.getSchemaName() == LEGACY_SCHEMA_NAME) {
                            string itemID = item.getAttributes().get(ATTRIBUTE_ID, null);
                            trace("ItemID " ~ itemID);
                            if (id == itemID) {
                                trace("Modifying item...");
                                item.setLabelSync(pd.label, null);
                                item.setSecretSync(new SecretValue(pd.password, "text/plain"), null);
                                reload();
                                break;
                            }
                        }
                    }
                }
            }
        });
        bButtons.add(btnEdit);

        Button btnDelete = Button.newWithLabel(_("Delete"));
        btnDelete.connectClicked(delegate() {
            TreeIter selected = getSelectedIter(tv);
            if (selected is null || collection is null) return;
            string id = getValueString(ls, selected, COLUMN_ID);

            // Iterate items rather than calling passwordClearvSync(schema,...) so both the current and legacy schemas are handled uniformly.
            bool deleted = false;
            try {
                foreach (item; collection.getItems()) {
                    string schemaName = item.getSchemaName();
                    if (schemaName != SCHEMA_NAME && schemaName != LEGACY_SCHEMA_NAME) continue;
                    string itemID = item.getAttributes().get(ATTRIBUTE_ID, null);
                    if (itemID == id) {
                        if (item.deleteSync(null)) deleted = true;
                        break;
                    }
                }
            } catch (ErrorWrap ge) {
                errorf("Failed to delete password %s: %s", id, ge.msg);
                showErrorDialog(this, _("Failed to delete password: ") ~ ge.msg, _("Delete failed"));
                return;
            }

            if (!deleted) {
                errorf("Password entry %s not removed from keyring", id);
                showErrorDialog(this, _("Password entry could not be deleted from the keyring."), _("Delete failed"));
                return;
            }

            rows = removeRowById(rows, id);
            ls.remove(selected);
        });
        bButtons.add(btnDelete);

        bList.add(bButtons);

        b.add(bList);
        CheckButton cbIncludeEnter = CheckButton.newWithLabel(_("Include return character with password"));
        gsSettings.bind(SETTINGS_PASSWORD_INCLUDE_RETURN_KEY, cbIncludeEnter, "active", SettingsBindFlags.Default);

        b.add(cbIncludeEnter);
        getContentArea().add(b);
    }

    void filterEntries() {
        string selectedID;
        TreeIter selected = getSelectedIter(tv);
        if (selected !is null) selectedID = getValueString(ls, selected, COLUMN_ID);
        selected = null;
        ls.clear();
        foreach(row; rows) {
            if (se.getText().length ==0 || row[0].indexOf(se.getText()) >=0) {
                TreeIter iter;
                ls.append(iter);
                ls.setValue(iter, COLUMN_NAME, new Value(row[0]));
                ls.setValue(iter, COLUMN_ID, new Value(row[1]));
                if (row[1] == selectedID) selected = iter;
            }
        }
        if (selected !is null) tv.getSelection().selectIter(selected);
        else selectRow(tv, 0);
    }

    void loadEntries() {
        Item[] items = collection.getItems();
        rows.length = 0;
        foreach (item; items) {
            if (item.getSchemaName() == SCHEMA_NAME || item.getSchemaName() == LEGACY_SCHEMA_NAME) {
                string id = item.getAttributes().get(ATTRIBUTE_ID, null);
                rows ~= [item.getLabel(), id];
            }
        }
        rows.sort();

        filterEntries();
        updateUI();
    }

    // Reload entries from collections
    void reload() {
        // Have to disconnect otherwise you just get back cached entries
        // (static in giD: disconnects the default service proxy)
        Service.disconnect();
        service = null;
        collection = null;
        createService();
    }

    void createSchema() {
        schema = newSchema(SCHEMA_NAME, SchemaFlags.None,
                           [ATTRIBUTE_ID: SchemaAttributeType.String,
                            ATTRIBUTE_DESCRIPTION: SchemaAttributeType.String]);
    }

    void createService() {
        Cancellable c = new Cancellable();
        pending[PENDING_SERVICE] = c;
        Service.get(ServiceFlags.OpenSession, c, delegate(ObjectWrap sourceObject, AsyncResult res) {
            trace("secretServiceCallback called");
            try {
                Service ss = Service.getFinish(res);
                if (ss !is null) {
                    pending.remove(PENDING_SERVICE);
                    service = ss;
                    createCollection();
                    trace("Retrieved secret service");
                }
            } catch (ErrorWrap ge) {
                trace("Error occurred: " ~ ge.msg);
            }
        });
    }

    void createCollection() {
        Cancellable c = new Cancellable();
        pending[PENDING_COLLECTION] = c;
        Collection.forAlias(service, DEFAULT_COLLECTION, CollectionFlags.LoadItems, c, delegate(ObjectWrap sourceObject, AsyncResult res) {
            trace("collectionCallback called");
            try {
                Collection col = Collection.forAliasFinish(res);
                if (col !is null) {
                    pending.remove(PENDING_COLLECTION);
                    collection = col;
                    loadEntries();
                    trace("Retrieved default collection");
                }
            } catch (ErrorWrap ge) {
                trace("Error occurred: " ~ ge.msg);
            }
        });
    }

    void updateUI() {
        setResponseSensitive(ResponseType.Apply, getSelectedIter(tv) !is null);
    }

public:

    this(Window parent) {
        // gtk_dialog_new_with_buttons is varargs (not bound by giD) and
        // use-header-bar is construct-only, so construct the underlying
        // GtkDialog directly with the property set (see advpaste.d).
        super(cast(void*) g_object_new(Dialog._getGType(), cast(const(char)*) "use-header-bar", 1, cast(const(char)*) null), No.Take);
        setTitle(_("Insert Password"));
        setModal(true);
        setTransientFor(parent);
        addButton(_("Apply"), ResponseType.Apply);
        addButton(_("Cancel"), ResponseType.Cancel);
        gsSettings = new GSettings(SETTINGS_ID);
        setDefaultResponse(ResponseType.Apply);
        connectDestroy(delegate() {
            foreach(c; pending) {
                c.cancel();
            }
        });
        trace("Retrieving secret service");
        createSchema();
        createUI();
        createService();
    }

    @property string password() {
        TreeIter selected = getSelectedIter(tv);
        if (selected !is null) {
            string id = getValueString(ls, selected, COLUMN_ID);
            trace("Getting password for " ~ id);
            // Use the non-pageable lookup so the retrieved secret is stored in
            // memory that libsecret keeps out of swap, rather than in ordinary
            // pageable memory that could be written to disk.
            string password = passwordLookupNonpageableSync(schema, [ATTRIBUTE_ID: id], null);
            if (gsSettings.getBoolean(SETTINGS_PASSWORD_INCLUDE_RETURN_KEY)) {
                password ~= '\n';
            }
            return password;
        } else {
            return null;
        }
    }

}

private:
class PasswordDialog: Dialog {

private:

    Label lblMatch;
    Label lblName;
    Label lblPassword;
    Label lblRepeatPwd;

    Entry eLabel;
    Entry ePassword;
    Entry eConfirmPassword;

    void createUI(string _label, string _password) {

        Grid grid = new Grid();
        grid.setColumnSpacing(12);
        grid.setRowSpacing(6);

        int row = 0;
        // Name (i.e. Label in libsecret parlance)
        lblName = new Label(_("Name"));
        lblName.setHalign(Align.End);
        grid.attach(lblName, 0, row, 1, 1);
        eLabel = new Entry();
        eLabel.setWidthChars(40);
        eLabel.setText(_label);
        grid.attach(eLabel, 1, row, 1, 1);
        row++;

        //Password
        lblPassword = new Label(_("Password"));
        lblPassword.setHalign(Align.End);
        grid.attach(lblPassword, 0, row, 1, 1);
        ePassword = new Entry();
        ePassword.setVisibility(false);
        ePassword.setText(_password);
        grid.attach(ePassword, 1, row, 1, 1);
        row++;

        //Confirm Password
        lblRepeatPwd = new Label(_("Confirm Password"));
        lblRepeatPwd.setHalign(Align.End);
        grid.attach(lblRepeatPwd, 0, row, 1, 1);
        eConfirmPassword = new Entry();
        eConfirmPassword.setVisibility(false);
        eConfirmPassword.setText(_password);
        grid.attach(eConfirmPassword, 1, row, 1, 1);
        row++;

        lblMatch = new Label("Password does not match confirmation");
        lblMatch.setSensitive(false);
        lblMatch.setNoShowAll(true);
        lblMatch.setHalign(Align.Center);
        grid.attach(lblMatch, 1, row, 1, 1);

        with (getContentArea()) {
            setMarginLeft(18);
            setMarginRight(18);
            setMarginTop(18);
            setMarginBottom(18);
            add(grid);
        }
        updateUI();
        eLabel.connectChanged(&entryChanged);
        ePassword.connectChanged(&entryChanged);
        eConfirmPassword.connectChanged(&entryChanged);
    }

    void entryChanged(Editable editable) {
        updateUI();
    }

    void updateUI() {
        setResponseSensitive(ResponseType.Ok, eLabel.getText().length > 0 && ePassword.getText().length > 0 && ePassword.getText() == eConfirmPassword.getText());
        if (ePassword.getText() != eConfirmPassword.getText()) {
            lblMatch.show();
        } else {
            lblMatch.hide();
        }
    }

    this(Window parent, string title) {
        // Raw construct so use-header-bar is set at construct time (advpaste.d pattern).
        super(cast(void*) g_object_new(Dialog._getGType(), cast(const(char)*) "use-header-bar", 1, cast(const(char)*) null), No.Take);
        setTitle(title);
        setModal(true);
        setTransientFor(parent);
        addButton(_("OK"), ResponseType.Ok);
        addButton(_("Cancel"), ResponseType.Cancel);
        setDefaultResponse(ResponseType.Ok);
    }

public:
    this(Window parent) {
        this(parent, _("Add Password"));
        createUI("","");
    }

    this(Window parent, string _label, string _password) {
        this(parent, _("Edit Password"));
        createUI(_label, _password);
    }

    @property string label() {
        return eLabel.getText();
    }

    @property string password() {
        return ePassword.getText();
    }

    // Best-effort — GTK doesn't securely zero EntryBuffer allocations, so overwriting only helps evict plaintext from the current backing store.
    public void clearSensitiveFields() {
        foreach (e; [ePassword, eConfirmPassword]) {
            if (e is null) continue;
            auto len = e.getText().length;
            if (len > 0) e.setText(replicate(" ", len));
            e.setText("");
        }
    }

}

/**
 * GtkD's TreeView.getSelectedIter convenience (unbound in giD). giD's
 * getSelected is an out-param + bool return, and the out iter is non-null
 * even when nothing is selected — the bool is authoritative.
 */
TreeIter getSelectedIter(TreeView tv) {
    TreeModel model;
    TreeIter iter;
    if (tv.getSelection().getSelected(model, iter)) {
        return iter;
    }
    return null;
}

/**
 * GtkD's TreeModel.getValueString convenience (unbound in giD).
 */
string getValueString(TreeModel model, TreeIter iter, int column) {
    Value value;
    model.getValue(iter, column, value);
    return value.getString();
}

/**
 * giD's secret.schema.Schema boxed class has no constructor —
 * secret_schema_new is varargs and secret_schema_newv was not generated.
 * Build the attribute-name → type GHashTable by hand and wrap the result.
 * secret_schema_newv copies the names, so the temporary table is freed here.
 */
Schema newSchema(string name, SchemaFlags flags, SchemaAttributeType[string] attributes) {
    GHashTable* ht = g_hash_table_new(g_str_hash, g_str_equal);
    scope(exit) g_hash_table_unref(ht);
    const(char)*[] keepAlive;
    foreach (attrName, attrType; attributes) {
        const(char)* key = toStringz(attrName);
        keepAlive ~= key;
        g_hash_table_insert(ht, cast(void*) key, cast(void*) attrType);
    }
    SecretSchema* ss = secret_schema_newv(toStringz(name), cast(SecretSchemaFlags) flags, ht);
    return new Schema(cast(void*) ss, Yes.Take);
}

/**
 * giD's secret.global binds only the synchronous variants of
 * secret_password_storev; this mirrors giD's generated async pattern
 * (extern(C) trampoline + freezeDelegate GC rooting) around the raw C call so
 * callers get a plain D delegate. libsecret converts the attribute table
 * before going async, so freeing it on scope exit is safe (same as giD's own
 * generated code for e.g. Item.create).
 */
void passwordStoreAsync(Schema schema, string[string] attributes, string collection, string label,
                        string password, Cancellable cancellable, AsyncReadyCallback callback) {
    extern(C) void _callbackCallback(GObject* sourceObject, GAsyncResult* res, void* data) nothrow {
        ptrThawGC(data);
        auto _dlg = cast(AsyncReadyCallback*) data;
        try {
            (*_dlg)(ObjectWrap._getDObject!(ObjectWrap)(cast(void*) sourceObject, No.Take),
                    ObjectWrap._getDObject!(AsyncResult)(cast(void*) res, No.Take));
        } catch (Exception e) {
            gidInvokeCallbackExceptionHandler(e, "gio.types.AsyncReadyCallback");
        }
    }
    auto _callbackCB = callback ? &_callbackCallback : null;
    auto _attributes = gHashTableFromD!(string, string)(attributes);
    scope(exit) containerFree!(GHashTable*, string, GidOwnership.None)(_attributes);
    const(char)* _collection = collection.toCString!(No.Malloc, Yes.Nullable);
    const(char)* _label = label.toCString!(No.Malloc, No.Nullable);
    const(char)* _password = password.toCString!(No.Malloc, No.Nullable);
    auto _callback = callback ? freezeDelegate(cast(void*) &callback) : null;
    secret_password_storev(schema ? cast(const(SecretSchema)*) schema._cPtr(No.Dup) : null, _attributes,
                           _collection, _label, _password,
                           cancellable ? cast(GCancellable*) cancellable._cPtr(No.Dup) : null,
                           _callbackCB, _callback);
}

/**
 * giD's secret.global binds only the pageable secret_password_lookupv_sync;
 * the original deliberately used the non-pageable variant so libsecret keeps
 * the retrieved secret out of swap. Raw C call with the same D-facing shape
 * as secret.global.passwordLookupSync. The non-pageable C buffer is copied to
 * a D string (as GtkD's wrapper also did) and released with
 * secret_password_free.
 * Throws: ErrorWrap
 */
string passwordLookupNonpageableSync(Schema schema, string[string] attributes, Cancellable cancellable = null) {
    auto _attributes = gHashTableFromD!(string, string)(attributes);
    scope(exit) containerFree!(GHashTable*, string, GidOwnership.None)(_attributes);
    GError* _err;
    char* _cretval = secret_password_lookupv_nonpageable_sync(
        schema ? cast(const(SecretSchema)*) schema._cPtr(No.Dup) : null, _attributes,
        cancellable ? cast(GCancellable*) cancellable._cPtr(No.Dup) : null, &_err);
    if (_err)
        throw new ErrorWrap(_err);
    if (_cretval is null)
        return null;
    string result = fromCString!(No.Free)(_cretval);
    secret_password_free(_cretval);
    return result;
}
