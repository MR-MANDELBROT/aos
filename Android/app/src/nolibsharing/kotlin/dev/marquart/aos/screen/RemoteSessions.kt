package dev.marquart.aos.screen

/** A build without the Go library (`-Paos.withoutGo=true`, or no third_party/aosgo/aosgo.aar): no screen sessions. */
object RemoteSessions {
    val factory: RemoteSessionFactory = object : RemoteSessionFactory {
        override val available = false

        override fun create(options: RemoteSessionOptions, listener: RemoteSessionListener): RemoteSession =
            throw UnsupportedOperationException("This build of aOS has no screen sharing library.")

        override fun checkLogin(options: RemoteSessionOptions): LoginCheckResult =
            LoginCheckResult.Failed("This build of aOS has no screen sharing library.")
    }
}
