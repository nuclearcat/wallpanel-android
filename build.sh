#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
GRADLEW="$ROOT_DIR/gradlew"
MAX_JAVA_MAJOR=21
GRADLE_CACHE_DIR="${WALLPANEL_GRADLE_USER_HOME:-$ROOT_DIR/.gradle}"

usage() {
  cat <<'EOF'
Usage:
  ./build.sh [gradle-arguments]

Examples:
  ./build.sh
  ./build.sh :WallPanelApp:assembleProdDebug
  ./build.sh :WallPanelApp:assembleProdRelease

If no arguments are passed, it builds:
  :WallPanelApp:assembleProdDebug
EOF
}

if [[ ${1-} == "--help" || ${1-} == "-h" ]]; then
  usage
  exit 0
fi

get_java_major() {
  local java_bin="$1"
  local raw
  raw="$("$java_bin" -version 2>&1 | sed -n 's/.*version \"\([^\"]*\)\".*/\1/p' | head -n1)"
  raw="${raw%%-*}"
  if [[ "$raw" == 1.* ]]; then
    raw="${raw#1.}"
  fi
  echo "${raw%%.*}"
}

fetch_sdkmanager() {
  local sdk_home="$1"
  local host_os
  local tools_zip_url
  local tmp_dir
  local zip_file
  local sdk_tools_dir="${sdk_home}/cmdline-tools"

  host_os="$(uname -s)"
  case "$host_os" in
    Linux*)
      tools_zip_url="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
      ;;
    Darwin*)
      tools_zip_url="https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip"
      ;;
    *)
      echo "Error: unsupported OS '$host_os' for auto-installing SDK command-line tools."
      return 1
      ;;
  esac

  if ! command -v unzip >/dev/null 2>&1; then
    echo "Error: unzip is required to install Android command-line tools."
    return 1
  fi

  tmp_dir="$(mktemp -d)"
  zip_file="${tmp_dir}/cmdline-tools.zip"

  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL -o "$zip_file" "$tools_zip_url"; then
      echo "Error: failed to download Android command-line tools from $tools_zip_url"
      rm -rf "$tmp_dir"
      return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -qO "$zip_file" "$tools_zip_url"; then
      echo "Error: failed to download Android command-line tools from $tools_zip_url"
      rm -rf "$tmp_dir"
      return 1
    fi
  else
    echo "Error: curl or wget is required to auto-install command-line tools."
    rm -rf "$tmp_dir"
    return 1
  fi

  rm -rf "$tmp_dir/extracted"
  mkdir -p "$tmp_dir/extracted"
  if ! unzip -q "$zip_file" -d "$tmp_dir/extracted"; then
    echo "Error: failed to unzip Android command-line tools archive."
    rm -rf "$tmp_dir"
    return 1
  fi

  mkdir -p "$sdk_tools_dir"
  rm -rf "$sdk_tools_dir/latest"
  mkdir -p "$sdk_tools_dir/latest"

  if [[ -d "$tmp_dir/extracted/cmdline-tools" ]]; then
    cp -R "$tmp_dir/extracted/cmdline-tools/"* "$sdk_tools_dir/latest/"
  else
    echo "Error: unexpected command-line tools archive contents."
    rm -rf "$tmp_dir"
    return 1
  fi

  chmod +x "$sdk_tools_dir/latest/bin/sdkmanager"
  rm -rf "$tmp_dir"
}

resolve_sdk_home() {
  local path_from_props=""
  if [[ -f local.properties ]]; then
    path_from_props="$(sed -n 's/^sdk\\.dir[[:space:]]*=//p' local.properties | tr -d '\r' | head -n1)"
  fi

  if [[ -n "$path_from_props" ]]; then
    echo "$path_from_props"
    return 0
  fi

  if [[ -n "${ANDROID_HOME:-}" ]]; then
    echo "$ANDROID_HOME"
    return 0
  fi

  if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    echo "$ANDROID_SDK_ROOT"
    return 0
  fi

  return 1
}

