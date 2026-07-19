/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/application.d. Differences from the GtkD original:
 *  - Snake_case giD module imports; GtkD interface types map to giD classes
 *    (gio.ActionGroupIF -> gio.action_group.ActionGroup). Unused legacy imports
 *    (gio.Menu, gio.MenuModel, gtk.Main, gtk.Widget list helpers) dropped.
 *  - Signals: addOnActivate/Startup/Shutdown/CommandLine ->
 *    connectActivate/Startup/Shutdown/CommandLine; the command-line handler
 *    loses GtkD's Scoped! wrapper and is a plain
 *    int(ApplicationCommandLine, GioApplication). Every delegate-literal
 *    parameter is named (giD connect* template requirement).
 *  - Variant.getString() takes no out-length param; executeCommand's tuple
 *    variant is built with GVariant.newTuple (GtkD's new Variant(Variant[])).
 *  - gtkc.gtk raw gtk_application_set_accels_for_action hack for disabled
 *    shortcuts is gone: giD's setAccelsForAction marshals an empty string[] as
 *    a NULL-terminated empty C array, so super.setAccelsForAction(name, [])
 *    removes the accelerator (super., not this., to bypass the paste-accel
 *    override exactly like the raw call did).
 *  - setAccelsForAction override must be `nothrow` to match giD's generated
 *    method; non-nothrow helper calls are wrapped in try/catch.
 *  - gtk.Settings property Value dance -> typed giD properties
 *    (gtkApplicationPreferDarkTheme/gtkMenuBarAccel/gtkEnableAccels);
 *    defaultMenuAccel is now a string + bool flag instead of a gobject.Value.
 *    resetProperty is bound in giD, so the 3.20 reset path carries over.
 *  - Version.checkVersion -> gtk.global.checkVersion (returns null, not "",
 *    when compatible — .length == 0 still works).
 *  - getWindows() returns gtk.window.Window[] directly (no ListG.toArray).
 *  - Pixbuf ctors -> Pixbuf.newFromFile/newFromFileAtScale (throw ErrorWrap);
 *    GException -> glib.error.ErrorWrap; explicit .destroy() on Pixbuf/
 *    ImageSurface dropped (giD objects are GC-managed); cairo ImageSurface ->
 *    cairo.surface.Surface (giD binds cairo procedurally — matches the ported
 *    gx.gtk.cairo renderImage signatures, so getBackgroundImage() now returns
 *    Surface).
 *  - GSettings.addOnChanged(dg) -> connectChanged(null, dg) (detail first,
 *    null = all keys); Settings.getDefault.addOnNotify(dg, "gtk-theme-name",
 *    AFTER) -> connectNotify("gtk-theme-name", dg, Yes.After) (detail first).
 *  - loadProfileShortcuts: GtkD's explicit gsProfile.destroy() dropped (no
 *    such unref helper in giD; wrapper is GC-managed).
 *  - warnVTEConfigIssue/MessageDialog: no varargs ctor in giD — raw-less
 *    builder().build() + property setters + addButton (gx.gtk.dialog pattern);
 *    getMessageArea() returns Widget, cast to Box; new Image(name, size) ->
 *    Image.newFromIconName; new CheckButton(label) -> CheckButton.newWithLabel.
 *  - addAccelerator(accel, action, param) is bound (deprecated in GTK 3.14+)
 *    and used as-is for profile shortcuts, matching GtkD behavior.
 *  - glib.Util.getUserConfigDir -> glib.global.getUserConfigDir; glib.Str gone.
 *  - Enums: PascalCase members from gio.types/glib.types/gtk.types
 *    (ApplicationFlags.HandlesCommandLine, OptionFlags.None, OptionArg.String,
 *    ResponseType.Cancel/DeleteEvent, MessageType.Warning, IconSize.Dialog);
 *    OR-ing ApplicationFlags needs a cast back to the enum type.
 *  - migrateConfigBetween/migrateTreeRecursive and all unit tests unchanged.
 */
module gx.ttyx.application;

import std.algorithm;
import std.conv;
import std.experimental.logger;
import std.file;
import std.format;
import std.path;
import std.process;
import std.stdio;
import std.typecons : No, Yes;

import core.sys.linux.sys.prctl : prctl, PR_SET_DUMPABLE;

import cairo.surface : Surface;

import gdk.screen : Screen;

import gdkpixbuf.pixbuf : Pixbuf;

import gio.action_group : ActionGroup;
import gio.application : GApplication = Application;
import gio.application_command_line : ApplicationCommandLine;
import gio.settings : GSettings = Settings;
import gio.simple_action : SimpleAction;
import gio.types : ApplicationFlags;

import glib.error : ErrorWrap;
import glib.global : getUserConfigDir;
import glib.types : OptionArg, OptionFlags;
import glib.variant : GVariant = Variant;
import glib.variant_type : GVariantType = VariantType;

import gobject.object : ObjectWrap;
import gobject.param_spec : ParamSpec;

import gtk.about_dialog : AboutDialog;
import gtk.application : Application;
import gtk.box : Box;
import gtk.check_button : CheckButton;
import gtk.css_provider : CssProvider;
import gtk.dialog : Dialog;
import gtk.global : checkVersion;
import gtk.image : Image;
import gtk.label : Label;
import gtk.link_button : LinkButton;
import gtk.message_dialog : MessageDialog;
import gtk.settings : Settings;
import gtk.style_context : StyleContext;
import gtk.types : IconSize, MessageType, ResponseType;
import gtk.widget : Widget;
import gtk.window : Window;

import gx.gtk.actions;
import gx.gtk.cairo;
import gx.gtk.resource;
import gx.gtk.util;
import gx.gtk.vte;
import gx.i18n.l10n;

import gx.ttyx.appwindow;
import gx.ttyx.closedialog;
import gx.ttyx.cmdparams;
import gx.ttyx.common;
import gx.ttyx.constants;
import gx.ttyx.preferences;
import gx.ttyx.shortcuts;

import gx.ttyx.bookmark.manager;

import gx.ttyx.prefeditor.prefdialog;

static import gx.util.array;


/**
 * Global variable to application
 */
Tilix tilix;

/**
 * The GTK Application used by Tilix.
 */
class Tilix : Application {

private:

    enum ACTION_NEW_SESSION = "new-session";
    enum ACTION_ACTIVATE_SESSION = "activate-session";
    enum ACTION_ACTIVATE_TERMINAL = "activate-terminal";
    enum ACTION_QUIT = "quit";
    enum ACTION_COMMAND = "command";

