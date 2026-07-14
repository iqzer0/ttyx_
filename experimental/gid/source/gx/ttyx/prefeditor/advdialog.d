/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/prefeditor/advdialog.d. Differences from GtkD:
 *   - Dialog subclass follows the advpaste.d pattern: giD binds no
 *     gtk_dialog_new_with_buttons and use-header-bar is construct-only, so the
 *     dialog is created with a raw g_object_new(Dialog._getGType(),
 *     "use-header-bar", 1, null) passed to super(ptr, No.Take), then
 *     setTitle/setModal/addButton/setTransientFor.
 *   - new TreeViewColumn(title, renderer, attr, col) (GtkD wraps the varargs
 *     gtk_tree_view_column_new_with_attributes, not introspectable) →
 *     createColumn helper: new TreeViewColumn() + setTitle + packStart(r, true)
 *     + addAttribute.
 *   - ls.createIter() → TreeIter iter; ls.append(iter) (iter is an out param);
 *     setValue takes a gobject.value.Value; ls.getValueString → getValue(iter,
 *     col, out Value) + Value.getString (local helpers below).
 *   - tv.getSelectedIter() (GtkD convenience) → getSelection().getSelected(out
 *     model, out iter) wrapped in a local helper that returns null when nothing
 *     is selected (giD TreeIter is a boxed class, still nullable).
 *   - iter.getTreePath() → model.getPath(iter); iter.copy(iter) → iter.copy();
 *     new TreePath(path) → TreePath.newFromString(path).
 *   - Cell renderers: setProperty("editable", 1) → typed property
 *     crt.editable = true; CellRendererCombo's raw g_object_set of
 *     "model"/"has-entry"/"text-column" → typed properties model/hasEntry/
 *     textColumn; addOnEdited/addOnToggled/addOnChanged → connectEdited/
 *     connectToggled/connectChanged (same path-string + iter shapes).
 *   - new Button(icon, IconSize.BUTTON) → Button.newFromIconName;
 *     new Button(label) → Button.newWithLabel; new CheckButton(label) →
 *     CheckButton.newWithLabel; new SpinButton(min,max,step) →
 *     SpinButton.newWithRange; new ScrolledWindow(child) →
 *     new ScrolledWindow() + add(child); new TreeView(model) →
 *     TreeView.newWithModel.
 *   - GType.STRING/BOOLEAN → cast(GType) GTypeEnum.String/.Boolean;
 *     enums are PascalCase in <pkg>.types; OR-ing SettingsBindFlags needs a
 *     cast back to the enum type.
 *   - glib.GException → glib.regex.RegexException (subclass of ErrorWrap);
 *     new GRegex(pattern, flags, matchFlags) ctor shape is unchanged.
 */
module gx.ttyx.prefeditor.advdialog;

import std.conv;
import std.csv;
import std.experimental.logger;
import std.format;
import std.typecons : No, Tuple;

import gio.settings : GSettings = Settings;
import gio.types : SettingsBindFlags;

import glib.regex : GRegex = Regex, RegexException;
import glib.types : RegexCompileFlags, RegexMatchFlags;

import gobject.c.functions : g_object_new;
import gobject.types : GType, GTypeEnum;
import gobject.value : Value;

import gtk.box : Box;
import gtk.button : Button;
import gtk.cell_renderer : CellRenderer;
import gtk.cell_renderer_combo : CellRendererCombo;
import gtk.cell_renderer_text : CellRendererText;
import gtk.cell_renderer_toggle : CellRendererToggle;
import gtk.check_button : CheckButton;
import gtk.dialog : Dialog;
import gtk.label : Label;
import gtk.list_store : ListStore;
import gtk.scrolled_window : ScrolledWindow;
import gtk.spin_button : SpinButton;
import gtk.tree_iter : TreeIter;
import gtk.tree_model : TreeModel;
import gtk.tree_path : TreePath;
import gtk.tree_view : TreeView;
import gtk.tree_view_column : TreeViewColumn;
import gtk.types : Align, IconSize, Orientation, PolicyType, ResponseType, ShadowType;
import gtk.window : Window;

import gx.i18n.l10n;
import gx.gtk.util;
import gx.util.string;

import gx.ttyx.preferences;

/**
 * Dialog for editing custom hyperlinks
 */
