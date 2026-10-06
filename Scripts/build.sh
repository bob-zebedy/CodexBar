#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

XCODE_PROJECT="${PROJECT_DIR}/CodexBar.xcodeproj"
XCODE_SCHEME="CodexBar"
CONFIGURATION="Release"
BUILD_DIR="${PROJECT_DIR}/Build"
DERIVED_DATA_PATH=""
ARCHIVE_PATH=""
EXPORT_OPTIONS_PLIST=""
ALLOW_PROVISIONING_UPDATES="1"
SKIP_NOTARIZATION="0"
SPCTL_ASSESS="1"

# Configure the keychain profile once before release builds:
# xcrun notarytool store-credentials "codexbar-notary" --apple-id "<Apple ID>" --team-id "<Team ID>"
NOTARYTOOL_PROFILE=""
APPLE_ID=""
NOTARYTOOL_PASSWORD=""
TEAM_ID=""
OUTPUT_APP_PATH=""
ARCHIVE_SIGNING_FLAGS=()

usage() {
    cat >&2 <<USAGE
usage: Scripts/build.sh [options] [Output.app]

Builds a Release archive, exports a Developer ID app, submits it to Apple
notarization, staples the ticket, validates the result, and writes the final app to build/

Options:
  --project PATH                 Xcode project. Defaults to CodexBar.xcodeproj.
  --scheme NAME                  Xcode scheme. Defaults to CodexBar.
  --configuration NAME           Xcode configuration. Defaults to Release.
  --build-dir DIR                Build output directory within Build/. Defaults to Build/.
                                  Cleaned before each build.
  --derived-data PATH            DerivedData path within Build/. Defaults to Build/DerivedData.
  --archive-path PATH            Archive path. Defaults to Build/<scheme>.xcarchive.
  --export-options PATH          Export options plist. Generated when unset.
  --team-id ID                   Apple Developer team ID. Defaults to the
                                  DEVELOPMENT_TEAM build setting.
  --allow-provisioning-updates   Pass -allowProvisioningUpdates. Default.
  --no-provisioning-updates      Omit -allowProvisioningUpdates.
  --notary-profile PROFILE       Keychain profile for xcrun notarytool.
  --apple-id APPLE_ID            Apple ID fallback when no notary profile is set.
  --notary-password PASSWORD     App-specific password fallback. Prefer profile.
  --skip-notarization            Build/export without notarytool and stapling.
  --skip-spctl-assess            Skip final Gatekeeper spctl assessment.
  --output-app PATH              Final app path. Defaults to Build/CodexBar.app.
  -h, --help                     Show this help.

Recommended credential setup:
  xcrun notarytool store-credentials "codexbar-notary" --apple-id "<Apple ID>" --team-id "<Team ID>" --sync
  Scripts/build.sh --export-options Scripts/DeveloperID.plist --notary-profile codexbar-notary
USAGE
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
            ;;
            --project)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: --project requires a value" >&2
                    usage
                    exit 1
                fi
                XCODE_PROJECT="$2"
                shift 2
            ;;
            --project=*)
                XCODE_PROJECT="${1#*=}"
                if [[ -z "${XCODE_PROJECT}" ]]; then
                    echo "error: --project requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --scheme)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: --scheme requires a value" >&2
                    usage
                    exit 1
                fi
                XCODE_SCHEME="$2"
                shift 2
            ;;
            --scheme=*)
                XCODE_SCHEME="${1#*=}"
                if [[ -z "${XCODE_SCHEME}" ]]; then
                    echo "error: --scheme requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --configuration)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: --configuration requires a value" >&2
                    usage
                    exit 1
                fi
                CONFIGURATION="$2"
                shift 2
            ;;
            --configuration=*)
                CONFIGURATION="${1#*=}"
                if [[ -z "${CONFIGURATION}" ]]; then
                    echo "error: --configuration requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --build-dir)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: --build-dir requires a value" >&2
                    usage
                    exit 1
                fi
                BUILD_DIR="$2"
                shift 2
            ;;
            --build-dir=*)
                BUILD_DIR="${1#*=}"
                if [[ -z "${BUILD_DIR}" ]]; then
                    echo "error: --build-dir requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --derived-data)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: --derived-data requires a value" >&2
                    usage
                    exit 1
                fi
                DERIVED_DATA_PATH="$2"
                shift 2
            ;;
            --derived-data=*)
                DERIVED_DATA_PATH="${1#*=}"
                if [[ -z "${DERIVED_DATA_PATH}" ]]; then
                    echo "error: --derived-data requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --archive-path)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: --archive-path requires a value" >&2
                    usage
                    exit 1
                fi
                ARCHIVE_PATH="$2"
                shift 2
            ;;
            --archive-path=*)
                ARCHIVE_PATH="${1#*=}"
                if [[ -z "${ARCHIVE_PATH}" ]]; then
                    echo "error: --archive-path requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --export-options)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: --export-options requires a value" >&2
                    usage
                    exit 1
                fi
                EXPORT_OPTIONS_PLIST="$2"
                shift 2
            ;;
            --export-options=*)
                EXPORT_OPTIONS_PLIST="${1#*=}"
                if [[ -z "${EXPORT_OPTIONS_PLIST}" ]]; then
                    echo "error: --export-options requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --team-id)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: --team-id requires a value" >&2
                    usage
                    exit 1
                fi
                TEAM_ID="$2"
                shift 2
            ;;
            --team-id=*)
                TEAM_ID="${1#*=}"
                if [[ -z "${TEAM_ID}" ]]; then
                    echo "error: --team-id requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --allow-provisioning-updates)
                ALLOW_PROVISIONING_UPDATES="1"
                shift
            ;;
            --no-provisioning-updates)
                ALLOW_PROVISIONING_UPDATES="0"
                shift
            ;;
            --notary-profile)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: --notary-profile requires a value" >&2
                    usage
                    exit 1
                fi
                NOTARYTOOL_PROFILE="$2"
                shift 2
            ;;
            --notary-profile=*)
                NOTARYTOOL_PROFILE="${1#*=}"
                if [[ -z "${NOTARYTOOL_PROFILE}" ]]; then
                    echo "error: --notary-profile requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --apple-id)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: --apple-id requires a value" >&2
                    usage
                    exit 1
                fi
                APPLE_ID="$2"
                shift 2
            ;;
            --apple-id=*)
                APPLE_ID="${1#*=}"
                if [[ -z "${APPLE_ID}" ]]; then
                    echo "error: --apple-id requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --notary-password|--app-specific-password)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: $1 requires a value" >&2
                    usage
                    exit 1
                fi
                NOTARYTOOL_PASSWORD="$2"
                shift 2
            ;;
            --notary-password=*|--app-specific-password=*)
                NOTARYTOOL_PASSWORD="${1#*=}"
                if [[ -z "${NOTARYTOOL_PASSWORD}" ]]; then
                    echo "error: ${1%%=*} requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --skip-notarization)
                SKIP_NOTARIZATION="1"
                shift
            ;;
            --skip-spctl-assess)
                SPCTL_ASSESS="0"
                shift
            ;;
            --output-app)
                if [[ "$#" -lt 2 || -z "$2" ]]; then
                    echo "error: --output-app requires a value" >&2
                    usage
                    exit 1
                fi
                if [[ -n "${OUTPUT_APP_PATH}" ]]; then
                    echo "error: multiple output app paths specified" >&2
                    usage
                    exit 1
                fi
                OUTPUT_APP_PATH="$2"
                shift 2
            ;;
            --output-app=*)
                if [[ -n "${OUTPUT_APP_PATH}" ]]; then
                    echo "error: multiple output app paths specified" >&2
                    usage
                    exit 1
                fi
                OUTPUT_APP_PATH="${1#*=}"
                if [[ -z "${OUTPUT_APP_PATH}" ]]; then
                    echo "error: --output-app requires a value" >&2
                    usage
                    exit 1
                fi
                shift
            ;;
            --)
                shift
                break
            ;;
            -*)
                echo "error: unknown option: $1" >&2
                usage
                exit 1
            ;;
            *)
                if [[ -n "${OUTPUT_APP_PATH}" ]]; then
                    echo "error: multiple output app paths specified" >&2
                    usage
                    exit 1
                fi
                OUTPUT_APP_PATH="$1"
                shift
            ;;
        esac
    done

    while [[ "$#" -gt 0 ]]; do
        if [[ -n "${OUTPUT_APP_PATH}" ]]; then
            echo "error: multiple output app paths specified" >&2
            usage
            exit 1
        fi
        OUTPUT_APP_PATH="$1"
        shift
    done
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: missing command: $1" >&2
        exit 1
    fi
}

