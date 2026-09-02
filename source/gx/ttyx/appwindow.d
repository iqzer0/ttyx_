/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/appwindow.d. GtkD -> giD notes:
 *  - ApplicationWindow subclass: giD binds this(gtk.application.Application)
 *    directly, super(application) carries over. Implements the GActionMap/
 *    GActionGroup D interfaces, so registerAction[WithSettings],
 *    insertActionGroup and changeActionState work unchanged.
 *  - addOn* -> connect*; ConnectFlags.AFTER -> Yes.After; EVERY delegate
 *    literal parameter is named (giD template inference requirement).
 *  - Typed event structs replace generic gdk.Event: delete-event keeps
 *    gdk.event.Event, focus in/out get gdk.event_focus.EventFocus,
 *    window-state gets gdk.event_window_state.EventWindowState (.newWindowState
 *    field, no pointer), scroll gets gdk.event_scroll.EventScroll (.direction
 *    field replaces getScrollDirection), button press gets
 *    gdk.event_button.EventButton (.type/.button fields), key press gets
 *    gdk.event_key.EventKey (.keyval field replaces out-param getKeyval).
 *  - size-allocate delegate receives gtk.types.Allocation (alias of the
 *    gdk.rectangle.Rectangle value struct) instead of GdkRectangle*.
 *  - GdkRectangle -> gdk.rectangle.Rectangle value struct; GdkWindowState ->
 *    gdk.types.WindowState; GdkGravity -> gdk.types.Gravity; GdkModifierType
 *    -> gdk.types.ModifierType; keysyms GdkKeysyms.GDK_* -> gdk.types.KEY_*;
 *    gsSettings.setInt of a WindowState needs an explicit cast(int).
 *  - cairo is procedural in giD: ImageSurface -> cairo.surface.Surface
 *    (matches the ported gx.gtk.cairo renderImage signatures); surfaces are
 *    GC-managed so the explicit isBGImage.destroy() calls are gone (cache
 *    invalidation just drops the reference); cairo_font_slant_t/
 *    cairo_font_weight_t/cairo_filter_t/cairo_text_extents_t ->
 *    cairo.types.FontSlant/FontWeight/Filter/TextExtents;
 *    cr.textExtents(text, &extents) -> out-param textExtents(text, extents);
 *    draw callbacks are bool(Context, Widget) (no Scoped!Context).
 *  - Icon buttons/images: new Button(icon, IconSize)/new Image(icon, IconSize)
 *    -> Button.newFromIconName/Image.newFromIconName; IconSize PascalCase.
 *  - new Popover(parent, model) -> Popover.newFromModel(parent, model).
 *  - Session-rename MessageDialog: GtkD's flags ctor is unbound; USE_HEADER_BAR
 *    and ButtonsType are construct-only -> MessageDialog.builder()
 *    .useHeaderBar(1).buttons(ButtonsType.OkCancel).build() + messageType/text
 *    property setters; getMessageArea() returns Widget -> cast to Box.
 *  - FileChooserDialog: the GtkD convenience ctor (varargs
 *    gtk_file_chooser_dialog_new) is unbound -> raw
 *    g_object_new(FileChooserDialog._getGType(), null) + this(ptr, No.Take),
 *    then setAction/setTitle/addButton. Button/response mapping preserved from
 *    GtkD's default: first button -> ResponseType.Ok, second ->
 *    ResponseType.Cancel. getFilenames() returns string[] directly (no
 *    ListSG.toArray).
 *  - gobject.Signals.handlerBlock/Unblock -> free functions
 *    gobject.global.signalHandlerBlock/signalHandlerUnblock.
 *  - gtkc.glib g_source_remove -> glib.source.Source.remove(tag).
 *  - gtk.Version.checkVersion -> gtk.global.checkVersion (same null-on-ok
 *    contract).
 *  - getWindowStruct() identity comparisons -> _cPtr comparisons;
 *    window.listToplevels() (ListG) -> static gtk.window.Window.listToplevels()
 *    returning Widget[].
 *  - GSettings.addOnChanged(dg) -> connectChanged(null, dg) (detail comes
 *    first, null = all keys).
 *  - hide()/present() overrides must be `override ... nothrow` (giD methods
 *    are nothrow); their bodies read the _quake field directly instead of
 *    calling isQuake().
 *  - Fix: tbSideBar.addEvents(EventType.SCROLL) passed a GdkEventType constant
 *    (31) where an event *mask* is expected; the port passes
 *    cast(int) EventMask.ScrollMask, which is what the code intended.
 *  - Preserved quirk: SessionTabLabel's Return-key handler commits the label's
 *    current `text` property (not the entry text) exactly like the GtkD
 *    original; the real commit happens in the focus-out handler.
 *  - Dropped unused GtkD imports (vte.Pty/vte.Terminal, gdkpixbuf.Pixbuf,
 *    glib.ListG/ListSG/Util/GException, gobject.Value, and the gtk widgets
 *    this module never instantiates).
 */
module gx.ttyx.appwindow;

import core.memory;

import std.algorithm;
import std.conv;
import std.experimental.logger;
import std.file;
import std.math;
import std.format;
import std.json;
import std.path;
import std.string;
import std.typecons : No, Yes;
import std.uuid;

import cairo.context : Context;
import cairo.surface : Surface;
import cairo.types : Filter, FontSlant, FontWeight, TextExtents;

import gdk.event : Event;
import gdk.toplevel : Toplevel;
import gdk.rectangle : Rectangle;
import gdk.rgba : RGBA;
import gdk.display : Display;
import gdk.monitor : MonitorWrap;
import gdk.types : Gravity, KEY_Escape, KEY_Return, ModifierType, ToplevelState;

import gid.basictypes : gulong;
import gid.gid : No, Yes;

import gio.file : File;
import gio.list_model : ListModel;
import gio.menu : GMenu = Menu;
import gio.menu_item : GMenuItem = MenuItem;
import gio.notification : Notification;
import gio.settings : GSettings = Settings;
import gio.simple_action : SimpleAction;
import gio.simple_action_group : SimpleActionGroup;

import glib.source : Source;
import glib.variant : GVariant = Variant;

import gobject.c.functions : g_object_new;
import gobject.global : signalHandlerBlock, signalHandlerUnblock;
import gobject.object : ObjectWrap;
import gobject.param_spec : ParamSpec;

import gtk.application : Application;
import gtk.application_window : ApplicationWindow;
import gtk.aspect_frame : AspectFrame;
import gtk.box : Box;
import gtk.button : Button;
import gtk.dialog : Dialog;
import gtk.drawing_area : DrawingArea;
import gtk.entry : Entry;
import gtk.event_controller_focus : EventControllerFocus;
import gtk.event_controller_key : EventControllerKey;
import gtk.event_controller_scroll : EventControllerScroll;
import gtk.gesture_click : GestureClick;
import gtk.file_chooser_dialog : FileChooserDialog;
import gtk.file_filter : FileFilter;
import gtk.global : checkVersion;
import gtk.header_bar : HeaderBar;
import gtk.image : Image;
import gtk.label : Label;
import gtk.menu_button : MenuButton;
import gtk.message_dialog : MessageDialog;
import gtk.notebook : Notebook;
import gtk.overlay : Overlay;
import gtk.popover : Popover;
import gtk.popover_menu : PopoverMenu;
import gtk.stack : Stack;
import gtk.toggle_button : ToggleButton;
import gtk.types : Allocation, ButtonsType, EventControllerScrollFlags, EventSequenceState, FileChooserAction,
    MessageType, Orientation, PositionType, ResponseType, PropagationPhase;
import gtk.widget : Widget;
import gtk.window : Window;
import gtk.window_group : WindowGroup;

import pango.types : EllipsizeMode;

import gx.gtk.actions;
import gx.gtk.cairo;
import gx.gtk.widgetimage;
import gx.gtk.dialog;
import gx.gtk.threads;
import gx.gtk.util;
import gx.gtk.x11 : setSkipTaskbarAndPager;
import gx.i18n.l10n;

import gx.ttyx.application;
import gx.ttyx.closedialog;
import gx.ttyx.cmdparams;
import gx.ttyx.common;
import gx.ttyx.constants;
import gx.ttyx.customtitle;
import gx.ttyx.prefeditor.titleeditor;
import gx.ttyx.preferences;
import gx.ttyx.session;
import gx.ttyx.sidebar;

/**
 * The GTK Application Window for Tilix. It is responsible for
 * managing sessions which are held as pages in a GTK Notebook. All
 * session actions are created and managed here but against the session
 * prefix rather then the win prefix which is typically used for
 * a AplicationWindow.
 */
class AppWindow : ApplicationWindow, IIdentifiable {

public:
    //Public Actions
    enum ACTION_PREFIX = "session";
    enum ACTION_SESSION_ADD_RIGHT = "add-right";
    enum ACTION_SESSION_ADD_DOWN = "add-down";
    enum ACTION_SESSION_ADD_AUTO = "add-auto";

private:

    // GTK CSS Style to flag attention
    enum CSS_CLASS_NEEDS_ATTENTION = "needs-attention";

    // Private Actions
    enum ACTION_SESSION_CLOSE = "close";
    enum ACTION_SESSION_NAME = "name";
    enum ACTION_SESSION_NEXT_TERMINAL = "switch-to-next-terminal";
    enum ACTION_SESSION_PREV_TERMINAL = "switch-to-previous-terminal";
    enum ACTION_SESSION_TERMINAL_X = "switch-to-terminal-";
    enum ACTION_RESIZE_TERMINAL_DIRECTION = "resize-terminal-";
    enum ACTION_SESSION_SAVE = "save";
    enum ACTION_SESSION_SAVE_AS = "save-as";
    enum ACTION_SESSION_OPEN = "open";
    enum ACTION_SESSION_SYNC_INPUT = "synchronize-input";
    enum ACTION_WIN_SESSION_X = "switch-to-session-";
    enum ACTION_WIN_SIDEBAR = "view-sidebar";
    enum ACTION_WIN_SESSIONSWITCHER = "view-session-switcher";
    enum ACTION_WIN_NEXT_SESSION = "switch-to-next-session";
    enum ACTION_WIN_PREVIOUS_SESSION = "switch-to-previous-session";
    enum ACTION_WIN_FULLSCREEN = "fullscreen";
    enum ACTION_SESSION_REORDER_PREVIOUS = "reorder-previous-session";
    enum ACTION_SESSION_REORDER_NEXT = "reorder-next-session";

    string _windowUUID;

    bool useTabs = false;

    Notebook nb;
    HeaderBar hb;
    SideBar sb;
    ToggleButton tbSideBar;
    DrawingArea badgeArea;
    ToggleButton tbFind;
    CustomTitle cTitle;
    // Put windows in separate groups
    WindowGroup group;

    SimpleActionGroup sessionActions;
    MenuButton mbSessionActions;
    SimpleAction saSyncInput;
    SimpleAction saViewSideBar;
    SimpleAction saSessionAddRight;
    SimpleAction saSessionAddDown;
    SimpleAction saSessionAddAuto;

    Label lblSideBar;

    SessionNotification[string] sessionNotifications;

    GSettings gsSettings;

    // Cached rendered background image
    Surface isBGImage;
    // Track size changes, only invalidate if size really changed
    int lastWidth, lastHeight;

    // True if window is in quake mode
    bool _quake;