class EditCustomLinksDialog: Dialog {

private:
    enum COLUMN_REGEX = 0;
    enum COLUMN_CMD = 1;
    enum COLUMN_CASE = 2;

    TreeView tv;
    ListStore ls;
    Button btnDelete;
    Button btnMoveUp;
    Button btnMoveDown;

    Label lblErrors;

    void createUI(string[] links) {

        setAllMargins(getContentArea(), 18);
        getContentArea().add(createSecurityWarningLabel(
            _("Warning: clicked links execute shell commands with captured text "
            ~ "substituted in. Under SSH or any remote session that text is "
            ~ "attacker-controlled — review templates for unquoted match-group "
            ~ "substitutions and only configure custom links for hosts you trust.")));
        Box box = new Box(Orientation.Vertical, 6);

        ls = ListStore.new_([cast(GType) GTypeEnum.String, cast(GType) GTypeEnum.String, cast(GType) GTypeEnum.Boolean]);
        foreach(link; links) {
            foreach(value; csvReader!(Tuple!(string, string, string))(link)) {
                TreeIter iter;
                ls.append(iter);
                ls.setValue(iter, COLUMN_REGEX, new Value(value[0]));
                ls.setValue(iter, COLUMN_CMD, new Value(value[1]));
                try {
                    ls.setValue(iter, COLUMN_CASE, new Value(to!bool(value[2])));
                } catch (Exception e) {
                    ls.setValue(iter, COLUMN_CASE, new Value(false));
                }
            }
        }

        tv = TreeView.newWithModel(ls);
        tv.setActivateOnSingleClick(false);
        tv.connectCursorChanged(delegate() {
            updateUI();
        });
        tv.setHeadersVisible(true);

        //Regex column
        CellRendererText crtRegex = new CellRendererText();
        crtRegex.editable = true;
        crtRegex.connectEdited(delegate(string path, string newText) {
            TreeIter iter;
            if (ls.getIter(iter, TreePath.newFromString(path))) {
                ls.setValue(iter, COLUMN_REGEX, new Value(newText));
            }
            updateUI();
        });
        TreeViewColumn column = createColumn(_("Regex"), crtRegex, "text", COLUMN_REGEX);
        column.setMinWidth(200);
        tv.appendColumn(column);

        //Command column
        CellRendererText crtCommand = new CellRendererText();
        crtCommand.editable = true;
        crtCommand.connectEdited(delegate(string path, string newText) {
            TreeIter iter;
            if (ls.getIter(iter, TreePath.newFromString(path))) {
                ls.setValue(iter, COLUMN_CMD, new Value(newText));
            }
        });
        column = createColumn(_("Command"), crtCommand, "text", COLUMN_CMD);
        column.setMinWidth(200);
        tv.appendColumn(column);

        //Case Insensitive Column
        CellRendererToggle crtCase = new CellRendererToggle();
        crtCase.setActivatable(true);
        crtCase.connectToggled(delegate(string path, CellRendererToggle crt) {
            TreeIter iter;
            if (ls.getIter(iter, TreePath.newFromString(path))) {
                ls.setValue(iter, COLUMN_CASE, new Value(!crt.getActive()));
            }
        });
        column = createColumn(_("Case Insensitive"), crtCase, "active", COLUMN_CASE);
        tv.appendColumn(column);

        ScrolledWindow sc = new ScrolledWindow();
        sc.add(tv);
        sc.setShadowType(ShadowType.EtchedIn);
        sc.setPolicy(PolicyType.Never, PolicyType.Automatic);
        sc.setHexpand(true);
        sc.setVexpand(true);
        sc.setSizeRequest(-1, 250);

        box.add(sc);

        Box buttons = new Box(Orientation.Horizontal, 0);
        buttons.getStyleContext().addClass("linked");

        Button btnAdd = Button.newFromIconName("list-add-symbolic", IconSize.Button);
        btnAdd.setTooltipText(_("Add"));
        btnAdd.connectClicked(delegate() {
            TreeIter iter;
            ls.append(iter);
            selectRow(tv, ls.iterNChildren(null) - 1, null);
        });
        buttons.add(btnAdd);
        btnDelete = Button.newFromIconName("list-remove-symbolic", IconSize.Button);
        btnDelete.setTooltipText(_("Delete"));
        btnDelete.connectClicked(delegate() {
            TreeIter selected = getSelectedIter(tv);
            if (selected !is null) {
                ls.remove(selected);
            }
        });
        buttons.add(btnDelete);

        btnMoveUp = Button.newFromIconName("pan-up-symbolic", IconSize.Button);
        btnMoveUp.setTooltipText(_("Move up"));
        btnMoveUp.connectClicked(delegate() {
            TreeIter selected = getSelectedIter(tv);
            if (selected !is null) {
                TreeIter previous = selected.copy();
                if (ls.iterPrevious(previous)) ls.swap(selected, previous);
            }
        });
        buttons.add(btnMoveUp);

        btnMoveDown = Button.newFromIconName("pan-down-symbolic", IconSize.Button);
        btnMoveDown.setTooltipText(_("Move down"));
        btnMoveDown.connectClicked(delegate() {
            TreeIter selected = getSelectedIter(tv);
            if (selected !is null) {
                TreeIter next = selected.copy();
                if (ls.iterNext(next)) ls.swap(selected, next);
            }
        });
        buttons.add(btnMoveDown);

        box.add(buttons);

        getContentArea().add(box);

        lblErrors = createErrorLabel();
        getContentArea().add(lblErrors);

        updateUI();
    }

