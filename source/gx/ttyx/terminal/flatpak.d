/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/ttyx/terminal/flatpak.d. The GtkD original leaned on
 * raw C for two things giD handles natively, so both go away:
 *   - g_variant_new varargs ("(^ay^aay@a{uh}@a{ss}u)") → typed Variant
 *     constructors (newBytestring / newBytestringArray / newDictEntry /
 *     newHandle / newUint32 / newTuple). The two VariantBuilders stay so the
 *     a{uh} / a{ss} arrays are correctly typed even when empty.
 *   - the extern(C) HostCommandExited D-Bus callback + manual GC.addRoot →
 *     signalSubscribe takes a D delegate (giD freezes/thaws it internally);
 *     shared spawn/exit state lives in a heap struct captured by the closure.
 * Also: callWithUnixFdListSync signals failure by throwing glib.error.ErrorWrap
 * (GtkD returned null), and GtkD's manual connection.doref() is dropped —
 * giD wrappers own their refs.
 */
module gx.ttyx.terminal.flatpak;

private:

import std.conv;
import std.experimental.logger;
import std.format;
import std.string;

import gio.dbus_connection : DBusConnection;
import gio.types : DBusCallFlags, DBusConnectionFlags, DBusSignalFlags;
import gio.unix_fdlist : UnixFDList;

import glib.error : ErrorWrap;
import glib.global : getHomeDir;
import glib.key_file : KeyFile;
import glib.main_context : MainContext;
import glib.types : KeyFileFlags;
import glib.variant : GVariant = Variant;
import glib.variant_builder : GVariantBuilder = VariantBuilder;
import glib.variant_type : GVariantType = VariantType;

import gx.util.redact : redactSensitive;

/// Delegate type for receiving host command exit notifications.
package alias HostCommandExitedCallback = void delegate(int);

/// Shared state between sendHostCommand and the HostCommandExited signal
/// closure. Heap-allocated and captured by the delegate, so no manual GC
/// rooting is needed (giD keeps the frozen delegate alive until unsubscribe).
struct HostCommandExitedArgs {
    HostCommandExitedCallback callback;
    int pid = -1;
    uint signalId = 0u;
    int status = -1;
}

/**
 * Build a GVariant for the Flatpak HostCommand D-Bus call.
 *
 * Constructs the (ay aay a{uh} a{ss} u) variant expected by
 * org.freedesktop.Flatpak.Development.HostCommand.
 */
GVariant buildHostCommandVariant(string workingDir, string[] args, string[] envv, uint[] handles) {
    if (workingDir.length == 0) workingDir = getHomeDir();

    GVariantBuilder fdBuilder = new GVariantBuilder(new GVariantType("a{uh}"));
    foreach (i, fd; handles) {
        fdBuilder.addValue(GVariant.newDictEntry(
            GVariant.newUint32(cast(uint) i), GVariant.newHandle(cast(int) fd)));
    }
    GVariantBuilder envBuilder = new GVariantBuilder(new GVariantType("a{ss}"));
    foreach (env; envv) {
        auto eqPos = env.indexOf('=');
        if (eqPos < 1) continue;
        string key = env[0 .. eqPos];
        string val = env[eqPos + 1 .. $];
        tracef("Adding env var %s=%s", key, redactSensitive(key, val));
        envBuilder.addValue(GVariant.newDictEntry(
            GVariant.newString(key), GVariant.newString(val)));
    }

    return GVariant.newTuple([
        GVariant.newBytestring(workingDir),
        GVariant.newBytestringArray(args),
        fdBuilder.end(),
        envBuilder.end(),
        GVariant.newUint32(1)
    ]);
}

package:

/**
 * Send a command to the host via the Flatpak D-Bus Development interface.
 *
 * Returns true on success, with gpid set to the host process ID.
 */
