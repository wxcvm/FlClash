import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.Properties
import java.security.MessageDigest
import java.util.zip.ZipFile
import javax.inject.Inject

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties().apply {
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use { load(it) }
    }
}

val releaseStoreFile = file("keystore.jks")
val releaseStorePassword = localProperties.getProperty("storePassword")
val releaseKeyAlias = localProperties.getProperty("keyAlias")
val releaseKeyPassword = localProperties.getProperty("keyPassword")
val requireReleaseSigning = System.getenv("FLCLASH_REQUIRE_RELEASE_SIGNING") == "true"
val hasReleaseSigning = releaseStoreFile.exists() &&
    releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null

check(!requireReleaseSigning || hasReleaseSigning) {
    "Published Android builds require the configured release signing key"
}

android {
    namespace = "com.follow.clash"
    compileSdk = libs.versions.compileSdk.get().toInt()
    ndkVersion = libs.versions.ndkVersion.get()

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.follow.clash"
        minSdk = flutter.minSdkVersion
        targetSdk = libs.versions.targetSdk.get().toInt()
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            applicationIdSuffix = ".dev"
        }

        release {
            isMinifyEnabled = true
            isShrinkResources = true
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
            if (!hasReleaseSigning) {
                applicationIdSuffix = ".dev"
            }

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    sourceSets {
        // Unit tests live under android/tests/ instead of each module's src/test.
        getByName("test").java.setSrcDirs(listOf("../tests/app"))
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(project(":service"))
    implementation(project(":common"))
    implementation(project(":core"))
    implementation(libs.core.splashscreen)
    implementation(libs.gson)
    implementation(libs.smali.dexlib2) {
        exclude(group = "com.google.guava", module = "guava")
    }
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}


// Keep libbox out of the ordinary app classpath: its gomobile go.Seq is
// incompatible with the embedded Mihomo bridge. This opt-in payload is ARM64 only.
abstract class PrepareSingBoxPayload : DefaultTask() {
    @get:Inject
    abstract val execOperations: ExecOperations

    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val libboxAar: RegularFileProperty

    @get:Input
    abstract val expectedSha256: Property<String>

    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val adapterSources: ConfigurableFileCollection

    @get:Internal
    abstract val sdkDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val assetsDirectory: DirectoryProperty

    @get:OutputDirectory
    abstract val jniDirectory: DirectoryProperty

    @TaskAction
    fun prepare() {
        val input = libboxAar.get().asFile
        val digest = MessageDigest.getInstance("SHA-256")
        input.inputStream().use { stream ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        check(actual.equals(expectedSha256.get(), ignoreCase = true)) { "libbox AAR SHA-256 mismatch" }

        val work = temporaryDir
        val classes = work.resolve("classes").apply { deleteRecursively(); mkdirs() }
        val dex = work.resolve("dex").apply { deleteRecursively(); mkdirs() }
        val jar = work.resolve("libbox.jar")
        val assets = assetsDirectory.get().asFile.apply { deleteRecursively(); mkdirs() }
        val jni = jniDirectory.get().asFile.apply { deleteRecursively(); mkdirs() }
        val native = jni.resolve("arm64-v8a/libbox.so").apply { parentFile.mkdirs() }
        ZipFile(input).use { zip ->
            fun extract(name: String, destination: File) {
                val entry = zip.getEntry(name) ?: error("Missing libbox AAR entry: $name")
                zip.getInputStream(entry).use { source ->
                    destination.outputStream().use { source.copyTo(it) }
                }
                check(destination.length() > 0) { "Empty libbox entry: $name" }
            }
            extract("classes.jar", jar)
            extract("jni/arm64-v8a/libbox.so", native)
        }
        val sdk = sdkDirectory.get().asFile
        val platform = sdk.resolve("platforms/android-35/android.jar")
        val d8 = sdk.resolve("build-tools/35.0.0/lib/d8.jar")
        check(platform.isFile && d8.isFile) {
            "Install Android SDK platform 35 and build-tools 35.0.0 for the optional libbox payload"
        }
        val javaHome = File(System.getProperty("java.home"), "bin")
        val suffix = if (System.getProperty("os.name").startsWith("Windows")) ".exe" else ""
        execOperations.exec {
            commandLine(
                javaHome.resolve("javac$suffix"),
                "--release", "8", "-cp", "${platform.path}${File.pathSeparator}${jar.path}",
                "-d", classes.path,
            )
            args(adapterSources.files.sortedBy { it.path }.map { it.path })
        }
        execOperations.exec {
            commandLine(
                javaHome.resolve("java$suffix"), "-cp", d8.path, "com.android.tools.r8.D8",
                "--min-api", "29", "--lib", platform.path, "--output", dex.path, jar.path,
            )
            args(classes.walkTopDown().filter { it.isFile && it.extension == "class" }.map { it.path }.toList())
        }
        val outputs = dex.listFiles().orEmpty().filter { it.extension == "dex" }
        check(outputs.size == 1 && outputs.single().name == "classes.dex") {
            "Expected one isolated libbox DEX"
        }
        outputs.single().copyTo(assets.resolve("libbox.dex"), overwrite = true)
    }
}

val singBoxAar = providers.gradleProperty("flclashSingBoxAar")
if (singBoxAar.isPresent) {
    val target = providers.gradleProperty("target-platform").orNull
    check(target == "android-arm64") { "The optional libbox payload requires -Ptarget-platform=android-arm64" }
    val sha = providers.gradleProperty("flclashSingBoxSha256").orNull
    check(sha != null && sha.matches(Regex("[0-9a-fA-F]{64}"))) {
        "Set -PflclashSingBoxSha256 to the verified official AAR digest"
    }
    androidComponents {
        onVariants { variant ->
            val payload = tasks.register<PrepareSingBoxPayload>(
                "prepare${variant.name.replaceFirstChar { it.uppercase() }}SingBoxPayload",
            ) {
                libboxAar.fileValue(rootProject.file(singBoxAar.get()))
                expectedSha256.set(sha)
                adapterSources.from(
                    fileTree(rootProject.file("../tool/android-singbox/isolation/libbox-src")) {
                        include("**/*.java")
                    },
                )
                sdkDirectory.set(androidComponents.sdkComponents.sdkDirectory)
                assetsDirectory.set(layout.buildDirectory.dir("singbox/${variant.name}/assets"))
                jniDirectory.set(layout.buildDirectory.dir("singbox/${variant.name}/jniLibs"))
            }
            variant.sources.assets?.addGeneratedSourceDirectory(payload, PrepareSingBoxPayload::assetsDirectory)
            variant.sources.jniLibs?.addGeneratedSourceDirectory(payload, PrepareSingBoxPayload::jniDirectory)
        }
    }
}
