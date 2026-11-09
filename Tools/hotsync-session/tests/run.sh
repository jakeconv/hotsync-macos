#!/bin/bash
# Runs hotsync-session against fake-pisock (an in-memory Palm, no device
# needed) with the commands in commands.txt and compares its output with
# expected.txt. Needs the pilot-link headers: ./Scripts/build.sh (or
# Scripts/build-pilot-link.sh) builds them into .build/pilot-link/install,
# or set PILOT_PREFIX.
#
#   Tools/hotsync-session/tests/run.sh           compare
#   Tools/hotsync-session/tests/run.sh --update  write expected.txt anew
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
PILOT_PREFIX="${PILOT_PREFIX:-$PROJECT_DIR/.build/pilot-link/install}"
WORK_DIR="$PROJECT_DIR/.build/session-tests"

if [ ! -f "$PILOT_PREFIX/include/pi-dlp.h" ]; then
    echo "pilot-link headers not found in $PILOT_PREFIX/include" >&2
    echo "build them first (./Scripts/build-pilot-link.sh) or set PILOT_PREFIX" >&2
    exit 1
fi

mkdir -p "$WORK_DIR"
# macOS gets htons/htonl from its headers; elsewhere they need arpa/inet.h
${CC:-cc} -std=c99 -D_DEFAULT_SOURCE -include arpa/inet.h -Wall -Wextra -Werror -O1 \
    -I"$PILOT_PREFIX/include" \
    -o "$WORK_DIR/hotsync-session-fake" \
    "$PROJECT_DIR/Tools/hotsync-session/hotsync-session.c" "$TEST_DIR/fake-pisock.c"

"$WORK_DIR/hotsync-session-fake" --port fake: < "$TEST_DIR/commands.txt" > "$WORK_DIR/output.txt"

# A record near the 64 KB limit: a command line of about 120 KB, read back
# byte for byte
BIG_HEX="$(head -c 60000 /dev/zero | tr '\0' 'Z' | od -v -An -tx1 | tr -d ' \n')"
printf 'opendb write MemoDB\nwriterec 0 0 3 %s\nreadall\nend\n' "$BIG_HEX" \
    | "$WORK_DIR/hotsync-session-fake" --port fake: > "$WORK_DIR/big.txt"
if ! grep -q "\"category\":3,\"data\":\"$BIG_HEX\"" "$WORK_DIR/big.txt"; then
    echo "hotsync-session: a 60,000-byte record did not come back unchanged" >&2
    exit 1
fi

if [ "${1:-}" = "--update" ]; then
    cp "$WORK_DIR/output.txt" "$TEST_DIR/expected.txt"
    echo "expected.txt updated"
    exit 0
fi
if diff -u "$TEST_DIR/expected.txt" "$WORK_DIR/output.txt"; then
    echo "hotsync-session: all record commands as expected"
else
    echo "hotsync-session: output differs from expected.txt (see above)" >&2
    exit 1
fi
