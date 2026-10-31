#!/usr/bin/env bash
set -euo pipefail

# For builds below this threshold, provide patches from older branches when available
# Otherwise, prompt users to upgrade manually
#
# For incompatible releases, update both the build threshold and upgrade guide version
# Keep both values unchanged for subsequent compatible releases
readonly MINIMUM_COMPATIBLE_BUILD=200
readonly UPGRADE_GUIDE_VERSION=5.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${PROJECT_DIR}/Build}"

DMG_PATH="${1:-}"
APPCAST_PATH="${APPCAST_PATH:-${PROJECT_DIR}/appcast.xml}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://codexbar.zabrian.app/download}"
RELEASE_NOTES_BASE_URL="${RELEASE_NOTES_BASE_URL:-https://codexbar.zabrian.app/notes}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-15.0}"
INCLUDE_RELEASE_NOTES="${INCLUDE_RELEASE_NOTES:-1}"
SIGN_UPDATE="${SIGN_UPDATE:-}"

if [[ "${BUILD_DIR}" != /* ]]; then
    BUILD_DIR="${PROJECT_DIR}/${BUILD_DIR}"
fi

usage() {
    cat >&2 <<USAGE
usage: Scripts/appcast.sh [CodexBar-vX.Y.Z.dmg]

Environment:
  BUILD_DIR               Directory used for default DMG lookup.
                           Defaults to Build/.
  APPCAST_PATH            Path to appcast.xml. Defaults to appcast.xml.
  DOWNLOAD_BASE_URL       Base URL for DMG downloads.
                           Defaults to https://codexbar.zabrian.app/download.
  RELEASE_NOTES_BASE_URL  Base URL for release notes and upgrade guides.
                           Both links append lang=en-US and lang=zh-CN query parameters.
                           Release notes append the current version as #X.Y.Z.
                           The browser upgrade link appends #${UPGRADE_GUIDE_VERSION}-Guide.
                           Defaults to https://codexbar.zabrian.app/notes.
  INCLUDE_RELEASE_NOTES   Set to 0 to omit sparkle:releaseNotesLink.
  MINIMUM_SYSTEM_VERSION  Defaults to 15.0.
  SIGN_UPDATE             Optional path to Sparkle's sign_update tool.
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

# Print the single entry matching a glob in a directory, or fail
# $1 noun for "no X found" $2 find -type $3 -name glob
# $4 noun for "multiple X found" $5 hint appended to the multiple-match error
# $6 directory to search. Returns 1 when nothing matches, 2 when more than one
# matches (printing the list)
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

require_command diskutil
require_command perl
require_command stat

WORK_DIR="$(mktemp -d)"
MOUNT_POINT="${WORK_DIR}/volume"
APPCAST_TMP="${WORK_DIR}/appcast.xml"
DMG_MOUNTED=0

cleanup() {
    if [[ "${DMG_MOUNTED}" == "1" ]]; then
        if ! diskutil eject "${MOUNT_POINT}" >/dev/null; then
            echo "error: unable to unmount ${MOUNT_POINT}" >&2
            return
        fi
    fi
    rm -f "${APPCAST_TMP}"
    if [[ -d "${MOUNT_POINT}" ]]; then
        rmdir "${MOUNT_POINT}"
    fi
    rmdir "${WORK_DIR}"
}
trap cleanup EXIT

mkdir "${MOUNT_POINT}"
diskutil image attach --readOnly --mountOptions nobrowse --mountPoint "${MOUNT_POINT}" "${DMG_PATH}" >/dev/null
DMG_MOUNTED=1
APP_PATH="$(find_single App d '*.app' Apps 'package a single App:' "${MOUNT_POINT}")" || exit 1
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}" 2>/dev/null || true)"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}" 2>/dev/null || true)"
PRODUCT_NAME="$(basename "${APP_PATH}" .app)"
diskutil eject "${MOUNT_POINT}" >/dev/null
DMG_MOUNTED=0

if [[ -z "${SHORT_VERSION}" || -z "${BUILD_VERSION}" ]]; then
    echo "error: unable to read CFBundleShortVersionString or CFBundleVersion" >&2
    exit 1
fi

if [[ ! "${BUILD_VERSION}" =~ ^[1-9][0-9]*$ || ! "${MINIMUM_COMPATIBLE_BUILD}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: CFBundleVersion and MINIMUM_COMPATIBLE_BUILD must be positive integer build numbers" >&2
    echo "       configure MINIMUM_COMPATIBLE_BUILD in Scripts/appcast.sh" >&2
    exit 1
fi
if ! perl -e 'exit($ARGV[0] > $ARGV[1] ? 1 : 0)' "${MINIMUM_COMPATIBLE_BUILD}" "${BUILD_VERSION}"; then
    echo "error: MINIMUM_COMPATIBLE_BUILD must not exceed CFBundleVersion" >&2
    exit 1
fi

RELEASE_NOTES_URL_PREFIX="${RELEASE_NOTES_BASE_URL%/}"
if [[ ! "${RELEASE_NOTES_URL_PREFIX}" =~ ^https?://[^/?#[:space:]]+([/?#][^[:space:]]*)?$ ]]; then
    echo "error: release notes URL must be an absolute HTTP or HTTPS URL without whitespace" >&2
    exit 1
fi
if [[ "${RELEASE_NOTES_URL_PREFIX}" == *\?* ]]; then
    RELEASE_NOTES_URL_PREFIX+="&lang="
else
    RELEASE_NOTES_URL_PREFIX+="?lang="
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
SHORT_VERSION_ESCAPED="$(printf '%s' "${SHORT_VERSION}" | xml_escape)"

UPGRADE_GUIDE_XML=""
RELEASE_NOTES_XML=""
for NOTES_LANGUAGE in en-US zh-CN; do
    UPGRADE_GUIDE_URL_ESCAPED="$(printf '%s%s#%s-Guide' "${RELEASE_NOTES_URL_PREFIX}" "${NOTES_LANGUAGE}" "${UPGRADE_GUIDE_VERSION}" | xml_escape)"
    UPGRADE_GUIDE_XML+="<link xml:lang=\"${NOTES_LANGUAGE}\">${UPGRADE_GUIDE_URL_ESCAPED}</link>
            "
    if [[ "${INCLUDE_RELEASE_NOTES}" != "0" ]]; then
        RELEASE_NOTES_URL_ESCAPED="$(printf '%s%s#%s' "${RELEASE_NOTES_URL_PREFIX}" "${NOTES_LANGUAGE}" "${SHORT_VERSION}" | xml_escape)"
        RELEASE_NOTES_XML+="<sparkle:releaseNotesLink xml:lang=\"${NOTES_LANGUAGE}\">${RELEASE_NOTES_URL_ESCAPED}</sparkle:releaseNotesLink>
            "
    fi
done

APPCAST_ITEM="        <item>
            <title>${TITLE}</title>
            <sparkle:version>${BUILD_VERSION}</sparkle:version>
            <sparkle:shortVersionString>${SHORT_VERSION_ESCAPED}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM_ESCAPED}</sparkle:minimumSystemVersion>
            <sparkle:minimumAutoupdateVersion>${MINIMUM_COMPATIBLE_BUILD}</sparkle:minimumAutoupdateVersion>
            <sparkle:informationalUpdate><sparkle:belowVersion>${MINIMUM_COMPATIBLE_BUILD}</sparkle:belowVersion></sparkle:informationalUpdate>
            ${UPGRADE_GUIDE_XML}${RELEASE_NOTES_XML}<pubDate>${PUB_DATE}</pubDate>
            <enclosure url=\"${DOWNLOAD_URL_ESCAPED}\" sparkle:edSignature=\"${ED_SIGNATURE_ESCAPED}\" length=\"${ARCHIVE_LENGTH}\" type=\"application/octet-stream\"/>
        </item>"

echo "==> Updating appcast"
# Write through a temp file so a perl die leaves appcast.xml untouched
APPCAST_ITEM="${APPCAST_ITEM}" APPCAST_VERSION="${BUILD_VERSION}" perl -0p -e '
  my $item = $ENV{"APPCAST_ITEM"};
  my $version = $ENV{"APPCAST_VERSION"};
  my $before = () = /<item>/g;

  # Keep the (?!<\/item>) guards: a plain .*? spans item boundaries and would
  # also delete every entry above the one being replaced
  s/\n\s*<item>(?:(?!<\/item>).)*?<sparkle:version>\Q$version\E<\/sparkle:version>(?:(?!<\/item>).)*?<\/item>//sg;

  if (!s/(<language>.*?<\/language>)/$1\n$item/s) {
    die "Unable to find <language>...</language> insertion point\n";
  }

  my $after = () = /<item>/g;
  if ($after != $before && $after != $before + 1) {
    die "Unexpected appcast item count: before=$before after=$after\n";
  }
' "${APPCAST_PATH}" > "${APPCAST_TMP}"
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "${APPCAST_TMP}"
fi
cat "${APPCAST_TMP}" > "${APPCAST_PATH}"

echo "==> Added ${PRODUCT_NAME} ${SHORT_VERSION} (${BUILD_VERSION})"
echo "    ${APPCAST_PATH}"
echo "    ${DOWNLOAD_URL}"
