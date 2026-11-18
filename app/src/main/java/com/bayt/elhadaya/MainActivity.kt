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
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
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
import com.bayt.elhadaya.data.checkout.CartLine
import com.bayt.elhadaya.data.checkout.CheckoutReceipt
import com.bayt.elhadaya.data.checkout.CheckoutRepository
import com.bayt.elhadaya.data.checkout.CheckoutTerms
import com.bayt.elhadaya.data.checkout.PrepaidPaymentMethod
import com.bayt.elhadaya.data.checkout.ShippingRegion
import com.bayt.elhadaya.ui.auth.AuthScreen
import com.bayt.elhadaya.ui.checkout.CartScreen
import com.bayt.elhadaya.ui.components.LuxuryBottomNav
import com.bayt.elhadaya.ui.components.LuxuryTheme
import com.bayt.elhadaya.ui.components.LuxuryTopBar
import com.bayt.elhadaya.ui.store.ProductDetailsScreen
import com.bayt.elhadaya.ui.store.StoreScreen
import com.bayt.elhadaya.ui.store.StoreProductDetails
import com.bayt.elhadaya.ui.store.StoreVariant
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
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.IOException
import java.security.GeneralSecurityException
import java.util.UUID

class MainActivity : ComponentActivity() {
    private lateinit var backendConfiguration: BackendConfiguration
    private var supabaseClient: SupabaseClient? = null
    private var authRepository: AuthRepository? = null
    private var catalogRepository: CatalogRepository? = null
    private var checkoutRepository: CheckoutRepository? = null

