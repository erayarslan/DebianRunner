#!/bin/sh
# DebianRunner Debian minimal support installer, run as root inside Debian via
# installer-run.sh.
#   debian-support.sh accounts [sudo]   ensure account tools (and sudo) exist
#   debian-support.sh mode-ssh          install OpenSSH server and generate host keys
set -u
cd "$(dirname "$0")"
. ./support-common.sh
mode=${1:-}
have() { command -v "$1" >/dev/null 2>&1; }
stage() { echo "PROFILE_STAGE: $1"; }

accounts_missing() {
    have passwd || return 0
    have chpasswd || return 0
    have useradd || have adduser || return 0
    return 1
}

apt_log=/tmp/linuxrunner-profile-apt.$$
trap 'rm -f "$apt_log" "$apt_log.update"' EXIT

classify_failure() {
    what=$1; text=$(cat "$apt_log" 2>/dev/null)
    if printf '%s\n' "$text" | grep -qE 'Unable to locate package|has no installation candidate' &&
        grep -qE '^(Err:|W: Failed to fetch|E: Failed to fetch)' "$apt_log.update" 2>/dev/null; then
        text=$(grep -E '^(Err:|W: |E: )|^  ' "$apt_log.update"; printf '%s\n' "$text")
    fi
    first() { printf '%s\n' "$text" | grep -m 1 -E "$1"; }
    if line=$(first 'Could not get lock|frontend lock|is locked by|unable to lock database'); then category=PACKAGE_MANAGER_BUSY
    elif line=$(first 'certificate verify failed|Certificate verification failed|server certificate'); then
        category=TLS_CERTIFICATE_ERROR
        [ -s /etc/ssl/certs/ca-certificates.crt ] || line="$line (trust store /etc/ssl/certs/ca-certificates.crt missing: Debian setup unfinished)"
    elif line=$(first 'Temporary failure resolving|Could not resolve|Network is unreachable|Connection timed out|No route to host|Connection refused|failed retrieving file|failed to synchronize'); then category=NETWORK_UNAVAILABLE
    elif line=$(first 'No space left|You don.t have enough free space|Partition .* too full|not enough free disk space'); then category=INSUFFICIENT_STORAGE
    elif line=$(first 'Unable to locate package|has no installation candidate'); then category=PACKAGE_NOT_FOUND
    elif line=$(first 'Unmet dependencies|held broken packages|unmet dependenc|unable to satisfy dependency|conflicting dependencies|are in conflict'); then category=DEPENDENCY_CONFLICT
    elif line=$(first 'invalid or corrupted package|signature from .* is (unknown trust|invalid)|key .* could not be looked up|GPG check FAILED'); then category=REPOSITORY_METADATA_ERROR
    elif line=$(first 'dpkg was interrupted|dpkg --configure -a'); then category=PACKAGE_DATABASE_RECOVERY_REQUIRED
    elif line=$(first 'InRelease|Release file|NO_PUBKEY|not signed|Hash Sum mismatch|404'); then category=REPOSITORY_METADATA_ERROR
    elif line=$(first 'cap_set_file failed.*Operation not supported'); then category=FILESYSTEM_FEATURE_UNSUPPORTED
    elif line=$(first 'Read-only file system|Input/output error|Permission denied'); then category=FILESYSTEM_ERROR
    else category=UNKNOWN; line=$(printf '%s\n' "$text" | grep -E '^(E|W): ' | tail -n 1); fi
    echo "PROFILE_FAILURE: category=$category stage=$what detail=$line"
}

