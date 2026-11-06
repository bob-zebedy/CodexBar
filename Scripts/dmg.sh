#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/Build}"
BACKGROUND_FILE="${SCRIPT_DIR}/resources/arrow.tiff"
LAYOUT_FILE="${SCRIPT_DIR}/resources/layout"
COPY_LAYOUT=0

usage() {
    cat <<USAGE
usage: Scripts/dmg.sh [options] [App.app] [Output.dmg]

Options:
  --layout PATH       Layout template to read, or save with --copy-layout
                      Defaults to Scripts/resources/layout
  --copy-layout       Configure the layout with Finder, save it, and build the DMG
  -h, --help          Show this help

By default, the script copies the template without calling Finder
The template must match the App name, volume name, and .background/arrow.tiff path
Relative paths are resolved from the project directory

Examples:
  Scripts/dmg.sh --copy-layout
  Scripts/dmg.sh
  Scripts/dmg.sh --layout path/to/layout
USAGE
}

POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --copy-layout)
            COPY_LAYOUT=1
            shift
        ;;
        --layout)
            if [[ -z "${2:-}" || "${2}" == -* ]]; then
                echo "error: --layout requires a path" >&2
                exit 1
            fi
            LAYOUT_FILE="$2"
            shift 2
        ;;
        -h|--help)
            usage
            exit 0
        ;;
        --)
            shift
            POSITIONAL_ARGS+=("$@")
            break
        ;;
        -*)
            echo "error: unknown option $1" >&2
            exit 1
        ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
        ;;
    esac
done

if [[ "${#POSITIONAL_ARGS[@]}" -gt 2 ]]; then
    usage >&2
    exit 1
fi

APP_PATH="${POSITIONAL_ARGS[0]:-}"
OUTPUT_PATH="${POSITIONAL_ARGS[1]:-}"

if [[ "${BUILD_DIR}" != /* ]]; then
    BUILD_DIR="${PROJECT_DIR}/${BUILD_DIR}"
fi
if [[ "${LAYOUT_FILE}" != /* ]]; then
    LAYOUT_FILE="${PROJECT_DIR}/${LAYOUT_FILE}"
fi

if [[ -z "${APP_PATH}" ]]; then
    if [[ ! -d "${BUILD_DIR}" ]]; then
        echo "error: build directory does not exist: ${BUILD_DIR}" >&2
        usage >&2
        exit 1
    fi

    apps=()
    while IFS= read -r app; do
        apps+=("${app}")
    done < <(find "${BUILD_DIR}" -maxdepth 1 -type d -name "*.app" | sort)

    if [[ "${#apps[@]}" -eq 0 ]]; then
        echo "error: no .app found in build directory: ${BUILD_DIR}" >&2
        usage >&2
        exit 1
    fi

    if [[ "${#apps[@]}" -gt 1 ]]; then
        echo "error: multiple apps found in build directory; specify the app path to package:" >&2
        printf '  %s\n' "${apps[@]}" >&2
        exit 1
    fi

    APP_PATH="${apps[0]}"
elif [[ "${APP_PATH}" != /* ]]; then
    APP_PATH="${PROJECT_DIR}/${APP_PATH}"
fi

if [[ ! -d "${APP_PATH}" || "${APP_PATH}" != *.app ]]; then
    echo "error: invalid app path: ${APP_PATH}" >&2
    exit 1
fi

APP_NAME="$(basename "${APP_PATH}" .app)"
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}" 2>/dev/null || true)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}" 2>/dev/null || true)"

if [[ -z "${VERSION}" || -z "${BUILD}" ]]; then
    echo "error: cannot read version information" >&2
    exit 1
fi

if [[ -z "${OUTPUT_PATH}" ]]; then
    OUTPUT_PATH="${BUILD_DIR}/${APP_NAME}-v${VERSION}.dmg"
elif [[ "${OUTPUT_PATH}" != /* ]]; then
    OUTPUT_PATH="${PROJECT_DIR}/${OUTPUT_PATH}"
fi

DIST_DIR="$(dirname "${OUTPUT_PATH}")"
VOLUME_NAME="${APP_NAME}"
RW_DMG="${DIST_DIR}/${APP_NAME}-${VERSION}-layout-rw.dmg"
TEMP_OUTPUT_PATH="${OUTPUT_PATH%.dmg}.tmp.dmg"
STAGING_DIR="$(mktemp -d "/private/tmp/${APP_NAME}DMGStage.XXXXXX")"
MOUNT_POINT=""
LAYOUT_TEMP=""

cleanup() {
    if [[ -n "${MOUNT_POINT}" ]]; then
        diskutil eject "${MOUNT_POINT}" >/dev/null 2>&1 || true
    fi

    rm -rf "${STAGING_DIR}"
    rm -f "${RW_DMG}" "${TEMP_OUTPUT_PATH}"
    if [[ -n "${LAYOUT_TEMP}" ]]; then
        rm -f "${LAYOUT_TEMP}"
    fi
}
trap 'rm -rf "${STAGING_DIR}"' EXIT

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: missing command $1" >&2
        exit 1
    fi
}

run_quietly() {
    local output
    if ! output="$("$@" 2>&1)"; then
        printf '%s\n' "${output}" >&2
        return 1
    fi
}

validate_layout() {
    if [[ ! -s "$1" || "$(od -An -tx1 -N8 "$1" | tr -d '[:space:]')" != "0000000142756431" ]]; then
        echo "error: missing or invalid layout $1" >&2
        echo "       use --copy-layout to create a template" >&2
        return 1
    fi
}

unmount_app_dmgs() {
    local image_info="${STAGING_DIR}/mounted-images.plist"
    local image_count index image_path device

    hdiutil info -plist > "${image_info}"
    image_count="$(plutil -extract images raw -expect array "${image_info}")"

    for ((index = 0; index < image_count; index++)); do
        image_path="$(plutil -extract "images.${index}.image-path" raw -expect string "${image_info}")"
        case "${image_path##*/}" in
            "${APP_NAME}.dmg"|"${APP_NAME}-v"*.dmg|"${APP_NAME}-"*-layout-rw.dmg)
            ;;
            *)
                continue
            ;;
        esac

        device="$(plutil -extract "images.${index}.system-entities.0.dev-entry" raw -expect string "${image_info}")"
        run_quietly diskutil eject "${device}"
    done

    rm -f "${image_info}"
}

