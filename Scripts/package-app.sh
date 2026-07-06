#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GIT_VERSION="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
APP_NAME="MeetingSidekickfree-${GIT_VERSION}"
APP_DIR="$ROOT_DIR/Build/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SIGNING_DIR="$ROOT_DIR/.codesign"
SIGNING_IDENTITY="MeetingSidekickfree Local Code Signing"
KEYCHAIN_PATH="$SIGNING_DIR/MeetingSidekickfree.keychain-db"
KEYCHAIN_PASSWORD="MeetingSidekickfreeLocalSigning"
P12_PASSWORD="MeetingSidekickfreeLocalP12"

cd "$ROOT_DIR"
mkdir -p ".build/module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"

swift build --disable-sandbox -c release

trim_keychain_line() {
    local value="$1"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    value="${value#\"}"
    value="${value%\"}"
    printf '%s' "$value"
}

ensure_keychain_search_list() {
    local keychains=("$KEYCHAIN_PATH")
    local existing

    while IFS= read -r existing; do
        existing="$(trim_keychain_line "$existing")"
        if [[ -n "$existing" && "$existing" != "$KEYCHAIN_PATH" ]]; then
            keychains+=("$existing")
        fi
    done < <(security list-keychains -d user 2>/dev/null || true)

    security list-keychains -d user -s "${keychains[@]}"
}

ensure_signing_identity() {
    if security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
        security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
        ensure_keychain_search_list
        return
    fi

    mkdir -p "$SIGNING_DIR"
    local key_file="$SIGNING_DIR/MeetingSidekickfree.key"
    local cert_file="$SIGNING_DIR/MeetingSidekickfree.crt"
    local p12_file="$SIGNING_DIR/MeetingSidekickfree.p12"

    openssl req \
        -newkey rsa:2048 \
        -nodes \
        -keyout "$key_file" \
        -x509 \
        -days 3650 \
        -out "$cert_file" \
        -subj "/CN=$SIGNING_IDENTITY/" \
        -addext "keyUsage=digitalSignature" \
        -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

    openssl pkcs12 \
        -export \
        -legacy \
        -macalg sha1 \
        -out "$p12_file" \
        -inkey "$key_file" \
        -in "$cert_file" \
        -passout "pass:$P12_PASSWORD" \
        -name "$SIGNING_IDENTITY" >/dev/null 2>&1

    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
    security import "$p12_file" -k "$KEYCHAIN_PATH" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    security add-trusted-cert -r trustRoot -p codeSign "$cert_file" >/dev/null 2>&1 || true
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    ensure_keychain_search_list
}

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp ".build/release/MeetingSidekickfree" "$MACOS_DIR/MeetingSidekickfree"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "Resources/MeetingSidekick.entitlements" "$RESOURCES_DIR/MeetingSidekick.entitlements"

/usr/libexec/PlistBuddy -c "Set :CFBundleName MeetingSidekickfree" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName MeetingSidekickfree" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string MeetingSidekickfree" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_VERSION" "$CONTENTS_DIR/Info.plist"

chmod +x "$MACOS_DIR/MeetingSidekickfree"

ensure_signing_identity
codesign \
    --force \
    --deep \
    --options runtime \
    --entitlements "Resources/MeetingSidekick.entitlements" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR" >/dev/null

echo "$APP_DIR"
