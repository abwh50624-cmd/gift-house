package com.bayt.elhadaya.data.checkout

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject

class CheckoutRepository(private val client: SupabaseClient) {
    suspend fun loadTerms(): CheckoutTerms =
        client.postgrest.rpc("get_checkout_terms").decodeAs()

    suspend fun loadShippingRegions(): List<ShippingRegion> =
        client.from("shipping_regions")
            .select(Columns.list("region_id", "name", "shipping_minor")) {
                filter { eq("is_active", true) }
                order("name", Order.ASCENDING)
            }
            .decodeList()

    suspend fun createOrder(
        items: List<CartLine>,
        idempotencyKey: String,
        paymentMethod: PrepaidPaymentMethod,
        shippingRegionId: String,
        terms: CheckoutTerms,
    ): CheckoutReceipt {
        return client.postgrest.rpc(
            function = "create_checkout_order",
            parameters = createCheckoutOrderParameters(
                items = items,
                idempotencyKey = idempotencyKey,
                paymentMethod = paymentMethod,
                shippingRegionId = shippingRegionId,
                terms = terms,
            ),
        ).decodeAs()
    }

    suspend fun createSandboxPaymentIntent(
        orderId: String,
        idempotencyKey: String,
    ): SandboxPaymentIntent =
        client.postgrest.rpc(
            function = "create_sandbox_payment_intent",
            parameters = createSandboxPaymentIntentParameters(orderId, idempotencyKey),
        ).decodeAs()
}

internal fun createSandboxPaymentIntentParameters(
    orderId: String,
    idempotencyKey: String,
) = Json.encodeToJsonElement(
    CreateSandboxPaymentIntentRequest.serializer(),
    CreateSandboxPaymentIntentRequest(
        orderId = orderId,
        idempotencyKey = idempotencyKey,
    ),
).jsonObject

internal fun createCheckoutOrderParameters(
    items: List<CartLine>,
    idempotencyKey: String,
    paymentMethod: PrepaidPaymentMethod,
    shippingRegionId: String,
    terms: CheckoutTerms,
) = Json.encodeToJsonElement(
    CreateCheckoutOrderRequest.serializer(),
    CreateCheckoutOrderRequest(
        items = items.map {
            CheckoutItemRequest(variantId = it.variantId, quantity = it.quantity)
        },
        idempotencyKey = idempotencyKey,
        paymentMethod = paymentMethod.apiValue,
        shippingRegionId = shippingRegionId,
        termsVersion = terms.version,
        termsSha256 = terms.sha256,
    ),
).jsonObject

@Serializable
data class CartLine(
    val variantId: String,
    val productId: String,
    val productName: String,
    val variantName: String,
    val weightGrams: Int,
    val unitPriceMinor: Long,
    val quantity: Int,
) {
    init {
        require(variantId.isNotBlank())
        require(productId.isNotBlank())
        require(productName.isNotBlank())
        require(variantName.isNotBlank())
        require(weightGrams > 0)
        require(unitPriceMinor > 0)
        require(quantity > 0)
    }
}

@Serializable
data class ShippingRegion(
    @SerialName("region_id")
    val id: String,
    val name: String,
    @SerialName("shipping_minor")
    val shippingMinor: Long,
)

enum class PrepaidPaymentMethod(val apiValue: String) {
    CARD("CARD"),
    MOBILE_WALLET("MOBILE_WALLET"),
    BANK_TRANSFER("BANK_TRANSFER"),
}

@Serializable
data class CheckoutTerms(
    val version: String,
    val text: String,
    val sha256: String,
)

@Serializable
data class CheckoutReceipt(
    @SerialName("order_id") val orderId: String,
    @SerialName("order_status") val orderStatus: String,
    @SerialName("payment_status") val paymentStatus: String,
    @SerialName("payment_method") val paymentMethod: String,
    @SerialName("currency_code") val currencyCode: String,
    @SerialName("subtotal_minor") val subtotalMinor: Long,
    @SerialName("shipping_minor") val shippingMinor: Long,
    @SerialName("total_minor") val totalMinor: Long,
    @SerialName("payment_expires_at") val paymentExpiresAt: String,
)

@Serializable
data class SandboxPaymentIntent(
    @SerialName("payment_attempt_id") val paymentAttemptId: String,
    val provider: String,
    @SerialName("payment_reference") val paymentReference: String,
    @SerialName("amount_minor") val amountMinor: Long,
    @SerialName("currency_code") val currencyCode: String,
    val status: String,
    val mode: String,
)

@Serializable
private data class CreateCheckoutOrderRequest(
    @SerialName("p_items") val items: List<CheckoutItemRequest>,
    @SerialName("p_idempotency_key") val idempotencyKey: String,
    @SerialName("p_payment_method") val paymentMethod: String,
    @SerialName("p_shipping_region_id") val shippingRegionId: String,
    @SerialName("p_terms_version") val termsVersion: String,
    @SerialName("p_terms_sha256") val termsSha256: String,
)

@Serializable
private data class CreateSandboxPaymentIntentRequest(
    @SerialName("p_order_id") val orderId: String,
    @SerialName("p_idempotency_key") val idempotencyKey: String,
)

@Serializable
private data class CheckoutItemRequest(
    @SerialName("variant_id") val variantId: String,
    val quantity: Int,
)
