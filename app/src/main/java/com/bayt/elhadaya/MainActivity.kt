package com.bayt.elhadaya

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import com.bayt.elhadaya.data.auth.AuthRepository
import com.bayt.elhadaya.data.auth.BackendConfiguration
import com.bayt.elhadaya.data.auth.SupabaseBackend
import com.bayt.elhadaya.data.catalog.CatalogRepository
import com.bayt.elhadaya.ui.auth.AuthScreen
import com.bayt.elhadaya.ui.components.LuxuryBottomNav
import com.bayt.elhadaya.ui.components.LuxuryTheme
import com.bayt.elhadaya.ui.components.LuxuryTopBar
import com.bayt.elhadaya.ui.store.StoreScreen
import com.bayt.elhadaya.ui.store.StoreProduct
import com.bayt.elhadaya.ui.store.StoreUiState
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.handleDeeplinks
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.exceptions.HttpRequestException
import io.github.jan.supabase.exceptions.RestException
import io.ktor.client.plugins.HttpRequestTimeoutException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.serialization.SerializationException
import java.io.IOException
import java.math.BigDecimal
import java.security.GeneralSecurityException
import java.text.NumberFormat
import java.util.Currency
import java.util.Locale

class MainActivity : ComponentActivity() {
    private lateinit var backendConfiguration: BackendConfiguration
    private var supabaseClient: SupabaseClient? = null
    private var authRepository: AuthRepository? = null
    private var catalogRepository: CatalogRepository? = null

    private var storeState by mutableStateOf<StoreUiState>(StoreUiState.Loading)
    private var selectedNavigationItem by mutableStateOf("المتجر")
    private var selectedCategoryId by mutableStateOf<String?>(null)
    private var selectedProduct by mutableStateOf<StoreProduct?>(null)
    private var sessionInitializing by mutableStateOf(true)
    private var isAuthenticated by mutableStateOf(false)
    private var accountEmail by mutableStateOf<String?>(null)
    private var authBusy by mutableStateOf(false)
    private var authError by mutableStateOf<String?>(null)
    private var authMessage by mutableStateOf<String?>(null)
    private var pendingVerificationEmail by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        backendConfiguration = SupabaseBackend.configure(this)
        (backendConfiguration as? BackendConfiguration.Ready)?.let { backend ->
            supabaseClient = backend.client
            authRepository = AuthRepository(backend.client)
            catalogRepository = CatalogRepository(backend.client)
            handleDeepLink(backend.client, intent)
            observeSession(backend.client)
            loadCatalog()
        } ?: run {
            storeState = StoreUiState.Error(configurationMessage())
        }

