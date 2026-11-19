import org.gradle.api.attributes.Attribute
import org.w3c.dom.Element
import javax.xml.parsers.DocumentBuilderFactory

// The aOS companion for Windows and Linux (it runs on macOS too, for development and screenshots): Compose
// Multiplatform on the JVM. The model, SSH and the connection come from :shared, the UI from ../shared-ui (compiled in
// here as it is into :app), the strings from shared-ui's Android XML (a generated `dev.marquart.aos.R` and string
// tables, see generateAosResources below). Packages: Tools/desktop.sh (zip for Windows, tar.gz and .deb for Linux).
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.compose.multiplatform)
}

kotlin {
    jvmToolchain(17)
}

val appVersion = "0.1.0"

// The Go library for the desktop (libsharing + tailnetkit, built by Tools/go-desktop.sh into third_party/aosgo-desktop):
// its JNA binding is compiled in when it is there; without it the app builds the same, without a screen session engine
// and without aOS's own Tailscale (src/noaosgo instead of src/aosgo). -Paos.withoutGo=true builds as if it were missing.
val aosgoBinding: File = rootProject.file("third_party/aosgo-desktop/kotlin/AosGo.kt")
val hasAosgo = aosgoBinding.isFile && providers.gradleProperty("aos.withoutGo").orNull != "true"

val aosKotlinOut: File = layout.buildDirectory.dir("generated/aos/kotlin").get().asFile
val aosResourcesOut: File = layout.buildDirectory.dir("generated/aos/resources").get().asFile

kotlin.sourceSets.named("main") {
    kotlin.srcDir("../shared-ui/src/main/kotlin")
    kotlin.srcDir(aosKotlinOut)
    if (hasAosgo) {
        kotlin.srcDir("../third_party/aosgo-desktop/kotlin")
        kotlin.srcDir("src/aosgo/kotlin")
    } else {
        kotlin.srcDir("src/noaosgo/kotlin")
    }
}
kotlin.sourceSets.named("test") { kotlin.srcDir("../shared-ui/src/test/kotlin") }
sourceSets.named("main") { resources.srcDir(aosResourcesOut) }

