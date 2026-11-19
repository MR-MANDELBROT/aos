package dev.marquart.aos.screen

import dev.marquart.aos.core.SSHRoute
import dev.marquart.aos.core.ScreenTarget
import org.junit.Test
import java.net.ServerSocket
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Where the screens are reached and in what size (iOS ScreenTests: routing, display sizes, screen ids). */
class RoutingTests {
    @Test fun theSameNetworkUsesTheAddressSSHReached() {
        assertEquals(DirectPath.Candidate.Address("192.168.1.20"),
            DirectPath.candidate(SSHRoute.Host("maxs-mac.local"), "192.168.1.20", emptyList(), systemVpn = false))
        assertEquals(DirectPath.Candidate.Address("192.168.1.20"),
            DirectPath.candidate(SSHRoute.Host("192.168.1.20"), null, emptyList(), systemVpn = false))
        assertEquals(DirectPath.Candidate.Address("10.0.0.5"),
            DirectPath.candidate(SSHRoute.Bonjour("Max's Mac"), "10.0.0.5", emptyList(), systemVpn = false))
        assertEquals(DirectPath.Candidate.NoAddress, DirectPath.candidate(SSHRoute.Bonjour("Max's Mac"), null, emptyList(), false))
    }

    @Test fun theTailnetNeedsTheTailscaleAppsVPN() {
        val hosts = listOf("mac.tailnet.ts.net", "fd7a:115c:a1e0::1", "100.101.102.103")
        assertEquals(DirectPath.Candidate.TailnetWithoutVpn, DirectPath.candidate(SSHRoute.Tailnet("100.101.102.103"), null, hosts, false))
        assertEquals(DirectPath.Candidate.Address("100.101.102.103"), DirectPath.candidate(SSHRoute.Tailnet("mac.tailnet.ts.net"), null, hosts, true))
        assertEquals(ScreenNetwork.INTERNET, DirectPath.network("100.101.102.103"))
        assertEquals(ScreenNetwork.LOCAL_NETWORK, DirectPath.network("192.168.1.20"))
    }

    @Test fun loopbackIsNoPath() {
        assertEquals(DirectPath.Candidate.NoAddress, DirectPath.candidate(SSHRoute.Host("127.0.0.1"), "127.0.0.1", emptyList(), false))
        assertEquals(DirectPath.Candidate.NoAddress, DirectPath.candidate(SSHRoute.Host("localhost"), "::1", emptyList(), false))
        assertTrue(DirectPath.isLoopback("127.0.0.2"))
        assertFalse(DirectPath.isLoopback("128.0.0.1"))
        // A link-local IPv6 address only with its interface
        assertEquals(DirectPath.Candidate.NoAddress, DirectPath.candidate(SSHRoute.Host("fe80::1"), "fe80::1", emptyList(), false))
        assertEquals(DirectPath.Candidate.Address("fe80::1%wlan0"), DirectPath.candidate(SSHRoute.Host("x"), "fe80::1%wlan0", emptyList(), false))
        assertTrue(DirectPath.isLinkLocalIPv6("FE80::abcd%wlan0"))
        assertFalse(DirectPath.isLinkLocalIPv6("fd7a:115c:a1e0::1"))
    }

    @Test fun reachableIsAQuickTCPCheck() {
        ServerSocket(0).use { server ->
            assertTrue(DirectPath.reachable("127.0.0.1", server.localPort, 1000))
        }
        val closed = ServerSocket(0).use { it.localPort }
        assertFalse(DirectPath.reachable("127.0.0.1", closed, 500))
    }

    @Test fun displaysAreSizedAsOpenScreenSharingSizesTheVirtualDisplay() {
        // iPhone 17 Pro upright (iOS NOTES): 402 x 812 points at 3x -> 1050 x 2120 pixels
        assertEquals(DisplayMode(525, 1060, 2), DisplayMode.matching(402.0, 812.0, 3.0))
        // A phone on its side, 1.5x: wider than the minimum already
        assertEquals(DisplayMode(1200, 600, 2), DisplayMode.matching(800.0, 400.0, 2.625, 1.5))
        // A low-density screen: one pixel per point
        assertEquals(1, DisplayMode.matching(400.0, 700.0, 1.5)?.density)
        assertNull(DisplayMode.matching(0.0, 700.0, 2.0))
        assertEquals(0, DisplayMode(525, 1060, 2).alignedToWidthMultiple(16).pixelWidth % 16)
    }

    @Test fun theWorkspaceGetsTheSameSizeThroughItsDisplayRequest() {
        val request = DisplayRequest.forArea(ScreenArea(402.0, 812.0, 3.0, 1.0))
        assertEquals(DisplayRequest(1050, 2120, 2), request)
        assertEquals("1050x2120@2", request.toString())
        // Within what the workspace takes: no side above 4096, even numbers, the shape kept
        assertEquals(DisplayRequest(4096, 2048, 2), DisplayRequest(8192, 4096, 2).clamped())
        assertEquals(DisplayRequest(640, 640, 2), DisplayRequest(3, 5, 2).clamped())
        assertEquals(DisplayRequest(1000, 2000, 1), DisplayRequest(1001, 2001, 1).clamped())
    }

    @Test fun resolutionsAreNamedAsInOpenScreenSharing() {
        assertEquals(listOf("Native", "1.25×", "1.5×", "1.75×", "2×"), DisplayMode.resolutionScales.map { DisplayMode.resolutionTitle(it, "Native") })
    }

    @Test fun eachScreenOfEachMacHasAnIdOfItsOwn() {
        val mac = "6F1C2B4A-0000-4000-8000-000000000001"
        // The iPhone's derivation (SHA-256 of "aos-screen\n<target>\n<mac>", version 5 style), computed in Python
        assertEquals("485C2F5D-F6E0-55CC-A367-12A9FA0B8973", ScreenIds.of(ScreenTarget.WORKSPACE, mac))
        assertEquals("7C1B2E9A-FCF0-59D5-923C-C219E99E84A3", ScreenIds.of(ScreenTarget.MAC, mac))
        assertNotEquals(ScreenIds.of(ScreenTarget.MAC, mac), ScreenIds.of(ScreenTarget.MAC, "another"))
    }
}
