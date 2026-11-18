package com.bayt.elhadaya.data.catalog

import com.bayt.elhadaya.ui.store.StoreCategory
import com.bayt.elhadaya.ui.store.StoreProduct
import com.bayt.elhadaya.ui.store.StoreUiState
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

class CatalogRepository(private val client: SupabaseClient) {
    suspend fun loadCatalog(): StoreUiState.Content {
        val categories = client.from("categories")
            .select(Columns.list("category_id", "name")) {
                filter { eq("is_active", true) }
                order("display_order", Order.ASCENDING)
            }
            .decodeList<CategoryRow>()

        val products = client.from("products")
            .select(Columns.list("product_id", "category_id", "name")) {
                filter { eq("status", "PUBLISHED") }
            }
            .decodeList<ProductRow>()

        val variants = if (products.isEmpty()) {
            emptyList()
        } else {
            client.from("product_variants")
                .select(
                    Columns.list(
                        "variant_id",
                        "product_id",
                        "variant_name",
                        "weight_grams",
                        "price_minor",
                    ),
                ) {
                    filter {
                        eq("is_active", true)
                        isIn("product_id", products.map(ProductRow::productId))
                    }
                    order("display_order", Order.ASCENDING)
                }
                .decodeList<VariantRow>()
        }

        return mapCatalog(categories, products, variants)
    }
}

internal fun mapCatalog(
    categories: List<CategoryRow>,
    products: List<ProductRow>,
    variants: List<VariantRow>,
): StoreUiState.Content {
    val categoryById = categories.associateBy(CategoryRow::categoryId)
    val productById = products.associateBy(ProductRow::productId)
    val storeCategories = categories.map { StoreCategory(it.categoryId, it.name) }
    val storeProducts = variants.map { variant ->
        val product = requireNotNull(productById[variant.productId]) {
            "Catalog returned a variant without its visible product."
        }
        requireNotNull(categoryById[product.categoryId]) {
            "Catalog returned a product without its visible category."
        }
        StoreProduct(
            id = variant.variantId,
            categoryId = product.categoryId,
            name = "${product.name} - ${variant.variantName}",
            priceMinor = variant.priceMinor,
            weightGrams = variant.weightGrams,
        )
    }
    return StoreUiState.Content(storeCategories, storeProducts)
}

@Serializable
internal data class CategoryRow(
    @SerialName("category_id") val categoryId: String,
    val name: String,
)

@Serializable
internal data class ProductRow(
    @SerialName("product_id") val productId: String,
    @SerialName("category_id") val categoryId: String,
    val name: String,
)

@Serializable
internal data class VariantRow(
    @SerialName("variant_id") val variantId: String,
    @SerialName("product_id") val productId: String,
    @SerialName("variant_name") val variantName: String,
    @SerialName("weight_grams") val weightGrams: Int,
    @SerialName("price_minor") val priceMinor: Long,
)
