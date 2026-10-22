#!/usr/bin/env bash
#
# Rehearses what a consumer receives, before anything is uploaded: publishes to the file repository
# under build/repo, resolves the main jar and every classifier present from it as a project
# building for Java 17 would, and checks that every jar holds what the toolkit's loader looks for.
# Central keeps what it accepts, so a mistake found here is one nobody downloads.
#
#   ./scripts/rehearse-consumer.sh            # the -SNAPSHOT of versions.properties
#   ./scripts/rehearse-consumer.sh 2.1.8078.0 # a release version (what the publish workflow passes)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-$(sed -n 's/^limn-angle-natives=\(.*\)$/\1/p' versions.properties)-SNAPSHOT}"
REPO="$ROOT/build/repo"
CONSUMER="$ROOT/build/consumer"

echo "· publishing $VERSION to ${REPO#"$ROOT/"}"
rm -rf "$REPO"
./gradlew publishAllPublicationsToBuildDirRepository -PlimnNativesVersion="$VERSION" -q

DIST="$ROOT/native/dist/limn/angle/native"
CLASSIFIERS=()
for dir in "$DIST"/*/; do
  ls "$dir"libGLESv2.* >/dev/null 2>&1 || continue
  CLASSIFIERS+=("natives-$(basename "$dir")")
done
if [ "${#CLASSIFIERS[@]}" -eq 0 ]; then
  echo "✗ no slice under ${DIST#"$ROOT/"}: run scripts/build-angle.sh or .ps1 first" >&2
  exit 1
fi
echo "· classifiers present: ${CLASSIFIERS[*]}"

# A jar of natives must not tell a Java 17 consumer it needs Java 21.
BAD="$(grep -rho '"org.gradle.jvm.version": [0-9]*' "$REPO" --include="*.module" | sort -u | grep -v ': 8$' || true)"
if [ -n "$BAD" ]; then
  echo "✗ a published variant declares a minimum JVM other than 8: $BAD" >&2
  exit 1
fi
echo "✓ every variant declares JVM 8"

rm -rf "$CONSUMER"; mkdir -p "$CONSUMER"
cp gradlew "$CONSUMER"/ && cp -r gradle "$CONSUMER"/
cat > "$CONSUMER/settings.gradle.kts" <<SETTINGS
rootProject.name = "consumer"
SETTINGS
{
  cat <<GRADLE
plugins { \`java-library\` }
repositories { maven { url = uri("$REPO") } }
java { toolchain { languageVersion.set(JavaLanguageVersion.of(21)) } }
tasks.withType<JavaCompile>().configureEach { options.release.set(17) }
dependencies {
    runtimeOnly("io.github.limn-toolkit:limn-angle-natives:$VERSION")
GRADLE
  for classifier in "${CLASSIFIERS[@]}"; do
    echo "    runtimeOnly(\"io.github.limn-toolkit:limn-angle-natives:$VERSION:$classifier\")"
  done
  cat <<'GRADLE'
}
tasks.register("resolveLikeAConsumer") {
    val files = configurations.runtimeClasspath.get()
    val out = layout.buildDirectory.file("resolved.txt")
    outputs.file(out)
    doLast { out.get().asFile.writeText(files.joinToString("\n", postfix = "\n") { it.absolutePath }) }
}
GRADLE
} > "$CONSUMER/build.gradle.kts"

( cd "$CONSUMER" && ./gradlew resolveLikeAConsumer -q )

status=0
seen=0
while IFS= read -r jar || [ -n "$jar" ]; do
  [ -n "$jar" ] || continue
  name="$(basename "$jar")"
  # The listing once, into a variable: under pipefail, `unzip -l | grep -q` reports unzip's SIGPIPE
  # when grep stops early, and a found file then reads as a missing one.
  listing="$(unzip -l "$jar" < /dev/null)"
  case "$name" in
    limn-angle-natives-*-natives-*.jar)
      # The platform is whatever follows the LAST "-natives-": a -SNAPSHOT publishes under a
      # timestamped file name, which is not the version string this script was given.
      platform="${name##*-natives-}"; platform="${platform%.jar}"
      for lib in libEGL libGLESv2; do
        if grep -Eq "limn/angle/native/$platform/$lib\.(dylib|dll)" <<< "$listing"; then
          echo "✓ $name carries $lib for $platform"
        else
          echo "✗ $name has no $lib for $platform" >&2; status=1
        fi
      done
      for f in "$platform/THIRD_PARTY.txt" LICENSE-angle.txt; do
        if ! grep -q "limn/angle/native/$f" <<< "$listing"; then
          echo "✗ $name carries no $f" >&2; status=1
        fi
      done
      module="$(unzip -p "$jar" META-INF/MANIFEST.MF | tr -d '\r' | sed -n 's/^Automatic-Module-Name: //p')"
      if [ "$module" != "limn.angle.natives.${platform//-/.}" ]; then
        echo "✗ $name is module '$module'; each platform's jar needs a name of its own" >&2; status=1
      else
        echo "✓ $name is module $module"
      fi
      seen=$((seen + 1)) ;;
    limn-angle-natives-*.jar)
      if ! grep -q "limn/angle/native/LICENSE-angle.txt" <<< "$listing"; then
        echo "✗ $name has no LICENSE-angle.txt" >&2; status=1
      fi
      if grep -Eq "lib(EGL|GLESv2)\.(dylib|dll)" <<< "$listing"; then
        echo "✗ $name, the main jar, carries a native; natives belong in the classifiers" >&2; status=1
      fi
      echo "✓ $name carries the licence and no native" ;;
  esac
done < "$CONSUMER/build/resolved.txt"

if [ "$seen" -ne "${#CLASSIFIERS[@]}" ]; then
  echo "✗ resolved $seen classifier jars, expected ${#CLASSIFIERS[@]}" >&2; status=1
fi
exit $status
