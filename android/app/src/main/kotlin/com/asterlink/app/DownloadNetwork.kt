package com.asterlink.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

internal object DownloadNetwork {
    fun read(context: Context): String = try {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val network = manager?.activeNetwork
        when {
            manager == null -> "unknown"
            network == null -> "other"
            else -> classify(manager.getNetworkCapabilities(network))
        }
    } catch (_: SecurityException) {
        "unknown"
    }

    fun classify(capabilities: NetworkCapabilities?): String {
        if (capabilities == null) return "unknown"
        // VPN capabilities can include the underlying transports. Check mobile
        // first, including networks that Android currently marks as unmetered.
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "other"
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) -> "other"
            // Some VPNs omit their underlying transport. A metered/unknown
            // connection must not silently bypass the mobile-data confirmation.
            else -> "unknown"
        }
    }
}