    enum THEME_AMBIANCE = "Ambiance";

    enum MAX_BG_WIDTH = 3840;
    enum MAX_BG_HEIGHT = 2160;

    GSettings gsDesktop;
    GSettings gsShortcuts;
    GSettings gsGeneral;
    GSettings gsProxy;

    // GtkD stored the captured default as a gobject.Value; with giD's typed
    // gtkMenuBarAccel property a plain string (plus captured flag) suffices.
    string defaultMenuAccel;
    bool defaultMenuAccelCaptured = false;

    CommandParameters cp;

    AppWindow[] appWindows;
    PreferenceDialog preferenceDialog;

    //Background Image for terminals, store it here as singleton instance
    Surface isFullBGImage;

    bool warnedVTEConfigIssue = false;

    bool useTabs = false;

    bool _processMonitor = false;

    CssProvider themeCssProvider;

    /**
     * Load and register binary resource file and add css files as providers
     */
    void loadResources() {
        //Load resources
        if (findResource(APPLICATION_RESOURCES, true)) {
            foreach (cssFile; APPLICATION_CSS_RESOURCES) {
                string cssURI = APPLICATION_RESOURCE_ROOT ~ "/" ~ cssFile;
                if (!addCssProvider(cssURI, ProviderPriority.APPLICATION)) {
                    warningf("Could not load CSS %s", cssURI);
                } else {
                    tracef("Loaded %s css file", cssURI);
                }
            }
            foreach (cssFile; THEME_CSS_RESOURCES) {
                string cssURI = APPLICATION_RESOURCE_ROOT ~ "/" ~ cssFile;
                if (!addCssProvider(cssURI, ProviderPriority.THEME)) {
                    warningf("Could not load CSS %s", cssURI);
                } else {
                    tracef("Loaded %s css file", cssURI);
                }
            }

            //Check if tilix has a theme specific CSS file to load
            string theme = getGtkTheme();
            string cssURI = APPLICATION_RESOURCE_ROOT ~ "/css/tilix." ~ theme ~ ".css";
            themeCssProvider = addCssProvider(cssURI, ProviderPriority.APPLICATION);
            if (!themeCssProvider) {
                tracef("No specific CSS found %s", cssURI);
            }
        }
    }

    /**
     * Registers the primary menu actions.
     *
	 * This code adapted from grestful (https://github.com/Gert-dev/grestful)
     */
    void setupPrimaryMenuActions() {
        /**
         * Action used to support notifications, when a notification it has this action associated with it
         * along with the sessionUUID
         */
        registerAction(this, ACTION_PREFIX_APP, ACTION_ACTIVATE_SESSION, null, delegate(GVariant value, SimpleAction sa) {
            string sessionUUID = value.getString();
            tracef("activate-session triggered for session %s", sessionUUID);
            foreach (window; appWindows) {
                if (window.activateSession(sessionUUID)) {
                    activateWindow(window);
                    break;
                }
            }
        }, new GVariantType("s"));

        /**
         * Action used to support notifications, when a notification it has this action associated with it
         * along with the terminalUUID
         */
        registerAction(this, ACTION_PREFIX_APP, ACTION_ACTIVATE_TERMINAL, null, delegate(GVariant value, SimpleAction sa) {
            string terminalUUID = value.getString();
            tracef("activate-terminal triggered for terminal %s", terminalUUID);
            foreach (window; appWindows) {
                if (window.activateTerminal(terminalUUID)) {
                    activateWindow(window);
                    break;
                }
            }
        }, new GVariantType("s"));

        registerActionWithSettings(this, ACTION_PREFIX_APP, ACTION_NEW_SESSION, gsShortcuts, delegate(GVariant value, SimpleAction sa) { onCreateNewSession(); });

        registerActionWithSettings(this, ACTION_PREFIX_APP, ACTION_NEW_WINDOW, gsShortcuts, delegate(GVariant value, SimpleAction sa) { onCreateNewWindow(); });

        registerActionWithSettings(this, ACTION_PREFIX_APP, ACTION_PREFERENCES, gsShortcuts, delegate(GVariant value, SimpleAction sa) { onShowPreferences(); });

        if (checkVersion(3, 19, 0).length == 0) {
            registerActionWithSettings(this, ACTION_PREFIX_APP, ACTION_SHORTCUTS, gsShortcuts, delegate(GVariant value, SimpleAction sa) {
                import gtk.shortcuts_window : ShortcutsWindow;

                ShortcutsWindow window = getShortcutWindow();
                if (window is null) return;
                window.setDestroyWithParent(true);
                window.setModal(true);
                window.showAll();
            });
        }

        registerAction(this, ACTION_PREFIX_APP, ACTION_ABOUT, null, delegate(GVariant value, SimpleAction sa) { onShowAboutDialog(); });

        registerAction(this, ACTION_PREFIX_APP, ACTION_QUIT, null, delegate(GVariant value, SimpleAction sa) { quitTilix(); });
    }

    void onCreateNewSession() {
        AppWindow appWindow = cast(AppWindow) getActiveWindow();
        if (appWindow !is null) {
            appWindow.createSession();
        } else {
            onCreateNewWindow();
        }
    }

    void onCreateNewWindow() {
        AppWindow window = getActiveAppWindow();
        if (window !is null && window.hasToplevelFocus()) {
            ITerminal terminal = window.getActiveTerminal();
            if (terminal !is null) {
                cp.workingDir = terminal.currentLocalDirectory();
                ProfileInfo info = prfMgr.getProfile(terminal.defaultProfileUUID());
                cp.profileName = info.name;
            }
        }
        createAppWindow();
        cp.clear();
    }

    void onShowPreferences() {
        presentPreferences();
    }

