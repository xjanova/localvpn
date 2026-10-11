import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing secrets come from env vars (CI) or the gitignored android/key.properties (local).
// No hardcoded fallback: this repo is public and anything committed stays in history.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

// An unset GitHub Actions secret expands to "", so blank counts as missing.
fun releaseSigningValue(envName: String, propertyName: String): String? =
    System.getenv(envName)?.takeIf { it.isNotBlank() }
        ?: keystoreProperties.getProperty(propertyName)?.takeIf { it.isNotBlank() }

val releaseKeystoreFile = file("keystore/release.keystore")
val releaseStorePassword = releaseSigningValue("KEYSTORE_PASSWORD", "storePassword")
val releaseKeyPassword = releaseSigningValue("KEY_PASSWORD", "keyPassword")
val missingReleaseSigning = listOfNotNull(
    "KEYSTORE_PASSWORD (env var) or storePassword (android/key.properties)"
        .takeIf { releaseStorePassword == null },
    "KEY_PASSWORD (env var) or keyPassword (android/key.properties)"
        .takeIf { releaseKeyPassword == null },
    "non-empty keystore file at ${releaseKeystoreFile.path}"
        .takeIf { !releaseKeystoreFile.isFile || releaseKeystoreFile.length() == 0L },
)

android {
    namespace = "com.xjanova.localvpn"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        create("release") {
            storeFile = releaseKeystoreFile
            storePassword = releaseStorePassword
            keyAlias = "localvpn-release"
            keyPassword = releaseKeyPassword
        }
    }

    defaultConfig {
        applicationId = "com.xjanova.localvpn"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

// Fail release builds up front with a clear message; debug and profile builds never need the release key.
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    val missing = missingReleaseSigning
    doFirst {
        if (missing.isNotEmpty()) {
            throw GradleException(
                "Release signing is not configured. Missing:\n" +
                    missing.joinToString("\n") { "  - $it" } +
                    "\nSet the env vars, or create android/key.properties (gitignored) containing:\n" +
                    "  storePassword=...\n  keyPassword=..."
            )
        }
    }
}

flutter {
    source = "../.."
}