    // True if window is being destroyed
    bool _destroyed;

    string[] recentSessionFiles;

    // The user overridden application title, specific to the window only
    string _overrideTitle;

    // Tells the window when closing not to prompt the user, just close
    bool _noPrompt = false;

    // Handler of the Find button "toggled" signal
    gulong _tbFindToggledId;

    // Preference for the Window Style, i.e normal,disable-csd,disable-csd-hide-toolbar,borderless
    size_t windowStyle = 0;

    enum DialogPath {
        SAVE_SESSION,
        LOAD_SESSION
    }

    // Save file dialog paths between invocations
    string[DialogPath] dialogPaths;

    uint timeoutID;

    bool isCSDDisabled() {
        return windowStyle > 0;
    }

    bool hideToolbar() {
        return (isQuake() && gsSettings.getBoolean(SETTINGS_QUAKE_HIDE_HEADERBAR_KEY)) || windowStyle > 1;
    }

    /**
     * Create the user interface
     */
    void createUI() {
        GSettings gsShortcuts = new GSettings(SETTINGS_KEY_BINDINGS_ID);

        createWindowActions(gsShortcuts);
        createSessionActions(gsShortcuts);
        createDelegatedTerminalActions(gsShortcuts);

        //Notebook
        nb = new Notebook();
        nb.setShowTabs(false);
        nb.setShowBorder(false);
        if (useTabs) {
            nb.getStyleContext().addClass("ttyx-background");
            nb.setScrollable(true);
            nb.setGroupName("ttyx");
            nb.connectCreateWindow(&onCreateWindow);
            nb.setCanFocus(false);
        }
        nb.connectPageAdded(&onPageAdded);
        nb.connectPageRemoved(&onPageRemoved);
        nb.connectSwitchPage(delegate(Widget page, uint pageNum, Notebook notebook) {
            trace("Switched Sessions");
            Session session = cast(Session) page;
            //Remove any sessions associated with current page
            sessionNotifications.remove(session.uuid);
            updateTitle();
            updateUIState();
            session.notifyActive();
            session.focusRestore();
            saSyncInput.setState(new GVariant(session.synchronizeInput));
            if (!useTabs && sb.getChildRevealed() && getCurrentSession() !is null) {
                sb.selectSession(getCurrentSession().uuid);
            }
            if (useTabs) {
                threadsAddIdleDelegate(delegate() {
                    // Delay focus restore. This runs deferred, so the session
                    // may have been closed between the page switch and the
                    // idle callback — getTabLabel then returns null. The
                    // result was dereferenced unguarded (switch tabs, close
                    // quickly); every other getTabLabel site null-checks.
                    trace("Delayed focus restore");
                    if (nb.pageNum(session) < 0) return false;
                    session.focusRestore();
                    SessionTabLabel label = cast(SessionTabLabel) nb.getTabLabel(session);
                    if (label !is null) label.showNewOutput(false);
                    return false;
                });
            }
            tilix.withdrawNotification(session.uuid);
        }, Yes.After);
        if (!useTabs) {
            sb = new SideBar();
            sb.onSelected.connect(&onSessionSelected);
            sb.onClose.connect(&onUserSessionClose);
            sb.onRequestReorder.connect(&onSessionReorder);
            sb.onSessionDetach.connect(&onSessionDetach);
            sb.onIsActionAllowed.connect(&onIsActionAllowed);
            // GTK4 removed gtk_grab_add, which the GTK3 sidebar used so that a
            // click anywhere outside it dismissed it. A capture-phase gesture on
            // the window sees every press first and does the same; presses on
            // the sidebar's own toggle button are left to the button, which
            // would otherwise toggle it straight back.
            GestureClick outsideClick = new GestureClick();
            outsideClick.setButton(0);
            outsideClick.setPropagationPhase(PropagationPhase.Capture);
            outsideClick.connectPressed(delegate void(int nPress, double x, double y, GestureClick g) {
                if (sb is null || !sb.getChildRevealed()) return;
                double lx, ly;
                if (translateCoordinates(sb, x, y, lx, ly) && sb.contains(lx, ly)) return;
                if (tbSideBar !is null && translateCoordinates(tbSideBar, x, y, lx, ly) && tbSideBar.contains(lx, ly)) return;
                saViewSideBar.activate(null);
            });
            addController(outsideClick);
        } else {
            updateTabPosition();
        }

        Overlay overlay;
        if (!useTabs) {
            overlay = new Overlay();
            overlay.setChild(nb);
            overlay.addOverlay(sb);
        }

        //Could be a Box or a Headerbar depending on value of disable_csd
        hb = createHeaderBar();

        if (isQuake() || isCSDDisabled()) {
            hb.getStyleContext().addClass("ttyx-embedded-headerbar");
            Box box = new Box(Orientation.Vertical, 0);
            box.append(hb);
            if (overlay !is null) box.append(overlay);
            else box.append(nb);
            if (isQuake()) {
                box.getStyleContext().addClass("ttyx-quake-frame");
            }
            setChild(box);
            hb.setVisible(!hideToolbar());
        } else {
            this.setTitlebar(hb);
            hb.setShowTitleButtons(true);
            // GTK4: a HeaderBar has no title of its own — it shows the window
            // title unless a title widget is set (createHeaderBar sets one).
            if (overlay !is null) setChild(overlay);
            else setChild(nb);
        }
    }

    HeaderBar createHeaderBar() {
        //New tab button
        Button btnNew;
        if (useTabs) {
            btnNew = Button.newFromIconName("tab-new-symbolic");
        } else {
            btnNew = Button.newFromIconName("list-add-symbolic");
        }
        btnNew.setFocusOnClick(false);
        btnNew.connectClicked(delegate(Button button) {
            createSession();
        });
        btnNew.setTooltipText(_("Create a new session"));

        Box bSessionButtons;

        if (!useTabs) {
            //View sessions button
            tbSideBar = new ToggleButton();
            tbSideBar.getStyleContext().addClass("session-sidebar-button");
            Box b = new Box(Orientation.Horizontal, 6);
            lblSideBar = new Label("1 / 1");
            Image img = Image.newFromIconName("pan-down-symbolic");
            b.append(lblSideBar);
            b.append(img);
            // GTK4: widgets have no draw signal. The notification badge is
            // painted by a transparent DrawingArea laid over the button's
            // content and refreshed with badgeArea.queueDraw() (WP4).
            Overlay badgeOverlay = new Overlay();
            badgeOverlay.setChild(b);
            badgeArea = new DrawingArea();
            badgeArea.setCanTarget(false);
            badgeArea.setDrawFunc(delegate(DrawingArea da, Context cr, int width, int height) {
                drawSideBarBadge(cr, tbSideBar, width, height);
            });
            badgeOverlay.addOverlay(badgeArea);
            tbSideBar.setChild(badgeOverlay);
            tbSideBar.setTooltipText(_("View session sidebar"));
            tbSideBar.setFocusOnClick(false);
            tbSideBar.setActionName(getActionDetailedName("win", ACTION_WIN_SIDEBAR));
            // GTK4: scroll-event -> EventControllerScroll. There is no direction
            // enum any more; the callback receives signed deltas, so "up" is a
            // negative dy. Vertical-only, since that is all this ever handled.
            EventControllerScroll sidebarScroll = new EventControllerScroll(EventControllerScrollFlags.Vertical);
            sidebarScroll.connectScroll(delegate bool(double dx, double dy, EventControllerScroll c) {
                if (dy < 0) {
                    focusPreviousSession();
                } else if (dy > 0) {
                    focusNextSession();
                }
                return false;
            });
            tbSideBar.addController(sidebarScroll);
            // GTK4: no event masks — the EventControllerScroll below receives
            // scroll events without one.

            bSessionButtons = new Box(Orientation.Horizontal, 0);
            bSessionButtons.getStyleContext().addClass("linked");
            btnNew.getStyleContext().addClass("session-new-button");
            bSessionButtons.append(tbSideBar);
            bSessionButtons.append(btnNew);
        }

        //Session Actions
        mbSessionActions = new MenuButton();
        mbSessionActions.setFocusOnClick(false);
        Image iHamburger = Image.newFromIconName("open-menu-symbolic");
        mbSessionActions.setChild(iHamburger);
        mbSessionActions.setPopover(createPopover(mbSessionActions));

        Button btnAddHorizontal = Button.newFromIconName("ttyx-add-horizontal-symbolic");
        btnAddHorizontal.setDetailedActionName(getActionDetailedName(ACTION_PREFIX, ACTION_SESSION_ADD_RIGHT));
        btnAddHorizontal.setFocusOnClick(false);
        btnAddHorizontal.setTooltipText(_("Add terminal right"));

        Button btnAddVertical = Button.newFromIconName("ttyx-add-vertical-symbolic");
        btnAddVertical.setDetailedActionName(getActionDetailedName(ACTION_PREFIX, ACTION_SESSION_ADD_DOWN));
        btnAddVertical.setTooltipText(_("Add terminal down"));
        btnAddVertical.setFocusOnClick(false);

        // Add find button
        tbFind = new ToggleButton();
        tbFind.setIconName("edit-find-symbolic");
        tbFind.setTooltipText(_("Find text in terminal"));
        tbFind.setFocusOnClick(false);
        _tbFindToggledId = tbFind.connectToggled(delegate(ToggleButton tb) {
            if (getCurrentSession() !is null) {
                getCurrentSession().toggleTerminalFind();
            }
        });

        //Header Bar
        HeaderBar header = new HeaderBar();
        if (!isCSDDisabled()) {
            header.setTitleWidget(createCustomTitle());
        }
        if (useTabs) {
            header.packStart(btnNew);
        } else {
            header.packStart(bSessionButtons);
        }
        header.packStart(btnAddHorizontal);
        header.packStart(btnAddVertical);
        header.packEnd(mbSessionActions);
        header.packEnd(tbFind);
        return header;
    }

    void onCustomTitleChange(string title) {
            _overrideTitle = title;
            updateTitle;
    }

    void onCustomTitleCancelEdit() {
        if (getCurrentSession() !is null) {
            getCurrentSession().focusRestore();
        }
    }

    void onCustomTitleEdit(CumulativeResult!string result) {
        if (_overrideTitle.length > 0) {
            result.addResult(_overrideTitle);
        } else {
            result.addResult(gsSettings.getString(SETTINGS_APP_TITLE_KEY));
        }
    }

    Widget createCustomTitle() {
        cTitle = new CustomTitle();
        cTitle.onTitleChange.connect(&onCustomTitleChange);
        cTitle.onCancelEdit.connect(&onCustomTitleCancelEdit);
        cTitle.onEdit.connect(&onCustomTitleEdit);
        return cTitle;
    }