install_packages() {
    label=$1; shift
    [ "$#" -gt 0 ] || return 2
    have apt-get || { echo "PROFILE_FAILURE: category=UNKNOWN stage=$label detail=apt-get is missing"; return 1; }
    export DEBIAN_FRONTEND=noninteractive
    status_file="$PWD/apt-status"
    echo 'man-db man-db/auto-update boolean false' | debconf-set-selections 2>/dev/null || true
    if [ -z "${apt_updated:-}" ]; then
        if dpkg --audit 2>/dev/null | grep -q .; then
            stage "Finishing an interrupted installation"
            if ! dpkg --force-confdef --force-confold --configure -a >> "$apt_log" 2>&1; then
                stage "Repairing missing packages"
                apt-get -o APT::Status-Fd=3 -f install -y 3> "$status_file" >> "$apt_log" 2>&1 || { classify_failure "$label"; return 1; }
            fi
        fi
        stage "Checking package dependencies"
        if [ -n "$(find /var/lib/apt/lists -maxdepth 1 -name '*_InRelease' -mtime -3 2>/dev/null | head -n 1)" ] &&
            apt-get -s install --no-install-recommends "$@" > "$apt_log" 2>&1; then
            apt_updated=reused; echo 'PROFILE: package lists recent; reused'
        else
            stage "Downloading package lists"
            : > "$status_file"
            apt-get -o APT::Status-Fd=3 update 3> "$status_file" > "$apt_log" 2>&1 || { cat "$apt_log"; classify_failure "package lists"; return 1; }
            cat "$apt_log"; cp "$apt_log" "$apt_log.update"; apt_updated=1
        fi
    fi
    stage "Installing $label"
    : > "$status_file"
    if ! apt-get -o APT::Status-Fd=3 install -y --no-install-recommends "$@" 3> "$status_file" > "$apt_log" 2>&1; then
        if [ "$apt_updated" = reused ] && grep -qE '^(Err:|E: Failed to fetch)|404' "$apt_log"; then
            cat "$apt_log"; stage "Downloading package lists"; : > "$status_file"
            apt-get -o APT::Status-Fd=3 update 3> "$status_file" > "$apt_log" 2>&1 || { cat "$apt_log"; classify_failure "package lists"; return 1; }
            cat "$apt_log"; cp "$apt_log" "$apt_log.update"; apt_updated=1
            stage "Installing $label"; : > "$status_file"
            apt-get -o APT::Status-Fd=3 install -y --no-install-recommends "$@" 3> "$status_file" > "$apt_log" 2>&1 || { cat "$apt_log"; classify_failure "$label"; return 1; }
        else
            cat "$apt_log"; classify_failure "$label"; return 1
        fi
    fi
    cat "$apt_log"
}

[ "$(id -u)" = 0 ] || support_fail PROFILE root-required

case "$mode" in
    accounts)
        stage "Checking existing installation"
        if accounts_missing; then install_packages "account tools" passwd || support_fail PROFILE account-tools; else echo 'PROFILE: account tools already installed'; fi
        if [ "${2:-}" = sudo ] && ! have sudo; then install_packages "administrator tools" sudo || support_fail PROFILE sudo; fi
        stage "Verifying installation"
        accounts_missing && support_fail PROFILE account-tools-missing
        for tool in useradd chpasswd passwd; do
            "$tool" --help > /dev/null 2>&1 || { echo "PROFILE_FAILURE: category=ACCOUNT_TOOL_BROKEN stage=verify detail=$tool --help failed"; support_fail PROFILE account-tool-broken; }
        done
        if [ "${2:-}" = sudo ]; then
            sudo -V > /dev/null 2>&1 || { echo 'PROFILE_FAILURE: category=ACCOUNT_TOOL_BROKEN stage=verify detail=sudo -V failed'; support_fail PROFILE sudo-broken; }
        fi
        echo 'PROFILE: accounts=PASS';;
    mode-ssh)
        stage "Installing OpenSSH server"
        if [ ! -x /usr/sbin/sshd ]; then
            install_packages "OpenSSH server" openssh-server || support_fail PROFILE ssh-packages
        fi
        [ -x /usr/sbin/sshd ] || support_fail PROFILE sshd-missing
        stage "Generating SSH host keys"
        mkdir -p /run/sshd /etc/ssh
        chown 0:0 /run/sshd 2>/dev/null || true
        chmod 755 /run/sshd
        ssh-keygen -A >/dev/null 2>&1 || true
        echo 'PROFILE: mode-ssh=PASS';;
    *)
        echo "PROFILE: unknown mode '$mode'" >&2
        exit 2;;
esac
