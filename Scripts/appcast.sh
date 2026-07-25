#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/build}"

DMG_PATH="${1:-}"
APPCAST_PATH="${APPCAST_PATH:-${PROJECT_DIR}/appcast.xml}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://codexbar.zabrian.app/download}"
RELEASE_NOTES_BASE_URL="${RELEASE_NOTES_BASE_URL:-https://codexbar.zabrian.app/notes}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-15.0}"
INCLUDE_RELEASE_NOTES="${INCLUDE_RELEASE_NOTES:-1}"
SIGN_UPDATE="${SIGN_UPDATE:-}"
XCODE_PROJECT="${XCODE_PROJECT:-}"
XCODE_SCHEME="${XCODE_SCHEME:-CodexBar}"

if [[ "${BUILD_DIR}" != /* ]]; then
    BUILD_DIR="${PROJECT_DIR}/${BUILD_DIR}"
fi

usage() {
    cat >&2 <<USAGE
usage: Scripts/appcast.sh [CodexBar-vX.Y.Z.dmg]

Environment:
  BUILD_DIR               Directory used for default DMG lookup.
                           Defaults to build/.
  APPCAST_PATH            Path to appcast.xml. Defaults to appcast.xml.
  DOWNLOAD_BASE_URL       Base URL for DMG downloads.
                           Defaults to https://codexbar.zabrian.app/download.
  RELEASE_NOTES_BASE_URL  Base URL for release notes. The version is appended
                           as a fragment anchor (BASE#X.Y.Z).
                           Defaults to https://codexbar.zabrian.app/notes.
  INCLUDE_RELEASE_NOTES   Set to 0 to omit sparkle:releaseNotesLink.
  MINIMUM_SYSTEM_VERSION  Defaults to 15.0.
  SIGN_UPDATE             Optional path to Sparkle's sign_update tool.
  XCODE_PROJECT           Optional .xcodeproj path.
  XCODE_SCHEME            Defaults to CodexBar.
USAGE
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: missing command: $1" >&2
        exit 1
    fi
}

xml_escape() {
    sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g'
}

read_build_setting() {
    local name="$1"
    printf '%s\n' "${BUILD_SETTINGS}" |
        awk -F= -v key="${name}" '
          $1 ~ key {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
          }
        '
}

# Print the single entry matching a glob in a directory, or fail:
# $1 noun for "no X found" $2 find -type $3 -name glob
# $4 noun for "multiple X found" $5 hint appended to the multiple-match error
# $6 directory to search. Exits 1 when nothing matches, 2 when more than one
# matches (printing the list).
find_single() {
    local search_dir="$6"
    local items=()

    if [[ ! -d "${search_dir}" ]]; then
        echo "error: search directory not found: ${search_dir}" >&2
        return 1
    fi

    while IFS= read -r item; do
        items+=("${item}")
    done < <(find "${search_dir}" -maxdepth 1 -type "$2" -name "$3" | sort)

    if [[ "${#items[@]}" -eq 0 ]]; then
        echo "error: no $1 found in ${search_dir}" >&2
        return 1
    fi

    if [[ "${#items[@]}" -gt 1 ]]; then
        echo "error: multiple $4 found; $5" >&2
        printf '  %s\n' "${items[@]}" >&2
        return 2
    fi

    printf '%s\n' "${items[0]}"
}

if [[ "${DMG_PATH}" == "-h" || "${DMG_PATH}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ -z "${DMG_PATH}" ]]; then
    DMG_PATH="$(find_single DMG f '*.dmg' DMGs 'specify one explicitly:' "${BUILD_DIR}")" || {
        [[ "$?" -eq 1 ]] && usage
        exit 1
    }
elif [[ "${DMG_PATH}" != /* ]]; then
    DMG_PATH="${PROJECT_DIR}/${DMG_PATH}"
fi

if [[ ! -f "${DMG_PATH}" || "${DMG_PATH}" != *.dmg ]]; then
    echo "error: invalid DMG path: ${DMG_PATH}" >&2
    exit 1
fi

if [[ "${APPCAST_PATH}" != /* ]]; then
    APPCAST_PATH="${PROJECT_DIR}/${APPCAST_PATH}"
fi

if [[ ! -f "${APPCAST_PATH}" ]]; then
    echo "error: appcast not found: ${APPCAST_PATH}" >&2
    exit 1
fi

if [[ -z "${XCODE_PROJECT}" ]]; then
    XCODE_PROJECT="$(find_single .xcodeproj d '*.xcodeproj' '.xcodeproj files' 'set XCODE_PROJECT' "${PROJECT_DIR}")" || exit 1
elif [[ "${XCODE_PROJECT}" != /* ]]; then
    XCODE_PROJECT="${PROJECT_DIR}/${XCODE_PROJECT}"
fi

require_command xcodebuild
require_command perl
require_command stat

BUILD_SETTINGS="$(
    xcodebuild \
        -project "${XCODE_PROJECT}" \
        -scheme "${XCODE_SCHEME}" \
        -configuration Release \
        -showBuildSettings 2>/dev/null
)"

SHORT_VERSION="$(read_build_setting MARKETING_VERSION)"
BUILD_VERSION="$(read_build_setting CURRENT_PROJECT_VERSION)"
PRODUCT_NAME="$(read_build_setting PRODUCT_NAME)"

if [[ -z "${SHORT_VERSION}" || -z "${BUILD_VERSION}" ]]; then
    echo "error: unable to read MARKETING_VERSION or CURRENT_PROJECT_VERSION" >&2
    exit 1
fi

if [[ -z "${PRODUCT_NAME}" || "${PRODUCT_NAME}" == '$(TARGET_NAME)' ]]; then
    PRODUCT_NAME="$(basename "${DMG_PATH}")"
    PRODUCT_NAME="${PRODUCT_NAME%%-v*}"
    PRODUCT_NAME="${PRODUCT_NAME%.dmg}"
fi

if [[ -z "${SIGN_UPDATE}" ]]; then
    if command -v sign_update >/dev/null 2>&1; then
        SIGN_UPDATE="$(command -v sign_update)"
    else
        SIGN_UPDATE="$(
            find "${HOME}/Library/Developer/Xcode/DerivedData" \
                -maxdepth 8 \
                -path "*/SourcePackages/artifacts/*sparkle*/Sparkle/bin/sign_update" \
                -type f \
                2>/dev/null |
                sort |
                tail -n 1
        )"
    fi
fi

if [[ -z "${SIGN_UPDATE}" || ! -x "${SIGN_UPDATE}" ]]; then
    echo "error: Sparkle sign_update not found; set SIGN_UPDATE=/path/to/sign_update" >&2
    exit 1
fi

echo "==> Signing update archive"
SIGN_OUTPUT="$("${SIGN_UPDATE}" "${DMG_PATH}")"
ED_SIGNATURE="$(
    printf '%s\n' "${SIGN_OUTPUT}" |
        sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' |
        head -n 1
)"
ARCHIVE_LENGTH="$(
    printf '%s\n' "${SIGN_OUTPUT}" |
        sed -n 's/.*length="\([^"]*\)".*/\1/p' |
        head -n 1
)"