    /**
     * Shows the about dialog.
     *
	 * This code adapted from grestful (https://github.com/Gert-dev/grestful)
     */
    void onShowAboutDialog() {
        AboutDialog dialog;

        with (dialog = new AboutDialog()) {
            setTransientFor(getActiveWindow());
            setDestroyWithParent(true);
            setModal(true);

            setWrapLicense(true);
            setLogoIconName(null);
            setProgramName(APPLICATION_NAME);
            setComments(_(APPLICATION_COMMENTS));
            setVersion(APPLICATION_VERSION);
            setCopyright(APPLICATION_COPYRIGHT);
            setAuthors(APPLICATION_AUTHORS.dup);
            setArtists(APPLICATION_ARTISTS.dup);
            setDocumenters(APPLICATION_DOCUMENTERS.dup);
            // TRANSLATORS: Please add your name to the list of translators if you want to be credited for the translations you have done.
            setTranslatorCredits(_("translator-credits"));
            setLicense(_(APPLICATION_LICENSE));
            setLogoIconName(APPLICATION_ICON_NAME);

            string[] localizedCredits;
            localizedCredits.length = APPLICATION_CREDITS.length;
            foreach (i, credit; APPLICATION_CREDITS) {
                localizedCredits[i] = _(credit);
            }
            addCreditSection(_("Credits"), localizedCredits);

            connectResponse(delegate(int responseId, Dialog sender) {
                if (responseId == ResponseType.Cancel || responseId == ResponseType.DeleteEvent)
                    sender.hideOnDelete(); // Needed to make the window closable (and hide instead of be deleted).
            });
            connectClose(delegate(Dialog dlg) {
                dlg.destroy();
            });
            present();
        }
    }

    void createAppWindow() {
        AppWindow window = new AppWindow(this, useTabs);
        // Window was being realized here to support inserting Window ID
        // into terminal but had lot's of other issues with it so commented
        // it out.
        //window.realize();
        window.initialize();
        window.showAll();
    }

    void quitTilix() {
        ProcessInformation pi = getProcessesInformation();
        if (pi.children.length > 0) {
            if (!promptCanCloseProcesses(gsGeneral, getActiveWindow(), pi)) return;
        }

        if (preferenceDialog !is null) {
            preferenceDialog.close();
        }

        foreach (window; appWindows) {
            window.closeNoPrompt();
        }
    }

    ProcessInformation getProcessesInformation() {
        ProcessInformation result = ProcessInformation(ProcessInfoSource.APPLICATION, _("ttyx_"), "", []);
        foreach(window; appWindows) {
            ProcessInformation winInfo = window.getProcessInformation();
            if (winInfo.children.length > 0) {
                result.children ~= winInfo;
            }
        }
        return result;
    }

    void loadBackgroundImage() {
        string filename = gsGeneral.getString(SETTINGS_BACKGROUND_IMAGE_KEY);
        // giD cairo surfaces are GC-managed, no explicit destroy
        isFullBGImage = null;
        Pixbuf image;
        try {
            if (exists(filename)) {
                int width, height;
                Pixbuf.getFileInfo(filename, width, height);
                if (width > MAX_BG_WIDTH || height > MAX_BG_HEIGHT) {
                    trace("Background image is too large, scaling");
                    image = Pixbuf.newFromFileAtScale(filename, MAX_BG_WIDTH, MAX_BG_HEIGHT, true);
                } else {
                    image = Pixbuf.newFromFile(filename);
                }
                isFullBGImage = renderImage(image, true);
            }
        } catch (ErrorWrap ge) {
            errorf("Could not load image '%s'", filename);
        }
    }

    int onCommandLine(ApplicationCommandLine acl, GApplication app) {
        trace("App processing command line");
        scope (exit) {
            cp.clear();
            acl.setExitStatus(cp.exitCode);
            // GtkD passed Scoped!ApplicationCommandLine, which unref'd the
            // command-line object when the handler returned — that final unref
            // is what signals a remote `ttyx -a ...` invocation to exit. giD's
            // wrapper holds its ref until GC, leaving the remote hanging, so
            // drop it eagerly (wrapper dtor → g_object_unref).
            acl.destroy();
        }
        cp = CommandParameters(acl);
        if (cp.exit) {
            return cp.exitCode;
        }
        if (cp.exitCode == 0 && cp.action.length > 0) {
            string terminalUUID = cp.terminalUUID;
            if (terminalUUID.length == 0) {
                AppWindow window = getActiveAppWindow();
                if (window !is null) terminalUUID = window.getActiveTerminalUUID();
            }
            //If workingDir is not set, override it with cwd so that it takes priority for
            //executing actions below
            if (cp.workingDir.length == 0 && cp.cwd.length > 0) {
                cp.workingDir = cp.cwd;
            }
            tracef("Executing action %s with working-dir %s", cp.action, cp.workingDir);
            Widget widget = executeAction(terminalUUID, cp.action);
            if (cp.focusWindow && widget !is null) {
                Window window = cast(Window) widget.getToplevel();
                if (window !is null) {
                    trace("Focusing window after action");
                    activateWindow(window);
                }
            }
            return cp.exitCode;
        }
        trace("Activating app");

        if (acl.getIsRemote()) {
            // Check if quake mode or preferences was passed and we have quake window already then
            // just toggle visibility or create quake window. If there isn't a quake window
            // fall through and let activate create one
            if (cp.preferences) {
                presentPreferences();
            } else if (cp.quake) {
                AppWindow qw = getQuakeWindow();
                if (qw !is null) {
                    if (qw.isVisible()) {
                        qw.hide();
                    } else {
                        activateWindow(qw);
                        qw.getActiveTerminal().focusTerminal();
                    }
                    return 0;
                }
            } else {
                AppWindow aw = getActiveAppWindow();
                if (aw !is null) {
                    string instanceAction = gsGeneral.getString(SETTINGS_NEW_INSTANCE_MODE_KEY);
                    //If focus-window command line parameter was passed, override setting
                    if (cp.focusWindow) instanceAction = SETTINGS_NEW_INSTANCE_MODE_FOCUS_WINDOW_VALUE;
                    switch (instanceAction) {
                        //New Session
                        case SETTINGS_NEW_INSTANCE_MODE_NEW_SESSION_VALUE:
                            activateWindow(aw);
                            if (cp.session.length > 0) {
                                // This will use global override and load sessions
                                aw.initialize();
                            } else {
                                aw.createSession();
                            }
                            return cp.exitCode;
                        //Split Right, Split Down
                        case SETTINGS_NEW_INSTANCE_MODE_SPLIT_RIGHT_VALUE, SETTINGS_NEW_INSTANCE_MODE_SPLIT_DOWN_VALUE:
                            if (cp.session.length > 0) break;
                            activateWindow(aw);
                            //If workingDir is not set, override it with cwd so that it takes priority for
                            //executing actions below
                            if (cp.workingDir.length == 0) {
                                cp.workingDir = cp.cwd;
                            }
                            if (instanceAction == SETTINGS_NEW_INSTANCE_MODE_SPLIT_RIGHT_VALUE)
                                executeAction(aw.getActiveTerminalUUID, AppWindow.ACTION_PREFIX ~ "-" ~ AppWindow.ACTION_SESSION_ADD_RIGHT);
                            else
                                executeAction(aw.getActiveTerminalUUID, AppWindow.ACTION_PREFIX ~ "-" ~ AppWindow.ACTION_SESSION_ADD_DOWN);

                            return cp.exitCode;
                        //Focus Window
                        case SETTINGS_NEW_INSTANCE_MODE_FOCUS_WINDOW_VALUE:
                            trace("Focus existing window");
                            if (cp.session.length > 0) {
                                // This will use global override and load sessions
                                aw.initialize();
                            }
                            activateWindow(aw);
                            aw.getActiveTerminal().focusTerminal();
                            return cp.exitCode;
                        default:
                            //Fall through to activate
                    }
                }
            }
        }
        activate();
        return cp.exitCode;
    }

