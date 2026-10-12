#!/bin/zsh
# Builds MousePilot.app (universal: Apple silicon + Intel) from Sources/MousePilot/*.swift.
#   scripts/build.sh            build into build/MousePilot.app
#   scripts/build.sh --install  also replace /Applications/MousePilot.app and relaunch it
#   scripts/build.sh --dmg      also make dist/MousePilot-<version>.dmg (drag-to-install)
#   scripts/build.sh --adhoc    ad-hoc signature instead of the keychain identity (see below)
#
# The app is built with the Hardened Runtime, so no other process can load code into the
# running app (DYLD_INSERT_LIBRARIES etc.). Resources/MousePilot.entitlements allows it to
# send Apple Events (to switch tabs in background browser windows).
#
# Signing: the app is signed with a self-signed "TabWheel Developer" code-signing
# identity. Its designated requirement is the same for every build, so macOS keeps the
# Accessibility and Automation grants across rebuilds — and across upgrades for anyone
# who installs DMGs signed with it. The flip side: any program signed with this identity
# and identifier gets those grants too, so the private key lives in a keychain of its
# own, ~/Library/Keychains/tabwheel-signing.keychain-db, locked except while building:
# the build asks for that keychain's password (it locks again after 5 idle minutes and
# on sleep). The first build creates it and asks for a new password; an identity left in
# the login keychain by preview builds is moved there (same certificate, so no grant
# has to be redone). --adhoc signs ad hoc instead: nothing to protect, but the grants
# have to be re-added after every build.
set -eu
ROOT=${0:a:h:h}
SRC=$ROOT/Sources/MousePilot/main.swift   # appVersion is read from here
SOURCES=($ROOT/Sources/MousePilot/*.swift)
BUILD=$ROOT/build
APP=$BUILD/MousePilot.app
IDENTITY="TabWheel Developer"
VERSION=$(sed -n 's/^let appVersion = "\([^"]*\)".*/\1/p' $SRC)
[[ -n $VERSION ]] || VERSION=0.0
TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT

SIGNING_KC=~/Library/Keychains/tabwheel-signing.keychain-db
LOGIN_KC=$(security login-keychain | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
KCTOOL=$TMP/keychain

signing_identity_valid() { security find-identity -v -p codesigning $SIGNING_KC 2>/dev/null | grep -q "\"$IDENTITY\"" }
# Certificate and private key both in the login keychain (where preview builds put them).
login_identity_hash() {
  security find-identity -p codesigning "$LOGIN_KC" 2>/dev/null | awk -v n="\"$IDENTITY\"" 'index($0, n) { print $2; exit }'
}

# Makes the signing identity usable, asking for passwords as needed. Runs in an `&&`
# list, where `set -e` is off: every step checks its own result.
ensure_identity() {
  swiftc -O $ROOT/Resources/keychain.swift -o $KCTOOL 2>/dev/null || { echo "keychain helper did not build" >&2; return 1; }
  if [[ ! -f $SIGNING_KC ]]; then
    echo "서명 전용 키체인을 만듭니다. 새 암호를 정하는 창이 뜹니다 (빌드할 때 이 암호를 묻습니다)."
    $KCTOOL create $SIGNING_KC || return 1
    security set-keychain-settings -l -u -t 300 $SIGNING_KC || return 1   # lock on sleep / after 5 idle minutes
  fi
  echo "서명 키체인을 엽니다 (잠겨 있으면 암호 창이 뜹니다)."
  $KCTOOL unlock $SIGNING_KC || return 1
  signing_identity_valid && return 0

  local hash; hash=$(login_identity_hash)
  if [[ -n $hash ]]; then
    # Move it (same certificate: the designated requirement and the grants stay valid).
    echo "로그인 키체인의 '$IDENTITY'를 서명 전용 키체인으로 옮깁니다. 내보내기를 허용하는 창이 뜹니다."
    local pass; pass=$(/usr/bin/openssl rand -hex 16)
    $KCTOOL export "$IDENTITY" "$LOGIN_KC" $TMP/identity.p12 $pass || return 1
    security import $TMP/identity.p12 -k $SIGNING_KC -P $pass -T /usr/bin/codesign >/dev/null || return 1
    rm -f $TMP/identity.p12
    if signing_identity_valid; then
      security delete-identity -Z $hash "$LOGIN_KC" >/dev/null 2>&1 \
        || echo "로그인 키체인의 '$IDENTITY'를 지우지 못했습니다. 키체인 접근에서 직접 지우세요." >&2
      return 0
    fi
    echo "옮긴 인증서가 서명용으로 인식되지 않습니다." >&2
    return 1
  fi

  echo "코드 서명 인증서 '$IDENTITY'를 서명 전용 키체인에 만듭니다 (처음 한 번)."
  # /usr/bin/openssl (LibreSSL) on purpose: PKCS#12 files from OpenSSL 3 use
  # algorithms `security import` does not accept.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$IDENTITY" \
    -keyout $TMP/key.pem -out $TMP/cert.pem -config $ROOT/Resources/codesign-cert.cnf 2>/dev/null || return 1
  local pass; pass=$(/usr/bin/openssl rand -hex 16)
  /usr/bin/openssl pkcs12 -export -inkey $TMP/key.pem -in $TMP/cert.pem -out $TMP/identity.p12 \
    -name "$IDENTITY" -passout pass:$pass || return 1
  security import $TMP/identity.p12 -k $SIGNING_KC -P $pass -T /usr/bin/codesign >/dev/null || return 1
  rm -f $TMP/key.pem $TMP/identity.p12   # the private key now lives only in the signing keychain
  echo "→ 인증서를 코드 서명용으로 신뢰하는 설정에 macOS 암호 창이 뜹니다."
  security add-trusted-cert -p codeSign -k $SIGNING_KC $TMP/cert.pem || return 1
  signing_identity_valid
}

SIGN="-"
if [[ " $* " != *" --adhoc "* ]]; then
  if ensure_identity; then
    SIGN=$IDENTITY
  else
    echo "서명 키체인을 쓸 수 없어 ad-hoc으로 서명합니다 (설치하면 권한을 다시 허용해야 합니다)." >&2
  fi
fi

rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
for arch in arm64 x86_64; do
  swiftc -O -target $arch-apple-macos13 $SOURCES -o $TMP/mousepilot-$arch
done
lipo -create $TMP/mousepilot-arm64 $TMP/mousepilot-x86_64 -output $APP/Contents/MacOS/mousepilot

if [[ ! -f $BUILD/AppIcon.icns ]]; then
  swiftc $ROOT/Resources/makeicon.swift -o $TMP/makeicon && $TMP/makeicon $TMP/icon.png
  mkdir $TMP/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s $TMP/icon.png --out $TMP/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) $TMP/icon.png --out $TMP/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $TMP/AppIcon.iconset -o $BUILD/AppIcon.icns
fi
cp $BUILD/AppIcon.icns $APP/Contents/Resources/AppIcon.icns

cat > $APP/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.pms.mousepilot</string>
  <key>CFBundleName</key><string>MousePilot</string>
  <key>CFBundleDisplayName</key><string>MousePilot</string>
  <key>CFBundleExecutable</key><string>mousepilot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>Wheel over a browser tab strip switches tabs.</string>
  <key>MousePilotCommandLine</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>뒤에 있거나 포커스가 없는 브라우저 창의 탭을 창을 앞으로 가져오지 않고 바꾸고, 마우스 제스처 ↓←(시크릿창에서 열기)로 지금 페이지를 새 시크릿 창에서 열 때 필요합니다. (Switches tabs in background browser windows without bringing them forward, and opens the current page in a new incognito window for the ↓← gesture.)</string>
</dict></plist>
P
sign_from=(); [[ $SIGN != "-" ]] && sign_from=(--keychain $SIGNING_KC)
if ! out=$(codesign -f -s "$SIGN" "${sign_from[@]}" -i com.pms.mousepilot --options runtime \
            --entitlements $ROOT/Resources/MousePilot.entitlements --timestamp=none $APP 2>&1); then
  print -r -- "$out"; echo "codesign failed" >&2; exit 1
fi
codesign --verify --strict $APP
echo "built $APP v$VERSION ($(lipo -archs $APP/Contents/MacOS/mousepilot)), signed by: ${$(codesign -dvv $APP 2>&1 | sed -n 's/^Authority=//p' | head -1):-ad-hoc}"

requirement() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p' }

for opt in "$@"; do
  case $opt in
    --install)
      old_req=$(requirement /Applications/MousePilot.app 2>/dev/null || true)
      if pgrep -U $UID -xq mousepilot; then
        osascript -e 'tell application id "com.pms.mousepilot" to quit' >/dev/null 2>&1 || true
        for i in {1..25}; do pgrep -U $UID -xq mousepilot || break; sleep 0.2; done
        if pgrep -U $UID -xq mousepilot; then
          echo "MousePilot did not quit; not replacing the running app (quit it from the menu bar icon)" >&2
          exit 1
        fi
      fi
      rm -rf /Applications/MousePilot.app
      ditto $APP /Applications/MousePilot.app
      open /Applications/MousePilot.app
      echo "installed /Applications/MousePilot.app"
      if [[ -n $old_req && $old_req != $(requirement /Applications/MousePilot.app) ]]; then
        echo "서명 기준이 바뀌어 손쉬운 사용 권한을 다시 허용해야 합니다 (이번 한 번):"
        echo "  시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 MousePilot을 − 로 지우고 다시 추가"
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      fi ;;
    --dmg)
      mkdir -p $ROOT/dist $TMP/dmg
      ditto $APP $TMP/dmg/MousePilot.app
      ln -s /Applications $TMP/dmg/Applications
      cp $ROOT/Resources/INSTALL.txt $TMP/dmg/"설치 방법.txt"
      OUT=$ROOT/dist/MousePilot-$VERSION.dmg
      rm -f $OUT
      # hdiutil prints a deprecation notice on stderr; keep real errors fatal.
      if ! log=$(hdiutil create -volname MousePilot -srcfolder $TMP/dmg -fs HFS+ -format UDZO -ov $OUT 2>&1); then
        print -r -- "$log"; exit 1
      fi
      echo "made $OUT" ;;
  esac
done
