package com.bayt.elhadaya.ui.admin

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.bayt.elhadaya.R
import com.bayt.elhadaya.data.catalog.AdminCatalogCategory
import com.bayt.elhadaya.data.catalog.CatalogAdminRole
import com.bayt.elhadaya.data.catalog.CatalogCategoryCreation
import com.bayt.elhadaya.data.catalog.CatalogProductCreation
import com.bayt.elhadaya.data.catalog.CatalogProductVariantInput
import java.math.BigDecimal

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdminCatalogScreen(
    role: CatalogAdminRole,
    categories: List<AdminCatalogCategory>,
    isLoading: Boolean,
    isSubmitting: Boolean,
    errorMessage: String?,
    successMessage: String?,
خ    categoryCreationRevision: Int,
    productCreationRevision: Int,
    onBack: () -> Unit,
    onRetry: () -> Unit,
    onCreateCategory: (CatalogCategoryCreation) -> Unit,
    onCreateProduct: (CatalogProductCreation) -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.catalog_admin_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                        )
                    }
                },
            )
        },
    ) { contentPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(contentPadding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = if (role == CatalogAdminRole.SUPER_ADMIN) {
                    stringResource(R.string.catalog_admin_super_admin)
                } else {
                    stringResource(R.string.catalog_admin_admin)
                },
                style = MaterialTheme.typography.titleMedium,
            )

            if (isLoading) {
                CircularProgressIndicator()
            }
            if (errorMessage != null) {
                Text(
                    text = errorMessage,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                )
                TextButton(onClick = onRetry) {
                    Text(stringResource(R.string.retry))
                }
            }
            if (successMessage != null) {
                Text(
                    text = successMessage,
                    color = MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }

            if (role == CatalogAdminRole.SUPER_ADMIN) {
                CategoryCreationForm(
                    categories = categories,
                    enabled = !isSubmitting && !isLoading,
                    creationRevision = categoryCreationRevision,
                    onCreate = onCreateCategory,
                )
            }

            ProductCreationForm(
                categories = categories,
                enabled = !isSubmitting && !isLoading,
                creationRevision = productCreationRevision,
                onCreate = onCreateProduct,
            )
        }
    }
}