    void onAppActivate(GApplication app) {
        trace("Activate App Signal");
        if (!app.getIsRemote()) {
            if (cp.preferences) presentPreferences();
            else createAppWindow();
        }
        cp.clear();
    }

    void handleThemeChange(ParamSpec pspec, ObjectWrap obj) {
        string theme = getGtkTheme();
        trace("Theme changed to " ~ theme);
        if (themeCssProvider !is null) {
            StyleContext.removeProviderForScreen(Screen.getDefault(), themeCssProvider);
            themeCssProvider = null;
        }
        //Check if tilix has a theme specific CSS file to load
        string cssURI = APPLICATION_RESOURCE_ROOT ~ "/css/tilix." ~ theme ~ ".css";
        themeCssProvider = addCssProvider(cssURI, ProviderPriority.APPLICATION);
        if (!themeCssProvider) {
            tracef("No specific CSS found %s", cssURI);
        }
        onThemeChange.emit();
    }

    void onAppStartup(GApplication app) {
        trace("Startup App Signal");
        Settings.getDefault.connectNotify("gtk-theme-name", &handleThemeChange, Yes.After);
        loadResources();
        gsDesktop = new GSettings(SETTINGS_DESKTOP_ID);
        gsDesktop.connectChanged(null, delegate(string key, GSettings settings) {
            if (key == SETTINGS_COLOR_SCHEME_KEY) {
                applyPreference(SETTINGS_THEME_VARIANT_KEY);
            }
        });
        gsShortcuts = new GSettings(SETTINGS_KEY_BINDINGS_ID);
        gsShortcuts.connectChanged(null, delegate(string key, GSettings settings) {
            string actionName = keyToDetailedActionName(key);
            //trace("Updating shortcut '" ~ actionName ~ "' to '" ~ gsShortcuts.getString(key) ~ "'");
            setShortcut(actionName, gsShortcuts.getString(key));
        });
        gsGeneral = new GSettings(SETTINGS_ID);
        // Set this once globally because it affects more then current window (i.e. shortcuts)
        useTabs = gsGeneral.getBoolean(SETTINGS_USE_TABS_KEY);
        _processMonitor = gsGeneral.getBoolean(SETTINGS_PROCESS_MONITOR);
        gsGeneral.connectChanged(null, delegate(string key, GSettings settings) {
            applyPreference(key);
        });

        migrateConfigFromTilix();
        initProfileManager();
        initBookmarkManager();
        bmMgr.load();
        applyPreferences();
        setupPrimaryMenuActions();
        loadProfileShortcuts();
    }

    void setShortcut(string actionName, string shortcut) {
        if (shortcut == SHORTCUT_DISABLED) {
            // giD marshals an empty accels array as a NULL-terminated empty C
            // array, so no raw gtk_application_set_accels_for_action hack is
            // needed. Call super. to bypass the paste-accel override, exactly
            // like the GtkD original's raw C call did.
            super.setAccelsForAction(actionName, []);
            trace("Removing accelerator");
        } else {
            setAccelsForAction(actionName, [shortcut]);
        }
    }

    /**
     * Load profile shortcuts
     */
    void loadProfileShortcuts() {
        // Load profile shortcuts
        string[] uuids = prfMgr.getProfileUUIDs();
        foreach(uuid; uuids) {
            GSettings gsProfile = prfMgr.getProfileSettings(uuid);
            string key = gsProfile.getString(SETTINGS_PROFILE_SHORTCUT_KEY);
            if (key != SHORTCUT_DISABLED) {
                addAccelerator(key, getActionDetailedName(ACTION_PREFIX_TERMINAL, ACTION_PROFILE_SELECT), new GVariant(uuid));
            }
        }
    }

    void onAppShutdown(GApplication app) {
        trace("Quit App Signal");
        if (bmMgr.hasChanged()) {
            bmMgr.save();
        }
        tilix = null;
    }

    /**
     * Migrate config directory from ~/.config/tilix/ to ~/.config/ttyx/
     * on first run after switching from Tilix. Delegates to the
     * testable free function migrateConfigBetween.
     */
    void migrateConfigFromTilix() {
        string oldConfig = buildPath(getUserConfigDir(), "tilix");
        string newConfig = buildPath(getUserConfigDir(), APPLICATION_CONFIG_FOLDER);
        migrateConfigBetween(oldConfig, newConfig);
    }

    void applyPreferences() {
        foreach(key; [SETTINGS_THEME_VARIANT_KEY,SETTINGS_MENU_ACCELERATOR_KEY,SETTINGS_ACCELERATORS_ENABLED,SETTINGS_BACKGROUND_IMAGE_KEY,SETTINGS_CORE_DUMP_PROTECTION]) {
            applyPreference(key);
        }
    }