    private var storeState by mutableStateOf<StoreUiState>(StoreUiState.Loading)
    private var selectedNavigationItem by mutableStateOf("المتجر")
    private var selectedCategoryId by mutableStateOf<String?>(null)
    private var selectedProductId by mutableStateOf<String?>(null)
    private var productDetails by mutableStateOf<StoreProductDetails?>(null)
    private var productDetailsLoading by mutableStateOf(false)
    private var productDetailsError by mutableStateOf<String?>(null)
    private var cartLines by mutableStateOf<List<CartLine>>(emptyList())
    private var checkoutTerms by mutableStateOf<CheckoutTerms?>(null)
    private var shippingRegions by mutableStateOf<List<ShippingRegion>>(emptyList())
    private var selectedShippingRegionId by mutableStateOf<String?>(null)
    private var selectedPaymentMethod by mutableStateOf(PrepaidPaymentMethod.CARD)
    private var checkoutTermsAccepted by mutableStateOf(false)
    private var checkoutOptionsLoading by mutableStateOf(false)
    private var checkoutSubmitting by mutableStateOf(false)
    private var checkoutOptionsError by mutableStateOf<String?>(null)
    private var checkoutError by mutableStateOf<String?>(null)
    private var checkoutReceipt by mutableStateOf<CheckoutReceipt?>(null)
    private var checkoutIdempotencyKey: String? = null
    private var checkoutKeyTermsVersion: String? = null
    private var checkoutKeyTermsSha256: String? = null
    private var sessionInitializing by mutableStateOf(true)
    private var isAuthenticated by mutableStateOf(false)
    private var accountEmail by mutableStateOf<String?>(null)
    private var authBusy by mutableStateOf(false)
    private var authError by mutableStateOf<String?>(null)
    private var authMessage by mutableStateOf<String?>(null)
    private var pendingVerificationEmail by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        restoreCheckoutState(savedInstanceState)
        backendConfiguration = SupabaseBackend.configure(this)
        (backendConfiguration as? BackendConfiguration.Ready)?.let { backend ->
            supabaseClient = backend.client
            authRepository = AuthRepository(backend.client)
            catalogRepository = CatalogRepository(backend.client)
            checkoutRepository = CheckoutRepository(backend.client)
            handleDeepLink(backend.client, intent)
            observeSession(backend.client)
            loadCatalog()
            loadCheckoutOptions()
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
                } else if (selectedNavigationItem == "السلة") {
                    CartScreen(
                        items = cartLines,
                        regions = shippingRegions,
                        terms = checkoutTerms,
                        selectedRegionId = selectedShippingRegionId,
                        paymentMethod = selectedPaymentMethod,
                        termsAccepted = checkoutTermsAccepted,
                        isAuthenticated = isAuthenticated,
                        isLoadingOptions = checkoutOptionsLoading,
                        isSubmitting = checkoutSubmitting,
                        optionsError = checkoutOptionsError,
                        checkoutError = checkoutError,
                        receipt = checkoutReceipt,
                        selectedNavigationItem = selectedNavigationItem,
                        onQuantityChanged = ::updateCartQuantity,
                        onRegionSelected = ::selectShippingRegion,
                        onPaymentMethodSelected = ::selectPaymentMethod,
                        onTermsAccepted = { checkoutTermsAccepted = it },
                        onRetryOptions = ::loadCheckoutOptions,
                        onCheckout = ::submitCheckout,
                        onSignIn = { selectNavigationItem("حسابي") },
                        onNavigationItemSelected = ::selectNavigationItem,
                    )
                } else if (selectedProductId != null) {
                    ProductDetailsScreen(
                        details = productDetails,
                        loading = productDetailsLoading,
                        errorMessage = productDetailsError,
                        selectedNavigationItem = selectedNavigationItem,
                        onBack = { selectedProductId = null },
                        onRetry = { loadProductDetails(requireNotNull(selectedProductId)) },
                        onAddToCart = ::addToCart,
                        onNavigationItemSelected = ::selectNavigationItem,
                    )
                } else {
                    StoreScreen(
                        state = storeState,
                        selectedCategoryId = selectedCategoryId,
                        selectedNavigationItem = selectedNavigationItem,
                        onCategorySelected = { selectedCategoryId = it },
                        onProductSelected = { productId ->
                            selectedProductId = productId
                            loadProductDetails(productId)
                        },
                        onNavigationItemSelected = ::selectNavigationItem,
                        onRetry = ::loadCatalog,
                    )
                }
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(STATE_CART_LINES, Json.encodeToString(cartLines))
        outState.putString(STATE_CHECKOUT_IDEMPOTENCY_KEY, checkoutIdempotencyKey)
        outState.putString(STATE_CHECKOUT_TERMS_VERSION, checkoutKeyTermsVersion)
        outState.putString(STATE_CHECKOUT_TERMS_SHA256, checkoutKeyTermsSha256)
        outState.putString(STATE_SHIPPING_REGION_ID, selectedShippingRegionId)
        outState.putString(STATE_PAYMENT_METHOD, selectedPaymentMethod.apiValue)
        super.onSaveInstanceState(outState)
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
        if (item in setOf("المتجر", "حسابي", "السلة")) {
            selectedNavigationItem = item
            if (item != "المتجر") selectedProductId = null
        }
    }

    private fun loadProductDetails(productId: String) {
        val repository = catalogRepository
        if (repository == null) {
            productDetails = null
            productDetailsError = getString(R.string.store_load_error)
            productDetailsLoading = false
            return
        }
        lifecycleScope.launch {
            productDetailsLoading = true
            productDetailsError = null
            try {
                productDetails = repository.loadProductDetails(productId)
                if (productDetails == null) {
                    productDetailsError = getString(R.string.product_unavailable)
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: HttpRequestTimeoutException) {
                productDetailsError = getString(R.string.store_load_error)
            } catch (_: HttpRequestException) {
                productDetailsError = getString(R.string.store_load_error)
            } catch (_: RestException) {
                productDetailsError = getString(R.string.store_load_error)
            } catch (_: SerializationException) {
                productDetailsError = getString(R.string.store_load_error)
            } catch (_: IOException) {
                productDetailsError = getString(R.string.store_load_error)
            } finally {
                productDetailsLoading = false
            }
        }
    }

    private fun addToCart(details: StoreProductDetails, variant: StoreVariant) {
        val existing = cartLines.firstOrNull { it.variantId == variant.id }
        cartLines = if (existing == null) {
            cartLines + CartLine(
                variantId = variant.id,
                productId = details.id,
                productName = details.name,
                variantName = variant.name,
                weightGrams = variant.weightGrams,
                unitPriceMinor = variant.priceMinor,
                quantity = 1,
            )
        } else {
            cartLines.map {
                if (it.variantId == variant.id && it.quantity < Int.MAX_VALUE) {
                    it.copy(quantity = it.quantity + 1)
                } else {
                    it
                }
            }
        }
        checkoutReceipt = null
        checkoutError = null
        clearCheckoutIdempotencyKey()
        selectedNavigationItem = "السلة"
    }

    private fun updateCartQuantity(variantId: String, quantity: Int) {
        cartLines = cartLines.mapNotNull { line ->
            when {
                line.variantId != variantId -> line
                quantity <= 0 -> null
                else -> line.copy(quantity = quantity)
            }
        }
        checkoutError = null
        clearCheckoutIdempotencyKey()
    }

    private fun selectShippingRegion(regionId: String) {
        if (selectedShippingRegionId != regionId) {
            selectedShippingRegionId = regionId
            clearCheckoutIdempotencyKey()
            checkoutError = null
        }
    }

    private fun selectPaymentMethod(method: PrepaidPaymentMethod) {
        if (selectedPaymentMethod != method) {
            selectedPaymentMethod = method
            clearCheckoutIdempotencyKey()
            checkoutError = null
        }
    }

    private fun loadCheckoutOptions() {
        val repository = checkoutRepository
        if (repository == null) {
            checkoutOptionsError = getString(R.string.backend_config_missing)
            return
        }
        lifecycleScope.launch {
            checkoutOptionsLoading = true
            checkoutOptionsError = null
            try {
                val latestTerms = repository.loadTerms()
                if (checkoutTerms?.sha256 != latestTerms.sha256) {
                    checkoutTermsAccepted = false
                }
                if (checkoutIdempotencyKey != null &&
                    (checkoutKeyTermsVersion != latestTerms.version ||
                        checkoutKeyTermsSha256 != latestTerms.sha256)
                ) {
                    clearCheckoutIdempotencyKey()
                }
                checkoutTerms = latestTerms
                shippingRegions = repository.loadShippingRegions()
                if (shippingRegions.none { it.id == selectedShippingRegionId }) {
                    selectedShippingRegionId = shippingRegions.firstOrNull()?.id
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: HttpRequestTimeoutException) {
                checkoutOptionsError = getString(R.string.checkout_options_error)
            } catch (_: HttpRequestException) {
                checkoutOptionsError = getString(R.string.checkout_options_error)
            } catch (_: RestException) {
                checkoutOptionsError = getString(R.string.checkout_options_error)
            } catch (_: SerializationException) {
                checkoutOptionsError = getString(R.string.checkout_options_error)
            } catch (_: IOException) {
                checkoutOptionsError = getString(R.string.checkout_options_error)
            } finally {
                checkoutOptionsLoading = false
            }
        }
    }

    private fun submitCheckout() {
        if (!isAuthenticated) {
            checkoutError = getString(R.string.checkout_sign_in_required)
            selectNavigationItem("حسابي")
            return
        }
        val repository = checkoutRepository ?: run {
            checkoutError = getString(R.string.backend_config_missing)
            return
        }
        val terms = checkoutTerms ?: return
        val regionId = selectedShippingRegionId ?: return
        if (cartLines.isEmpty() || !checkoutTermsAccepted || checkoutSubmitting) return

        val idempotencyKey = checkoutIdempotencyKey ?: UUID.randomUUID().toString().also {
            checkoutIdempotencyKey = it
            checkoutKeyTermsVersion = terms.version
            checkoutKeyTermsSha256 = terms.sha256
        }
        val submittedItems = cartLines.toList()
        val submittedPaymentMethod = selectedPaymentMethod
        lifecycleScope.launch {
            checkoutSubmitting = true
            checkoutError = null
            try {
                checkoutReceipt = repository.createOrder(
                    items = submittedItems,
                    idempotencyKey = idempotencyKey,
                    paymentMethod = submittedPaymentMethod,
                    shippingRegionId = regionId,
                    terms = terms,
                )
                cartLines = emptyList()
                clearCheckoutIdempotencyKey()
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: HttpRequestTimeoutException) {
                checkoutError = getString(R.string.checkout_submit_error)
            } catch (_: HttpRequestException) {
                checkoutError = getString(R.string.checkout_submit_error)
            } catch (_: RestException) {
                checkoutError = getString(R.string.checkout_submit_error)
                loadCheckoutOptions()
            } catch (_: SerializationException) {
                checkoutError = getString(R.string.checkout_submit_error)
            } catch (_: IOException) {
                checkoutError = getString(R.string.checkout_submit_error)
            } finally {
                checkoutSubmitting = false
            }
        }
    }

    private fun restoreCheckoutState(savedInstanceState: Bundle?) {
        if (savedInstanceState == null) return

        savedInstanceState.getString(STATE_CART_LINES)?.let { serializedCart ->
            try {
                cartLines = Json.decodeFromString(serializedCart)
            } catch (_: SerializationException) {
                checkoutError = getString(R.string.cart_restore_error)
                cartLines = emptyList()
            } catch (_: IllegalArgumentException) {
                checkoutError = getString(R.string.cart_restore_error)
                cartLines = emptyList()
            }
        }

        selectedShippingRegionId = savedInstanceState.getString(STATE_SHIPPING_REGION_ID)
        savedInstanceState.getString(STATE_PAYMENT_METHOD)?.let { savedMethod ->
            selectedPaymentMethod = PrepaidPaymentMethod.values()
                .firstOrNull { it.apiValue == savedMethod }
                ?: PrepaidPaymentMethod.CARD
        }
        val savedKey = savedInstanceState.getString(STATE_CHECKOUT_IDEMPOTENCY_KEY)
        if (savedKey != null) {
            try {
                checkoutIdempotencyKey = UUID.fromString(savedKey).toString()
                checkoutKeyTermsVersion =
                    savedInstanceState.getString(STATE_CHECKOUT_TERMS_VERSION)
                checkoutKeyTermsSha256 =
                    savedInstanceState.getString(STATE_CHECKOUT_TERMS_SHA256)
            } catch (_: IllegalArgumentException) {
                checkoutError = getString(R.string.cart_restore_error)
            }
        }
    }

    private fun clearCheckoutIdempotencyKey() {
        checkoutIdempotencyKey = null
        checkoutKeyTermsVersion = null
        checkoutKeyTermsSha256 = null
    }

    private fun requireAuthRepository(): AuthRepository =
        checkNotNull(authRepository) { "Supabase Auth is not configured." }

    private fun configurationMessage(): String = when (backendConfiguration) {
        BackendConfiguration.Missing -> getString(R.string.backend_config_missing)
        BackendConfiguration.Invalid -> getString(R.string.backend_config_invalid)
        is BackendConfiguration.Ready -> getString(R.string.store_load_error)
    }

    private companion object {
        const val STATE_CART_LINES = "checkout.cart_lines"
        const val STATE_CHECKOUT_IDEMPOTENCY_KEY = "checkout.idempotency_key"
        const val STATE_CHECKOUT_TERMS_VERSION = "checkout.terms_version"
        const val STATE_CHECKOUT_TERMS_SHA256 = "checkout.terms_sha256"
        const val STATE_SHIPPING_REGION_ID = "checkout.shipping_region_id"
        const val STATE_PAYMENT_METHOD = "checkout.payment_method"
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
