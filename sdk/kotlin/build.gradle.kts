import com.vanniktech.maven.publish.SonatypeHost

plugins {
    id("com.android.application") version "9.3.0" apply false
    id("com.android.library") version "9.3.0"
    id("org.jlleitschuh.gradle.ktlint") version "12.1.1"
    id("com.vanniktech.maven.publish") version "0.30.0"
}

android {
    namespace = "com.gosslens"
    // The platform the current Android Gradle plugin line compiles against; the AAR's compile floor
    // follows it, so an app on that line takes the package. The library itself needs Android 10: the
    // engine is built against API 29, and an app with a lower floor keeps it off below that.
    compileSdk = 36

    defaultConfig {
        minSdk = 29
    }

    sourceSets {
        getByName("main") {
            // The .so comes from zig build android; gradle only packages it.
            jniLibs.srcDir("../../zig-out/android")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
}

// ARCore is compile-only: GossARCoreWorldSource reads its frames, and an app that wears a world
// lens adds the runtime itself, so one that never does carries none of it.
dependencies {
    compileOnly("com.google.ar:core:1.56.0")
    // The unit suite runs on the jvm and never loads the .so, so the values the
    // C ABI freezes and the helpers that pack them fail on a laptop rather than
    // on a device.
    testImplementation("junit:junit:4.13.2")
}

// Publishes the AAR - the prebuilt .so already inside - to Maven Central through
// the Sonatype Central Portal, so an Android app adds one coordinate and never
// runs Zig or the NDK. Coordinates and POM come from gradle.properties; the token
// and signing key come from the release job. JitPack builds it from a tag instead.
mavenPublishing {
    publishToMavenCentral(SonatypeHost.CENTRAL_PORTAL)
    // Central requires signatures, and the release job supplies the key. A
    // source build without one (JitPack, a fork) publishes unsigned instead
    // of failing on the .asc artifacts the publication would otherwise name.
    if (project.findProperty("signingInMemoryKey") != null) {
        signAllPublications()
    }
    coordinates("io.github.avosa", "gosslens", project.property("VERSION_NAME").toString())
}
