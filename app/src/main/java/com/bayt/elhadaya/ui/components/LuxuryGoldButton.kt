package com.bayt.elhadaya.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@Composable
fun LuxuryGoldButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val shape = RoundedCornerShape(16.dp)
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val pressProgress by animateFloatAsState(
        targetValue = if (pressed && enabled) 1f else 0f,
        label = "buttonPress",
    )
    val goldGradient = if (enabled) {
        Brush.verticalGradient(
            colors = listOf(Color(0xFFFFE7A3), Color(0xFFC39135), Color(0xFF80531B)),
        )
    } else {
        Brush.verticalGradient(
            colors = listOf(Color(0xFF8A806A), Color(0xFF61594B), Color(0xFF464137)),
        )
    }
    val glassGradient = if (enabled) {
        Brush.verticalGradient(
            colors = listOf(Color(0xFF30271B), Color(0xFF171411), Color(0xFF100E0C)),
        )
    } else {
        Brush.verticalGradient(
            colors = listOf(Color(0xFF292622), Color(0xFF201E1B)),
        )
    }

    Box(
        modifier = modifier
            .shadow(
                elevation = (8f - 4f * pressProgress).dp,
                shape = shape,
                clip = false,
            )
            .background(goldGradient, shape)
            .graphicsLayer { translationY = 2.dp.toPx() * pressProgress },
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 3.dp)
                .heightIn(min = 52.dp)
                .clip(shape)
                .background(glassGradient)
                .border(
                    width = 1.dp,
                    brush = Brush.verticalGradient(
                        colors = if (enabled) {
                            listOf(Color(0xFFFFE9B1), Color(0xFFB98834), Color(0xFF72501F))
                        } else {
                            listOf(Color(0xFF8A806A), Color(0xFF514B40))
                        },
                    ),
                    shape = shape,
                )
                .clickable(
                    interactionSource = interactionSource,
                    indication = LocalIndication.current,
                    enabled = enabled,
                    role = Role.Button,
                    onClick = onClick,
                )
                .padding(horizontal = 24.dp, vertical = 14.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = text,
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                color = if (enabled) Color(0xFFFFE7A3) else Color(0xFFAAA397),
            )
        }
    }
}
