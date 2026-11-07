// The screen sharing client lives in its own module (AOSRFB) so the iPhone app can use it too; everything that
// imports AOSKit sees it as before.
@_exported import AOSRFB
// Tailscale's status and the ways to reach the Mac, shared with the iPhone app the same way.
@_exported import AOSTailnet
