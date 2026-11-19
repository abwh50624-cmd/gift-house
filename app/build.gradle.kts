plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

fun String.asJavaStringLiteral(): String =
    "\"" + replace("\\", "\\\\").replace("\"", "\\\"") + "\""

val productionSupabaseUrl = "https://wkhbxljqaywprplpadve.supabase.co"
val productionSupabasePublishableKey =
    "sb_publishable__p6sRxEQJEyix921A-QoWA_fl79wked"

val supabaseUrl = providers.gradleProperty("supabaseUrl")
    .orElse(providers.environmentVariable("SUPABASE_URL"))
    .getOrElse(productionSupabaseUrl)
val supabasePublishableKey = providers.gradleProperty("supabasePublishableKey")
    .orElse(providers.environmentVariable("SUPABASE_PUBLISHABLE_KEY"))
    .getOrElse(productionSupabasePublishableKey)
val r2PublicBaseUrl = providers.gradleProperty("r2PublicBaseUrl")
    .orElse(providers.environmentVariable("R2_PUBLIC_BASE_URL").orElse("https://wkhbxljqaymprplpadve.supabase.co/storage/v1/object/public/gift-house-media"))
    .get()

android {
    namespace = "com.bayt.elhadaya"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.bayt.elhadaya"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "SUPABASE_URL", supabaseUrl.asJavaStringLiteral())
        buildConfigField(
            "String",
            "SUPABASE_PUBLISHABLE_KEY",
            supabasePublishableKey.asJavaStringLiteral(),
        )
        buildConfigField("String", "R2_PUBLIC_BASE_URL", r2PublicBaseUrl.asJavaStringLiteral())
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }

}

dependencies {
    implementation(platform(libs.supabase.bom))
    implementation(libs.supabase.auth)
    implementation(libs.supabase.postgrest)
    implementation(libs.ktor.client.android)
    implementation(libs.coil.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)

    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)

    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.espresso.core)
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
