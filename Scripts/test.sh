#!/bin/bash
# Runs the unit tests (HotSyncCore) and the hotsync-session tests. With only the Command Line Tools
# installed, swift-testing lives outside the default search paths.
set -euo pipefail
cd "$(dirname "$0")/.."

# hotsync-session against an in-memory Palm (needs the pilot-link headers,
# built by ./Scripts/build.sh); skipped until they exist
if [ -f .build/pilot-link/install/include/pi-dlp.h ] || [ -n "${PILOT_PREFIX:-}" ]; then
  Tools/hotsync-session/tests/run.sh
else
  echo "hotsync-session tests skipped: run ./Scripts/build.sh once to build the pilot-link headers"
fi

CLT=/Library/Developer/CommandLineTools/Library/Developer
if [ -d "$CLT/Frameworks/Testing.framework" ]; then
  exec swift test -Xswiftc -F"$CLT/Frameworks" -Xlinker -F"$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
