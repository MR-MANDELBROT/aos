// A screen of the Screen tab, the Mac's own or the workspace's: aOS's ScreenSession (iOS/Sources/Screen/
// ScreenSession.swift) for Android. Written for aOS's Android app on 2026-11-19.

package dev.marquart.aos.screen

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.marquart.aos.AosApp
import dev.marquart.aos.R
import dev.marquart.aos.companion.CompanionError
import dev.marquart.aos.connection.MacConnection
import dev.marquart.aos.core.ConnectionPlan
import dev.marquart.aos.core.MacRefusal
import dev.marquart.aos.core.PairedMac
import dev.marquart.aos.core.ScreenEndpoint
import dev.marquart.aos.core.ScreenTarget
import dev.marquart.aos.ssh.LocalForwarder
import dev.marquart.aos.ssh.SshConnection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What a screen starts with: one setting for both screens. */
data class ScreenOptions(val matchesPhone: Boolean = true, val resolutionScale: Double = DisplayMode.DEFAULT_RESOLUTION_SCALE)

/** Where a screen is reached and how its session signs in (the Mac forwards to `targetHost:targetPort`). */
data class ScreenRouteInfo(
    val target: ScreenTarget,
    val name: String,
    val screenId: String,
    val macId: String,
    val targetHost: String,
    val targetPort: Int,
    val username: String,
    val password: String?,
    val followsWindowShape: Boolean,
) {
    /** "Sync Clipboard" starts on for the Mac, off for the workspace (what the phone copies, a password or a code,
     *  doesn't go to the agent's Mac unasked). */
    val sharesClipboard: Boolean get() = target == ScreenTarget.MAC

    override fun toString() = "ScreenRouteInfo($target, $targetHost:$targetPort)"

    companion object {
        /** The workspace: its address and its screen sharing account, as the Mac sealed them to this phone. */
        fun workspace(login: ScreenEndpoint, mac: PairedMac, name: String, matchShape: Boolean): ScreenRouteInfo? {
            val username = login.username?.takeIf { it.isNotEmpty() } ?: return null
            val password = login.password?.takeIf { it.isNotEmpty() } ?: return null
            return ScreenRouteInfo(ScreenTarget.WORKSPACE, name, ScreenIds.of(ScreenTarget.WORKSPACE, mac.id), mac.id,
                login.host, login.port, username, password, matchShape)
        }

        /** The Mac's own screen sharing (127.0.0.1:5900 on the Mac), with the Mac account the person entered. */
        fun mac(endpoint: ScreenEndpoint, mac: PairedMac, login: MacLogin): ScreenRouteInfo =
            ScreenRouteInfo(ScreenTarget.MAC, mac.name, ScreenIds.of(ScreenTarget.MAC, mac.id), mac.id, endpoint.host,
                endpoint.port, login.username, login.password, followsWindowShape = false)
    }
}

/**
 * One screen. It connects only when asked (a tap on its card). The workspace asks for its display in the phone's shape
 * and renews that lease while it is shown; the Mac goes the direct path when the phone's size is wanted and the Mac can
 * be reached there (high performance, the virtual display), otherwise and when that path fails through the tunnel.
 */
class ScreenController(val target: ScreenTarget, private val hub: ScreenHub) {
    sealed class Phase {
        data object Idle : Phase()
        /** The Mac's own screen needs the Mac account. */
        data object NeedsLogin : Phase()
        data object Preparing : Phase()
        data object Running : Phase()
        /** The app went to the background with the session on screen: it comes back with the app. */
        data object Paused : Phase()
        data class Failed(val message: String) : Phase()
    }

    var phase by mutableStateOf<Phase>(Phase.Idle); private set
    var session by mutableStateOf<SessionModel?>(null); private set
    var loginProblem by mutableStateOf<String?>(null); private set
    var tunnelReason by mutableStateOf<TunnelReason?>(null); private set
    var tunnelDetail by mutableStateOf<String?>(null); private set
    var path by mutableStateOf<ScreenPath?>(null); private set
    var route: ScreenRouteInfo? = null; private set

    /** The person changed the resolution in the session (one setting for both screens). */
    var onResolutionScale: ((Double) -> Unit)? = null

