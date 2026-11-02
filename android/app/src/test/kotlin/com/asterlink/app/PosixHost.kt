package com.asterlink.app

import java.io.File
import org.junit.Assume

/**
 * Cases that depend on POSIX-only facilities: the `/proc/self/fd` descriptor
 * bridge, an atomic rename over an existing file (`android.util.AtomicFile`), and
 * real file descriptors handed out by Robolectric.
 *
 * The Android Gradle job runs on a Windows runner, where none of those exist, so
 * the affected cases skip there instead of reporting a false failure. They still
 * run on a Linux host or a device.
 */
object PosixHost {
    /** `/proc/self/fd` exists on Linux only, which is the requirement here. */
    @JvmField val available: Boolean = File("/proc/self/fd").isDirectory

    fun require() = Assume.assumeTrue(
        "Needs a POSIX host: /proc/self/fd, atomic rename over an existing file",
        available,
    )
}
