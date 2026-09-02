/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/terminal/search.d. Differences from GtkD:
 *   - Icon widgets/buttons: `new Image(name, IconSize.MENU)` /
 *     `new Button(name, IconSize.MENU)` → static factories
 *     `Image.newFromIconName` / `Button.newFromIconName` with
 *     `gtk.types.IconSize.Menu`.
 *   - `new Popover(relativeTo, model)` → `Popover.newFromModel(relativeTo, model)`.
 *   - `new Frame(child, null)` → `new Frame()` + `add(child)` (giD only binds
 *     the label ctor).
 *   - `Version.checkVersion(3,20,0)` → free function `gtk.global.checkVersion`
 *     (same null-on-compatible contract).
 *   - Key release: `addOnKeyRelease(Event, Widget)` + `event.getKeyval(out kv)`
 *     → `connectGdkEvent!EventKey(this, "key-release-event", bool delegate(EventKey))` with direct
 *     `.keyval`/`.state` field access; keysyms are `gdk.types.KEY_*`,
 *     modifiers `gdk.types.ModifierType.ShiftMask`.
 *   - `sagSearch.lookup(name)` → `lookupAction(name)` (ActionMap mixin; the
 *     GtkD-style `lookup` still exists but is deprecated).
 *   - `GSettings.addOnChanged(cb)` → `connectChanged(null, cb)` — the first
 *     parameter is the optional signal detail (a settings key); null keeps
 *     the GtkD match-all behavior.
 *   - `VRegex.newSearch(pattern, -1, flags)` → static
 *     `VRegex.newForSearch(pattern, flags)`; throws `glib.error.ErrorWrap`
 *     on an invalid pattern (GtkD threw GException — caller logic unchanged).
 *   - Upstream bug fixed: the original connected `addOnFocusIn` TWICE and
 *     emitted `onSearchEntryFocusOut` from the second focus-IN handler, so
 *     focus-out fired on focus-in and never on focus-out. The port connects
 *     `connectFocusOutEvent` for the focus-out emission (terminal.d connects
 *     both events symmetrically, so this is the evident intent).
 */
module gx.ttyx.terminal.search;

import std.experimental.logger;
import std.format;

import gdk.types : KEY_Escape, KEY_Return, ModifierType;

import gtk.event_controller_focus : EventControllerFocus;
import gtk.event_controller_key : EventControllerKey;

import gio.action_group : ActionGroup;
import gio.menu : Menu;
import gio.settings : GSettings = Settings;
import gio.simple_action : SimpleAction;
import gio.simple_action_group : SimpleActionGroup;

import glib.error : ErrorWrap;
import glib.regex : GRegex = Regex;
import glib.variant : GVariant = Variant;

import gtk.box : Box;
import gtk.button : Button;
import gtk.frame : Frame;
import gtk.global : checkVersion;
import gtk.image : Image;
import gtk.menu_button : MenuButton;
import gtk.popover : Popover;
import gtk.popover_menu : PopoverMenu;
import gtk.revealer : Revealer;
import gtk.search_entry : SearchEntry;
import gtk.types : Align, Orientation;
import gtk.widget : Widget;

import vte.regex : VRegex = Regex;
import vte.terminal : VTE = Terminal;

import gx.gtk.actions;
import gx.gtk.vte;
import gx.i18n.l10n;

import gx.ttyx.common;
import gx.ttyx.constants;
import gx.ttyx.preferences;
import gx.ttyx.terminal.actions;
import gx.gtk.util : gtkAtLeast;

/**
 * Widget that displays the Find UI for a terminal and manages the search actions
 */
class SearchRevealer : Revealer {

private:

    enum ACTION_SEARCH_PREFIX = "search";
    enum ACTION_SEARCH_MATCH_CASE = "match-case";
    enum ACTION_SEARCH_ENTIRE_WORD_ONLY = "entire-word";
    enum ACTION_SEARCH_MATCH_REGEX = "match-regex";
    enum ACTION_SEARCH_WRAP_AROUND = "wrap-around";

    GSettings gsSettings;

    VTE vte;
    ActionGroup terminalActions;
    SimpleActionGroup sagSearch;

    SearchEntry seSearch;

    MenuButton mbOptions;
    bool matchCase;
    bool entireWordOnly;
    bool matchAsRegex;