@Composable
private fun CategoryCreationForm(
    categories: List<AdminCatalogCategory>,
    enabled: Boolean,
    creationRevision: Int,
    onCreate: (CatalogCategoryCreation) -> Unit,
) {
    var name by rememberSaveable { mutableStateOf("") }
    var slug by rememberSaveable { mutableStateOf("") }
    var description by rememberSaveable { mutableStateOf("") }
    var parentCategoryId by rememberSaveable { mutableStateOf<String?>(null) }
    var isActive by rememberSaveable { mutableStateOf(false) }
    var validationError by remember { mutableStateOf(false) }

    LaunchedEffect(creationRevision) {
        if (creationRevision > 0) {
            name = ""
            slug = ""
            description = ""
            parentCategoryId = null
            isActive = false
            validationError = false
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            stringResource(R.string.catalog_admin_add_category),
            style = MaterialTheme.typography.titleLarge,
        )
        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text(stringResource(R.string.catalog_admin_category_name)) },
            enabled = enabled,
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = slug,
            onValueChange = { slug = it },
            label = { Text(stringResource(R.string.catalog_admin_slug)) },
            supportingText = { Text(stringResource(R.string.catalog_admin_slug_hint)) },
            enabled = enabled,
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        CategoryDropdown(
            label = stringResource(R.string.catalog_admin_parent_category),
            categories = categories.filter { it.parentId == null },
            selectedId = parentCategoryId,
            allowNoSelection = true,
            enabled = enabled,
            onSelected = { parentCategoryId = it },
        )
        OutlinedTextField(
            value = description,
            onValueChange = { description = it },
            label = { Text(stringResource(R.string.catalog_admin_description)) },
            enabled = enabled,
            minLines = 2,
            modifier = Modifier.fillMaxWidth(),
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(
                checked = isActive,
                onCheckedChange = { isActive = it },
                enabled = enabled,
            )
            Text(stringResource(R.string.catalog_admin_activate_category))
        }
        if (validationError) {
            Text(
                text = stringResource(R.string.catalog_admin_invalid_category),
                color = MaterialTheme.colorScheme.error,
            )
        }
        Button(
            enabled = enabled,
            onClick = {
                val valid = name.trim().isNotEmpty() &&
                    name.trim().length <= 100 &&
                    isValidSlug(slug) &&
                    description.length <= 500
                validationError = !valid
                if (valid) {
                    onCreate(
                        CatalogCategoryCreation(
                            parentCategoryId = parentCategoryId,
                            slug = slug.trim(),
                            name = name.trim(),
                            description = description.trim().ifEmpty { null },
                            isActive = isActive,
                        ),
                    )
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(stringResource(R.string.catalog_admin_create_category))
        }
    }
}

@Composable
private fun ProductCreationForm(
    categories: List<AdminCatalogCategory>,
    enabled: Boolean,
    creationRevision: Int,
    onCreate: (CatalogProductCreation) -> Unit,
) {
    var name by rememberSaveable { mutableStateOf("") }
    var slug by rememberSaveable { mutableStateOf("") }
    var description by rememberSaveable { mutableStateOf("") }
    var imageObjectKey by rememberSaveable { mutableStateOf("") }
    var categoryId by rememberSaveable { mutableStateOf<String?>(null) }
    var publish by rememberSaveable { mutableStateOf(false) }
    var variants by remember { mutableStateOf(listOf(VariantFormRow())) }
    var validationError by remember { mutableStateOf(false) }

    LaunchedEffect(categories) {
        if (categoryId !in categories.map(AdminCatalogCategory::id)) {
            categoryId = categories.firstOrNull()?.id
        }
    }
    LaunchedEffect(creationRevision) {
        if (creationRevision > 0) {
            name = ""
            slug = ""
            description = ""
            imageObjectKey = ""
            categoryId = categories.firstOrNull()?.id
            publish = false
            variants = listOf(VariantFormRow())
            validationError = false
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            stringResource(R.string.catalog_admin_add_product),
            style = MaterialTheme.typography.titleLarge,
        )
        if (categories.isEmpty()) {
            Text(stringResource(R.string.catalog_admin_no_categories))
        } else {
            CategoryDropdown(
                label = stringResource(R.string.catalog_admin_product_category),
                categories = categories,
                selectedId = categoryId,
                allowNoSelection = false,
                enabled = enabled,
                onSelected = { categoryId = it },
            )
        }
        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text(stringResource(R.string.catalog_admin_product_name)) },
            enabled = enabled,
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = slug,
            onValueChange = { slug = it },
            label = { Text(stringResource(R.string.catalog_admin_slug)) },
            supportingText = { Text(stringResource(R.string.catalog_admin_slug_hint)) },
            enabled = enabled,
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = description,
            onValueChange = { description = it },
            label = { Text(stringResource(R.string.catalog_admin_description)) },
            enabled = enabled,
            minLines = 2,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = imageObjectKey,
            onValueChange = { imageObjectKey = it },
            label = { Text(stringResource(R.string.catalog_admin_image_key)) },
            supportingText = { Text(stringResource(R.string.catalog_admin_image_key_hint)) },
            enabled = enabled,
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )

        Text(
            stringResource(R.string.catalog_admin_variants),
            style = MaterialTheme.typography.titleMedium,
        )
        variants.forEachIndexed { index, variant ->
            VariantFields(
                index = index,
                variant = variant,
                canRemove = variants.size > 1,
                enabled = enabled,
                onChange = { updated ->
                    variants = variants.toMutableList().also { it[index] = updated }
                },
                onRemove = {
                    variants = variants.toMutableList().also { it.removeAt(index) }
                },
            )
        }
        OutlinedButton(
            enabled = enabled && variants.size < 50,
            onClick = { variants = variants + VariantFormRow() },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Filled.Add, contentDescription = null)
            Text(stringResource(R.string.catalog_admin_add_variant))
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(
                checked = publish,
                onCheckedChange = { publish = it },
                enabled = enabled,
            )
            Text(stringResource(R.string.catalog_admin_publish_now))
        }
        if (validationError) {
            Text(
                text = stringResource(R.string.catalog_admin_invalid_product),
                color = MaterialTheme.colorScheme.error,
            )
        }
        Button(
            enabled = enabled && categories.isNotEmpty(),
            onClick = {
                val parsedVariants = variants.mapNotNull { row ->
                    val weight = row.weightGrams.toIntOrNull()
                    val priceMinor = parsePriceMinor(row.price)
                    if (row.name.trim().isEmpty() || row.name.trim().length > 100 ||
                        weight == null || weight <= 0 ||
                        priceMinor == null
                    ) {
                        null
                    } else {
                        CatalogProductVariantInput(row.name.trim(), weight, priceMinor)
                    }
                }
                val valid = categoryId != null &&
                    name.trim().isNotEmpty() &&
                    name.trim().length <= 160 &&
                    isValidSlug(slug) &&
                    description.length <= 2000 &&
                    imageObjectKey.length <= 512 &&
                    (imageObjectKey.isBlank() || isValidObjectKey(imageObjectKey)) &&
                    parsedVariants.size == variants.size &&
                    parsedVariants.isNotEmpty()
                validationError = !valid
                if (valid) {
                    onCreate(
                        CatalogProductCreation(
                            categoryId = requireNotNull(categoryId),
                            slug = slug.trim(),
                            name = name.trim(),
                            description = description.trim().ifEmpty { null },
                            imageObjectKey = imageObjectKey.trim().ifEmpty { null },
                            publish = publish,
                            variants = parsedVariants,
                        ),
                    )
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(stringResource(R.string.catalog_admin_create_product))
        }
    }
}

