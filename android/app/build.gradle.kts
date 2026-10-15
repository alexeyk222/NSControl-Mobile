plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.nscontrol.nscontrol"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.nscontrol.nscontrol"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Flutter selects its engine ABI, while SDK AARs may still bundle other ABIs.
    // Filter at packaging time so APK metadata never advertises an ABI lacking libapp.
    val targetAbis = providers.gradleProperty("target-platform").orNull
        ?.split(",")?.mapNotNull {
            when (it.trim()) {
                "android-arm" -> "armeabi-v7a"
                "android-arm64" -> "arm64-v8a"
                "android-x64" -> "x86_64"
                else -> null
            }
        }
    if (!targetAbis.isNullOrEmpty()) {
        packaging {
            jniLibs {
                listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
                    .filterNot { it in targetAbis }
                    .forEach { excludes.add("lib/$it/**") }
            }
        }
    }

    buildTypes {
        release {
            // Local bench-test release uses a development key; distribution requires
            // an owner's release signing configuration kept outside the repository.
            signingConfig = signingConfigs.getByName("debug")
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

dependencies {
    implementation("androidx.health.connect:connect-client:1.1.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("com.garmin.connectiq:ciq-companion-app-sdk:2.2.0@aar")
}