        setContent {
            LuxuryTheme {
                if (selectedNavigationItem == "حسابي") {
                    AccountContent(
                        configuration = backendConfiguration,
                        busy = authBusy,
                        authenticated = isAuthenticated,
                        initializing = sessionInitializing,
                        email = accountEmail,
                        errorMessage = authError,
                        successMessage = authMessage,
                        verificationEmail = pendingVerificationEmail,
                        onEmailAction = ::submitEmailAuth,
                        onVerifyEmailCode = ::verifyEmailCode,
                        onResendVerificationCode = ::resendVerificationCode,
                        onCancelEmailVerification = ::cancelEmailVerification,
                        onGoogleSignIn = { runAuthAction { requireAuthRepository().signInWithGoogle() } },
                        onFacebookSignIn = { runAuthAction { requireAuthRepository().signInWithFacebook() } },
                        onSignOut = { runAuthAction { requireAuthRepository().signOut() } },
                        onNavigationItemSelected = ::selectNavigationItem,
                    )
                } else {
                    StoreScreen(
                        state = storeState,
                        selectedCategoryId = selectedCategoryId,
                        selectedNavigationItem = selectedNavigationItem,
                        onCategorySelected = { selectedCategoryId = it },
                        onProductSelected = { productId ->
                            selectedProduct = (storeState as? StoreUiState.Content)
                                ?.products
                                ?.firstOrNull { it.id == productId }
                        },
                        onNavigationItemSelected = ::selectNavigationItem,
                        onRetry = ::loadCatalog,
                    )
                    selectedProduct?.let { product ->
                        ProductDetailsDialog(
                            product = product,
                            onDismiss = { selectedProduct = null },
                        )
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        supabaseClient?.let { handleDeepLink(it, intent) }
    }

    private fun handleDeepLink(client: SupabaseClient, intent: Intent) {
        client.handleDeeplinks(
            intent = intent,
            onError = {
                runOnUiThread {
                    authError = getString(R.string.auth_error)
                    sessionInitializing = false
                }
            },
        )
    }

    private fun observeSession(client: SupabaseClient) {
        lifecycleScope.launch {
            client.auth.sessionStatus.collect { status ->
                when (status) {
                    SessionStatus.Initializing -> sessionInitializing = true
                    is SessionStatus.Authenticated -> {
                        sessionInitializing = false
                        isAuthenticated = true
                        accountEmail = status.session.user?.email
                        authError = null
                        authMessage = null
                        pendingVerificationEmail = null
                    }
                    is SessionStatus.NotAuthenticated -> {
                        sessionInitializing = false
                        isAuthenticated = false
                        accountEmail = null
                    }
                    is SessionStatus.RefreshFailure -> {
                        sessionInitializing = false
                        isAuthenticated = false
                        accountEmail = null
                        authError = getString(R.string.auth_error)
                    }
                }
            }
        }
    }

    private fun loadCatalog() {
        val repository = catalogRepository
        if (repository == null) {
            storeState = StoreUiState.Error(configurationMessage())
            return
        }
        lifecycleScope.launch {
            storeState = StoreUiState.Loading
            storeState = try {
                repository.loadCatalog()
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: HttpRequestTimeoutException) {
                StoreUiState.Error(getString(R.string.store_load_error))
            } catch (_: HttpRequestException) {
                StoreUiState.Error(getString(R.string.store_load_error))
            } catch (_: RestException) {
                StoreUiState.Error(getString(R.string.store_load_error))
            } catch (_: SerializationException) {
                StoreUiState.Error(getString(R.string.store_load_error))
            } catch (_: IllegalArgumentException) {
                StoreUiState.Error(getString(R.string.store_load_error))
            } catch (_: IllegalStateException) {
                StoreUiState.Error(getString(R.string.store_load_error))
            } catch (_: IOException) {
                StoreUiState.Error(getString(R.string.store_load_error))
            }
        }
    }

    private fun submitEmailAuth(email: String, password: String, createAccount: Boolean) {
        runAuthAction {
            if (createAccount) {
                requireAuthRepository().signUpWithEmail(email, password)
                pendingVerificationEmail = email.trim()
                authMessage = getString(R.string.auth_signup_submitted)
            } else {
                requireAuthRepository().signInWithEmail(email, password)
            }
        }
    }

    private fun verifyEmailCode(code: String) {
        val email = pendingVerificationEmail ?: run {
            authError = getString(R.string.auth_error)
            return
        }
        runAuthAction {
            requireAuthRepository().verifyEmailSignup(email, code)
            pendingVerificationEmail = null
            authMessage = null
        }
    }

    private fun resendVerificationCode() {
        val email = pendingVerificationEmail ?: run {
            authError = getString(R.string.auth_error)
            return
        }
        runAuthAction {
            requireAuthRepository().resendEmailSignupCode(email)
            authMessage = getString(R.string.auth_code_resent)
        }
    }

    private fun cancelEmailVerification() {
        pendingVerificationEmail = null
        authError = null
        authMessage = null
    }

    private fun runAuthAction(action: suspend () -> Unit) {
        lifecycleScope.launch {
            authBusy = true
            authError = null
            authMessage = null
            try {
                action()
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: HttpRequestTimeoutException) {
                authError = getString(R.string.auth_error)
            } catch (_: HttpRequestException) {
                authError = getString(R.string.auth_error)
            } catch (_: RestException) {
                authError = getString(R.string.auth_error)
            } catch (_: SerializationException) {
                authError = getString(R.string.auth_error)
            } catch (_: IOException) {
                authError = getString(R.string.auth_error)
            } catch (_: GeneralSecurityException) {
                authError = getString(R.string.auth_error)
            } catch (_: SecurityException) {
                authError = getString(R.string.auth_error)
            } catch (_: ActivityNotFoundException) {
                authError = getString(R.string.auth_error)
            } catch (_: IllegalArgumentException) {
                authError = getString(R.string.auth_error)
            } catch (_: IllegalStateException) {
                authError = getString(R.string.auth_error)
            } finally {
                authBusy = false
            }
        }
    }

    private fun selectNavigationItem(item: String) {
        if (item == "المتجر" || item == "حسابي") {
            selectedNavigationItem = item
            if (item == "حسابي") selectedProduct = null
        }
    }

    private fun requireAuthRepository(): AuthRepository =
        checkNotNull(authRepository) { "Supabase Auth is not configured." }

    private fun configurationMessage(): String = when (backendConfiguration) {
        BackendConfiguration.Missing -> getString(R.string.backend_config_missing)
        BackendConfiguration.Invalid -> getString(R.string.backend_config_invalid)
        is BackendConfiguration.Ready -> getString(R.string.store_load_error)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@androidx.compose.runtime.Composable
private fun AccountContent(
    configuration: BackendConfiguration,
    busy: Boolean,
    authenticated: Boolean,
    initializing: Boolean,
    email: String?,
    errorMessage: String?,
    successMessage: String?,
    verificationEmail: String?,
    onEmailAction: (String, String, Boolean) -> Unit,
    onVerifyEmailCode: (String) -> Unit,
    onResendVerificationCode: () -> Unit,
    onCancelEmailVerification: () -> Unit,
    onGoogleSignIn: () -> Unit,
    onFacebookSignIn: () -> Unit,
    onSignOut: () -> Unit,
    onNavigationItemSelected: (String) -> Unit,
) {
    when (configuration) {
        BackendConfiguration.Missing,
        BackendConfiguration.Invalid -> ConfigurationContent(
            message = stringResource(
                if (configuration == BackendConfiguration.Missing) {
                    R.string.backend_config_missing
                } else {
                    R.string.backend_config_invalid
                },
            ),
            onNavigationItemSelected = onNavigationItemSelected,
        )

        is BackendConfiguration.Ready -> if (authenticated) {
            Scaffold(
                topBar = { LuxuryTopBar(title = stringResource(R.string.account_title)) },
                bottomBar = {
                    LuxuryBottomNav(
                        selectedItem = "حسابي",
                        onItemSelected = onNavigationItemSelected,
                    )
                },
            ) { padding ->
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding)
                        .padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Text(
                        text = stringResource(
                            R.string.account_signed_in_as,
                            email ?: stringResource(R.string.account_title),
                        ),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Button(
                        onClick = onSignOut,
                        enabled = !busy,
                        modifier = Modifier.padding(top = 20.dp),
                    ) {
                        Text(stringResource(R.string.account_sign_out))
                    }
                    if (busy) {
                        CircularProgressIndicator(modifier = Modifier.padding(top = 16.dp))
                    }
                    if (errorMessage != null) {
                        Text(
                            text = errorMessage,
                            color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.padding(top = 16.dp),
                        )
                    }
                }
            }
        } else if (initializing) {
            Scaffold(
                topBar = { LuxuryTopBar(title = stringResource(R.string.account_title)) },
                bottomBar = {
                    LuxuryBottomNav(
                        selectedItem = "حسابي",
                        onItemSelected = onNavigationItemSelected,
                    )
                },
            ) { padding ->
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(padding),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    CircularProgressIndicator()
                    Text(
                        stringResource(R.string.account_initializing),
                        modifier = Modifier.padding(top = 12.dp),
                    )
                }
            }
        } else {
            AuthScreen(
                busy = busy,
                errorMessage = errorMessage,
                successMessage = successMessage,
                verificationEmail = verificationEmail,
                selectedNavigationItem = "حسابي",
                onSubmitEmail = onEmailAction,
                onVerifyEmailCode = onVerifyEmailCode,
                onResendVerificationCode = onResendVerificationCode,
                onCancelEmailVerification = onCancelEmailVerification,
                onGoogleSignIn = onGoogleSignIn,
                onFacebookSignIn = onFacebookSignIn,
                onNavigationItemSelected = onNavigationItemSelected,
            )
        }
    }
}

@androidx.compose.runtime.Composable
private fun ProductDetailsDialog(
    product: StoreProduct,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(product.name) },
        text = {
            Text(
                stringResource(
                    R.string.product_details,
                    product.weightGrams,
                    formatPrice(product.priceMinor),
                ),
            )
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text(stringResource(R.string.close))
            }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@androidx.compose.runtime.Composable
private fun ConfigurationContent(
    message: String,
    onNavigationItemSelected: (String) -> Unit,
) {
    Scaffold(
        topBar = { LuxuryTopBar(title = stringResource(R.string.account_title)) },
        bottomBar = {
            LuxuryBottomNav(
                selectedItem = "حسابي",
                onItemSelected = onNavigationItemSelected,
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(message, color = MaterialTheme.colorScheme.error)
        }
    }
}

private fun formatPrice(priceMinor: Long): String {
    val formatter = NumberFormat.getCurrencyInstance(Locale.forLanguageTag("ar-EG")).apply {
        currency = Currency.getInstance("EGP")
    }
    return formatter.format(BigDecimal.valueOf(priceMinor, 2))
}
