package com.bayt.elhadaya.ui.chat

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Image
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bayt.elhadaya.ui.components.LuxuryPalette
import com.bayt.elhadaya.ui.components.LuxuryTopBar

data class ChatMessage(
    val id: String,
    val text: String,
    val fromAi: Boolean,
    val imageUri: Uri? = null,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AiChatScreen(
    messages: List<ChatMessage>,
    isSending: Boolean,
    errorMessage: String?,
    onSendText: (String) -> Unit,
    onSendImage: (Uri) -> Unit,
    onBack: () -> Unit,
) {
    var draft by remember { mutableStateOf("") }
    val imagePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) onSendImage(uri)
    }

    Scaffold(
        topBar = {
            LuxuryTopBar(
                title = "مستشار الهدايا الذكي",
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "رجوع")
                    }
                },
            )
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            LazyColumn(
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(messages, key = ChatMessage::id) { message ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = if (message.fromAi) Arrangement.Start else Arrangement.End,
                    ) {
                        Surface(
                            shape = RoundedCornerShape(
                                topStart = 18.dp,
                                topEnd = 18.dp,
                                bottomStart = if (message.fromAi) 4.dp else 18.dp,
                                bottomEnd = if (message.fromAi) 18.dp else 4.dp,
                            ),
                            color = if (message.fromAi) LuxuryPalette.GlassSurface else LuxuryPalette.RoyalGold,
                        ) {
                            Column(modifier = Modifier.padding(12.dp)) {
                                if (message.imageUri != null) {
                                    Text(
                                        text = "صورة مرفقة",
                                        color = if (message.fromAi) LuxuryPalette.PrimaryText else LuxuryPalette.OnGold,
                                    )
                                }
                                if (message.text.isNotBlank()) {
                                    Text(
                                        text = message.text,
                                        color = if (message.fromAi) LuxuryPalette.PrimaryText else LuxuryPalette.OnGold,
                                    )
                                }
                            }
                        }
                    }
                }
            }

            if (errorMessage != null) {
                Surface(
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.errorContainer,
                ) {
                    Text(
                        text = errorMessage,
                        color = MaterialTheme.colorScheme.onErrorContainer,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
            }

            Surface(
                modifier = Modifier.fillMaxWidth(),
                color = LuxuryPalette.Surface,
            ) {
                Row(
                    modifier = Modifier.padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    IconButton(onClick = {
                        imagePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    }) {
                        Icon(Icons.Filled.Image, contentDescription = "إرفاق صورة")
                    }
                    OutlinedTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        modifier = Modifier.weight(1f),
                        placeholder = { Text("اكتب رسالتك") },
                        singleLine = true,
                    )
                    IconButton(
                        enabled = draft.isNotBlank() && !isSending,
                        onClick = {
                            onSendText(draft.trim())
                            draft = ""
                        },
                    ) {
                        if (isSending) {
                            CircularProgressIndicator(modifier = Modifier.padding(4.dp))
                        } else {
                            Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "إرسال")
                        }
                    }
                }
            }
        }
    }
}
