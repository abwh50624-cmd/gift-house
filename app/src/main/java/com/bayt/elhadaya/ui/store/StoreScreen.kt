package com.bayt.elhadaya.ui.store

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.bayt.elhadaya.R
import com.bayt.elhadaya.ui.components.LuxuryBottomNav
import com.bayt.elhadaya.ui.components.LuxuryPalette
import com.bayt.elhadaya.ui.components.LuxuryProductCard
import com.bayt.elhadaya.ui.components.LuxuryTopBar
import java.math.BigDecimal
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale

data class StoreCategory(
    val id: String,
    val name: String,
)

data class StoreProduct(
    val id: String,
    val categoryId: String,
    val name: String,
    val priceMinor: Long,
    val variantCount: Int,
    val image: Painter? = null,
    val imageDescription: String? = null,
) {
    init {
        require(id.isNotBlank())
        require(categoryId.isNotBlank())
        require(name.isNotBlank())
        require(priceMinor > 0)
        require(variantCount > 0)
    }
}

data class StoreVariant(
    val id: String,
    val name: String,
    val weightGrams: Int,
    val priceMinor: Long,
) {
    init {
        require(id.isNotBlank())
        require(name.isNotBlank())
        require(weightGrams > 0)
        require(priceMinor > 0)
    }
}

data class StoreProductDetails(
    val id: String,
    val categoryId: String,
    val name: String,
    val description: String?,
    val variants: List<StoreVariant>,
)

sealed interface StoreUiState {
    data object Loading : StoreUiState
    data class Error(val message: String? = null) : StoreUiState
    data class Content(
        val categories: List<StoreCategory>,
        val products: List<StoreProduct>,
    ) : StoreUiState
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StoreScreen(
    state: StoreUiState,
    selectedCategoryId: String?,
    selectedNavigationItem: String,
    onCategorySelected: (String?) -> Unit,
    onProductSelected: (String) -> Unit,
    onNavigationItemSelected: (String) -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        topBar = {
            LuxuryTopBar(title = stringResource(R.string.store_title))
        },
        bottomBar = {
            LuxuryBottomNav(
                selectedItem = selectedNavigationItem,
                onItemSelected = onNavigationItemSelected,
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { contentPadding ->
        when (state) {
            StoreUiState.Loading -> StoreMessage(
                text = stringResource(R.string.store_loading),
                modifier = Modifier
                    .fillMaxSize()
                    .padding(contentPadding),
                showProgress = true,
            )

            is StoreUiState.Error -> StoreMessage(
                text = state.message ?: stringResource(R.string.store_load_error),
                modifier = Modifier
                    .fillMaxSize()
                    .padding(contentPadding),
                retryLabel = stringResource(R.string.retry),
                onRetry = onRetry,
            )

            is StoreUiState.Content -> StoreContent(
                state = state,
                selectedCategoryId = selectedCategoryId,
                onCategorySelected = onCategorySelected,
                onProductSelected = onProductSelected,
                contentPadding = contentPadding,
            )
        }
    }
}

@Composable
private fun StoreContent(
    state: StoreUiState.Content,
    selectedCategoryId: String?,
    onCategorySelected: (String?) -> Unit,
    onProductSelected: (String) -> Unit,
    contentPadding: PaddingValues,
) {
    val visibleProducts = if (selectedCategoryId == null) {
        state.products
    } else {
        state.products.filter { it.categoryId == selectedCategoryId }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(contentPadding),
    ) {
        Text(
            text = stringResource(R.string.store_categories),
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onBackground,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 8.dp),
        )

        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            item(key = "all") {
                CategoryChip(
                    name = stringResource(R.string.store_all_categories),
                    selected = selectedCategoryId == null,
                    onClick = { onCategorySelected(null) },
                )
            }
            items(state.categories, key = StoreCategory::id) { category ->
                CategoryChip(
                    name = category.name,
                    selected = selectedCategoryId == category.id,
                    onClick = { onCategorySelected(category.id) },
                )
            }
        }

        Spacer(modifier = Modifier.height(12.dp))

        if (visibleProducts.isEmpty()) {
            StoreMessage(
                text = stringResource(R.string.store_empty),
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
            )
        } else {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(minSize = 160.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(visibleProducts, key = StoreProduct::id) { product ->
                    LuxuryProductCard(
                        productName = product.name,
                        price = formatEgyptianPrice(product.priceMinor),
                        image = product.image,
                        imageContentDescription = product.imageDescription ?: product.name,
                        badge = stringResource(R.string.store_variant_count, product.variantCount),
                        onClick = { onProductSelected(product.id) },
                    )
                }
            }
        }
    }
}

@Composable
private fun CategoryChip(
    name: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(18.dp),
        color = if (selected) LuxuryPalette.RoyalGold else LuxuryPalette.GlassSurface,
        border = BorderStroke(
            width = 1.dp,
            color = if (selected) LuxuryPalette.LightGold else LuxuryPalette.GlassBorder,
        ),
    ) {
        Text(
            text = name,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            style = MaterialTheme.typography.labelLarge,
            color = if (selected) LuxuryPalette.OnGold else LuxuryPalette.PrimaryText,
        )
    }
}

@Composable
private fun StoreMessage(
    text: String,
    modifier: Modifier = Modifier,
    showProgress: Boolean = false,
    retryLabel: String? = null,
    onRetry: (() -> Unit)? = null,
) {
    Column(
        modifier = modifier.padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        if (showProgress) {
            CircularProgressIndicator(color = LuxuryPalette.RoyalGold)
            Spacer(modifier = Modifier.height(16.dp))
        }
        Text(
            text = text,
            style = MaterialTheme.typography.bodyLarge,
            color = LuxuryPalette.SecondaryText,
        )
        if (retryLabel != null && onRetry != null) {
            TextButton(onClick = onRetry) {
                Text(retryLabel)
            }
        }
    }
}

private fun formatEgyptianPrice(priceMinor: Long): String {
    val formatter = NumberFormat.getCurrencyInstance(Locale.forLanguageTag("ar-EG")).apply {
        currency = Currency.getInstance("EGP")
    }
    return formatter.format(BigDecimal.valueOf(priceMinor, 2))
}
