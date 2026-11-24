#!/bin/sh
# Shared, environment-local checks. Metadata is parsed as data, never evaluated.
SUPPORT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cd "$SUPPORT_DIR"
SUPPORT_VERSION=$(cat support-version 2>/dev/null || true)
# Unattended dpkg configuration-file answers for managed apt runs; the user's
# own terminal apt is unaffected.
if [ -r "$SUPPORT_DIR/apt-unattended.conf" ] && [ -z "${APT_CONFIG:-}" ]; then export APT_CONFIG="$SUPPORT_DIR/apt-unattended.conf"; fi
support_fail() { echo "$1: result=FAIL reason=$2"; exit "${3:-1}"; }
verify_resources() {
    [ -n "$SUPPORT_VERSION" ] || support_fail SUPPORT_DEPLOY version-missing
    echo "SUPPORT_DEPLOY: version=$SUPPORT_VERSION destination=$SUPPORT_DIR"
    if ! resource_check=$(sha256sum -c support.sha256 2>&1); then
        printf '%s\n' "$resource_check"
        support_fail SUPPORT_DEPLOY checksum-or-resource-missing
    fi
    while read -r checksum resource; do
        case "$resource" in *.sh) [ -x "$resource" ] || chmod 755 "$resource" || support_fail SUPPORT_DEPLOY executable-permission-failed;; esac
    done < support.sha256
    echo 'SUPPORT_DEPLOY: source/scripts/checksums/modes=verified result=PASS'
}
metadata_value() { awk -F= -v key="$2" '$1==key {print substr($0,length(key)+2); exit}' "$1" 2>/dev/null; }
verify_shm_namespace() (
    prefix=$1
    [ -d /dev/shm ] || support_fail "$prefix" shared-memory-directory-missing
    mode=$(stat -c %a /dev/shm) || support_fail "$prefix" shared-memory-stat-failed
    [ -w /dev/shm ] && [ -x /dev/shm ] || support_fail "$prefix" shared-memory-directory-inaccessible
    probe=$(mktemp /dev/shm/.linuxrunner-check.XXXXXX) || support_fail "$prefix" shared-memory-file-create-failed
    rm "$probe" || support_fail "$prefix" shared-memory-file-unlink-failed
    echo "$prefix: shared_memory=/dev/shm mode=$mode create/unlink=PASS guest-page=$(getconf PAGESIZE)"
)
verify_elf() (
    prefix=$1; binary=$2
    [ -f "$binary" ] || support_fail "$prefix" "binary-missing:$binary" 127
    [ -x "$binary" ] || support_fail "$prefix" "executable-permission-missing:$binary" 126
    command -v readelf >/dev/null || support_fail "$prefix" readelf-missing
    header=$(readelf -h "$binary" 2>&1) || support_fail "$prefix" "invalid-linux-elf:$binary" 126
    printf '%s\n' "$header" | grep -q 'Machine:.*AArch64' || support_fail "$prefix" "invalid-architecture:$binary" 126
    printf '%s\n' "$header" | grep -q 'Class:.*ELF64' || support_fail "$prefix" "invalid-elf-class:$binary" 126
    loader=$(readelf -l "$binary" | sed -n 's/.*interpreter: \(.*\)\]/\1/p')
    [ -z "$loader" ] || [ -x "$loader" ] || support_fail "$prefix" "dynamic-loader-missing:$loader" 126
    dependencies=$(ldd "$binary" 2>&1) || { printf '%s\n' "$dependencies"; support_fail "$prefix" dynamic-dependency-failed 126; }
    if printf '%s\n' "$dependencies" | grep -Eq 'not found|Error loading|Error relocating'; then
        printf '%s\n' "$dependencies"; support_fail "$prefix" dynamic-library-missing 126
    fi
    echo "$prefix: executable_path=$binary exists=yes executable=yes architecture=aarch64 dependencies=resolved"
)
