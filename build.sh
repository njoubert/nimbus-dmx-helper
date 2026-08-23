#!/usr/bin/env bash
# Build, run, package and install Nimbus DMX Helper — the Enttec DMX USB Pro companion.
#
#   ./build.sh              debug build → .build/debug/{NimbusDMXHelper,dmxcli}
#   ./build.sh run [args]   debug build, then launch the app in the foreground. Args pass
#                           through: --connect, --high-speed, --demo, --monitor, --screenshot PATH
#   ./build.sh cli ...      debug build, then run dmxcli   (e.g. ./build.sh cli halo 50 3200)
#   ./build.sh app          release build → dist/Nimbus DMX Helper.app (icon baked in) and open it
#   ./build.sh dmg          release build → dist/NimbusDMXHelper-<version>.dmg, the
#                           drag-to-Applications disk image (background from DMGBackground.swift)
#   ./build.sh install      release build → /Applications, replacing any older copy
#   ./build.sh uninstall    quit and delete /Applications/Nimbus DMX Helper.app
#   ./build.sh status       running? installed? how is it signed?
#   ./build.sh icon         re-render docs/icon.png from Sources/DMXCore/AppIcon.swift
#   ./build.sh social       re-render docs/social-preview.png from Sources/DMXCore/SocialCard.swift
#                           — GitHub's link-preview card. Upload it by hand under the repo's
#                           Settings › General › Social preview; GitHub has no API for it.
#   ./build.sh clean        remove build products
#
# Signing: release bundles (app / dmg / install) are ad-hoc signed unless a Developer ID is
# configured, in which case they are signed with it, hardened-runtime, timestamped, and the
# disk image is notarized and stapled. Configure it in a git-ignored ./.signing file (or the
# environment):
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=<profile>         # the name given to: xcrun notarytool store-credentials <profile> …
#                                  (credentials are per Apple ID + team, so one profile serves every project)
# Debug builds (run / cli) stay ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

NAME=NimbusDMXHelper          # executable / target / process name
APP_NAME="Nimbus DMX Helper"  # what the user sees: the .app, the disk image volume
BUNDLE_ID=com.njoubert.nimbusdmxhelper
VERSION=1.2
INSTALL_DIR=/Applications
INSTALLED="$INSTALL_DIR/$APP_NAME.app"
REL_APP="dist/$APP_NAME.app"
DMG="dist/$NAME-$VERSION.dmg"
ZIP="dist/$NAME-$VERSION.zip"     # what the auto-updater downloads; a release needs both

# Developer ID signing / notarization, off unless configured (see the header).
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -f .signing ]; then
  # shellcheck source=/dev/null
  . ./.signing
fi

# --- helpers -----------------------------------------------------------------------------

dim=$'\033[2m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
say()  { printf '%s%s%s\n' "$green" "$*" "$reset"; }
note() { printf '%s%s%s\n' "$dim" "$*" "$reset"; }
warn() { printf '%s%s%s\n' "$yellow" "$*" "$reset" >&2; }

# Assemble the .app around the release binary: icon, Info.plist, LICENSE, signature.
make_bundle() {
  swift build -c release --product "$NAME"
  swift build -c release --product dmxcli
  rm -rf "$REL_APP"
  mkdir -p "$REL_APP/Contents/MacOS" "$REL_APP/Contents/Resources"
  cp ".build/release/$NAME" "$REL_APP/Contents/MacOS/$NAME"
  cp LICENSE "$REL_APP/Contents/Resources/LICENSE"

  # The icon is drawn in code; render it to an .iconset and let iconutil pack it.
  .build/release/dmxcli icon --iconset dist/AppIcon.iconset >/dev/null
  iconutil -c icns dist/AppIcon.iconset -o "$REL_APP/Contents/Resources/AppIcon.icns"
  rm -rf dist/AppIcon.iconset

  cat > "$REL_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
  plutil -convert xml1 -o /dev/null "$REL_APP/Contents/Info.plist"   # validate (plutil -lint misparses here)

  if [ -n "$SIGN_IDENTITY" ]; then
    # Hardened runtime + secure timestamp are what notarization requires. No entitlements:
    # the widget is a /dev/cu.* serial device, which needs no exception outside the sandbox.
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp --identifier "$BUNDLE_ID" "$REL_APP"
    codesign --verify --strict --deep "$REL_APP"
    note "bundled $REL_APP  (signed: $SIGN_IDENTITY)"
  else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$REL_APP" >/dev/null 2>&1 || warn "codesign failed (continuing unsigned)"
    note "bundled $REL_APP  (ad-hoc signed)"
  fi
}