    /**
     * Create Window actions
     */
    void createWindowActions(GSettings gsShortcuts) {
        debug(GC) {
            registerAction(this, "win", "gc", null, delegate(GVariant value, SimpleAction sa) {
                trace("Performing collection");
                core.memory.GC.collect();
                core.memory.GC.minimize();
            });
        }

        //Create Switch to Session (0..9) actions
        //Can't use :: action targets for this since action name needs to be preferences
        for (int i = 0; i <= 9; i++) {
            registerActionWithSettings(this, "win", ACTION_WIN_SESSION_X ~ to!string(i), gsShortcuts, delegate(GVariant value, SimpleAction sa) {
                int index = to!int(sa.getName()[$ - 1 .. $]);
                if (index == 0)
                    index = 9;
                else
                    index--;
                if (index <= nb.getNPages()) {
                    nb.setCurrentPage(index);
                }
            });
        }

        registerActionWithSettings(this, "win", ACTION_WIN_NEXT_SESSION, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            focusNextSession();
        });
        registerActionWithSettings(this, "win", ACTION_WIN_PREVIOUS_SESSION, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            focusPreviousSession();
        });

        registerActionWithSettings(this, "win", ACTION_SESSION_REORDER_PREVIOUS, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            reorderCurrentSessionRelative(-1);
        });

        registerActionWithSettings(this, "win", ACTION_SESSION_REORDER_NEXT, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            reorderCurrentSessionRelative(1);
        });

        registerActionWithSettings(this, "win", ACTION_WIN_FULLSCREEN, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            trace("Setting fullscreen");
            // GTK4: GdkWindow is gone; the window exposes fullscreened directly.
            if (fullscreened) {
                unfullscreen();
                sa.setState(new GVariant(false));
            } else {
                fullscreen();
                sa.setState(new GVariant(true));
            }
        }, null, new GVariant(false));

        if (!useTabs) {
            saViewSideBar = registerActionWithSettings(this, "win", ACTION_WIN_SIDEBAR, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
                bool newState = !sa.getState().getBoolean();
                trace("Sidebar action activated " ~ to!string(newState));
                // Note that populate sessions does some weird shit with event
                // handling, don't trigger UI activity until after it is done
                // See comments in gx.gtk.cairo.getWidgetImage
                if (newState) {
                    Session current = getCurrentSession();
                    if (current is null) return;
                    sb.populateSessions(getSessions(), current.uuid, sessionNotifications, nb.getAllocatedWidth(), nb.getAllocatedHeight());
                    sb.setVisible(true);
                }
                sb.setRevealChild(newState);
                sa.setState(new GVariant(newState));
                tbSideBar.setActive(newState);
                if (!newState) {
                    //Hiding session, restore focus
                    Session session = getCurrentSession();
                    if (session !is null) {
                        session.focusRestore();
                    }
                }
            }, null, new GVariant(false));
        }
    }

    /**
     * Create all the session actions and corresponding actions
     */
    void createSessionActions(GSettings gsShortcuts) {
        sessionActions = new SimpleActionGroup();

        //Create Switch to Terminal (0..9) actions
        //Can't use :: action targets for this since action name needs to be preferences
        for (int i = 0; i <= 9; i++) {
            registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_TERMINAL_X ~ to!string(i), gsShortcuts, delegate(GVariant value, SimpleAction sa) {
                Session session = getCurrentSession();
                if (session !is null) {
                    auto terminalID = to!size_t(sa.getName()[$ - 1 .. $]);
                    if (terminalID == 0)
                        terminalID = 10;
                    session.focusTerminal(terminalID);
                }
            });
        }

        //Create directional Switch to Terminal actions
        const string[] directions = ["up", "down", "left", "right"];
        foreach (string direction; directions) {
            registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_TERMINAL_X ~ direction, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
                Session session = getCurrentSession();
                if (session !is null) {
                    string actionName = sa.getName();
                    string direction = actionName[lastIndexOf(actionName, '-') + 1 .. $];
                    session.focusDirection(direction);
                }
            });
        }

        //Create directional Resize to Terminal actions
        foreach (string direction; directions) {
            registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_RESIZE_TERMINAL_DIRECTION ~ direction, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
                Session session = getCurrentSession();
                if (session !is null) {
                    string actionName = sa.getName();
                    string direction = actionName[lastIndexOf(actionName, '-') + 1 .. $];
                    session.resizeTerminal(direction);
                }
            });
        }

        //Add Terminal Actions
        saSessionAddRight = registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_ADD_RIGHT, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            Session session = getCurrentSession();
            if (session !is null && !session.maximized)
                session.addTerminal(Orientation.Horizontal);
        });
        saSessionAddDown = registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_ADD_DOWN, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            Session session = getCurrentSession();
            if (session !is null && !session.maximized)
                session.addTerminal(Orientation.Vertical);
        });
        saSessionAddAuto = registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_ADD_AUTO, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            Session session = getCurrentSession();
            if (session !is null && !session.maximized)
                session.addAutoOrientedTerminal();
        });

        /* TODO - GTK doesn't support settings Tab for accelerators, need to look into this more */
        registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_NEXT_TERMINAL, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            Session session = getCurrentSession();
            if (session !is null)
                session.focusNext();
        });
        registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_PREV_TERMINAL, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            Session session = getCurrentSession();
            if (session !is null)
                session.focusPrevious();
        });

        //Close Session
        registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_CLOSE, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            Session session = getCurrentSession();
            if (session is null) return;
            CumulativeResult!bool results = new CumulativeResult!bool();
            onUserSessionClose(session.uuid, results);
        });

        //Load Session
        registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_OPEN, gsShortcuts, delegate(GVariant value, SimpleAction sa) { loadSession(); });

        //Save Session
        registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_SAVE, gsShortcuts, delegate(GVariant value, SimpleAction sa) { saveSession(false); });

        //Save As Session
        registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_SAVE_AS, gsShortcuts, delegate(GVariant value, SimpleAction sa) { saveSession(true); });

        //Change name of session
        registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_NAME, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            Session session = getCurrentSession();
            if (session is null) return;

            // GtkD's MessageDialog flags ctor is unbound in giD; use-header-bar
            // and buttons are construct-only -> builder pattern.
            MessageDialog dialog = MessageDialog.builder()
                .useHeaderBar(1)
                .buttons(ButtonsType.OkCancel)
                .build();
            dialog.messageType = MessageType.Question;
            dialog.text = _("Enter a new name for the session");
            dialog.setModal(true);
            dialog.setTransientFor(this);
            dialog.setTitle( _("Change Session Name"));
            Entry entry = new Entry();
            entry.setText(session.name);
            entry.setWidthChars(30);
            entry.connectActivate(delegate(Entry e) {
                dialog.response(ResponseType.Ok);
            });
            // Note check for Wayland below otherwise popover will clip
            if (isWayland(this) && gtkAtLeast(3, 16, 0)) {
                (cast(Box) dialog.getMessageArea()).append(createTitleEditHelper(entry, TitleEditScope.SESSION));
            } else {
                (cast(Box) dialog.getMessageArea()).append(entry);
            }
            dialog.setDefaultResponse(ResponseType.Ok);
            dialog.connectResponse(delegate(int response, Dialog d) {
                if (response == ResponseType.Ok && entry.getText().length > 0) {
                    session.name = entry.getText();
                    updateTitle();
                }
                dialog.hide();
                dialog.destroy();
            });
            dialog.connectClose(delegate(Dialog dlg) {
                dlg.destroy();
            });
            dialog.present();
        });

        //Synchronize Input
        saSyncInput = registerActionWithSettings(sessionActions, ACTION_PREFIX, ACTION_SESSION_SYNC_INPUT, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
            Session session = getCurrentSession();
            if (session is null) return;
            bool newState = !sa.getState().getBoolean();
            sa.setState(new GVariant(newState));
            session.synchronizeInput = newState;
            mbSessionActions.setActive(false);
        }, null, new GVariant(false));

        insertActionGroup(ACTION_PREFIX, sessionActions);
    }

    /**
     * Create actions that will be delegated to the active terminal.
     * This is required due to a bug in GTK+ < 3.5.15.
     *
     * https://bugzilla.gnome.org/show_bug.cgi?id=740682
     * https://github.com/gnunn1/tilix/issues/342
     */
    void createDelegatedTerminalActions(GSettings gsShortcuts) {
        import gx.ttyx.terminal.terminal : Terminal;

        if (!gtkAtLeast(3, 15, 3)) {
            SimpleActionGroup terminalActions = new SimpleActionGroup();

            foreach (string action; gsShortcuts.listKeys) {
                if (action.startsWith("terminal-")) {
                    logf(LogLevel.trace, "Registering terminal shortcut delegation for action %s", action[9..$]);
                    registerActionWithSettings(terminalActions, "terminal", action[9..$], gsShortcuts, delegate(GVariant va, SimpleAction sa) {
                        string terminalUUID = getActiveTerminalUUID();
                        logf(LogLevel.trace, "Delegating terminal action '%s' to terminal '%s'", sa.getName(), terminalUUID);
                        auto terminal = cast(Terminal) findWidgetForUUID(terminalUUID);
                        if (terminal !is null) {
                            terminal.triggerAction(sa.getName(), va);
                        }
                    });
                }
            }

            insertActionGroup("terminal", terminalActions);
        }
    }

    /**
     * Creates the session action popover
     */
    Popover createPopover(Widget parent) {
        GMenu model = new GMenu();

        GMenu mWindowSection = new GMenu();
        mWindowSection.appendItem(new GMenuItem(_("New Window"), getActionDetailedName(ACTION_PREFIX_APP, ACTION_NEW_WINDOW)));
        model.appendSection(null, mWindowSection);

        GMenu mFileSection = new GMenu();
        mFileSection.appendItem(new GMenuItem(_("Open…"), getActionDetailedName(ACTION_PREFIX, ACTION_SESSION_OPEN)));
        mFileSection.appendItem(new GMenuItem(_("Save"), getActionDetailedName(ACTION_PREFIX, ACTION_SESSION_SAVE)));
        mFileSection.appendItem(new GMenuItem(_("Save As…"), getActionDetailedName(ACTION_PREFIX, ACTION_SESSION_SAVE_AS)));
// Remove this since both tabs and sidebar have a close button already
//        mFileSection.appendItem(new GMenuItem(_("Close Session"), getActionDetailedName(ACTION_PREFIX, ACTION_SESSION_CLOSE)));
        model.appendSection(null, mFileSection);

        GMenu mSessionSection = new GMenu();
        mSessionSection.appendItem(new GMenuItem(_("Name…"), getActionDetailedName(ACTION_PREFIX, ACTION_SESSION_NAME)));
        mSessionSection.appendItem(new GMenuItem(_("Synchronize Input"), getActionDetailedName(ACTION_PREFIX, ACTION_SESSION_SYNC_INPUT)));
        model.appendSection(null, mSessionSection);

        GMenu mPrefSection = new GMenu();
        mPrefSection.appendItem(new GMenuItem(_("Preferences"), getActionDetailedName(ACTION_PREFIX_APP, ACTION_PREFERENCES)));
        mPrefSection.appendItem(new GMenuItem(_("Keyboard Shortcuts"), getActionDetailedName(ACTION_PREFIX_APP, ACTION_SHORTCUTS)));
        mPrefSection.append(_("About ttyx_"), getActionDetailedName(ACTION_PREFIX_APP, ACTION_ABOUT));


        model.appendSection(null, mPrefSection);

        debug(GC) {
            GMenu mDebugSection = new GMenu();
            mDebugSection.appendItem(new GMenuItem(_("GC"), getActionDetailedName("win", "gc")));
            model.appendSection(null, mDebugSection);
        }

        return PopoverMenu.newFromModel(model);
    }

    /**
     * This is required to get terminal transparency working
     */
    void updateVisual() {
        // GTK4: GdkVisual, gtk_widget_set_visual and set_app_paintable are all
        // gone. Windows are always alpha-capable and compositing is the
        // compositor's business, so there is nothing to select here. Kept as a
        // no-op so the two call sites need no change.
    }

    void createNewSession(string name, string profileUUID, string workingDir) {
        //Set firstRun based on whether any sessions currently exist, i.e. no pages in NoteBook
        Session session = new Session(name);
        session.initSession(profileUUID, workingDir, nb.getNPages() == 0);
        addSession(session);
    }

    void onPageAdded(Widget page, uint index, Notebook notebook) {
        trace("**** Adding page");

        Session session = cast(Session) page;

        session.onClose.connect(&onSessionClose);
        session.onAttach.connect(&onSessionAttach);
        session.onDetach.connect(&onSessionDetach);
        session.onStateChange.connect(&onSessionStateChange);
        session.onIsActionAllowed.connect(&onIsActionAllowed);
        session.onProcessNotification.connect(&onSessionProcessNotification);

        if (useTabs) {
            SessionTabLabel label = cast(SessionTabLabel) nb.getTabLabel(page);
            // Guarded to match closeSession/onCreateWindow, which null-check.
            if (label !is null) label.onCloseClicked.connect(&closeSession);
            nb.setTabReorderable(session, true);
            nb.setTabDetachable(session, true);
        }
    }

    void onPageRemoved(Widget page, uint index, Notebook notebook) {
        trace("**** Removing page");
        Session session = cast(Session) page;

        //remove event handlers
        session.onClose.disconnect(&onSessionClose);
        session.onAttach.disconnect(&onSessionAttach);
        session.onDetach.disconnect(&onSessionDetach);
        session.onStateChange.disconnect(&onSessionStateChange);
        session.onIsActionAllowed.disconnect(&onIsActionAllowed);
        session.onProcessNotification.disconnect(&onSessionProcessNotification);
    }

    void addSession(Session session) {
        int index;
        int insertPos = nb.getCurrentPage() + 1;
        if (!useTabs) {
            index = nb.insertPage(session, new Label(session.name), insertPos);
        } else {
            SessionTabLabel label = new SessionTabLabel(nb.getTabPos, session.displayName, session);
            index = nb.insertPage(session, label, insertPos);
        }
        nb.setCurrentPage(index);
        updateUIState();
    }

    void removeSession(Session session) {
        nb.removePage(nb.pageNum(session));
        updateUIState();
        //Close Window if there are no pages
        if (nb.getNPages() == 0) {
            if (gsSettings.getBoolean(SETTINGS_CLOSE_WITH_LAST_SESSION_KEY)) {
                trace("No more sessions, closing AppWindow");
                this.close();
            } else {
                createSession();
            }
        }
    }

    Session[] getSessions() {
        Session[] result = new Session[](nb.getNPages());
        for (int i = 0; i < nb.getNPages(); i++) {
            result[i] = getSession(i);
        }
        return result;
    }

    Session getSession(int i) {
        return cast(Session) nb.getNthPage(i);
    }

    /**
     * Used to handle cases where the user requests a session be closed
     */
    void onUserSessionClose(string sessionUUID, CumulativeResult!bool result) {
        if (_noPrompt) {
            result.addResult(false);
            return;
        }
        trace("Sidebar requested to close session " ~ sessionUUID);
        if (sessionUUID.length > 0) {
            Session session = getSession(sessionUUID);
            if (session !is null) {
                ProcessInformation pi = session.getProcessInformation();
                if (pi.children.length > 0) {
                    // GTK4: the prompt is asynchronous. If it needs the user,
                    // report "not closed" now and close from the callback; the
                    // sidebar refreshes through the normal close signals.
                    bool answered = false;
                    bool canClose = false;
                    bool deferred = false;
                    promptCanCloseProcesses(gsSettings, this, pi, delegate(bool ok) {
                        answered = true;
                        canClose = ok;
                        if (deferred && ok) {
                            Session s = getSession(sessionUUID);
                            if (s !is null) closeSession(s);
                        }
                    });
                    if (!answered) {
                        deferred = true;
                        result.addResult(false);
                        return;
                    }
                    if (!canClose) {
                        result.addResult(false);
                        return;
                    }
                }
                closeSession(session);
                result.addResult(true);
                return;
            }
        }
        result.addResult(false);
        return;
    }

    void closeSession(Session session) {
        //remove session reference from label
        if (useTabs) {
            SessionTabLabel label = cast(SessionTabLabel) nb.getTabLabel(session);
            if (label !is null) {
                label.onCloseClicked.disconnect(&closeSession);
                label.clear();
            }
        }
        bool isCurrentSession = (session == getCurrentSession());
        removeSession(session);
        // GTK4: no gtk_widget_destroy; removeSession() took it out of the
        // notebook, which drops GTK's reference to it.
        if (!isCurrentSession) {
            updateTitle();
            updateUIState();
        }
        trace("Session closed");
    }

    void onSessionClose(Session session) {
        closeSession(session);
    }

    void onFileSelected(string file) {
        if (file) {
            try {
                loadSession(file);
            }
            catch (SessionCreationException e) {
                removeRecentSessionFile(file);
                showErrorDialog(this, e.msg);
            }
        }
    }

    void onFileRemoved(string file) {
        removeRecentSessionFile(file);
    }

    void onOpenSelected(string uuid) {
        if (uuid) {
            activateSession(uuid);
        }
    }

    void reorderCurrentSessionRelative(int offset) {
        int page = nb.getCurrentPage();
        Session session = getCurrentSession();
        if (session is null) return;
        nb.reorderChild(session, page + offset);
        updateUIState();
    }

    void onSessionReorder(string sourceUUID, string targetUUID, bool after, CumulativeResult!bool result) {
        Session sourceSession = getSession(sourceUUID);
        Session targetSession = getSession(targetUUID);
        if (sourceSession is null || targetSession is null) {
            errorf("Unexpected error for DND, source or target page is null %s, %s", sourceUUID, targetUUID);
            result.addResult(false);
            return;
        }
        int index;
        if (!after) {
            index = nb.pageNum(targetSession);
        } else {
            index = nb.pageNum(targetSession);
            if (index == nb.getNPages() - 1) index = -1;
        }
        nb.reorderChild(sourceSession, index);
        result.addResult(true);
        updateUIState();
    }

    /**
     * Invoked by sidebar when user selects a session.
     */
    void onSessionSelected(string sessionUUID) {
        trace("Session selected " ~ sessionUUID);
        saViewSideBar.activate(null);
        if (sessionUUID.length > 0) {
            activateSession(sessionUUID);
        } else {
            Session session = getCurrentSession();
            if (session !is null) {
                getCurrentSession().focusRestore();
            }
        }
    }

    /**
     * Invoked by DND a session on a terminal
     */
    void onSessionAttach(string sessionUUID) {

        AppWindow getWindow(Session session) {

            Widget widget = session.getParent();
            while (widget !is null) {
                AppWindow result = cast(AppWindow) widget;
                if (result !is null)
                    return result;
                widget = widget.getParent();
            }
            return null;
        }

        Session session = getSession(sessionUUID);
        // If session isn't null it already belongs to this window, ignore
        if (session !is null) return;

        session = cast(Session) tilix.findWidgetForUUID(sessionUUID);
        if (session is null) {
            errorf("The session %s could not be located", sessionUUID);
            return;
        }

        AppWindow sourceWindow = getWindow(session);
        if (sourceWindow is null) {
            errorf("The AppWindow for session %s could not be located", sessionUUID);
            return;
        }

        sourceWindow.removeSession(session);
        addSession(session);
    }

    AppWindow cloneWindow() {
        AppWindow result = new AppWindow(tilix, useTabs);
        tilix.addAppWindow(result);

        result.setDefaultSize(getAllocatedWidth(), getAllocatedHeight());
        if (isMaximized) result.maximize();
        return result;
    }

    /*
     * Event occurs when tab is detached from notebook
     */
    Notebook onCreateWindow(Widget page, Notebook notebook) {
        trace("Detaching tab, create new window");
        SessionTabLabel label = cast(SessionTabLabel) nb.getTabLabel(page);
        if (label !is null) {
            label.onCloseClicked.disconnect(&closeSession);
        }
        AppWindow window = cloneWindow();
        // GTK4: no client-side window placement (WP5); the compositor places it.
        window.present();
        return window.nb;
    }

    void onSessionDetach(string sessionUUID, int x, int y) {
        Session session = getSession(sessionUUID);
        if (session !is null) {
            onSessionDetach(session, x, y, false);
        } else {
            errorf("Could not locate session for %s", sessionUUID);
        }
    }

    void onSessionDetach(Session session, int x, int y, bool isNewSession) {
        trace("Detaching session");
        //Detach an existing session, let's close it
        if (!isNewSession) {
            removeSession(session);
        }
        AppWindow window = cloneWindow();//new AppWindow(tilix);
        tilix.addAppWindow(window);
        window.initialize(session);
        // GTK4: no client-side window placement (WP5); the compositor places it.
        window.present();
    }

    void onSessionStateChange(Session session, SessionStateChange stateChange) {
        //tracef("State change received %d", stateChange);
        if (getCurrentSession() == session) {
            updateUIState();
            updateTitle();
            if (stateChange == SessionStateChange.TERMINAL_FOCUSED) {
                signalHandlerBlock(tbFind, _tbFindToggledId);
                tbFind.setActive(getActiveTerminal().isFindToggled());
                signalHandlerUnblock(tbFind, _tbFindToggledId);
            }
        }
        if (useTabs) {
            if (((stateChange == SessionStateChange.TERMINAL_TITLE) || (stateChange == SessionStateChange.SESSION_TITLE)) || (stateChange == SessionStateChange.TERMINAL_FOCUSED)) {
                SessionTabLabel label = cast(SessionTabLabel) nb.getTabLabel(session);
                if (label !is null) label.text=session.displayName;
            }
            if (getCurrentSession() != session && stateChange == SessionStateChange.TERMINAL_OUTPUT) {
                SessionTabLabel label = cast(SessionTabLabel) nb.getTabLabel(session);
                if (label !is null) label.showNewOutput(true);
            }
        }
    }

    void updateUIState() {
        if (!useTabs) {
            badgeArea.queueDraw();
        }
        //saCloseSession.setEnabled(nb.getNPages > 1);
        Session session = getCurrentSession();
        if (session !is null) {
            saSessionAddRight.setEnabled(!session.maximized);
            saSessionAddDown.setEnabled(!session.maximized);
        }
        if (useTabs) {
            nb.setShowTabs(nb.getNPages() > 1);
            for (int i = 0; i < nb.getNPages(); i++) {
                Session s = getSession(i);
                SessionTabLabel label = cast(SessionTabLabel) nb.getTabLabel(s);
                if (label is null) continue;
                if (s.uuid in sessionNotifications) {
                    label.updateNotifications(sessionNotifications[s.uuid].messages);
                } else {
                    label.clearNotifications();
                }
            }
        } else {
            lblSideBar.setLabel(format("%d / %d", nb.getCurrentPage() + 1, nb.getNPages()));
        }
    }

    void updateTitle() {
        string title = getDisplayTitle();
        if (!isCSDDisabled()) {
            // GTK4: without a custom title widget the HeaderBar shows the
            // window title set below.
            if (cTitle !is null) {
                cTitle.title = title;
            }
        }
        setTitle(title);
    }

    string getDisplayTitle() {
        string title = _overrideTitle.length == 0?gsSettings.getString(SETTINGS_APP_TITLE_KEY):_overrideTitle;
        title = title.replace(VARIABLE_APP_NAME, _(APPLICATION_NAME));
        Session session = getCurrentSession();
        if (session) {
            title = session.getDisplayText(title);
            title = title.replace(VARIABLE_SESSION_NUMBER, to!string(nb.getCurrentPage()+1));
            title = title.replace(VARIABLE_SESSION_COUNT, to!string(nb.getNPages()));
            title = title.replace(VARIABLE_SESSION_NAME, session.displayName);
        } else {
            title = title.replace(VARIABLE_SESSION_NUMBER, to!string(nb.getCurrentPage()+1));
            title = title.replace(VARIABLE_SESSION_COUNT, to!string(nb.getNPages()));
            title = title.replace(VARIABLE_SESSION_NAME, _("Default"));
        }
        return title;
    }

    void drawSideBarBadge(Context cr, Widget widget, int w, int h) {

        // pw, ph, ps = percent width, height, size
        void drawBadge(double pw, double ph, double ps, RGBA fg, RGBA bg, int value) {

            double x = w * pw;
            double y = h * ph;
            double radius = min(w,h) * ps;

            cr.save();
            cr.setSourceRgba(bg.red, bg.green, bg.blue, bg.alpha);
            cr.arc(x, y, radius, 0.0, 2.0 * PI);
            cr.fillPreserve();
            cr.stroke();
            cr.selectFontFace("monospace", FontSlant.Normal, FontWeight.Normal);
            cr.setFontSize(10);
            cr.setSourceRgba(fg.red, fg.green, fg.blue, 1.0);
            string text = to!string(value);
            TextExtents extents;
            cr.textExtents(text, extents);
            cr.moveTo(x - extents.width / 2, y + extents.height / 2);
            cr.showText(text);
            cr.restore();
            cr.newPath();
        }

        RGBA fg;
        RGBA bg;
        //Draw number of notifications on button
        ulong count = 0;
        foreach (sn; sessionNotifications.values) {
            count = count + sn.messages.length;
        }
        if (count > 0) {
            widget.getStyleContext().lookupColor("theme_selected_fg_color", fg);
            widget.getStyleContext().lookupColor("theme_selected_bg_color", bg);
            bg.alpha = 0.9;
            drawBadge(0.87, 0.68, 0.15, fg, bg, to!int(count));
        }
    }

    void onIsActionAllowed(ActionType actionType, CumulativeResult!bool result) {
        final switch (actionType) {
            case ActionType.DETACH_TERMINAL:
                // Only allow if there is more then one session, note that session
                // checks if there is more then one terminal and allows in either case
                result.addResult( nb.getNPages() > 1);
                break;
            case ActionType.DETACH_SESSION:
                // Only allow if there is more then one session
                result.addResult( nb.getNPages() > 1);
                break;
        }
        return;
    }

    void sendNotification(string id, string summary, string _body, ) {
        Notification n = new Notification(summary);
        n.setBody(_body);
        tracef("Sending notification %s", id);
        getApplication().sendNotification(id, n);
    }

    void onSessionProcessNotification(string summary, string _body, string terminalUUID, string sessionUUID) {
        tracef("Notification Received\n\tSummary=%s\n\tBody=%s", summary, _body);
        // If window not active, send notification to shell
        if (!isActive() && !_destroyed && gsSettings.getBoolean(SETTINGS_NOTIFY_ON_PROCESS_COMPLETE_KEY)) {
            string uuid = terminalUUID.length == 0? sessionUUID:terminalUUID;
            Notification n = new Notification(_(summary));
            n.setBody(_body);
            n.setDefaultAction("app.activate-session::" ~ sessionUUID);
            tracef("Sending notification %s", uuid);
            getApplication().sendNotification(uuid, n);
            //if session not visible send to local handler
        }
        // If session not active, keep copy locally.
        // getCurrentSession() was dereferenced unguarded here. This handler is
        // driven by the background process monitor, so it can fire while the
        // notebook has no current page (window teardown, last session
        // closing) — the branch above already guards on _destroyed, this one
        // did not.
        Session current = getCurrentSession();
        if (current is null) return;
        if (sessionUUID != current.uuid) {
            tracef("SessionUUID: %s versus notification UUID: %s", sessionUUID, current.uuid);
            //handle session level notifications here
            ProcessNotificationMessage msg = ProcessNotificationMessage(terminalUUID, summary, _body);
            if (sessionUUID in sessionNotifications) {
                SessionNotification sn = sessionNotifications[sessionUUID];
                sn.messages ~= msg;
                trace("Updated with new notification " ~ to!string(sn.messages.length));
            } else {
                SessionNotification sn = new SessionNotification(sessionUUID);
                sn.messages ~= msg;
                sessionNotifications[sessionUUID] = sn;
                trace("Session UUID " ~ sn.sessionUUID);
                trace("Messages " ~ to!string(sn.messages.length));
            }
            updateUIState();
        }
    }

    /**
     * Bridges an asynchronous confirmation into the synchronous close-request
     * answer. If the prompt resolves immediately (disabled by preference) the
     * answer is returned directly; otherwise this close is blocked and, once
     * the user agrees, re-issued without prompting via closeNoPrompt().
     */
    bool deferClose(void delegate(void delegate(bool)) ask) {
        bool answered = false;
        bool canClose = false;
        bool deferred = false;
        ask(delegate(bool ok) {
            answered = true;
            canClose = ok;
            if (deferred && ok) closeNoPrompt();
        });
        if (answered) return !canClose;
        deferred = true;
        return true;
    }

    bool onWindowClosed(Window window) {
        if (_noPrompt) return false;
        // GTK4: close-request must answer synchronously; the dialogs are not.
        ProcessInformation pi = getProcessInformation();
        if (pi.children.length > 0) {
            return deferClose(delegate(void delegate(bool) then) {
                promptCanCloseProcesses(gsSettings, this, pi, then);
            });
        } else if (nb.getNPages() > 1) {
            return deferClose(delegate(void delegate(bool) then) {
                showConfirmDialog(this, _("There are multiple sessions open, close anyway?"), gsSettings, SETTINGS_PROMPT_ON_CLOSE_KEY, then);
            });
        }
        return false;
    }

    void onWindowDestroyed(Widget widget) {
        tracef("AppWindow %s destroyed", uuid);
        _destroyed = true;
        tilix.withdrawNotification(uuid);
        tilix.removeAppWindow(this);
        sessionActions = null; // GTK4/giD: no ObjectG.destroy; dropping the reference releases it
        sessionActions = null;
        saSyncInput  = null;
        saViewSideBar = null;
        saSessionAddRight = null;
        saSessionAddDown = null;
        group = null;
    }

    void onWindowShow(Widget widget) {
        if (tilix.getGlobalOverrides().maximize) {
            maximize();
        } else if (tilix.getGlobalOverrides().minimize) {
            minimize();
        } else if (tilix.getGlobalOverrides().fullscreen) {
            changeActionState(ACTION_WIN_FULLSCREEN, new GVariant(true));
            fullscreen();
        } else if (isQuake()) {
            moveAndSizeQuake();
            applyPreference(SETTINGS_QUAKE_KEEP_ON_TOP_KEY);
            trace("Focus terminal");
            // GTK4: activateFocus() is gone; the terminal is focused explicitly.
            if (getActiveTerminal() !is null) {
                getActiveTerminal().focusTerminal();
            } else if (getCurrentSession() !is null) {
                getCurrentSession().focusTerminal(1);
            }
        } else if (tilix.getGlobalOverrides().geometry.flag == GeometryFlag.NONE && !isWayland(this) && gsSettings.getBoolean(SETTINGS_WINDOW_SAVE_STATE_KEY)) {
            // GTK4: the persisted value is a GdkToplevelState bitmask, stored
            // under its own key (toplevel-state). GTK3 builds wrote window-state
            // as GdkWindowState, whose bit values differ (Iconified=2/Maximized=4
            // vs Minimized=1/Maximized=2), so that key is deliberately not read.
            ToplevelState state = cast(ToplevelState) gsSettings.getInt(SETTINGS_WINDOW_STATE_KEY);
            if (state & ToplevelState.Maximized) {
                maximize();
            } else if (state & ToplevelState.Minimized) {
                minimize();
            } else if (state & ToplevelState.Fullscreen) {
                fullscreen();
            }
            // GTK4 has no sticky/all-workspaces API (WP5); the Sticky bit is
            // read but cannot be applied.
        }
    }

    void onWindowRealized(Widget widget) {
        if (isQuake()) {
            // GTK4: skip-taskbar/pager are X11 surface hints, set once the
            // surface exists (quake mode is X11-only, see the constructor).
            setSkipTaskbarAndPager(getSurface(), true);
            applyPreference(SETTINGS_QUAKE_HEIGHT_PERCENT_KEY);
        } else {
            handleGeometry();
        }
    }

    void onWindowStateChanged(ParamSpec pspec, ObjectWrap obj) {
        trace("Window state changed");
        if (fullscreened) {
            trace("Window state is fullscreen");
        }
        if (!isQuake() && gsSettings.getBoolean(SETTINGS_WINDOW_SAVE_STATE_KEY)) {
            Toplevel toplevel = cast(Toplevel) getSurface();
            if (toplevel !is null) {
                // Written as GdkToplevelState bits to the GTK4-only key.
                gsSettings.setInt(SETTINGS_WINDOW_STATE_KEY, cast(int) toplevel.state);
            }
        }
    }

    bool handleGeometry() {
        // GTK4: no client-side window positioning (WP5). The --geometry size is
        // applied through the terminal's first-run sizing; its x/y part cannot
        // be honoured. Returns whether a full geometry was requested.
        if (!isQuake() && tilix.getGlobalOverrides().geometry.flag == GeometryFlag.FULL && !isWayland(this)) {
            trace("Window position from --geometry is not supported under GTK4; ignoring x/y");
            return true;
        }
        return false;
    }

    void onCompositedChanged(Widget widget) {
        trace("Composite changed");
        updateVisual();
    }

    void updateTabPosition() {
        if (useTabs) {
            if (isQuake) {
                nb.setTabPos(cast(PositionType) gsSettings.getEnum(SETTINGS_QUAKE_TAB_POSITION_KEY));
            } else {
                nb.setTabPos(cast(PositionType) gsSettings.getEnum(SETTINGS_TAB_POSITION_KEY));
            }
            for (int i=0; i<nb.getNPages; i++) {
                SessionTabLabel label = cast(SessionTabLabel) nb.getTabLabel(nb.getNthPage(i));
                // Guarded to match updateUIState, which already skips nulls.
                if (label !is null) label.updatePositionType(nb.getTabPos);
            }
        }
    }

    void applyPreference(string key) {
        switch(key) {
            case SETTINGS_QUAKE_WIDTH_PERCENT_KEY, SETTINGS_QUAKE_HEIGHT_PERCENT_KEY, SETTINGS_QUAKE_ACTIVE_MONITOR_KEY, SETTINGS_QUAKE_SPECIFIC_MONITOR_KEY, SETTINGS_QUAKE_ALIGNMENT_KEY:
                if (isQuake) {
                    moveAndSizeQuake();
                }
                break;
            case SETTINGS_QUAKE_SHOW_ON_ALL_WORKSPACES_KEY:
                // GTK4 has no sticky/all-workspaces API (WP5); the preference
                // is kept but has no effect under GTK4.
                break;
            case SETTINGS_QUAKE_TAB_POSITION_KEY:
                updateTabPosition();
                break;
            case SETTINGS_TAB_POSITION_KEY:
                updateTabPosition();
                break;
            /*
            case SETTINGS_QUAKE_DISABLE_ANIMATION_KEY:
                if (isQuake) {
                    if (gsSettings.getBoolean(SETTINGS_QUAKE_DISABLE_ANIMATION_KEY)) {
                        setTypeHint(GdkWindowTypeHint.UTILITY);
                    } else {
                        setTypeHint(GdkWindowTypeHint.NORMAL);
                    }
                }
                break;
            */
            case SETTINGS_QUAKE_HIDE_HEADERBAR_KEY:
                if (isQuake) {
                    bool hide = gsSettings.getBoolean(SETTINGS_QUAKE_HIDE_HEADERBAR_KEY);
                    if (hide) hb.hide();
                    else hb.show();
                }
                break;
            case SETTINGS_QUAKE_KEEP_ON_TOP_KEY:
                // GTK4 has no keep-above API (WP5); the preference is kept but
                // has no effect under GTK4.
                break;
            default:
                break;
        }
    }

    void moveAndSizeQuake() {
        if (getSurface() is null) return;
        Rectangle rect;
        getQuakePosition(rect);
        // GTK4 (WP5): there is NO client-side window positioning any more —
        // gtk_window_move, gdk_window_move_resize and their like are all gone,
        // on every backend. The size half of the computed rectangle can still
        // be applied; the placement half (bottom/top edge, left/centre/right
        // alignment) cannot be expressed through GTK at all and needs a
        // protocol-level solution (xdg-positioner / wlr-layer-shell), which
        // the ROADMAP already tracks. Until then the quake window is sized but
        // placed by the compositor.
        trace("Sizing quake window; placement is not available on GTK4 (WP5)");
        setDefaultSize(rect.width, rect.height);
    }

    void getQuakePosition(out Rectangle rect) {
        bool wayland = isWayland(this);

        // GTK4 (WP5): GdkScreen is gone and with it three things this relied on.
        //  - There is no primary-monitor concept; monitors are a plain list, so
        //    index 0 is the default.
        //  - There is no pointer query (gdk_display_get_pointer) and no
        //    "active window" query, so SETTINGS_QUAKE_ACTIVE_MONITOR_KEY —
        //    "open on the monitor the mouse is on" — cannot be honoured. The
        //    GTK3 code already skipped it under Wayland; it is now unavailable
        //    everywhere and falls through to the specific/default monitor.
        //  - There is no workarea API; getGeometry is the full monitor, so
        //    panels are no longer subtracted.
        Display display = Display.getDefault();
        ListModel monitors = display.getMonitors();
        uint monitorCount = monitors.getNItems();
        int monitor = 0;
        if (!wayland && !gsSettings.getBoolean(SETTINGS_QUAKE_ACTIVE_MONITOR_KEY)) {
            int altMonitor = gsSettings.getInt(SETTINGS_QUAKE_SPECIFIC_MONITOR_KEY);
            if (altMonitor >= 0 && altMonitor < cast(int) monitorCount) {
                monitor = altMonitor;
            }
        }
        if (monitorCount == 0) {
            warning("No monitors reported by the display; cannot size quake window");
            return;
        }
        MonitorWrap mon = cast(MonitorWrap) monitors.getItem(cast(uint) monitor);
        mon.getGeometry(rect);
        tracef("Monitor geometry: monitor=%d, x=%d, y=%d, width=%d, height=%d", monitor, rect.x, rect.y, rect.width, rect.height);

        // Wayland works with screen factor natively whereas X11 does not
        int scaleFactor = mon.getScaleFactor();
        if (wayland && scaleFactor > 1) {
            rect.width = rect.width / scaleFactor;
            rect.height = rect.height / scaleFactor;
            tracef("Scaled monitor geometry: monitor=%d, scaleFactor=%d, x=%d, y=%d, width=%d, height=%d", monitor, scaleFactor, rect.x, rect.y, rect.width, rect.height);
        }

        double widthPercent = to!double(gsSettings.getInt(SETTINGS_QUAKE_WIDTH_PERCENT_KEY))/100.0;
        double heightPercent = to!double(gsSettings.getInt(SETTINGS_QUAKE_HEIGHT_PERCENT_KEY))/100.0;
        if (wayland) {
            widthPercent = 1;
        }

        if (widthPercent == 1 && heightPercent == 1) {
            maximize();
            return;
        }

        // Calculate Height and offset for bottom positioning
        int height = to!int(rect.height * heightPercent);
        if (!wayland && heightPercent < 1 && gsSettings.getString(SETTINGS_QUAKE_WINDOW_POSITION_KEY)==SETTINGS_QUAKE_WINDOW_POSITION_VALUES[1]) {
            rect.y = rect.height - height;
        }
        rect.height = height;

        //Width
        // Window only gets positioned properly in Wayland when width is 100%,
        // not sure if this kludge is really a good idea and will work consistently.
        if (widthPercent < 1) {
            int width = to!int(rect.width * widthPercent);
            tracef("Calculated width %d", width);
            switch (gsSettings.getString(SETTINGS_QUAKE_ALIGNMENT_KEY)) {
                case SETTINGS_QUAKE_ALIGNMENT_LEFT_VALUE:
                    break;
                case SETTINGS_QUAKE_ALIGNMENT_CENTER_VALUE:
                    rect.x = rect.x + (rect.width - width)/2;
                    break;
                case SETTINGS_QUAKE_ALIGNMENT_RIGHT_VALUE:
                    rect.x = rect.x + rect.width - width;
                    break;
                default:
                    break;
            }
            rect.width = width;
        }
        tracef("Quake window: monitor=%d, x=%d, y=%d, width=%d, height=%d", monitor, rect.x, rect.y, rect.width, rect.height);
    }

    Session getCurrentSession() {
        if (nb.getCurrentPage < 0)
            return null;
        else
            return getSession(nb.getCurrentPage());
    }

    Session getSession(string sessionUUID) {
        for (int i = 0; i < nb.getNPages(); i++) {
            Session session = getSession(i);
            if (session.uuid == sessionUUID) {
                return session;
            }
        }
        return null;
    }

    void addFilters(FileChooserDialog fcd) {
        FileFilter ff = new FileFilter();
        ff.addPattern("*.json");
        ff.setName(_("All JSON Files"));
        fcd.addFilter(ff);
        ff = new FileFilter();
        ff.addPattern("*");
        ff.setName(_("All Files"));
        fcd.addFilter(ff);
    }

    /**
     * Loads session from a file
     */
    void loadSession(string filename) {
        if (!exists(filename))
            throw new SessionCreationException(format(_("Filename '%s' does not exist"), filename));
        string text = readText(filename);
        JSONValue value = parseJSON(text);
        int width = nb.getAllocatedWidth();
        int height = nb.getAllocatedHeight();
        // If no sessions then we are loading our first session,
        // set the window size to what was saved in session JSON file
        if (!nb.getRealized()) {
            try {
                Session.getPersistedSessionSize(value, width, height);
                if (nb.getNPages() == 0) {
                    setDefaultSize(width, height);
                }
            }
            catch (Exception e) {
                throw new SessionCreationException("Session could not be created due to error: " ~ e.msg, e);
            }
        }
		addRecentSessionFile(filename);
        tracef("Session dimensions: w=%d, h=%d", width, height);
        Session session = new Session("");
        session.initSession(value, filename, width, height, nb.getNPages() == 0);
        addSession(session);
    }

    FileChooserDialog fcd;

    /**
     * Creates a FileChooserDialog. The GtkD convenience ctor wraps the
     * varargs gtk_file_chooser_dialog_new which giD does not bind, so the
     * dialog is constructed raw and configured with property setters.
     * Button/response mapping matches GtkD's defaults:
     * first button = ResponseType.Ok, second = ResponseType.Cancel.
     */
    FileChooserDialog createFileChooserDialog(string title, FileChooserAction action, string acceptLabel) {
        FileChooserDialog dialog = new FileChooserDialog(
            cast(void*) g_object_new(FileChooserDialog._getGType(), cast(const(char)*) null), No.Take);
        dialog.setTitle(title);
        dialog.setAction(action);
        dialog.addButton(acceptLabel, ResponseType.Ok);
        dialog.addButton(_("Cancel"), ResponseType.Cancel);
        return dialog;
    }

    /**
     * Loads session from a file, prompt user to select file
     */
    void loadSession() {
        fcd = createFileChooserDialog(_("Load Session"), FileChooserAction.Open, _("Open"));
        if (DialogPath.LOAD_SESSION in dialogPaths) {
            fcd.setCurrentFolder(File.newForPath(dialogPaths[DialogPath.LOAD_SESSION]));
        }
        fcd.setModal(true);
        fcd.setTransientFor(this);

        addFilters(fcd);
        fcd.setSelectMultiple(true);
        fcd.connectResponse(delegate(int response, Dialog d) {
            if (response == ResponseType.Ok) {
                try {
                    // GTK4: getFiles() is a ListModel of GFile.
                    ListModel files = fcd.getFiles();
                    string[] filenames;
                    foreach (i; 0 .. files.getNItems()) {
                        File f = cast(File) files.getItem(i);
                        if (f !is null && f.getPath().length > 0) filenames ~= f.getPath();
                    }
                    foreach(filename; filenames) {
                        loadSession(filename);
                        addRecentSessionFile(filename);
                    }
                    if (fcd.getCurrentFolder() !is null) dialogPaths[DialogPath.LOAD_SESSION] = fcd.getCurrentFolder().getPath();
                }
                catch (Exception e) {
                    fcd.hide();
                    if (fcd.getFile() !is null) removeRecentSessionFile(fcd.getFile().getPath());
                    error(e);
                    showErrorDialog(this, _("Could not load session due to unexpected error.") ~ "\n" ~ e.msg, _("Error Loading Session"));
                }
            }
            fcd.hide();
            fcd.destroy();
        });
        fcd.connectClose(delegate(Dialog d) {
            fcd.destroy();
            fcd = null;
        });
        fcd.present();
    }

    /**
     * Saves session to a file
     *
     * Params:
     *  showSaveAsDialog = Determines if save as dialog is shown. Note dialog may be shown even if false is passed if the session filename is not set
     */
    void saveSession(bool showSaveAsDialog = true) {
        Session session = getCurrentSession();
        // The null check used to be folded into the `if` below as
        // `session !is null && (...)`, which guarded only the Save-As branch —
        // a null session fell through to the `else` and dereferenced it in
        // session.serialize(). Return early so both branches are covered.
        if (session is null) return;
        if (session.filename.length <= 0 || showSaveAsDialog) {
            fcd = createFileChooserDialog(_("Save Session"), FileChooserAction.Save, _("Save"));
            fcd.setModal(true);
            fcd.setTransientFor(this);

            addFilters(fcd);

            fcd.setDefaultResponse(ResponseType.Ok);
            if (session.filename.length > 0) {
                fcd.setCurrentFolder(File.newForPath(dirName(session.filename)));
                fcd.setCurrentName(session.filename.length > 0 ? baseName(session.filename) : session.displayName ~ ".json");
            } else if (DialogPath.SAVE_SESSION in dialogPaths) {
                fcd.setCurrentFolder(File.newForPath(dialogPaths[DialogPath.SAVE_SESSION]));
            }

            fcd.connectResponse(delegate(int response, Dialog d) {
                if (response == ResponseType.Ok) {
                    try {
                        File chosen = fcd.getFile();
                        if (chosen is null) return;
                        string filename = chosen.getPath();
                        if (!filename.endsWith(".json")) {
                            filename ~= ".json";
                        }
                        if (fcd.getCurrentFolder() !is null) dialogPaths[DialogPath.SAVE_SESSION] = fcd.getCurrentFolder().getPath();
                        addRecentSessionFile(filename);
                        string json = session.serialize().toPrettyString();
                        write(filename, json);
                        session.filename = filename;
                    }
                    catch (Exception e) {
                        fcd.hide();
                        if (fcd.getFile() !is null) removeRecentSessionFile(fcd.getFile().getPath());
                        error(e);
                        showErrorDialog(this, _("Could not save session due to unexpected error.") ~ "\n" ~ e.msg, _("Error Saving Session"));
                    }
                }
                fcd.hide();
                fcd.destroy();
            });
            fcd.connectClose(delegate(Dialog d) {
                fcd.destroy();
                fcd = null;
            });
            fcd.present();
        }
        else {
            try {
                string json = session.serialize().toPrettyString();
                write(session.filename, json);
            }
            catch (Exception e) {
                error(e);
                showErrorDialog(this, _("Could not save session due to unexpected error.") ~ "\n" ~ e.msg, _("Error Saving Session"));
            }
        }
    }

    /**
     * Creates a new session based on parameters, user is not prompted
     */
    void createSession(string name, string profileUUID, string workingDir = null) {
        createNewSession(name, profileUUID, workingDir);
    }

    void loadRecentSessionFileList() {
        recentSessionFiles = gsSettings.getStrv(SETTINGS_RECENT_SESSION_FILES_KEY);
    }

    void saveRecentSessionFileList() {
        gsSettings.setStrv(SETTINGS_RECENT_SESSION_FILES_KEY, recentSessionFiles);
    }

    /**
     * Prepends a file path to the recent session files list
     */
    void addRecentSessionFile(string path, bool save = true) {
        // Don't save after removing as the list will be saved later
        removeRecentSessionFile(path, false);

        recentSessionFiles = path ~ recentSessionFiles;

        if (save) {
            saveRecentSessionFileList();
        }
    }

    /**
     * Removes a file path from from the recent session files list
     */
    void removeRecentSessionFile(string path, bool save = true) {
        string[] temp;

        foreach (i, string aPath; recentSessionFiles) {
            if (aPath != path) {
                temp ~= aPath;
            }
        }

        recentSessionFiles = temp;

        if (save) {
            saveRecentSessionFileList();
        }
    }

    void removeTimeout() {
        if (timeoutID > 0) {
            Source.remove(timeoutID);
            timeoutID = 0;
        }
    }

    void setWindowStyle() {
        windowStyle = gsSettings.getEnum(SETTINGS_WINDOW_STYLE_KEY);
        if (tilix.getGlobalOverrides().windowStyle.length > 0) {
            foreach(i, style; SETTINGS_WINDOW_STYLE_VALUES) {
                if (style == tilix.getGlobalOverrides().windowStyle) {
                    windowStyle = i;
                    break;
                }
            }
        }
    }

