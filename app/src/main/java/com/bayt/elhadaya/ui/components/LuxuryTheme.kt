package com.bayt.elhadaya.ui.components

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

object LuxuryPalette {
    val Background = Color(0xFF0B0907)
    val Surface = Color(0xFF15120E)
    val SurfaceVariant = Color(0xFF282219)
    val SurfaceElevated = Color(0xFF201B13)

    val RoyalGold = Color(0xFFD7B56D)
    val LightGold = Color(0xFFF2D99C)
    val DeepGold = Color(0xFF75551F)
    val OnGold = Color(0xFF211807)

    val PrimaryText = Color(0xFFF5F0E6)
    val SecondaryText = Color(0xFFC9C0B0)
    val MutedText = Color(0xFF958B7B)

    val GlassSurface = Color(0xCC1C1812)
    val GlassHighlight = Color(0x26FFFFFF)
    val GlassBorder = Color(0x66D7B56D)
}

private val LuxuryDarkColorScheme = darkColorScheme(
    primary = LuxuryPalette.RoyalGold,
    onPrimary = LuxuryPalette.OnGold,
    primaryContainer = Color(0xFF554019),
    onPrimaryContainer = LuxuryPalette.LightGold,
    inversePrimary = Color(0xFF70551F),
    secondary = Color(0xFFC4A76D),
    onSecondary = Color(0xFF261D0B),
    secondaryContainer = Color(0xFF403318),
    onSecondaryContainer = Color(0xFFE9D8AF),
    tertiary = Color(0xFFE0C48A),
    onTertiary = Color(0xFF2B210E),
    tertiaryContainer = Color(0xFF4A3A1D),
    onTertiaryContainer = Color(0xFFF3E1B9),
    background = LuxuryPalette.Background,
    onBackground = LuxuryPalette.PrimaryText,
    surface = LuxuryPalette.Surface,
    onSurface = LuxuryPalette.PrimaryText,
    surfaceVariant = LuxuryPalette.SurfaceVariant,
    onSurfaceVariant = LuxuryPalette.SecondaryText,
    surfaceTint = LuxuryPalette.RoyalGold,
    inverseSurface = Color(0xFFF0E8D8),
    inverseOnSurface = Color(0xFF29241B),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    outline = Color(0xFF94866A),
    outlineVariant = Color(0xFF4A4232),
    scrim = Color(0x99000000),
)

@Composable
fun LuxuryTheme(
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = LuxuryDarkColorScheme,
        content = content,
    )
}
