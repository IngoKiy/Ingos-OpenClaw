#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/ios-personal-testflight-archive.sh [--build-number 7] [--team-id TEAMID] [--bundle-base BUNDLE_ID]
    [--asc-key-path /path/to/AuthKey_XXXX.p8] [--asc-key-id KEYID] [--asc-issuer-id ISSUER]
    [--upload]

Archives and exports a personal App Store Connect IPA for TestFlight using
automatic signing under your Apple Developer team.

When App Store Connect credentials are supplied, xcodebuild can create/download
distribution signing assets and export/upload without relying on Xcode Organizer.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="${ROOT_DIR}/apps/ios"
OUTPUT_DIR="${IOS_DIR}/build/personal-testflight"
ARCHIVE_PATH="${OUTPUT_DIR}/OpenClaw-Personal.xcarchive"
EXPORT_OPTIONS="${OUTPUT_DIR}/ExportOptions.plist"
XCCONFIG_PATH="${IOS_DIR}/build/PersonalTestFlight.xcconfig"
ASC_KEY_PATH="${APP_STORE_CONNECT_KEY_PATH:-}"
ASC_KEY_ID="${APP_STORE_CONNECT_KEY_ID:-}"
ASC_ISSUER_ID="${APP_STORE_CONNECT_ISSUER_ID:-}"
ASC_KEYCHAIN_SERVICE="${APP_STORE_CONNECT_KEYCHAIN_SERVICE:-}"
ASC_KEYCHAIN_ACCOUNT="${APP_STORE_CONNECT_KEYCHAIN_ACCOUNT:-${USER:-${LOGNAME:-}}}"
UPLOAD_TO_TESTFLIGHT="${IOS_TESTFLIGHT_UPLOAD:-0}"
ASC_TEMP_KEY_PATH=""

cleanup() {
  if [[ -n "${ASC_TEMP_KEY_PATH}" ]]; then
    rm -f "${ASC_TEMP_KEY_PATH}"
  fi
}
trap cleanup EXIT

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
    --asc-key-path)
      ASC_KEY_PATH="${2:-}"
      shift 2
      ;;
    --asc-key-id)
      ASC_KEY_ID="${2:-}"
      shift 2
      ;;
    --asc-issuer-id)
      ASC_ISSUER_ID="${2:-}"
      shift 2
      ;;
    --asc-keychain-service)
      ASC_KEYCHAIN_SERVICE="${2:-}"
      shift 2
      ;;
    --asc-keychain-account)
      ASC_KEYCHAIN_ACCOUNT="${2:-}"
      shift 2
      ;;
    --upload)
      UPLOAD_TO_TESTFLIGHT=1
      shift
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

if [[ -z "${ASC_KEYCHAIN_SERVICE}" && -z "${ASC_KEY_PATH}" && -n "${ASC_KEY_ID}" && -n "${ASC_ISSUER_ID}" ]]; then
  ASC_KEYCHAIN_SERVICE="openclaw-app-store-connect-key"
fi

bash "${ROOT_DIR}/scripts/ios-personal-testflight-prepare.sh" "${PREPARE_ARGS[@]+"${PREPARE_ARGS[@]}"}"

TEAM_ID="$(sed -n 's/^OPENCLAW_DEVELOPMENT_TEAM = //p' "${XCCONFIG_PATH}" | tail -1)"
mkdir -p "${OUTPUT_DIR}"
rm -rf "${ARCHIVE_PATH}"
rm -f "${OUTPUT_DIR}"/*.ipa

AUTH_ARGS=()
if [[ -z "${ASC_KEY_PATH}" && -n "${ASC_KEYCHAIN_SERVICE}" ]]; then
  if [[ -z "${ASC_KEYCHAIN_ACCOUNT}" ]]; then
    echo "App Store Connect keychain account is empty. Set APP_STORE_CONNECT_KEYCHAIN_ACCOUNT." >&2
    exit 1
  fi

  ASC_TEMP_KEY_PATH="$(mktemp "${TMPDIR:-/tmp}/openclaw-asc-key.XXXXXX.p8")"
  if ! security find-generic-password \
    -a "${ASC_KEYCHAIN_ACCOUNT}" \
    -s "${ASC_KEYCHAIN_SERVICE}" \
    -w >"${ASC_TEMP_KEY_PATH}"
  then
    echo "Could not read App Store Connect key from Keychain service='${ASC_KEYCHAIN_SERVICE}' account='${ASC_KEYCHAIN_ACCOUNT}'." >&2
    exit 1
  fi
  chmod 600 "${ASC_TEMP_KEY_PATH}"
  python3 - "${ASC_TEMP_KEY_PATH}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
data = path.read_bytes().strip()
if b"-----BEGIN PRIVATE KEY-----" in data:
    raise SystemExit(0)

if re.fullmatch(rb"[0-9a-fA-F]+", data or b"") and len(data) % 2 == 0:
    decoded = bytes.fromhex(data.decode("ascii"))
    if b"-----BEGIN PRIVATE KEY-----" in decoded:
        path.write_bytes(decoded)
        raise SystemExit(0)

raise SystemExit("Keychain item did not contain a PEM App Store Connect key.")
PY
  ASC_KEY_PATH="${ASC_TEMP_KEY_PATH}"
fi

if [[ -n "${ASC_KEY_PATH}${ASC_KEY_ID}${ASC_ISSUER_ID}" ]]; then
  if [[ -z "${ASC_KEY_PATH}" || -z "${ASC_KEY_ID}" || -z "${ASC_ISSUER_ID}" ]]; then
    echo "Incomplete App Store Connect auth. Set key path, key ID, and issuer ID." >&2
    exit 1
  fi
  if [[ ! -f "${ASC_KEY_PATH}" ]]; then
    echo "App Store Connect key file not found: ${ASC_KEY_PATH}" >&2
    exit 1
  fi
  AUTH_ARGS=(
    -authenticationKeyPath "${ASC_KEY_PATH}"
    -authenticationKeyID "${ASC_KEY_ID}"
    -authenticationKeyIssuerID "${ASC_ISSUER_ID}"
  )
fi

EXPORT_DESTINATION="export"
if [[ "${UPLOAD_TO_TESTFLIGHT}" == "1" || "${UPLOAD_TO_TESTFLIGHT}" == "true" ]]; then
  EXPORT_DESTINATION="upload"
fi

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
  <string>${EXPORT_DESTINATION}</string>
EOF

if [[ "${EXPORT_DESTINATION}" == "upload" ]]; then
  cat >>"${EXPORT_OPTIONS}" <<EOF
  <key>testFlightInternalTestingOnly</key>
  <true/>
EOF
fi

cat >>"${EXPORT_OPTIONS}" <<EOF
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
    "${AUTH_ARGS[@]}" \
    clean archive

  xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${OUTPUT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    -allowProvisioningUpdates \
    "${AUTH_ARGS[@]}"
)

if [[ "${EXPORT_DESTINATION}" == "upload" ]]; then
  echo "Personal TestFlight upload complete: ${OUTPUT_DIR}"
else
  echo "Personal TestFlight export complete: ${OUTPUT_DIR}"
fi
