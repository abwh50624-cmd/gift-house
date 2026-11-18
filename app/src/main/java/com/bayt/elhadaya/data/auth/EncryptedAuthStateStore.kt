package com.bayt.elhadaya.data.auth

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.github.jan.supabase.auth.CodeVerifierCache
import io.github.jan.supabase.auth.SessionManager
import io.github.jan.supabase.auth.exception.NoSessionFoundException
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class EncryptedAuthStateStore(context: Context) : SessionManager, CodeVerifierCache {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun saveSession(session: UserSession) {
        saveEncrypted(SESSION_KEY, json.encodeToString(UserSession.serializer(), session))
    }

    override suspend fun loadSession(): UserSession {
        val serialized = loadEncrypted(SESSION_KEY) ?: throw NoSessionFoundException()
        return json.decodeFromString(UserSession.serializer(), serialized)
    }

    override suspend fun deleteSession() {
        deleteValue(SESSION_KEY)
    }

    override suspend fun saveCodeVerifier(codeVerifier: String) {
        saveEncrypted(CODE_VERIFIER_KEY, codeVerifier)
    }

    override suspend fun loadCodeVerifier(): String? = loadEncrypted(CODE_VERIFIER_KEY)

    override suspend fun deleteCodeVerifier() {
        deleteValue(CODE_VERIFIER_KEY)
    }

    @Suppress("UseKtx")
    private suspend fun saveEncrypted(key: String, value: String) {
        withContext(Dispatchers.IO) {
            val cipher = Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.ENCRYPT_MODE, getOrCreateKey())
            }
            val encrypted = cipher.iv + cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
            val encoded = Base64.encodeToString(encrypted, Base64.NO_WRAP)
            check(preferences.edit().putString(key, encoded).commit()) {
                "Could not persist encrypted authentication state."
            }
        }
    }

    private suspend fun loadEncrypted(key: String): String? = withContext(Dispatchers.IO) {
        val encoded = preferences.getString(key, null) ?: return@withContext null
        val encrypted = Base64.decode(encoded, Base64.NO_WRAP)
        if (encrypted.size <= GCM_IV_LENGTH) {
            throw IOException("Stored authentication state is invalid.")
        }
        val iv = encrypted.copyOfRange(0, GCM_IV_LENGTH)
        val ciphertext = encrypted.copyOfRange(GCM_IV_LENGTH, encrypted.size)
        val cipher = Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))
        }
        String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
    }

    @Suppress("UseKtx")
    private suspend fun deleteValue(key: String) {
        withContext(Dispatchers.IO) {
            check(preferences.edit().remove(key).commit()) {
                "Could not remove authentication state."
            }
        }
    }

    @Synchronized
    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEY_STORE = "AndroidKeyStore"
        const val CODE_VERIFIER_KEY = "pkce_code_verifier"
        const val GCM_IV_LENGTH = 12
        const val GCM_TAG_LENGTH_BITS = 128
        const val KEY_ALIAS = "bayt_elhidaya_auth_v1"
        const val PREFERENCES_NAME = "secure_auth_state_v1"
        const val SESSION_KEY = "user_session"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}
