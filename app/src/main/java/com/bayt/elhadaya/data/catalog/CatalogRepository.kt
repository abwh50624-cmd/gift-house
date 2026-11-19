package com.bayt.elhadaya.data.catalog

import com.bayt.elhadaya.ui.store.StoreCategory
import com.bayt.elhadaya.ui.store.StoreProduct
import com.bayt.elhadaya.ui.store.StoreProductDetails
import com.bayt.elhadaya.ui.store.StoreUiState
import com.bayt.elhadaya.ui.store.StoreVariant
import io.github.jan.supabase.SupabaseClient
import com.bayt.elhadaya.BuildConfig
import io.github.jan.supabase.postgrest.from
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject

fun resolveR2PublicUrl(objectKey: String): String? {
    val base = BuildConfig.R2_PUBLIC_BASE_URL.trim().trimEnd('/')
    val key = objectKey.trim().trimStart('/')
    if (base.isBlank() || key.isBlank()) return null
    return "$base/$key"
}

class CatalogRepository(private val client: SupabaseClient) {
    suspend fun loadAdminRole(userId: String): CatalogAdminRole? {
        val role = client.from("app_user_roles")
            .select(Columns.list("role")) {
                filter { eq("user_id", userId) }
            }
            .decodeList<CatalogRoleRow>()
            .singleOrNull()
            ?.role
            ?: return null

        return when (role) {
            "ADMIN" -> CatalogAdminRole.ADMIN
            "SUPER_ADMIN" -> CatalogAdminRole.SUPER_ADMIN
            "CUSTOMER" -> null
            else -> error("Supabase returned an unknown catalog role.")
        }
    }

    suspend fun loadAdminCategories(): List<AdminCatalogCategory> =
        client.from("categories")
            .select(
                Columns.list(
                    "category_id",
                    "parent_category_id",
                    "name",
                    "slug",
                    "is_active",
                ),
            ) {
                filter { eq("is_active", true) }
                order("display_order", Order.ASCENDING)
            }
            .decodeList<AdminCategoryRow>()
            .map {
                AdminCatalogCategory(
                    id = it.categoryId,
                    parentId = it.parentCategoryId,
                    name = it.name,
                    slug = it.slug,
                    isActive = it.isActive,
                )
            }

    suspend fun createCategory(category: CatalogCategoryCreation) {
        client.from("categories").insert(
            CategoryInsert(
                parentCategoryId = category.parentCategoryId,
                slug = category.slug,
                name = category.name,
                description = category.description,
                isActive = category.isActive,
            ),
        )
    }

    suspend fun createProduct(product: CatalogProductCreation): String =
        client.postgrest.rpc(
            function = "create_catalog_product_with_variants",
            parameters = Json.encodeToJsonElement(
                CreateCatalogProductRequest.serializer(),
                CreateCatalogProductRequest(
                    categoryId = product.categoryId,
                    slug = product.slug,
                    name = product.name,
                    description = product.description,
                    imageObjectKey = product.imageObjectKey,
                    publish = product.publish,
                    variants = product.variants,
                ),
            ).jsonObject,
        ).decodeAs()

