#!/bin/zsh
# Builds "Webcam Crop.app".
#
#   ./build.sh               build, sign with a local identity, install to /Applications
#   ./build.sh --no-install  build and sign, leave the app in build/
#   ./build.sh --ci          build, ad-hoc sign and zip (what CI runs; touches no keychains)
#
# Env: BUNDLE_ID (default com.ahmedehab.webcamcrop), ARCHS (default "arm64 x86_64").
# Needs only the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

MODE=install
case "${1:-}" in
  "") ;;
  --no-install) MODE=build ;;
  --ci) MODE=ci ;;
  *) echo "usage: $0 [--no-install | --ci]" >&2; exit 2 ;;
esac

BUNDLE_ID=${BUNDLE_ID:-com.ahmedehab.webcamcrop}
ARCHS=(${=ARCHS:-arm64 x86_64})
MIN_MACOS=15.0
APP="build/Webcam Crop.app"
mkdir -p build

# --- compile (one slice per arch, merged into a universal binary) -------------------------
bins=()
for arch in $ARCHS; do
  echo "compiling $arch..."
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos$MIN_MACOS" \
    Sources/*.swift -o "build/WebcamCrop-$arch"
  bins+=("build/WebcamCrop-$arch")
done
lipo -create $bins -output build/WebcamCrop

# --- icon ---------------------------------------------------------------------------------
if [[ ! -f build/AppIcon.icns || make_icon.swift -nt build/AppIcon.icns ]]; then
  swiftc -O make_icon.swift -o build/make_icon
  rm -rf build/AppIcon.iconset
  build/make_icon build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

# --- bundle -------------------------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
cp build/WebcamCrop "$APP/Contents/MacOS/WebcamCrop"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ $MODE == ci ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  rm -f build/Webcam-Crop.zip
  ditto -c -k --keepParent "$APP" build/Webcam-Crop.zip
  echo "built $APP (ad-hoc signed) and build/Webcam-Crop.zip"
  exit 0
fi

# --- sign with a stable local identity ------------------------------------------------------
# An ad-hoc signature changes on every build, and macOS then forgets the camera permission.
# So we sign with a self-signed certificate kept in a private keychain under signing/
# (git-ignored, created once, never added to your login keychain).
KC="$PWD/signing/webcamcrop-signing.keychain-db"
ID="Webcam Crop Local Signing"
if [[ ! -f "$KC" ]]; then
  echo "creating local signing identity in signing/ (one time)..."
  mkdir -p signing && chmod 700 signing
  openssl rand -hex 24 > signing/keychain-password && chmod 600 signing/keychain-password
  PW=$(cat signing/keychain-password)
  cat > signing/cert.cnf <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $ID
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config signing/cert.cnf \
    -keyout signing/key.pem -out signing/cert.pem 2>/dev/null
  openssl pkcs12 -export -inkey signing/key.pem -in signing/cert.pem -out signing/id.p12 -passout "pass:$PW"
  rm signing/key.pem
  security create-keychain -p "$PW" "$KC"
  security set-keychain-settings "$KC"   # no auto-lock
  security import signing/id.p12 -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
  rm signing/id.p12
fi
security unlock-keychain -p "$(cat signing/keychain-password)" "$KC"
HASH=$(security find-identity -p codesigning "$KC" | grep -F "\"$ID\"" | head -1 | awk '{print $2}')

# codesign only looks at keychains in the search list: add ours for this one call, then restore
ORIG=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
trap 'security list-keychains -d user -s "${ORIG[@]}"' EXIT
security list-keychains -d user -s "${ORIG[@]}" "$KC"
codesign --force --sign "$HASH" --identifier "$BUNDLE_ID" "$APP"
security list-keychains -d user -s "${ORIG[@]}"

if [[ $MODE == build ]]; then
  echo "built $APP"
  exit 0
fi

# --- install --------------------------------------------------------------------------------
DEST="/Applications/Webcam Crop.app"
osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "installed $DEST"
