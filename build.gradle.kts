// limn-angle-natives: the OpenGL ES 3.0 implementation the Limn toolkit falls back to on a machine
// whose own OpenGL gives it no context (its ADR 003), and nothing else.
//
// NOTHING HERE IS BUILT BY GRADLE'S COMPILERS. The libraries come from scripts/build-angle.sh
// (macOS) and scripts/build-angle.ps1 (Windows), which is how a release builds them on its runners
// (.github/workflows/natives.yml) and how a developer builds them locally. What this file does is
// PACKAGE, and test what was built:
//
//   the main jar          ANGLE's licence. The one jar the toolkit's backend names; it carries no
//                         code and no native.
//   natives-<os>-<arch>   one classifier jar per target: that platform's libEGL and libGLESv2,
//                         the inventory of every source compiled into them with each licence
//                         (THIRD_PARTY.txt), and how they were built (BUILD-INFO.txt).
//                         Windows and macOS only: Linux has Mesa, and ANGLE is no fallback there.
//
// The loader in the toolkit resolves limn/angle/native/<os>-<arch>/ as a CLASSPATH resource, and a
// classpath spans jars, so which jar holds which file is invisible to it.
//
// NO native is committed, and none ever will be. .gitignore excludes the whole native/ tree.

import java.util.Properties

plugins {
    `java-library`
    alias(libs.plugins.central.publish)
}

group = "io.github.limn-toolkit"

// The version, from -PlimnNativesVersion (the publish workflow passes it, taken from the tag) and
// otherwise the -SNAPSHOT of versions.properties. Its first three components must be 2.1 and the
// Chromium branch angle.pin takes ANGLE from: a version that names one ANGLE over another's payload
// is a lie the build can catch, so it does.
val declaredVersion = Properties().apply {
    file("versions.properties").inputStream().use { load(it) }
}.getProperty("limn-angle-natives") ?: throw GradleException("versions.properties names no version")
version = (findProperty("limnNativesVersion") as String?) ?: "$declaredVersion-SNAPSHOT"

val pinnedBranch = Properties().apply {
    file("angle.pin").inputStream().use { load(it) }
}.getProperty("ANGLE_BRANCH") ?: throw GradleException("angle.pin names no ANGLE_BRANCH")
if (!version.toString().startsWith("2.1.$pinnedBranch.")) {
    throw GradleException(
        "version $version does not name the ANGLE it carries: angle.pin takes it from " +
                "chromium/$pinnedBranch, so the version must be 2.1.$pinnedBranch.<n> (see versions.properties)"
    )
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
    withSourcesJar()
}

// A jar of native libraries runs on any Java, and this is what says so where consumers listen:
// without it the published module metadata takes its minimum JVM from the toolchain above and
// refuses every consumer building for an older Java.
tasks.named<JavaCompile>("compileJava") {
    options.release.set(8)
}
// The tests are this repository's own and run on the build's JDK; JUnit asks for 17.
tasks.named<JavaCompile>("compileTestJava") {
    options.release.set(17)
}

val angleNatives = file("native/dist")

sourceSets {
    named("main") {
        // Absent on a machine that never ran a build script, which Gradle accepts.
        resources.srcDir(angleNatives)
    }
}

/**
 * The targets a published payload must cover, written out rather than discovered: a check that
 * trusts what it finds calls an empty directory complete.
 */
val requiredNativePlatforms = listOf(
    "macos-aarch64", "macos-x86_64",
    "windows-aarch64", "windows-x86_64",
)

val licences = listOf("LICENSE-angle.txt")

// The main jar: the licence, nothing else.
tasks.named<ProcessResources>("processResources") {
    exclude {
        it.path.startsWith("limn/angle/native/") && !it.isDirectory && it.name !in licences
    }
    doFirst {
        if (!angleNatives.isDirectory) {
            logger.lifecycle("limn-angle-natives: no payload built (run scripts/build-angle.sh or .ps1); the jars will be empty")
        }
    }
}

