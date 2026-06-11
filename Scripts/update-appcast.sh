#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DMG_PATH="${1:-}"
APPCAST_PATH="${APPCAST_PATH:-${PROJECT_DIR}/Updates/appcast.xml}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL:-https://codexbar.zabrian.app/download}"
RELEASE_NOTES_BASE_URL="${RELEASE_NOTES_BASE_URL:-https://codexbar.zabrian.app/notes}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-15.0}"
INCLUDE_RELEASE_NOTES="${INCLUDE_RELEASE_NOTES:-1}"
SIGN_UPDATE="${SIGN_UPDATE:-}"
XCODE_PROJECT="${XCODE_PROJECT:-}"
XCODE_SCHEME="${XCODE_SCHEME:-CodexBar}"

usage() {
  cat >&2 <<USAGE
usage: Scripts/update-appcast.sh [CodexBar-vX.Y.Z.dmg]

Environment:
  APPCAST_PATH            Path to appcast.xml. Defaults to Updates/appcast.xml.
  DOWNLOAD_BASE_URL       Base URL for DMG downloads.
                           Defaults to https://codexbar.zabrian.app/download.
  RELEASE_NOTES_BASE_URL  Base URL for release notes.
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
  printf '%s\n' "${BUILD_SETTINGS}" \
    | awk -F= -v key="${name}" '
      $1 ~ key {
        value = $2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    '
}

if [[ "${DMG_PATH}" == "-h" || "${DMG_PATH}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${DMG_PATH}" ]]; then
  dmgs=()
  while IFS= read -r dmg; do
    dmgs+=("${dmg}")
  done < <(find "${PROJECT_DIR}" -maxdepth 1 -type f -name "*.dmg" | sort)

  if [[ "${#dmgs[@]}" -eq 0 ]]; then
    echo "error: no DMG found in project root" >&2
    usage
    exit 1
  fi

  if [[ "${#dmgs[@]}" -gt 1 ]]; then
    echo "error: multiple DMGs found; specify one explicitly:" >&2
    printf '  %s\n' "${dmgs[@]}" >&2
    exit 1
  fi

  DMG_PATH="${dmgs[0]}"
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
  projects=()
  while IFS= read -r project; do
    projects+=("${project}")
  done < <(find "${PROJECT_DIR}" -maxdepth 1 -type d -name "*.xcodeproj" | sort)

  if [[ "${#projects[@]}" -eq 0 ]]; then
    echo "error: no .xcodeproj found in project root" >&2
    exit 1
  fi

  if [[ "${#projects[@]}" -gt 1 ]]; then
    echo "error: multiple .xcodeproj files found; set XCODE_PROJECT" >&2
    printf '  %s\n' "${projects[@]}" >&2
    exit 1
  fi

  XCODE_PROJECT="${projects[0]}"
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
        -path "*Sparkle*/bin/sign_update" \
        -type f \
        2>/dev/null \
        | sort \
        | tail -n 1
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
  printf '%s\n' "${SIGN_OUTPUT}" \
    | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' \
    | head -n 1
)"
ARCHIVE_LENGTH="$(
  printf '%s\n' "${SIGN_OUTPUT}" \
    | sed -n 's/.*length="\([^"]*\)".*/\1/p' \
    | head -n 1
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
  RELEASE_NOTES_URL="${RELEASE_NOTES_BASE_URL%/}/${SHORT_VERSION}.html"
  RELEASE_NOTES_URL_ESCAPED="$(printf '%s' "${RELEASE_NOTES_URL}" | xml_escape)"
  RELEASE_NOTES_XML="<sparkle:releaseNotesLink>${RELEASE_NOTES_URL_ESCAPED}</sparkle:releaseNotesLink>
"
fi

APPCAST_ITEM="        <item>
            <title>${TITLE}</title>
            <sparkle:version>${BUILD_VERSION}</sparkle:version>
            <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MIN_SYSTEM_ESCAPED}</sparkle:minimumSystemVersion>
            ${RELEASE_NOTES_XML}            <pubDate>${PUB_DATE}</pubDate>
            <enclosure url=\"${DOWNLOAD_URL_ESCAPED}\" sparkle:edSignature=\"${ED_SIGNATURE_ESCAPED}\" length=\"${ARCHIVE_LENGTH}\" type=\"application/octet-stream\"/>
        </item>"

echo "==> Updating appcast"
APPCAST_ITEM="${APPCAST_ITEM}" APPCAST_VERSION="${BUILD_VERSION}" perl -0pi -e '
  my $item = $ENV{"APPCAST_ITEM"};
  my $version = $ENV{"APPCAST_VERSION"};

  s/\n\s*<item>\s*.*?<sparkle:version>\Q$version\E<\/sparkle:version>.*?<\/item>//sg;

  if (!s/(<language>.*?<\/language>)/$1\n$item/s) {
    die "Unable to find <language>...</language> insertion point\n";
  }
' "${APPCAST_PATH}"

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "${APPCAST_PATH}"
fi

echo "==> Added ${PRODUCT_NAME} ${SHORT_VERSION} (${BUILD_VERSION})"
echo "    ${APPCAST_PATH}"
echo "    ${DOWNLOAD_URL}"
