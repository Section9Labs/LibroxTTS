#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-run}"
CONFIGURATION="${CONFIGURATION:-release}"
CLOUD_ENVIRONMENT="${COMPANION_CLOUD_ENVIRONMENT:-Production}"
APP="$ROOT/dist/Librox Companion.app"
BUNDLE_ID="com.section9labs.Libros.Companion"
cd "$ROOT"

# Ask the running application to take its cancel/join path; do not kill a
# producer while it owns an encoder, CloudKit upload or worker claim.
if pgrep -x LibroxCompanion >/dev/null; then
    osascript -e 'tell application id "com.section9labs.Libros.Companion" to quit'
    for attempt in {1..60}; do
        if ! pgrep -x LibroxCompanion >/dev/null; then break; fi
        sleep 1
    done
    if pgrep -x LibroxCompanion >/dev/null; then
        echo "Companion is still joining active work. Build stopped; retry after it quits." >&2
        exit 1
    fi
fi

swift build -c "$CONFIGURATION" --product LibroxCompanion
PRODUCTS="$(swift build -c "$CONFIGURATION" --show-bin-path)"
STAGE="$ROOT/dist/.LibroxCompanion-staging.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$PRODUCTS/LibroxCompanion" "$STAGE/Contents/MacOS/LibroxCompanion"
for resource in "$PRODUCTS"/*.bundle; do
    [ -d "$resource" ] || continue
    ditto "$resource" "$STAGE/Contents/Resources/$(basename "$resource")"
done
python3 - "$STAGE" <<'PY'
import pathlib,plistlib,sys
bundle=pathlib.Path(sys.argv[1])
info={
 'CFBundleExecutable':'LibroxCompanion','CFBundleIdentifier':'com.section9labs.Libros.Companion',
 'CFBundleName':'Librox Companion','CFBundleDisplayName':'Librox Companion','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'0.1','CFBundleVersion':'1','LSMinimumSystemVersion':'15.0',
 'LSUIElement':True,'NSPrincipalClass':'NSApplication',
 'CFBundleDocumentTypes':[{'CFBundleTypeName':'Books','CFBundleTypeRole':'Viewer',
   'LSHandlerRank':'Alternate','CFBundleTypeExtensions':['epub','txt','libroxbook']}]
}
(bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY

# The existing Companion profile is inspected, not manufactured. Local builds
# may use either permitted iCloud environment. Production reads the live library.
python3 - "$STAGE" "$ROOT/dist/companion.entitlements" "$CLOUD_ENVIRONMENT" <<'PY'
import datetime,pathlib,plistlib,subprocess,sys
bundle=pathlib.Path(sys.argv[1]); profile=None; environment=sys.argv[3]
if environment not in ('Development','Production'): raise SystemExit('Invalid CloudKit environment')
roots=[pathlib.Path.home()/'Library/Developer/Xcode/UserData/Provisioning Profiles',
       pathlib.Path.home()/'Library/MobileDevice/Provisioning Profiles']
for root in roots:
 for candidate in root.glob('*'):
  result=subprocess.run(['security','cms','-D','-i',str(candidate)],capture_output=True)
  try: data=plistlib.loads(result.stdout)
  except Exception: continue
  entitlements=data.get('Entitlements',{})
  if (entitlements.get('com.apple.application-identifier')=='995PCLM9KH.com.section9labs.Libros.Companion'
      and environment in entitlements.get('com.apple.developer.icloud-container-environment',[])
      and data['ExpirationDate']>datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)):
   profile=candidate; break
 if profile: break
if profile is None: raise SystemExit('Install a valid Librox Companion Mac provisioning profile before running this build.')
(bundle/'Contents/embedded.provisionprofile').write_bytes(profile.read_bytes())
entitlements={'com.apple.application-identifier':'995PCLM9KH.com.section9labs.Libros.Companion',
 'com.apple.developer.team-identifier':'995PCLM9KH',
 'com.apple.developer.icloud-container-identifiers':['iCloud.com.section9labs.Libros'],
 'com.apple.developer.icloud-services':['CloudKit'],
 'com.apple.developer.icloud-container-environment':environment}
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(entitlements))
PY
IDENTITY="${COMPANION_SIGNING_IDENTITY:-E96C00F14EF8F2937CD600CBD35A806FF8E45AAE}"
codesign --force --deep --sign "$IDENTITY" --entitlements "$ROOT/dist/companion.entitlements" "$STAGE"
codesign --verify --deep --strict "$STAGE"
if [ -e "$APP" ]; then mv "$APP" "$ROOT/dist/Librox Companion.previous-$(date +%s).app"; fi
mv "$STAGE" "$APP"

case "$MODE" in
    --build) echo "$APP" ;;
    run) open -n "$APP" ;;
    --verify) open -n "$APP"; sleep 2; pgrep -x LibroxCompanion ;;
    --debug) lldb -- "$APP/Contents/MacOS/LibroxCompanion" ;;
    --logs|--telemetry) open -n "$APP"; /usr/bin/log stream --info --style compact --predicate 'process == "LibroxCompanion"' ;;
    *) echo "Usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
