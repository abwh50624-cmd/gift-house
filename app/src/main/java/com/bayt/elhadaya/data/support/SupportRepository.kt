package com.bayt.elhadaya.data.support

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import java.io.ByteArrayOutputStream

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.postgrest
import io.ktor.client.HttpClient
import io.ktor.client.engine.android.Android
import io.ktor.client.request.bearerAuth
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.put
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class SupportRepository(
    private val client: SupabaseClient,
    private val supabaseUrl: String,
    private val publishableKey: String,
) {
    suspend fun uploadChatImage(
        context: Context,
        uri: Uri,
        accessToken: String,
    ): R2UploadResult {
        val original = context.contentResolver.openInputStream(uri)?.use { input ->
            BitmapFactory.decodeStream(input)
        } ?: throw IllegalStateException("Unable to read selected image")
        val encoded = ByteArrayOutputStream().use { output ->
            if (!original.compress(Bitmap.CompressFormat.WEBP, 85, output)) {
                throw IllegalStateException("Unable to optimize selected image")
            }
            output.toByteArray()
        }
        if (encoded.isEmpty() || encoded.size > 10 * 1024 * 1024) {
            throw IllegalStateException("Uploaded image must be no larger than 10 MB")
        }
        original.recycle()

        val http = HttpClient(Android)
        try {
            val presign: HttpResponse = http.post("${supabaseUrl.trimEnd('/')}/functions/v1/r2-presign") {
                header("apikey", publishableKey)
                bearerAuth(accessToken)
                contentType(ContentType.Application.Json)
                setBody(
                    Json.encodeToString(
                        R2PresignRequest.serializer(),
                        R2PresignRequest("image/webp", encoded.size.toLong()),
                    ),
                )
            }
            if (!presign.status.isSuccess()) {
                throw IllegalStateException(presign.bodyAsText().ifBlank { "Unable to prepare image upload" })
            }
            val presigned = Json.decodeFromString<R2PresignResponse>(presign.bodyAsText())
            val upload: HttpResponse = http.put(presigned.uploadUrl) {
                contentType(ContentType.parse("image/webp"))
                setBody(encoded)
            }
            if (!upload.status.isSuccess()) {
                throw IllegalStateException("Image upload failed (${upload.status.value})")
            }
            return R2UploadResult(presigned.objectKey, presigned.publicUrl)
        } finally {
            http.close()
        }
    }
    suspend fun openThread(
        subject: String,
        initialMessage: String,
        idempotencyKey: String,
    ): SupportThreadOpenResult =
        client.postgrest.rpc(
            function = "open_support_thread",
            parameters = Json.encodeToJsonElement(
                OpenSupportThreadRequest.serializer(),
                OpenSupportThreadRequest(
                    subject = subject,
                    initialMessage = initialMessage,
                    idempotencyKey = idempotencyKey,
                ),
            ).jsonObject,
        ).decodeAs()

    suspend fun sendMessage(threadId: String, message: String, idempotencyKey: String) =
        client.postgrest.rpc(
            function = "send_support_message",
            parameters = Json.encodeToJsonElement(
                SendSupportMessageRequest.serializer(),
                SendSupportMessageRequest(threadId, message, idempotencyKey),
            ).jsonObject,
        ).decodeAs<SupportMessageSendResult>()

    suspend fun loadThreads(): List<SupportThread> =
        client.postgrest.rpc("get_my_support_threads").decodeList()

    suspend fun loadMessages(threadId: String): List<SupportMessage> =
        client.postgrest.rpc(
            function = "get_support_thread_messages",
            parameters = Json.encodeToJsonElement(
                ThreadMessagesRequest.serializer(),
                ThreadMessagesRequest(threadId),
            ).jsonObject,
        ).decodeList()

    fun observeMessages(threadId: String): Flow<List<SupportMessage>> = flow {
        while (true) {
            emit(loadMessages(threadId))
            delay(2_000)
        }
    }

    suspend fun requestAiReply(
        threadId: String,
        subject: String,
        message: String,
        complaintKind: String?,
        orderId: String?,
        imageObjectKey: String? = null,
        imageUrl: String? = null,
        accessToken: String,
    ) {
        val http = HttpClient(Android)
        try {
            val response: HttpResponse = http.post("${supabaseUrl.trimEnd('/')}/functions/v1/ai-concierge") {
                header("apikey", publishableKey)
                bearerAuth(accessToken)
                contentType(ContentType.Application.Json)
                setBody(
                    Json.encodeToString(
                        AiConciergeRequest.serializer(),
                        AiConciergeRequest(threadId, subject, message, complaintKind, orderId, imageObjectKey, imageUrl),
                    ),
                )
            }
            if (!response.status.isSuccess()) {
                val detail = response.bodyAsText()
                throw IllegalStateException(
                    if (detail.isBlank()) "AI concierge request failed (${response.status.value})" else detail,
                )
            }
        } finally {
            http.close()
        }
    }
}

@Serializable
private data class OpenSupportThreadRequest(
    @SerialName("p_subject") val subject: String,
    @SerialName("p_initial_message") val initialMessage: String,
    @SerialName("p_order_id") val orderId: String? = null,
    @SerialName("p_complaint_kind") val complaintKind: String? = null,
    @SerialName("p_idempotency_key") val idempotencyKey: String,
)

@Serializable
private data class SendSupportMessageRequest(
    @SerialName("p_thread_id") val threadId: String,
    @SerialName("p_message") val message: String,
    @SerialName("p_idempotency_key") val idempotencyKey: String,
)

@Serializable
private data class ThreadMessagesRequest(
    @SerialName("p_thread_id") val threadId: String,
)

@Serializable
private data class AiConciergeRequest(
    @SerialName("thread_id") val threadId: String,
    val subject: String,
    val message: String,
    @SerialName("complaint_kind") val complaintKind: String?,
    @SerialName("order_id") val orderId: String?,
    @SerialName("image_object_key") val imageObjectKey: String? = null,
    @SerialName("image_url") val imageUrl: String? = null,
)

@Serializable
private data class R2PresignRequest(
    @SerialName("content_type") val contentType: String,
    val size: Long,
)

@Serializable
private data class R2PresignResponse(
    @SerialName("upload_url") val uploadUrl: String,
    @SerialName("object_key") val objectKey: String,
    @SerialName("public_url") val publicUrl: String? = null,
)

data class R2UploadResult(
    val objectKey: String,
    val publicUrl: String?,
)

@Serializable
data class SupportThreadOpenResult(
    @SerialName("thread_id") val threadId: String,
    val status: String,
)

@Serializable
data class SupportMessageSendResult(
    @SerialName("thread_id") val threadId: String,
    @SerialName("sender_type") val senderType: String,
)

@Serializable
data class SupportThread(
    @SerialName("thread_id") val threadId: String,
    val subject: String,
    val status: String,
    val priority: Int,
    @SerialName("complaint_kind") val complaintKind: String?,
    @SerialName("updated_at") val updatedAt: String,
)

@Serializable
data class SupportMessage(
    @SerialName("message_id") val messageId: String,
    @SerialName("sender_type") val senderType: String,
    val body: String,
    @SerialName("ai_sandbox") val aiSandbox: Boolean,
    @SerialName("created_at") val createdAt: String,
)