// Android's string resources for the desktop: shared-ui/src/main/res (the UI's strings, English and German) and
// desktop/src/main/res (strings only the desktop has, and the desktop's wording where Android's says "phone": the
// later folder wins). Writes `dev.marquart.aos.R` (ids: string, plurals, drawable, raw) and the tables
// aos/strings/<language>.tsv the app reads (DesktopStrings), plus the drawables and raw files R names.
val generateAosResources = tasks.register("generateAosResources") {
    val resDirs = listOf(rootProject.file("shared-ui/src/main/res"), file("src/main/res"))
    resDirs.forEach { inputs.dir(it) }
    inputs.property("version", appVersion)
    outputs.dir(aosKotlinOut)
    outputs.dir(aosResourcesOut)
    doLast {
        fun unescape(raw: String): String {
            var text = raw
            val quoted = text.length >= 2 && text.startsWith("\"") && text.endsWith("\"")
            text = if (quoted) text.substring(1, text.length - 1) else text.replace(Regex("\\s+"), " ").trim()
            val out = StringBuilder()
            var i = 0
            while (i < text.length) {
                val c = text[i]
                if (c == '\\' && i + 1 < text.length) {
                    val n = text[i + 1]
                    when (n) {
                        'n' -> out.append('\n')
                        't' -> out.append('\t')
                        'u' -> { out.append(text.substring(i + 2, i + 6).toInt(16).toChar()); i += 4 }
                        else -> out.append(n)
                    }
                    i += 2
                } else {
                    if (c != '"') out.append(c)
                    i++
                }
            }
            return out.toString()
        }
        // language ("" = default) -> name -> value; plurals as "quantity=value" entries.
        val strings = sortedMapOf<String, MutableMap<String, String>>()
        val plurals = sortedMapOf<String, MutableMap<String, Map<String, String>>>()
        val stringNames = sortedSetOf<String>()
        val pluralNames = sortedSetOf<String>()
        val factory = DocumentBuilderFactory.newInstance()
        for (dir in resDirs) {
            dir.listFiles { f -> f.isDirectory && (f.name == "values" || f.name.startsWith("values-")) }?.sortedBy { it.name }?.forEach { values ->
                val language = values.name.removePrefix("values").removePrefix("-")
                values.listFiles { f -> f.name.endsWith(".xml") }?.sortedBy { it.name }?.forEach { xml ->
                    val doc = factory.newDocumentBuilder().parse(xml)
                    val stringNodes = doc.getElementsByTagName("string")
                    for (k in 0 until stringNodes.length) {
                        val e = stringNodes.item(k) as Element
                        val name = e.getAttribute("name")
                        stringNames += name
                        strings.getOrPut(language) { mutableMapOf() }[name] = unescape(e.textContent)
                    }
                    val pluralNodes = doc.getElementsByTagName("plurals")
                    for (k in 0 until pluralNodes.length) {
                        val e = pluralNodes.item(k) as Element
                        val name = e.getAttribute("name")
                        pluralNames += name
                        val items = e.getElementsByTagName("item")
                        val map = (0 until items.length).associate { j ->
                            val item = items.item(j) as Element
                            item.getAttribute("quantity") to unescape(item.textContent)
                        }
                        plurals.getOrPut(language) { mutableMapOf() }[name] = map
                    }
                }
            }
        }
        val drawables = rootProject.file("shared-ui/src/main/res/drawable-nodpi").listFiles()!!.filter { it.extension == "png" }.sortedBy { it.name }
        val raws = rootProject.file("shared-ui/src/main/res/raw").listFiles()!!.sortedBy { it.name }

        val kotlinOut = aosKotlinOut.resolve("dev/marquart/aos")
        kotlinOut.mkdirs()
        val r = StringBuilder()
        r.append("// Generated by :desktop:generateAosResources from the Android string resources. Do not edit.\n")
        r.append("package dev.marquart.aos\n\n@Suppress(\"ClassName\", \"unused\")\nobject R {\n")
        fun block(kind: String, names: List<String>, base: Int) {
            r.append("    object $kind {\n")
            names.forEachIndexed { i, n -> r.append("        const val $n = ${base + i}\n") }
            r.append("    }\n")
        }
        block("string", stringNames.toList(), 0x7f010000)
        block("plurals", pluralNames.toList(), 0x7f020000)
        block("drawable", drawables.map { it.nameWithoutExtension }, 0x7f030000)
        block("raw", raws.map { it.nameWithoutExtension }, 0x7f040000)
        r.append("    /** Resource names by id (DesktopStrings looks them up in the tables). */\n")
        r.append("    val names: Map<Int, String> = buildMap {\n")
        stringNames.forEachIndexed { i, n -> r.append("        put(${0x7f010000 + i}, \"$n\")\n") }
        pluralNames.forEachIndexed { i, n -> r.append("        put(${0x7f020000 + i}, \"$n\")\n") }
        drawables.forEachIndexed { i, f -> r.append("        put(${0x7f030000 + i}, \"drawable/${f.name}\")\n") }
        raws.forEachIndexed { i, f -> r.append("        put(${0x7f040000 + i}, \"raw/${f.name}\")\n") }
        r.append("    }\n}\n")
        kotlinOut.resolve("R.kt").writeText(r.toString())
        kotlinOut.resolve("desktop").mkdirs()
        kotlinOut.resolve("desktop/BuildInfo.kt").writeText("// Generated by :desktop:generateAosResources. Do not edit.\n" +
            "package dev.marquart.aos.desktop\n\nobject BuildInfo {\n    const val VERSION = \"$appVersion\"\n}\n")

        val resOut = aosResourcesOut.resolve("aos")
        resOut.deleteRecursively()
        resOut.resolve("strings").mkdirs()
        fun esc(s: String) = s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")
        val languages = (strings.keys + plurals.keys).toSortedSet()
        for (language in languages) {
            val lines = StringBuilder()
            strings[language]?.toSortedMap()?.forEach { (k, v) -> lines.append("s\t$k\t\t${esc(v)}\n") }
            plurals[language]?.toSortedMap()?.forEach { (k, m) -> m.forEach { (q, v) -> lines.append("p\t$k\t$q\t${esc(v)}\n") } }
            resOut.resolve("strings/${language.ifEmpty { "default" }}.tsv").writeText(lines.toString())
        }
        resOut.resolve("drawable").mkdirs()
        drawables.forEach { it.copyTo(resOut.resolve("drawable/${it.name}"), overwrite = true) }
        resOut.resolve("raw").mkdirs()
        raws.forEach { it.copyTo(resOut.resolve("raw/${it.name}"), overwrite = true) }
    }
}
tasks.named("compileKotlin") { dependsOn(generateAosResources) }
tasks.named("processResources") { dependsOn(generateAosResources) }

