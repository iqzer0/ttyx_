/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/gtk/util.d. Key differences from the GtkD original:
 *   - gdk.rgba.RGBA is a value struct, not a class: equal(RGBA, RGBA) loses its
 *     null handling (structs cannot be null), callers compare directly;
 *   - parseName uses gio.file.File.parseName (giD binds it; GtkD needed a
 *     hand-rolled g_file_parse_name call);
 *   - isWayland replaces GtkD's gtkc.gdk/gtkc.gobject C imports with a plain
 *     extern(C) gdk_x11_surface_get_type (link-time resolve from libgtk-4, same
 *     pattern as gx.gtk.x11) + gobject.global.typeCheckInstanceIsA;
 *   - Container.getChildren returns Widget[] directly (no ListG);
 *   - tree stores: createIter → append(out iter), setValue takes a
 *     gobject.value.Value (Value's templated ctor covers strings + scalars);
 *   - ComboBox: ComboBox.newWithModel + CellLayout packStart/addAttribute;
 *   - getGtkTheme reads gtk.settings.Settings.getDefault().gtkThemeName
 *     (giD generates typed property accessors, no gobject.Value dance);
 *   - processEvents was DELETED in the GTK4 port: it had no callers, and
 *     gtk_events_pending/gtk_main_iteration_do no longer exist. If a
 *     bounded event drain is ever needed again, GLib's MainContext
 *     pending()/iteration() survives GTK4 and is the direct equivalent.
 */
module gx.gtk.util;

import glib.variant : Variant;
import std.conv;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.experimental.logger;
import std.process : environment;
import std.typecons : No;

import gdk.rgba : RGBA;
import gdk.types : ModifierType, KEY_Left, KEY_Right;

import gio.file : File;

import gobject.global : typeCheckInstanceIsA;
import gobject.type_instance : TypeInstance;
import gobject.types : GType, GTypeEnum;
import gobject.value : Value;

import gtk.box : Box;
import gtk.callback_action : CallbackAction;
import gtk.cell_renderer_text : CellRendererText;
import gtk.combo_box : ComboBox;
import gtk.keyval_trigger : KeyvalTrigger;
import gtk.list_store : ListStore;
import gtk.settings : Settings;
import gtk.shortcut : Shortcut;
import gtk.shortcut_controller : ShortcutController;
import gtk.style_context : StyleContext;
import gtk.tree_iter : TreeIter;
import gtk.tree_model : TreeModel;
import gtk.tree_path : TreePath;
import gtk.tree_store : TreeStore;
import gtk.tree_view : TreeView;
import gtk.tree_view_column : TreeViewColumn;
import gtk.types : Orientation, StateFlags;
import gtk.widget : Widget;
import gtk.window : Window;
import gtk.global : getMajorVersion, getMinorVersion, getMicroVersion;

import gx.gtk.x11;

/**
 * Parse filename and return File object
 */
public File parseName(string parseName) {
    return File.parseName(parseName);
}

/**
 * Activates a window using the X11 APIs when available
 */
void activateWindow(Window window) {
    if (window.isActive()) return;

    if (isWayland(window)) {
        trace("Present Window for Wayland");
        window.presentWithTime(cast(uint) GDK_CURRENT_TIME);
    } else {
        trace("Present Window for X11");
        window.present();
        activateX11Window(window);
    }
}

/**
 * Returns true if running under Wayland, right now
 * it just uses a simple environment variable check to detect it.
 */
bool isWayland(Window window) {
    if (window is null || window.getSurface() is null) {
        return (environment.get("XDG_SESSION_TYPE","x11") == "wayland" && environment.get("GDK_BACKEND")!="x11");
    }

    GType x11Type = gdk_x11_surface_get_type();
    scope instance = new TypeInstance(window.getSurface()._cPtr, No.Take);

    return !typeCheckInstanceIsA(instance, x11Type);
}

/**
 * Return the name of the GTK Theme
 */
string getGtkTheme() {
    return Settings.getDefault().gtkThemeName;
}

/**
 * Convenience method for creating a box and adding children
 */
Box createBox(Orientation orientation, int spacing,  Widget[] children) {
    Box result = new Box(orientation, spacing);
    foreach(child; children) {
        result.append(child);
    }
    return result;
}

/**
 * Direct children of `widget`, in order.
 *
 * GTK4 removed GtkContainer and GtkBin: every widget exposes its children
 * through the same first-child/next-sibling walk, so the old
 * "is it a Bin or a Container?" branch disappears entirely.
 */
Widget[] childWidgets(Widget widget) {
    Widget[] result;
    if (widget is null) return result;
    for (Widget c = widget.getFirstChild(); c !is null; c = c.getNextSibling()) {
        result ~= c;
    }
    return result;
}

/**
 * Finds the index position of a child within its parent.
 */
int getChildIndex(Widget parent, Widget child) {
    if (parent is null || child is null) return -1;
    foreach(i, c; childWidgets(parent)) {
        if (c._cPtr == child._cPtr) return cast(int) i;
    }
    return -1;
}

/**
 * Walks up the parent chain until it finds the parent of the
 * requested type.
 */
T findParent(T) (Widget widget) {
    while ((widget !is null)) {
        widget = widget.getParent();
        T result = cast(T) widget;
        if (result !is null) return result;
    }
    return null;
}

/**
 * Template for finding all children of a specific type
 */
T[] getChildren(T) (Widget widget, bool recursive) {
    T[] result;
    Widget[] children;

    if (widget is null) return result;

    children = childWidgets(widget);

    foreach(child; children) {
        if (child is null) continue;
        T match = cast(T) child;
        if (match !is null) result ~= match;
        if (recursive) {
            result ~= getChildren!(T)(child, recursive);
        }
    }
    return result;
}

/**
 * Gets the background color from style context. Works around
 * spurious VTE State messages on GTK 3.19 or later. See the
 * blog entry here: https://blogs.gnome.org/mclasen/2015/11/20/a-gtk-update/
 */
/**
 * Approximate the themed background colour.
 *
 * GTK4 removed gtk_style_context_get_background_color() outright, with no
 * replacement: backgrounds are CSS-rendered and simply not queryable any more.
 * The closest surviving mechanism is looking up the named colour GTK themes
 * conventionally define, so that is what this does.
 *
 * Caveats the caller should know:
 *   - `flags` is now unused. Per-state background colours cannot be resolved,
 *     so a Selected vs Active distinction is no longer available here.
 *   - a theme that does not define the named colour yields false, and `color`
 *     is left at its default. Callers already guard on the profile's
 *     use-theme-colors setting, but they should treat the result as
 *     best-effort rather than authoritative.
 *
 * Returns: true if the theme provided a value.
 */
bool getStyleBackgroundColor(StyleContext context, StateFlags flags, out RGBA color) {
    // theme_bg_color is the long-standing convention; theme_base_color is what
    // entry-like widgets use and is the better match for a terminal surface.
    foreach (name; ["theme_base_color", "theme_bg_color"]) {
        if (context.lookupColor(name, color)) return true;
    }
    return false;
}

/**
 * Gets the color from style context. Works around
 * spurious VTE State messages on GTK 3.19 or later. See the
 * blog entry here: https://blogs.gnome.org/mclasen/2015/11/20/a-gtk-update/
 */
void getStyleColor(StyleContext context, StateFlags flags, out RGBA color) {
    with (context) {
        save();
        setState(flags);
        getColor(color);
        restore();
    }
}

/**
 * Sets all margins of a widget to the same value
 */
void setAllMargins(Widget widget, int margin) {
    setMargins(widget, margin, margin, margin, margin);
}

/**
 * Sets margins of a widget to the passed values
 */
void setMargins(Widget widget, int left, int top, int right, int bottom) {
    widget.setMarginStart(left);
    widget.setMarginTop(top);
    widget.setMarginEnd(right);
    widget.setMarginBottom(bottom);
}

/**
 * Defined here since not defined in GtkD
 */
enum MouseButton : uint {
    PRIMARY = 1,
    MIDDLE = 2,
    SECONDARY = 3
}

/**
 * Not declared in giD
 */
enum long GDK_CURRENT_TIME = 0;

/**
 * Compares two RGBA and returns if they are equal. In giD RGBA is a value
 * struct, so the GtkD version's null handling no longer applies.
 */
bool equal(RGBA r1, RGBA r2) {
    return r1.equal(r2);
}

bool equal(Widget w1, Widget w2) {
    if (w1 is null && w2 is null)
        return true;
    if ((w1 is null && w2 !is null) || (w1 !is null && w2 is null))
        return false;
    return w1._cPtr == w2._cPtr;
}

/**
 * Appends multiple values to a row in a tree store
 */
TreeIter appendValues(TreeStore ts, TreeIter parentIter, string[] values) {
    TreeIter iter;
    ts.append(iter, parentIter);
    for (int i = 0; i < values.length; i++) {
        ts.setValue(iter, i, new Value(values[i]));
    }
    return iter;
}

/**
 * Appends multiple values to a row in a list store
 */
TreeIter appendValues(ListStore ls, string[] values) {
    TreeIter iter;
    ls.append(iter);
    for (int i = 0; i < values.length; i++) {
        ls.setValue(iter, i, new Value(values[i]));
    }
    return iter;
}

/**
 * Creates a combobox that holds a set of name/value pairs
 * where the name is displayed.
 */
ComboBox createNameValueCombo(const string[string] keyValues) {

    ListStore ls = ListStore.new_([cast(GType) GTypeEnum.String, cast(GType) GTypeEnum.String]);

    foreach (key, value; keyValues) {
        appendValues(ls, [value, key]);
    }

    return wireNameValueCombo(ls);
}

/**
 * Creates a combobox that holds a set of name/value pairs
 * where the name is displayed.
 */
ComboBox createNameValueCombo(const string[] names, const string[] values) {
    assert(names.length == values.length);

    ListStore ls = ListStore.new_([cast(GType) GTypeEnum.String, cast(GType) GTypeEnum.String]);

    for (int i = 0; i < names.length; i++) {
        appendValues(ls, [names[i], values[i]]);
    }

    return wireNameValueCombo(ls);
}

template TComboBox(T) {

    ComboBox createComboBox(const string[] names, T[] values) {
        assert(names.length == values.length);
        trace(typeof(values).stringof);

        static if (is(T == int) || is(T == uint)) {
            enum GTypeEnum valueType = GTypeEnum.Int;
        } else static if (is(T == long) || is(T == ulong)) {
            enum GTypeEnum valueType = GTypeEnum.Int64;
        } else static if (is(T == double)) {
            enum GTypeEnum valueType = GTypeEnum.Double;
        } else {
            enum GTypeEnum valueType = GTypeEnum.String;
        }
        trace(valueType);

        ListStore ls = ListStore.new_([cast(GType) GTypeEnum.String, cast(GType) valueType]);

        for (int row; row < values.length; row++) {
            TreeIter iter;
            ls.append(iter);
            ls.setValue(iter, 0, new Value(names[row]));
            static if (valueType == GTypeEnum.Int) {
                ls.setValue(iter, 1, new Value(cast(int) values[row]));
            } else static if (valueType == GTypeEnum.Int64) {
                ls.setValue(iter, 1, new Value(cast(long) values[row]));
            } else static if (valueType == GTypeEnum.Double) {
                ls.setValue(iter, 1, new Value(cast(double) values[row]));
            } else {
                ls.setValue(iter, 1, new Value(to!string(values[row])));
            }
        }

        return wireNameValueCombo(ls);
    }
}

/**
 * Shared tail of the combo factories: display column 0, id column 1.
 */
private ComboBox wireNameValueCombo(ListStore ls) {
    ComboBox cb = ComboBox.newWithModel(ls);
    cb.setFocusOnClick(false);
    cb.setIdColumn(1);
    CellRendererText cell = new CellRendererText();
    cell.setAlignment(0, 0);
    cb.packStart(cell, false);
    cb.addAttribute(cell, "text", 0);
    return cb;
}

/**
 * Selects the specified row in a Treeview
 */
void selectRow(TreeView tv, int row, TreeViewColumn column = null) {
    TreeModel model = tv.getModel();
    TreeIter iter;
    if (model.iterNthChild(iter, null, row)) {
        tv.setCursor(model.getPath(iter), column, false);
    } else {
        tracef("No TreeIter found for row %d", row);
    }
}

/**
 * An implementation of a range that allows using foreach with a TreeModel and TreeIter
 */
struct TreeIterRange {

private:
    TreeModel model;
    TreeIter iter;
    bool _empty;

public:
    this(TreeModel model) {
        this.model = model;
        _empty = !model.getIterFirst(iter);
    }

    this(TreeModel model, TreeIter parent) {
        this.model = model;
        _empty = !model.iterChildren(iter, parent);
        if (_empty) trace("TreeIter has no children");
    }

    @property bool empty() {
        return _empty;
    }

    @property auto front() {
        return iter;
    }

    void popFront() {
        _empty = !model.iterNext(iter);
    }

    /**
     * Based on the example here https://www.sociomantic.com/blog/2010/06/opapply-recipe/#.Vm8mW7grKEI
     */
    int opApply(int delegate(ref TreeIter iter) dg) {
        int result = 0;
        bool hasNext = !_empty;
        while (hasNext) {
            result = dg(iter);
            if (result) {
                break;
            }
            hasNext = model.iterNext(iter);
        }
        return result;
    }
}

private:

// giD does not bind the GDK X11 backend; resolves at link time from libgdk-3
// (same pattern as gx.gtk.x11).
extern(C) GType gdk_x11_surface_get_type();

/**
 * True when the running GTK is at least major.minor.micro.
 *
 * Replaces the GTK3-era `checkVersion(3, x, 0).length == 0` feature gates.
 * gtk_check_version() reports a *major mismatch* as an error, so on GTK4 every
 * one of those gates answered "too old" and took the legacy branch. A plain
 * numeric comparison says what the gates always meant.
 */
public bool gtkAtLeast(uint major, uint minor, uint micro = 0) {
    uint rMajor = getMajorVersion();
    uint rMinor = getMinorVersion();
    uint rMicro = getMicroVersion();
    if (rMajor != major) return rMajor > major;
    if (rMinor != minor) return rMinor > minor;
    return rMicro >= micro;
}

/**
 * Left collapses the cursor row or, if it is already collapsed, moves the
 * cursor to its parent; Right expands it. This is the tree-view navigation
 * ttyx.base320.css installed for every TreeView with a GTK3 @binding-set.
 * GTK4 has no CSS key bindings, so it is a ShortcutController per view that
 * drives the TreeView directly (the action signals the binding fired are
 * still there, but a Shortcut carries one action and Left needed two).
 */
public void addTreeViewNavigation(TreeView tv) {
    ShortcutController sc = new ShortcutController();

    Shortcut left = new Shortcut(new KeyvalTrigger(KEY_Left, cast(ModifierType) 0),
        new CallbackAction(delegate bool(Widget w, Variant args) {
            TreePath path;
            TreeViewColumn column;
            tv.getCursor(path, column);
            if (path is null) return false;
            if (tv.rowExpanded(path)) {
                tv.collapseRow(path);
                return true;
            }
            if (path.getDepth() > 1 && path.up()) {
                tv.setCursor(path, null, false);
                return true;
            }
            return false;
        }));
    sc.addShortcut(left);

    Shortcut right = new Shortcut(new KeyvalTrigger(KEY_Right, cast(ModifierType) 0),
        new CallbackAction(delegate bool(Widget w, Variant args) {
            TreePath path;
            TreeViewColumn column;
            tv.getCursor(path, column);
            if (path is null) return false;
            tv.expandRow(path, false);
            return true;
        }));
    sc.addShortcut(right);

    tv.addController(sc);
}