public:

    this(Application application, bool useTabs = false) {
        super(application);
        group = new WindowGroup();
        group.addWindow(this);
        _windowUUID = randomUUID().toString();
        this.useTabs = useTabs;
        tilix.addAppWindow(this);
        gsSettings = new GSettings(SETTINGS_ID);
        gsSettings.connectChanged(null, delegate(string key, GSettings settings) {
            applyPreference(key);
        });
        setTitle(_("ttyx_"));
        setIconName("io.github.gwelr.ttyx");
        setWindowStyle();
        loadRecentSessionFileList();
        gsSettings.connectChanged(null, delegate(string key, GSettings settings) {
            if (key == SETTINGS_RECENT_SESSION_FILES_KEY) {
                loadRecentSessionFileList();
            } else if (key == SETTINGS_APP_TITLE_KEY) {
                updateTitle();
            }
        });

        if (gsSettings.getBoolean(SETTINGS_ENABLE_TRANSPARENCY_KEY)) {
            updateVisual();
        }
        if (tilix.getGlobalOverrides().quake && !isWayland(null)) {
            _quake = true;
            setDecorated(false);
            // GTK4: no gravity (no client-side placement, WP5). The X11
            // skip-taskbar/pager hints need a realized surface and are applied
            // in onWindowRealized.
            applyPreference(SETTINGS_QUAKE_HEIGHT_PERCENT_KEY);
            applyPreference(SETTINGS_QUAKE_SHOW_ON_ALL_WORKSPACES_KEY);
            // On Ubuntu this causes terminal to use default size, see #602
            //setResizable(false);
            // GTK4: no window role API (WP5).
        } else {
            if (tilix.getGlobalOverrides.quake) {
                string message = _("Quake mode is not supported under Wayland, running as normal window");
                error(message);
                sendNotification("quake", _("Quake Mode Not Supported"), message);
            }
            if (windowStyle == 3) {
                setDecorated(false);
            }
        }
        setShowMenubar(false);

        createUI();

        connectCloseRequest(&onWindowClosed);
        connectDestroy(&onWindowDestroyed);
        connectRealize(&onWindowRealized);
        /*
        connectMap(delegate(Widget widget) {
            if (isQuake()) {
                applyPreference(SETTINGS_QUAKE_DISABLE_ANIMATION_KEY);
            }
        }, Yes.After);
        */

        connectShow(&onWindowShow, Yes.After);
        // GTK4: no size-allocate; a toplevel's default-width/height properties
        // track its actual size, so watch those to invalidate the background.
        void onWindowSizeChanged(ParamSpec pspec, ObjectWrap obj) {
            int width = getWidth();
            int height = getHeight();
            if (lastWidth != width || lastHeight != height) {
                //invalidate rendered background
                // (giD cairo surfaces are GC managed, no explicit destroy)
                isBGImage = null;
                lastWidth = width;
                lastHeight = height;
            }
        }
        connectNotify("default-width", &onWindowSizeChanged, Yes.After);
        connectNotify("default-height", &onWindowSizeChanged, Yes.After);
        // GTK4: composited-changed is gone; windows are always composited.
        // GTK4: focus-in/out-event -> EventControllerFocus enter/leave. The
        // callbacks return void; the GTK3 handlers always returned false.
        EventControllerFocus windowFocus = new EventControllerFocus();
        windowFocus.connectLeave(delegate void(EventControllerFocus c) {
            if (isQuake && gsSettings.getBoolean(SETTINGS_QUAKE_HIDE_LOSE_FOCUS_KEY)) {
                Window window = tilix.getActiveWindow();
                if (window !is null) {
                    if (window._cPtr is this._cPtr) {
                        Widget[] toplevels = Window.listToplevels();
                        tracef("Top level windows = %d", toplevels.length);
                        foreach(Widget child; toplevels) {
                            Dialog dialog = cast(Dialog)child;
                            if (dialog !is null && dialog.getTransientFor() !is null && dialog.getTransientFor()._cPtr is this._cPtr) return;
                        }
                    }
                }

                trace("Focus lost, waiting to hide quake window");
                // store a reference to this timeout so that it may be canceled if we regain focus
                timeoutID = threadsAddTimeoutDelegate(gsSettings.getInt(SETTINGS_QUAKE_HIDE_LOSE_FOCUS_DELAY_KEY), delegate() {
                    trace("Focus lost and timeout reached, hiding quake window");
                    if (isVisible()) {
                        this.hide();
                    }
                    return false;
                });
            }
        }, Yes.After);
        windowFocus.connectEnter(delegate void(EventControllerFocus c) {
            // if we're restoring focus to quake window, we want to keep it open
            removeTimeout();

            tilix.withdrawNotification(uuid);
            if (getCurrentSession() !is null) {
                getCurrentSession().withdrawNotification();
            }
        });
        addController(windowFocus);
        // GTK4: window-state-event is gone. Maximized and fullscreen are plain
        // properties on GtkWindow, so watch those; the full bitmask to persist
        // comes from the GdkToplevel behind the surface.
        connectNotify("maximized", &onWindowStateChanged, Yes.After);
        connectNotify("fullscreened", &onWindowStateChanged, Yes.After);
        handleGeometry();
    }

    debug(Destructors) {
        ~this() {
            import std.stdio;
            writeln("***** AppWindow destructor is called");
        }
    }

    void initialize() {
        if (tilix.getGlobalOverrides().session.length > 0) {
            foreach (sessionFilename; tilix.getGlobalOverrides().session) {
                try {
                    if (!exists(sessionFilename)) {
                        string filename = buildPath(tilix.getGlobalOverrides().cwd, sessionFilename);
                        tracef("Trying filename %s", filename);
                        if (exists(filename)) {
                            sessionFilename = filename;
                        } else {
                            warningf("Session filename '%s' does not exist, ignoring", filename);
                            continue;
                        }
                    }
                    loadSession(sessionFilename);
                } catch (SessionCreationException e) {
                    errorf("Could not load session from file '%s', error occurred", sessionFilename);
                    error(e.msg);
                }
            }
            if (nb.getNPages() > 0) return;
        }
        //Create an initial session using default session name and profile
        createSession(gsSettings.getString(SETTINGS_SESSION_NAME_KEY), prfMgr.getDefaultProfile());
    }

    void initialize(Session session) {
        addSession(session);
    }

    void closeNoPrompt() {
        _noPrompt = true;
        close();
    }

    /**
     * Activates the specified sessionUUID
     */
    bool activateSession(string sessionUUID) {
        for (int i = 0; i < nb.getNPages(); i++) {
            Session session = getSession(i);
            if (session.uuid == sessionUUID) {
                nb.setCurrentPage(i);
                return true;
            }
        }
        return false;
    }

    /**
     * Focus the previous session
     */
    void focusPreviousSession() {
        if (nb.getCurrentPage() > 0) {
            nb.prevPage();
        } else {
            nb.setCurrentPage(nb.getNPages() - 1);
        }
    }

    /**
     * Focus the next session
     */
    void focusNextSession() {
        if (nb.getCurrentPage() < nb.getNPages() - 1) {
            nb.nextPage();
        } else {
            nb.setCurrentPage(0);
        }
    }

    /**
     * Activates the specified terminal
     */
    bool activateTerminal(string sessionUUID, string terminalUUID) {
        if (activateSession(sessionUUID)) {
            return getCurrentSession().focusTerminal(terminalUUID);
        }
        return false;
    }

    bool activateTerminal(string terminalUUID) {
        for (int i = 0; i < nb.getNPages(); i++) {
            Session session = cast(Session) nb.getNthPage(i);
            Widget result = session.findWidgetForUUID(terminalUUID);
            if (result !is null) {
                activateTerminal(session.uuid, terminalUUID);
                return true;
            }
        }
        return false;
    }

    ITerminal getActiveTerminal() {
        Session session = getCurrentSession();
        if (session !is null) {
            return session.getActiveTerminal();
        }
        return null;
    }

    string getActiveTerminalUUID() {
        ITerminal terminal = getActiveTerminal();
        if (terminal !is null) return terminal.uuid;
        return null;
    }

    /**
     * Finds the widget matching a specific UUID, typically
     * a Session or Terminal
     */
    Widget findWidgetForUUID(string uuid) {
        for (int i = 0; i < nb.getNPages(); i++) {
            Session session = cast(Session) nb.getNthPage(i);
            if (session.uuid == uuid)
                return session;
            trace("Searching session");
            Widget result = session.findWidgetForUUID(uuid);
            if (result !is null)
                return result;
        }
        return null;
    }

    /**
     * Creates a new session and prompts the user for session properties
     */
    void createSession() {
        // Hide the sidebar if it is open
        if (!useTabs && sb.getRevealChild()) {
            saViewSideBar.activate(null);
        }

        string workingDir;
        string profileUUID = prfMgr.getDefaultProfile();

        // Inherit current session directory unless overrides exist, fix #343
        if (tilix.getGlobalOverrides().cwd.length ==0 && tilix.getGlobalOverrides().workingDir.length == 0) {
            ITerminal terminal = getActiveTerminal();
            if (terminal !is null) {
                workingDir = terminal.currentLocalDirectory;
                profileUUID = terminal.defaultProfileUUID;
            }
        }
        if (gsSettings.getBoolean(SETTINGS_PROMPT_ON_NEW_SESSION_KEY)) {
            SessionProperties sp = new SessionProperties(this, gsSettings.getString(SETTINGS_SESSION_NAME_KEY), profileUUID);
            // GTK4: no Dialog.run(); the result arrives in the response signal.
            sp.connectResponse(delegate(int response, Dialog d) {
                if (response == ResponseType.Ok) {
                    createSession(sp.name, sp.profileUUID, workingDir);
                }
                sp.destroy();
            });
            sp.present();
        } else {
            createSession(gsSettings.getString(SETTINGS_SESSION_NAME_KEY), profileUUID, workingDir);
        }
    }

    /**
     * Information about any running processes in the window.
     */
    ProcessInformation getProcessInformation() {
        ProcessInformation result = ProcessInformation(ProcessInfoSource.WINDOW, getTitle(), "", []);
        for(int i=0; i<nb.getNPages; i++) {
            Session session = cast(Session) nb.getNthPage(i);
            if (session !is null) {
                ProcessInformation sessionInfo = session.getProcessInformation();
                if (sessionInfo.children.length > 0) {
                    result.children ~= sessionInfo;
                }
            }
        }
        return result;
    }

    /**
     * Unique and immutable session ID
     */
    @property string uuid() {
        return _windowUUID;
    }

    /**
     * Invaidates background image cache and redraws
     */
    void updateBackgroundImage() {
        if (isBGImage !is null) {
            trace("Destroying cached background image");
            // giD cairo surfaces are GC managed, dropping the reference
            // is all that is needed
            isBGImage = null;
        }
        queueDraw();
    }

    /**
     * Returns an image surface that contains the rendered background
     * image. This returns null if no background image has been set.
     *
     * The image surface is cached between invocations to improve draw
     * performance as per #340.
     */
    Surface getBackgroundImage(Widget widget) {
        if (isBGImage !is null) {
            return isBGImage;
        }

        Surface surface = tilix.getBackgroundImage();
        if (surface is null) {
            isBGImage = null;
            return isBGImage;
        }

        ImageLayoutMode mode;
        string bgMode = gsSettings.getString(SETTINGS_BACKGROUND_IMAGE_MODE_KEY);
        final switch (bgMode) {
            case SETTINGS_BACKGROUND_IMAGE_MODE_SCALE_VALUE:
                mode = ImageLayoutMode.SCALE;
                break;
            case SETTINGS_BACKGROUND_IMAGE_MODE_TILE_VALUE:
                mode = ImageLayoutMode.TILE;
                break;
            case SETTINGS_BACKGROUND_IMAGE_MODE_CENTER_VALUE:
                mode = ImageLayoutMode.CENTER;
                break;
            case SETTINGS_BACKGROUND_IMAGE_MODE_STRETCH_VALUE:
                mode = ImageLayoutMode.STRETCH;
                break;
        }
        int scale = gsSettings.getEnum(SETTINGS_BACKGROUND_IMAGE_SCALE_KEY);
        isBGImage = renderImage(surface, widget.getAllocatedWidth(), widget.getAllocatedHeight(), mode, true, cast(Filter) scale);
        return isBGImage;
    }

