#!/usr/bin/env bash

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
    local export_certificate_selector=""
    local main_application_identifier=""
    local helper_application_identifier=""
    local main_team_identifier=""
    local debugger_entitlement=""
    local helper_debugger_entitlement=""
    local app_debugger_status="disabled"
    local helper_debugger_status="disabled"
    local icloud_environment=""
    local icloud_containers=""
    local icloud_services=""
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
    local -a profile_certificate_sha1s=()
    local profile_icloud_environment=""
    local profile_icloud_containers=""
    local profile_icloud_services=""
    local profile_ubiquity_containers=""
    local profile_ubiquity_kvstore=""
    local profile_keychain_access_groups=""
    local expected_profile=""
    local gatekeeper_source=""

    echo "==> Validating final app"
    validation_section "Bundle"

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

    if ! helper_architectures="$(lipo -archs "${helper_path}" 2>&1)"; then
        validation_fail "Helper architectures" "lipo could not inspect the helper executable" "${helper_architectures}"
        return 1
    fi
    validation_pass "Architectures inspected"

    validation_field "Path" "${app_path}"
    validation_field "Display name" "${display_name}"
    validation_field "Bundle identifier" "${bundle_identifier}"
    validation_field "Version" "${short_version} (${build_version})"
    validation_field "Minimum macOS" "${minimum_system_version}"
    validation_field "LSUIElement" "${ui_element}"
    validation_field "App architectures" "${architectures}"
    validation_field "Helper architectures" "${helper_architectures}"

    validation_section "Code signature"

    if ! command_output="$(codesign --verify --deep --strict --verbose=4 "${app_path}" 2>&1)"; then
        validation_fail "Deep strict app signature" "codesign rejected the app bundle" "${command_output}"
        return 1
    fi
    validation_pass "Deep strict app signature"

    for architecture in ${architectures}; do
        if ! command_output="$(codesign --verify --strict --verbose=4 --arch "${architecture}" "${app_path}" 2>&1)"; then
            validation_fail "App ${architecture} signature" "codesign rejected the ${architecture} slice" "${command_output}"
            return 1
        fi
    done
    validation_pass "App signature slices: ${architectures}"

    if ! command_output="$(codesign --verify --strict --verbose=4 "${helper_path}" 2>&1)"; then
        validation_fail "Helper signature" "codesign rejected the helper executable" "${command_output}"
        return 1
    fi
    validation_pass "Helper signature"

    for architecture in ${helper_architectures}; do
        if ! command_output="$(codesign --verify --strict --verbose=4 --arch "${architecture}" "${helper_path}" 2>&1)"; then
            validation_fail "Helper ${architecture} signature" "codesign rejected the helper ${architecture} slice" "${command_output}"
            return 1
        fi
    done
    validation_pass "Helper signature slices: ${helper_architectures}"

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
        export_certificate_selector="${expected_signing_certificate}"
    fi

    validation_field "App identifier" "${signature_identifier}"
    validation_field "Helper identifier" "${helper_signature_identifier}"
    validation_field "Authority" "${signing_authority}"
    validation_field "Team identifier" "${signing_team}"
    validation_field "App certificate SHA-1" "${signing_certificate_sha1}"
    validation_field "Helper certificate SHA-1" "${helper_signing_certificate_sha1}"
    validation_field "Timestamp" "${signing_timestamp:-none}"
    validation_field "CDHash" "${signing_cdhash}"
    if [[ -n "${export_certificate_selector}" ]]; then
        validation_field "Export certificate selector" "${export_certificate_selector}"
    fi

    validation_section "Entitlements"

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
    main_team_identifier="$(read_plist_value "${main_entitlements}" com.apple.developer.team-identifier)"
    debugger_entitlement="$(read_plist_value "${main_entitlements}" com.apple.security.get-task-allow)"
    helper_debugger_entitlement="$(read_plist_value "${helper_entitlements}" com.apple.security.get-task-allow)"
    icloud_environment="$(read_plist_compact_value "${main_entitlements}" com.apple.developer.icloud-container-environment)"
    icloud_containers="$(read_plist_compact_value "${main_entitlements}" com.apple.developer.icloud-container-identifiers)"
    icloud_services="$(read_plist_compact_value "${main_entitlements}" com.apple.developer.icloud-services)"
    if [[ "${debugger_entitlement}" == "true" || "${debugger_entitlement}" == "1" ]]; then
        app_debugger_status="allowed"
    fi
    if [[ "${helper_debugger_entitlement}" == "true" || "${helper_debugger_entitlement}" == "1" ]]; then
        helper_debugger_status="allowed"
    fi

    if [[ "${main_application_identifier}" != "${signing_team}.${bundle_identifier}" ||
        "${helper_application_identifier}" != "${signing_team}.${bundle_identifier}.helper" ]]; then
        validation_fail \
            "Entitlement application identifiers" \
            "Expected ${signing_team}.${bundle_identifier} and ${signing_team}.${bundle_identifier}.helper; got ${main_application_identifier:-none} and ${helper_application_identifier:-none}"
        return 1
    fi
    validation_pass "Entitlement application identifiers"

    if [[ "${CONFIGURATION}" == "Release" &&
        ("${app_debugger_status}" == "allowed" || "${helper_debugger_status}" == "allowed") ]]; then
        validation_fail \
            "Release debugger attachment" \
            "get-task-allow is enabled for app=${debugger_entitlement:-false}, helper=${helper_debugger_entitlement:-false}"
        return 1
    fi

    if ! command_output="$(plutil -p "${main_entitlements}" 2>&1)"; then
        validation_fail "App entitlements" "Unable to read app entitlements" "${command_output}"
        return 1
    fi

    if ! command_output="$(plutil -p "${helper_entitlements}" 2>&1)"; then
        validation_fail "Helper entitlements" "Unable to read helper entitlements" "${command_output}"
        return 1
    fi
    validation_pass "Debugger attachment policy"

    validation_field "App identifier" "${main_application_identifier}"
    validation_field "Helper identifier" "${helper_application_identifier}"
    validation_field "Team identifier" "${main_team_identifier}"
    validation_field "iCloud environment" "${icloud_environment}"
    validation_field "iCloud containers" "${icloud_containers}"
    validation_field "iCloud services" "${icloud_services}"
    validation_field "App debugger attachment" "${app_debugger_status}"
    validation_field "Helper debugger attachment" "${helper_debugger_status}"

    validation_section "LaunchDaemon"

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

    validation_field "File" "$(basename "${launch_daemon_plist}")"
    validation_field "Label" "${launch_daemon_label}"
    validation_field "Associated bundle" "${launch_daemon_bundle_identifier}"
    validation_field "Program" "${launch_daemon_program}"

    validation_section "Provisioning profile"

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
            profile_certificate_sha1s+=("${profile_certificate_sha1}")
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
        if ! command_output="$(plutil -p "${profile_entitlements}" 2>&1)"; then
            validation_fail "Profile entitlements" "Unable to read authorized entitlements" "${command_output}"
            return 1
        fi
        profile_icloud_environment="$(read_plist_compact_value "${profile_entitlements}" com.apple.developer.icloud-container-environment)"
        profile_icloud_containers="$(read_plist_compact_value "${profile_entitlements}" com.apple.developer.icloud-container-identifiers)"
        profile_icloud_services="$(read_plist_compact_value "${profile_entitlements}" com.apple.developer.icloud-services)"
        profile_ubiquity_containers="$(read_plist_compact_value "${profile_entitlements}" com.apple.developer.ubiquity-container-identifiers)"
        profile_ubiquity_kvstore="$(read_plist_compact_value "${profile_entitlements}" com.apple.developer.ubiquity-kvstore-identifier)"
        profile_keychain_access_groups="$(read_plist_compact_value "${profile_entitlements}" keychain-access-groups)"
        validation_pass "Profile entitlements"

        validation_field "Name" "${profile_name}"
        validation_field "UUID" "${profile_uuid}"
        validation_field "Team identifier" "${profile_team}"
        validation_field "Application identifier" "${profile_application_identifier}"
        validation_field "Expiration" "${profile_expiration}"
        validation_field "Authorized certificates" "${profile_certificate_count}"
        for ((profile_certificate_index = 0; profile_certificate_index < profile_certificate_count; profile_certificate_index++)); do
            validation_field \
                "Certificate $((profile_certificate_index + 1)) SHA-1" \
                "${profile_certificate_sha1s[${profile_certificate_index}]}"
        done
        validation_field "iCloud environment" "${profile_icloud_environment}"
        validation_field "iCloud containers" "${profile_icloud_containers}"
        validation_field "iCloud services" "${profile_icloud_services}"
        validation_field "Ubiquity containers" "${profile_ubiquity_containers}"
        validation_field "Ubiquity KV store" "${profile_ubiquity_kvstore}"
        validation_field "Keychain access groups" "${profile_keychain_access_groups}"
    elif [[ -n "${icloud_containers}" ]]; then
        validation_fail "Embedded provisioning profile" "CloudKit entitlements require embedded.provisionprofile"
        return 1
    else
        validation_pass "Provisioning profile not required"
    fi

    validation_section "Distribution"

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
            validation_field "Gatekeeper source" "${gatekeeper_source}"
        else
            validation_skip "Gatekeeper assessment"
        fi
    fi

    validation_summary "Final app validation passed"
}
