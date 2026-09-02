/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/closedialog.d. Differences from GtkD:
 *   - Dialog(title, parent, flags, buttons[], responses[]) wraps the varargs
 *     gtk_dialog_new_with_buttons, which giD does not bind, and use-header-bar
 *     is construct-only: the dialog is created via raw
 *     g_object_new(Dialog._getGType(), "use-header-bar", 1, null) passed to
 *     super(ptr, No.Take), then setTitle/setModal/setTransientFor/addButton
 *     (the advpaste.d pattern).
 *   - IconInfo.loadIcon() throws glib.error.ErrorWrap instead of returning
 *     null on failure — wrapped in try/catch so a missing/broken icon still
 *     only logs a warning like the original.
 *   - new TreeStore(GType[]) → TreeStore.new_(GType[]); createIter(parent) →
 *     append(out iter, parent); setValue takes a gobject.value.Value (its
 *     templated ctor covers strings and Pixbuf); Pixbuf.getType() →
 *     Pixbuf._getGType(); GType.STRING → cast(GType) GTypeEnum.String.
 *   - new TreeView(model) → TreeView.newWithModel(model);
 *     new TreeViewColumn(title, renderer, attr, col) → new TreeViewColumn() +
 *     setTitle + packStart + addAttribute.
 *   - crt.setProperty("ellipsize", new Value(...)) / crp.setProperty(
 *     "stock-size", 16) → giD's generated typed property setters
 *     (crt.ellipsize = EllipsizeMode.End; crp.stockSize = 16) — giD's
 *     Value-from-enum init uses abstract G_TYPE_ENUM, so the typed setters
 *     are the reliable route for enum-typed properties.
 *   - addOnKeyRelease(Event, Widget) + event.getKeyval(out kv) →
 *     connectGdkEvent!EventKey(this, "key-release-event", bool delegate(EventKey)) with direct .keyval
 *     field access; keysyms are module-level gdk.types.KEY_* constants.
 *   - new ScrolledWindow(tv) → new ScrolledWindow() + add(tv);
 *     new CheckButton(label) → CheckButton.newWithLabel(label).
 *   - Enums are PascalCase in <pkg>.types (ResponseType.Ok, Align.Start,
 *     Orientation.Vertical, ShadowType.EtchedIn, PolicyType.Never/Automatic,
 *     IconLookupFlags).
 */
module gx.ttyx.closedialog;

import std.experimental.logger;
import std.format;

import gid.gid : No;


import gdk.types : KEY_Escape, KEY_Return, ModifierType;

import gtk.event_controller_key : EventControllerKey;

import gio.settings : GSettings = Settings;

import glib.error : ErrorWrap;

import gobject.c.functions : g_object_new;
import gobject.types : GType, GTypeEnum;
import gobject.value : Value;

import gtk.box : Box;
import gtk.cell_renderer_pixbuf : CellRendererPixbuf;
import gtk.cell_renderer_text : CellRendererText;
import gtk.check_button : CheckButton;
import gtk.dialog : Dialog;
import gtk.label : Label;
import gtk.scrolled_window : ScrolledWindow;
import gtk.tree_iter : TreeIter;
import gtk.tree_store : TreeStore;
import gtk.tree_view : TreeView;
import gtk.tree_view_column : TreeViewColumn;
import gtk.types : Align, Orientation, PolicyType, ResponseType;
import gtk.window : Window;

import pango.types : EllipsizeMode;

import gx.i18n.l10n;
import gx.gtk.util;

import gx.ttyx.common;
import gx.ttyx.preferences;

public:

/**
 * Prompts the user to confirm that processes can be closed
 */
void promptCanCloseProcesses(GSettings gsSettings, Window window, ProcessInformation pi, void delegate(bool canClose) then) {
    if (!gsSettings.getBoolean(SETTINGS_PROMPT_ON_CLOSE_PROCESS_KEY)) { then(true); return; }

    // GTK4: no Dialog.run(); the answer goes through the continuation, which
    // is invoked synchronously when no prompt is needed.
    CloseDialog dialog = new CloseDialog(window, pi);
    dialog.connectResponse(delegate(int result, Dialog d) {
        if (result == ResponseType.Ok && dialog.futureIgnore) {
            gsSettings.setBoolean(SETTINGS_PROMPT_ON_CLOSE_PROCESS_KEY, false);
        }

        // Weird looking code, exists because of the way hotkeys get interpreted into results, it's
        // easier to check if the result is not OK
        bool cancelClose = (result != ResponseType.Ok);
        dialog.destroy();
        then(!cancelClose);
    });
    dialog.present();
}

private:

/**
 * Dialog that is used to close object when running processes are detected
 */
class CloseDialog: Dialog {

private:
    enum MAX_DESCRIPTION = 120;

    ProcessInformation processes;

    TreeStore ts;
    TreeView tv;
    CheckButton cbIgnore;

    // GTK4: the ICON column holds an icon *name*, not a loaded Pixbuf.
    // GtkIconTheme.lookupIcon now returns a GtkIconPaintable with no
    // loadIcon() — GTK4 icons are not Pixbufs — while CellRendererPixbuf has
    // always been able to render straight from a theme name via its
    // "icon-name" property. Letting the renderer do the lookup deletes the
    // manual theme handling, both error paths and the hardcoded 16px size.
    enum ICON_TERMINAL = "utilities-terminal";

