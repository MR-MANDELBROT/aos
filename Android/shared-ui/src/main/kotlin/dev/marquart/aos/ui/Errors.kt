package dev.marquart.aos.ui

import dev.marquart.aos.R
import dev.marquart.aos.companion.CompanionError
import dev.marquart.aos.core.MacRefusal
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.ssh.PairingClient
import dev.marquart.aos.ssh.SessionChannel
import dev.marquart.aos.ssh.SshConnectException
import dev.marquart.aos.ui.Txt.Companion.raw
import dev.marquart.aos.ui.Txt.Companion.res

/**
 * Errors in the app's words. The foundation's texts are English fallbacks; the codes and types are worded here, in
 * English and German (iOS: MacRefusal.text, PairingClient's and SSHConnection's descriptions).
 */
object ErrorText {
    fun of(error: Throwable): Txt = when (error) {
        is MacRefusal -> refusal(error.code) ?: raw(error.text)
        is CompanionError -> companion(error)
        is PairingClient.Failure -> pairing(error)
        is SshConnectException -> ssh(error)
        is PairingLink.ParseError.NewerVersion -> res(R.string.pair_newer_code)
        is PairingLink.ParseError -> res(R.string.pair_not_a_code)
        else -> raw(error.message ?: error.javaClass.simpleName)
    }

    /** A refusal of the Overview's actions by its code (MacRefusal.code); null for a code the app doesn't know. */
    fun refusal(code: String?): Txt? = when (code) {
        "other-service" -> res(R.string.refusal_other_service)
        "sleep-disabled" -> res(R.string.refusal_sleep_disabled)
        "sleep-held" -> res(R.string.refusal_sleep_held)
        "not-set-up" -> res(R.string.refusal_not_set_up)
        "no-session" -> res(R.string.refusal_no_session)
        "no-keeper" -> res(R.string.refusal_no_keeper)
        "keeper-old" -> res(R.string.refusal_keeper_old)
        "not-kept" -> res(R.string.refusal_not_kept)
        "chat-running" -> res(R.string.refusal_chat_running)
        "not-found" -> res(R.string.refusal_not_found)
        "sign-out-failed" -> res(R.string.refusal_sign_out_failed)
        else -> null
    }

    fun companion(error: CompanionError): Txt = when (error) {
        CompanionError.Closed -> res(R.string.error_closed)
        CompanionError.Timeout -> res(R.string.error_timeout)
        is CompanionError.Refused -> refusal(error.code) ?: raw(error.reason)
        CompanionError.InvalidAnswer -> res(R.string.error_invalid_answer)
        CompanionError.PairAgain -> res(R.string.error_pair_again)
        CompanionError.Unsignable -> res(R.string.error_unsignable)
        CompanionError.UpdateMac -> res(R.string.error_update_mac)
        is CompanionError.ChannelEnded -> {
            val failure = error.failure
            if (failure is SessionChannel.Failure.Exited && failure.status == 127) res(R.string.error_not_installed)
            else res(R.string.error_closed)
        }
    }

    fun pairing(error: PairingClient.Failure): Txt = when (error) {
        PairingClient.Failure.Unreachable -> res(R.string.pair_error_unreachable)
        PairingClient.Failure.LocalNetworkDenied -> res(R.string.error_local_network)
        PairingClient.Failure.NoAnswer -> res(R.string.pair_error_no_answer)
        PairingClient.Failure.InvalidAnswer -> res(R.string.pair_error_invalid_answer)
        is PairingClient.Failure.Refused -> res(R.string.pair_error_refused, error.reason)
        PairingClient.Failure.NotAuthentic -> res(R.string.pair_error_not_authentic)
    }

    fun ssh(error: SshConnectException): Txt = when (error) {
        is SshConnectException.HostKeyMismatch -> res(R.string.ssh_error_host_key, error.host, error.presented)
        is SshConnectException.UnknownHostKey -> res(R.string.ssh_error_unknown_key, error.host, error.fingerprint)
        is SshConnectException.AuthenticationFailed -> res(R.string.ssh_error_login, error.host)
        is SshConnectException.Unreachable -> res(R.string.ssh_error_unreachable)
        SshConnectException.LocalNetworkDenied -> res(R.string.error_local_network)
    }
}

/**
 * The connection's state messages (MacConnection's English texts) in the app's words. They come as text, so they are
 * matched here; a text the app doesn't know is shown as it came.
 */
object ConnectionText {
    private val exact: Map<String, Int> = mapOf(
        "The Mac is going to sleep." to R.string.conn_going_to_sleep,
        "The connection to the Mac ended." to R.string.conn_ended,
        "The Mac isn't reachable." to R.string.conn_unreachable_plain,
        "The Mac no longer accepts this phone. Pair again in aOS on the Mac." to R.string.conn_not_accepted,
        "aOS may not use the local network. Allow it in the app's settings." to R.string.error_local_network,
        "aOS may not use the local network." to R.string.error_local_network,
        "The Mac isn't reachable. Outside your home network you need Tailscale or another VPN to reach it." to R.string.conn_unreachable_vpn,
        "The Mac's key is unknown." to R.string.conn_key_unknown,
        "The Mac isn't reachable, also not through Tailscale. Is it awake, and is Tailscale on there?" to R.string.conn_unreachable_tailscale,
        "The Mac isn't reachable. On the go, set up aOS's Tailscale on this phone: Settings > Connection." to R.string.conn_unreachable_set_up_aos,
        "The Mac isn't reachable, and aOS's Tailscale on this phone isn't connected (Settings > Connection)." to R.string.conn_unreachable_aos_off,
        "The Mac isn't reachable. On the go, switch on Tailscale on this phone (the Tailscale app, or aOS's Tailscale in Settings > Connection)." to R.string.conn_unreachable_switch_on,
        "The Mac isn't reachable. Your Mac is set up for the same network only; to reach it on the go, choose a way with Tailscale in aOS on the Mac." to R.string.conn_unreachable_lan,
        "aOS isn't installed on the Mac where it was paired. Open aOS on the Mac and pair again." to R.string.error_not_installed,
        "aOS on the Mac doesn't answer." to R.string.conn_companion_silent,
        "aOS on the Mac stopped answering." to R.string.conn_companion_stopped,
    )

    fun message(text: String): Txt {
        exact[text]?.let { return res(it) }
        // "At <host> a different computer answered, or the Mac's SSH key changed. ..."
        val mismatch = Regex("^At (.+) a different computer answered, or the Mac's SSH key changed\\. If you set the Mac up again, pair it again\\.$")
        mismatch.find(text)?.let { return res(R.string.conn_host_key_changed, it.groupValues[1]) }
        if (text.startsWith("aOS on the Mac isn't ready: ")) {
            return res(R.string.conn_companion_not_ready, text.removePrefix("aOS on the Mac isn't ready: "))
        }
        return raw(text)
    }
}
