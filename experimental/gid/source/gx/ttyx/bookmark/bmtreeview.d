/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/bookmark/bmtreeview.d. GtkD -> giD:
 *  - gdk.Pixbuf -> gdkpixbuf.pixbuf.Pixbuf; Pixbuf.getType() -> Pixbuf._getGType();
 *    GType.STRING/BOOLEAN -> cast(GType) GTypeEnum.String/Boolean.
 *  - new TreeStore(GType[]) -> static TreeStore.new_(GType[]).
 *  - TreeIter out-params: every GtkD nullable-iter idiom converts to giD's
 *    bool return + `out TreeIter` (which is ALWAYS set to a non-null wrapper,
 *    even on failure) — null checks became bool checks throughout.
 *  - GtkD's aliasing walk `iterParent(parent, parent)` is invalid with a D
 *    `out` param (out zeroes the arg before the call reads it) — replaced with
 *    a temp iter per step (getParentBookmark, updateFilter).
 *  - GtkD TreeView.getSelectedIter()/TreeModel.getValueString() helpers do not
 *    exist in giD — local private helpers (getSelectedIter over
 *    getSelection().getSelected(out model, out iter); getValueString over
 *    getValue(iter, col, out Value) + Value.getString()).
 *  - ts.createIter(parent) -> ts.append(out iter, parent); setValue takes a
 *    gobject.value.Value (templated ctor: string/bool/Pixbuf all covered);
 *    ts.append(target)/insertBefore/insertAfter all take `out iter`.
 *  - new TreeModelFilter(ts, null) -> ts.filterNew(null) (cast to
 *    TreeModelFilter — giD returns the most-derived wrapper).
 *  - TreeViewColumn(title, renderer, attr, col) ctor -> new TreeViewColumn() +
 *    setTitle + packStart + addAttribute.
 *  - crp.setProperty("stock-size", 16) -> typed property crp.stockSize = 16.
 *  - expandRow(iter, model, openAll) -> expandRow(model.getPath(iter), openAll);
 *    iter.getTreePath() -> model.getPath(iter); TreePath.toString() ->
 *    toString_(); new TreePath(string) -> TreePath.newFromString(string).
 *  - DnD: addOnDragDataGet/Received -> connectDragDataGet/Received (same
 *    delegate shapes, Widget last); gdk.Atom intern() free function ->
 *    static Atom.intern(); SelectionData.set takes ubyte[];
 *    getDataWithLength() -> getData() (already length-sliced ubyte[], cast to
 *    char[] before to!string to keep text semantics).
 *  - Enums PascalCase: TreeViewDropPosition.Before/After/IntoOrBefore/
 *    IntoOrAfter (gtk.types), TargetFlags.SameWidget (gtk.types),
 *    DragAction.Move / ModifierType.Button1Mask (gdk.types).
 * Behavior is unchanged; no upstream bugs found or fixed.
 */
module gx.ttyx.bookmark.bmtreeview;

import std.conv;
import std.experimental.logger;
import std.string;
import std.traits;
import std.typecons : No;

import gdk.atom : Atom;
import gdk.drag_context : DragContext;
import gdk.types : DragAction, ModifierType;

import gdkpixbuf.pixbuf : Pixbuf;

import gobject.types : GType, GTypeEnum;
import gobject.value : Value;

import gtk.cell_renderer : CellRenderer;
import gtk.cell_renderer_pixbuf : CellRendererPixbuf;
import gtk.cell_renderer_text : CellRendererText;
import gtk.selection_data : SelectionData;
import gtk.target_entry : TargetEntry;
import gtk.tree_view_column : TreeViewColumn;
import gtk.tree_iter : TreeIter;
import gtk.tree_model : TreeModel;
import gtk.tree_model_filter : TreeModelFilter;
import gtk.tree_path : TreePath;
import gtk.tree_store : TreeStore;
import gtk.tree_view : TreeView;
import gtk.types : TargetFlags, TreeViewDropPosition;
import gtk.widget : Widget;

import gx.i18n.l10n;

import gx.ttyx.bookmark.manager;