    /**
     * Creates the find overlay
     */
    void createUI() {
        createActions();

        setHexpand(true);
        setVexpand(false);
        setHalign(Align.Fill);
        setValign(Align.Start);

        Box bSearch = new Box(Orientation.Horizontal, 6);
        bSearch.setHalign(Align.Center);
        bSearch.setMarginStart(4);
        bSearch.setMarginEnd(4);
        bSearch.setMarginTop(4);
        bSearch.setMarginBottom(4);
        bSearch.setHexpand(true);

        Box bEntry = new Box(Orientation.Horizontal, 0);
        bEntry.getStyleContext().addClass("linked");

        seSearch = new SearchEntry();
        seSearch.setWidthChars(1);
        seSearch.setMaxWidthChars(30);
        if (!gtkAtLeast(3, 20, 0)) {
            seSearch.getStyleContext().addClass("ttyx-search-entry");
        }
        seSearch.connectSearchChanged(delegate() {
            setTerminalSearchCriteria();
        });
        // GTK4: key-release-event -> EventControllerKey's key-released, whose
        // callback returns void rather than bool. No behaviour is lost here —
        // the GTK3 handler unconditionally returned false, i.e. it never
        // consumed the event.
        EventControllerKey keyController = new EventControllerKey();
        keyController.connectKeyReleased(
            delegate void(uint keyval, uint keycode, ModifierType state, EventControllerKey c) {
                switch (keyval) {
                    case KEY_Escape:
                        setRevealChild(false);
                        vte.grabFocus();
                        break;
                    case KEY_Return:
                        if (state & ModifierType.ShiftMask) {
                            terminalActions.activateAction(ACTION_FIND_NEXT, null);
                        } else {
                            terminalActions.activateAction(ACTION_FIND_PREVIOUS, null);
                        }
                        break;
                    default:
                }
            });
        seSearch.addController(keyController);
        bEntry.append(seSearch);

        mbOptions = new MenuButton();
        mbOptions.setTooltipText(_("Search Options"));
        mbOptions.setFocusOnClick(false);
        Image iHamburger = Image.newFromIconName("pan-down-symbolic");
        mbOptions.setChild(iHamburger);
        mbOptions.setPopover(createPopover());
        bEntry.append(mbOptions);

        bSearch.append(bEntry);

        Box bButtons = new Box(Orientation.Horizontal, 0);
        bButtons.getStyleContext().addClass("linked");

        Button btnNext = Button.newFromIconName("go-up-symbolic");
        btnNext.setTooltipText(_("Find next"));
        btnNext.setActionName(getActionDetailedName(ACTION_PREFIX, ACTION_FIND_PREVIOUS));
        btnNext.setCanFocus(false);
        bButtons.append(btnNext);

        Button btnPrevious = Button.newFromIconName("go-down-symbolic");
        btnPrevious.setTooltipText(_("Find previous"));
        btnPrevious.setActionName(getActionDetailedName(ACTION_PREFIX, ACTION_FIND_NEXT));
        btnPrevious.setCanFocus(false);
        bButtons.append(btnPrevious);

        bSearch.append(bButtons);

        Button btnClose = Button.newFromIconName("window-close-symbolic");
        btnClose.setTooltipText(_("Close search box"));
        // GTK4: GtkReliefStyle is gone; a button either has a frame or not.
        btnClose.setHasFrame(false);
        btnClose.setFocusOnClick(true);
        btnClose.connectClicked(delegate() {
            setRevealChild(false);
            vte.grabFocus();
        });
        // GTK4: GtkBox lost pack_end's expand/fill/padding arguments. The
        // close button is pushed to the trailing edge with halign + hexpand
        // instead, which is the GTK4 idiom.
        btnClose.setHalign(Align.End);
        btnClose.setHexpand(true);
        bSearch.append(btnClose);

        Frame frame = new Frame();
        frame.setChild(bSearch);
        // GTK4: GtkShadowType is gone; GtkFrame has no shadow, only a label
        // and CSS styling, so ShadowType.None is simply the default.
        frame.getStyleContext().addClass("ttyx-search-frame");
        setChild(frame);
    }

    void createActions() {
        GSettings gsGeneral = new GSettings(SETTINGS_ID);

        sagSearch = new SimpleActionGroup();

        registerAction(sagSearch, ACTION_SEARCH_PREFIX, ACTION_SEARCH_MATCH_CASE, null, delegate(GVariant value, SimpleAction sa) {
            matchCase = !sa.getState().getBoolean();
            sa.setState(new GVariant(matchCase));
            setTerminalSearchCriteria();
        }, null, gsGeneral.getValue(SETTINGS_SEARCH_DEFAULT_MATCH_CASE));

        registerAction(sagSearch, ACTION_SEARCH_PREFIX, ACTION_SEARCH_ENTIRE_WORD_ONLY, null, delegate(GVariant value, SimpleAction sa) {
            entireWordOnly = !sa.getState().getBoolean();
            sa.setState(new GVariant(entireWordOnly));
            setTerminalSearchCriteria();
        }, null, gsGeneral.getValue(SETTINGS_SEARCH_DEFAULT_MATCH_ENTIRE_WORD));

        registerAction(sagSearch, ACTION_SEARCH_PREFIX, ACTION_SEARCH_MATCH_REGEX, null, delegate(GVariant value, SimpleAction sa) {
            matchAsRegex = !sa.getState().getBoolean();
            sa.setState(new GVariant(matchAsRegex));
            setTerminalSearchCriteria();
        }, null, gsGeneral.getValue(SETTINGS_SEARCH_DEFAULT_MATCH_AS_REGEX));

        registerAction(sagSearch, ACTION_SEARCH_PREFIX, ACTION_SEARCH_WRAP_AROUND, null, delegate(GVariant value, SimpleAction sa) {
            bool newState = !sa.getState().getBoolean();
            sa.setState(new GVariant(newState));
            vte.searchSetWrapAround(newState);
        }, null, gsGeneral.getValue(SETTINGS_SEARCH_DEFAULT_WRAP_AROUND));

        updateActionsState();
        insertActionGroup(ACTION_SEARCH_PREFIX, sagSearch);
    }