    void applyPreference(string key) {
        switch (key) {
            case SETTINGS_THEME_VARIANT_KEY:
                bool darkMode = false;
                bool reset = false;
                string theme = gsGeneral.getString(SETTINGS_THEME_VARIANT_KEY);
                if (theme == SETTINGS_THEME_VARIANT_DARK_VALUE || theme == SETTINGS_THEME_VARIANT_LIGHT_VALUE) {
                    darkMode = (SETTINGS_THEME_VARIANT_DARK_VALUE == theme);
                } else {
                    string colorSchemePreference = gsDesktop.getString(SETTINGS_COLOR_SCHEME_KEY);
                    if (colorSchemePreference !is null) {
                        darkMode = (colorSchemePreference == SETTINGS_COLOR_SCHEME_PREFER_DARK_VALUE);
                    } else {
                        reset = true;
                    }
                }

                if (reset) {
                    // gtk_settings_reset_property is bound in giD (GtkD lacked
                    // it, hence the original's version-gated comment)
                    if (checkVersion(3, 19, 0).length == 0) {
                        Settings.getDefault.resetProperty(GTK_APP_PREFER_DARK_THEME);
                    }
                } else {
                    Settings.getDefault().gtkApplicationPreferDarkTheme = darkMode;
                }
                onThemeChange.emit();
                clearBookmarkIconCache();
                break;
            case SETTINGS_MENU_ACCELERATOR_KEY:
                if (!defaultMenuAccelCaptured) {
                    defaultMenuAccel = Settings.getDefault().gtkMenuBarAccel;
                    defaultMenuAccelCaptured = true;
                    trace("Default menu accelerator is " ~ defaultMenuAccel);
                }
                if (!gsGeneral.getBoolean(SETTINGS_MENU_ACCELERATOR_KEY)) {
                    Settings.getDefault().gtkMenuBarAccel = "";
                } else {
                    Settings.getDefault().gtkMenuBarAccel = defaultMenuAccel;
                }
                break;
            case SETTINGS_ACCELERATORS_ENABLED:
                Settings.getDefault().gtkEnableAccels = gsGeneral.getBoolean(SETTINGS_ACCELERATORS_ENABLED);
                break;
            case SETTINGS_BACKGROUND_IMAGE_KEY, SETTINGS_BACKGROUND_IMAGE_MODE_KEY, SETTINGS_BACKGROUND_IMAGE_SCALE_KEY:
                if (key == SETTINGS_BACKGROUND_IMAGE_KEY) {
                    loadBackgroundImage();
                }
                foreach(window; appWindows) {
                    window.updateBackgroundImage();
                }
                break;
            case SETTINGS_CORE_DUMP_PROTECTION:
                size_t dumpable = gsGeneral.getBoolean(SETTINGS_CORE_DUMP_PROTECTION) ? 0 : 1;
                if (prctl(PR_SET_DUMPABLE, dumpable, 0, 0, 0) != 0) {
                    warning("Failed to set PR_SET_DUMPABLE");
                }
                break;
            default:
                break;
        }
    }

    Widget executeAction(string terminalUUID, string action) {
        trace("Executing action " ~ action);
        string prefix;
        string actionName;
        getActionNameFromKey(action, prefix, actionName);
        Widget widget = findWidgetForUUID(terminalUUID);
        Widget result = widget;
        while (widget !is null) {
            ActionGroup group = widget.getActionGroup(prefix);
            if (group !is null && group.hasAction(actionName)) {
                tracef("Activating action for prefix=%s and action=%s", prefix, actionName);
                group.activateAction(actionName, null);
                return result;
            }
            widget = widget.getParent();
        }
        //Check if the action belongs to the app
        if (prefix == ACTION_PREFIX_APP) {
            activateAction(actionName, null);
            return result;
        }
        warningf("Could not find action for prefix=%s and action=%s", prefix, actionName);
        return result;
    }

    /**
     * Returns the most active AppWindow, ignores preference
     * windows
     */
    AppWindow getActiveAppWindow() {
        AppWindow appWindow = cast(AppWindow)getActiveWindow();
        if (appWindow !is null) return appWindow;

        Window[] windows = getWindows();
        foreach(window; windows) {
            appWindow = cast(AppWindow) window;
            if (appWindow !is null) return appWindow;
        }
        return null;
    }

    AppWindow getQuakeWindow() {
        Window[] windows = getWindows();
        foreach(window; windows) {
            AppWindow appWindow = cast(AppWindow) window;
            if (appWindow !is null && appWindow.isQuake()) return appWindow;
        }
        return null;
    }

    /**
     * Add main options supported by application
     */
    void addOptions() {
        addMainOption(CMD_WORKING_DIRECTORY, 'w', OptionFlags.None, OptionArg.String, _("Set the working directory of the terminal"), _("DIRECTORY"));
        addMainOption(CMD_PROFILE, 'p', OptionFlags.None, OptionArg.String, _("Set the starting profile"), _("PROFILE_NAME"));
        addMainOption(CMD_TITLE, 't', OptionFlags.None, OptionArg.String, _("Set the title of the new terminal"), _("TITLE"));
        addMainOption(CMD_SESSION, 's', OptionFlags.None, OptionArg.StringArray, _("Open the specified session"), _("SESSION_NAME"));
        if (checkVersion(3, 16, 0).length == 0) {
            addMainOption(CMD_ACTION, 'a', OptionFlags.None, OptionArg.String, _("Send an action to current ttyx_ instance"), _("ACTION_NAME"));
        }
        addMainOption(CMD_COMMAND, 'e', OptionFlags.None, OptionArg.String, _("Execute the parameter as a command"), _("COMMAND"));
        addMainOption(CMD_MAXIMIZE, '\0', OptionFlags.None, OptionArg.None, _("Maximize the terminal window"), null);
        addMainOption(CMD_MINIMIZE, '\0', OptionFlags.None, OptionArg.None, _("Minimize the terminal window"), null);
        addMainOption(CMD_WINDOW_STYLE, '\0', OptionFlags.None, OptionArg.String, _("Override the preferred window style to use, one of: normal,disable-csd,disable-csd-hide-toolbar,borderless"), _("WINDOW_STYLE"));
        addMainOption(CMD_FULL_SCREEN, '\0', OptionFlags.None, OptionArg.None, _("Full-screen the terminal window"), null);
        addMainOption(CMD_FOCUS_WINDOW, '\0', OptionFlags.None, OptionArg.None, _("Focus the existing window"), null);
        addMainOption(CMD_NEW_PROCESS, '\0', OptionFlags.None, OptionArg.None, _("Start additional instance as new process (Not Recommended)"), null);
        addMainOption(CMD_GEOMETRY, '\0', OptionFlags.None, OptionArg.String, _("Set the window size; for example: 80x24, or 80x24+200+200 (COLSxROWS+X+Y)"), _("GEOMETRY"));
        addMainOption(CMD_QUAKE, 'q', OptionFlags.None, OptionArg.None, _("Opens a window in quake mode or toggles existing quake mode window visibility"), null);
        addMainOption(CMD_VERSION, 'v', OptionFlags.None, OptionArg.None, _("Show ttyx_ and dependent component versions"), null);
        addMainOption(CMD_PREFERENCES, '\0', OptionFlags.None, OptionArg.None, _("Show the ttyx_ preferences dialog directly"), null);
        addMainOption(CMD_GROUP, 'g', OptionFlags.None, OptionArg.String, _("Group ttyx_ instances into different processes (Experimental, not recommended)"), _("GROUP_NAME"));

        //Hidden options used to communicate with primary instance
        addMainOption(CMD_TERMINAL_UUID, '\0', OptionFlags.Hidden, OptionArg.String, _("Hidden argument to pass terminal UUID"), _("TERMINAL_UUID"));
    }

public:

