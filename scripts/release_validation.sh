#!/bin/bash
# Shared validation for Ping Warden release artifacts.
#
# This file is sourced by notarize.sh and release.sh. The caller must enable
# strict shell handling before invoking these functions.

PING_WARDEN_BUNDLE_ID="com.amesvt.pingwarden"
PING_WARDEN_WIDGET_BUNDLE_ID="com.amesvt.pingwarden.widget"
PING_WARDEN_HELPER_BUNDLE_ID="com.amesvt.pingwarden.helper"
PING_WARDEN_TEAM_ID="PV3W52NDZ3"
PING_WARDEN_APP_GROUP="PV3W52NDZ3.com.amesvt.pingwarden"

release_validation_error() {
    echo "Error: $*" >&2
}

validate_release_version() {
    local version="$1"

    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then
        release_validation_error "version '$version' must use X.Y.Z or X.Y.Z-(alpha|beta|rc).N format"
        return 1
    fi
}

release_marketing_version() {
    local version="$1"
    printf '%s\n' "${version%%-*}"
}

plist_value() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

validate_numeric_bundle_version() {
    local bundle_version="$1"

    if [[ ! "$bundle_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        release_validation_error "CFBundleVersion '$bundle_version' must contain one to three dot-separated integers"
        return 1
    fi
}

validate_minimum_system_version() {
    local minimum_version="$1"

    if [[ ! "$minimum_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        release_validation_error "LSMinimumSystemVersion '$minimum_version' is not numeric"
        return 1
    fi

    if [ "$minimum_version" != "13.0" ] && [ "$minimum_version" != "13.0.0" ]; then
        release_validation_error "LSMinimumSystemVersion is '$minimum_version'; Ping Warden publicly supports macOS 13.0"
        return 1
    fi
}

validate_universal_binary() {
    local binary_path="$1"
    local component_name="$2"
    local architectures

    if [ ! -x "$binary_path" ]; then
        release_validation_error "$component_name binary is missing or not executable at $binary_path"
        return 1
    fi
    architectures="$(lipo -archs "$binary_path" 2>/dev/null || true)"
    case " $architectures " in
        *" arm64 "*) ;;
        *)
            release_validation_error "$component_name is missing arm64 architecture: $architectures"
            return 1
            ;;
    esac
    case " $architectures " in
        *" x86_64 "*) ;;
        *)
            release_validation_error "$component_name is missing x86_64 architecture: $architectures"
            return 1
            ;;
    esac
}

validate_signed_component() {
    local component_path="$1"
    local component_name="$2"
    local expected_identifier="$3"
    local signing_output

    if ! codesign --verify --strict --verbose=2 "$component_path"; then
        release_validation_error "code signature validation failed for $component_name"
        return 1
    fi

    signing_output="$(codesign -dvvv "$component_path" 2>&1 || true)"
    case "$signing_output" in
        *"Identifier=$expected_identifier"*) ;;
        *)
            release_validation_error "$component_name signature identifier does not match $expected_identifier"
            return 1
            ;;
    esac
    case "$signing_output" in
        *"Authority=Developer ID Application:"*) ;;
        *)
            release_validation_error "$component_name is not signed with a Developer ID Application identity"
            return 1
            ;;
    esac
    case "$signing_output" in
        *"TeamIdentifier=$PING_WARDEN_TEAM_ID"*) ;;
        *)
            release_validation_error "$component_name signature does not use Team ID $PING_WARDEN_TEAM_ID"
            return 1
            ;;
    esac
    case "$signing_output" in
        *"flags="*"(runtime)"*) ;;
        *)
            release_validation_error "$component_name does not enable Hardened Runtime"
            return 1
            ;;
    esac
}

validate_distribution_signature() {
    local app_path="$1"
    local info_plist app_executable helper_path widget_path widget_plist widget_executable
    local app_entitlements widget_entitlements

    if ! codesign --verify --deep --strict --verbose=2 "$app_path"; then
        release_validation_error "code signature validation failed for $app_path"
        return 1
    fi

    info_plist="$app_path/Contents/Info.plist"
    app_executable="$(plist_value "$info_plist" CFBundleExecutable || true)"
    helper_path="$app_path/Contents/MacOS/PingWardenHelper"
    widget_path="$app_path/Contents/PlugIns/PingWardenWidget.appex"
    widget_plist="$widget_path/Contents/Info.plist"
    widget_executable="$(plist_value "$widget_plist" CFBundleExecutable || true)"

    validate_signed_component "$app_path" "app" "$PING_WARDEN_BUNDLE_ID" || return 1
    validate_signed_component "$helper_path" "privileged helper" "$PING_WARDEN_HELPER_BUNDLE_ID" || return 1
    validate_signed_component "$widget_path" "Control Center widget" "$PING_WARDEN_WIDGET_BUNDLE_ID" || return 1

    validate_universal_binary "$app_path/Contents/MacOS/$app_executable" "app" || return 1
    validate_universal_binary "$helper_path" "privileged helper" || return 1
    validate_universal_binary "$widget_path/Contents/MacOS/$widget_executable" "Control Center widget" || return 1

    app_entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
    widget_entitlements="$(codesign -d --entitlements :- "$widget_path" 2>/dev/null || true)"
    case "$app_entitlements$widget_entitlements" in
        *"com.apple.security.get-task-allow"*)
            release_validation_error "distribution payload contains the get-task-allow entitlement"
            return 1
            ;;
    esac
    case "$app_entitlements" in
        *"$PING_WARDEN_APP_GROUP"*) ;;
        *)
            release_validation_error "app signature is missing App Group $PING_WARDEN_APP_GROUP"
            return 1
            ;;
    esac
    case "$widget_entitlements" in
        *"$PING_WARDEN_APP_GROUP"*) ;;
        *)
            release_validation_error "widget signature is missing App Group $PING_WARDEN_APP_GROUP"
            return 1
            ;;
    esac
}

