#!/bin/sh
# Shared by the Debian support installer and APT package manager, per environment.
# Every LinuxRunner package operation (installer-run.sh, package-manager.sh)
# takes this lock, then waits until Debian's first-start configuration
# (init.sh -> initialize-debian.sh -> dpkg --configure -a) and any other
# dpkg/apt process have finished. Locks are never unlinked and package
# processes are never killed here.
package_lock_acquire() {
    mkdir -p /var/lib/linuxrunner || return 1
    if command -v flock >/dev/null 2>&1; then
        [ ! -L /var/lib/linuxrunner/package-operation.lock ] || return 75
        exec 9>>/var/lib/linuxrunner/package-operation.lock || return 1
        flock -n 9 || { echo 'PACKAGE_LOCK: category=PACKAGE_MANAGER_BUSY managed operation already running'; return 75; }
        [ "${1:-}" = defer-ready ] || package_system_ready
        return $?
    fi
    lock=/var/lib/linuxrunner/package-operation.lock.d
    if ! mkdir "$lock" 2>/dev/null; then
        [ ! -L "$lock" ] || { echo 'PACKAGE_LOCK: unsafe symlink'; return 75; }
        owner=$(cat "$lock/pid" 2>/dev/null || true)
        case "$owner" in ''|*[!0-9]*)
            created=$(stat -c %Y "$lock" 2>/dev/null || date +%s); now=$(date +%s)
            [ "$((now-created))" -ge 60 ] || { echo 'PACKAGE_LOCK: owner publication pending'; return 75; }
            owner=0;;
        esac
        if [ "$owner" != 0 ] && kill -0 "$owner" 2>/dev/null; then
            echo "PACKAGE_LOCK: category=PACKAGE_MANAGER_BUSY managed operation already running pid=$owner"; return 75
        fi
        echo 'PACKAGE_LOCK: recovering abandoned LinuxRunner lock (its owner is gone)'
        rm -f "$lock/pid"; rmdir "$lock" || return 75; mkdir "$lock" || return 75
    fi
    echo $$ > "$lock/pid"
    trap 'rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true' EXIT
    [ "${1:-}" = defer-ready ] || package_system_ready
}

package_processes() {
    for lr_proc in /proc/[0-9]*; do
        lr_pid=${lr_proc#/proc/}
        [ "$lr_pid" != "$$" ] || continue
        lr_cmd=$( { tr '\000' ' ' < "$lr_proc/cmdline"; } 2>/dev/null) || continue
        lr_arg0=${lr_cmd%% *} lr_rest=${lr_cmd#* }; lr_arg1=${lr_rest%% *}
        case "${lr_arg0##*/}" in
            dpkg|apt-get|apt|aptitude|unattended-upgrade|initialize-debian.sh) echo "$lr_pid $lr_cmd";;
            sh|dash|bash) case "${lr_arg1##*/}" in initialize-debian.sh) echo "$lr_pid $lr_cmd";; esac;;
            *) case "$lr_arg0" in /usr/lib/apt/methods/*) echo "$lr_pid $lr_cmd";; esac;;
        esac
    done
}

# Wait for Debian's first-start configuration and for any other package
# operation. Fails with PACKAGE_MANAGER_STUCK only when nothing progresses
# for 15 minutes.
package_system_ready() {
    if [ -x /usr/lib/linuxrunner/initialize-debian.sh ] && [ "$(id -u)" = 0 ]; then
        if [ -d /etc/apt/apt.conf.d ] && [ ! -e /etc/apt/apt.conf.d/90linuxrunner-lock-wait ]; then
            printf 'DPkg::Lock::Timeout "900";\n' > /etc/apt/apt.conf.d/90linuxrunner-lock-wait.new &&
                mv /etc/apt/apt.conf.d/90linuxrunner-lock-wait.new /etc/apt/apt.conf.d/90linuxrunner-lock-wait
        fi
        lr_init_log=/var/log/linuxrunner-initialize.log lr_last= lr_idle=0 lr_named=
        while [ ! -f /var/lib/linuxrunner/initialized ]; do
            if ! package_processes | grep -q -e 'initialize-debian.sh' -e 'dpkg' && sleep 5 &&
                ! package_processes | grep -q -e 'initialize-debian.sh' -e 'dpkg'; then
                echo 'PACKAGE_STAGE: Finishing Debian setup (first start)'
                if ! /usr/lib/linuxrunner/initialize-debian.sh >> "$lr_init_log" 2>&1; then
                    echo 'PACKAGE_LOCK: category=PACKAGE_DATABASE_RECOVERY_REQUIRED Debian first-start configuration failed'
                    tail -n 8 "$lr_init_log" | sed 's/^/PACKAGE_DETAIL: /'
                    return 1
                fi
                continue
            fi
            lr_configured=$(grep -c '^Setting up ' "$lr_init_log" 2>/dev/null || true)
            lr_pending=$(dpkg-query -W -f '${Status}\n' 2>/dev/null | grep -c 'unpacked\|half-configured' || true)
            lr_current=$(grep '^Setting up ' "$lr_init_log" 2>/dev/null | tail -n 1 | cut -d' ' -f3)
            [ -n "$lr_named" ] || { lr_named=1; package_processes | sed 's/^/PACKAGE_DETAIL: waiting for /'; }
            if [ "$lr_configured" != "$lr_last" ]; then
                lr_last=$lr_configured lr_idle=0
                echo "PACKAGE_STAGE: Finishing Debian setup (first start): ${lr_configured:-0} packages configured${lr_current:+, now $lr_current}"
                echo "PACKAGE_PROGRESS: ${lr_configured:-0} $(( ${lr_configured:-0} + ${lr_pending:-0} ))"
            else
                lr_idle=$((lr_idle+3))
            fi
            if [ "$lr_idle" -ge 900 ]; then
                echo "PACKAGE_LOCK: category=PACKAGE_MANAGER_STUCK Debian first-start configuration made no progress for 15 minutes (last: ${lr_current:-none})"
                package_processes | sed 's/^/PACKAGE_DETAIL: running /'
                return 1
            fi
            sleep 3
        done
    fi
    lr_waited=0
    while :; do
        lr_others=$(package_processes)
        [ -n "$lr_others" ] || break
        [ "$lr_waited" -gt 0 ] || { echo 'PACKAGE_STAGE: Waiting for another package installation to finish'; printf '%s\n' "$lr_others" | sed 's/^/PACKAGE_DETAIL: running /'; }
        lr_waited=$((lr_waited+3))
        [ "$lr_waited" -lt 1800 ] || { echo 'PACKAGE_LOCK: category=PACKAGE_MANAGER_BUSY another package operation is still running after 30 minutes'; return 75; }
        sleep 3
    done
    return 0
}