    suspend fun loadCatalog(): StoreUiState.Content {
        val categories = client.from("categories")
            .select(Columns.list("category_id", "parent_category_id", "name")) {
                filter { eq("is_active", true) }
                order("display_order", Order.ASCENDING)
            }
            .decodeList<CategoryRow>()

        val products = client.from("products")
            .select(Columns.list("product_id", "category_id", "name", "description", "image_object_key")) {
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

    suspend fun loadProductDetails(productId: String): StoreProductDetails? {
        val product = client.from("products")
            .select(
                Columns.list(
                    "product_id",
                    "category_id",
                    "name",
                    "description",
                    "image_object_key",
                ),
            ) {
                filter {
                    eq("product_id", productId)
                    eq("status", "PUBLISHED")
                }
            }
            .decodeList<ProductRow>()
            .singleOrNull()
            ?: return null

        val variants = client.from("product_variants")
            .select(
                Columns.list(
                    "variant_id",
                    "variant_name",
                    "weight_grams",
                    "price_minor",
                ),
            ) {
                filter {
                    eq("product_id", product.productId)
                    eq("is_active", true)
                }
                order("display_order", Order.ASCENDING)
            }
            .decodeList<ProductDetailVariantRow>()

        if (variants.isEmpty()) return null
        return StoreProductDetails(
            id = product.productId,
            categoryId = product.categoryId,
            name = product.name,
            description = product.description,
            imageObjectKey = product.imageObjectKey,
            imageUrl = product.imageObjectKey?.let(::resolveR2PublicUrl),
            variants = variants.map {
                StoreVariant(
                    id = it.variantId,
                    name = it.variantName,
                    weightGrams = it.weightGrams,
                    priceMinor = it.priceMinor,
                )
            },
        )
    }
}

enum class CatalogAdminRole {
    ADMIN,
    SUPER_ADMIN,
}

data class AdminCatalogCategory(
    val id: String,
    val parentId: String?,
    val name: String,
    val slug: String,
    val isActive: Boolean,
)

data class CatalogCategoryCreation(
    val parentCategoryId: String?,
    val slug: String,
    val name: String,
    val description: String?,
    val isActive: Boolean,
)

data class CatalogProductCreation(
    val categoryId: String,
    val slug: String,
    val name: String,
    val description: String?,
    val imageObjectKey: String?,
    val publish: Boolean,
    val variants: List<CatalogProductVariantInput>,
)

@Serializable
data class CatalogProductVariantInput(
    @SerialName("variant_name") val name: String,
    @SerialName("weight_grams") val weightGrams: Int,
    @SerialName("price_minor") val priceMinor: Long,
)

@Serializable
private data class CreateCatalogProductRequest(
    @SerialName("p_category_id") val categoryId: String,
    @SerialName("p_slug") val slug: String,
    @SerialName("p_name") val name: String,
    @SerialName("p_description") val description: String?,
    @SerialName("p_image_object_key") val imageObjectKey: String?,
    @SerialName("p_publish") val publish: Boolean,
    @SerialName("p_variants") val variants: List<CatalogProductVariantInput>,
)

@Serializable
private data class CatalogRoleRow(val role: String)

@Serializable
private data class AdminCategoryRow(
    @SerialName("category_id") val categoryId: String,
    @SerialName("parent_category_id") val parentCategoryId: String?,
    val name: String,
    val slug: String,
    @SerialName("is_active") val isActive: Boolean,
)

@Serializable
private data class CategoryInsert(
    @SerialName("parent_category_id") val parentCategoryId: String?,
    val slug: String,
    val name: String,
    val description: String?,
    @SerialName("is_active") val isActive: Boolean,
)

internal fun mapCatalog(
    categories: List<CategoryRow>,
    products: List<ProductRow>,
    variants: List<VariantRow>,
): StoreUiState.Content {
    val categoryById = categories.associateBy(CategoryRow::categoryId)
    val productById = products.associateBy(ProductRow::productId)
    val storeCategories = categories.map {
        StoreCategory(it.categoryId, it.name, it.parentCategoryId)
    }
    val storeProducts = variants.groupBy(VariantRow::productId).map { (productId, productVariants) ->
        val product = requireNotNull(productById[productId]) {
            "Catalog returned a variant without its visible product."
        }
        requireNotNull(categoryById[product.categoryId]) {
            "Catalog returned a product without its visible category."
        }
        StoreProduct(
            id = product.productId,
            categoryId = product.categoryId,
            name = product.name,
            priceMinor = productVariants.minOf(VariantRow::priceMinor),
            variantCount = productVariants.size,
            imageObjectKey = product.imageObjectKey,
            imageUrl = product.imageObjectKey?.let(::resolveR2PublicUrl),
            imageDescription = product.description ?: product.name,
            description = product.description,
            colorVariants = productVariants.map(VariantRow::variantName).distinct(),
        )
    }
    return StoreUiState.Content(storeCategories, storeProducts)
}

@Serializable
internal data class CategoryRow(
    @SerialName("category_id") val categoryId: String,
    val name: String,
    @SerialName("parent_category_id") val parentCategoryId: String? = null,
    val description: String? = null,
)

@Serializable
internal data class ProductRow(
    @SerialName("product_id") val productId: String,
    @SerialName("category_id") val categoryId: String,
    val name: String,
    val description: String? = null,
    @SerialName("image_object_key") val imageObjectKey: String? = null,
)

@Serializable
internal data class VariantRow(
    @SerialName("variant_id") val variantId: String,
    @SerialName("product_id") val productId: String,
    @SerialName("variant_name") val variantName: String,
    @SerialName("weight_grams") val weightGrams: Int,
    @SerialName("price_minor") val priceMinor: Long,
)

@Serializable
internal data class ProductDetailVariantRow(
    @SerialName("variant_id") val variantId: String,
    @SerialName("variant_name") val variantName: String,
    @SerialName("weight_grams") val weightGrams: Int,
    @SerialName("price_minor") val priceMinor: Long,
)