/** One jar per platform: that platform's two libraries, their inventory and the licence. */
val nativeJars = requiredNativePlatforms.map { platform ->
    val suffix = platform.split("-").joinToString("") { part -> part.replaceFirstChar(Char::uppercase) }
    tasks.register<Jar>("nativesJar$suffix") {
        description = "ANGLE for $platform, published as natives-$platform."
        group = "build"
        archiveClassifier.set("natives-$platform")
        // A module name of its own: two jars deriving the same one from their file names stop the
        // JVM at startup on the module path ("Two versions of module").
        manifest { attributes("Automatic-Module-Name" to "limn.angle.natives." + platform.replace('-', '.')) }
        from(angleNatives) {
            include("limn/angle/native/$platform/**")
        }
        from(angleNatives) {
            licences.forEach { include("limn/angle/native/$it") }
        }
    }
}

tasks.named("assemble") {
    dependsOn(nativeJars)
}

// The main jar's module name, which the toolkit's backend module requires. "native" is a keyword,
// so no jar here has a package and two of them never collide on one.
tasks.named<Jar>("jar") {
    manifest { attributes("Automatic-Module-Name" to "limn.angle.natives") }
}

val hostPlatform: String = run {
    val os = System.getProperty("os.name").lowercase()
    val arch = when (System.getProperty("os.arch")) {
        "aarch64", "arm64" -> "aarch64"
        else -> "x86_64"
    }
    when {
        os.contains("mac") -> "macos-$arch"
        os.contains("win") -> "windows-$arch"
        else -> "linux-$arch"
    }
}
val lwjglNatives = when (hostPlatform) {
    "macos-aarch64" -> "natives-macos-arm64"
    "macos-x86_64" -> "natives-macos"
    "windows-aarch64" -> "natives-windows-arm64"
    "windows-x86_64" -> "natives-windows"
    "linux-aarch64" -> "natives-linux-arm64"
    else -> "natives-linux"
}

dependencies {
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
    testImplementation(platform(libs.lwjgl.bom))
    listOf("lwjgl", "lwjgl-egl", "lwjgl-opengles").forEach { module ->
        testImplementation("org.lwjgl:$module")
    }
    // Classes only for EGL: it binds the library under test, which is the point.
    listOf("lwjgl", "lwjgl-opengles").forEach { module ->
        testRuntimeOnly("org.lwjgl:$module::$lwjglNatives")
    }
}