    void updateUI() {
        TreeIter selected = getSelectedIter(tv);
        btnDelete.setSensitive(selected !is null);
        btnMoveUp.setSensitive(selected !is null && ls.getPath(selected).getIndices()[0] > 0);
        btnMoveDown.setSensitive(selected !is null && ls.getPath(selected).getIndices()[0] < ls.iterNChildren(null) - 1);
        setResponseSensitive(ResponseType.Apply, validateRegex(ls, COLUMN_REGEX, lblErrors));
    }

public:
    this(Window parent, string[] links) {
        // gtk_dialog_new_with_buttons is varargs (not bound by giD) and
        // use-header-bar is construct-only, so construct the underlying
        // GtkDialog directly with the property set (see advpaste.d).
        super(cast(void*) g_object_new(Dialog._getGType(), cast(const(char)*) "use-header-bar", 1, cast(const(char)*) null), No.Take);
        setTitle(_("Edit Custom Links"));
        setModal(true);
        addButton(_("Apply"), ResponseType.Apply);
        addButton(_("Cancel"), ResponseType.Cancel);
        setTransientFor(parent);
        setDefaultResponse(ResponseType.Apply);
        createUI(links);
    }

    string[] getLinks() {
        string[] results;
        foreach (TreeIter iter; TreeIterRange(ls)) {
            string regex = getValueString(ls, iter, COLUMN_REGEX);
            if (regex.length == 0) continue;
            Value caseValue;
            ls.getValue(iter, COLUMN_CASE, caseValue);
            results ~= escapeCSV(regex) ~ ',' ~
                       escapeCSV(getValueString(ls, iter, COLUMN_CMD)) ~ ',' ~
                       to!string(caseValue.getBoolean());
        }
        return results;
    }
}

/**
 * Dialog for editing triggers
 */
class EditTriggersDialog: Dialog {

private:
    enum COLUMN_REGEX = 0;
    enum COLUMN_ACTION = 1;
    enum COLUMN_PARAMETERS = 2;

    TreeView tv;
    ListStore ls;
    ListStore lsActions;
    Button btnDelete;

    Label lblErrors;

    string[string] localizedActions;

