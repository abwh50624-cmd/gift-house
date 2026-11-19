package com.bayt.elhadaya.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Logout
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun AppDrawer(
    authenticated: Boolean,
    accountEmail: String?,
    onAccountSelected: () -> Unit,
    onNotificationsSelected: () -> Unit,
    onSettingsSelected: () -> Unit,
    onLogoutSelected: () -> Unit,
) {
    ModalDrawerSheet {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = if (authenticated) accountEmail ?: "حسابي" else "مرحباً بك",
                style = androidx.compose.material3.MaterialTheme.typography.titleLarge,
            )
            Spacer(Modifier.height(16.dp))
            NavigationDrawerItem(
                label = { Text("إدارة الحساب") },
                icon = { Icon(Icons.Filled.Person, contentDescription = null) },
                selected = false,
                onClick = onAccountSelected,
            )
            NavigationDrawerItem(
                label = { Text("الإشعارات والرسائل") },
                icon = { Icon(Icons.Filled.Notifications, contentDescription = null) },
                selected = false,
                onClick = onNotificationsSelected,
            )
            NavigationDrawerItem(
                label = { Text("الإعدادات") },
                icon = { Icon(Icons.Filled.Settings, contentDescription = null) },
                selected = false,
                onClick = onSettingsSelected,
            )
            HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
            if (authenticated) {
                NavigationDrawerItem(
                    label = { Text("تسجيل الخروج الآمن") },
                    icon = { Icon(Icons.Filled.Logout, contentDescription = null) },
                    selected = false,
                    onClick = onLogoutSelected,
                )
            }
        }
    }
}
