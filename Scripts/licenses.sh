#!/usr/bin/env bash
set -euo pipefail

# Download licenses at the commits pinned in Package.resolved and combine them in ThirdPartyLicenses.txt

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_RESOLVED="${PROJECT_DIR}/CodexBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
OUTPUT="${PROJECT_DIR}/CodexBar/Resources/ThirdPartyLicenses.txt"
PACKAGE_IDS=(swift-tree-sitter tree-sitter tree-sitter-bash sparkle)
SOURCES=()
VERSIONS=()
REVISIONS=()

fail() {
    echo "error: $*" >&2
    exit 1
}

read_value() {
    local value
    if ! value="$(plutil -extract "$1" raw -expect "${2:-string}" -o - "${PACKAGE_RESOLVED}" 2>&1)"; then
        fail "Cannot read $1 from Package.resolved: ${value}"
    fi
    printf '%s' "${value}"
}

package_index() {
    local index
    for index in "${!PACKAGE_IDS[@]}"; do
        if [[ "${PACKAGE_IDS[index]}" == "$1" ]]; then
            printf '%s' "${index}"
            return
        fi
    done
    fail "Add license sources for new package '$1' in Scripts/licenses.sh"
}

[[ "$#" -eq 0 ]] || fail "Usage: Scripts/licenses.sh (no arguments)"
[[ "$(read_value version integer)" == "3" ]] || fail "Expected Package.resolved format version 3"
pin_count="$(read_value pins array)"

for ((pin_index = 0; pin_index < pin_count; pin_index++)); do
    identity="$(read_value "pins.${pin_index}.identity")"
    index="$(package_index "${identity}")"
    [[ -z "${SOURCES[index]-}" ]] || fail "Duplicate package: ${identity}"
    [[ "$(read_value "pins.${pin_index}.kind")" == "remoteSourceControl" ]] || fail "Expected a Git source for ${identity}"

    source="$(read_value "pins.${pin_index}.location")"
    source="${source%/}"
    source="${source%.git}"
    version="$(read_value "pins.${pin_index}.state.version")"
    revision="$(read_value "pins.${pin_index}.state.revision")"
    [[ "${source}" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Expected a public GitHub source for ${identity}"
    [[ -n "${version}" && "${version}" != *$'\n'* && "${version}" != *$'\r'* ]] || fail "Invalid version for ${identity}"
    [[ "${revision}" =~ ^[0-9a-f]{40}$ ]] || fail "Expected a pinned Git revision for ${identity}"
    SOURCES[index]="${source}"
    VERSIONS[index]="${version}"
    REVISIONS[index]="${revision}"
done

for index in "${!PACKAGE_IDS[@]}"; do
    [[ -n "${SOURCES[index]-}" ]] || fail "Remove license sources for missing package '${PACKAGE_IDS[index]}' in Scripts/licenses.sh"
done

# Remove temporary files and directories on failure, keeping the existing license file
WORK_DIR="$(mktemp -d "${OUTPUT%/*}/.third-party-licenses.XXXXXX")"
TEMP_OUTPUT="${WORK_DIR}/licenses"
DOWNLOAD_PATH="${WORK_DIR}/download"
cleanup() {
    rm -f "${TEMP_OUTPUT}" "${DOWNLOAD_PATH}"
    rmdir "${WORK_DIR}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

append_license() {
    local identity="$1" title="$2" license_path="$3" version_prefix="${4:-}"
    local index source version revision repository body width
    index="$(package_index "${identity}")"
    source="${SOURCES[index]}"
    version="${VERSIONS[index]}"
    revision="${REVISIONS[index]}"
    repository="${source#https://github.com/}"

    echo "Fetching ${title} (${version})"
    curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 30 --retry 1 --retry-max-time 65 \
        --output "${DOWNLOAD_PATH}" \
        "https://raw.githubusercontent.com/${repository}/${revision}/${license_path}"
    body="$(sed $'s/[ \t\r]*$//' "${DOWNLOAD_PATH}")"
    [[ -n "${body}" ]] || fail "Empty license for ${title}"

    width="${#title}"
    # Git treats a separator of seven equals signs as a conflict marker
    ((width >= 8)) || width=8
    {
        if [[ -s "${TEMP_OUTPUT}" ]]; then
            printf '\n\n'
        fi
        printf '%s\n' "${title}"
        printf '%*s\n' "${width}" '' | tr ' ' '='
        printf '\nVersion: %s%s\n' "${version_prefix}" "${version}"
        printf 'Source: %s\n' "${source}"
        printf 'License: %s/blob/%s/%s\n\n' "${source}" "${revision}" "${license_path}"
        printf '%s\n' "${body}"
    } >> "${TEMP_OUTPUT}"
}

append_license swift-tree-sitter SwiftTreeSitter LICENSE
append_license tree-sitter Tree-sitter LICENSE
append_license tree-sitter-bash tree-sitter-bash LICENSE
# Include the separate notice for Unicode content bundled with Tree-sitter
append_license tree-sitter 'Unicode data used by Tree-sitter' lib/src/unicode/LICENSE 'Bundled with Tree-sitter '
append_license sparkle Sparkle LICENSE

if [[ -f "${OUTPUT}" ]] && cmp -s "${TEMP_OUTPUT}" "${OUTPUT}"; then
    echo "ThirdPartyLicenses.txt is already up to date"
    exit 0
fi

if [[ -f "${OUTPUT}" ]]; then
    chmod "$(stat -f '%Lp' "${OUTPUT}")" "${TEMP_OUTPUT}"
else
    chmod 644 "${TEMP_OUTPUT}"
fi
mv -f "${TEMP_OUTPUT}" "${OUTPUT}"
echo "Updated CodexBar/Resources/ThirdPartyLicenses.txt"