    void createUI(GSettings gs, bool showLineSettings) {

        string[] triggers = gs.getStrv(SETTINGS_ALL_TRIGGERS_KEY);

        setAllMargins(getContentArea(), 18);
        getContentArea().add(createSecurityWarningLabel(
            _("Warning: ExecuteCommand and RunProcess actions run shell commands "
            ~ "with captured groups substituted in. Under SSH or any remote session "
            ~ "terminal output is attacker-controlled — only configure these actions "
            ~ "for hosts you trust.")));
        Box box = new Box(Orientation.Horizontal, 6);

        ls = ListStore.new_([cast(GType) GTypeEnum.String, cast(GType) GTypeEnum.String, cast(GType) GTypeEnum.String]);
        foreach(trigger; triggers) {
            foreach(value; csvReader!(Tuple!(string, string, string))(trigger)) {
                TreeIter iter;
                ls.append(iter);
                ls.setValue(iter, COLUMN_REGEX, new Value(value[0]));
                ls.setValue(iter, COLUMN_ACTION, new Value(_(value[1])));
                ls.setValue(iter, COLUMN_PARAMETERS, new Value(value[2]));
            }
        }

        tv = TreeView.newWithModel(ls);
        tv.setActivateOnSingleClick(false);
        tv.connectCursorChanged(delegate() {
            updateUI();
        });
        tv.setHeadersVisible(true);
        //Regex column
        CellRendererText crtRegex = new CellRendererText();
        crtRegex.editable = true;
        crtRegex.connectEdited(delegate(string path, string newText) {
            TreeIter iter;
            if (ls.getIter(iter, TreePath.newFromString(path))) {
                ls.setValue(iter, COLUMN_REGEX, new Value(newText));
            }
            updateUI();
        });
        TreeViewColumn column = createColumn(_("Regex"), crtRegex, "text", COLUMN_REGEX);
        column.setMinWidth(200);
        tv.appendColumn(column);

        //Action Column
        CellRendererCombo crtAction = new CellRendererCombo();
        lsActions = ListStore.new_([cast(GType) GTypeEnum.String]);
        foreach(value; SETTINGS_PROFILE_TRIGGER_ACTION_VALUES) {
            TreeIter iter;
            lsActions.append(iter);
            lsActions.setValue(iter, 0, new Value(_(value)));
            localizedActions[_(value)] = value;
        }
        // GtkD needed a raw g_object_set for "model"; giD generates typed
        // property accessors for CellRendererCombo.
        crtAction.model = lsActions;
        crtAction.editable = true;
        crtAction.hasEntry = false;
        crtAction.textColumn = 0;
        crtAction.connectChanged(delegate(string path, TreeIter actionIter) {
            string action = getValueString(lsActions, actionIter, 0);
            TreeIter iter;
            if (ls.getIter(iter, TreePath.newFromString(path))) {
                ls.setValue(iter, COLUMN_ACTION, new Value(action));
            }
        });
        column = createColumn(_("Action"), crtAction, "text", COLUMN_ACTION);
        column.setMinWidth(150);
        tv.appendColumn(column);

        //Parameter column
        CellRendererText crtParameter = new CellRendererText();
        crtParameter.editable = true;
        crtParameter.connectEdited(delegate(string path, string newText) {
            TreeIter iter;
            if (ls.getIter(iter, TreePath.newFromString(path))) {
                ls.setValue(iter, COLUMN_PARAMETERS, new Value(newText));
            }
        });
        column = createColumn(_("Parameter"), crtParameter, "text", COLUMN_PARAMETERS);
        column.setMinWidth(200);
        tv.appendColumn(column);

        ScrolledWindow sc = new ScrolledWindow();
        sc.add(tv);
        sc.setShadowType(ShadowType.EtchedIn);
        sc.setPolicy(PolicyType.Never, PolicyType.Automatic);
        sc.setHexpand(true);
        sc.setVexpand(true);
        sc.setSizeRequest(-1, 250);

        box.add(sc);

        Box buttons = new Box(Orientation.Vertical, 6);
        Button btnAdd = Button.newWithLabel(_("Add"));
        btnAdd.connectClicked(delegate() {
            TreeIter iter;
            ls.append(iter);
            selectRow(tv, ls.iterNChildren(null) - 1, null);
        });
        buttons.add(btnAdd);
        btnDelete = Button.newWithLabel(_("Delete"));
        btnDelete.connectClicked(delegate() {
            TreeIter selected = getSelectedIter(tv);
            if (selected !is null) {
                ls.remove(selected);
            }
        });
        buttons.add(btnDelete);

        box.add(buttons);
        getContentArea().add(box);

        if (showLineSettings) {
            // Maximum number of lines to check for triggers when content change is
            // received from VTE with a block of text
            Box bLines = new Box(Orientation.Horizontal, 6);
            bLines.setMarginTop(6);

            CheckButton cbTriggerLimit = CheckButton.newWithLabel(_("Limit number of lines for trigger processing to:"));
            gs.bind(SETTINGS_TRIGGERS_UNLIMITED_LINES_KEY, cbTriggerLimit, "active",
                    cast(SettingsBindFlags)(SettingsBindFlags.Default | SettingsBindFlags.InvertBoolean));

            SpinButton sbLines = SpinButton.newWithRange(256.0, double.max, 256.0);
            gs.bind(SETTINGS_TRIGGERS_LINES_KEY, sbLines, "value", SettingsBindFlags.Default);
            gs.bind(SETTINGS_TRIGGERS_UNLIMITED_LINES_KEY, sbLines, "sensitive",
                    cast(SettingsBindFlags)(SettingsBindFlags.Get | SettingsBindFlags.NoSensitivity | SettingsBindFlags.InvertBoolean));

            bLines.add(cbTriggerLimit);
            bLines.add(sbLines);

            getContentArea().add(bLines);
        }
        lblErrors = createErrorLabel();
        getContentArea().add(lblErrors);
        updateUI();
    }