    this(bool newProcess, string group=null) {
        ApplicationFlags flags = ApplicationFlags.HandlesCommandLine;
        if (newProcess) flags = cast(ApplicationFlags)(flags | ApplicationFlags.NonUnique);
        super(APPLICATION_ID, flags);

        if (group.length > 0) {
            string id = "io.github.gwelr.ttyx." ~ group;
            if (GApplication.idIsValid(id)) {
                tracef("Setting app id to %s", id);
                setApplicationId(id);
            } else {
                warningf(_("The application ID %s is not valid"));
            }
        }

        addOptions();

        this.connectActivate(&onAppActivate);
        this.connectStartup(&onAppStartup);
        this.connectShutdown(&onAppShutdown);
        this.connectCommandLine(&onCommandLine);
        tilix = this;
    }

    /**
     * Executes a command by invoking the command action.
     * This is used to invoke a command on a remote instance of
     * the GTK Application leveraging the ability for the remote
     * instance to trigger actions on the primary instance.
     *
     * See https://wiki.gnome.org/HowDoI/GtkApplication
     */
    void executeCommand(string command, string terminalID, string cmdLine) {
        GVariant[] param = [new GVariant(command), new GVariant(terminalID), new GVariant(cmdLine)];
        activateAction(ACTION_COMMAND, GVariant.newTuple(param));
    }

    bool isQuake() {
        AppWindow appWindow = cast(AppWindow) getActiveWindow();
        if (appWindow !is null && appWindow.isQuake()) {
            return true;
        }
        return cp.quake;
    }

    void addAppWindow(AppWindow window) {
        appWindows ~= window;
        //GTK add window
        addWindow(window);
    }

    void removeAppWindow(AppWindow window) {
        gx.util.array.remove(appWindows, window);
        removeWindow(window);
    }

    /**
    * This searches across all Windows to find
    * a widget that matches the UUID specified. At the
    * moment this would be a session or a terminal.
    *
    * This is used for any operations that span windows, at
    * the moment there is just one, dragging a terminal from
    * one Window to the next.
    *
    * TODO - Convert this into a template to eliminate casting
    *        by callers
    */
    Widget findWidgetForUUID(string uuid) {

        foreach (window; appWindows) {
            trace("Finding widget " ~ uuid);
            trace("Checking app window");
            Widget result = window.findWidgetForUUID(uuid);
            if (result !is null) {
                return result;
            }
        }
        return null;
    }

    void presentPreferences() {
        import core.memory : GC;

        tracef("*** Application ID %s",getApplicationId());

        //Check if preference window already exists
        if (preferenceDialog !is null) {
            AppWindow window = getActiveAppWindow();
            if (window != preferenceDialog.getParent()) {
                preferenceDialog.setTransientFor(window);
            }
            preferenceDialog.present();
            return;
        }
        //Otherwise create it and save the ID
        trace("Creating preference window");
        // Disable GC during dialog construction to prevent the D garbage
        // collector from finalizing temporary wrapper objects while
        // GTK is still building the widget tree and CSS style cache.
        // On GLib 2.84+ (e.g. Flatpak GNOME 48 runtime), premature
        // finalization corrupts CSS node style cache ref counts, causing
        // a crash in gtk_css_node_style_cache_unref.
        GC.disable();
        scope(exit) GC.enable();
        preferenceDialog = new PreferenceDialog(getActiveAppWindow());
        preferenceDialog.connectDestroy(delegate(Widget widget) {
            trace("Remove preference window reference");
            preferenceDialog = null;
        });
        preferenceDialog.showAll();
        preferenceDialog.present;
    }

    void presentProfilePreferences(ProfileInfo profile) {
        presentPreferences();
        preferenceDialog.focusProfile(profile.uuid);
    }

    void presentEncodingPreferences() {
        presentPreferences();
        preferenceDialog.focusEncoding();
    }

    bool testVTEConfig() {
        return !warnedVTEConfigIssue && gsGeneral.getBoolean(SETTINGS_WARN_VTE_CONFIG_ISSUE_KEY);
    }

    /**
     * Add additional accelerators to force paste actions to always go
     * through Tilix, see #666 fore more information.
     *
     * giD's generated setAccelsForAction is nothrow, so the override must be
     * nothrow too; the non-nothrow name helper is wrapped.
     */
    override void setAccelsForAction(string detailedActionName, string[] accels) nothrow {
        import gx.ttyx.terminal.actions;

        try {
            if (detailedActionName == getActionDetailedName(gx.ttyx.terminal.actions.ACTION_PREFIX, gx.ttyx.terminal.actions.ACTION_PASTE)) {
                accels ~= ["<Shift><Ctrl>Insert"];
            } else if (detailedActionName == getActionDetailedName(gx.ttyx.terminal.actions.ACTION_PREFIX, gx.ttyx.terminal.actions.ACTION_PASTE_PRIMARY)) {
                accels ~= ["<Shift>Insert"];
            }
        } catch (Exception) {
        }
        super.setAccelsForAction(detailedActionName, accels);
    }

    /**
     * Even though these are parameters passed on the command-line
     * they are used by the terminal when it is created as a global
     * override and referenced via the application object which is global.
     *
     * Originally I was passing command line parameters to the terminal
     * via the hierarchy App > AppWindow > Session > Terminal but this
     * is unwiedly. It's also not feasible when supporting using the
     * command line to create terminals in the current instance since
     * that uses actions. GIO Actions don't have a way to pass arbrirtary
     * parameters, basically it's not feasible to pass these.
     *
     * When a terminal is created, it will check this global overrides and
     * use it where applicaable. The application is responsible for setiing
     * and clearing these overrides around the terminal creation. Since GTK
     * is single threaded this works fine.
     */
    CommandParameters getGlobalOverrides() {
        return cp;
    }

