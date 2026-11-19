package com.termux.terminal

import kotlin.concurrent.thread

// Termux's TerminalView shows a TerminalSession, which is final and runs a local process through JNI. aOS's terminal
// runs on the Mac and comes over SSH (dev.marquart.aos.terminal.MacTerminal), so the view gets a session that runs
// nothing: its emulator is the one MacTerminal feeds, and what the view types goes to MacTerminal instead of a pty.
// This needs the session's package-private fields, hence this file in Termux's package (the only one aOS has there).

/** Sessions for TerminalView without a process. */
object RemoteTerminalSessions {
    /**
     * A session whose emulator is `emulator` (already fed and sized; the view resizes it) and whose input (keys, the
     * IME, autofill) goes to `sink` in order, on a thread of its own. No process is started: the emulator is there
     * before the view asks for one, the pty descriptor is -1 (the view's window size ioctl does nothing), and the
     * "pid" only marks the session as running so that `write` queues.
     */
    @JvmStatic
    fun create(emulator: TerminalEmulator, client: TerminalSessionClient, sink: (ByteArray) -> Unit): TerminalSession {
        val session = TerminalSession("/system/bin/false", "/", arrayOf(), arrayOf(), null, client)
        session.mEmulator = emulator
        session.mShellPid = Int.MAX_VALUE
        try {
            TerminalSession::class.java.getDeclaredField("mTerminalFileDescriptor").apply { isAccessible = true }.setInt(session, -1)
        } catch (_: ReflectiveOperationException) {
        }
        val queue = session.mTerminalToProcessIOQueue
        thread(name = "aos-terminal-input", isDaemon = true) {
            val buffer = ByteArray(4096)
            while (true) {
                val n = queue.read(buffer, true)
                if (n < 0) break
                if (n > 0) sink(buffer.copyOf(n))
            }
        }
        return session
    }

    /** The session is done: its input thread ends, writes are dropped. Never `finishIfRunning` (there is no pid). */
    @JvmStatic
    fun close(session: TerminalSession) {
        synchronized(session) { session.mShellPid = -1 }
        session.mTerminalToProcessIOQueue.close()
        session.mProcessToTerminalIOQueue.close()
    }

    /** Points the session at another emulator (the terminal started afresh with a new one). */
    @JvmStatic
    fun setEmulator(session: TerminalSession, emulator: TerminalEmulator) {
        session.mEmulator = emulator
    }
}