    void updateUI() {
        btnDelete.setSensitive(getSelectedIter(tv) !is null);
        setResponseSensitive(ResponseType.Apply, validateRegex(ls, COLUMN_REGEX, lblErrors));
    }

public:
    this(Window parent, GSettings gs, bool showLineSettings = false) {
        // Same construct-only use-header-bar pattern as EditCustomLinksDialog.
        super(cast(void*) g_object_new(Dialog._getGType(), cast(const(char)*) "use-header-bar", 1, cast(const(char)*) null), No.Take);
        setTitle(_("Edit Triggers"));
        setModal(true);
        addButton(_("Apply"), ResponseType.Apply);
        addButton(_("Cancel"), ResponseType.Cancel);
        setTransientFor(parent);
        setDefaultResponse(ResponseType.Apply);
        createUI(gs, showLineSettings);
    }

    string[] getTriggers() {
        string[] results;
        foreach (TreeIter iter; TreeIterRange(ls)) {
            string regex = getValueString(ls, iter, COLUMN_REGEX);
            if (regex.length == 0) continue;
            results ~= escapeCSV(regex) ~ ',' ~
                       escapeCSV(localizedActions[getValueString(ls, iter, COLUMN_ACTION)]) ~ ',' ~
                       escapeCSV(getValueString(ls, iter, COLUMN_PARAMETERS));
        }
        return results;
    }
}

private:

/**
 * GtkD's TreeView.getSelectedIter convenience: returns the selected iter or
 * null when nothing is selected.
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
 * GtkD's TreeModel.getValueString convenience.
 */
string getValueString(TreeModel model, TreeIter iter, int column) {
    Value value;
    model.getValue(iter, column, value);
    return value.getString();
}

/**
 * GtkD's TreeViewColumn(title, renderer, attribute, column) ctor wraps the
 * varargs gtk_tree_view_column_new_with_attributes (not bound by giD).
 */
TreeViewColumn createColumn(string title, CellRenderer renderer, string attribute, int column) {
    TreeViewColumn result = new TreeViewColumn();
    result.setTitle(title);
    result.packStart(renderer, true);
    result.addAttribute(renderer, attribute, column);
    return result;
}

Label createErrorLabel() {
    Label lblErrors = new Label("");
    lblErrors.setHalign(Align.Start);
    lblErrors.setMarginTop(12);
    lblErrors.getStyleContext().addClass("ttyx-error");
    lblErrors.setNoShowAll(true);

    return lblErrors;
}

Label createSecurityWarningLabel(string text) {
    Label lbl = new Label(text);
    lbl.setHalign(Align.Start);
    lbl.setMarginBottom(12);
    lbl.setLineWrap(true);
    lbl.setMaxWidthChars(70);
    lbl.setXalign(0.0);
    return lbl;
}

bool validateRegex(ListStore ls, int regexColumn, Label lblErrors) {
    bool valid = true;
    string errors;
    int index = 0;
    foreach (TreeIter iter; TreeIterRange(ls)) {
        index++;
        try {
            string regex = getValueString(ls, iter, regexColumn);
            if (regex.length > 0) {
                GRegex check = new GRegex(regex, RegexCompileFlags.Optimize, cast(RegexMatchFlags) 0);
            }
        } catch (RegexException ge) {
            if (errors.length > 0) errors ~= "\n";
            errors ~= format(_("Row %d: "), index) ~ ge.msg;
            valid = false;
        }
    }
    if (errors.length == 0) {
        lblErrors.hide();
    } else {
        lblErrors.setText(errors);
        lblErrors.show();
    }
    return valid;
}