    private val context: Context get() = hub.context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val main = Handler(Looper.getMainLooper())
    private var forwarder: LocalForwarder? = null
    private var mac: MacConnection? = null
    private var options = ScreenOptions()
    private var login: MacLogin? = null
    private var displayRequest: DisplayRequest? = null
    private var displayJob: Job? = null
    private var renewJob: Job? = null
    private var watchJob: Job? = null
    private var demoServer: DemoScreenServer? = null
    private val directFailures = HashMap<String, Pair<Long, String>>()
    private val withoutHighPerformance = HashSet<String>()
    private var resuming = false

    val isRunning: Boolean get() = phase == Phase.Preparing || phase == Phase.Running

    fun showNeedsLogin(problem: String? = null) {
        stop()
        loginProblem = problem
        phase = Phase.NeedsLogin
    }

    fun cancelLogin() {
        if (phase != Phase.NeedsLogin) return
        stop()
        loginProblem = null
        phase = Phase.Idle
    }

    // Connecting

    /** A tap on the card: the workspace's sealed login from the Mac; the Mac's from the phone's store behind its lock
     *  (once), or the login form if none is kept. */
    suspend fun connect(mac: MacConnection, options: ScreenOptions, area: ScreenArea, unlock: suspend (PairedMac) -> MacLogin?) {
        if (target != ScreenTarget.MAC) {
            start(mac, null, options, area)
            return
        }
        stop()
        phase = Phase.Preparing
        val login = try {
            unlock(mac.mac.value)
        } catch (e: UnlockCancelled) {
            phase = Phase.Idle
            return
        } catch (e: Exception) {
            showNeedsLogin(context.getString(R.string.screen_login_unreadable))
            return
        }
        if (login == null) {
            showNeedsLogin()
            return
        }
        if (phase != Phase.Preparing) return
        start(mac, login, options, area)
    }

    /** Starts the screen: its login, the tunnel, the direct path for the Mac if wanted and possible, the session. */
    suspend fun start(mac: MacConnection, login: MacLogin?, options: ScreenOptions, area: ScreenArea) {
        stop(keepDisplay = target == ScreenTarget.WORKSPACE && options.matchesPhone)
        phase = Phase.Preparing
        loginProblem = null
        this.options = options
        this.mac = mac
        this.login = login
        if (target == ScreenTarget.MAC) {
            tunnelReason = null
            tunnelDetail = null
        }
        try {
            if (!hub.factory.available) throw IllegalStateException(context.getString(R.string.screen_no_library))
            val ssh = mac.ssh.value?.takeIf { it.isActive } ?: throw NotConnected()
            val pairedMac = mac.mac.value
            val route = when (target) {
                ScreenTarget.WORKSPACE -> {
                    val endpoint = mac.screenEndpoint(ScreenTarget.WORKSPACE)
                    val route = ScreenRouteInfo.workspace(endpoint, pairedMac, context.getString(R.string.screen_workspace), options.matchesPhone)
                        ?: throw IllegalStateException(context.getString(R.string.screen_workspace_no_login))
                    if (options.matchesPhone) requestDisplay(area)
                    route
                }
                ScreenTarget.MAC -> {
                    val l = login ?: throw IllegalStateException(context.getString(R.string.screen_mac_login_missing))
                    ScreenRouteInfo.mac(mac.screenEndpoint(ScreenTarget.MAC), pairedMac, l)
                }
            }
            if (phase != Phase.Preparing) return
            val forwarder = LocalForwarder(route.targetHost, route.targetPort) { activeSsh(mac) }
            val port = withContext(Dispatchers.IO) { forwarder.start() }
            if (phase != Phase.Preparing) {
                forwarder.stop()
                return
            }
            this.forwarder = forwarder
            val path = if (target == ScreenTarget.MAC && options.matchesPhone) directPath(route, ssh, pairedMac, port) else ScreenPath.Tunnel
            if (phase != Phase.Preparing) return
            run(route, path)
        } catch (e: Exception) {
            stop(keepDisplay = false)
            phase = Phase.Failed(describe(e))
        }
    }

