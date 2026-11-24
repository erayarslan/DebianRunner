#!/bin/sh
# Normal UI installation entrypoint for Debian minimal support operations.
set -eu
cd "$(dirname "$0")"
case "${1:-}" in debian-support.sh) installer=$1;; *) exit 2;; esac
shift
for arg in "$@"; do
    case "$arg" in accounts|sudo|mode-agent|mode-ssh|mode-liftoff|mode-pocket) ;; *) exit 2;; esac
done
. ./package-lock.sh
# Refuse duplicates before altering the active operation's output.
package_lock_acquire defer-ready || exit $?
for file in install-result install-result.tmp "$installer.log" "$installer.log.previous"; do
    [ ! -L "$file" ] || exit 2
done
rm -f install-result
log="$installer.log"
if [ -f "$log" ]; then tail -c 1048576 "$log" > "$log.previous"; fi
printf 'SUPPORT_INSTALL: script=%s started; package output retained\n' "$installer" > "$log"
tail -n +1 -f "$log" & reader=$!
code=0
if package_system_ready >> "$log" 2>&1; then
    /bin/sh "./$installer" "$@" >> "$log" 2>&1 || code=$?
else
    code=$?
fi
kill "$reader" 2>/dev/null || true; wait "$reader" 2>/dev/null || true
printf '\nSUPPORT_INSTALL: script=%s exit=%s\n' "$installer" "$code" >> "$log"
tail -c 1048576 "$log" > "$log.trimmed" && mv "$log.trimmed" "$log"
tail -n 12 "$log"
printf '%s\n' "$code" > install-result.tmp; mv install-result.tmp install-result
exit "$code"
