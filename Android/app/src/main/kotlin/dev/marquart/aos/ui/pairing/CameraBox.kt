package dev.marquart.aos.ui.pairing

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CameraAlt
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.marquart.aos.R

/** The pairing page's camera (the shared PairingScreen shows it through `Platform.pairingScanner`). */
@Composable
fun CameraBox(modifier: Modifier, demo: Boolean, accept: (String) -> Unit) {
    val (granted, ask) = rememberCameraPermission()
    val cameraWanted = !demo
    LaunchedEffect(Unit) { if (!granted && cameraWanted) ask() }
    Box(modifier) {
        if (granted && cameraWanted) {
            QrScanner(Modifier.fillMaxSize(), onCode = accept)
            Text(stringResource(R.string.pair_point_camera), style = MaterialTheme.typography.labelLarge, color = Color.White,
                modifier = Modifier.align(Alignment.BottomCenter).padding(12.dp)
                    .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(50)).padding(horizontal = 14.dp, vertical = 8.dp))
        } else {
            Column(Modifier.align(Alignment.Center).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Icon(Icons.Rounded.QrCodeScanner, contentDescription = null, tint = Color.White, modifier = Modifier.size(56.dp))
                Text(stringResource(R.string.pair_camera_needed), color = Color.White, textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.bodyMedium)
                if (cameraWanted) FilledTonalButton(onClick = ask) {
                    Icon(Icons.Rounded.CameraAlt, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.size(6.dp))
                    Text(stringResource(R.string.pair_allow_camera))
                }
            }
        }
    }
}