if [[ -z "${ED_SIGNATURE}" ]]; then
    echo "error: unable to parse sparkle:edSignature from sign_update output" >&2
    printf '%s\n' "${SIGN_OUTPUT}" >&2
    exit 1
fi

if [[ -z "${ARCHIVE_LENGTH}" ]]; then
    ARCHIVE_LENGTH="$(stat -f%z "${DMG_PATH}")"
fi

DOWNLOAD_URL="${DOWNLOAD_BASE_URL%/}/$(basename "${DMG_PATH}")"
PUB_DATE="$(LC_ALL=C TZ=Asia/Shanghai date '+%a, %d %b %Y %H:%M:%S %z')"
TITLE="$(printf '%s %s' "${PRODUCT_NAME}" "${SHORT_VERSION}" | xml_escape)"
DOWNLOAD_URL_ESCAPED="$(printf '%s' "${DOWNLOAD_URL}" | xml_escape)"
ED_SIGNATURE_ESCAPED="$(printf '%s' "${ED_SIGNATURE}" | xml_escape)"
MIN_SYSTEM_ESCAPED="$(printf '%s' "${MINIMUM_SYSTEM_VERSION}" | xml_escape)"

RELEASE_NOTES_XML=""
if [[ "${INCLUDE_RELEASE_NOTES}" != "0" ]]; then
    RELEASE_NOTES_URL="${RELEASE_NOTES_BASE_URL%/}#${SHORT_VERSION}"
    RELEASE_NOTES_URL_ESCAPED="$(printf '%s' "${RELEASE_NOTES_URL}" | xml_escape)"
    RELEASE_NOTES_XML="<sparkle:releaseNotesLink>${RELEASE_NOTES_URL_ESCAPED}</sparkle:releaseNotesLink>
    "
fi

APPCAST_ITEM="        <item>
            <title>${TITLE}</title>
            <sparkle:version>${BUILD_VERSION}</sparkle:version>
            <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM_ESCAPED}</sparkle:minimumSystemVersion>
            ${RELEASE_NOTES_XML}        <pubDate>${PUB_DATE}</pubDate>
            <enclosure url=\"${DOWNLOAD_URL_ESCAPED}\" sparkle:edSignature=\"${ED_SIGNATURE_ESCAPED}\" length=\"${ARCHIVE_LENGTH}\" type=\"application/octet-stream\"/>
        </item>"

echo "==> Updating appcast"
# Write through a temp file so a perl die leaves appcast.xml untouched.
APPCAST_TMP="$(mktemp)"
trap 'rm -f "${APPCAST_TMP}"' EXIT
APPCAST_ITEM="${APPCAST_ITEM}" APPCAST_VERSION="${BUILD_VERSION}" perl -0p -e '
  my $item = $ENV{"APPCAST_ITEM"};
  my $version = $ENV{"APPCAST_VERSION"};
  my $before = () = /<item>/g;

  # Keep the (?!<\/item>) guards: a plain .*? spans item boundaries and would
  # also delete every entry above the one being replaced.
  s/\n\s*<item>(?:(?!<\/item>).)*?<sparkle:version>\Q$version\E<\/sparkle:version>(?:(?!<\/item>).)*?<\/item>//sg;

  if (!s/(<language>.*?<\/language>)/$1\n$item/s) {
    die "Unable to find <language>...</language> insertion point\n";
  }

  my $after = () = /<item>/g;
  if ($after != $before && $after != $before + 1) {
    die "Unexpected appcast item count: before=$before after=$after\n";
  }
' "${APPCAST_PATH}" > "${APPCAST_TMP}"
cat "${APPCAST_TMP}" > "${APPCAST_PATH}"

if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "${APPCAST_PATH}"
fi

echo "==> Added ${PRODUCT_NAME} ${SHORT_VERSION} (${BUILD_VERSION})"
echo "    ${APPCAST_PATH}"
echo "    ${DOWNLOAD_URL}"