bool sendHostCommand(string workingDir, string[] args, string[] envv, int[] stdio_fds, out int gpid, HostCommandExitedCallback exitedCallback) {
    import std.process : environment;

    uint[] handles;

    UnixFDList outFdList;
    UnixFDList inFdList = new UnixFDList();
    foreach (i, fd; stdio_fds) {
        handles ~= inFdList.append(fd);
        if (handles[i] == cast(uint) -1) {
            warning("Error creating fd list handles");
        }
    }

    DBusConnection connection = DBusConnection.newForAddressSync(
        environment.get("DBUS_SESSION_BUS_ADDRESS"),
        DBusConnectionFlags.AuthenticationClient | DBusConnectionFlags.MessageBusConnection,
        null,
        null
    );
    connection.setExitOnClose(false);

    auto state = new HostCommandExitedArgs();
    state.callback = exitedCallback;

    uint signalId = connection.signalSubscribe(
        "org.freedesktop.Flatpak",
        "org.freedesktop.Flatpak.Development",
        "HostCommandExited",
        "/org/freedesktop/Flatpak/Development",
        null,
        DBusSignalFlags.None,
        delegate(DBusConnection conn, string senderName, string objectPath, string interfaceName, string signalName, GVariant parameters) {
            uint pid = parameters.getChildValue(0).getUint32();
            uint status = parameters.getChildValue(1).getUint32();

            if (state.pid == -1 || pid == state.pid) {
                if (state.pid == -1) {
                    trace("HostCommandExited was emitted before spawn completed.");
                    state.pid = pid;
                    state.status = status;
                } else {
                    conn.signalUnsubscribe(state.signalId);
                    state.callback(status);
                }
            }
        }
    );

    GVariant reply;
    try {
        reply = connection.callWithUnixFdListSync(
            "org.freedesktop.Flatpak",
            "/org/freedesktop/Flatpak/Development",
            "org.freedesktop.Flatpak.Development",
            "HostCommand",
            buildHostCommandVariant(workingDir, args, envv, handles),
            new GVariantType("(u)"),
            DBusCallFlags.None,
            -1,
            inFdList,
            outFdList,
            null
        );
    } catch (ErrorWrap e) {
        warning("No reply from flatpak dbus service: " ~ e.msg);
        connection.signalUnsubscribe(signalId);
        return false;
    }

    uint pid = reply.getChildValue(0).getUint32();
    gpid = pid;

    if (state.pid != -1) {
        trace("HostCommandExited was already emitted");
        connection.signalUnsubscribe(signalId);
        exitedCallback(state.status);
    } else {
        state.pid = pid;
        state.signalId = signalId;
    }

    return true;
}

/**
 * Run a ttyx-flatpak-toolbox command on the host and capture its stdout output.
 *
 * This is a thin wrapper over sendHostCommand that launches the toolbox binary
 * from the Flatpak app-path and waits for it to complete.
 */
string captureHostToolboxCommand(string command, string arg, int[] extra_fds) {
    import std.process : Pipe, pipe;

    KeyFile kf = new KeyFile();
    kf.loadFromFile("/.flatpak-info", KeyFileFlags.None);

    string hostRoot = kf.getString("Instance", "app-path");
    string[] args = [format("%s/bin/ttyx-flatpak-toolbox", hostRoot), command, arg];

    Pipe output = pipe();
    scope(exit) output.close();

    int gpid, status = -1;

    void commandExited(int command_status) {
        status = command_status;
    }

    int[] stdio_fds = [0, output.writeEnd.fileno, 2] ~ extra_fds;

    if (!sendHostCommand("/", args, [], stdio_fds, gpid, &commandExited)) {
        return null;
    }

    MainContext ctx = MainContext.getThreadDefault();
    if (ctx is null) {
        // https://github.com/gtkd-developers/GtkD/issues/247
        ctx = MainContext.default_();
    }

    trace("captureHostToolboxCommand is waiting for status to be filled...");
    while (status == -1) {
        ctx.iteration(true);
    }

    if (status != 0) {
        return null;
    }

    return output.readEnd.readln().strip();
}