absolute_path() {
    local path="$1"
    if [[ "${path}" == /* ]]; then
        printf '%s\n' "${path}"
    else
        printf '%s\n' "${PROJECT_DIR}/${path}"
    fi
}

read_build_setting() {
    local name="$1"
    printf '%s\n' "${BUILD_SETTINGS}" |
        awk -F= -v key="${name}" '
          $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
          }
        '
}

read_plist_value() {
    local plist_path="$1"
    local key_path="$2"

    /usr/libexec/PlistBuddy -c "Print :${key_path}" "${plist_path}" 2>/dev/null || true
}

read_plist_compact_value() {
    local plist_path="$1"
    local key_path="$2"
    local raw_value=""

    if ! raw_value="$(/usr/libexec/PlistBuddy -c "Print :${key_path}" "${plist_path}" 2>/dev/null)"; then
        return 0
    fi

    printf '%s\n' "${raw_value}" |
        awk '
          /^[[:space:]]*(Array|Dict) \{$/ || /^[[:space:]]*\}$/ { next }
          {
            value = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value == "") next
            output = output separator value
            separator = ", "
          }
          END { if (output != "") print output }
        '
}

certificate_sha1() {
    local certificate_path="$1"

    shasum -a 1 "${certificate_path}" | awk '{print toupper($1)}'
}

supports_color() {
    [[ -t "$1" && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
}

validation_section() {
    printf '\n'
    if supports_color 1; then
        printf '  \033[1m%s\033[0m\n' "$1"
    else
        printf '  %s\n' "$1"
    fi
}

validation_field() {
    local label="$1"
    local value="${2:-none}"

    printf '    %-28s %s\n' "${label}:" "${value}"
}

validation_pass() {
    if supports_color 1; then
        printf '    \033[32m✓\033[0m %s\n' "$1"
    else
        printf '    ✓ %s\n' "$1"
    fi
}

validation_fail() {
    local check="$1"
    local reason="$2"
    local details="${3:-}"

    if supports_color 2; then
        printf '    \033[31m✗\033[0m %s\n' "${check}" >&2
    else
        printf '    ✗ %s\n' "${check}" >&2
    fi
    printf '      Reason: %s\n' "${reason}" >&2
    if [[ -n "${details}" ]]; then
        printf '%s\n' "${details}" | sed 's/^/      /' >&2
    fi
}

validation_skip() {
    printf '    - %s: skipped\n' "$1"
}

validation_summary() {
    printf '\n'
    if supports_color 1; then
        printf '  \033[1;32m✓ %s\033[0m\n' "$1"
    else
        printf '  ✓ %s\n' "$1"
    fi
}

source "${SCRIPT_DIR}/lib/validate.sh"

safe_remove_path() {
    local path="$1"
    local parent=""
    local resolved=""

    if [[ ! -e "${path}" ]]; then
        return
    fi

    parent="$(cd "$(dirname "${path}")" && pwd)"
    resolved="${parent}/$(basename "${path}")"

    validate_build_path "${resolved}"
    case "${resolved}" in
        "${BUILD_DIR}"/*)
            rm -rf "${resolved}"
        ;;
        *)
            echo "error: refusing to remove path outside build: ${resolved}" >&2
            exit 1
        ;;
    esac
}

validate_build_path() {
    local path="$1"
    local current=""
    local part=""
    local parts=()
    case "${path}" in
        "${PROJECT_DIR}/Build"|"${PROJECT_DIR}/Build/"*) ;;
        *) echo "error: build paths must be inside ${PROJECT_DIR}/Build: ${path}" >&2; exit 1 ;;
    esac
    IFS='/' read -r -a parts <<< "${path}"
    for part in "${parts[@]}"; do
        [[ -z "${part}" ]] && continue
        if [[ "${part}" == "." || "${part}" == ".." ]]; then
            echo "error: ambiguous build path: ${path}" >&2
            exit 1
        fi
        current="${current}/${part}"
        if [[ -L "${current}" ]]; then
            echo "error: build paths must not traverse symbolic links: ${current}" >&2
            exit 1
        fi
    done
}

clean_build_dir() {
    validate_build_path "${BUILD_DIR}"
    if [[ -e "${BUILD_DIR}" && ! -d "${BUILD_DIR}" ]]; then
        echo "error: build path exists but is not a directory: ${BUILD_DIR}" >&2
        exit 1
    fi
    echo "==> Cleaning build directory ${BUILD_DIR}"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
}

clean_intermediate_build_artifacts() {
    local output_parent=""
    local output_resolved=""
    local entry=""
    local entry_parent=""
    local entry_resolved=""

    output_parent="$(cd "$(dirname "${OUTPUT_APP_PATH}")" && pwd)"
    output_resolved="${output_parent}/$(basename "${OUTPUT_APP_PATH}")"

    echo "==> Cleaning intermediate build artifacts"
    while IFS= read -r -d '' entry; do
        entry_parent="$(cd "$(dirname "${entry}")" && pwd)"
        entry_resolved="${entry_parent}/$(basename "${entry}")"

        if [[ "${entry_resolved}" == "${output_resolved}" ]]; then
            continue
        fi

        case "${output_resolved}" in
            "${entry_resolved}"/*)
                continue
            ;;
        esac

        safe_remove_path "${entry_resolved}"
    done < <(find "${BUILD_DIR}" -mindepth 1 -maxdepth 1 -print0)
}

write_export_options() {
    local path="$1"

    {
        cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
PLIST
        if [[ -n "${TEAM_ID}" ]]; then
            cat <<PLIST
    <key>teamID</key>
    <string>${TEAM_ID}</string>
PLIST
        fi
        cat <<PLIST
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST
    } > "${path}"
}

configure_archive_signing() {
    local signing_style=""
    local signing_certificate=""
    local provisioning_profile=""
    local bundle_identifier=""

    signing_style="$(read_plist_value "${EXPORT_OPTIONS_PLIST}" signingStyle)"
    if [[ "${signing_style}" != "manual" ]]; then
        return
    fi

    bundle_identifier="$(read_build_setting PRODUCT_BUNDLE_IDENTIFIER)"
    if [[ -z "${bundle_identifier}" ]]; then
        echo "error: unable to read PRODUCT_BUNDLE_IDENTIFIER for manual signing" >&2
        exit 1
    fi

    signing_certificate="$(read_plist_value "${EXPORT_OPTIONS_PLIST}" signingCertificate)"
    provisioning_profile="$(
        read_plist_value \
            "${EXPORT_OPTIONS_PLIST}" \
            "provisioningProfiles:${bundle_identifier}"
    )"
    if [[ -z "${provisioning_profile}" ]]; then
        echo "error: manual export options do not specify a profile for ${bundle_identifier}" >&2
        exit 1
    fi

    # exportArchive 不会下载缺失的手动 profile, 在 archive 阶段解析才能触发 Xcode 账户同步
    ARCHIVE_SIGNING_FLAGS=(
    "CODE_SIGN_STYLE=Manual"
    "CODEXBAR_PROVISIONING_PROFILE_SPECIFIER=${provisioning_profile}"
    )
    if [[ -n "${signing_certificate}" ]]; then
        ARCHIVE_SIGNING_FLAGS+=("CODE_SIGN_IDENTITY=${signing_certificate}")
    fi

    echo "==> Resolving provisioning profile ${provisioning_profile} during archive"
}

parse_args "$@"

XCODE_PROJECT="$(absolute_path "${XCODE_PROJECT}")"
BUILD_DIR="$(absolute_path "${BUILD_DIR}")"

if [[ -z "${DERIVED_DATA_PATH}" ]]; then
    DERIVED_DATA_PATH="${BUILD_DIR}/DerivedData"
else
    DERIVED_DATA_PATH="$(absolute_path "${DERIVED_DATA_PATH}")"
fi

if [[ -z "${ARCHIVE_PATH}" ]]; then
    ARCHIVE_PATH="${BUILD_DIR}/${XCODE_SCHEME}.xcarchive"
else
    ARCHIVE_PATH="$(absolute_path "${ARCHIVE_PATH}")"
fi

if [[ -n "${EXPORT_OPTIONS_PLIST}" ]]; then
    EXPORT_OPTIONS_PLIST="$(absolute_path "${EXPORT_OPTIONS_PLIST}")"
fi

if [[ ! -d "${XCODE_PROJECT}" || "${XCODE_PROJECT}" != *.xcodeproj ]]; then
    echo "error: invalid Xcode project: ${XCODE_PROJECT}" >&2
    exit 1
fi

require_command xcodebuild
require_command ditto
require_command codesign
require_command lipo
require_command plutil
require_command security
require_command shasum
require_command base64

if [[ "${SKIP_NOTARIZATION}" != "1" ]]; then
    require_command xcrun
    if [[ "${SPCTL_ASSESS}" == "1" ]]; then
        require_command spctl
    fi
fi

validate_build_path "${BUILD_DIR}"
validate_build_path "${ARCHIVE_PATH}"
validate_build_path "${DERIVED_DATA_PATH}"
if [[ -n "${OUTPUT_APP_PATH}" ]]; then
    validate_build_path "$(absolute_path "${OUTPUT_APP_PATH}")"
fi
BUILD_LOCK="${PROJECT_DIR}/.codexbar-build.lock"
if ! mkdir "${BUILD_LOCK}" 2>/dev/null; then
    echo "error: build lock exists: ${BUILD_LOCK}; wait for the running build, or remove the stale lock after verifying no build is running" >&2
    exit 1
fi
TEMP_ROOT=""
cleanup() {
    [[ -z "${TEMP_ROOT}" ]] || rm -rf "${TEMP_ROOT}"
    rmdir "${BUILD_LOCK}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "${BUILD_DIR}" "$(dirname "${ARCHIVE_PATH}")" "${DERIVED_DATA_PATH}"
BUILD_DIR="$(cd "${BUILD_DIR}" && pwd)"
DERIVED_DATA_PATH="$(cd "${DERIVED_DATA_PATH}" && pwd)"

echo "==> Reading Xcode build settings"
BUILD_SETTINGS="$(
    xcodebuild \
        -project "${XCODE_PROJECT}" \
        -scheme "${XCODE_SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -destination "generic/platform=macOS" \
        -showBuildSettings
)"

PRODUCT_NAME="$(read_build_setting PRODUCT_NAME)"
FULL_PRODUCT_NAME="$(read_build_setting FULL_PRODUCT_NAME)"
DEVELOPMENT_TEAM="$(read_build_setting DEVELOPMENT_TEAM)"

if [[ -z "${TEAM_ID}" ]]; then
    TEAM_ID="${DEVELOPMENT_TEAM}"
fi

if [[ -z "${PRODUCT_NAME}" || "${PRODUCT_NAME}" == *'$('* ]]; then
    PRODUCT_NAME="${XCODE_SCHEME}"
fi

if [[ -z "${FULL_PRODUCT_NAME}" || "${FULL_PRODUCT_NAME}" == *'$('* ]]; then
    FULL_PRODUCT_NAME="${PRODUCT_NAME}.app"
fi

if [[ -z "${OUTPUT_APP_PATH}" ]]; then
    OUTPUT_APP_PATH="${BUILD_DIR}/${FULL_PRODUCT_NAME}"
else
    OUTPUT_APP_PATH="$(absolute_path "${OUTPUT_APP_PATH}")"
fi

if [[ "${OUTPUT_APP_PATH}" != *.app ]]; then
    echo "error: output path must end with .app: ${OUTPUT_APP_PATH}" >&2
    exit 1
fi

case "${OUTPUT_APP_PATH}" in
    "${BUILD_DIR}"/*) ;;
    *)
        echo "error: output app must be inside BUILD_DIR (${BUILD_DIR}): ${OUTPUT_APP_PATH}" >&2
        exit 1
    ;;
esac

TEMP_ROOT="$(mktemp -d "/private/tmp/${PRODUCT_NAME}BuildNotary.XXXXXX")"
EXPORT_DIR="${TEMP_ROOT}/export"
NOTARY_ZIP="${TEMP_ROOT}/${PRODUCT_NAME}-notary.zip"
GENERATED_EXPORT_OPTIONS="${TEMP_ROOT}/ExportOptions.plist"


if [[ -z "${EXPORT_OPTIONS_PLIST}" ]]; then
    EXPORT_OPTIONS_PLIST="${GENERATED_EXPORT_OPTIONS}"
    write_export_options "${EXPORT_OPTIONS_PLIST}"
elif [[ ! -f "${EXPORT_OPTIONS_PLIST}" ]]; then
    echo "error: export options plist not found: ${EXPORT_OPTIONS_PLIST}" >&2
    exit 1
fi

configure_archive_signing

PROVISIONING_FLAGS=()
if [[ "${ALLOW_PROVISIONING_UPDATES}" == "1" ]]; then
    PROVISIONING_FLAGS=(-allowProvisioningUpdates)
fi

NOTARY_AUTH_ARGS=()
if [[ "${SKIP_NOTARIZATION}" != "1" ]]; then
    if [[ -n "${NOTARYTOOL_PROFILE}" ]]; then
        NOTARY_AUTH_ARGS=(--keychain-profile "${NOTARYTOOL_PROFILE}")
    else
        if [[ -z "${APPLE_ID}" || -z "${NOTARYTOOL_PASSWORD}" || -z "${TEAM_ID}" ]]; then
            echo "error: set --notary-profile, or set --apple-id, --notary-password, and --team-id" >&2
            usage
            exit 1
        fi
        NOTARY_AUTH_ARGS=(--apple-id "${APPLE_ID}" --password "${NOTARYTOOL_PASSWORD}" --team-id "${TEAM_ID}")
    fi
fi

clean_build_dir
mkdir -p "$(dirname "${ARCHIVE_PATH}")" "${DERIVED_DATA_PATH}"

echo "==> Archiving ${XCODE_SCHEME} (${CONFIGURATION})"
xcodebuild \
    -project "${XCODE_PROJECT}" \
    -scheme "${XCODE_SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -archivePath "${ARCHIVE_PATH}" \
    "${PROVISIONING_FLAGS[@]+"${PROVISIONING_FLAGS[@]}"}" \
    "${ARCHIVE_SIGNING_FLAGS[@]+"${ARCHIVE_SIGNING_FLAGS[@]}"}" \
    archive

mkdir -p "${EXPORT_DIR}"

echo "==> Exporting Developer ID app"
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}" \
    "${PROVISIONING_FLAGS[@]+"${PROVISIONING_FLAGS[@]}"}"

EXPORTED_APP_PATH="${EXPORT_DIR}/${FULL_PRODUCT_NAME}"
if [[ ! -d "${EXPORTED_APP_PATH}" ]]; then
    exported_apps=()
    while IFS= read -r app; do
        exported_apps+=("${app}")
    done < <(find "${EXPORT_DIR}" -maxdepth 1 -type d -name "*.app" | sort)

    if [[ "${#exported_apps[@]}" -ne 1 ]]; then
        echo "error: unable to find a single exported app in ${EXPORT_DIR}" >&2
        printf '  %s\n' "${exported_apps[@]}" >&2
        exit 1
    fi

    EXPORTED_APP_PATH="${exported_apps[0]}"
fi

echo "==> Verifying exported app signature"
codesign --verify --deep --strict --verbose=2 "${EXPORTED_APP_PATH}"

if [[ "${SKIP_NOTARIZATION}" == "1" ]]; then
    echo "warning: --skip-notarization set, notary submission and stapling were skipped" >&2
else
    echo "==> Preparing notarization archive"
    ditto -c -k --keepParent "${EXPORTED_APP_PATH}" "${NOTARY_ZIP}"

    echo "==> Submitting notarization"
    xcrun notarytool submit "${NOTARY_ZIP}" --wait "${NOTARY_AUTH_ARGS[@]}"

    echo "==> Stapling notarization ticket"
    xcrun stapler staple "${EXPORTED_APP_PATH}"
    xcrun stapler validate "${EXPORTED_APP_PATH}"
fi

safe_remove_path "${OUTPUT_APP_PATH}"

echo "==> Copying app to ${OUTPUT_APP_PATH}"
mkdir -p "$(dirname "${OUTPUT_APP_PATH}")"
ditto "${EXPORTED_APP_PATH}" "${OUTPUT_APP_PATH}"

validate_final_app "${OUTPUT_APP_PATH}"

clean_intermediate_build_artifacts

echo "==> Built ${OUTPUT_APP_PATH}"