    /**
     * Note: was GtkD cairo.ImageSurface; giD binds cairo procedurally so the
     * cached background image is a cairo.surface.Surface (matches the ported
     * gx.gtk.cairo renderImage). Callers snapshot semantics are unchanged.
     */
    Surface getBackgroundImage() {
        return isFullBGImage;
    }

    /**
     * Return the GSettings object for the proxy. Used so terminals
     * don't need to constantly re-create this on their own.
     */
    GSettings getProxySettings() {
        if (gsProxy is null) {
            gsProxy = new GSettings(SETTINGS_PROXY_ID);
        }
        return gsProxy;
    }

    /**
     * Shows a dialog when a VTE configuration issue is detected.
     * See Issue #34 and https://github.com/gnunn1/tilix/wiki/VTE-Configuration-Issue
     * for more information.
     */
    void warnVTEConfigIssue() {
        if (testVTEConfig()) {
            warnedVTEConfigIssue = true;
            string msg = _("There appears to be an issue with the configuration of the terminal.\nThis issue is not serious, but correcting it will improve your experience.\nClick the link below for more information:");
            string title = "<span weight='bold' size='larger'>" ~ _("Configuration Issue Detected") ~ "</span>";
            // no `with (dlg)` here: giD's Window.title property would shadow
            // the local title variable inside the with-block
            MessageDialog dlg = MessageDialog.builder().build();
            scope (exit) {
                dlg.destroy();
            }
            dlg.messageType = MessageType.Warning;
            dlg.addButton(_("_OK"), ResponseType.Ok);
            dlg.setModal(true);
            dlg.setTransientFor(getActiveWindow());
            dlg.setMarkup(title);
            Box messageArea = cast(Box) dlg.getMessageArea();
            messageArea.setMarginLeft(0);
            messageArea.setMarginRight(0);
            messageArea.add(new Label(msg));
            messageArea.add(new LinkButton("https://gnunn1.github.io/tilix-web/manual/vteconfig/"));
            CheckButton cb = CheckButton.newWithLabel(_("Do not show this message again"));
            messageArea.add(cb);
            dlg.setImage(Image.newFromIconName("dialog-warning", IconSize.Dialog));
            dlg.showAll();
            dlg.run();
            if (cb.getActive()) {
                gsGeneral.setBoolean(SETTINGS_WARN_VTE_CONFIG_ISSUE_KEY, false);
            }
        }
    }

    /**
    * When true asynchronous process monitoring is enabled. This
    * will watch the shell process for new child processes and
    * raise events when detected. Since this uses polling, quick
    * commands (ls, cd, etc) may be missed.
    */
    @property bool processMonitor() {
        return _processMonitor;
    }

// Events
public:
    /**
    * Invoked when the GTK theme or theme-variant has changed. While
    * things could listen to gtk.Settings.addOnNotify directly,
    * because this is a long lived object and GtkD doesn't provide a
    * way to remove listeners it will lead to memory leaks so we use
    * this instead
    */
    GenericEvent!() onThemeChange;
}

/**
 * Core migration logic, parameterized for testability.
 *
 * Copies oldConfig into newConfig only if:
 *   - oldConfig exists and is not a symlink (don't follow a symlink root)
 *   - newConfig does not exist (including not as a dangling symlink)
 *
 * Returns true if the migration ran to completion, false otherwise.
 * See #49 for the attack vectors this guards against.
 */
package bool migrateConfigBetween(string oldConfig, string newConfig) {
    import std.file : exists, getLinkAttributes, attrIsSymlink, mkdir;

    if (!exists(oldConfig)) return false;

    // If oldConfig is itself a symlink, refuse — don't follow it.
    try {
        if (getLinkAttributes(oldConfig).attrIsSymlink) {
            warning("Config migration skipped: " ~ oldConfig ~ " is a symlink");
            return false;
        }
    } catch (Exception e) {
        warning("Config migration skipped: could not stat " ~ oldConfig);
        return false;
    }

    // Refuse if anything exists at newConfig — including a dangling
    // symlink, which plain exists() would report as absent.
    try {
        getLinkAttributes(newConfig);
        return false; // already migrated or something is there
    } catch (Exception) {
        // newConfig doesn't exist, proceed
    }

    try {
        // mkdir (not mkdirRecurse) errors if path exists, including
        // as a symlink — provides some TOCTOU resistance.
        mkdir(newConfig);
        migrateTreeRecursive(oldConfig, newConfig);
        info("Migrated config from " ~ oldConfig ~ " to " ~ newConfig);
        return true;
    } catch (Exception e) {
        warning("Config migration failed: " ~ e.msg);
        return false;
    }
}

/**
 * Walk src recursively, mirroring regular files and directories into
 * dst. Symlinks are skipped with a warning. Paths that already exist
 * at dst are skipped. Uses getLinkAttributes and SpanMode.shallow with
 * followSymlink=false so the walker never follows a symlink.
 *
 * Free function (not a class method) so it can be unit-tested against
 * temp directories without constructing a full Tilix application.
 */
package void migrateTreeRecursive(string src, string dst) {
    import std.file : DirEntry, SpanMode, dirEntries, getLinkAttributes,
                      attrIsSymlink, mkdir, copy;
    import std.path : buildPath, baseName;

    foreach (DirEntry entry; dirEntries(src, SpanMode.shallow, false)) {
        string name = baseName(entry.name);
        string target = buildPath(dst, name);

        if (entry.isSymlink) {
            warning("Skipping symlink during migration: " ~ entry.name);
            continue;
        }

        // Check target doesn't already exist (including as a symlink).
        // getLinkAttributes catches dangling symlinks that plain exists()
        // would miss.
        try {
            getLinkAttributes(target);
            warning("Skipping existing target during migration: " ~ target);
            continue;
        } catch (Exception) {
            // target doesn't exist, good, proceed
        }

        if (entry.isDir) {
            mkdir(target);
            migrateTreeRecursive(entry.name, target);
        } else if (entry.isFile) {
            copy(entry.name, target);
        }
        // else: socket, pipe, device, etc. — skip silently.
    }
}

// -- Unit tests for migrateTreeRecursive --

version (unittest) {
    import std.file : mkdir, mkdirRecurse, rmdirRecurse, write,
                      symlink, exists, readText, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;
}

