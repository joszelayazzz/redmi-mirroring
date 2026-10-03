#!/bin/bash
set -euo pipefail
ANDROID_PROJECT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$ANDROID_PROJECT/.." && pwd)"
PROJECT_WORK="${REDMI_BUILD_WORK_DIR:-$PROJECT_ROOT/.build-work}"
JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
KOTLIN_ROOT="${KOTLIN_ROOT:-/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc}"
export JAVA_HOME
mkdir -p "$PROJECT_WORK/android-tests"
"$KOTLIN_ROOT/bin/kotlinc" "$ANDROID_PROJECT/app/src/main/java/com/redmimirroring/companion/Wire.kt" "$ANDROID_PROJECT/tests/WireTest.kt" \
  -jvm-target 1.8 -include-runtime -d "$PROJECT_WORK/android-tests/wire-tests.jar"
"$JAVA_HOME/bin/java" -jar "$PROJECT_WORK/android-tests/wire-tests.jar"