    /** Whether the Mac goes the direct path: an address in a network, the Mac's screen sharing key known (learned
     *  through the tunnel, once), high performance offered, the Mac answering there. */
    private suspend fun directPath(route: ScreenRouteInfo, ssh: SshConnection, mac: PairedMac, port: Int): ScreenPath {
        val remote = withContext(Dispatchers.IO) { DirectPath.literal(ssh.address) }
        val host = when (val candidate = DirectPath.candidate(ssh.route, remote, ConnectionPlan.tailnetHosts(mac), hub.tailscaleVpnActive())) {
            is DirectPath.Candidate.Address -> candidate.host
            DirectPath.Candidate.NoAddress -> return tunnel(TunnelReason.NO_ADDRESS, context.getString(R.string.screen_detail_no_address, ssh.host))
            DirectPath.Candidate.TailnetWithoutVpn -> return tunnel(TunnelReason.TAILNET_WITHOUT_VPN, null)
        }
        directFailures[host]?.let { (at, reason) ->
            val minutes = (System.currentTimeMillis() - at) / 60_000
            if (System.currentTimeMillis() - at < 10 * 60_000) {
                return tunnel(TunnelReason.FAILED, context.getString(R.string.screen_detail_failed_before, host, maxOf(1, minutes).toInt(), reason))
            }
        }
        if (route.screenId in withoutHighPerformance) return tunnel(TunnelReason.NO_HIGH_PERFORMANCE, null)
        // A direct connection signs in only with the screen sharing key the Mac showed through SSH (libsharing's
        // RequireTrustedKey): a stranger in the network posing as the Mac gets nothing of the login. The first time per
        // Mac the setup check signs in once through the tunnel to learn it.
        if (hub.store.record(route.screenId)?.knowsServerKey != true) {
            val check = withContext(Dispatchers.IO) {
                hub.factory.checkLogin(RemoteSessionOptions("127.0.0.1", port, route.username, route.password,
                    trustedFingerprint = hub.store.record(route.screenId)?.trustedFingerprint ?: ""))
            }
            when (check) {
                is LoginCheckResult.Ok -> {
                    if (check.fingerprint.isNotEmpty()) hub.store.update(route.screenId, route.macId) { it.copy(trustedFingerprint = check.fingerprint) }
                    if (!check.highPerformance) {
                        withoutHighPerformance += route.screenId
                        return tunnel(TunnelReason.NO_HIGH_PERFORMANCE, check.security.ifEmpty { null })
                    }
                    if (check.fingerprint.isEmpty()) {
                        return tunnel(TunnelReason.FAILED, context.getString(R.string.screen_detail_no_key, check.security))
                    }
                }
                LoginCheckResult.LoginRefused -> return tunnel(TunnelReason.FAILED, context.getString(R.string.screen_detail_check_refused))
                is LoginCheckResult.Failed -> return tunnel(TunnelReason.FAILED, context.getString(R.string.screen_detail_check_failed, check.message))
            }
        }
        if (!withContext(Dispatchers.IO) { DirectPath.reachable(host, hub.directPort) }) {
            return tunnel(TunnelReason.UNREACHABLE, context.getString(R.string.screen_detail_unreachable, host, hub.directPort))
        }
        tunnelReason = null
        tunnelDetail = null
        return ScreenPath.Direct(host, DirectPath.network(host))
    }

    private fun tunnel(reason: TunnelReason, detail: String?): ScreenPath {
        tunnelReason = reason
        tunnelDetail = detail
        return ScreenPath.Tunnel
    }

    /** Opens the session for a route: through the tunnel's listener, or on the direct path. */
    private fun run(route: ScreenRouteInfo, path: ScreenPath, host: String = "127.0.0.1", port: Int? = null) {
        val previous = session
        val record = hub.store.record(route.screenId)
        val direct = path as? ScreenPath.Direct
        val sessionRoute = SessionRoute(
            screenId = route.screenId, name = route.name,
            host = direct?.host ?: host,
            port = if (direct != null) hub.directPort else port ?: forwarder?.port ?: 0,
            username = route.username, password = route.password, followsWindowShape = route.followsWindowShape,
            highPerformance = direct?.network,
            trustedFingerprint = record?.trustedFingerprint ?: "",
            sharesClipboard = record?.sharesClipboard ?: route.sharesClipboard,
            fullQuality = record?.fullQuality ?: false,
            clientName = route.username,
            cacheDirectory = java.io.File(context.cacheDir, "Screen/libsharing").apply { mkdirs() }.path,
        )
        val model = SessionModel(sessionRoute, hub.factory, { main.post(it) }, options.resolutionScale)
        model.onDisplayArea = { area -> pictureAreaChanged(area) }
        model.onPicture = { jpeg -> hub.store.savePicture(route.screenId, jpeg) }
        model.onResolutionScale = { scale ->
            options = options.copy(resolutionScale = scale)
            onResolutionScale?.invoke(scale)
        }
        model.onFingerprint = { fp -> hub.store.update(route.screenId, route.macId) { it.copy(trustedFingerprint = fp) } }
        model.onConnected = { device ->
            hub.store.update(route.screenId, route.macId) {
                it.copy(lastConnected = System.currentTimeMillis(), model = device.ifEmpty { it.model })
            }
        }
        model.onClipboardSharing = { on -> hub.store.update(route.screenId, route.macId) { it.copy(sharesClipboard = on) } }
        model.onFullQuality = { on -> hub.store.update(route.screenId, route.macId) { it.copy(fullQuality = on) } }
        model.onClosed = { closed(model) }
        if (route.target == ScreenTarget.MAC) {
            model.onLoginRefused = { showNeedsLogin(context.getString(R.string.screen_mac_login_refused)) }
        }
        if (direct != null) {
            model.onDirectPathFailed = { reason -> if (session === model) leaveDirectPath(direct.host, reason) }
        }
        this.route = route
        this.path = path
        session = model
        phase = Phase.Running
        watchJob?.cancel()
        watchJob = if (direct != null) watchDirectPicture(model, direct.host) else null
        model.start()
        // The one it replaces (the direct path that failed) lets go.
        previous?.let {
            it.onClosed = null
            it.close()
        }
        Log.i(TAG, "Screen ${route.target.raw} through ${sessionRoute.host}:${sessionRoute.port}")
    }