/// Source symlinks are skipped, regular files are copied.
unittest {
    string tmpRoot = buildPath(tempDir(), "ttyx-migration-test-" ~ randomUUID.toString);
    scope(exit) {
        if (exists(tmpRoot)) rmdirRecurse(tmpRoot);
    }
    string src = buildPath(tmpRoot, "src");
    string dst = buildPath(tmpRoot, "dst");

    mkdirRecurse(src);
    write(buildPath(src, "safe.txt"), "ok");
    symlink("/etc/passwd", buildPath(src, "evil"));
    mkdir(dst);

    migrateTreeRecursive(src, dst);

    assert(exists(buildPath(dst, "safe.txt")));
    assert(!exists(buildPath(dst, "evil")), "symlink should have been skipped");
}

/// Existing files at the destination are preserved, not overwritten.
unittest {
    string tmpRoot = buildPath(tempDir(), "ttyx-migration-test-" ~ randomUUID.toString);
    scope(exit) {
        if (exists(tmpRoot)) rmdirRecurse(tmpRoot);
    }
    string src = buildPath(tmpRoot, "src");
    string dst = buildPath(tmpRoot, "dst");

    mkdirRecurse(src);
    write(buildPath(src, "file.txt"), "from_source");
    mkdir(dst);
    write(buildPath(dst, "file.txt"), "preexisting");

    migrateTreeRecursive(src, dst);

    assert(readText(buildPath(dst, "file.txt")) == "preexisting");
}

/// Nested directories are mirrored correctly.
unittest {
    string tmpRoot = buildPath(tempDir(), "ttyx-migration-test-" ~ randomUUID.toString);
    scope(exit) {
        if (exists(tmpRoot)) rmdirRecurse(tmpRoot);
    }
    string src = buildPath(tmpRoot, "src");
    string dst = buildPath(tmpRoot, "dst");

    mkdirRecurse(buildPath(src, "a", "b"));
    write(buildPath(src, "a", "b", "deep.txt"), "deep_content");
    mkdir(dst);

    migrateTreeRecursive(src, dst);

    assert(exists(buildPath(dst, "a", "b", "deep.txt")));
    assert(readText(buildPath(dst, "a", "b", "deep.txt")) == "deep_content");
}

/// Symlinked directories in source are skipped entirely (not traversed).
unittest {
    string tmpRoot = buildPath(tempDir(), "ttyx-migration-test-" ~ randomUUID.toString);
    scope(exit) {
        if (exists(tmpRoot)) rmdirRecurse(tmpRoot);
    }
    string src = buildPath(tmpRoot, "src");
    string dst = buildPath(tmpRoot, "dst");
    string outside = buildPath(tmpRoot, "outside");

    mkdirRecurse(src);
    mkdirRecurse(outside);
    write(buildPath(outside, "secret.txt"), "exfiltrated");
    symlink(outside, buildPath(src, "link-to-outside"));
    mkdir(dst);

    migrateTreeRecursive(src, dst);

    // The symlink should not have been followed, so the outside file
    // should not appear in dst.
    assert(!exists(buildPath(dst, "link-to-outside")));
    assert(!exists(buildPath(dst, "link-to-outside", "secret.txt")));
}

// -- Unit tests for migrateConfigBetween --

/// Normal case: src has content, dst doesn't exist, migration runs.
unittest {
    string tmpRoot = buildPath(tempDir(), "ttyx-migration-test-" ~ randomUUID.toString);
    scope(exit) {
        if (exists(tmpRoot)) rmdirRecurse(tmpRoot);
    }
    string src = buildPath(tmpRoot, "tilix");
    string dst = buildPath(tmpRoot, "ttyx");

    mkdirRecurse(src);
    write(buildPath(src, "config.json"), "{}");

    assert(migrateConfigBetween(src, dst));
    assert(exists(buildPath(dst, "config.json")));
}

/// Refuses if source root is itself a symlink (attack: symlink ~/.config/tilix to /etc).
unittest {
    string tmpRoot = buildPath(tempDir(), "ttyx-migration-test-" ~ randomUUID.toString);
    scope(exit) {
        if (exists(tmpRoot)) rmdirRecurse(tmpRoot);
    }
    string realDir = buildPath(tmpRoot, "real");
    string srcLink = buildPath(tmpRoot, "tilix");
    string dst = buildPath(tmpRoot, "ttyx");

    mkdirRecurse(realDir);
    write(buildPath(realDir, "sensitive.txt"), "secret");
    symlink(realDir, srcLink);

    assert(!migrateConfigBetween(srcLink, dst));
    assert(!exists(dst), "dst should not have been created when src is a symlink");
}

/// Refuses if dest is a dangling symlink (attack: symlink ~/.config/ttyx to attacker-writable path).
unittest {
    string tmpRoot = buildPath(tempDir(), "ttyx-migration-test-" ~ randomUUID.toString);
    scope(exit) {
        if (exists(tmpRoot)) rmdirRecurse(tmpRoot);
    }
    string src = buildPath(tmpRoot, "tilix");
    string dst = buildPath(tmpRoot, "ttyx");
    string target = buildPath(tmpRoot, "nonexistent");

    mkdirRecurse(src);
    write(buildPath(src, "a.txt"), "payload");
    // Create dangling symlink at dst pointing to a path that doesn't exist.
    symlink(target, dst);

    assert(!migrateConfigBetween(src, dst));
    assert(!exists(target), "dangling symlink should not have been written through");
}

/// Refuses if destination already exists as a regular directory.
unittest {
    string tmpRoot = buildPath(tempDir(), "ttyx-migration-test-" ~ randomUUID.toString);
    scope(exit) {
        if (exists(tmpRoot)) rmdirRecurse(tmpRoot);
    }
    string src = buildPath(tmpRoot, "tilix");
    string dst = buildPath(tmpRoot, "ttyx");

    mkdirRecurse(src);
    write(buildPath(src, "a.txt"), "new");
    mkdirRecurse(dst);
    write(buildPath(dst, "existing.txt"), "keep");

    assert(!migrateConfigBetween(src, dst));
    // Existing content is preserved; nothing from src was copied.
    assert(exists(buildPath(dst, "existing.txt")));
    assert(!exists(buildPath(dst, "a.txt")));
}

/// Returns false when source doesn't exist (no migration needed).
unittest {
    string tmpRoot = buildPath(tempDir(), "ttyx-migration-test-" ~ randomUUID.toString);
    scope(exit) {
        if (exists(tmpRoot)) rmdirRecurse(tmpRoot);
    }
    string src = buildPath(tmpRoot, "tilix");
    string dst = buildPath(tmpRoot, "ttyx");

    // src is never created.
    assert(!migrateConfigBetween(src, dst));
    assert(!exists(dst));
}
