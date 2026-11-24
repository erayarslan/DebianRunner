#!/bin/sh
# DebianRunner built-in OpenSSH server controller, run headlessly as root.
#   modes.sh status                    write modes-status for the app
#   modes.sh start ssh [yes|no]        start OpenSSH server on :2222 (permit root: yes|no)
#   modes.sh stop ssh                  stop OpenSSH server cleanly
#   modes.sh restart ssh [yes|no]      restart OpenSSH server cleanly
set -u
cd "$(dirname "$0")" || exit 1
state=/run/linuxrunner-modes
mkdir -p "$state" && chmod 700 "$state"
ssh_port=2222

alive_pid() {
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

alive() {
    [ -s "$state/$1.pid" ] && alive_pid "$(cat "$state/$1.pid" 2>/dev/null)"
}

read_permit_root() {
    val=$(cat "$state/ssh.permit_root" 2>/dev/null || echo no)
    case "$val" in yes|no) echo "$val" ;; *) echo no ;; esac
}

wait_pid_exit() {
    pid=$1
    i=0
    while [ "$i" -lt 15 ]; do
        alive_pid "$pid" || return 0
        sleep 0.2 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.2 2>/dev/null || true
}

stop_ssh() {
    for pf in "$state/ssh.pid" "$state/sshd.pid"; do
        if [ -s "$pf" ]; then
            pid=$(cat "$pf" 2>/dev/null || true)
            if alive_pid "$pid"; then
                kill -TERM "$pid" 2>/dev/null || true
                wait_pid_exit "$pid"
            fi
        fi
        rm -f "$pf"
    done
    echo "MODES: ssh=stopped"
}

write_status() {
    permit_root=$(read_permit_root)
    {
        if [ -x /usr/sbin/sshd ]; then echo ssh_installed=1; else echo ssh_installed=0; fi
        echo "ssh_permit_root=$permit_root"
        if alive ssh; then echo "ssh=running port=$ssh_port"; else echo ssh=stopped; fi
    } > modes-status.tmp && mv modes-status.tmp modes-status
    if [ -f "$state/ssh.log" ]; then
        { echo "== ssh"; tail -n 80 "$state/ssh.log"; } > modes.log.tmp 2>/dev/null && mv modes.log.tmp modes.log
    fi
    cat modes-status
}

start_ssh() {
    permit_root=${1:-no}
    case "$permit_root" in yes|no) ;; *) permit_root=no ;; esac
    [ -x /usr/sbin/sshd ] || { echo 'MODES: ssh=FAIL reason=not-installed'; return 1; }
    stop_ssh >/dev/null 2>&1
    mkdir -p /run/sshd /etc/ssh
    chown 0:0 /run/sshd 2>/dev/null || true
    chmod 755 /run/sshd
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ] || [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        ssh-keygen -A >/dev/null 2>&1 || true
    fi
    printf '%s\n' "$permit_root" > "$state/ssh.permit_root"
    setsid nohup /usr/sbin/sshd -D -e \
        -p "$ssh_port" \
        -o ListenAddress=0.0.0.0 \
        -o PermitRootLogin="$permit_root" \
        -o PasswordAuthentication=yes \
        -o KbdInteractiveAuthentication=no \
        -o PubkeyAuthentication=yes \
        -o UsePAM=no \
        -o UseDNS=no \
        -o TCPKeepAlive=yes \
        -o ClientAliveInterval=15 \
        -o ClientAliveCountMax=6 \
        -o Compression=no \
        -o PidFile="$state/sshd.pid" \
        > "$state/ssh.log" 2>&1 < /dev/null &
    echo $! > "$state/ssh.pid"
    i=0
    while [ "$i" -lt 4 ]; do
        sleep 0.5 2>/dev/null || sleep 1
        alive ssh || { echo 'MODES: ssh=FAIL reason=sshd-exited'; tail -n 10 "$state/ssh.log" 2>/dev/null; rm -f "$state/ssh.pid"; return 1; }
        i=$((i + 1))
    done
    echo "MODES: ssh=PASS port=$ssh_port permit_root=$permit_root"
}

code=0
case "${1:-status}" in
    status) ;;
    start)
        case "${2:-ssh}" in
            ssh) start_ssh "${3:-no}" || code=1 ;;
            *) exit 2 ;;
        esac ;;
    restart)
        case "${2:-ssh}" in
            ssh) start_ssh "${3:-no}" || code=1 ;;
            *) exit 2 ;;
        esac ;;
    stop)
        case "${2:-ssh}" in
            ssh) stop_ssh ;;
            *) exit 2 ;;
        esac ;;
    *) exit 2 ;;
esac
write_status > /dev/null
cat modes-status
exit "$code"