    /** The direct session shows no picture in time (UDP blocked, for example): the tunnel takes over. */
    private fun watchDirectPicture(model: SessionModel, address: String) = scope.launch {
        var waited = 0L
        while (true) {
            delay(250)
            if (session !== model) return@launch
            if (model.phase == SessionPhase.Connected && model.hasPicture) return@launch
            val waits = model.phase is SessionPhase.ChoosingSession || model.phase == SessionPhase.WaitingForPermission
            if (!waits) waited += 250
            if (waited >= hub.directPictureTimeoutMillis) {
                leaveDirectPath(address, "no picture within ${hub.directPictureTimeoutMillis / 1000} s")
                return@launch
            }
        }
    }

    /** Back to the SSH tunnel after the direct path failed (same login, no unlock). */
    private fun leaveDirectPath(address: String, reason: String) {
        val route = route ?: return
        if (path?.isDirect != true) return
        Log.i(TAG, "Direct path to $address given up ($reason); through SSH")
        directFailures[address] = System.currentTimeMillis() to reason
        val noHighPerformance = "no high performance" in reason
        if (noHighPerformance) withoutHighPerformance += route.screenId
        tunnelReason = if (noHighPerformance) TunnelReason.NO_HIGH_PERFORMANCE else TunnelReason.FAILED
        tunnelDetail = reason
        watchJob?.cancel()
        watchJob = null
        run(route, ScreenPath.Tunnel)
    }

    /** The session closed itself (its menu, the alert after a failure). Only the shown one counts. */
    fun closed(closing: SessionModel) {
        if (closing !== session) return
        stop()
    }

    private suspend fun activeSsh(mac: MacConnection): SshConnection {
        repeat(40) {
            mac.ssh.value?.takeIf { it.isActive }?.let { return it }
            delay(250)
        }
        throw NotConnected()
    }

    // The background

    /** The app has been in the background for a while: the session ends (its last picture is kept). */
    fun pause() {
        if (phase != Phase.Running && phase != Phase.Preparing) return
        val keep = Triple(mac, options, login)
        stop(keepDisplay = false)
        mac = keep.first
        options = keep.second
        login = keep.third
        phase = Phase.Paused
    }

    /** Back in the foreground after `pause()`: the same screen again once the Mac is connected (no unlock). */
    suspend fun resume(connection: MacConnection?, area: ScreenArea) {
        if (phase != Phase.Paused || resuming) return
        resuming = true
        try {
            val mac = connection ?: this.mac
            if (mac == null || (this.mac != null && mac.mac.value.id != this.mac?.mac?.value?.id)) {
                stop()
                return
            }
            var tries = 0
            while (mac.ssh.value?.isActive != true && tries++ < 60) {
                delay(250)
                if (phase != Phase.Paused) return
            }
            if (phase != Phase.Paused) return
            if (mac.ssh.value?.isActive != true) {
                stop()
                phase = Phase.Failed(context.getString(R.string.screen_not_connected))
                return
            }
            start(mac, login, options, area)
        } finally {
            resuming = false
        }
    }

    // Without the Mac (debug builds)

