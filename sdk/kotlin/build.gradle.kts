import com.vanniktech.maven.publish.SonatypeHost

plugins {
    id("com.android.application") version "9.3.0" apply false
    id("com.android.library") version "9.3.0"
    id("org.jlleitschuh.gradle.ktlint") version "12.1.1"
    id("com.vanniktech.maven.publish") version "0.30.0"
}

android {
    namespace = "com.gosslens"
    compileSdk = 37

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

// Publishes the AAR - the prebuilt .so already inside - to Maven Central through
// the Sonatype Central Portal, so an Android app adds one coordinate and never
// runs Zig or the NDK. Coordinates and POM come from gradle.properties; the token
// and signing key come from the release job. JitPack builds it from a tag instead.
mavenPublishing {
    publishToMavenCentral(SonatypeHost.CENTRAL_PORTAL)
    signAllPublications()
    coordinates("io.github.avosa", "gosslens", project.property("VERSION_NAME").toString())
}