    Popover createPopover() {
        Menu model = new Menu();
        model.append(_("Match case"), getActionDetailedName(ACTION_SEARCH_PREFIX, ACTION_SEARCH_MATCH_CASE));
        model.append(_("Match entire word only"), getActionDetailedName(ACTION_SEARCH_PREFIX, ACTION_SEARCH_ENTIRE_WORD_ONLY));
        model.append(_("Wrap around"), getActionDetailedName(ACTION_SEARCH_PREFIX, ACTION_SEARCH_WRAP_AROUND));
        model.append(_("Match as regular expression"), getActionDetailedName(ACTION_SEARCH_PREFIX, ACTION_SEARCH_MATCH_REGEX));

        // GTK4: gtk_popover_new_from_model is gone. PopoverMenu.newFromModel
        // takes only the model — the widget association is made by
        // MenuButton.setPopover, which the caller already does.
        return PopoverMenu.newFromModel(model);
    }

    void updateActionsState()
    {
        auto action = cast(SimpleAction) sagSearch.lookupAction(ACTION_SEARCH_MATCH_REGEX);
        bool alwaysUseRegex = gsSettings.getBoolean(SETTINGS_ALWAYS_USE_REGEX_IN_SEARCH);
        action.setEnabled(!alwaysUseRegex);
        action.setState(new GVariant(alwaysUseRegex));
        matchAsRegex = alwaysUseRegex;
    }

    void setTerminalSearchCriteria() {
        string text = seSearch.getText();
        if (text.length == 0) {
            vte.searchSetRegex(null, 0);
            return;
        }

        if (!matchAsRegex)
            text = GRegex.escapeString(text);
        if (entireWordOnly)
            text = format("\\b%s\\b", text);

        try {
            uint flags = PCRE2Flags.UTF | PCRE2Flags.MULTILINE | PCRE2Flags.NO_UTF_CHECK;
            if (!matchCase) {
                flags |= PCRE2Flags.CASELESS;
            }
            trace("Setting VTE.Regex for pattern %s", text);
            vte.searchSetRegex(VRegex.newForSearch(text, flags), 0);
            seSearch.getStyleContext().removeClass("error");
        } catch (ErrorWrap ge) {
            string message = format(_("Search '%s' is not a valid regex\n%s"), text, ge.msg);
            seSearch.getStyleContext().addClass("error");
            error(message);
            error(ge.msg);
        }
    }

public:

    this(VTE vte, ActionGroup terminalActions) {
        super();

        this.vte = vte;
        this.terminalActions = terminalActions;

        gsSettings = new GSettings(SETTINGS_ID);
        createUI();
        gsSettings.connectChanged(null, delegate(string key, GSettings settings) {
            if (key == SETTINGS_ALWAYS_USE_REGEX_IN_SEARCH)
                updateActionsState();
        });

        this.connectDestroy(delegate() {
            this.vte = null;
            this.terminalActions = null;
        });
        // GTK4: focus-in/out-event -> EventControllerFocus enter/leave. The
        // callback receives the controller, not the widget, so the widget the
        // events describe is captured from the enclosing scope instead.
        // (The GtkD original connected addOnFocusIn twice — an evident
        // copy-paste bug; focus-out belongs on the leave signal.)
        EventControllerFocus focusController = new EventControllerFocus();
        focusController.connectEnter(delegate void(EventControllerFocus c) {
            onSearchEntryFocusIn.emit(seSearch);
        });
        focusController.connectLeave(delegate void(EventControllerFocus c) {
            onSearchEntryFocusOut.emit(seSearch);
        });
        seSearch.addController(focusController);
    }

    void focusSearchEntry() {
        seSearch.grabFocus();
    }

    bool hasSearchEntryFocus() {
        return seSearch.hasFocus();
    }

    bool isSearchEntryFocus() {
        return seSearch.isFocus();
    }

    GenericEvent!(Widget) onSearchEntryFocusIn;

    GenericEvent!(Widget) onSearchEntryFocusOut;
}