    void createUI() {
        setAllMargins(getContentArea(), 18);
        Box box = new Box(Orientation.Vertical, 6);

        Label lbl = new Label("There are processes still running as shown below, close anyway?");
        lbl.setHalign(Align.Start);
        lbl.setMarginBottom(6);
        box.append(lbl);

        ts = TreeStore.new_([cast(GType) GTypeEnum.String, cast(GType) GTypeEnum.String, cast(GType) GTypeEnum.String]);
        loadProcesses();

        tv = TreeView.newWithModel(ts);
        addTreeViewNavigation(tv);
        // GTK4: key-release-event -> EventControllerKey's key-released, whose
        // callback returns void. The GTK3 handler returned false throughout,
        // so nothing is lost.
        EventControllerKey keyController = new EventControllerKey();
        keyController.connectKeyReleased(
            delegate void(uint keyval, uint keycode, ModifierType state, EventControllerKey c) {
                switch (keyval) {
                    case KEY_Escape:
                        response(ResponseType.Cancel);
                        break;
                    case KEY_Return:
                        response(ResponseType.Ok);
                        break;
                    default:
                }
            });
        tv.addController(keyController);
        tv.setHeadersVisible(false);

        CellRendererText crt = new CellRendererText();
        crt.ellipsize = EllipsizeMode.End;

        TreeViewColumn column = new TreeViewColumn();
        column.setTitle(_("Title"));
        column.packStart(crt, true);
        column.addAttribute(crt, "text", COLUMNS.NAME);
        column.setExpand(true);
        tv.appendColumn(column);

        CellRendererPixbuf crp = new CellRendererPixbuf();
        // GTK4 dropped CellRendererPixbuf's stock-size property; an icon-name
        // renders at its natural themed size.
        column = new TreeViewColumn();
        column.setTitle(_("Icon"));
        column.packStart(crp, true);
        column.addAttribute(crp, "icon-name", COLUMNS.ICON);
        column.setExpand(true);
        tv.appendColumn(column);

        ScrolledWindow sw = new ScrolledWindow();
        sw.setChild(tv);
        // GTK4: GtkShadowType is gone; the border is a boolean frame.
        sw.setHasFrame(true);
        sw.setPolicy(PolicyType.Never, PolicyType.Automatic);
        sw.setHexpand(true);
        sw.setVexpand(true);
        sw.setSizeRequest(-1, 300);

        box.append(sw);
        tv.expandAll();

        cbIgnore = CheckButton.newWithLabel(_("Do not show this again"));
        box.append(cbIgnore);

        getContentArea().append(box);
    }

    /**
     * Load list of processes into treeview, never show Application
     * as root, just windows.
     */
    void loadProcesses() {
        if (processes.source == ProcessInfoSource.APPLICATION) {
            foreach(child; processes.children) {
                loadProcess(null, child);
            }
        } else {
            loadProcess(null, processes);
        }
    }

    void loadProcess(TreeIter parent, ProcessInformation pi) {
        TreeIter current;
        ts.append(current, parent);
        if (pi.source == ProcessInfoSource.TERMINAL) {
            ts.setValue(current, COLUMNS.ICON, new Value(ICON_TERMINAL));
        }
        switch (pi.source) {
            case ProcessInfoSource.WINDOW:
                ts.setValue(current, COLUMNS.NAME, new Value(format(_("Window (%s)"), pi.description)));
                break;
            case ProcessInfoSource.SESSION:
                ts.setValue(current, COLUMNS.NAME, new Value(format(_("Session (%s)"), pi.description)));
                break;
            default:
                ts.setValue(current, COLUMNS.NAME, new Value(pi.description));
                break;
        }
        ts.setValue(current, COLUMNS.UUID, new Value(pi.uuid));

        foreach(child; pi.children) {
            loadProcess(current, child);
        }
    }

    static string getTitle(ProcessInfoSource source) {
        final switch (source) {
            case ProcessInfoSource.APPLICATION:
                return _("Close Application");
            case ProcessInfoSource.WINDOW:
                return _("Close Window");
            case ProcessInfoSource.SESSION:
                return _("Close Session");
            case ProcessInfoSource.TERMINAL:
                return _("Close Session");
        }
    }

public:

    this(Window parent, ProcessInformation processes) {
        // gtk_dialog_new_with_buttons is varargs (not bound by giD) and
        // use-header-bar is construct-only, so construct the underlying
        // GtkDialog directly with the property set (see advpaste.d).
        super(cast(void*) g_object_new(Dialog._getGType(), cast(const(char)*) "use-header-bar", 1, cast(const(char)*) null), No.Take);
        setTitle(getTitle(processes.source));
        setModal(true);
        setTransientFor(parent);
        addButton(_("OK"), ResponseType.Ok);
        addButton(_("Cancel"), ResponseType.Cancel);
        this.processes = processes;
        setDefaultResponse(ResponseType.Ok);
        createUI();
    }

    @property bool futureIgnore() {
        return cbIgnore.getActive();
    }

}

private:
    enum COLUMNS : uint {
        NAME = 0,
        ICON = 1,
        UUID = 2
    }
