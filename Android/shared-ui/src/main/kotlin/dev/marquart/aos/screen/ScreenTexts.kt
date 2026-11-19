package dev.marquart.aos.screen

import androidx.compose.runtime.Composable
import dev.marquart.aos.R
import dev.marquart.aos.ui.platform.stringResource

/** The title of a session's failure (Android's session screen and the desktop's). */
@Composable
fun failureTitle(failure: SessionFailure, name: String): String = when (failure.kind) {
    FailureKind.AUTHENTICATION -> stringResource(R.string.screen_failure_sign_in, name)
    FailureKind.PERMISSION_DENIED -> stringResource(R.string.screen_failure_declined, name)
    FailureKind.HOST_NOT_FOUND -> stringResource(R.string.screen_failure_not_found, name)
    FailureKind.OWN_SCREEN -> stringResource(R.string.screen_failure_own_screen)
    FailureKind.UNREACHABLE, FailureKind.OTHER -> stringResource(R.string.screen_failure_connect, name)
    FailureKind.CONNECTION_LOST -> stringResource(R.string.screen_failure_lost, name)
    FailureKind.ENDED -> stringResource(R.string.screen_failure_disconnected, name)
    FailureKind.CLOSED_BY_SERVER -> stringResource(R.string.screen_failure_ended, name)
    FailureKind.UNSUPPORTED -> stringResource(R.string.screen_failure_unsupported, name)
    FailureKind.CERTIFICATE_CHANGED, FailureKind.UNVERIFIED_SERVER -> stringResource(R.string.screen_failure_verify, name)
    FailureKind.HIGH_PERFORMANCE -> when (failure.media) {
        MediaFailureKind.BUSY -> stringResource(R.string.screen_failure_hp_busy, name)
        MediaFailureKind.UNSUPPORTED -> stringResource(R.string.screen_failure_hp_unsupported, name)
        MediaFailureKind.UNDECODABLE -> stringResource(R.string.screen_failure_hp_undecodable)
        MediaFailureKind.REFUSED -> stringResource(R.string.screen_failure_hp_refused, name)
        else -> stringResource(R.string.screen_failure_hp_stopped)
    }
}