dependencies {
    implementation(project(":shared"))
    // Compose without Skia's native parts; those come per target (runtimeOnly for this Mac, the packages' own below).
    implementation(compose.desktop.common)
    runtimeOnly(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(libs.compose.material.icons.desktop)
    implementation(libs.kotlinx.coroutines.swing)
    implementation(libs.kotlinx.serialization.json)
    // CNG and DPAPI (Windows), libsecret and PAM (Linux), the registry, and the Go library's binding.
    implementation(libs.jna)
    implementation(libs.jna.platform)
    // The terminal: JetBrains' JediTerm (the terminal of IntelliJ; LGPL-3.0 or Apache-2.0, used under Apache-2.0).
    implementation(libs.jediterm.core)
    implementation(libs.jediterm.ui)
    // Bonjour: the Mac's pairing listener (_aos-pair._tcp) and SSH (_ssh._tcp).
    implementation(libs.jmdns)
    testImplementation(kotlin("test-junit"))
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(testFixtures(project(":shared")))
}

tasks.test {
    maxHeapSize = "1g"
    if (rootProject.file("third_party/aosgo-desktop/out/darwin-arm64/libaosgo.dylib").isFile) {
        systemProperty("aosgo.library", rootProject.file("third_party/aosgo-desktop/out/darwin-arm64/libaosgo.dylib").absolutePath)
    }
    systemProperty("java.awt.headless", "true")
    val live = providers.gradleProperty("aos.live.link").orNull
    if (live != null) {
        systemProperty("aos.live.link", live)
        outputs.upToDateWhen { false }
    }
    testLogging.showStandardStreams = live != null
}

val mainClassName = "dev.marquart.aos.desktop.MainKt"

compose.desktop {
    application {
        mainClass = mainClassName
        jvmArgs += listOf("-Xmx512m")
    }
}

// The packages (Tools/desktop.sh): one jar per target with Skia's native part for that system only.
// ./gradlew :desktop:packageJars -> build/package/<target>/aOS.jar
val composeVersion = libs.versions.composeMultiplatform.get()
val packageTargets = listOf("windows-x64", "windows-arm64", "linux-x64", "linux-arm64")
    .associateWith { "org.jetbrains.compose.desktop:desktop-jvm-$it:$composeVersion" }
val packageJars = tasks.register("packageJars")
for ((target, composeRuntime) in packageTargets) {
    val runtime = configurations.create("runtime-$target") {
        isCanBeConsumed = false
        isCanBeResolved = true
        extendsFrom(configurations.implementation.get())
        val base = configurations.runtimeClasspath.get().attributes
        attributes {
            @Suppress("UNCHECKED_CAST")
            base.keySet().forEach { key -> attribute(key as Attribute<Any>, base.getAttribute(key)!!) }
        }
    }
    dependencies.add(runtime.name, composeRuntime)
    val jar = tasks.register<Jar>("jar-$target") {
        group = "distribution"
        archiveFileName.set("aOS.jar")
        destinationDirectory.set(layout.buildDirectory.dir("package/$target"))
        duplicatesStrategy = DuplicatesStrategy.EXCLUDE
        manifest {
            attributes("Main-Class" to mainClassName, "Implementation-Version" to appVersion, "Enable-Native-Access" to "ALL-UNNAMED")
        }
        from(sourceSets.main.get().output)
        dependsOn(runtime)
        from({ runtime.filter { it.name.endsWith(".jar") }.map { zipTree(it) } })
        exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA", "META-INF/versions/9/module-info.class", "module-info.class")
    }
    packageJars.configure { dependsOn(jar) }
}

// For this Mac (development, screenshots): ./gradlew :desktop:run --args="--demo"
// The Go library for this Mac (Tools/go-desktop.sh darwin-arm64), when it is built.
val devGoLibrary: File = rootProject.file("third_party/aosgo-desktop/out/darwin-arm64/libaosgo.dylib")

tasks.register<JavaExec>("runDesktop") {
    group = "application"
    mainClass.set(mainClassName)
    classpath = sourceSets.main.get().runtimeClasspath
    jvmArgs("-Xmx512m")
    if (devGoLibrary.isFile) systemProperty("aosgo.library", devGoLibrary.absolutePath)
    providers.gradleProperty("aos.home").orNull?.let { systemProperty("aos.home", it) }
    providers.gradleProperty("aos.args").orNull?.let { args(it.split(" ")) }
}

