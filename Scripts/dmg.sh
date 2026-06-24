#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_PATH="${1:-}"
OUTPUT_PATH="${2:-}"

if [[ -z "${APP_PATH}" ]]; then
    apps=()
    while IFS= read -r app; do
        apps+=("${app}")
    done < <(find "${PROJECT_DIR}" -maxdepth 1 -type d -name "*.app" | sort)

    if [[ "${#apps[@]}" -eq 0 ]]; then
        echo "error: 当前目录没有找到 .app" >&2
        echo "usage: Scripts/dmg.sh [App.app] [Output.dmg]" >&2
        exit 1
    fi

    if [[ "${#apps[@]}" -gt 1 ]]; then
        echo "error: 当前目录找到多个 .app, 请指定要打包的 app 路径: " >&2
        printf '  %s\n' "${apps[@]}" >&2
        exit 1
    fi

    APP_PATH="${apps[0]}"
elif [[ "${APP_PATH}" != /* ]]; then
    APP_PATH="${PROJECT_DIR}/${APP_PATH}"
fi

if [[ ! -d "${APP_PATH}" || "${APP_PATH}" != *.app ]]; then
    echo "error: app 路径无效: ${APP_PATH}" >&2
    exit 1
fi

APP_NAME="$(basename "${APP_PATH}" .app)"
PLIST_PATH="${APP_PATH}/Contents/Info.plist"
XCODE_PROJECT="${XCODE_PROJECT:-}"
XCODE_SCHEME="${XCODE_SCHEME:-${APP_NAME}}"
VERSION=""

if [[ -z "${XCODE_PROJECT}" ]]; then
    while IFS= read -r project; do
        XCODE_PROJECT="${project}"
        break
    done < <(find "${PROJECT_DIR}" -maxdepth 1 -type d -name "*.xcodeproj" | sort)
elif [[ "${XCODE_PROJECT}" != /* ]]; then
    XCODE_PROJECT="${PROJECT_DIR}/${XCODE_PROJECT}"
fi

if [[ -n "${XCODE_PROJECT}" && -d "${XCODE_PROJECT}" ]]; then
    VERSION="$(
        xcodebuild \
        -project "${XCODE_PROJECT}" \
        -scheme "${XCODE_SCHEME}" \
        -configuration Release \
        -showBuildSettings 2>/dev/null |
        awk -F= '/MARKETING_VERSION/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' ||
        true
    )"
fi

if [[ -z "${VERSION}" && -n "${XCODE_PROJECT}" && -d "${XCODE_PROJECT}" ]]; then
    VERSION="$(
        awk -F= '
      /MARKETING_VERSION/ {
        value = $2
        gsub(/[[:space:];]/, "", value)
        print value
        exit
      }
        ' "${XCODE_PROJECT}/project.pbxproj" 2>/dev/null || true
    )"
fi

if [[ -z "${VERSION}" && -f "${PLIST_PATH}" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST_PATH}" 2>/dev/null || true)"
fi

if [[ -z "${VERSION}" ]]; then
    echo "error: 无法从 Xcode 或 Info.plist 读取版本号" >&2
    exit 1
fi

if [[ -z "${OUTPUT_PATH}" ]]; then
    OUTPUT_PATH="${PROJECT_DIR}/${APP_NAME}-v${VERSION}.dmg"
elif [[ "${OUTPUT_PATH}" != /* ]]; then
    OUTPUT_PATH="${PROJECT_DIR}/${OUTPUT_PATH}"
fi

DIST_DIR="$(dirname "${OUTPUT_PATH}")"
VOLUME_NAME="${APP_NAME}"
RW_DMG="${DIST_DIR}/${APP_NAME}-${VERSION}-layout-rw.dmg"
TEMP_OUTPUT_PATH="${OUTPUT_PATH%.dmg}.tmp.dmg"
STAGING_DIR="$(mktemp -d "/private/tmp/${APP_NAME}DMGStage.XXXXXX")"
MOUNT_POINT=""

cleanup() {
    if [[ -n "${MOUNT_POINT}" ]]; then
        hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true
    fi

    rm -rf "${STAGING_DIR}"
    rm -f "${RW_DMG}" "${TEMP_OUTPUT_PATH}"
}
trap cleanup EXIT

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: 缺少命令: $1" >&2
        exit 1
    fi
}

require_command hdiutil
require_command osascript
require_command ditto

mkdir -p "${DIST_DIR}"
rm -f "${RW_DMG}" "${TEMP_OUTPUT_PATH}"

echo "==> Preparing DMG contents"
ditto "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"

echo "==> Creating writable DMG"
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDRW \
    "${RW_DMG}" >/dev/null

echo "==> Mounting writable DMG"
ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "${RW_DMG}")"
MOUNT_POINT="$(printf '%s\n' "${ATTACH_OUTPUT}" | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/")); exit}')"

if [[ -z "${MOUNT_POINT}" || ! -d "${MOUNT_POINT}" ]]; then
    echo "error: 挂载 DMG 失败" >&2
    printf '%s\n' "${ATTACH_OUTPUT}" >&2
    exit 1
fi

echo "==> Writing Finder layout"
osascript <<APPLESCRIPT
set mountFolder to POSIX file "${MOUNT_POINT}" as alias
set applicationsFolder to POSIX file "/Applications" as alias

tell application "Finder"
    open mountFolder
    delay 1
    if exists item "Applications" of mountFolder then
        delete item "Applications" of mountFolder
    end if
    make new alias file to applicationsFolder at mountFolder with properties {name:"Applications"}
    set targetWindow to front Finder window
    set current view of targetWindow to icon view
    set toolbar visible of targetWindow to false
    set statusbar visible of targetWindow to false
    set bounds of targetWindow to {120, 120, 640, 420}
    set theViewOptions to icon view options of targetWindow
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set text size of theViewOptions to 13
    set position of item "${APP_NAME}.app" of mountFolder to {170, 80}
    set position of item "Applications" of mountFolder to {350, 80}
    update mountFolder without registering applications
    delay 2
    try
        close targetWindow
    end try
end tell
APPLESCRIPT

DS_STORE="${MOUNT_POINT}/.DS_Store"
if [[ ! -s "${DS_STORE}" ]]; then
    echo "warning: 没有写入 .DS_Store 窗口布局不会生效" >&2
else
    echo "==> Finder layout saved"
fi

sync
hdiutil detach "${MOUNT_POINT}" >/dev/null
MOUNT_POINT=""

echo "==> Creating compressed DMG"
hdiutil convert \
    "${RW_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "${TEMP_OUTPUT_PATH}" >/dev/null

mv -f "${TEMP_OUTPUT_PATH}" "${OUTPUT_PATH}"

echo "==> Created ${OUTPUT_PATH}"
echo "==> Update appcast with: Scripts/appcast.sh \"${OUTPUT_PATH}\""
