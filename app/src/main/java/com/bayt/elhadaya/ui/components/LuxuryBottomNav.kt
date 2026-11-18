package com.bayt.elhadaya.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp

private data class LuxuryNavigationItem(
    val label: String,
    val icon: ImageVector,
)

private val luxuryNavigationItems = listOf(
    LuxuryNavigationItem("الرئيسية", Icons.Filled.Home),
    LuxuryNavigationItem("المتجر", Icons.Filled.ShoppingCart),
    LuxuryNavigationItem("طلباتي", Icons.AutoMirrored.Filled.List),
    LuxuryNavigationItem("المفضلة", Icons.Filled.Favorite),
    LuxuryNavigationItem("حسابي", Icons.Filled.Person),
)

@Composable
fun LuxuryBottomNav(
    selectedItem: String,
    onItemSelected: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = MaterialTheme.shapes.large

    Box(
        modifier = modifier
            .shadow(elevation = 8.dp, shape = shape, clip = false)
            .background(
                brush = Brush.horizontalGradient(
                    colors = listOf(
                        LuxuryPalette.LightGold,
                        LuxuryPalette.RoyalGold,
                        LuxuryPalette.DeepGold,
                        LuxuryPalette.RoyalGold,
                    ),
                ),
                shape = shape,
            )
            .padding(1.dp),
    ) {
        NavigationBar(
            modifier = Modifier
                .clip(shape)
                .background(
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            Color(0xFF211C14),
                            LuxuryPalette.GlassSurface,
                            LuxuryPalette.Surface,
                        ),
                    ),
                )
                .border(1.dp, LuxuryPalette.GlassBorder, shape),
            containerColor = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onSurface,
        ) {
            luxuryNavigationItems.forEach { item ->
                NavigationBarItem(
                    selected = selectedItem == item.label,
                    onClick = { onItemSelected(item.label) },
                    icon = {
                        Icon(
                            imageVector = item.icon,
                            contentDescription = item.label,
                        )
                    },
                    label = { Text(text = item.label) },
                    alwaysShowLabel = true,
                    colors = NavigationBarItemDefaults.colors(
                        selectedIconColor = LuxuryPalette.OnGold,
                        selectedTextColor = LuxuryPalette.LightGold,
                        indicatorColor = LuxuryPalette.RoyalGold,
                        unselectedIconColor = LuxuryPalette.SecondaryText,
                        unselectedTextColor = LuxuryPalette.MutedText,
                    ),
                )
            }
        }
    }
}
