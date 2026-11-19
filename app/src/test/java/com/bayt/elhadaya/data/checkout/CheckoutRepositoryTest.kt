package com.bayt.elhadaya.data.checkout

import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class CheckoutRepositoryTest {
    @Test
    fun checkoutRpcParametersMatchServerSignatureAndExcludeClientPrices() {
        val parameters = createCheckoutOrderParameters(
            items = listOf(
                CartLine(
                    variantId = "54000000-0000-0000-0000-000000000001",
                    productId = "53000000-0000-0000-0000-000000000001",
                    productName = "صندوق",
                    variantName = "كبير",
                    weightGrams = 500,
                    unitPriceMinor = 12500,
                    quantity = 2,
                ),
            ),
            idempotencyKey = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            paymentMethod = PrepaidPaymentMethod.CARD,
            shippingRegionId = "55000000-0000-0000-0000-000000000001",
            terms = CheckoutTerms("prepaid-order-v1", "الشروط", "a".repeat(64)),
            governorate = "القاهرة",
            streetAddress = "شارع التحرير، مبنى 10",
            landmark = "أمام السوق",
            latitude = 30.0444,
            longitude = 31.2357,
        )

        assertEquals(
            setOf(
                "p_items",
                "p_idempotency_key",
                "p_payment_method",
                "p_shipping_region_id",
                "p_terms_version",
                "p_terms_sha256",
                "p_governorate",
                "p_street_address",
                "p_landmark",
                "p_latitude",
                "p_longitude",
            ),
            parameters.keys,
        )
        val item = parameters.getValue("p_items").jsonArray.single().jsonObject
        assertEquals(
            setOf("variant_id", "quantity"),
            item.keys,
        )
        assertEquals(
            "54000000-0000-0000-0000-000000000001",
            item.getValue("variant_id").jsonPrimitive.content,
        )
        assertEquals("2", item.getValue("quantity").jsonPrimitive.content)
        assertFalse(item.containsKey("price_minor"))
    }

    @Test
    fun sandboxPaymentIntentParametersMatchServerSignature() {
        val parameters = createSandboxPaymentIntentParameters(
            orderId = "81000000-0000-0000-0000-000000000001",
            idempotencyKey = "82000000-0000-0000-0000-000000000001",
        )

        assertEquals(setOf("p_order_id", "p_idempotency_key"), parameters.keys)
        assertEquals(
            "81000000-0000-0000-0000-000000000001",
            parameters.getValue("p_order_id").jsonPrimitive.content,
        )
        assertEquals(
            "82000000-0000-0000-0000-000000000001",
            parameters.getValue("p_idempotency_key").jsonPrimitive.content,
        )
    }
}
