package com.bayt.elhadaya.data.auth

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.OtpType
import io.github.jan.supabase.auth.providers.OAuthProvider
import io.github.jan.supabase.auth.providers.invoke
import io.github.jan.supabase.auth.providers.builtin.Email

class AuthRepository(private val client: SupabaseClient) {
    suspend fun accessToken(): String? = client.auth.currentSessionOrNull()?.accessToken

    suspend fun signInWithEmail(emailAddress: String, password: String) {
        client.auth.signInWith(Email) {
            email = emailAddress.trim()
            this.password = password
        }
    }

    suspend fun signUpWithEmail(emailAddress: String, password: String) {
        client.auth.signUpWith(Email) {
            email = emailAddress.trim()
            this.password = password
        }
    }

    suspend fun verifyEmailSignup(emailAddress: String, code: String) {
        client.auth.verifyEmailOtp(
            type = OtpType.Email.SIGNUP,
            email = emailAddress.trim(),
            token = code.trim(),
        )
    }

    suspend fun resendEmailSignupCode(emailAddress: String) {
        client.auth.resendEmail(
            type = OtpType.Email.SIGNUP,
            email = emailAddress.trim(),
        )
    }

    suspend fun signInWithGoogle() {
        signInWithOAuthProvider("google")
    }

    suspend fun signInWithFacebook() {
        signInWithOAuthProvider("facebook")
    }

    private suspend fun signInWithOAuthProvider(provider: String) {
        client.auth.signInWith(OAuthProvider(provider)) {
            automaticallyOpenUrl = true
        }
    }

    suspend fun signOut() {
        client.auth.signOut()
    }
}