validate_app_artifact() {
    local app_path="$1"
    local release_version="$2"
    local require_signature="${3:-1}"
    local info_plist expected_marketing_version widget_plist widget_minimum_version
    local app_executable widget_executable helper_path
    local require_signed_feed verify_before_extraction

    validate_release_version "$release_version" || return 1

    info_plist="$app_path/Contents/Info.plist"
    if [ ! -f "$info_plist" ]; then
        release_validation_error "app Info.plist not found at $info_plist"
        return 1
    fi

    VALIDATED_BUNDLE_ID="$(plist_value "$info_plist" CFBundleIdentifier || true)"
    VALIDATED_SHORT_VERSION="$(plist_value "$info_plist" CFBundleShortVersionString || true)"
    VALIDATED_BUNDLE_VERSION="$(plist_value "$info_plist" CFBundleVersion || true)"
    VALIDATED_MINIMUM_SYSTEM_VERSION="$(plist_value "$info_plist" LSMinimumSystemVersion || true)"
    expected_marketing_version="$(release_marketing_version "$release_version")"

    if [ "$VALIDATED_BUNDLE_ID" != "$PING_WARDEN_BUNDLE_ID" ]; then
        release_validation_error "artifact bundle ID is '$VALIDATED_BUNDLE_ID', expected '$PING_WARDEN_BUNDLE_ID'"
        return 1
    fi
    if [ "$VALIDATED_SHORT_VERSION" != "$expected_marketing_version" ]; then
        release_validation_error "artifact CFBundleShortVersionString is '$VALIDATED_SHORT_VERSION', expected '$expected_marketing_version' for release '$release_version'"
        return 1
    fi
    validate_numeric_bundle_version "$VALIDATED_BUNDLE_VERSION" || return 1
    validate_minimum_system_version "$VALIDATED_MINIMUM_SYSTEM_VERSION" || return 1

    if [ -z "$(plist_value "$info_plist" SUFeedURL || true)" ]; then
        release_validation_error "artifact has no SUFeedURL"
        return 1
    fi
    if [ -z "$(plist_value "$info_plist" SUPublicEDKey || true)" ]; then
        release_validation_error "artifact has no SUPublicEDKey"
        return 1
    fi

    require_signed_feed="$(plist_value "$info_plist" SURequireSignedFeed || true)"
    verify_before_extraction="$(plist_value "$info_plist" SUVerifyUpdateBeforeExtraction || true)"
    if [ "$require_signed_feed" != "true" ] || [ "$verify_before_extraction" != "true" ]; then
        release_validation_error "artifact must enable SURequireSignedFeed and SUVerifyUpdateBeforeExtraction"
        return 1
    fi

    widget_plist="$app_path/Contents/PlugIns/PingWardenWidget.appex/Contents/Info.plist"
    if [ ! -f "$widget_plist" ]; then
        release_validation_error "widget Info.plist not found at $widget_plist"
        return 1
    fi
    if [ "$(plist_value "$widget_plist" CFBundleIdentifier || true)" != "$PING_WARDEN_WIDGET_BUNDLE_ID" ]; then
        release_validation_error "widget bundle ID is incorrect"
        return 1
    fi
    if [ "$(plist_value "$widget_plist" CFBundleShortVersionString || true)" != "$VALIDATED_SHORT_VERSION" ]; then
        release_validation_error "widget marketing version does not match the app"
        return 1
    fi
    if [ "$(plist_value "$widget_plist" CFBundleVersion || true)" != "$VALIDATED_BUNDLE_VERSION" ]; then
        release_validation_error "widget build version does not match the app"
        return 1
    fi
    widget_minimum_version="$(plist_value "$widget_plist" LSMinimumSystemVersion || true)"
    if [ "$widget_minimum_version" != "26.0" ] && [ "$widget_minimum_version" != "26.0.0" ]; then
        release_validation_error "widget LSMinimumSystemVersion is '$widget_minimum_version'; Control Center controls require macOS 26.0"
        return 1
    fi

    app_executable="$(plist_value "$info_plist" CFBundleExecutable || true)"
    widget_executable="$(plist_value "$widget_plist" CFBundleExecutable || true)"
    helper_path="$app_path/Contents/MacOS/PingWardenHelper"
    validate_universal_binary "$app_path/Contents/MacOS/$app_executable" "app" || return 1
    validate_universal_binary "$helper_path" "privileged helper" || return 1
    validate_universal_binary "$app_path/Contents/PlugIns/PingWardenWidget.appex/Contents/MacOS/$widget_executable" "Control Center widget" || return 1

    # The helper embeds its Info.plist in the binary
    # (CREATE_INFOPLIST_SECTION_IN_BINARY), so its version lives outside the
    # plists checked above. Extract the section and pin both version keys to
    # the app's so a hand-edited bump cannot ship half-applied. segedit only
    # operates on thin Mach-O files, so isolate the arm64 slice first when
    # the artifact is a universal binary.
    local helper_plist_extract="${TMPDIR:-/tmp}/pingwarden_helper_info.$$.plist"
    local helper_thin="${TMPDIR:-/tmp}/pingwarden_helper_arm64.$$.bin"
    local helper_for_extraction="$helper_path"
    if lipo -info "$helper_path" 2>/dev/null | grep -q "fat file"; then
        if ! lipo "$helper_path" -thin arm64 -output "$helper_thin"; then
            rm -f "$helper_thin" "$helper_plist_extract"
            release_validation_error "could not isolate arm64 slice of privileged helper for version extraction"
            return 1
        fi
        helper_for_extraction="$helper_thin"
    fi
    if ! xcrun segedit "$helper_for_extraction" -extract __TEXT __info_plist "$helper_plist_extract" >/dev/null 2>&1; then
        rm -f "$helper_thin" "$helper_plist_extract"
        release_validation_error "could not extract embedded Info.plist section from privileged helper"
        return 1
    fi
    local helper_short_version helper_bundle_version
    helper_short_version="$(plist_value "$helper_plist_extract" CFBundleShortVersionString || true)"
    helper_bundle_version="$(plist_value "$helper_plist_extract" CFBundleVersion || true)"
    rm -f "$helper_thin" "$helper_plist_extract"
    if [ "$helper_short_version" != "$VALIDATED_SHORT_VERSION" ]; then
        release_validation_error "privileged helper marketing version is '$helper_short_version', expected '$VALIDATED_SHORT_VERSION'"
        return 1
    fi
    if [ "$helper_bundle_version" != "$VALIDATED_BUNDLE_VERSION" ]; then
        release_validation_error "privileged helper build version does not match the app"
        return 1
    fi

    if [ "$require_signature" = "1" ]; then
        validate_distribution_signature "$app_path" || return 1
    fi
}

