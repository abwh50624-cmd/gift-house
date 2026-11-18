package com.bayt.elhadaya.data.catalog

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class CatalogRepositoryTest {
    @Test
    fun mapCatalogBuildsCardsFromReturnedProductsAndVariants() {
        val result = mapCatalog(
            categories = listOf(CategoryRow("category-1", "هدايا")),
            products = listOf(ProductRow("product-1", "category-1", "صندوق")),
            variants = listOf(VariantRow("variant-1", "product-1", "كبير", 500, 12500)),
        )

        assertEquals(listOf("category-1"), result.categories.map { it.id })
        assertEquals(1, result.products.size)
        assertEquals("صندوق - كبير", result.products.single().name)
        assertEquals("variant-1", result.products.single().id)
        assertEquals(12500L, result.products.single().priceMinor)
        assertEquals(500, result.products.single().weightGrams)
    }

    @Test
    fun mapCatalogFailsWhenRlsResultsDoNotContainReferencedCategory() {
        val exception = assertThrows(IllegalArgumentException::class.java) {
            mapCatalog(
                categories = emptyList(),
                products = listOf(ProductRow("product-1", "missing-category", "صندوق")),
                variants = listOf(VariantRow("variant-1", "product-1", "كبير", 500, 12500)),
            )
        }

        assertEquals("Catalog returned a product without its visible category.", exception.message)
    }
}
