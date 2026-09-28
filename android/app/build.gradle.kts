import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
if (signingPropertiesFile.exists()) {
    signingPropertiesFile.inputStream().use { stream -> signingProperties.load(stream) }
}
fun decodedSigningProperty(name: String): String? {
    val encoded = signingProperties.getProperty(name) ?: return null
    return try {
        String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
    } catch (error: IllegalArgumentException) {
        throw GradleException("Release signing property $name is not valid base64.", error)
    }
}

android {
    namespace = "com.example.notes"
    compileSdk = maxOf(flutter.compileSdkVersion, 37)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.notes"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val configuredStoreFile = signingProperties.getProperty("storeFile")
            if (!configuredStoreFile.isNullOrBlank()) {
                storeFile = file(configuredStoreFile)
                storePassword = decodedSigningProperty("storePasswordBase64")
                keyAlias = decodedSigningProperty("keyAliasBase64")
                keyPassword = decodedSigningProperty("keyPasswordBase64")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

tasks.matching { it.name.contains("Release") && (it.name.startsWith("sign") || it.name.startsWith("package")) }.configureEach {
    doFirst {
        val requiredProperties = listOf("storeFile", "storePasswordBase64", "keyAliasBase64", "keyPasswordBase64")
        val missingProperties = requiredProperties.filter { signingProperties.getProperty(it).isNullOrBlank() }
        if (!signingPropertiesFile.exists() || missingProperties.isNotEmpty()) {
            throw GradleException(
                "Release signing is not configured. Add android/key.properties with storeFile and base64-encoded storePasswordBase64, keyAliasBase64, and keyPasswordBase64. Debug builds do not require release keys."
            )
        }
        val configuredStoreFile = file(signingProperties.getProperty("storeFile"))
        if (!configuredStoreFile.isFile) {
            throw GradleException("Release signing keystore was not found at android/app/${signingProperties.getProperty("storeFile")}. Check android/key.properties.")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
