/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/prefeditor/bookmarkeditor.d. GtkD -> giD:
 *  - GtkD's TreeView.getSelectedIter() convenience is unbound in giD — local
 *    helper over getSelection().getSelected(out model, out iter) returning
 *    null when nothing is selected (same pattern as bmtreeview.d/advdialog.d).
 *    unselectBookmark guards on it before unselectIter (the GtkD original
 *    passed a possibly-null iter straight through).
 *  - new Button(iconName, IconSize.BUTTON) -> Button.newFromIconName(iconName,
 *    IconSize.Button); addOnClicked(&method) -> connectClicked(&method)
 *    (methods keep their `Button button` parameter — it matches giD's
 *    emitter-instance parameter).
 *  - addOnCursorChanged/addOnRowActivated -> connectCursorChanged/
 *    connectRowActivated with zero-param delegate literals.
 *  - new ScrolledWindow(tv) -> new ScrolledWindow() + add(tv).
 *  - Enums PascalCase in gtk.types: SelectionMode.Single, ShadowType.EtchedIn,
 *    PolicyType.Automatic, Orientation.Vertical/Horizontal, ResponseType.Ok,
 *    IconSize.Button.
 * Behavior is unchanged. (The shadowed local `sw` over the unused field from
 * the original is kept as-is.)
 */
module gx.ttyx.prefeditor.bookmarkeditor;

import std.experimental.logger;

import gtk.box : Box;
import gtk.button : Button;
import gtk.scrolled_window : ScrolledWindow;
import gtk.tree_iter : TreeIter;
import gtk.tree_model : TreeModel;
import gtk.tree_view : TreeView;
import gtk.types : IconSize, Orientation, PolicyType, ResponseType, SelectionMode, ShadowType;
import gtk.window : Window;

import gx.i18n.l10n;

import gx.gtk.util;

import gx.ttyx.bookmark.bmeditor;
import gx.ttyx.bookmark.bmtreeview;
import gx.ttyx.bookmark.manager;

/**
 * Editor for globally managing bookmarks as part of the preferences dialog. Should not
 * be used outside this context.
 */
class GlobalBookmarkEditor: Box {

private:
    BMTreeView tv;
    ScrolledWindow sw;

    Button btnEdit;
    Button btnDelete;
    Button btnUnselect;

    void createUI() {
        tv = new BMTreeView(false, false, true);
        tv.setActivateOnSingleClick(false);
        tv.setHeadersVisible(false);
        tv.getSelection().setMode(SelectionMode.Single);
        tv.connectCursorChanged(() {
            updateUI();
        });
        tv.connectRowActivated(() {
            editBookmark(btnEdit);
        });

        ScrolledWindow sw = new ScrolledWindow();
        sw.add(tv);
        sw.setShadowType(ShadowType.EtchedIn);
        sw.setPolicy(PolicyType.Automatic, PolicyType.Automatic);
        sw.setHexpand(true);
        sw.setVexpand(true);

        add(sw);

        Box bButtons = new Box(Orientation.Horizontal, 0);
        bButtons.getStyleContext().addClass("linked");

        Button btnAdd = Button.newFromIconName("list-add-symbolic", IconSize.Button);
        btnAdd.setTooltipText(_("Add bookmark"));
        btnAdd.connectClicked(&addBookmark);
        bButtons.add(btnAdd);

        btnEdit = Button.newFromIconName("input-tablet-symbolic", IconSize.Button);
        btnEdit.setTooltipText(_("Edit bookmark"));
        btnEdit.connectClicked(&editBookmark);
        bButtons.add(btnEdit);

        btnDelete = Button.newFromIconName("list-remove-symbolic", IconSize.Button);
        btnDelete.setTooltipText(_("Delete bookmark"));
        btnDelete.connectClicked(&deleteBookmark);
        bButtons.add(btnDelete);

        btnUnselect = Button.newFromIconName("edit-clear-symbolic", IconSize.Button);
        btnUnselect.setTooltipText(_("Unselect bookmark"));
        btnUnselect.connectClicked(&unselectBookmark);
        bButtons.add(btnUnselect);

        add(bButtons);

        updateUI();
    }

    void updateUI() {
        TreeIter selected = getSelectedIter(tv);
        btnEdit.setSensitive(selected !is null);
        btnDelete.setSensitive(selected !is null);
        btnUnselect.setSensitive(selected !is null);
    }

    void addBookmark(Button button) {
        BookmarkEditor be = new BookmarkEditor(cast(Window)getToplevel(), BookmarkEditorMode.ADD, null);
        scope(exit) {
            be.destroy();
        }
        be.showAll();
        if (be.run() == ResponseType.Ok) {
            Bookmark bm = be.create();
            tv.addBookmark(bm);
        }
    }

    void editBookmark(Button button) {
        Bookmark bm = tv.getSelectedBookmark();
        if (bm is null) return;
        BookmarkEditor be = new BookmarkEditor(cast(Window)getToplevel(), BookmarkEditorMode.EDIT, bm);
        scope(exit) {
            be.destroy();
        }
        be.showAll();
        if (be.run() == ResponseType.Ok) {
            be.update(bm);
            tv.updateBookmark(bm);
        }
    }

    void deleteBookmark(Button button) {
        tv.removeBookmark();
    }

    void unselectBookmark(Button button) {
        TreeIter selected = getSelectedIter(tv);
        if (selected !is null) {
            tv.getSelection().unselectIter(selected);
        }
    }

public:
    this() {
        super(Orientation.Vertical, 6);
        setAllMargins(this, 18);
        setMarginBottom(6);
        createUI();
    }
}

private:

/**
 * giD has no TreeView.getSelectedIter helper (GtkD convenience); returns
 * null when nothing is selected, matching the GtkD helper's contract.
 */
TreeIter getSelectedIter(TreeView tv) {
    TreeModel model;
    TreeIter iter;
    if (tv.getSelection().getSelected(model, iter)) return iter;
    return null;
}
