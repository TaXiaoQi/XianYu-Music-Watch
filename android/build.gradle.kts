import org.gradle.api.tasks.compile.JavaCompile

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}
// OpenHarmony 移植插件（gitcode 拉取的 fluttertpc_audio_service 等）在 JavaCompile 上
// 自带 -Werror，配合新版 JDK 的「source/target 8 已过时」警告会把警告升级成错误，
// 导致 :audio_service:compileDebugJavaWithJavac 构建失败。统一剥掉 -Werror 即可
// 恢复构建；app 模块自身的 Java 17 配置不受影响。
// 用 taskGraph.whenReady 而非 subprojects.afterEvaluate，避免子模块已求值时抛错。
gradle.taskGraph.whenReady {
    allTasks.filterIsInstance<JavaCompile>().forEach {
        it.options.compilerArgs.removeAll(listOf("-Werror"))
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