require_command diskutil
require_command hdiutil
require_command plutil
require_command ditto
if [[ "${COPY_LAYOUT}" == "1" ]]; then
    require_command osascript
fi

if [[ ! -f "${BACKGROUND_FILE}" ]]; then
    echo "error: missing DMG background ${BACKGROUND_FILE}" >&2
    exit 1
fi

if [[ "${COPY_LAYOUT}" == "1" ]]; then
    mkdir -p "$(dirname "${LAYOUT_FILE}")"
    if [[ -d "${LAYOUT_FILE}" || ! -w "$(dirname "${LAYOUT_FILE}")" ]]; then
        echo "error: cannot save layout to ${LAYOUT_FILE}" >&2
        exit 1
    fi
else
    validate_layout "${LAYOUT_FILE}"
    cp "${LAYOUT_FILE}" "${STAGING_DIR}/.DS_Store"
fi

mkdir -p "${DIST_DIR}"
echo "==> Unmounting DMG"
unmount_app_dmgs

echo "==> Removing DMG"
find "${DIST_DIR}" -maxdepth 1 -type f -name '*.dmg' -delete
trap cleanup EXIT

echo "==> Preparing DMG"
ditto "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"
mkdir -p "${STAGING_DIR}/.background"
ditto "${BACKGROUND_FILE}" "${STAGING_DIR}/.background/arrow.tiff"

echo "==> Creating DMG"
run_quietly diskutil image create from \
    --format RAW \
    --volumeName "${VOLUME_NAME}" \
    "${STAGING_DIR}" \
    "${RW_DMG}"

echo "==> Mounting DMG"
MOUNT_POINT="${STAGING_DIR}/mount"
run_quietly diskutil image attach \
    --mountOptions nobrowse \
    --mountPoint "${MOUNT_POINT}" \
    "${RW_DMG}"

if [[ -z "${MOUNT_POINT}" || ! -d "${MOUNT_POINT}" ]]; then
    echo "error: failed to mount DMG" >&2
    exit 1
fi

ln -s /Applications "${MOUNT_POINT}/Applications"

if [[ "${COPY_LAYOUT}" == "1" ]]; then
    echo "==> Writing Layout"
    osascript >/dev/null <<APPLESCRIPT
set mountFolder to POSIX file "${MOUNT_POINT}" as alias

tell application "Finder"
    open mountFolder
    delay 1
    set targetWindow to front Finder window
    set current view of targetWindow to icon view
    set toolbar visible of targetWindow to false
    set statusbar visible of targetWindow to false
    set bounds of targetWindow to {120, 120, 640, 420}
    set theViewOptions to icon view options of targetWindow
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set text size of theViewOptions to 13
    set backgroundFile to get file ".background:arrow.tiff" of mountFolder
    set background picture of theViewOptions to backgroundFile
    set position of item "${APP_NAME}.app" of mountFolder to {160, 110}
    set position of item "Applications" of mountFolder to {360, 110}
    update mountFolder without registering applications
    delay 2
    try
        close targetWindow
    end try
end tell
APPLESCRIPT
else
    echo "==> Applying Layout"
    cp "${STAGING_DIR}/.DS_Store" "${MOUNT_POINT}/.DS_Store"
    validate_layout "${MOUNT_POINT}/.DS_Store"
fi

sync
run_quietly diskutil eject "${MOUNT_POINT}"
MOUNT_POINT=""

if [[ "${COPY_LAYOUT}" == "1" ]]; then
    # Finder may finish writing the layout while the volume is being ejected
    MOUNT_POINT="${STAGING_DIR}/mount"
    run_quietly diskutil image attach \
        --readOnly \
        --mountOptions nobrowse \
        --mountPoint "${MOUNT_POINT}" \
        "${RW_DMG}"
    validate_layout "${MOUNT_POINT}/.DS_Store"
    LAYOUT_TEMP="$(mktemp "${LAYOUT_FILE}.XXXXXX")"
    cp "${MOUNT_POINT}/.DS_Store" "${LAYOUT_TEMP}"
    run_quietly diskutil eject "${MOUNT_POINT}"
    MOUNT_POINT=""
fi

echo "==> Compressing DMG"
run_quietly diskutil image create from \
    --format UDZO \
    "${RW_DMG}" \
    "${TEMP_OUTPUT_PATH}"

mv -f "${TEMP_OUTPUT_PATH}" "${OUTPUT_PATH}"

if [[ "${COPY_LAYOUT}" == "1" ]]; then
    mv -f "${LAYOUT_TEMP}" "${LAYOUT_FILE}"
    LAYOUT_TEMP=""
    echo "==> Layout saved to ${LAYOUT_FILE}"
fi

echo "==> Created ${OUTPUT_PATH}"
CHECKSUM="$(shasum -a 256 "${OUTPUT_PATH}" | awk '{print $1}')"
echo "    Version: ${VERSION} (${BUILD})"
echo "    SHA-256: ${CHECKSUM}"
