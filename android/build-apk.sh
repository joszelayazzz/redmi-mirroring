#!/bin/bash
set -euo pipefail
ANDROID_PROJECT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$ANDROID_PROJECT/.." && pwd)"
PROJECT_WORK="${REDMI_BUILD_WORK_DIR:-$PROJECT_ROOT/.build-work}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
KOTLIN_ROOT="${KOTLIN_ROOT:-/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc}"
ANDROID_PLATFORM="${ANDROID_PLATFORM:-android-36.1}"
ANDROID_BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-36.0.0}"
D8_JAR="${D8_JAR:-/Applications/Android Studio.app/Contents/plugins/android/lib/r8.jar}"
BUILD_WORK="$PROJECT_WORK/android-build"
SIGNING_WORK="${REDMI_SIGNING_DIR:-$PROJECT_WORK/android-signing}"
APK_OUTPUT="$ANDROID_PROJECT/../build"
TOOLS="$ANDROID_SDK_ROOT/build-tools/$ANDROID_BUILD_TOOLS"
PLATFORM_JAR="$ANDROID_SDK_ROOT/platforms/$ANDROID_PLATFORM/android.jar"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
mkdir -p "$BUILD_WORK/classes" "$BUILD_WORK/generated" "$BUILD_WORK/dex" "$BUILD_WORK/assets" "$SIGNING_WORK" "$APK_OUTPUT"
cp "$ANDROID_PROJECT/../THIRD-PARTY-NOTICES.txt" "$BUILD_WORK/assets/THIRD-PARTY-NOTICES.txt"
chmod 700 "$SIGNING_WORK"
# These are local build credentials. They never enter source or an APK.
if [[ ! -e "$SIGNING_WORK/password.txt" ]]; then
  umask 077
  openssl rand -hex 32 > "$SIGNING_WORK/password.txt"
fi
if [[ ! -e "$SIGNING_WORK/development.p12" ]]; then
  "$JAVA_HOME/bin/keytool" -genkeypair -alias redmi-dev -keyalg RSA -keysize 3072 -validity 3650 \
    -dname 'CN=Redmi Mirroring Local Development' -storetype PKCS12 \
    -keystore "$SIGNING_WORK/development.p12" -storepass:file "$SIGNING_WORK/password.txt" -keypass:file "$SIGNING_WORK/password.txt"
fi
"$TOOLS/aapt2" compile --dir "$ANDROID_PROJECT/app/src/main/res" -o "$BUILD_WORK/resources.zip"
"$TOOLS/aapt2" link -o "$BUILD_WORK/base.apk" -I "$PLATFORM_JAR" \
  --manifest "$ANDROID_PROJECT/app/src/main/AndroidManifest.xml" --java "$BUILD_WORK/generated" -A "$BUILD_WORK/assets" "$BUILD_WORK/resources.zip"
"$JAVA_HOME/bin/javac" --release 8 -Xlint:-options -cp "$PLATFORM_JAR" -d "$BUILD_WORK/classes" "$BUILD_WORK/generated/com/redmimirroring/companion/R.java"
"$KOTLIN_ROOT/bin/kotlinc" "$ANDROID_PROJECT/app/src/main/java" -no-stdlib -no-reflect \
  -classpath "$PLATFORM_JAR:$KOTLIN_ROOT/lib/kotlin-stdlib.jar:$BUILD_WORK/classes" -jvm-target 1.8 -d "$BUILD_WORK/classes"
"$JAVA_HOME/bin/jar" cf "$BUILD_WORK/classes.jar" -C "$BUILD_WORK/classes" .
"$JAVA_HOME/bin/java" -cp "$D8_JAR" com.android.tools.r8.D8 --lib "$PLATFORM_JAR" --min-api 29 --output "$BUILD_WORK/dex" "$BUILD_WORK/classes.jar" "$KOTLIN_ROOT/lib/kotlin-stdlib.jar"
cp "$BUILD_WORK/base.apk" "$BUILD_WORK/unaligned.apk"
(cd "$BUILD_WORK/dex" && zip -q -u "$BUILD_WORK/unaligned.apk" classes*.dex)
"$TOOLS/zipalign" -f -p 4 "$BUILD_WORK/unaligned.apk" "$BUILD_WORK/aligned.apk"
"$TOOLS/apksigner" sign --ks "$SIGNING_WORK/development.p12" --ks-key-alias redmi-dev \
  --ks-pass "file:$SIGNING_WORK/password.txt" --out "$APK_OUTPUT/RedmiMirroring-companion.apk" "$BUILD_WORK/aligned.apk"
"$TOOLS/apksigner" verify --verbose "$APK_OUTPUT/RedmiMirroring-companion.apk"
"$TOOLS/aapt2" dump badging "$APK_OUTPUT/RedmiMirroring-companion.apk"
printf '\nBuilt: %s\n' "$APK_OUTPUT/RedmiMirroring-companion.apk"
