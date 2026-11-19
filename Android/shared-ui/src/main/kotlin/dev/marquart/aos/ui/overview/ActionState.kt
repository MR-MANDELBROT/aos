package dev.marquart.aos.ui.overview

import dev.marquart.aos.ui.platform.platformContext
import dev.marquart.aos.ui.platform.PlatformContext
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.MacAction
import dev.marquart.aos.core.MacActionResult
import dev.marquart.aos.ui.ErrorText
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** An action of the Overview that is running, or what went wrong with the last one (shown for 8 s). One at a time. */
@Stable
class ActionState(private val scope: CoroutineScope, private val context: PlatformContext) {
    var running by mutableStateOf<MacAction?>(null)
        private set
    /** The value the running action was sent with (a chat's id). */
    var value by mutableStateOf<String?>(null)
        private set
    var problem by mutableStateOf<String?>(null)
        private set
    private var clear: Job? = null

    fun isRunning(value: String) = running != null && this.value == value

    fun run(action: MacAction, connection: MacConnection, value: String? = null, then: ((MacActionResult) -> Unit)? = null) {
        if (running != null) return
        running = action
        this.value = value
        problem = null
        scope.launch {
            try {
                val result = connection.perform(action, value)
                then?.invoke(result)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                show(ErrorText.of(e).resolve(context))
            } finally {
                running = null
                this@ActionState.value = null
            }
        }
    }

    private fun show(text: String) {
        problem = text
        clear?.cancel()
        clear = scope.launch {
            delay(8_000)
            problem = null
        }
    }
}

@Composable
fun rememberActionState(): ActionState {
    val scope = rememberCoroutineScope()
    val context = platformContext()
    return remember { ActionState(scope, context) }
}
