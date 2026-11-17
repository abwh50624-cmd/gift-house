package com.bayt.elhadaya.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.TopAppBarScrollBehavior
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LuxuryTopBar(
    title: String,
    modifier: Modifier = Modifier,
    navigationIcon: @Composable () -> Unit = {},
    actions: @Composable RowScope.() -> Unit = {},
    scrollBehavior: TopAppBarScrollBehavior? = null,
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
        TopAppBar(
            title = {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleLarge,
                )
            },
            modifier = Modifier
                .clip(shape)
                .background(
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            Color(0xFF211C14),
                            LuxuryPalette.GlassSurface,
                            Color(0xFF15120E),
                        ),
                    ),
                ),
            navigationIcon = navigationIcon,
            actions = actions,
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = Color.Transparent,
                titleContentColor = LuxuryPalette.PrimaryText,
                navigationIconContentColor = LuxuryPalette.RoyalGold,
                actionIconContentColor = LuxuryPalette.RoyalGold,
            ),
            scrollBehavior = scrollBehavior,
        )
    }
}