validate_notarized_app() {
    local app_path="$1"

    if ! xcrun stapler validate "$app_path"; then
        release_validation_error "app does not contain a valid notarization ticket"
        return 1
    fi
    if ! spctl --assess --type execute --verbose=2 "$app_path"; then
        release_validation_error "Gatekeeper rejected $app_path"
        return 1
    fi
}

validate_dmg_artifact() {
    local dmg_path="$1"
    local release_version="$2"
    local require_notarization="${3:-1}"
    local attach_output mount_point app_path result

    if [ ! -f "$dmg_path" ]; then
        release_validation_error "DMG not found at $dmg_path"
        return 1
    fi
    if ! codesign --verify --verbose=2 "$dmg_path"; then
        release_validation_error "DMG code signature validation failed"
        return 1
    fi
    if [ "$require_notarization" = "1" ] && ! xcrun stapler validate "$dmg_path"; then
        release_validation_error "DMG does not contain a valid notarization ticket"
        return 1
    fi

    attach_output="$(hdiutil attach -readonly -nobrowse "$dmg_path")" || {
        release_validation_error "could not mount $dmg_path"
        return 1
    }
    mount_point="$(printf '%s\n' "$attach_output" | awk '/^\/dev\// { path=$0; sub(/^\/dev\/[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", path); if (path ~ /^\//) print path }' | tail -1)"
    if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
        release_validation_error "could not determine mounted volume path"
        return 1
    fi

    app_path="$mount_point/Ping Warden.app"
    result=0
    validate_app_artifact "$app_path" "$release_version" 1 || result=$?
    if [ "$result" = "0" ] && [ "$require_notarization" = "1" ]; then
        validate_notarized_app "$app_path" || result=$?
    fi

    if ! hdiutil detach "$mount_point" >/dev/null; then
        release_validation_error "could not detach $mount_point"
        return 1
    fi
    return "$result"
}
