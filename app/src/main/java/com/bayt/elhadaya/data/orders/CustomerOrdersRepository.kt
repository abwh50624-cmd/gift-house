package com.bayt.elhadaya.data.orders

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject

class CustomerOrdersRepository(private val client: SupabaseClient) {
    suspend fun loadOrders(): List<CustomerOrder> =
        client.from("orders")
            .select(
                Columns.list(
                    "order_id",
                    "order_status",
                    "payment_status",
                    "shipping_status",
                    "total_minor",
                    "currency_code",
                    "created_at",
                ),
            ) {
                order("created_at", Order.DESCENDING)
            }
            .decodeList()

    suspend fun loadReturnRequests(): List<CustomerReturnRequest> =
        client.from("consumer_return_requests")
            .select(
                Columns.list(
                    "return_request_id",
                    "order_id",
                    "refund_amount_minor",
                    "reason",
                    "status",
                    "created_at",
                ),
            ) {
                order("created_at", Order.DESCENDING)
            }
            .decodeList()

    suspend fun createReturnRequest(
        orderId: String,
        refundAmountMinor: Long,
        reason: String,
        idempotencyKey: String,
    ): CustomerReturnResult {
        val confirmationId = client.postgrest.rpc(
            function = "confirm_legal_acceptance",
            parameters = Json.encodeToJsonElement(
                LegalAcceptanceRequest.serializer(),
                LegalAcceptanceRequest(
                    termsType = "REFUND",
                    termsVersion = "refund-v1",
                    termsSha256 = "20a889a3407b4efdc53ef49a3149b5375e73ee32aec2702fb50d5b4b2a313810",
                    orderId = orderId,
                    idempotencyKey = "refund-acceptance-$idempotencyKey",
                ),
            ).jsonObject,
        ).decodeAs<String>()

        val confirmationInsert = client.from("customer_contract_confirmations")
            .insert(
                ContractConfirmation(
                    orderId = orderId,
                    termsVersion = "refund-v1",
                    termsSha256 = "20a889a3407b4efdc53ef49a3149b5375e73ee32aec2702fb50d5b4b2a313810",
                )
            ) {
                select()
            }
            .decodeSingle<ContractConfirmation>()

        return client.postgrest.rpc(
            function = "request_consumer_return",
            parameters = Json.encodeToJsonElement(
                ConsumerReturnRequest.serializer(),
                ConsumerReturnRequest(
                    orderId = orderId,
                    refundAmountMinor = refundAmountMinor,
                    reason = reason,
                    contractConfirmationId = confirmationInsert.confirmationId,
                    idempotencyKey = idempotencyKey,
                ),
            ).jsonObject,
        ).decodeAs()
    }
}

@Serializable
private data class LegalAcceptanceRequest(
    @SerialName("p_terms_type") val termsType: String,
    @SerialName("p_terms_version") val termsVersion: String,
    @SerialName("p_terms_sha256") val termsSha256: String,
    @SerialName("p_order_id") val orderId: String,
    @SerialName("p_idempotency_key") val idempotencyKey: String,
)

@Serializable
private data class ContractConfirmation(
    @SerialName("confirmation_id") val confirmationId: String? = null,
    @SerialName("order_id") val orderId: String,
    @SerialName("terms_version") val termsVersion: String,
    @SerialName("terms_sha256") val termsSha256: String,
)

@Serializable
private data class ConsumerReturnRequest(
    @SerialName("p_order_id") val orderId: String,
    @SerialName("p_refund_amount_minor") val refundAmountMinor: Long,
    @SerialName("p_reason") val reason: String,
    @SerialName("p_contract_confirmation_id") val contractConfirmationId: String?,
    @SerialName("p_idempotency_key") val idempotencyKey: String,
)

@Serializable
data class CustomerOrder(
    @SerialName("order_id") val orderId: String,
    @SerialName("order_status") val orderStatus: String,
    @SerialName("payment_status") val paymentStatus: String,
    @SerialName("shipping_status") val shippingStatus: String,
    @SerialName("total_minor") val totalMinor: Long,
    @SerialName("currency_code") val currencyCode: String,
    @SerialName("created_at") val createdAt: String,
)

@Serializable
data class CustomerReturnRequest(
    @SerialName("return_request_id") val returnRequestId: String,
    @SerialName("order_id") val orderId: String,
    @SerialName("refund_amount_minor") val refundAmountMinor: Long,
    val reason: String,
    val status: String,
    @SerialName("created_at") val createdAt: String,
)

@Serializable
data class CustomerReturnResult(
    @SerialName("return_request_id") val returnRequestId: String,
    @SerialName("refund_id") val refundId: String,
    val status: String,
)