enum Columns : uint {
    ICON = 0,
    NAME = 1,
    UUID = 2,
    FILTER = 3
}

TreeStore createBMTreeModel(Pixbuf[] icons, bool foldersOnly) {
    TreeStore ts = TreeStore.new_([Pixbuf._getGType(), cast(GType) GTypeEnum.String, cast(GType) GTypeEnum.String, cast(GType) GTypeEnum.Boolean]);
    loadBookmarks(ts, null, bmMgr.root, foldersOnly, icons);
    return ts;
}

class BMTreeView: TreeView {
private:
    TreeStore ts;
    TreeModelFilter filter;
    string _filterText;
    Pixbuf[] icons;

    bool ignoreOperationFlag = false;
    string deletedBookmarkUUID;

    enum BOOKMARK_DND = "bookmark";

    enum DropTargets {
        BOOKMARK
    };

    /**
     * giD has no TreeView.getSelectedIter helper; returns null when
     * nothing is selected (matching the GtkD helper's contract).
     */
    TreeIter getSelectedIter() {
        TreeModel model;
        TreeIter iter;
        if (getSelection().getSelected(model, iter)) return iter;
        return null;
    }

    void createColumns() {
        CellRendererPixbuf crp = new CellRendererPixbuf();
        crp.stockSize = 16;
        TreeViewColumn column = createColumn(_("Icon"), crp, "pixbuf", Columns.ICON);
        appendColumn(column);

        column = createColumn(_("Name"), new CellRendererText(), "text", Columns.NAME);
        column.setExpand(true);
        appendColumn(column);

        column = createColumn("UUID", new CellRendererText(), "text", Columns.UUID);
        column.setVisible(false);
        appendColumn(column);

        column = createColumn("Filter", new CellRendererText(), "text", Columns.FILTER);
        column.setVisible(false);
        appendColumn(column);
    }

    FolderBookmark getParentBookmark(Bookmark bm, out TreeIter parent) {
        parent = getSelectedIter();
        if (parent is null) return null;
        if (!getModel().iterHasChild(parent)) {
            TreeIter grandParent;
            if (!getModel().iterParent(grandParent, parent)) {
                parent = null;
                return bmMgr.root;
            }
            parent = grandParent;
        }
        return cast(FolderBookmark) bmMgr.get(getValueString(getModel(), parent, Columns.UUID));
    }

    /**
     * Updates the filter and returns the TreePath
     * of the node that should be focused.
     */
    void updateFilter() {

        void checkFilter(TreeIter iter) {
            string name = getValueString(ts, iter, Columns.NAME);
            bool visible = filterText.length == 0 || name.indexOf(filterText, No.caseSensitive) >= 0;
            ts.setValue(iter, Columns.FILTER, new Value(visible));
            if (visible) {
                TreeIter current = iter;
                // Walk up the parent hierarchy and set it's visibility to true
                TreeIter parent;
                while (ts.iterParent(parent, current)) {
                    // has parent visibility already been set?
                    Value value;
                    ts.getValue(parent, Columns.FILTER, value);
                    if (value.getBoolean()) break;
                    ts.setValue(parent, Columns.FILTER, new Value(true));
                    current = parent;
                }
            }
            if (ts.iterHasChild(iter)) {
                TreeIter child;
                if (ts.iterChildren(child, iter)) {
                    do {
                        checkFilter(child);
                    } while (ts.iterNext(child));
                }
            }
        }

        TreeIter iter;
        if (ts.getIterFirst(iter)) {
            do {
                checkFilter(iter);
            } while (ts.iterNext(iter));
        }
    }

    void selectFirstFilteredLeaf() {
        bool focusLeaf(TreeIter iter) {
            string uuid = getValueString(filter, iter, Columns.UUID);
            FolderBookmark bm = cast(FolderBookmark) bmMgr.get(uuid);
            if (bm is null) {
                getSelection().selectIter(iter);
                return true;
            }
            if (filter.iterHasChild(iter)) {
                TreeIter child;
                if (filter.iterChildren(child, iter)) {
                    do {
                        if (focusLeaf(child)) return true;
                    } while (filter.iterNext(child));
                }
            }
            return false;
        }

        TreeIter iter;
        if (filter.getIterFirst(iter)) {
            do {
                if (focusLeaf(iter)) return;
            } while (filter.iterNext(iter));
        }
    }

// Drag and drop functionality
private:

    void onDragDataGet(DragContext dc, SelectionData data, uint x, uint y, Widget) {
        TreeIter iter = getSelectedIter();
        if (iter !is null) {
            //string uuid = getValueString(ts, iter, Columns.UUID);
            string path = getModel().getPath(iter).toString_();
            ubyte[] buffer = cast(ubyte[]) (path ~ '\0').dup;
            data.set(Atom.intern(BOOKMARK_DND, false), 8, buffer);
        }
    }

    void onDragDataReceived(DragContext dc, int x, int y, SelectionData data, uint info, uint time, Widget widget) {
        if (info != DropTargets.BOOKMARK) return;

        TreePath pathTarget;
        TreeViewDropPosition tvdp;
        if (!getDestRowAtPos(x, y, pathTarget, tvdp)) return;
        TreeIter target;
        ts.getIter(target, pathTarget);

        string dataPath = to!string(cast(char[]) data.getData()[0 .. $ - 1]);
        tracef("Data received %s", dataPath);
        TreePath pathSource = TreePath.newFromString(dataPath);
        TreeIter source;
        ts.getIter(source, pathSource);

        //Move bookmark first
        Bookmark bmTarget = bmMgr.get(getValueString(ts, target, Columns.UUID));
        Bookmark bmSource = bmMgr.get(getValueString(ts, source, Columns.UUID));
        try {
            switch (tvdp) {
                case TreeViewDropPosition.Before:
                    bmMgr.moveBefore(bmTarget, bmSource);
                    break;
                case TreeViewDropPosition.After:
                    bmMgr.moveAfter(bmTarget, bmSource);
                    break;
                case TreeViewDropPosition.IntoOrBefore:
                ..
                case TreeViewDropPosition.IntoOrAfter:
                    FolderBookmark fb = cast(FolderBookmark) bmTarget;
                    if (fb is null) {
                        error("Unexpected, not a folder bookmark, bookmark not moved");
                        return;
                    }
                    bmMgr.moveInto(fb, bmSource);
                    break;
                default:
                    error("Unexpected value for TreeViewDropPosition, should never get here");
                    return;

            }
        } catch (Exception e) {
            error("Could not perform operation, error occurred");
            error(e);
            return;
        }

        TreeIter iter;
        final switch (tvdp) {
            case TreeViewDropPosition.Before:
                TreeIter iterParent;
                if (!ts.iterParent(iterParent, target)) {
                    iterParent = null;
                }
                ts.insertBefore(iter, iterParent, target);
                break;
            case TreeViewDropPosition.After:
                TreeIter iterParent;
                if (!ts.iterParent(iterParent, target)) {
                    iterParent = null;
                }
                ts.insertAfter(iter, iterParent, target);
                break;
            case TreeViewDropPosition.IntoOrBefore:
                ts.append(iter, target);
                break;
            case TreeViewDropPosition.IntoOrAfter:
                ts.append(iter, target);
                break;
        }

        foreach(column; EnumMembers!Columns) {
            Value value;
            ts.getValue(source, column, value);
            ts.setValue(iter, column, value);
        }
        ts.remove(source);
    }

    void setupDragAndDrop() {
        TargetEntry bmEntry = new TargetEntry(BOOKMARK_DND, TargetFlags.SameWidget, DropTargets.BOOKMARK);
        TargetEntry[] targets = [bmEntry];
        enableModelDragDest(targets, DragAction.Move);
        enableModelDragSource(ModifierType.Button1Mask, targets, DragAction.Move);
        connectDragDataGet(&onDragDataGet);
        connectDragDataReceived(&onDragDataReceived);
    }

public:
    this(bool enableFilter = false, bool foldersOnly = false, bool reorganizeable = false) {
        super();
        icons = getBookmarkIcons(this);
        ts = createBMTreeModel(icons, foldersOnly);

        if (enableFilter) {
            filter = cast(TreeModelFilter) ts.filterNew(null);
            filter.setVisibleColumn(Columns.FILTER);
            setModel(filter);
        } else {
            setModel(ts);
            if (reorganizeable) {
                setupDragAndDrop();
            }
        }
        createColumns();
    }

