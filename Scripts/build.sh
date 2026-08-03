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

usage() {
    cat >&2 <<USAGE
usage: Scripts/build.sh [options] [Output.app]

Builds a Release archive, exports a Developer ID app, submits it to Apple
notarization, staples the ticket, validates the result, and writes the final app to build/

Options:
  --project PATH                 Xcode project. Defaults to CodexBar.xcodeproj.
  --scheme NAME                  Xcode scheme. Defaults to CodexBar.
  --configuration NAME           Xcode configuration. Defaults to Release.
  --build-dir DIR                Build output directory. Defaults to Build/.
                                  Cleaned before each build.
  --derived-data PATH            DerivedData path. Defaults to Build/DerivedData.
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
  Scripts/build.sh --export-options Scripts/DeveloperID.plist --no-provisioning-updates --notary-profile codexbar-notary
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

certificate_sha1() {
    local certificate_path="$1"

    shasum -a 1 "${certificate_path}" | awk '{print toupper($1)}'
}

print_indented() {
    sed 's/^/    /'
}

supports_color() {
    [[ -t "$1" && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]
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

validate_final_app() {
    local app_path="$1"
    local contents_path="${app_path}/Contents"
    local info_plist="${contents_path}/Info.plist"
    local executable_path="${contents_path}/MacOS/${PRODUCT_NAME}"
    local helper_path="${contents_path}/Resources/CodexBarHelper"
    local launch_daemons_path="${contents_path}/Library/LaunchDaemons"
    local embedded_profile="${contents_path}/embedded.provisionprofile"
    local validation_dir="${TEMP_ROOT}/validation"
    local main_entitlements="${validation_dir}/main-entitlements.plist"
    local helper_entitlements="${validation_dir}/helper-entitlements.plist"
    local profile_plist="${validation_dir}/embedded-profile.plist"
    local profile_decode_error="${validation_dir}/profile-decode-error.log"
    local profile_entitlements="${validation_dir}/profile-entitlements.plist"
    local signing_certificate_prefix="${validation_dir}/signing-certificate"
    local signing_certificate="${signing_certificate_prefix}0"
    local helper_signing_certificate_prefix="${validation_dir}/helper-signing-certificate"
    local helper_signing_certificate="${helper_signing_certificate_prefix}0"
    local bundle_identifier=""
    local display_name=""
    local short_version=""
    local build_version=""
    local minimum_system_version=""
    local ui_element=""
    local architectures=""
    local helper_architectures=""
    local architecture=""
    local command_output=""
    local signature_details=""
    local helper_signature_details=""
    local signature_identifier=""
    local helper_signature_identifier=""
    local signing_authority=""
    local signing_timestamp=""
    local signing_team=""
    local helper_signing_team=""
    local signing_cdhash=""
    local signing_certificate_sha1=""
    local helper_signing_certificate_sha1=""
    local expected_signing_certificate=""
    local normalized_expected_certificate=""
    local main_application_identifier=""
    local helper_application_identifier=""
    local debugger_entitlement=""
    local helper_debugger_entitlement=""
    local icloud_containers=""
    local launch_daemon_count="0"
    local launch_daemon_plist=""
    local launch_daemon_label=""
    local launch_daemon_bundle_identifier=""
    local launch_daemon_program=""
    local profile_name=""
    local profile_uuid=""
    local profile_team=""
    local profile_application_identifier=""
    local profile_expiration=""
    local profile_certificate_count="0"
    local profile_certificate_index="0"
    local profile_certificate_path=""
    local profile_certificate_sha1=""
    local profile_certificate_match_count="0"
    local expected_profile=""
    local gatekeeper_source=""

    echo "==> Validating final app"

    if [[ ! -d "${app_path}" || ! -f "${info_plist}" || ! -x "${executable_path}" ]]; then
        validation_fail "App bundle structure" "Missing app directory, Info.plist, or executable at ${app_path}"
        return 1
    fi
    validation_pass "App bundle structure"

    if [[ ! -x "${helper_path}" ]]; then
        validation_fail "Embedded helper" "Executable helper not found at ${helper_path}"
        return 1
    fi
    validation_pass "Embedded helper"

    mkdir -p "${validation_dir}"

    bundle_identifier="$(read_plist_value "${info_plist}" CFBundleIdentifier)"
    display_name="$(read_plist_value "${info_plist}" CFBundleDisplayName)"
    short_version="$(read_plist_value "${info_plist}" CFBundleShortVersionString)"
    build_version="$(read_plist_value "${info_plist}" CFBundleVersion)"
    minimum_system_version="$(read_plist_value "${info_plist}" LSMinimumSystemVersion)"
    ui_element="$(read_plist_value "${info_plist}" LSUIElement)"

    if [[ -z "${bundle_identifier}" || -z "${short_version}" || -z "${build_version}" ]]; then
        validation_fail "Required bundle metadata" "CFBundleIdentifier, CFBundleShortVersionString, or CFBundleVersion is missing"
        return 1
    fi
    validation_pass "Required bundle metadata"

    if ! architectures="$(lipo -archs "${executable_path}" 2>&1)"; then
        validation_fail "App architectures" "lipo could not inspect the main executable" "${architectures}"
        return 1
    fi
    validation_pass "App architectures: ${architectures}"

    if ! helper_architectures="$(lipo -archs "${helper_path}" 2>&1)"; then
        validation_fail "Helper architectures" "lipo could not inspect the helper executable" "${helper_architectures}"
        return 1
    fi
    validation_pass "Helper architectures: ${helper_architectures}"

    echo "  Bundle"
    printf '    Path: %s\n' "${app_path}"
    printf '    Display name: %s\n' "${display_name}"
    printf '    Bundle identifier: %s\n' "${bundle_identifier}"
    printf '    Version: %s (%s)\n' "${short_version}" "${build_version}"
    printf '    Minimum macOS: %s\n' "${minimum_system_version}"
    printf '    LSUIElement: %s\n' "${ui_element}"
    printf '    Architectures: %s\n' "${architectures}"

    if ! command_output="$(codesign --verify --deep --strict --verbose=4 "${app_path}" 2>&1)"; then
        validation_fail "Deep strict app signature" "codesign rejected the app bundle" "${command_output}"
        return 1
    fi
    echo "  Code signature"
    validation_pass "Deep strict app signature"

    for architecture in ${architectures}; do
        if ! command_output="$(codesign --verify --strict --verbose=4 --arch "${architecture}" "${app_path}" 2>&1)"; then
            validation_fail "App ${architecture} signature" "codesign rejected the ${architecture} slice" "${command_output}"
            return 1
        fi
        validation_pass "App ${architecture} signature"
    done

    if ! command_output="$(codesign --verify --strict --verbose=4 "${helper_path}" 2>&1)"; then
        validation_fail "Helper signature" "codesign rejected the helper executable" "${command_output}"
        return 1
    fi
    printf '    Helper architectures: %s\n' "${helper_architectures}"
    validation_pass "Helper signature"

    for architecture in ${helper_architectures}; do
        if ! command_output="$(codesign --verify --strict --verbose=4 --arch "${architecture}" "${helper_path}" 2>&1)"; then
            validation_fail "Helper ${architecture} signature" "codesign rejected the helper ${architecture} slice" "${command_output}"
            return 1
        fi
        validation_pass "Helper ${architecture} signature"
    done

    if ! signature_details="$(codesign -d --verbose=4 "${app_path}" 2>&1)"; then
        validation_fail "App signature metadata" "codesign could not read the app signature" "${signature_details}"
        return 1
    fi

    if ! helper_signature_details="$(codesign -d --verbose=4 "${helper_path}" 2>&1)"; then
        validation_fail "Helper signature metadata" "codesign could not read the helper signature" "${helper_signature_details}"
        return 1
    fi

    signature_identifier="$(printf '%s\n' "${signature_details}" | awk -F= '/^Identifier=/ {print $2; exit}')"
    helper_signature_identifier="$(printf '%s\n' "${helper_signature_details}" | awk -F= '/^Identifier=/ {print $2; exit}')"
    signing_authority="$(printf '%s\n' "${signature_details}" | awk -F= '/^Authority=/ {print substr($0, index($0, "=") + 1); exit}')"
    signing_timestamp="$(printf '%s\n' "${signature_details}" | awk -F= '/^Timestamp=/ {print substr($0, index($0, "=") + 1); exit}')"
    signing_team="$(printf '%s\n' "${signature_details}" | awk -F= '/^TeamIdentifier=/ {print $2; exit}')"
    helper_signing_team="$(printf '%s\n' "${helper_signature_details}" | awk -F= '/^TeamIdentifier=/ {print $2; exit}')"
    signing_cdhash="$(printf '%s\n' "${signature_details}" | awk -F= '/^CDHash=/ {print $2; exit}')"

    if [[ "${signature_identifier}" != "${bundle_identifier}" ||
        "${helper_signature_identifier}" != "${bundle_identifier}.helper" ||
        -z "${signing_team}" || "${helper_signing_team}" != "${signing_team}" ]]; then
        validation_fail \
            "Code signature identifiers" \
            "Expected app ${bundle_identifier}, helper ${bundle_identifier}.helper, and one shared team; got app ${signature_identifier}, helper ${helper_signature_identifier}, teams ${signing_team:-none}/${helper_signing_team:-none}"
        return 1
    fi
    validation_pass "Code signature identifiers"

    if ! printf '%s\n' "${signature_details}" | grep -Eq '^CodeDirectory .*flags=.*\(runtime\)'; then
        validation_fail "App Hardened Runtime" "The app CodeDirectory does not contain the runtime flag"
        return 1
    fi
    validation_pass "App Hardened Runtime"

    if ! printf '%s\n' "${helper_signature_details}" | grep -Eq '^CodeDirectory .*flags=.*\(runtime\)'; then
        validation_fail "Helper Hardened Runtime" "The helper CodeDirectory does not contain the runtime flag"
        return 1
    fi
    validation_pass "Helper Hardened Runtime"

    if ! codesign --display --extract-certificates="${signing_certificate_prefix}" "${app_path}" >/dev/null 2>&1 || [[ ! -f "${signing_certificate}" ]]; then
        validation_fail "App signing certificate" "codesign could not extract the app leaf certificate"
        return 1
    fi

    if ! codesign --display --extract-certificates="${helper_signing_certificate_prefix}" "${helper_path}" >/dev/null 2>&1 || [[ ! -f "${helper_signing_certificate}" ]]; then
        validation_fail "Helper signing certificate" "codesign could not extract the helper leaf certificate"
        return 1
    fi

    if ! signing_certificate_sha1="$(certificate_sha1 "${signing_certificate}")"; then
        validation_fail "App signing certificate" "Unable to calculate the app certificate SHA-1"
        return 1
    fi

    if ! helper_signing_certificate_sha1="$(certificate_sha1 "${helper_signing_certificate}")"; then
        validation_fail "Helper signing certificate" "Unable to calculate the helper certificate SHA-1"
        return 1
    fi

    if [[ "${helper_signing_certificate_sha1}" != "${signing_certificate_sha1}" ]]; then
        validation_fail \
            "App and helper certificate match" \
            "App uses ${signing_certificate_sha1}, helper uses ${helper_signing_certificate_sha1}"
        return 1
    fi
    validation_pass "App and helper certificate match"

    printf '    Identifier: %s\n' "${signature_identifier}"
    printf '    Helper identifier: %s\n' "${helper_signature_identifier}"
    printf '    Authority: %s\n' "${signing_authority}"
    printf '    Team identifier: %s\n' "${signing_team}"
    printf '    Certificate SHA-1: %s\n' "${signing_certificate_sha1}"
    printf '    Helper certificate SHA-1: %s\n' "${helper_signing_certificate_sha1}"
    printf '    Timestamp: %s\n' "${signing_timestamp:-none}"
    printf '    CDHash: %s\n' "${signing_cdhash}"

    expected_signing_certificate="$(read_plist_value "${EXPORT_OPTIONS_PLIST}" signingCertificate)"
    normalized_expected_certificate="$(printf '%s' "${expected_signing_certificate}" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
    if [[ "${normalized_expected_certificate}" =~ ^[0-9A-F]{40}$ ]]; then
        if [[ "${signing_certificate_sha1}" != "${normalized_expected_certificate}" ]]; then
            validation_fail \
                "Export certificate match" \
                "ExportOptions requires ${normalized_expected_certificate}, app uses ${signing_certificate_sha1}"
            return 1
        fi
        validation_pass "Export certificate match"
    elif [[ -n "${expected_signing_certificate}" ]]; then
        printf '    Export certificate selector: %s\n' "${expected_signing_certificate}"
    fi

    if ! codesign --display --entitlements="${main_entitlements}" --xml "${app_path}" >/dev/null 2>&1 || [[ ! -s "${main_entitlements}" ]]; then
        validation_fail "App entitlements" "codesign did not return an app entitlements plist"
        return 1
    fi
    validation_pass "App entitlements extracted"

    if ! codesign --display --entitlements="${helper_entitlements}" --xml "${helper_path}" >/dev/null 2>&1 || [[ ! -s "${helper_entitlements}" ]]; then
        validation_fail "Helper entitlements" "codesign did not return a helper entitlements plist"
        return 1
    fi
    validation_pass "Helper entitlements extracted"

    main_application_identifier="$(read_plist_value "${main_entitlements}" com.apple.application-identifier)"
    helper_application_identifier="$(read_plist_value "${helper_entitlements}" com.apple.application-identifier)"
    debugger_entitlement="$(read_plist_value "${main_entitlements}" com.apple.security.get-task-allow)"
    helper_debugger_entitlement="$(read_plist_value "${helper_entitlements}" com.apple.security.get-task-allow)"
    icloud_containers="$(read_plist_value "${main_entitlements}" com.apple.developer.icloud-container-identifiers)"

    if [[ "${main_application_identifier}" != "${signing_team}.${bundle_identifier}" ||
        "${helper_application_identifier}" != "${signing_team}.${bundle_identifier}.helper" ]]; then
        validation_fail \
            "Entitlement application identifiers" \
            "Expected ${signing_team}.${bundle_identifier} and ${signing_team}.${bundle_identifier}.helper; got ${main_application_identifier:-none} and ${helper_application_identifier:-none}"
        return 1
    fi
    validation_pass "Entitlement application identifiers"

    if [[ "${CONFIGURATION}" == "Release" &&
        ("${debugger_entitlement}" == "true" || "${debugger_entitlement}" == "1" ||
        "${helper_debugger_entitlement}" == "true" || "${helper_debugger_entitlement}" == "1") ]]; then
        validation_fail \
            "Release debugger attachment" \
            "get-task-allow is enabled for app=${debugger_entitlement:-false}, helper=${helper_debugger_entitlement:-false}"
        return 1
    fi

    echo "  App entitlements"
    if ! command_output="$(plutil -p "${main_entitlements}" 2>&1)"; then
        validation_fail "App entitlements" "Unable to display app entitlements" "${command_output}"
        return 1
    fi
    printf '%s\n' "${command_output}" | print_indented
    if [[ "${debugger_entitlement}" == "true" || "${debugger_entitlement}" == "1" ]]; then
        validation_pass "App debugger attachment: allowed"
    else
        validation_pass "App debugger attachment: disabled"
    fi

    echo "  Helper entitlements"
    if ! command_output="$(plutil -p "${helper_entitlements}" 2>&1)"; then
        validation_fail "Helper entitlements" "Unable to display helper entitlements" "${command_output}"
        return 1
    fi
    printf '%s\n' "${command_output}" | print_indented
    if [[ "${helper_debugger_entitlement}" == "true" || "${helper_debugger_entitlement}" == "1" ]]; then
        validation_pass "Helper debugger attachment: allowed"
    else
        validation_pass "Helper debugger attachment: disabled"
    fi

    if [[ ! -d "${launch_daemons_path}" ]]; then
        validation_fail "LaunchDaemon directory" "Missing ${launch_daemons_path}"
        return 1
    fi

    if ! command_output="$(find "${launch_daemons_path}" -maxdepth 1 -type f -name '*.plist' 2>&1)"; then
        validation_fail "LaunchDaemon plist discovery" "Unable to read ${launch_daemons_path}" "${command_output}"
        return 1
    fi
    launch_daemon_count="$(printf '%s\n' "${command_output}" | awk 'NF {count++} END {print count + 0}')"
    launch_daemon_plist="$(printf '%s\n' "${command_output}" | sort | sed -n '1p')"
    if [[ "${launch_daemon_count}" -ne 1 || -z "${launch_daemon_plist}" ]]; then
        validation_fail "LaunchDaemon plist count" "Expected exactly 1 plist, found ${launch_daemon_count}"
        return 1
    fi

    launch_daemon_label="$(read_plist_value "${launch_daemon_plist}" Label)"
    launch_daemon_bundle_identifier="$(read_plist_value "${launch_daemon_plist}" AssociatedBundleIdentifiers:0)"
    launch_daemon_program="$(read_plist_value "${launch_daemon_plist}" BundleProgram)"
    if [[ "${launch_daemon_label}" != "${bundle_identifier}.helper" ||
        "${launch_daemon_bundle_identifier}" != "${bundle_identifier}" ||
        "${launch_daemon_program}" != "Contents/Resources/CodexBarHelper" ]]; then
        validation_fail \
            "LaunchDaemon configuration" \
            "Expected label ${bundle_identifier}.helper, bundle ${bundle_identifier}, and program Contents/Resources/CodexBarHelper; got ${launch_daemon_label:-none}, ${launch_daemon_bundle_identifier:-none}, ${launch_daemon_program:-none}"
        return 1
    fi
    validation_pass "LaunchDaemon configuration"

    echo "  LaunchDaemon"
    printf '    File: %s\n' "$(basename "${launch_daemon_plist}")"
    printf '    Label: %s\n' "${launch_daemon_label}"
    printf '    Associated bundle: %s\n' "${launch_daemon_bundle_identifier}"
    printf '    Program: %s\n' "${launch_daemon_program}"

    if [[ -f "${embedded_profile}" ]]; then
        if ! security cms -D -i "${embedded_profile}" > "${profile_plist}" 2> "${profile_decode_error}"; then
            validation_fail \
                "Embedded provisioning profile" \
                "security cms could not decode embedded.provisionprofile" \
                "$(< "${profile_decode_error}")"
            return 1
        fi
        validation_pass "Embedded provisioning profile decoded"

        profile_name="$(read_plist_value "${profile_plist}" Name)"
        profile_uuid="$(read_plist_value "${profile_plist}" UUID)"
        profile_team="$(read_plist_value "${profile_plist}" TeamIdentifier:0)"
        profile_application_identifier="$(read_plist_value "${profile_plist}" Entitlements:com.apple.application-identifier)"
        profile_expiration="$(read_plist_value "${profile_plist}" ExpirationDate)"
        if ! profile_certificate_count="$(
            plutil -extract DeveloperCertificates xml1 -o - "${profile_plist}" |
                awk '{line = $0; while (match(line, /<data>/)) {count++; line = substr(line, RSTART + RLENGTH)}} END {print count + 0}'
        )"; then
            validation_fail "Profile certificates" "DeveloperCertificates is missing or malformed"
            return 1
        fi

        if [[ "${profile_application_identifier}" != "${main_application_identifier}" || "${profile_team}" != "${signing_team}" ]]; then
            validation_fail \
                "Profile signature identity" \
                "Expected application ${main_application_identifier} and team ${signing_team}; got ${profile_application_identifier:-none} and ${profile_team:-none}"
            return 1
        fi
        validation_pass "Profile signature identity"

        if [[ "${profile_certificate_count}" -lt 1 ]]; then
            validation_fail "Profile certificates" "DeveloperCertificates contains no signing certificates"
            return 1
        fi

        echo "  Provisioning profile"
        printf '    Name: %s\n' "${profile_name}"
        printf '    UUID: %s\n' "${profile_uuid}"
        printf '    Team identifier: %s\n' "${profile_team}"
        printf '    Application identifier: %s\n' "${profile_application_identifier}"
        printf '    Expiration: %s\n' "${profile_expiration}"
        printf '    Authorized certificates: %s\n' "${profile_certificate_count}"

        for ((profile_certificate_index = 0; profile_certificate_index < profile_certificate_count; profile_certificate_index++)); do
            profile_certificate_path="${validation_dir}/profile-certificate-${profile_certificate_index}.der"
            if ! plutil -extract "DeveloperCertificates.${profile_certificate_index}" raw -o - "${profile_plist}" |
                base64 -D > "${profile_certificate_path}"; then
                validation_fail \
                    "Profile certificate $((profile_certificate_index + 1))" \
                    "Unable to decode the certificate from DeveloperCertificates"
                return 1
            fi
            if ! profile_certificate_sha1="$(certificate_sha1 "${profile_certificate_path}")"; then
                validation_fail \
                    "Profile certificate $((profile_certificate_index + 1))" \
                    "Unable to calculate the certificate SHA-1"
                return 1
            fi
            printf '    Certificate %s SHA-1: %s\n' "$((profile_certificate_index + 1))" "${profile_certificate_sha1}"
            if [[ "${profile_certificate_sha1}" == "${signing_certificate_sha1}" ]]; then
                profile_certificate_match_count=$((profile_certificate_match_count + 1))
            fi
        done
        validation_pass "Profile certificates decoded"

        if [[ "${profile_certificate_match_count}" -lt 1 ]]; then
            validation_fail \
                "App certificate authorization" \
                "App certificate ${signing_certificate_sha1} is not listed in the embedded profile"
            return 1
        fi
        validation_pass "App certificate authorization"

        expected_profile="$(read_plist_value "${EXPORT_OPTIONS_PLIST}" "provisioningProfiles:${bundle_identifier}")"
        if [[ -n "${expected_profile}" ]]; then
            if [[ "${expected_profile}" != "${profile_uuid}" && "${expected_profile}" != "${profile_name}" ]]; then
                validation_fail \
                    "Export profile match" \
                    "ExportOptions requires ${expected_profile}, embedded profile is ${profile_name} (${profile_uuid})"
                return 1
            fi
            validation_pass "Export profile match"
        fi

        if ! command_output="$(plutil -extract Entitlements xml1 -o "${profile_entitlements}" "${profile_plist}" 2>&1)"; then
            validation_fail "Profile entitlements" "Unable to extract authorized entitlements" "${command_output}"
            return 1
        fi
        echo "    Authorized entitlements"
        if ! command_output="$(plutil -p "${profile_entitlements}" 2>&1)"; then
            validation_fail "Profile entitlements" "Unable to display authorized entitlements" "${command_output}"
            return 1
        fi
        printf '%s\n' "${command_output}" | print_indented
        validation_pass "Profile entitlements"
    elif [[ -n "${icloud_containers}" ]]; then
        validation_fail "Embedded provisioning profile" "CloudKit entitlements require embedded.provisionprofile"
        return 1
    else
        validation_pass "Provisioning profile not required"
    fi

    if [[ "${SKIP_NOTARIZATION}" == "1" ]]; then
        validation_skip "Notarization ticket"
        validation_skip "Gatekeeper assessment"
    else
        if ! command_output="$(xcrun stapler validate "${app_path}" 2>&1)"; then
            validation_fail "Notarization ticket" "stapler could not validate the ticket" "${command_output}"
            return 1
        fi
        validation_pass "Notarization ticket"

        if [[ "${SPCTL_ASSESS}" == "1" ]]; then
            if ! command_output="$(spctl --assess --type execute --verbose=4 "${app_path}" 2>&1)"; then
                validation_fail "Gatekeeper assessment" "spctl rejected the app" "${command_output}"
                return 1
            fi
            gatekeeper_source="$(printf '%s\n' "${command_output}" | awk -F= '/^source=/ {print substr($0, index($0, "=") + 1); exit}')"
            validation_pass "Gatekeeper assessment"
            printf '    Gatekeeper source: %s\n' "${gatekeeper_source}"
        else
            validation_skip "Gatekeeper assessment"
        fi
    fi

    validation_pass "Final app validation passed"
}

safe_remove_path() {
    local path="$1"
    local parent=""
    local resolved=""

    if [[ ! -e "${path}" ]]; then
        return
    fi

    parent="$(cd "$(dirname "${path}")" && pwd)"
    resolved="${parent}/$(basename "${path}")"

    case "${resolved}" in
        "${BUILD_DIR}"/*|/private/tmp/*)
            rm -rf "${resolved}"
        ;;
        *)
            echo "error: refusing to remove path outside build or /private/tmp: ${resolved}" >&2
            exit 1
        ;;
    esac
}

clean_build_dir() {
    case "${BUILD_DIR}" in
        *"/.."*|*"../"*|"..")
            echo "error: refusing to clean build path containing '..': ${BUILD_DIR}" >&2
            exit 1
        ;;
        "${PROJECT_DIR}"|"${PROJECT_DIR}/"|"${PROJECT_DIR}/.git"|\
            "${PROJECT_DIR}/.github"|"${PROJECT_DIR}/CodexBar"|\
            "${PROJECT_DIR}/Docs"|"${PROJECT_DIR}/Images"|\
            "${PROJECT_DIR}/Scripts")
            echo "error: refusing to clean protected project path: ${BUILD_DIR}" >&2
            exit 1
        ;;
        "${PROJECT_DIR}"/*|/private/tmp/*)
        ;;
        *)
            echo "error: refusing to clean build directory outside project or /private/tmp: ${BUILD_DIR}" >&2
            exit 1
        ;;
    esac

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

cleanup() {
    rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

if [[ -z "${EXPORT_OPTIONS_PLIST}" ]]; then
    EXPORT_OPTIONS_PLIST="${GENERATED_EXPORT_OPTIONS}"
    write_export_options "${EXPORT_OPTIONS_PLIST}"
elif [[ ! -f "${EXPORT_OPTIONS_PLIST}" ]]; then
    echo "error: export options plist not found: ${EXPORT_OPTIONS_PLIST}" >&2
    exit 1
fi

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
echo "==> Next: Scripts/dmg.sh \"${OUTPUT_APP_PATH}\""
