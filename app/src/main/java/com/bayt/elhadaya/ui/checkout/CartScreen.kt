package com.bayt.elhadaya.ui.checkout

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.bayt.elhadaya.R
import com.bayt.elhadaya.data.checkout.CartLine
import com.bayt.elhadaya.data.checkout.CheckoutReceipt
import com.bayt.elhadaya.data.checkout.CheckoutTerms
import com.bayt.elhadaya.data.checkout.PrepaidPaymentMethod
import com.bayt.elhadaya.data.checkout.SandboxPaymentIntent
import com.bayt.elhadaya.data.checkout.ShippingRegion
import com.bayt.elhadaya.ui.components.LuxuryBottomNav
import com.bayt.elhadaya.ui.components.LuxuryPalette
import com.bayt.elhadaya.ui.components.LuxuryTopBar
import java.math.BigDecimal
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CartScreen(
    items: List<CartLine>,
    regions: List<ShippingRegion>,
    terms: CheckoutTerms?,
    selectedRegionId: String?,
    paymentMethod: PrepaidPaymentMethod,
    termsAccepted: Boolean,
    isAuthenticated: Boolean,
    isLoadingOptions: Boolean,
    isSubmitting: Boolean,
    optionsError: String?,
    checkoutError: String?,
    receipt: CheckoutReceipt?,
    sandboxPaymentIntent: SandboxPaymentIntent?,
    selectedNavigationItem: String,
    onQuantityChanged: (String, Int) -> Unit,
    onRegionSelected: (String) -> Unit,
    onPaymentMethodSelected: (PrepaidPaymentMethod) -> Unit,
    onTermsAccepted: (Boolean) -> Unit,
    onRetryOptions: () -> Unit,
    onCheckout: () -> Unit,
    onRetryPaymentIntent: () -> Unit,
    onSignIn: () -> Unit,
    onNavigationItemSelected: (String) -> Unit,
) {
    val selectedRegion = regions.firstOrNull { it.id == selectedRegionId }
    val subtotal = items.fold(BigDecimal.ZERO) { total, line ->
        total + BigDecimal.valueOf(line.unitPriceMinor)
            .multiply(BigDecimal.valueOf(line.quantity.toLong()))
    }
    val total = subtotal + BigDecimal.valueOf(selectedRegion?.shippingMinor ?: 0L)
    val enabled = items.isNotEmpty() &&
        selectedRegion != null &&
        terms != null &&
        termsAccepted &&
        isAuthenticated &&
        !isLoadingOptions &&
        !isSubmitting

    Scaffold(
        topBar = { LuxuryTopBar(title = stringResource(R.string.cart_title)) },
        bottomBar = {
            LuxuryBottomNav(
                selectedItem = selectedNavigationItem,
                onItemSelected = {
                    if (!isSubmitting) onNavigationItemSelected(it)
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (receipt != null) {
                Text(
                    stringResource(R.string.checkout_order_created, receipt.orderId),
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    stringResource(R.string.checkout_payment_pending),
                    color = LuxuryPalette.LightGold,
                )
                Text(stringResource(R.string.checkout_total, formatPrice(receipt.totalMinor)))
                if (sandboxPaymentIntent != null) {
                    Text(stringResource(R.string.checkout_sandbox_mode))
                    Text(
                        stringResource(
                            R.string.checkout_sandbox_reference,
                            sandboxPaymentIntent.paymentReference,
                        ),
                    )
                } else {
                    checkoutError?.let {
                        Text(it, color = MaterialTheme.colorScheme.error)
                    }
                    Button(
                        onClick = onRetryPaymentIntent,
                        enabled = !isSubmitting,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        if (isSubmitting) {
                            CircularProgressIndicator()
                        } else {
                            Text(stringResource(R.string.checkout_retry_payment_intent))
                        }
                    }
                }
                return@Column
            }

            if (items.isEmpty()) {
                Text(stringResource(R.string.cart_empty))
                return@Column
            }

            items.forEach { line ->
                Surface(
                    color = LuxuryPalette.GlassSurface,
                    shape = MaterialTheme.shapes.medium,
                ) {
                    Column(modifier = Modifier.fillMaxWidth().padding(14.dp)) {
                        Text(line.productName, style = MaterialTheme.typography.titleSmall)
                        Text(
                            stringResource(
                                R.string.cart_variant_summary,
                                line.variantName,
                                line.weightGrams,
                                formatPrice(line.unitPriceMinor),
                            ),
                            color = LuxuryPalette.SecondaryText,
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.End,
                        ) {
                            TextButton(
                                enabled = line.quantity > 1 && !isSubmitting,
                                onClick = { onQuantityChanged(line.variantId, line.quantity - 1) },
                            ) {
                                Text("-")
                            }
                            Text(line.quantity.toString())
                            TextButton(
                                enabled = line.quantity < Int.MAX_VALUE && !isSubmitting,
                                onClick = { onQuantityChanged(line.variantId, line.quantity + 1) },
                            ) {
                                Text("+")
                            }
                        }
                    }
                }
            }

            Text(stringResource(R.string.checkout_shipping_region), style = MaterialTheme.typography.titleMedium)
            if (isLoadingOptions) {
                CircularProgressIndicator(color = LuxuryPalette.RoyalGold)
            } else if (optionsError != null) {
                Text(optionsError, color = MaterialTheme.colorScheme.error)
                TextButton(onClick = onRetryOptions) { Text(stringResource(R.string.retry)) }
            } else if (regions.isEmpty()) {
                Text(stringResource(R.string.checkout_no_regions))
            } else {
                regions.forEach { region ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(
                            selected = selectedRegionId == region.id,
                            onClick = if (isSubmitting) null else ({ onRegionSelected(region.id) }),
                            enabled = !isSubmitting,
                        )
                        Text(
                            stringResource(
                                R.string.checkout_region_option,
                                region.name,
                                formatPrice(region.shippingMinor),
                            ),
                        )
                    }
                }
            }

            Text(stringResource(R.string.checkout_payment_method), style = MaterialTheme.typography.titleMedium)
            PrepaidPaymentMethod.values().forEach { method ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(
                        selected = paymentMethod == method,
                        onClick = if (isSubmitting) null else ({ onPaymentMethodSelected(method) }),
                        enabled = !isSubmitting,
                    )
                    Text(stringResource(method.labelResource()))
                }
            }
            Text(
                stringResource(R.string.checkout_prepaid_only),
                color = LuxuryPalette.SecondaryText,
            )

            if (terms != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(
                        checked = termsAccepted,
                        onCheckedChange = onTermsAccepted,
                        enabled = !isSubmitting,
                    )
                    Text(terms.text, style = MaterialTheme.typography.bodySmall)
                }
            }

            Text(
                stringResource(
                    R.string.checkout_total,
                    formatPrice(total),
                ),
                style = MaterialTheme.typography.titleLarge,
                color = LuxuryPalette.LightGold,
            )
            checkoutError?.let {
                Text(it, color = MaterialTheme.colorScheme.error)
            }
            if (!isAuthenticated) {
                TextButton(onClick = onSignIn) {
                    Text(stringResource(R.string.checkout_sign_in_required))
                }
            }
            Button(
                onClick = onCheckout,
                enabled = enabled,
                modifier = Modifier.fillMaxWidth(),
                contentPadding = PaddingValues(14.dp),
            ) {
                if (isSubmitting) {
                    CircularProgressIndicator()
                } else {
                    Text(stringResource(R.string.checkout_submit))
                }
            }
        }
    }
}

private fun PrepaidPaymentMethod.labelResource(): Int = when (this) {
    PrepaidPaymentMethod.CARD -> R.string.checkout_card
    PrepaidPaymentMethod.MOBILE_WALLET -> R.string.checkout_mobile_wallet
    PrepaidPaymentMethod.BANK_TRANSFER -> R.string.checkout_bank_transfer
}

private fun formatPrice(priceMinor: Long): String =
    formatPrice(BigDecimal.valueOf(priceMinor))

private fun formatPrice(amountMinor: BigDecimal): String {
    val formatter = NumberFormat.getCurrencyInstance(Locale.forLanguageTag("ar-EG")).apply {
        currency = Currency.getInstance("EGP")
    }
    return formatter.format(amountMinor.movePointLeft(2).setScale(2))
}
