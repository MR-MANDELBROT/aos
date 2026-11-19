package dev.marquart.aos.desktop.system

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R
import dev.marquart.aos.ui.platform.stringResource
import dev.marquart.aos.ui.theme.AosTheme
import kotlinx.coroutines.CompletableDeferred

/** The in-app password dialog ("Confirm with the password", Linux): one question at a time. */
class PasswordPrompt {
    class Request(val reason: String, val wrong: Boolean, val answer: CompletableDeferred<CharArray?>)

    var current by mutableStateOf<Request?>(null)
        private set

    suspend fun ask(reason: String, wrong: Boolean): CharArray? {
        val request = Request(reason, wrong, CompletableDeferred())
        current = request
        return try {
            request.answer.await()
        } finally {
            if (current === request) current = null
        }
    }

    fun answer(request: Request, password: CharArray?) {
        request.answer.complete(password)
    }
}

@Composable
fun PasswordPromptHost(prompt: PasswordPrompt) {
    val request = prompt.current ?: return
    var text by remember(request) { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    LaunchedEffect(request) { focus.requestFocus() }
    AlertDialog(
        onDismissRequest = { prompt.answer(request, null) },
        title = { Text(stringResource(R.string.desktop_password_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(request.reason)
                OutlinedTextField(text, { text = it }, singleLine = true, visualTransformation = PasswordVisualTransformation(),
                    label = { Text(stringResource(R.string.desktop_password_label, System.getProperty("user.name"))) },
                    isError = request.wrong, modifier = Modifier.focusRequester(focus))
                if (request.wrong) Text(stringResource(R.string.desktop_password_wrong), color = AosTheme.colors.red)
            }
        },
        confirmButton = { Button(onClick = { prompt.answer(request, text.toCharArray()) }, enabled = text.isNotEmpty()) { Text(stringResource(R.string.ok)) } },
        dismissButton = { TextButton(onClick = { prompt.answer(request, null) }) { Text(stringResource(R.string.cancel)) } },
    )
}