sdkmanager_path() {
  local root="$1"
  local candidates=(
    "$root/cmdline-tools/latest/bin/sdkmanager"
    "$root/cmdline-tools/bin/sdkmanager"
    "$root/tools/bin/sdkmanager"
    "$(command -v sdkmanager || true)"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  local discovered
  discovered="$(find "$root" -type f -path '*/cmdline-tools/*/bin/sdkmanager' -name sdkmanager 2>/dev/null | head -n1)"
  if [[ -n "$discovered" ]]; then
    echo "$discovered"
    return 0
  fi

  return 1
}

ensure_android_sdk() {
  local sdk_home sdk_manager

  sdk_home="$(resolve_sdk_home || true)"
  if [[ -z "$sdk_home" ]]; then
    echo "Error: Android SDK path not found."
    echo "Set ANDROID_HOME, ANDROID_SDK_ROOT, or add sdk.dir to local.properties, then rerun."
    exit 1
  fi

  if [[ ! -d "$sdk_home" ]]; then
    echo "Error: Android SDK path '$sdk_home' does not exist."
    exit 1
  fi

  sdk_manager="$(sdkmanager_path "$sdk_home" || true)"
  if [[ -z "$sdk_manager" ]]; then
    if [[ "${WALLPANEL_AUTO_INSTALL_SDK_TOOLS:-1}" == "1" ]]; then
      echo "sdkmanager not found under '$sdk_home'. Attempting auto-install."
      if ! fetch_sdkmanager "$sdk_home"; then
        echo "Auto-install failed."
        echo "Install Android SDK command-line tools manually, then rerun."
        echo "https://developer.android.com/studio#command-tools"
        exit 1
      fi
      sdk_manager="$(sdkmanager_path "$sdk_home" || true)"
    fi

    if [[ -z "$sdk_manager" ]]; then
      echo "Error: sdkmanager not found under '$sdk_home'."
      echo "Install Android SDK command-line tools and retry."
      echo "Hint: export WALLPANEL_AUTO_INSTALL_SDK_TOOLS=1 to let the script download them."
      echo "Manual setup: https://developer.android.com/studio#command-tools"
      exit 1
    fi
  fi

  export ANDROID_HOME="$sdk_home"
  export ANDROID_SDK_ROOT="$sdk_home"

  echo "Using Android SDK at $sdk_home"
  if ! echo y | "$sdk_manager" --licenses --sdk_root="$sdk_home" >/tmp/wallpanel-sdk-licenses.log 2>&1; then
    echo "Warning: failed to auto-accept all licenses. Continuing with explicit install attempt."
    cat /tmp/wallpanel-sdk-licenses.log
  fi

  if ! echo y | "$sdk_manager" --sdk_root="$sdk_home" --install \
      "platforms;android-33" \
      "build-tools;34.0.0" \
      >/tmp/wallpanel-sdk-install.log 2>&1; then
    echo "Warning: SDK package install reported a warning/error. Check details:"
    cat /tmp/wallpanel-sdk-install.log
  fi
}

resolve_java_home() {
  local major
  local candidates=(
    "${WALLPANEL_JAVA_HOME:-}"
    "${JAVA_HOME_17:-}"
    "${JAVA17_HOME:-}"
    "${JAVA_HOME:-}"
  )

  if [[ ! -z "${WALLPANEL_GRADLE_JAVA_HOME:-}" ]]; then
    candidates=("$WALLPANEL_GRADLE_JAVA_HOME" "${candidates[@]}")
  fi

  for home in "${candidates[@]}"; do
    if [[ -z "$home" ]]; then
      continue
    fi

    if [[ ! -x "$home/bin/java" ]]; then
      continue
    fi

    major="$(get_java_major "$home/bin/java")"
    if [[ "$major" =~ ^[0-9]+$ && "$major" -le "$MAX_JAVA_MAJOR" ]]; then
      echo "$home"
      return 0
    fi
  done

  return 1
}

if ! command -v java >/dev/null 2>&1; then
  echo "Error: java is not in PATH. Install JDK (up to ${MAX_JAVA_MAJOR}) and retry."
  exit 1
fi

java_major="$(get_java_major java)"
if [[ ! "$java_major" =~ ^[0-9]+$ || "$java_major" -gt "$MAX_JAVA_MAJOR" ]]; then
  if java_home="$(resolve_java_home)"; then
    export JAVA_HOME="$java_home"
    export PATH="$JAVA_HOME/bin:$PATH"
    java_major="$(get_java_major "$JAVA_HOME/bin/java")"
    echo "Using JAVA_HOME=$JAVA_HOME (Java $java_major)"
  else
    echo "Error: Current Java version is unsupported (detected Java $java_major)."
    echo "Android Studio is not required, but this project needs JDK <= ${MAX_JAVA_MAJOR}."
    echo "Set one of these environment variables to a supported JDK and rerun:"
    echo "  export JAVA_HOME_17=/path/to/jdk17"
    echo "  export JAVA_HOME=/path/to/jdk17"
    echo "or set WALLPANEL_GRADLE_JAVA_HOME."
    exit 1
  fi
fi

if ! command -v java >/dev/null 2>&1; then
  echo "Error: java command not available after JAVA_HOME resolution."
  exit 1
fi

if [[ ! -f "$GRADLEW" ]]; then
  echo "Error: gradlew not found at $GRADLEW."
  exit 1
fi

if [[ ! -f local.properties ]]; then
  if [[ -n "${ANDROID_HOME:-}" || -n "${ANDROID_SDK_ROOT:-}" ]]; then
    sdk_path="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    echo "sdk.dir=$sdk_path" > local.properties
    echo "Created local.properties with sdk.dir=$sdk_path"
  else
    echo "Error: local.properties is missing and neither ANDROID_HOME nor ANDROID_SDK_ROOT is set."
    echo "Set one SDK env var and rerun, or create local.properties manually with:"
    echo "  sdk.dir=/path/to/Android/Sdk"
    exit 1
  fi
fi

ensure_android_sdk

if [[ ! -f WallPanelApp/google-services.json ]]; then
  echo "Warning: WallPanelApp/google-services.json is missing. Firebase-related build steps may fail."
fi

if (($#)); then
  GRADLE_ARGS=("$@")
else
  GRADLE_ARGS=(":WallPanelApp:assembleProdDebug")
fi

if [[ -x "$GRADLEW" ]]; then
  export GRADLE_USER_HOME="$GRADLE_CACHE_DIR"
  mkdir -p "$GRADLE_USER_HOME"
  echo "Running: $GRADLEW ${GRADLE_ARGS[*]}"
  "$GRADLEW" "${GRADLE_ARGS[@]}"
else
  echo "Warning: gradlew is not executable. Running via bash fallback."
  bash "$GRADLEW" "${GRADLE_ARGS[@]}"
fi
