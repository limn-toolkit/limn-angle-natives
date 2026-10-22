rootProject.name = "limn-angle-natives"

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
    }
}

// One project, one artifact, five jars: the licences in the main jar and ANGLE's libEGL and
// libGLESv2 in one natives-<os>-<arch> classifier each, for Windows and macOS. It is the OpenGL ES
// fallback of limn-toolkit's ADR 003, here so that it versions with ANGLE, as limn-ffmpeg-natives
// versions with FFmpeg and limn-lunasvg-natives with lunasvg: a toolkit release re-uploads no
// native byte.