// Quake methods
private:
    bool wasFullscreen = false;

public:

    /**
     * Returns true if this window is in quake mode.
     */
    bool isQuake() {
        return _quake;
    }

    /**
     * Override hide to handle hiding quake window when full screened
     *
     * giD's Widget.hide is nothrow, so the override must be as well;
     * the body reads _quake directly instead of calling isQuake().
     */
    override void hide() nothrow {
        if (_quake) {
            // GTK4: GdkWindow is gone; the window exposes fullscreened directly.
            if (fullscreened) {
                unfullscreen();
                wasFullscreen = true;
            } else {
                wasFullscreen = false;
            }
        }
        super.hide();
    }

    /**
     * If quake window was hidden when fullscreen, restore fullscreen
     */
    override void present() nothrow {
        super.present();
        if (_quake) {
            if (getSurface() !is null && wasFullscreen) {
                wasFullscreen = false;
                fullscreen();
            }
        }
    }
}

/**
 * Widget used for labels in tabs for sessions.
 */
class SessionTabLabel: Box {

private:
	Button button;
    Box evNotifications;
    AspectFrame afNotifications;
	Label lblText;
    Label lblNotifications;
	Session session;
    Image imgNewOutput;
    Entry lblEditBox;
    Stack stTitle;

    enum PAGE_LABEL = "label";
    enum PAGE_EDIT = "edit";

