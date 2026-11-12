import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import java.util.zip.ZipFile
import javax.inject.Inject

plugins {
    id("com.android.library")
}

android {
    namespace = "com.follow.clash.service"
    compileSdk = libs.versions.compileSdk.get().toInt()

    defaultConfig {
        minSdk = libs.versions.minSdk.get().toInt()
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        // Unit tests live under android/tests/ instead of each module's src/test.
        getByName("test").java.setSrcDirs(listOf("../tests/service"))
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":core"))
    implementation(project(":common"))
    implementation(libs.gson)
    implementation(libs.androidx.core)
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}

/** Keep the second gomobile go.Seq and JNI bindings outside the host DEX. */
abstract class PackageSingBoxRuntime : DefaultTask() {
    @get:Inject abstract val execOperations: ExecOperations
    @get:InputFile @get:PathSensitive(PathSensitivity.NONE)
    abstract val aar: RegularFileProperty
    @get:InputDirectory @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val adapterSources: DirectoryProperty
    @get:InputFile @get:PathSensitive(PathSensitivity.NONE)
    abstract val androidJar: RegularFileProperty
    @get:InputFile @get:PathSensitive(PathSensitivity.NONE)
    abstract val d8Jar: RegularFileProperty
    @get:Input abstract val abis: ListProperty<String>
    @get:OutputDirectory abstract val assets: DirectoryProperty
    @get:OutputDirectory abstract val jni: DirectoryProperty

    @TaskAction
    fun pack() {
        val work = temporaryDir
        work.deleteRecursively()
        work.mkdirs()
        val libboxJar = work.resolve("libbox.jar")
        val classes = work.resolve("adapter").apply { mkdirs() }
        val dex = work.resolve("dex").apply { mkdirs() }
        val nativeDir = jni.get().asFile
        val assetDir = assets.get().asFile
        nativeDir.deleteRecursively()
        assetDir.deleteRecursively()
        ZipFile(aar.get().asFile).use { zip ->
            fun extract(name: String, target: File) {
                val entry = zip.getEntry(name) ?: error("Official libbox AAR is missing $name")
                target.parentFile.mkdirs()
                zip.getInputStream(entry).use { input -> target.outputStream().use { input.copyTo(it) } }
            }
            extract("classes.jar", libboxJar)
            abis.get().forEach { abi ->
                extract("jni/$abi/libbox.so", nativeDir.resolve("$abi/libbox.so"))
            }
        }
        val javaHome = File(System.getProperty("java.home"), "bin")
        val suffix = if (System.getProperty("os.name").startsWith("Windows")) ".exe" else ""
        val sources = adapterSources.get().asFile.walkTopDown().filter { it.isFile && it.extension == "java" }.toList()
        check(sources.isNotEmpty()) { "Missing sing-box Android adapter sources" }
        execOperations.exec {
            commandLine(
                listOf(javaHome.resolve("javac$suffix").path, "--release", "8",
                    "-cp", androidJar.get().asFile.path + File.pathSeparator + libboxJar.path,
                    "-d", classes.path) + sources.map { it.path },
            )
        }
        val adapterJar = work.resolve("adapter.jar")
        execOperations.exec {
            commandLine(javaHome.resolve("jar$suffix").path, "cf", adapterJar.path, "-C", classes.path, ".")
        }
        execOperations.exec {
            commandLine(
                javaHome.resolve("java$suffix").path, "-cp", d8Jar.get().asFile.path,
                "com.android.tools.r8.D8", "--min-api", "29", "--lib", androidJar.get().asFile.path,
                "--output", dex.path, libboxJar.path, adapterJar.path,
            )
        }
        val dexFiles = dex.listFiles().orEmpty().filter { it.extension == "dex" }
        check(dexFiles.size == 1 && dexFiles.single().name == "classes.dex") {
            "Expected a single isolated libbox DEX"
        }
        val target = assetDir.resolve("singbox/libbox.dex")
        target.parentFile.mkdirs()
        dexFiles.single().copyTo(target, overwrite = true)
    }
}

val singBoxAar = providers.gradleProperty("flclashSingBoxAar")
if (singBoxAar.isPresent) {
    val abiByPlatform = mapOf(
        "android-arm" to "armeabi-v7a",
        "android-arm64" to "arm64-v8a",
        "android-x64" to "x86_64",
    )
    val selectedAbis = (rootProject.findProperty("target-platform") as String?)
        ?.split(",")?.map { abiByPlatform[it.trim()] ?: error("Unsupported Android target $it") }
        ?: abiByPlatform.values.toList()
    val sdk = androidComponents.sdkComponents.sdkDirectory
    val compileApi = libs.versions.compileSdk.get()
    val buildTools = android.buildToolsVersion
    val packageRuntime = tasks.register<PackageSingBoxRuntime>("packageSingBoxRuntime") {
        aar.set(rootProject.layout.file(singBoxAar.map { rootProject.file(it) }))
        adapterSources.set(rootProject.layout.projectDirectory.dir(
            "../tool/android-singbox/isolation/libbox-src",
        ))
        androidJar.set(sdk.map { it.file("platforms/android-$compileApi/android.jar") })
        d8Jar.set(sdk.map { it.file("build-tools/$buildTools/lib/d8.jar") })
        abis.set(selectedAbis)
        assets.set(layout.buildDirectory.dir("singbox/assets"))
        jni.set(layout.buildDirectory.dir("singbox/jni"))
    }
    androidComponents.onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(packageRuntime, PackageSingBoxRuntime::assets)
        variant.sources.jniLibs?.addGeneratedSourceDirectory(packageRuntime, PackageSingBoxRuntime::jni)
    }
}