# Send something to Apple's notary service and staple the ticket to it.
#   notarize <path to submit> <path to staple>
notarize() {
  local submit=$1 staple=$2
  say "notarizing $(basename "$submit") — this waits on Apple, usually a few minutes"
  if ! xcrun notarytool submit "$submit" --keychain-profile "$NOTARY_PROFILE" --wait; then
    warn "notarization failed; for the reason run:"
    warn "  xcrun notarytool log <submission id> --keychain-profile $NOTARY_PROFILE"
    return 1
  fi
  xcrun stapler staple -q "$staple"
  note "stapled $staple"
}

# Notarize the app itself, so a copy dragged out of the disk image verifies offline too.
notarize_app() {
  local zip="dist/$NAME-notarize.zip"
  [ -n "$NOTARY_PROFILE" ] || { warn "no NOTARY_PROFILE: app signed but not notarized"; return 0; }
  rm -f "$zip"
  ditto -c -k --keepParent "$REL_APP" "$zip"
  notarize "$zip" "$REL_APP"
  rm -f "$zip"
}

# Quit every running copy and wait for it to go away. A running copy holds the serial port
# (and its own binary), so this has to happen before replacing or launching one.
stop_all() {
  if pgrep -x "$NAME" >/dev/null; then
    pkill -x "$NAME" || true
    for _ in $(seq 1 30); do pgrep -x "$NAME" >/dev/null || break; sleep 0.1; done
    if pgrep -x "$NAME" >/dev/null; then warn "still running, killing"; pkill -9 -x "$NAME" || true; sleep 0.3; fi
    say "stopped $APP_NAME"
  fi
}

# The auto-updater's asset: the stapled app, zipped with ditto (which keeps symlinks and
# extended attributes, so the signature and the notarization ticket survive). Must run after
# notarize_app, or the download is the pre-staple copy.
#   make_zip <out.zip>
make_zip() {
  local out=$1
  rm -f "$out"
  ditto -c -k --keepParent "$REL_APP" "$out"
  note "packed $out ($(du -h "$out" | cut -f1))"
}

# Wrap the app in the usual drag-to-Applications disk image: the app, an Applications alias,
# and a background picture that says what to do. Finder keeps icon positions / background /
# window size in the volume's .DS_Store, and the only supported way to write that is to ask
# Finder — hence the AppleScript (the first run prompts for permission to control Finder).
make_dmg() {
  local out=$1
  local staging="dist/dmg-staging" rw="dist/$NAME-rw.dmg" vol="/Volumes/$APP_NAME"

  rm -rf "$staging" "$rw"
  mkdir -p "$staging/.background"
  ditto "$REL_APP" "$staging/$APP_NAME.app"
  ln -s /Applications "$staging/Applications"
  cp LICENSE "$staging/.LICENSE"    # hidden: present, but not a third icon to drag
  local bgflags=()
  [ -n "$SIGN_IDENTITY" ] && bgflags+=(--signed)   # drops the "unsigned build" footer
  .build/release/dmxcli dmg-background --dir "$staging/.background" "${bgflags[@]+"${bgflags[@]}"}" >/dev/null
  # One TIFF holding the 1× and 2× renders, so Finder picks the sharp one on Retina.
  tiffutil -cathidpicheck "$staging/.background/background.png" "$staging/.background/background@2x.png" \
    -out "$staging/.background/background.tiff" >/dev/null 2>&1
  rm "$staging/.background/background.png" "$staging/.background/background@2x.png"

  # A stale mount from an earlier run would make this one land on "/Volumes/$APP_NAME 1".
  if [ -d "$vol" ]; then hdiutil detach "$vol" -quiet -force || true; fi
  hdiutil create -volname "$APP_NAME" -srcfolder "$staging" -ov -format UDRW -fs HFS+ -quiet "$rw"
  local dev
  dev=$(hdiutil attach -readwrite -noverify -noautoopen "$rw" | awk '/^\/dev\// {print $1; exit}')
  [ -d "$vol" ] || { warn "mount failed"; hdiutil detach "$dev" -quiet || true; return 1; }

  # Geometry matches DMGBackground.swift: 640×440 window, icon centres at (170,210) / (470,210).
  osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    -- Finder remembers the (hidden) sidebar's width and adds it back on reopen unless zeroed.
    set sidebar width of container window to 0
    -- bounds include the 28 pt title bar.
    set the bounds of container window to {200, 120, 840, 588}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 12
    set label position of opts to bottom
    set background picture of opts to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {170, 210}
    set position of item "Applications" of container window to {470, 210}
    close
    open
    set sidebar width of container window to 0
    set the bounds of container window to {200, 120, 840, 588}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  sync
  rm -rf "$vol/.fseventsd"
  chmod -Rf go-w "$vol" || true
  hdiutil detach "$dev" -quiet
  rm -f "$out"
  hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -quiet -o "$out"
  rm -rf "$rw" "$staging"
  if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$out"
    if [ -n "$NOTARY_PROFILE" ]; then
      notarize "$out" "$out"
      spctl -a -t open --context context:primary-signature -v "$out" 2>&1 | sed 's/^/  /' || true
    fi
  else
    codesign --force --sign - "$out" >/dev/null 2>&1 || true
  fi
  note "packed $out ($(du -h "$out" | cut -f1))"
}

