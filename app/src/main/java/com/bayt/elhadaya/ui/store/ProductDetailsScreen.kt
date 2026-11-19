package com.bayt.elhadaya.ui.store

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.IconButton
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.bayt.elhadaya.R
import com.bayt.elhadaya.ui.components.LuxuryBottomNav
import com.bayt.elhadaya.ui.components.LuxuryPalette
import com.bayt.elhadaya.ui.components.LuxuryTopBar
import java.math.BigDecimal
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale
import coil.compose.AsyncImage
import com.bayt.elhadaya.data.catalog.resolveR2PublicUrl

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProductDetailsScreen(
    details: StoreProductDetails?,
    loading: Boolean,
    errorMessage: String?,
    selectedNavigationItem: String,
    onBack: () -> Unit,
    onRetry: () -> Unit,
    onAddToCart: (StoreProductDetails, StoreVariant) -> Unit,
    onNavigationItemSelected: (String) -> Unit,
) {
    Scaffold(
        topBar = {
            LuxuryTopBar(
                title = details?.name ?: stringResource(R.string.product_details_title),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Text(stringResource(R.string.back))
                    }
                },
            )
        },
        bottomBar = {
            LuxuryBottomNav(
                selectedItem = selectedNavigationItem,
                onItemSelected = onNavigationItemSelected,
            )
        },
    ) { padding ->
        when {
            loading -> Column(
                modifier = Modifier.fillMaxSize().padding(padding),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                CircularProgressIndicator(color = LuxuryPalette.RoyalGold)
            }

            errorMessage != null || details == null -> Column(
                modifier = Modifier.fillMaxSize().padding(padding).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    errorMessage ?: stringResource(R.string.product_unavailable),
                    color = MaterialTheme.colorScheme.error,
                )
                TextButton(onClick = onRetry) {
                    Text(stringResource(R.string.retry))
                }
            }

            else -> LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                item {
                    val imageUrl = details.imageObjectKey?.let(resolveR2PublicUrl)
                    if (imageUrl != null) {
                        AsyncImage(
                            model = imageUrl,
                            contentDescription = details.name,
                            modifier = Modifier
                                .fillMaxWidth()
                                .aspectRatio(1f)
                                .clip(RoundedCornerShape(18.dp)),
                        )
                    }
                    Text(details.name, style = MaterialTheme.typography.headlineSmall)
                    
                    val description = details.description
                    if (!description.isNullOrBlank()) {
                        Text(
                            description,
                            color = LuxuryPalette.SecondaryText,
                            modifier = Modifier.padding(top = 8.dp),
                        )
                    }
                    Text(
                        stringResource(R.string.product_choose_variant),
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(top = 20.dp),
                    )
                }
                items(details.variants, key = StoreVariant::id) { variant ->
                    Surface(
                        color = LuxuryPalette.GlassSurface,
                        shape = MaterialTheme.shapes.medium,
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(variant.name, style = MaterialTheme.typography.titleSmall)
                                Text(
                                    stringResource(R.string.product_variant_weight, variant.weightGrams),
                                    color = LuxuryPalette.SecondaryText,
                                )
                                Text(
                                    formatPrice(variant.priceMinor),
                                    color = LuxuryPalette.LightGold,
                                    style = MaterialTheme.typography.titleMedium,
                                )
                            }
                            Button(onClick = { onAddToCart(details, variant) }) {
                                Text(stringResource(R.string.cart_add))
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun formatPrice(priceMinor: Long): String {
    val formatter = NumberFormat.getCurrencyInstance(Locale.forLanguageTag("ar-EG")).apply {
        currency = Currency.getInstance("EGP")
    }
    return formatter.format(BigDecimal.valueOf(priceMinor, 2))
}
