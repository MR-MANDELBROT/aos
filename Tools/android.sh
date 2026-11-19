#!/bin/zsh
# Runs Gradle for the Android app with the right environment: Tools/android.sh :core:test, :app:assembleDebug, ...
# Java and the Android SDK come from Homebrew (openjdk@17, android-commandlinetools).
set -e
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
cd "$(dirname "$0")/../Android"
exec ./gradlew "$@"