	void closeClicked(Button button) {
		onCloseClicked.emit(session);
	}

public:

	this(PositionType position, string text, Session session) {
		super( (position==PositionType.Left || PositionType.Right)?Orientation.Vertical:Orientation.Horizontal , 5);

		this.session = session;

        lblNotifications = new Label("");
        lblNotifications.setUseMarkup(true);
        lblNotifications.setWidthChars(2);
        setAllMargins(lblNotifications, 4);

        // GTK4: GtkEventBox is gone. This one carried nothing but a CSS class,
        // so a plain Box does the same job.
        evNotifications = new Box(Orientation.Horizontal, 0);
        evNotifications.append(lblNotifications);
        evNotifications.getStyleContext().addClass("ttyx-notification-count");

        afNotifications = new AspectFrame(0.5, 0.5, 1.0, false);
        // GTK4: GtkShadowType is gone (AspectFrame has no shadow); Bin.add -> setChild.
        afNotifications.setChild(evNotifications);

        append(afNotifications);

        stTitle = new Stack();

		lblText = new Label(text);
        lblText.setEllipsize(EllipsizeMode.Start);
		lblText.setWidthChars(10);
        updatePositionType(position);


        // Double-clicking the label switches to the edit entry. GTK4: the
        // EventBox wrapper is gone — the label takes the gesture itself.
        // setButton(1) restricts it to the primary button; a double-click is
        // nPress == 2; and because pressed returns void, the GTK3 `return true`
        // becomes an explicit claim of the event sequence.
        GestureClick titleClick = new GestureClick();
        titleClick.setButton(1);
        titleClick.connectPressed(delegate void(int nPress, double x, double y, GestureClick g) {
            if (nPress == 2) {
                lblEditBox.setText(session.name());
                stTitle.setVisibleChildName(PAGE_EDIT);
                lblEditBox.grabFocus();
                g.setState(EventSequenceState.Claimed);
            }
        });
        lblText.addController(titleClick);
        stTitle.addNamed(lblText, PAGE_LABEL);

        // when done editing the Entry, hide the Entry and show the lblBox again
        lblEditBox = new Entry();
        lblEditBox.setHexpand(true);
        EventControllerFocus editFocus = new EventControllerFocus();
        editFocus.connectLeave(delegate void(EventControllerFocus c) {
            string text = lblEditBox.getText().strip();
            if (text.length == 0)
                return;

            session.name(text);
            stTitle.setVisibleChildName(PAGE_LABEL);
        });
        lblEditBox.addController(editFocus);
        EventControllerKey editKeys = new EventControllerKey();
        editKeys.connectKeyPressed(delegate bool(uint keyval, uint keycode, ModifierType state, EventControllerKey c) {
            switch (keyval) {
                case KEY_Escape:
                    stTitle.setVisibleChildName(PAGE_LABEL);
                    return true;
                case KEY_Return:
                    // Preserved GtkD quirk: this commits the label's current
                    // text property; the entry text is committed by the
                    // focus-out handler when the stack page switches.
                    session.name(text);
                    stTitle.setVisibleChildName(PAGE_LABEL);
                    return true;
                default:
            }
            return false;
        });
        lblEditBox.addController(editKeys);
        if (gtkAtLeast(3, 16, 0)) {
            stTitle.addNamed(createTitleEditHelper(lblEditBox, TitleEditScope.SESSION), PAGE_EDIT);
        } else {
            stTitle.addNamed(lblEditBox, PAGE_EDIT);
        }

        append(stTitle);

        imgNewOutput = Image.newFromIconName("view-list-symbolic");
        imgNewOutput.setVisible(false);
        imgNewOutput.setTooltipText(_("New output displayed"));

        append(imgNewOutput);

		button = Button.newFromIconName("window-close-symbolic");
        button.getStyleContext().addClass("ttyx-small-button");
		button.setHasFrame(false);
		button.setFocusOnClick(false);
        button.setTooltipText(_("Close session"));

		button.connectClicked(&closeClicked);

        append(button);

        stTitle.setVisibleChildName(PAGE_LABEL);
    }