    Bookmark getSelectedBookmark() {
        TreeIter selected = getSelectedIter();
        if (selected is null) return null;
        return bmMgr.get(getValueString(getModel(), selected, Columns.UUID));
    }

    /**
     * Adds a bookmark to the treeview based on the selected
     * bookmark. Returns the FolderBookmark to which the
     * bookmark was added.
     */
    FolderBookmark addBookmark(Bookmark bm) {
        TreeIter parent;
        FolderBookmark fbm = cast(FolderBookmark) getSelectedBookmark();
        if (fbm is null) {
            fbm = getParentBookmark(bm, parent);
            if (fbm is null) {
                fbm = bmMgr.root;
            }
        } else {
            parent = getSelectedIter();
        }

        bmMgr.add(fbm, bm);
        ignoreOperationFlag = true;
        TreeIter iter = addBookmarktoParent(ts, parent, bm, icons);
        ignoreOperationFlag = false;
        if (parent !is null) {
            expandRow(ts.getPath(parent), false);
        }
        getSelection().selectIter(iter);
        return fbm;
    }

    /**
     * Removes selected bookmark.
     */
    void removeBookmark() {
        TreeIter selected = getSelectedIter();
        Bookmark bm = getSelectedBookmark();
        if (selected is null || bm is null) return;

        bmMgr.remove(bm);
        ignoreOperationFlag = true;
        ts.remove(selected);
        ignoreOperationFlag = false;
    }

    /**
     * Update the selected bookmark.
     */
    void updateBookmark(Bookmark bm) {
        TreeIter selected = getSelectedIter();
        if (selected is null || getValueString(ts, selected, Columns.UUID) != bm.uuid) return;
        ts.setValue(selected, Columns.NAME, new Value(bm.name));
    }

    @property string filterText() {
        return _filterText;
    }

    @property void filterText(string value) {
        if (filter is null) {
            error("Cannot filter treeview, filter not created");
            return;
        }

        if (_filterText != value) {
            _filterText = value;
            updateFilter();
            trace("Refilter");
            filter.refilter();
            expandAll();
            selectFirstFilteredLeaf();
        }
    }
}

private:

/**
 * giD has no TreeModel.getValueString helper (GtkD convenience);
 * equivalent over getValue(iter, column, out Value).
 */
string getValueString(TreeModel model, TreeIter iter, int column) {
    Value value;
    model.getValue(iter, column, value);
    return value.getString();
}

/**
 * giD binds no TreeViewColumn(title, renderer, attribute, column) ctor
 * (varargs); assembled from parts instead.
 */
TreeViewColumn createColumn(string title, CellRenderer renderer, string attribute, int column) {
    TreeViewColumn result = new TreeViewColumn();
    result.setTitle(title);
    result.packStart(renderer, true);
    result.addAttribute(renderer, attribute, column);
    return result;
}

void loadBookmarks(TreeStore ts, TreeIter current, FolderBookmark parent, bool foldersOnly, Pixbuf[] icons) {
    foreach(bm; parent) {
        FolderBookmark fm = cast(FolderBookmark)bm;
        if (foldersOnly && fm is null) {
            continue;
        }
        TreeIter childIter = addBookmarktoParent(ts, current, bm, icons);
        if (fm !is null) {
            loadBookmarks(ts, childIter, fm, foldersOnly, icons);
        }
    }
}

TreeIter addBookmarktoParent(TreeStore ts, TreeIter parent, Bookmark bm, Pixbuf[] icons) {
    TreeIter result;
    ts.append(result, parent);
    ts.setValue(result, Columns.ICON, new Value(icons[cast(uint)bm.type()]));
    ts.setValue(result, Columns.NAME, new Value(bm.name));
    ts.setValue(result, Columns.UUID, new Value(bm.uuid));
    ts.setValue(result, Columns.FILTER, new Value(true));
    return result;
}
