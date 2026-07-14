/*
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not
 * distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * giD port of source/gx/gtk/threads.d — a large simplification.
 *
 * The GtkD original needed the grestful DelegatePointer/invokeDelegatePointerFunc
 * machinery (C-linkage trampoline + manual GC.addRoot/removeRoot) because
 * gdk.Threads.threadsAddIdle took a raw GSourceFunc. giD's gdk.global bindings
 * take a D `bool delegate()` directly and do all of that internally:
 * freezeDelegate copies the closure into pinned, GC-rooted memory and
 * thawDelegate un-roots it via the GDestroyNotify when the source is removed.
 * So the public API here is unchanged, but each function is now just a closure
 * over giD's delegate-native binding.
 *
 * gdk_threads_add_idle defaults to G_PRIORITY_DEFAULT_IDLE and
 * gdk_threads_add_timeout to G_PRIORITY_DEFAULT in C; giD only exposes the
 * *_full variants, so those priorities are passed explicitly to keep GtkD's
 * scheduling behavior.
 */
module gx.gtk.threads;

import std.experimental.logger;

import gdk.global : threadsAddIdle, threadsAddTimeout;
import glib.types : PRIORITY_DEFAULT, PRIORITY_DEFAULT_IDLE;

/**
 * Convenience method that allows scheduling a delegate to be executed on the main
 * loop's idle cycle instead of a traditional callback with C linkage. The delegate
 * returns true to be called again on the next idle cycle, false to stop.
 *
 * @param theDelegate The delegate to schedule.
 * @param parameters  A tuple of parameters to pass to the delegate when it is invoked.
 *
 * @example
 *     auto myMethod = delegate(string name, string value) { do_something_with_name_and_value(); }
 *     threadsAddIdleDelegate(myMethod, "thisIsAName", "thisIsAValue");
 */
void threadsAddIdleDelegate(T, parameterTuple...)(T theDelegate, parameterTuple parameters)
{
    threadsAddIdle(PRIORITY_DEFAULT_IDLE, delegate bool() {
        try
        {
            return theDelegate(parameters);
        }
        catch (Exception e)
        {
            warning("Unexpected exception occurred in wrapper");
            return false;
        }
    });
}

/**
 * Convenience method that allows scheduling a delegate to be executed at a regular
 * interval instead of a traditional callback with C linkage. The delegate returns
 * true to keep the timeout running, false to destroy it.
 *
 * @param interval The interval to call the delegate in ms
 * @param theDelegate The delegate to schedule.
 * @param parameters  A tuple of parameters to pass to the delegate when it is invoked.
 *
 * @example
 *     auto myMethod = delegate(string name, string value) { do_something_with_name_and_value(); }
 *     threadsAddTimeoutDelegate(1000, myMethod, "thisIsAName", "thisIsAValue");
 */
uint threadsAddTimeoutDelegate(T, parameterTuple...)(uint interval, T theDelegate, parameterTuple parameters)
{
    return threadsAddTimeout(PRIORITY_DEFAULT, interval, delegate bool() {
        try
        {
            return theDelegate(parameters);
        }
        catch (Exception e)
        {
            warning("Unexpected exception occurred in wrapper");
            return false;
        }
    });
}