// The tests load what the build scripts staged for THIS machine, by path, and skip with a sentence
// when it was not built here: a checkout that never ran a script still builds and packages.
tasks.named<Test>("test") {
    useJUnitPlatform()
    systemProperty("limn.angle.dist", angleNatives.resolve("limn/angle/native/$hostPlatform").absolutePath)
    testLogging { events("passed", "failed", "skipped"); showStandardStreams = true; exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}

/** Which platforms the staged payload really carries: a directory with both libraries in it. */
fun carriedPlatforms(): Set<String> {
    val root = angleNatives.resolve("limn/angle/native")
    return (root.listFiles() ?: emptyArray())
        .filter { platform ->
            val names = (platform.listFiles() ?: emptyArray()).map { it.name }.toSet()
            platform.isDirectory && names.any { it.startsWith("libEGL.") } && names.any { it.startsWith("libGLESv2.") }
                    && "THIRD_PARTY.txt" in names
        }
        .map { it.name }
        .toSet()
}

// A release ships all four, and this turns the sentence into a rule.
tasks.withType<AbstractPublishToMaven>().configureEach {
    // The local file repository is where a partial payload is LOOKED AT; the guard is for anything
    // that leaves the machine.
    if (name.contains("BuildDir")) return@configureEach
    doFirst {
        val missing = requiredNativePlatforms.filterNot { carriedPlatforms().contains(it) }
        if (missing.isNotEmpty()) {
            throw GradleException(
                "refusing to publish limn-angle-natives without its whole payload: " +
                        "${missing.joinToString(", ")} " + (if (missing.size == 1) "is" else "are") +
                        " missing from ${angleNatives.relativeTo(rootDir)}. A release builds all four on its own " +
                        "runners (.github/workflows/natives.yml) and merges them in before this task runs."
            )
        }
    }
}

// The payload reaches the main source set through resources.srcDir above, which is what a sources
// jar copies as well: this jar answers "what was this compiled from", and the answer is the pinned
// ANGLE commit and the build scripts, so the binaries leave it and the scripts join it.
tasks.named<Jar>("sourcesJar") {
    exclude("limn/angle/native/**")
    from("scripts") { into("scripts") }
    from("patches") { into("patches") }
    from("angle.pin")
}

mavenPublishing {
    // Uploads and stops: the deployment sits staged on the Central Portal until somebody presses
    // Publish, which is the last moment a release can still be dropped.
    publishToMavenCentral()

    if (providers.gradleProperty("signingInMemoryKey").isPresent ||
            providers.gradleProperty("signing.keyId").isPresent) {
        signAllPublications()
    }

    pom {
        name.set("limn-angle-natives")
        description.set(
            "The OpenGL ES 3.0 fallback of the Limn toolkit: ANGLE (BSD-3-Clause) from Chromium " +
                    "branch $pinnedBranch, built with only its Direct3D 11 backend for Windows and its " +
                    "Metal backend for macOS, on x86_64 and aarch64, one natives-<os>-<arch> classifier " +
                    "each. Versions with ANGLE, not with the toolkit."
        )
        url.set("https://github.com/limn-toolkit/limn-angle-natives")
        scm {
            url.set("https://github.com/limn-toolkit/limn-angle-natives")
            connection.set("scm:git:https://github.com/limn-toolkit/limn-angle-natives.git")
            developerConnection.set("scm:git:ssh://git@github.com/limn-toolkit/limn-angle-natives.git")
        }
        licenses {
            license {
                name.set("BSD 3-Clause License")
                url.set("https://opensource.org/license/bsd-3-clause")
                comments.set("ANGLE; the third-party code compiled into each library, and its licence, " +
                        "is listed in THIRD_PARTY.txt in that platform's jar")
            }
            license {
                name.set("The Apache License, Version 2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                comments.set("this repository's build scripts")
            }
        }
        developers {
            developer {
                id.set("limn-toolkit")
                name.set("Limn Toolkit")
                email.set("limntoolkit@gmail.com")
                url.set("https://github.com/limn-toolkit")
            }
        }
    }
}

// The classifier jars join the one publication the plugin configured.
publishing {
    publications.withType<MavenPublication>().configureEach {
        nativeJars.forEach { artifact(it) }
    }
    // A plain file repository under build/repo, for looking at what would ship without sending it
    // anywhere, and for scripts/rehearse-consumer.sh to resolve from.
    repositories {
        maven {
            name = "buildDir"
            url = uri(layout.buildDirectory.dir("repo"))
        }
    }
}

// A release that Central would reject on validation (unsigned), caught before anything leaves.
gradle.taskGraph.whenReady {
    val releasing = allTasks.any {
        it.name == "publishToMavenCentral" || it.name == "publishAndReleaseToMavenCentral" ||
                it.name.startsWith("publishAllPublicationsToMavenCentral")
    }
    if (!releasing) return@whenReady
    if (project.version.toString().endsWith("-SNAPSHOT")) {
        logger.lifecycle("publishing ${project.version} to Central's SNAPSHOT repository. This is " +
                "not a release: bump versions.properties and push for one (see RELEASING.md).")
        return@whenReady
    }
    if (!providers.gradleProperty("signingInMemoryKey").isPresent &&
            !providers.gradleProperty("signing.keyId").isPresent) {
        throw GradleException(
            "refusing to publish ${project.version} to Maven Central unsigned: no signing key is " +
                    "configured, and Central requires a signature on every artifact of a release."
        )
    }
}