@Composable
private fun VariantFields(
    index: Int,
    variant: VariantFormRow,
    canRemove: Boolean,
    enabled: Boolean,
    onChange: (VariantFormRow) -> Unit,
    onRemove: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = stringResource(R.string.catalog_admin_variant_number, index + 1),
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.weight(1f),
            )
            if (canRemove) {
                IconButton(onClick = onRemove, enabled = enabled) {
                    Icon(
                        Icons.Filled.Delete,
                        contentDescription = stringResource(R.string.catalog_admin_remove_variant),
                    )
                }
            }
        }
        OutlinedTextField(
            value = variant.name,
            onValueChange = { onChange(variant.copy(name = it)) },
            label = { Text(stringResource(R.string.catalog_admin_variant_name)) },
            enabled = enabled,
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = variant.weightGrams,
            onValueChange = { onChange(variant.copy(weightGrams = it)) },
            label = { Text(stringResource(R.string.catalog_admin_weight_grams)) },
            enabled = enabled,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = variant.price,
            onValueChange = { onChange(variant.copy(price = it)) },
            label = { Text(stringResource(R.string.catalog_admin_price_egp)) },
            enabled = enabled,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun CategoryDropdown(
    label: String,
    categories: List<AdminCatalogCategory>,
    selectedId: String?,
    allowNoSelection: Boolean,
    enabled: Boolean,
    onSelected: (String?) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val selected = categories.firstOrNull { it.id == selectedId }
    val selectedLabel = selected?.displayName(categories)
        ?: if (allowNoSelection) stringResource(R.string.catalog_admin_root_category)
        else ""

    Box(modifier = Modifier.fillMaxWidth()) {
        OutlinedTextField(
            value = selectedLabel,
            onValueChange = {},
            label = { Text(label) },
            readOnly = true,
            enabled = enabled,
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = enabled) { expanded = true },
        )
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            if (allowNoSelection) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.catalog_admin_root_category)) },
                    onClick = {
                        onSelected(null)
                        expanded = false
                    },
                )
            }
            categories.forEach { category ->
                DropdownMenuItem(
                    text = { Text(category.displayName(categories)) },
                    onClick = {
                        onSelected(category.id)
                        expanded = false
                    },
                )
            }
        }
    }
}

private fun AdminCatalogCategory.displayName(
    categories: List<AdminCatalogCategory>,
): String {
    val parentName = categories.firstOrNull { it.id == parentId }?.name
    return if (parentName == null) name else "$parentName / $name"
}

private fun isValidSlug(value: String): Boolean =
    Regex("^[a-z0-9]+(-[a-z0-9]+)*$").matches(value.trim())

private fun isValidObjectKey(value: String): Boolean {
    val key = value.trim()
    return key.isNotEmpty() &&
        !key.startsWith('/') &&
        !Regex("(^|/)\\.\\.?(/|$)").containsMatchIn(key)
}

internal fun parsePriceMinor(value: String): Long? {
    val trimmed = value.trim()
    if (!Regex("^[0-9]+(\\.[0-9]{1,2})?$").matches(trimmed)) return null
    return try {
        BigDecimal(trimmed).movePointRight(2).longValueExact()
            .takeIf { it > 0 }
    } catch (_: NumberFormatException) {
        null
    } catch (_: ArithmeticException) {
        null
    }
}

private data class VariantFormRow(
    val name: String = "",
    val weightGrams: String = "",
    val price: String = "",
)
