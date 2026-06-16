#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/ios-personal-testflight-archive.sh [--build-number 7] [--team-id TEAMID] [--bundle-base BUNDLE_ID]

Archives and exports a personal App Store Connect IPA for TestFlight using
automatic signing under your Apple Developer team.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${ROOT_DIR}/apps/ios"
OUTPUT_DIR="${IOS_DIR}/build/personal-testflight"
ARCHIVE_PATH="${OUTPUT_DIR}/OpenClaw-Personal.xcarchive"
EXPORT_OPTIONS="${OUTPUT_DIR}/ExportOptions.plist"
XCCONFIG_PATH="${IOS_DIR}/build/PersonalTestFlight.xcconfig"

PREPARE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift
      ;;
    --build-number|--team-id|--bundle-base)
      PREPARE_ARGS+=("$1" "${2:-}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

bash "${ROOT_DIR}/scripts/ios-personal-testflight-prepare.sh" "${PREPARE_ARGS[@]+"${PREPARE_ARGS[@]}"}"

TEAM_ID="$(sed -n 's/^OPENCLAW_DEVELOPMENT_TEAM = //p' "${XCCONFIG_PATH}" | tail -1)"
mkdir -p "${OUTPUT_DIR}"
rm -rf "${ARCHIVE_PATH}"
rm -f "${OUTPUT_DIR}"/*.ipa

cat >"${EXPORT_OPTIONS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>signingCertificate</key>
  <string>Apple Distribution</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>destination</key>
  <string>export</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
EOF

(
  cd "${IOS_DIR}"
  XCODE_XCCONFIG_FILE="${XCCONFIG_PATH}" xcodebuild \
    -project OpenClaw.xcodeproj \
    -scheme OpenClaw \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "${ARCHIVE_PATH}" \
    -allowProvisioningUpdates \
    clean archive

  xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${OUTPUT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    -allowProvisioningUpdates
)

echo "Personal TestFlight export complete: ${OUTPUT_DIR}"