# --- commands ----------------------------------------------------------------------------

cmd="${1:-build}"
[ $# -gt 0 ] && shift

case "$cmd" in
  build)
    swift build
    say "ok → .build/debug/$NAME, .build/debug/dmxcli"
    ;;

  run)
    swift build
    exec ".build/debug/$NAME" "$@"
    ;;

  cli)
    swift build --product dmxcli >/dev/null
    exec .build/debug/dmxcli "$@"
    ;;

  app)
    make_bundle
    [ -n "$SIGN_IDENTITY" ] && notarize_app
    say "built $REL_APP"
    open "$REL_APP"
    ;;

  dmg)
    make_bundle
    [ -n "$SIGN_IDENTITY" ] && notarize_app
    make_zip "$ZIP"
    make_dmg "$DMG"
    say "built $DMG"
    note "Test it: open $DMG"
    ;;

  # Everything a release needs: both artefacts, the tag, the publish. Refuses a dirty tree or
  # a commit that is not the version's tag.
  release)
    notes=${1:-}
    if [ -z "$notes" ] || [ ! -f "$notes" ]; then
      warn "usage: ./build.sh release NOTES.md   (the GitHub release body)"
      exit 2
    fi
    if [ -n "$(git status --porcelain)" ]; then
      warn "working tree is dirty; commit first"
      exit 1
    fi
    tag="v$VERSION"
    if git rev-parse "$tag" >/dev/null 2>&1; then
      if [ "$(git rev-parse "$tag^{commit}")" != "$(git rev-parse HEAD)" ]; then
        warn "$tag exists but is not HEAD"
        exit 1
      fi
    else
      git tag -a "$tag" -m "$APP_NAME $VERSION"
      note "tagged $tag"
    fi
    "$0" dmg
    # The requirements auto-update depends on, checked while it can still be undone: identity,
    # signature, version, and whether the copies people already have would accept this build.
    swift build --product dmxcli >/dev/null
    .build/debug/dmxcli preflight "$REL_APP"
    git push origin main
    git push origin "$tag"
    if command -v gh >/dev/null 2>&1; then
      gh release create "$tag" "$DMG" "$ZIP" --title "$APP_NAME $VERSION" --notes-file "$notes"
      say "published $tag"
    else
      warn "gh is not installed; publish by hand:"
      note "gh release create $tag $DMG $ZIP --title \"$APP_NAME $VERSION\" --notes-file $notes"
    fi
    note "the updater needs $(basename "$ZIP") on the release — a DMG-only release is invisible to it"
    ;;

  install)
    make_bundle
    [ -n "$SIGN_IDENTITY" ] && notarize_app
    stop_all
    if [ -e "$INSTALLED" ]; then
      note "replacing $INSTALLED"
      rm -rf "$INSTALLED"
    fi
    ditto "$REL_APP" "$INSTALLED"
    say "installed $INSTALLED"
    note "open with: open -a \"$APP_NAME\""
    ;;

  uninstall)
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
    rm -rf "$INSTALL_DIR/.$NAME-old.app" "$INSTALL_DIR/.$NAME-update.app"
    stop_all
    if [ -e "$INSTALLED" ]; then
      rm -rf "$INSTALLED"
      say "removed $INSTALLED"
    else
      note "$INSTALLED is not installed"
    fi
    ;;

  status)
    if pgrep -x "$NAME" >/dev/null; then
      say "running: $(pgrep -x "$NAME" | tr '\n' ' ')"
    else
      note "not running"
    fi
    if [ -e "$INSTALLED" ]; then
      say "installed: $INSTALLED (v$(defaults read "$INSTALLED/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?'))"
      sig=$(codesign -dv --verbose=2 "$INSTALLED" 2>&1 || true)
      auth=$(printf '%s\n' "$sig" | grep -m1 '^Authority=' | cut -d= -f2- || true)
      gate=$(spctl -a -t exec -v "$INSTALLED" 2>&1 || true)
      note "signed by: ${auth:-ad-hoc (no identity)}  ·  Gatekeeper: ${gate#*: }"
    else
      note "not installed in $INSTALL_DIR"
    fi
    ;;

  icon)
    swift build --product dmxcli >/dev/null
    .build/debug/dmxcli icon --png docs/icon.png --size 512
    ;;

  social)
    swift build --product dmxcli >/dev/null
    .build/debug/dmxcli social --png docs/social-preview.png
    ;;

  clean)
    rm -rf .build dist
    ;;

  *)
    sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
