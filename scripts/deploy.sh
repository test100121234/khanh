#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Enterprise CI/CD Deployment Pipeline for Headless QA Agent
# ==============================================================================

PROVISION_PROFILE=""
P12_CERTIFICATE=""
P12_PASSWORD="yay"
PROJECT_DIR="."
SCHEME="devicekit-ios"
CONFIGURATION="Release"
BUILD_DIR="build"
OUTPUT_DIR="build/export"
ENTITLEMENTS_PATH="build/entitlements.plist"
PROVISION_PLIST="build/profile.plist"
INFO_PLIST="DeviceKit/Info.plist"

usage() {
    echo "Usage: $0 -p <profile.mobileprovision> -c <cert.p12> [-k <password>]"
    echo ""
    echo "Options:"
    echo "  -p, --provision   Path to .mobileprovision file"
    echo "  -c, --cert        Path to .p12 distribution/enterprise certificate"
    echo "  -k, --password    Password for .p12 certificate (Default: yay)"
    echo "  -h, --help        Show this help message"
    exit 1
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p|--provision) PROVISION_PROFILE="$2"; shift ;;
        -c|--cert) P12_CERTIFICATE="$2"; shift ;;
        -k|--password) P12_PASSWORD="$2"; shift ;;
        -h|--help) usage ;;
        *) echo "[-] Unknown argument: $1"; usage ;;
    esac
    shift
done

PROVISION_PROFILE="${PROVISION_PROFILE:-cert/HSBC.mobileprovision}"
P12_CERTIFICATE="${P12_CERTIFICATE:-cert/HSBC.p12}"

if [[ ! -f "$PROVISION_PROFILE" ]]; then
    echo "[-] Error: Provisioning profile not found at '$PROVISION_PROFILE'"
    usage
fi

if [[ ! -f "$P12_CERTIFICATE" ]]; then
    echo "[-] Error: Certificate file not found at '$P12_CERTIFICATE'"
    usage
fi

echo "[*] Initializing build directories..."
mkdir -p "$BUILD_DIR"
mkdir -p "$OUTPUT_DIR"

echo "[+] Step 1: Parsing provisioning profile via security cms -D..."
security cms -D -i "$PROVISION_PROFILE" > "$PROVISION_PLIST"

APP_ID_PREFIX=$(/usr/libexec/PlistBuddy -c "Print :ApplicationIdentifierPrefix:0" "$PROVISION_PLIST" 2>/dev/null || echo "")
APP_IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:application-identifier" "$PROVISION_PLIST" 2>/dev/null || echo "")

if [[ -z "$APP_IDENTIFIER" ]]; then
    echo "[-] Error: Could not extract application-identifier from provisioning profile."
    exit 1
fi

if [[ -n "$APP_ID_PREFIX" && "$APP_IDENTIFIER" == "$APP_ID_PREFIX."* ]]; then
    BUNDLE_ID="${APP_IDENTIFIER#"$APP_ID_PREFIX."}"
else
    BUNDLE_ID="$APP_IDENTIFIER"
fi

echo "[*] Application Identifier : $APP_IDENTIFIER"
echo "[*] Bundle Identifier      : $BUNDLE_ID"

echo "[+] Step 2: Generating runtime production entitlements (get-task-allow = false)..."
cat <<EOF > "$ENTITLEMENTS_PATH"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>${APP_IDENTIFIER}</string>
    <key>get-task-allow</key>
    <false/>
    <key>keychain-access-groups</key>
    <array>
        <string>${APP_IDENTIFIER}</string>
    </array>
</dict>
</plist>
EOF

echo "[+] Step 3: Injecting Bundle ID and Background Modes into $INFO_PLIST..."
if [[ -f "$INFO_PLIST" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"
    
    # Enforce background audio execution
    /usr/libexec/PlistBuddy -c "Delete :UIBackgroundModes" "$INFO_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :UIBackgroundModes array" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Add :UIBackgroundModes:0 string audio" "$INFO_PLIST"
else
    echo "[-] Warning: $INFO_PLIST not found. Skipping Plist injection."
fi

echo "[+] Step 4: Building unsigned .app with xcodebuild (iphoneos SDK)..."
xcodebuild clean build \
    -project "${SCHEME}.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=""

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "[-] Build failed: $APP_PATH does not exist."
    exit 1
fi

echo "[+] Step 5: Packaging & Signing IPA with zsign..."
OUTPUT_IPA="${OUTPUT_DIR}/${SCHEME}-enterprise.ipa"

if command -v zsign &> /dev/null; then
    zsign -k "$P12_CERTIFICATE" \
          -p "$P12_PASSWORD" \
          -m "$PROVISION_PROFILE" \
          -e "$ENTITLEMENTS_PATH" \
          -o "$OUTPUT_IPA" \
          "$APP_PATH"
else
    echo "[-] zsign not found in PATH. Packaging unsigned IPA into $OUTPUT_IPA..."
    rm -rf "$BUILD_DIR/Payload"
    mkdir -p "$BUILD_DIR/Payload"
    cp -r "$APP_PATH" "$BUILD_DIR/Payload/"
    (cd "$BUILD_DIR" && zip -qry "export/${SCHEME}-enterprise.ipa" Payload)
    rm -rf "$BUILD_DIR/Payload"
fi

echo "[✓] Deployment package successfully generated: $OUTPUT_IPA"