    void clear() {
        session = null;
    }

	@property string text() {
		return lblText.getText();
	}

	@property void text(string value) {
		lblText.setText(value);
	}

    @property bool showNewOutput() {
        return imgNewOutput.isVisible();
    }

    @property void showNewOutput(bool value) {
        if (value) imgNewOutput.show();
        else imgNewOutput.hide();
    }

    void updateNotifications(ProcessNotificationMessage[] pn) {
        if (pn is null || pn.length == 0) {
            afNotifications.hide();
        } else {
            lblNotifications.setText(to!string(pn.length));
            string tooltip;
            foreach (i, message; pn) {
                if (i > 0) tooltip ~= "\n\n";
                tooltip ~= message._body;
            }
            evNotifications.setTooltipText(tooltip);
            afNotifications.show();
            lblNotifications.show();
        }
    }

    void updatePositionType(PositionType position) {
        if (position == PositionType.Left || position == PositionType.Right) {
            setOrientation(Orientation.Vertical);
            // GTK4: labels cannot be rotated; side tabs keep horizontal text.
            lblText.setHexpand(false);
            lblText.setVexpand(true);
        } else {
            setOrientation(Orientation.Horizontal);
            lblText.setHexpand(true);
            lblText.setVexpand(false);
        }
    }


    void clearNotifications() {
        afNotifications.hide();
    }

	/**
	 * Event triggered when user clicks the close button
	 */
    GenericEvent!(Session) onCloseClicked;
}
