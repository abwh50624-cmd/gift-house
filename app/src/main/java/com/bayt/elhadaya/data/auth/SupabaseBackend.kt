package com.bayt.elhadaya.data.auth

import android.content.Context
import com.bayt.elhadaya.BuildConfig
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.FlowType
import io.github.jan.supabase.postgrest.Postgrest
import androidx.core.net.toUri

sealed interface BackendConfiguration {
    data class Ready(val client: SupabaseClient) : BackendConfiguration
    data object Missing : BackendConfiguration
    data object Invalid : BackendConfiguration
}

object SupabaseBackend {
    fun configure(context: Context): BackendConfiguration {
        val url = BuildConfig.SUPABASE_URL.trim()
        val publishableKey = BuildConfig.SUPABASE_PUBLISHABLE_KEY.trim()
        if (url.isEmpty() || publishableKey.isEmpty()) return BackendConfiguration.Missing
        if (!isValidConfiguration(url, publishableKey)) return BackendConfiguration.Invalid

        val authStateStore = EncryptedAuthStateStore(context)
        val client = createSupabaseClient(
            supabaseUrl = url.trimEnd('/'),
            supabaseKey = publishableKey,
        ) {
            install(Auth) {
                flowType = FlowType.PKCE
                host = AUTH_REDIRECT_HOST
                scheme = AUTH_REDIRECT_SCHEME
                sessionManager = authStateStore
                codeVerifierCache = authStateStore
            }
            install(Postgrest)
        }
        return BackendConfiguration.Ready(client)
    }

    private fun isValidConfiguration(url: String, key: String): Boolean {
        val parsedUrl = url.toUri()
        return parsedUrl.scheme == "https" &&
            !parsedUrl.host.isNullOrBlank() &&
            parsedUrl.userInfo == null &&
            (parsedUrl.path.isNullOrEmpty() || parsedUrl.path == "/") &&
            parsedUrl.query == null &&
            parsedUrl.fragment == null &&
            key.startsWith(PUBLISHABLE_KEY_PREFIX)
    }

    const val AUTH_REDIRECT_SCHEME = "baytelhidaya"
    const val AUTH_REDIRECT_HOST = "auth-callback"
    private const val PUBLISHABLE_KEY_PREFIX = "sb_publishable_"
}
