package com.bayt.elhadaya.ui.auth

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.bayt.elhadaya.R
import com.bayt.elhadaya.ui.components.LuxuryBottomNav
import com.bayt.elhadaya.ui.components.LuxuryTopBar

enum class SocialSignInProvider {
    GOOGLE,
    FACEBOOK,
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AuthScreen(
    busy: Boolean,
    errorMessage: String?,
    successMessage: String?,
    verificationEmail: String?,
    activeSocialSignInProvider: SocialSignInProvider?,
    selectedNavigationItem: String,
    onSubmitEmail: (email: String, password: String, createAccount: Boolean) -> Unit,
    onVerifyEmailCode: (code: String) -> Unit,
    onResendVerificationCode: () -> Unit,
    onCancelEmailVerification: () -> Unit,
    onGoogleSignIn: () -> Unit,
    onFacebookSignIn: () -> Unit,
    onNavigationItemSelected: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var verificationCode by remember { mutableStateOf("") }
    var createAccount by remember { mutableStateOf(false) }
    var createAccount by remember { mutableStateOf(false) }
    var termsAccepted by remember { mutableStateOf(false) }



    Scaffold(
        modifier = modifier,
        topBar = { LuxuryTopBar(title = stringResource(R.string.account_title)) },
        bottomBar = {
            LuxuryBottomNav(
                selectedItem = selectedNavigationItem,
                onItemSelected = onNavigationItemSelected,
            )
        },
    ) { contentPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(contentPadding)
                .padding(horizontal = 24.dp, vertical = 24.dp),
            verticalArrangement = Arrangement.Center,
        ) {
            if (verificationEmail != null) {
                Text(
                    text = stringResource(R.string.auth_enter_code_for, verificationEmail),
                    style = MaterialTheme.typography.headlineSmall,
                )
                Spacer(Modifier.height(20.dp))
                OutlinedTextField(
                    value = verificationCode,
                    onValueChange = { value ->
                        if (value.all(Char::isDigit)) verificationCode = value
                    },
                    label = { Text(stringResource(R.string.auth_verification_code)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    singleLine = true,
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(16.dp))
                Button(
                    onClick = { onVerifyEmailCode(verificationCode) },
                    enabled = !busy && verificationCode.isNotBlank(),
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = PaddingValues(vertical = 14.dp),
                ) {
                    if (busy) {
                        CircularProgressIndicator()
                    } else {
                        Text(stringResource(R.string.auth_verify_code))
                    }
                }
                TextButton(
                    onClick = onResendVerificationCode,
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.auth_resend_code))
                }
                TextButton(
                    onClick = onCancelEmailVerification,
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.auth_cancel_verification))
                }
            } else {
                Text(
                    stringResource(
                        if (createAccount) R.string.auth_create_account else R.string.auth_sign_in,
                    ),
                    style = MaterialTheme.typography.headlineSmall,
                )
                Spacer(Modifier.height(20.dp))
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text(stringResource(R.string.auth_email)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    singleLine = true,
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text(stringResource(R.string.auth_password)) },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    singleLine = true,
                Spacer(Modifier.height(16.dp))
                androidx.compose.foundation.layout.Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                ) {
                    androidx.compose.material3.Checkbox(
                        checked = termsAccepted,
                        onCheckedChange = { termsAccepted = it },
                        enabled = !busy,
                    )
                    Text(
                        text = stringResource(R.string.auth_terms_consent),
                        style = MaterialTheme.typography.bodySmall,
                    )
                }

                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(16.dp))
                Button(
                    onClick = {
                        if (termsAccepted) {
                            onSubmitEmail(email, password, createAccount)
                        } else {
                            // TODO: Add error handling for terms not accepted
                        }
                    },
                    enabled = !busy && email.isNotBlank() && password.isNotBlank() && (termsAccepted || !createAccount),
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = PaddingValues(vertical = 14.dp),
                ) {
                    if (busy && activeSocialSignInProvider == null) {
                        CircularProgressIndicator()
                    } else {
                        Text(
                            stringResource(
                                if (createAccount) R.string.auth_create_account
                                else R.string.auth_sign_in,
                            ),
                        )
                    }
                }
                TextButton(
                    onClick = { createAccount = !createAccount },
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        stringResource(
                            if (createAccount) R.string.auth_have_account
                            else R.string.auth_need_account,
                        ),
                    )
                }
                Spacer(Modifier.height(16.dp))
                OutlinedButton(
                    onClick = onGoogleSignIn,
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = PaddingValues(vertical = 14.dp),
                ) {
                    if (activeSocialSignInProvider == SocialSignInProvider.GOOGLE) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                        )
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(stringResource(R.string.auth_google))
                }
                Spacer(Modifier.height(8.dp))
                OutlinedButton(
                    onClick = onFacebookSignIn,
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = PaddingValues(vertical = 14.dp),
                ) {
                    if (activeSocialSignInProvider == SocialSignInProvider.FACEBOOK) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                        )
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(stringResource(R.string.auth_facebook))
                }
            }
            if (errorMessage != null) {
                Spacer(Modifier.height(16.dp))
                Text(
                    text = errorMessage,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            if (successMessage != null) {
                Spacer(Modifier.height(12.dp))
                Text(
                    text = successMessage,
                    color = MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
}
