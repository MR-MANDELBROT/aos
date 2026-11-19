package dev.marquart.aos.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.PairingLink
import dev.marquart.aos.model.AppModel
import kotlinx.coroutines.launch

private val Indigo = Color(0xFF4F46E5)
private val Mint = Color(0xFF3EB489)

/**
 * A placeholder so the app builds and runs: the connection's state and a field to pair from a link. The UI agent
 * replaces this file (and binds to `AppModel` the same way: collect its StateFlows).
 */
@Composable
fun PlaceholderScreen(model: AppModel, incomingLink: String?) {
    val scheme = if (isSystemInDarkTheme()) darkColorScheme(primary = Indigo, secondary = Mint)
        else lightColorScheme(primary = Indigo, secondary = Mint)
    MaterialTheme(colorScheme = scheme) {
        Surface(Modifier.fillMaxSize()) {
            val macs by model.macs.collectAsState()
            val state by model.connectionState.collectAsState()
            val companion by model.companionState.collectAsState()
            val keyError by model.keyError.collectAsState()
            val questions by model.questions.collectAsState()
            var link by remember { mutableStateOf(incomingLink ?: "") }
            var status by remember { mutableStateOf<String?>(null) }
            val scope = rememberCoroutineScope()
            LaunchedEffect(incomingLink) { if (incomingLink != null) link = incomingLink }

            Column(Modifier.safeDrawingPadding().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("aOS", style = MaterialTheme.typography.headlineLarge)
                val mac = macs.firstOrNull()
                Text(if (mac == null) "Not paired" else "Mac: ${mac.name}")
                Text("Connection: " + describe(state))
                Text("aOS on the Mac: " + describe(companion))
                if (questions.isNotEmpty()) Text("Waiting for you: ${questions.size}")
                keyError?.let { Text("Keys: $it", color = MaterialTheme.colorScheme.error) }
                OutlinedTextField(value = link, onValueChange = { link = it }, label = { Text("Pairing link (aos-pair://...)") },
                    modifier = Modifier.fillMaxWidth(), singleLine = false)
                Button(onClick = {
                    scope.launch {
                        status = try {
                            val parsed = PairingLink.parse(link)
                            model.pair(parsed) { step -> status = step.kind.name.lowercase().replace('_', ' ') }
                            "Paired"
                        } catch (e: PairingLink.ParseError.NewerVersion) {
                            "This pairing code is newer than this app. Update aOS on this phone."
                        } catch (e: Exception) {
                            e.message ?: e.javaClass.simpleName
                        }
                    }
                }, enabled = link.isNotBlank()) { Text("Pair") }
                if (mac != null) {
                    Button(onClick = { scope.launch { model.unpair(mac) } }) { Text("Forget this Mac") }
                }
                status?.let { Text(it) }
            }
        }
    }
}

private fun describe(state: MacConnection.State): String = when (state) {
    MacConnection.State.Idle -> "idle"
    MacConnection.State.Connecting -> "connecting"
    is MacConnection.State.Connected -> "connected (${state.host})"
    is MacConnection.State.Unreachable -> state.message
    is MacConnection.State.NeedsAttention -> state.message
}

private fun describe(state: MacConnection.CompanionState): String = when (state) {
    MacConnection.CompanionState.NotStarted -> "not started"
    MacConnection.CompanionState.Starting -> "starting"
    MacConnection.CompanionState.Ready -> "ready"
    is MacConnection.CompanionState.Unavailable -> state.message
    MacConnection.CompanionState.NeedsPairing -> "pair again"
}
