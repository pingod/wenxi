package com.asterlink.app

import android.net.NetworkCapabilities
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 36], manifest = Config.NONE)
class DownloadNetworkTest {
    private fun network(vararg transports: Int, unmetered: Boolean = false) =
        NetworkCapabilities().also { capabilities ->
            val shadow = shadowOf(capabilities)
            transports.forEach { shadow.addTransportType(it) }
            if (unmetered) shadow.addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            else shadow.removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        }

    @Test fun cellularStillWarnsWithAnUnmeteredPlan() {
        for (unmetered in listOf(false, true)) {
            assertEquals("mobile", DownloadNetwork.classify(network(
                NetworkCapabilities.TRANSPORT_CELLULAR, unmetered = unmetered,
            )))
        }
    }

    @Test fun wifiAndEthernetAreNotMistakenForCellular() {
        for (transport in listOf(NetworkCapabilities.TRANSPORT_WIFI, NetworkCapabilities.TRANSPORT_ETHERNET)) {
            for (unmetered in listOf(false, true)) {
                assertEquals("other", DownloadNetwork.classify(network(transport, unmetered = unmetered)))
            }
        }
    }

    @Test fun vpnUsesItsUnderlyingTransport() {
        assertEquals("mobile", DownloadNetwork.classify(network(
            NetworkCapabilities.TRANSPORT_VPN, NetworkCapabilities.TRANSPORT_CELLULAR,
        )))
        assertEquals("other", DownloadNetwork.classify(network(
            NetworkCapabilities.TRANSPORT_VPN, NetworkCapabilities.TRANSPORT_WIFI,
        )))
        assertEquals("mobile", DownloadNetwork.classify(network(
            NetworkCapabilities.TRANSPORT_VPN, NetworkCapabilities.TRANSPORT_WIFI,
            NetworkCapabilities.TRANSPORT_CELLULAR,
        )))
    }

    @Test fun vpnWithHiddenTransportCannotSilentlyAllowMeteredDownloads() {
        assertEquals("unknown", DownloadNetwork.classify(network(NetworkCapabilities.TRANSPORT_VPN)))
        assertEquals("other", DownloadNetwork.classify(network(
            NetworkCapabilities.TRANSPORT_VPN, unmetered = true,
        )))
        assertEquals("unknown", DownloadNetwork.classify(null))
    }
}
