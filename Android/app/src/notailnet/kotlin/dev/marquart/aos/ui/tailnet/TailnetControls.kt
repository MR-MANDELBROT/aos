package dev.marquart.aos.ui.tailnet

import dev.marquart.aos.connection.TailnetDialer

/** Built without the Go library: no node of aOS's own, nothing to control. */
object TailnetControls {
    fun of(dialer: TailnetDialer): TailnetControl? = null
}