    /** Straight to a screen sharing server, without the Mac and SSH. */
    fun startDirect(host: String, port: Int, username: String, password: String?, name: String, highPerformance: ScreenNetwork? = null) {
        stop()
        val route = ScreenRouteInfo(target, name, ScreenIds.named("direct\n$host"), "", host, port, username, password, false)
        run(route, highPerformance?.let { ScreenPath.Direct(host, it) } ?: ScreenPath.Tunnel, host, port)
    }

    /** The demo: a screen sharing server in the app that shows a picture (no Mac, no SSH). */
    fun startDemo(name: String, width: Int, height: Int) {
        stop()
        phase = Phase.Preparing
        val server = DemoScreenServer.start(width, height, name)
        demoServer = server
        run(ScreenRouteInfo(target, name, ScreenIds.named("demo\n${target.raw}"), "", "127.0.0.1", server.port, "", null, false),
            ScreenPath.Tunnel, "127.0.0.1", server.port)
    }

    // Stopping

    fun stop(keepDisplay: Boolean = false) {
        val model = session
        session = null
        watchJob?.cancel()
        watchJob = null
        displayJob?.cancel()
        displayJob = null
        renewJob?.cancel()
        renewJob = null
        forwarder?.stop()
        forwarder = null
        route = null
        path = null
        login = null
        demoServer?.stop()
        demoServer = null
        // The workspace gets its own size back (if the phone can't say so, the Mac's lease runs out).
        if (!keepDisplay) {
            if (displayRequest != null) mac?.let { m -> scope.launch { runCatching { m.display("reset") } } }
            displayRequest = null
        }
        if (phase != Phase.NeedsLogin) phase = Phase.Idle
        model?.let {
            it.onClosed = null
            it.close()
        }
    }

    class NotConnected : Exception()

    private fun describe(e: Exception): String = when (e) {
        is NotConnected, is CompanionError -> context.getString(R.string.screen_not_connected)
        is MacRefusal -> e.message.ifEmpty { context.getString(R.string.screen_not_connected) }
        else -> e.message ?: e.javaClass.simpleName
    }

    // The workspace in the phone's shape

    private fun pictureAreaChanged(area: ScreenArea) {
        if (target != ScreenTarget.WORKSPACE || !options.matchesPhone || phase != Phase.Running) return
        displayJob?.cancel()
        displayJob = scope.launch {
            // Turning the phone sends a few sizes in a row: only the one it settles on counts.
            delay(500)
            requestDisplay(area)
        }
    }

    /** Asks the Mac for the workspace's display in the shape of `area` and keeps renewing it while it is shown. */
    private suspend fun requestDisplay(area: ScreenArea) {
        val wanted = DisplayRequest.forArea(area) ?: return
        if (wanted == displayRequest) return
        val mac = mac ?: return
        try {
            mac.display(wanted.toString())
            displayRequest = wanted
        } catch (e: Exception) {
            // An older Mac or a closed workspace: the picture keeps the workspace's own shape.
            Log.i(TAG, "Display request refused: ${e.message}")
            return
        }
        if (renewJob != null) return
        renewJob = scope.launch {
            while (true) {
                delay(20_000)
                if (!isRunning) return@launch
                val request = displayRequest ?: return@launch
                runCatching { this@ScreenController.mac?.display(request.toString()) }
            }
        }
    }

    companion object {
        private const val TAG = "aos-screen"
    }
}

/** The person closed the unlock prompt. */
class UnlockCancelled : Exception()

/** The Screen tab's state that outlives the tab (turning the phone recreates the activity): both screens, the store. */
class ScreenHub private constructor(val context: Context) {
    val store = ScreenStore(context, (context.applicationContext as? AosApp)?.graph?.secrets)
    val factory: RemoteSessionFactory = RemoteSessions.factory
    val workspace = ScreenController(ScreenTarget.WORKSPACE, this)
    val mac = ScreenController(ScreenTarget.MAC, this)

    /** The Mac's screen sharing port on the direct path (tests: their own server's). */
    var directPort = DirectPath.SCREEN_SHARING_PORT
    var directPictureTimeoutMillis = 15_000L

    fun screen(target: ScreenTarget) = if (target == ScreenTarget.MAC) mac else workspace

    fun tailscaleVpnActive(): Boolean = try {
        (context.applicationContext as? AosApp)?.graph?.network?.tailscaleVpnActive() == true
    } catch (_: Exception) {
        false
    }

    companion object {
        @Volatile private var instance: ScreenHub? = null

        fun get(context: Context): ScreenHub = instance ?: synchronized(this) {
            instance ?: ScreenHub(context.applicationContext).also { instance = it }
        }
    }
}
