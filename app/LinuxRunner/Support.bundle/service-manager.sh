#!/bin/bash
# DebianRunner lightweight systemd-compatible service manager.
# Installed to /usr/lib/linuxrunner/service-manager.sh and symlinked at:
#   /usr/local/bin/systemctl
#   /usr/local/bin/journalctl
#   /usr/local/bin/loginctl
#
# Runs standard systemd .service unit files (both --user and system scopes)
# without requiring systemd as PID 1, supporting agy remote-control, user
# daemons, and common Debian services.

set -u

SELF_PATH="/usr/lib/linuxrunner/service-manager.sh"
if [ ! -x "$SELF_PATH" ]; then
    SELF_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
fi
INVOKED_AS="$(basename "$0")"

# ── Helpers ──────────────────────────────────────────────────────────────────

current_uid() { id -u; }
current_user() { id -un; }

current_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

pid_starttime() {
    local p="${1:-}"
    [ -n "$p" ] && [ -r "/proc/$p/stat" ] || return 1
    awk '{sub(/^.*\) /, ""); print $20}' "/proc/$p/stat" 2>/dev/null || true
}

pid_alive() {
    local p="${1:-}" expect_boot="${2:-}" expect_start="${3:-}"
    [ -n "$p" ] || return 1
    case "$p" in *[!0-9]*) return 1 ;; esac
    [ "$p" -gt 1 ] 2>/dev/null || return 1
    if [ -n "$expect_boot" ]; then
        local cur_boot
        cur_boot="$(current_boot_id)"
        if [ -n "$cur_boot" ] && [ "$expect_boot" != "$cur_boot" ]; then
            return 1
        fi
    fi
    kill -0 "$p" 2>/dev/null || return 1
    if [ -r /proc/self/stat ]; then
        local st
        st="$(awk '{sub(/^.*\) /, ""); print $1}' "/proc/$p/stat" 2>/dev/null || true)"
        [ -n "$st" ] && [ "$st" != "Z" ] && [ "$st" != "X" ] || return 1
        if [ -n "$expect_start" ]; then
            local cur_start
            cur_start="$(pid_starttime "$p")"
            [ -n "$cur_start" ] && [ "$cur_start" = "$expect_start" ] || return 1
        fi
    fi
    return 0
}

normalize_unit() {
    local u="$1"
    u="${u%.}"
    case "$u" in
        *.service|*.socket|*.target|*.timer|*.mount|*.automount|*.swap|*.path|*.slice|*.scope|*.device)
            printf '%s' "$u"
            ;;
        *)
            printf '%s.service' "$u"
            ;;
    esac
}

parse_duration_sec() {
    local raw="${1:-0}"
    awk -v s="$raw" 'BEGIN {
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        if (s == "") { print "1"; exit }
        if (s ~ /^[0-9]+(\.[0-9]+)?$/) { printf "%s", s; exit }
        total = 0; matched = 0
        while (length(s) > 0) {
            gsub(/^[ \t]+/, "", s)
            if (length(s) == 0) break
            if (!match(s, /^[0-9]+(\.[0-9]+)?/)) { matched = 0; break }
            num = substr(s, RSTART, RLENGTH) + 0
            s = substr(s, RSTART + RLENGTH)
            gsub(/^[ \t]+/, "", s)
            unit = ""
            if (match(s, /^[A-Za-z]+/)) {
                unit = tolower(substr(s, RSTART, RLENGTH))
                s = substr(s, RSTART + RLENGTH)
            }
            if (unit == "" || unit == "s" || unit == "sec" || unit == "second" || unit == "seconds") mult = 1
            else if (unit == "ms" || unit == "msec" || unit == "millisecond" || unit == "milliseconds") mult = 0.001
            else if (unit == "us" || unit == "usec" || unit == "microsecond" || unit == "microseconds") mult = 0.000001
            else if (unit == "m" || unit == "min" || unit == "minute" || unit == "minutes") mult = 60
            else if (unit == "h" || unit == "hr" || unit == "hour" || unit == "hours") mult = 3600
            else if (unit == "d" || unit == "day" || unit == "days") mult = 86400
            else { matched = 0; break }
            total += num * mult
            matched = 1
        }
        if (!matched) { print "1"; exit }
        if (total > 0 && total < 0.1) total = 0.1
        if (total == int(total)) printf "%.0f", total
        else printf "%.2f", total
    }'
}

utc_systemd_now() {
    LC_ALL=C date -u '+%a %Y-%m-%d %H:%M:%S UTC'
}

log_ts() {
    LC_ALL=C date '+%b %d %H:%M:%S'
}

# ── Scope Paths ──────────────────────────────────────────────────────────────

state_root_for_scope() {
    local scope="$1"
    if [ "$scope" = "user" ]; then
        local uid
        uid="$(current_uid)"
        if [ -d /run/debianrunner-systemd ] && [ -w /run/debianrunner-systemd ]; then
            printf '/run/debianrunner-systemd/user-%s' "$uid"
        elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -w "${XDG_RUNTIME_DIR}" ]; then
            printf '%s/debianrunner-systemd' "$XDG_RUNTIME_DIR"
        else
            printf '/tmp/debianrunner-systemd-user-%s' "$uid"
        fi
    else
        printf '/run/debianrunner-systemd/system'
    fi
}

log_dir_for_scope() {
    local scope="$1"
    if [ "$scope" = "user" ]; then
        printf '%s/debianrunner-systemd/logs' "${XDG_STATE_HOME:-${HOME:-/root}/.local/state}"
    else
        printf '/var/log/debianrunner-systemd'
    fi
}

config_dir_for_scope() {
    local scope="$1"
    if [ "$scope" = "user" ]; then
        printf '%s/systemd/user' "${XDG_CONFIG_HOME:-${HOME:-/root}/.config}"
    else
        printf '/etc/systemd/system'
    fi
}

unit_search_dirs() {
    local scope="$1"
    if [ "$scope" = "user" ]; then
        printf '%s\n' \
            "${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/systemd/user" \
            "/etc/systemd/user" \
            "/run/systemd/user" \
            "/usr/local/lib/systemd/user" \
            "/usr/lib/systemd/user" \
            "/lib/systemd/user"
    else
        printf '%s\n' \
            "/etc/systemd/system" \
            "/run/systemd/system" \
            "/usr/local/lib/systemd/system" \
            "/usr/lib/systemd/system" \
            "/lib/systemd/system"
    fi
}

find_unit_file() {
    local scope="$1" unit="$2"
    local dir
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        if [ -f "$dir/$unit" ] && [ ! -L "$dir/$unit" -o -e "$dir/$unit" ]; then
            printf '%s' "$dir/$unit"
            return 0
        fi
    done < <(unit_search_dirs "$scope")

    # Template fallback: foo@bar.service -> foo@.service
    if [[ "$unit" == *@*.* ]]; then
        local tmpl="${unit%%@*}@.${unit##*.}"
        while IFS= read -r dir; do
            [ -n "$dir" ] || continue
            if [ -f "$dir/$tmpl" ]; then
                printf '%s' "$dir/$tmpl"
                return 0
            fi
        done < <(unit_search_dirs "$scope")
    fi
    return 1
}

unit_dropin_files() {
    local scope="$1" unit="$2"
    local dir f
    local -a dirs=()
    while IFS= read -r dir; do
        [ -n "$dir" ] && dirs+=("$dir")
    done < <(unit_search_dirs "$scope")

    # Merge lowest-priority to highest-priority so higher-priority overrides win
    local i
    for (( i=${#dirs[@]}-1; i>=0; i-- )); do
        dir="${dirs[$i]}"
        if [ -d "$dir/$unit.d" ]; then
            for f in "$dir/$unit.d"/*.conf; do
                [ -f "$f" ] && printf '%s\n' "$f"
            done
        fi
    done
}

# ── Safe Tokenizer & Specifier Expansion ─────────────────────────────────────

expand_specifiers() {
    local str="$1" unit="$2" scope="$3"
    local unit_no_ext="${unit%.*}"
    local prefix="$unit_no_ext"
    local instance=""
    if [[ "$unit_no_ext" == *@* ]]; then
        prefix="${unit_no_ext%%@*}"
        instance="${unit_no_ext#*@}"
    fi
    local uname uid hdir rdir hname
    uname="$(current_user)"
    uid="$(current_uid)"
    hdir="${HOME:-/root}"
    rdir="$(state_root_for_scope "$scope")"
    hname="$(hostname 2>/dev/null || echo localhost)"

    local out="" i=0 len=${#str} ch nxt
    while [ "$i" -lt "$len" ]; do
        ch="${str:$i:1}"
        if [ "$ch" = "%" ] && [ $((i + 1)) -lt "$len" ]; then
            nxt="${str:$((i + 1)):1}"
            case "$nxt" in
                %) out+='%' ;;
                n) out+="$unit" ;;
                N) out+="$unit_no_ext" ;;
                p) out+="$prefix" ;;
                i|I) out+="$instance" ;;
                u) out+="$uname" ;;
                U) out+="$uid" ;;
                h) out+="$hdir" ;;
                t) out+="$rdir" ;;
                H) out+="$hname" ;;
                *) out+="%$nxt" ;;
            esac
            i=$((i + 2))
        else
            out+="$ch"
            i=$((i + 1))
        fi
    done
    printf '%s' "$out"
}

# Splits a systemd command/Environment value into TOKENS array respecting
# single/double quotes and backslash escapes without using eval.
declare -a TOKENS=()
tokenize_systemd_words() {
    local s="$1"
    TOKENS=()
    local i=0 len=${#s} ch cur="" in_tok=0 quote=""
    while [ "$i" -lt "$len" ]; do
        ch="${s:$i:1}"
        if [ -n "$quote" ]; then
            if [ "$ch" = "$quote" ]; then
                quote=""
            elif [ "$ch" = "\\" ] && [ "$quote" = '"' ] && [ $((i + 1)) -lt "$len" ]; then
                i=$((i + 1))
                cur+="${s:$i:1}"
            else
                cur+="$ch"
            fi
        else
            case "$ch" in
                "'"|'"')
                    quote="$ch"
                    in_tok=1
                    ;;
                "\\")
                    if [ $((i + 1)) -lt "$len" ]; then
                        i=$((i + 1))
                        cur+="${s:$i:1}"
                        in_tok=1
                    fi
                    ;;
                ' '|$'\t')
                    if [ "$in_tok" -eq 1 ]; then
                        TOKENS+=("$cur")
                        cur=""
                        in_tok=0
                    fi
                    ;;
                *)
                    cur+="$ch"
                    in_tok=1
                    ;;
            esac
        fi
        i=$((i + 1))
    done
    if [ "$in_tok" -eq 1 ]; then
        TOKENS+=("$cur")
    fi
}

# ── Unit File Parser ─────────────────────────────────────────────────────────

U_DESC=""
U_TYPE="simple"
U_WORKDIR=""
U_USER=""
U_GROUP=""
U_PIDFILE=""
U_RESTART="no"
U_RESTART_SEC="1"
U_RESTART_PREVENT=""
U_SUCCESS_EXIT=""
U_TIMEOUT_STOP="15"
U_KILL_MODE="control-group"
U_REMAIN_AFTER_EXIT="no"
declare -a U_EXEC_START=()
declare -a U_EXEC_PRE=()
declare -a U_EXEC_POST=()
declare -a U_EXEC_STOP=()
declare -a U_EXEC_RELOAD=()
declare -a U_ENV=()
declare -a U_ENV_FILES=()
declare -a U_WANTED_BY=()

reset_unit_vars() {
    U_DESC=""
    U_TYPE="simple"
    U_WORKDIR=""
    U_USER=""
    U_GROUP=""
    U_PIDFILE=""
    U_RESTART="no"
    U_RESTART_SEC="1"
    U_RESTART_PREVENT=""
    U_SUCCESS_EXIT=""
    U_TIMEOUT_STOP="15"
    U_KILL_MODE="control-group"
    U_REMAIN_AFTER_EXIT="no"
    U_EXEC_START=()
    U_EXEC_PRE=()
    U_EXEC_POST=()
    U_EXEC_STOP=()
    U_EXEC_RELOAD=()
    U_ENV=()
    U_ENV_FILES=()
    U_WANTED_BY=()
}

parse_single_unit_file() {
    local file="$1"
    local section="" line="" acc="" key val
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        # Skip comments unless inside a continuation
        if [ -z "$acc" ]; then
            case "$line" in
                ''|'#'*|';'*) continue ;;
            esac
        fi
        # Line continuation with trailing backslash
        if [[ "$line" == *\\ ]]; then
            acc+="${line%\\} "
            continue
        fi
        line="${acc}${line}"
        acc=""

        # Trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue

        case "$line" in
            '#'*|';'*) continue ;;
            '['*']')
                section="${line#\[}"
                section="${section%\]}"
                continue
                ;;
        esac

        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"

        case "$section:$key" in
            Unit:Description) U_DESC="$val" ;;
            Service:Type) U_TYPE="$val" ;;
            Service:WorkingDirectory) U_WORKDIR="$val" ;;
            Service:User) U_USER="$val" ;;
            Service:Group) U_GROUP="$val" ;;
            Service:PIDFile) U_PIDFILE="$val" ;;
            Service:Restart) U_RESTART="$val" ;;
            Service:RestartSec) U_RESTART_SEC="$(parse_duration_sec "$val")" ;;
            Service:RestartPreventExitStatus) U_RESTART_PREVENT="${U_RESTART_PREVENT:+$U_RESTART_PREVENT }$val" ;;
            Service:SuccessExitStatus) U_SUCCESS_EXIT="${U_SUCCESS_EXIT:+$U_SUCCESS_EXIT }$val" ;;
            Service:TimeoutStopSec) U_TIMEOUT_STOP="$(parse_duration_sec "$val")" ;;
            Service:KillMode) U_KILL_MODE="$val" ;;
            Service:RemainAfterExit) U_REMAIN_AFTER_EXIT="$val" ;;
            Service:ExecStart)
                if [ -z "$val" ]; then U_EXEC_START=(); else U_EXEC_START+=("$val"); fi ;;
            Service:ExecStartPre)
                if [ -z "$val" ]; then U_EXEC_PRE=(); else U_EXEC_PRE+=("$val"); fi ;;
            Service:ExecStartPost)
                if [ -z "$val" ]; then U_EXEC_POST=(); else U_EXEC_POST+=("$val"); fi ;;
            Service:ExecStop)
                if [ -z "$val" ]; then U_EXEC_STOP=(); else U_EXEC_STOP+=("$val"); fi ;;
            Service:ExecReload)
                if [ -z "$val" ]; then U_EXEC_RELOAD=(); else U_EXEC_RELOAD+=("$val"); fi ;;
            Service:Environment)
                if [ -z "$val" ]; then
                    U_ENV=()
                else
                    tokenize_systemd_words "$val"
                    local item
                    for item in "${TOKENS[@]}"; do U_ENV+=("$item"); done
                fi
                ;;
            Service:EnvironmentFile)
                if [ -z "$val" ]; then U_ENV_FILES=(); else U_ENV_FILES+=("$val"); fi ;;
            Install:WantedBy)
                local t
                for t in $val; do U_WANTED_BY+=("$t"); done ;;
        esac
    done < "$file"
}

load_unit() {
    local scope="$1" unit="$2"
    local main_file
    main_file="$(find_unit_file "$scope" "$unit")" || return 1
    reset_unit_vars
    parse_single_unit_file "$main_file"
    local dropin
    while IFS= read -r dropin; do
        [ -f "$dropin" ] && parse_single_unit_file "$dropin"
    done < <(unit_dropin_files "$scope" "$unit")
    UNIT_FILE_PATH="$main_file"
    return 0
}

# ── Runtime State Inspection ─────────────────────────────────────────────────

unit_state_dir() {
    printf '%s/units/%s' "$(state_root_for_scope "$1")" "$2"
}

unit_log_file() {
    printf '%s/%s.log' "$(log_dir_for_scope "$1")" "$2"
}

read_unit_status() {
    local scope="$1" unit="$2"
    local sdir
    sdir="$(unit_state_dir "$scope" "$unit")"

    ST_ACTIVE="inactive"
    ST_SUB="dead"
    ST_MAIN_PID="0"
    ST_SUP_PID="0"
    ST_BOOT_ID=""
    ST_MAIN_START=""
    ST_SUP_START=""
    ST_SINCE=""
    ST_SINCE_MONO="0"
    ST_EXIT="0"

    local cur_boot saved_boot=""
    cur_boot="$(current_boot_id)"
    [ -f "$sdir/boot_id" ] && saved_boot="$(cat "$sdir/boot_id" 2>/dev/null || true)"
    ST_BOOT_ID="$saved_boot"
    if [ -n "$cur_boot" ] && [ -n "$saved_boot" ] && [ "$saved_boot" != "$cur_boot" ]; then
        return 0
    fi

    [ -f "$sdir/active_since" ] && ST_SINCE="$(cat "$sdir/active_since" 2>/dev/null || true)"
    [ -f "$sdir/active_since_mono" ] && ST_SINCE_MONO="$(cat "$sdir/active_since_mono" 2>/dev/null || echo 0)"
    [ -f "$sdir/exit_code" ] && ST_EXIT="$(cat "$sdir/exit_code" 2>/dev/null || echo 0)"

    local mpid="" spid="" mstart="" sstart="" saved_sub=""
    [ -f "$sdir/main.pid" ] && mpid="$(cat "$sdir/main.pid" 2>/dev/null || true)"
    [ -f "$sdir/main.start" ] && mstart="$(cat "$sdir/main.start" 2>/dev/null || true)"
    [ -f "$sdir/supervisor.pid" ] && spid="$(cat "$sdir/supervisor.pid" 2>/dev/null || true)"
    [ -f "$sdir/supervisor.start" ] && sstart="$(cat "$sdir/supervisor.start" 2>/dev/null || true)"
    [ -f "$sdir/sub_state" ] && saved_sub="$(cat "$sdir/sub_state" 2>/dev/null || true)"
    ST_MAIN_START="$mstart"
    ST_SUP_START="$sstart"

    if pid_alive "$mpid" "$saved_boot" "$mstart"; then
        ST_ACTIVE="active"
        ST_SUB="running"
        ST_MAIN_PID="$mpid"
        pid_alive "$spid" "$saved_boot" "$sstart" && ST_SUP_PID="$spid"
    elif pid_alive "$spid" "$saved_boot" "$sstart"; then
        ST_SUP_PID="$spid"
        if [ "$saved_sub" = "auto-restart" ]; then
            ST_ACTIVE="activating"
            ST_SUB="auto-restart"
        else
            ST_ACTIVE="activating"
            ST_SUB="start"
        fi
    elif [ "$saved_sub" = "exited" ]; then
        ST_ACTIVE="active"
        ST_SUB="exited"
    elif [ "$saved_sub" = "failed" ]; then
        ST_ACTIVE="failed"
        ST_SUB="failed"
    fi
}

unit_is_enabled_state() {
    local scope="$1" unit="$2"
    local cfg
    cfg="$(config_dir_for_scope "$scope")"
    local link
    for link in "$cfg"/*.wants/"$unit"; do
        if [ -L "$link" ] || [ -f "$link" ]; then
            printf 'enabled'
            return 0
        fi
    done
    if load_unit "$scope" "$unit" 2>/dev/null; then
        if [ "${#U_WANTED_BY[@]}" -gt 0 ]; then
            printf 'disabled'
            return 1
        fi
        printf 'static'
        return 0
    fi
    printf 'not-found'
    return 1
}

# ── Environment & Command Execution ──────────────────────────────────────────

RESOLVED_UID=""
RESOLVED_GID=""
RESOLVED_USER=""
RESOLVED_HOME=""
resolve_unit_identity() {
    local scope="$1"
    RESOLVED_UID=""
    RESOLVED_GID=""
    RESOLVED_USER=""
    RESOLVED_HOME=""
    if [ "$scope" != "system" ] || [ "$(current_uid)" -ne 0 ]; then
        return 0
    fi
    if [ -n "$U_USER" ]; then
        local pw_line=""
        if command -v getent >/dev/null 2>&1; then
            pw_line="$(getent passwd "$U_USER" 2>/dev/null || true)"
        fi
        if [ -z "$pw_line" ] && [ -r /etc/passwd ]; then
            pw_line="$(awk -F: -v u="$U_USER" '$1==u || $3==u {print; exit}' /etc/passwd 2>/dev/null || true)"
        fi
        [ -n "$pw_line" ] || { echo "Unknown User=$U_USER" >&2; return 1; }
        local _p _g
        IFS=: read -r RESOLVED_USER _p RESOLVED_UID RESOLVED_GID _g RESOLVED_HOME _ <<< "$pw_line"
        [ -n "$RESOLVED_UID" ] && [ -n "$RESOLVED_GID" ] || return 1
        export -- HOME="${RESOLVED_HOME:-/root}" USER="$RESOLVED_USER" LOGNAME="$RESOLVED_USER"
    fi
    if [ -n "$U_GROUP" ]; then
        local gr_line=""
        if command -v getent >/dev/null 2>&1; then
            gr_line="$(getent group "$U_GROUP" 2>/dev/null || true)"
        fi
        if [ -z "$gr_line" ] && [ -r /etc/group ]; then
            gr_line="$(awk -F: -v g="$U_GROUP" '$1==g || $3==g {print; exit}' /etc/group 2>/dev/null || true)"
        fi
        [ -n "$gr_line" ] || { echo "Unknown Group=$U_GROUP" >&2; return 1; }
        local _gn _gp
        IFS=: read -r _gn _gp RESOLVED_GID _ <<< "$gr_line"
        [ -n "$RESOLVED_GID" ] || return 1
        [ -n "$RESOLVED_UID" ] || RESOLVED_UID=0
    fi
    return 0
}

apply_unit_environment() {
    local scope="$1" unit="$2"
    local ef opt line k v
    for ef in "${U_ENV_FILES[@]}"; do
        opt=0
        if [[ "$ef" == -* ]]; then
            opt=1
            ef="${ef#-}"
        fi
        ef="$(expand_specifiers "$ef" "$unit" "$scope")"
        if [ ! -r "$ef" ]; then
            [ "$opt" -eq 1 ] && continue
            return 1
        fi
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            case "$line" in ''|'#'*|';'*) continue ;; esac
            [[ "$line" == export[[:space:]]* ]] && line="${line#export}" && line="${line#"${line%%[![:space:]]*}"}"
            [[ "$line" == *=* ]] || continue
            k="${line%%=*}"
            v="${line#*=}"
            k="${k%"${k##*[![:space:]]}"}"
            v="${v#"${v%%[![:space:]]*}"}"
            v="${v%"${v##*[![:space:]]}"}"
            if [[ "$v" == \"*\" && "${#v}" -ge 2 && "${v:1:${#v}-2}" != *\"* ]]; then
                v="${v#\"}"; v="${v%\"}"
            elif [[ "$v" == \'*\' && "${#v}" -ge 2 && "${v:1:${#v}-2}" != *\'* ]]; then
                v="${v#\'}"; v="${v%\'}"
            fi
            [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            export -- "$k=$v"
        done < "$ef"
    done

    local kv
    for kv in "${U_ENV[@]}"; do
        kv="$(expand_specifiers "$kv" "$unit" "$scope")"
        if [[ "$kv" == *=* ]]; then
            k="${kv%%=*}"
            v="${kv#*=}"
            k="${k%"${k##*[![:space:]]}"}"
            [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            export -- "$k=$v"
        fi
    done
    return 0
}

apply_working_dir() {
    local scope="$1" unit="$2"
    [ -n "$U_WORKDIR" ] || return 0
    local wd="$U_WORKDIR" opt=0
    if [[ "$wd" == -* ]]; then
        opt=1
        wd="${wd#-}"
    fi
    if [ "$wd" = "~" ]; then
        wd="${HOME:-/root}"
    elif [[ "$wd" == \~/* ]]; then
        wd="${HOME:-/root}/${wd#\~/}"
    fi
    wd="$(expand_specifiers "$wd" "$unit" "$scope")"
    if ! cd "$wd" 2>/dev/null; then
        [ "$opt" -eq 1 ] && return 0
        return 1
    fi
    return 0
}

# Safely expands systemd-style $VAR (word-split, dropped if empty), ${VAR}
# (single-word), and $$ (literal $) in TOKENS without eval.
expand_env_tokens() {
    local -a out=()
    local tok i len ch next vname val cur part
    for tok in "${TOKENS[@]}"; do
        if [[ "$tok" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
            vname="${BASH_REMATCH[1]}"
            val="${!vname:-}"
            if [ -n "$val" ]; then
                for part in $val; do out+=("$part"); done
            fi
            continue
        fi
        cur=""
        i=0
        len=${#tok}
        while [ "$i" -lt "$len" ]; do
            ch="${tok:$i:1}"
            if [ "$ch" = '$' ] && [ $((i + 1)) -lt "$len" ]; then
                next="${tok:$((i + 1)):1}"
                if [ "$next" = '$' ]; then
                    cur+='$'
                    i=$((i + 2))
                    continue
                elif [ "$next" = '{' ]; then
                    local rest="${tok:$((i + 2))}"
                    if [[ "$rest" =~ ^([A-Za-z_][A-Za-z0-9_]*)\} ]]; then
                        vname="${BASH_REMATCH[1]}"
                        cur+="${!vname:-}"
                        i=$((i + 2 + ${#vname} + 1))
                        continue
                    fi
                elif [[ "${tok:$((i + 1))}" =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]; then
                    vname="${BASH_REMATCH[1]}"
                    cur+="${!vname:-}"
                    i=$((i + 1 + ${#vname}))
                    continue
                fi
            fi
            cur+="$ch"
            i=$((i + 1))
        done
        out+=("$cur")
    done
    TOKENS=("${out[@]}")
}

# Prepares CMD_ARGV and CMD_IGNORE_ERR from a raw systemd Exec* string.
CMD_IGNORE_ERR=0
declare -a CMD_ARGV=()
prepare_exec_cmd() {
    local raw="$1" scope="$2" unit="$3"
    CMD_IGNORE_ERR=0
    CMD_ARGV=()
    local expanded
    expanded="$(expand_specifiers "$raw" "$unit" "$scope")"
    tokenize_systemd_words "$expanded"
    [ "${#TOKENS[@]}" -gt 0 ] || return 1

    local cmd="${TOKENS[0]}"
    # Strip systemd command prefix flags (-, @, +, !, :)
    while [ -n "$cmd" ]; do
        case "${cmd:0:1}" in
            -) CMD_IGNORE_ERR=1; cmd="${cmd:1}" ;;
            @|+|!|:) cmd="${cmd:1}" ;;
            *) break ;;
        esac
    done
    TOKENS[0]="$cmd"
    expand_env_tokens
    [ "${#TOKENS[@]}" -gt 0 ] || return 1
    CMD_ARGV=("${TOKENS[@]}")
    [ -n "${CMD_ARGV[0]}" ]
}

exec_with_identity() {
    local with_setsid="$1"
    shift
    if [ -n "$RESOLVED_UID" ] && [ "$(current_uid)" -eq 0 ] && { [ "$RESOLVED_UID" != "0" ] || [ "${RESOLVED_GID:-0}" != "0" ]; }; then
        if command -v setpriv >/dev/null 2>&1; then
            local -a sp_args=(--reuid="$RESOLVED_UID" --regid="$RESOLVED_GID")
            if [ -n "$RESOLVED_USER" ] && [ "$RESOLVED_USER" != "root" ]; then
                sp_args+=(--init-groups)
            else
                sp_args+=(--clear-groups)
            fi
            if [ "$with_setsid" -eq 1 ] && command -v setsid >/dev/null 2>&1; then
                exec setsid -w setpriv "${sp_args[@]}" "$@"
            else
                exec setpriv "${sp_args[@]}" "$@"
            fi
        elif [ -n "$RESOLVED_USER" ]; then
            if [ "$with_setsid" -eq 1 ] && command -v setsid >/dev/null 2>&1; then
                exec setsid -w su -s /bin/sh "$RESOLVED_USER" -c 'exec "$@"' -- debianrunner-svc "$@"
            else
                exec su -s /bin/sh "$RESOLVED_USER" -c 'exec "$@"' -- debianrunner-svc "$@"
            fi
        else
            return 1
        fi
    else
        if [ "$with_setsid" -eq 1 ] && command -v setsid >/dev/null 2>&1; then
            exec setsid -w "$@"
        else
            exec "$@"
        fi
    fi
}

run_exec_sync() {
    local raw="$1" scope="$2" unit="$3" logf="$4"
    local ignore_err=0
    local trimmed="${raw#"${raw%%[![:space:]]*}"}"
    while [ -n "$trimmed" ]; do
        case "${trimmed:0:1}" in
            -) ignore_err=1; trimmed="${trimmed:1}" ;;
            @|+|!|:) trimmed="${trimmed:1}" ;;
            *) break ;;
        esac
    done
    (
        resolve_unit_identity "$scope" || exit 1
        apply_unit_environment "$scope" "$unit" || exit 1
        apply_working_dir "$scope" "$unit" || exit 1
        prepare_exec_cmd "$raw" "$scope" "$unit" || exit 0
        exec_with_identity 0 "${CMD_ARGV[@]}"
    ) >> "$logf" 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ] && [ "$ignore_err" -eq 1 ]; then
        return 0
    fi
    return "$rc"
}

code_in_list() {
    local code="$1" list="$2" item
    for item in $list; do
        [ "$item" = "$code" ] && return 0
    done
    return 1
}

should_restart_exit() {
    local rc="$1"
    if [ -n "$U_RESTART_PREVENT" ] && code_in_list "$rc" "$U_RESTART_PREVENT"; then
        return 1
    fi
    case "$U_RESTART" in
        always) return 0 ;;
        on-failure|on-abnormal|on-abort|on-watchdog)
            if [ "$rc" -eq 0 ]; then return 1; fi
            if [ -n "$U_SUCCESS_EXIT" ] && code_in_list "$rc" "$U_SUCCESS_EXIT"; then return 1; fi
            return 0
            ;;
        on-success)
            [ "$rc" -eq 0 ] && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

trim_log_if_large() {
    local logf="$1"
    [ -f "$logf" ] || return 0
    local sz
    sz="$(wc -c < "$logf" 2>/dev/null || echo 0)"
    if [ "$sz" -gt 5242880 ]; then
        tail -n 2000 "$logf" > "$logf.tmp" 2>/dev/null && mv -f "$logf.tmp" "$logf" 2>/dev/null || true
    fi
}

# ── Background Supervisor Daemon ─────────────────────────────────────────────

run_supervisor() {
    local scope="$1" unit="$2"
    load_unit "$scope" "$unit" || exit 1

    local sdir logd logf boot_id sup_start
    sdir="$(unit_state_dir "$scope" "$unit")"
    logd="$(log_dir_for_scope "$scope")"
    logf="$(unit_log_file "$scope" "$unit")"
    mkdir -p "$sdir" "$logd"
    boot_id="$(current_boot_id)"
    sup_start="$(pid_starttime "$$" || true)"
    [ -n "$boot_id" ] && echo "$boot_id" > "$sdir/boot_id"
    echo "$$" > "$sdir/supervisor.pid"
    [ -n "$sup_start" ] && echo "$sup_start" > "$sdir/supervisor.start"

    # Forward termination to stop gracefully
    trap 'touch "$sdir/stop_requested"' TERM INT

    if [ "${#U_EXEC_START[@]}" -eq 0 ]; then
        echo "failed" > "$sdir/sub_state"
        if [ "$(cat "$sdir/supervisor.pid" 2>/dev/null || true)" = "$$" ]; then
            rm -f "$sdir/supervisor.pid" "$sdir/supervisor.start"
        fi
        exit 1
    fi
    local exec_cmd="${U_EXEC_START[${#U_EXEC_START[@]}-1]}"

    while :; do
        [ -f "$sdir/stop_requested" ] && break
        trim_log_if_large "$logf"
        printf '%s [%s] Starting: %s\n' "$(log_ts)" "$unit" "$exec_cmd" >> "$logf"

        # Spawn service in its own session/process-group so stop kills cleanly
        (
            resolve_unit_identity "$scope" || exit 1
            apply_unit_environment "$scope" "$unit" || exit 1
            apply_working_dir "$scope" "$unit" || exit 1
            prepare_exec_cmd "$exec_cmd" "$scope" "$unit" || exit 1
            exec_with_identity 1 "${CMD_ARGV[@]}"
        ) </dev/null >> "$logf" 2>&1 &
        local child_pid=$!
        local child_start
        child_start="$(pid_starttime "$child_pid" || true)"

        echo "$child_pid" > "$sdir/main.pid"
        [ -n "$child_start" ] && echo "$child_start" > "$sdir/main.start" || rm -f "$sdir/main.start"
        utc_systemd_now > "$sdir/active_since"
        date +%s > "$sdir/active_since_mono"
        echo "running" > "$sdir/sub_state"

        wait "$child_pid"
        local rc=$?
        echo "$rc" > "$sdir/exit_code"
        rm -f "$sdir/main.pid" "$sdir/main.start"

        # Handle Type=forking with PIDFile: wait while forked daemon lives
        if [ "$U_TYPE" = "forking" ] && [ "$rc" -eq 0 ] && [ -n "$U_PIDFILE" ]; then
            local pf
            pf="$(expand_specifiers "$U_PIDFILE" "$unit" "$scope")"
            sleep 0.2 2>/dev/null || true
            if [ -s "$pf" ]; then
                local fpid fstart
                fpid="$(tr -d '[:space:]' < "$pf" 2>/dev/null || true)"
                if pid_alive "$fpid"; then
                    fstart="$(pid_starttime "$fpid" || true)"
                    echo "$fpid" > "$sdir/main.pid"
                    [ -n "$fstart" ] && echo "$fstart" > "$sdir/main.start" || rm -f "$sdir/main.start"
                    while pid_alive "$fpid" "$boot_id" "$fstart" && [ ! -f "$sdir/stop_requested" ]; do
                        sleep 1 &
                        wait $! 2>/dev/null || true
                    done
                    rm -f "$sdir/main.pid" "$sdir/main.start"
                    if [ ! -f "$sdir/stop_requested" ]; then
                        rc=1
                        echo "$rc" > "$sdir/exit_code"
                    fi
                fi
            fi
        fi

        if [ -f "$sdir/stop_requested" ]; then
            printf '%s [%s] Stopped (exit code %d)\n' "$(log_ts)" "$unit" "$rc" >> "$logf"
            if [ "$(cat "$sdir/supervisor.pid" 2>/dev/null || true)" = "$$" ]; then
                echo "dead" > "$sdir/sub_state"
            fi
            break
        fi

        printf '%s [%s] Process exited with code %d\n' "$(log_ts)" "$unit" "$rc" >> "$logf"

        if should_restart_exit "$rc"; then
            echo "auto-restart" > "$sdir/sub_state"
            printf '%s [%s] Scheduling restart in %ss\n' "$(log_ts)" "$unit" "$U_RESTART_SEC" >> "$logf"
            # Interruptible sleep so systemctl stop/start wakes immediately on SIGTERM
            local secs_int="${U_RESTART_SEC%%.*}"
            case "$secs_int" in ''|*[!0-9]*) secs_int=1 ;; esac
            if [ "$secs_int" -lt 1 ]; then
                sleep "$U_RESTART_SEC" 2>/dev/null &
                wait $! 2>/dev/null || true
            else
                local i=0
                while [ "$i" -lt "$secs_int" ]; do
                    [ -f "$sdir/stop_requested" ] && break
                    sleep 1 &
                    wait $! 2>/dev/null || true
                    i=$((i + 1))
                done
            fi
            if [ -f "$sdir/stop_requested" ]; then
                if [ "$(cat "$sdir/supervisor.pid" 2>/dev/null || true)" = "$$" ]; then
                    echo "dead" > "$sdir/sub_state"
                fi
                break
            fi
            continue
        fi

        if [ "$(cat "$sdir/supervisor.pid" 2>/dev/null || true)" = "$$" ]; then
            if [ "$rc" -eq 0 ] || code_in_list "$rc" "$U_SUCCESS_EXIT"; then
                echo "dead" > "$sdir/sub_state"
            else
                echo "failed" > "$sdir/sub_state"
            fi
        fi
        break
    done

    if [ "$(cat "$sdir/supervisor.pid" 2>/dev/null || true)" = "$$" ]; then
        rm -f "$sdir/supervisor.pid" "$sdir/supervisor.start" "$sdir/main.pid" "$sdir/main.start" "$sdir/stop_requested"
    fi
    exit 0
}

# ── Unit Lifecycle Actions ───────────────────────────────────────────────────

start_unit() {
    local scope="$1" unit="$2"
    unit="$(normalize_unit "$unit")"

    if ! load_unit "$scope" "$unit"; then
        echo "Unit $unit could not be found." >&2
        return 5
    fi

    read_unit_status "$scope" "$unit"
    if [ "$ST_ACTIVE" = "active" ]; then
        return 0
    fi

    local sdir logd logf
    sdir="$(unit_state_dir "$scope" "$unit")"
    logd="$(log_dir_for_scope "$scope")"
    logf="$(unit_log_file "$scope" "$unit")"
    mkdir -p "$sdir" "$logd"

    # Wait for any previous supervisor (e.g. in RestartSec backoff) to exit
    # completely before clearing stop_requested and launching a replacement.
    if pid_alive "$ST_SUP_PID" "$ST_BOOT_ID" "$ST_SUP_START"; then
        touch "$sdir/stop_requested"
        kill -TERM "$ST_SUP_PID" 2>/dev/null || true
        local w=0
        while [ "$w" -lt 25 ] && pid_alive "$ST_SUP_PID" "$ST_BOOT_ID" "$ST_SUP_START"; do
            sleep 0.1 2>/dev/null || sleep 1
            w=$((w + 1))
        done
        if pid_alive "$ST_SUP_PID" "$ST_BOOT_ID" "$ST_SUP_START"; then
            kill -KILL "$ST_SUP_PID" 2>/dev/null || true
        fi
        rm -f "$sdir/supervisor.pid" "$sdir/supervisor.start" "$sdir/main.pid" "$sdir/main.start"
    fi
    rm -f "$sdir/stop_requested"
    local boot_id
    boot_id="$(current_boot_id)"
    [ -n "$boot_id" ] && echo "$boot_id" > "$sdir/boot_id"

    local cmd
    for cmd in "${U_EXEC_PRE[@]}"; do
        if ! run_exec_sync "$cmd" "$scope" "$unit" "$logf"; then
            echo "failed" > "$sdir/sub_state"
            echo "Job for $unit failed (ExecStartPre)." >&2
            return 1
        fi
    done

    if [ "${#U_EXEC_START[@]}" -eq 0 ]; then
        if [ "$U_TYPE" = "oneshot" ]; then
            utc_systemd_now > "$sdir/active_since"
            date +%s > "$sdir/active_since_mono"
            [ "$U_REMAIN_AFTER_EXIT" = "yes" ] && echo "exited" > "$sdir/sub_state" || echo "dead" > "$sdir/sub_state"
            return 0
        fi
        echo "Unit $unit has no ExecStart= configured." >&2
        return 1
    fi

    if [ "$U_TYPE" = "oneshot" ]; then
        for cmd in "${U_EXEC_START[@]}"; do
            if ! run_exec_sync "$cmd" "$scope" "$unit" "$logf"; then
                echo "failed" > "$sdir/sub_state"
                echo "Job for $unit failed." >&2
                return 1
            fi
        done
        utc_systemd_now > "$sdir/active_since"
        date +%s > "$sdir/active_since_mono"
        echo "0" > "$sdir/exit_code"
        case "$U_REMAIN_AFTER_EXIT" in
            yes|true|1) echo "exited" > "$sdir/sub_state" ;;
            *)          echo "dead" > "$sdir/sub_state" ;;
        esac
        for cmd in "${U_EXEC_POST[@]}"; do
            run_exec_sync "$cmd" "$scope" "$unit" "$logf" || true
        done
        return 0
    fi

    echo "start" > "$sdir/sub_state"
    rm -f "$sdir/main.pid" "$sdir/main.start" "$sdir/exit_code"

    # Launch completely detached so caller's stdout/stderr pipes close immediately
    if command -v setsid >/dev/null 2>&1; then
        setsid "$SELF_PATH" _supervise "$scope" "$unit" </dev/null >/dev/null 2>&1 &
    else
        nohup "$SELF_PATH" _supervise "$scope" "$unit" </dev/null >/dev/null 2>&1 &
    fi

    # Wait briefly for main.pid and confirm it didn't fail immediately
    local i=0
    while [ "$i" -lt 20 ]; do
        read_unit_status "$scope" "$unit"
        if [ "$ST_ACTIVE" = "active" ]; then
            for cmd in "${U_EXEC_POST[@]}"; do
                run_exec_sync "$cmd" "$scope" "$unit" "$logf" || true
            done
            return 0
        fi
        if [ "$ST_ACTIVE" = "failed" ]; then
            echo "Job for $unit failed. Check logs with: journalctl $([ "$scope" = "user" ] && echo "--user ")-u $unit -n 50" >&2
            return 1
        fi
        if [ "$ST_SUB" = "dead" ] && [ -f "$sdir/exit_code" ] && [ "$ST_EXIT" = "0" ]; then
            for cmd in "${U_EXEC_POST[@]}"; do
                run_exec_sync "$cmd" "$scope" "$unit" "$logf" || true
            done
            return 0
        fi
        sleep 0.1 2>/dev/null || sleep 1
        i=$((i + 1))
    done

    read_unit_status "$scope" "$unit"
    if [ "$ST_ACTIVE" = "active" ] || [ "$ST_ACTIVE" = "activating" ] ||
       { [ "$ST_SUB" = "dead" ] && [ -f "$sdir/exit_code" ] && [ "$ST_EXIT" = "0" ]; }; then
        return 0
    fi
    echo "Job for $unit failed to start." >&2
    return 1
}

stop_unit() {
    local scope="$1" unit="$2"
    unit="$(normalize_unit "$unit")"

    local sdir logf
    sdir="$(unit_state_dir "$scope" "$unit")"
    logf="$(unit_log_file "$scope" "$unit")"
    mkdir -p "$sdir"
    touch "$sdir/stop_requested"

    read_unit_status "$scope" "$unit"
    local mpid="$ST_MAIN_PID" spid="$ST_SUP_PID"
    local b_id="$ST_BOOT_ID" mstart="$ST_MAIN_START" sstart="$ST_SUP_START"

    local timeout_sec=15
    if load_unit "$scope" "$unit" 2>/dev/null; then
        timeout_sec="${U_TIMEOUT_STOP%%.*}"
        case "$timeout_sec" in ''|*[!0-9]*) timeout_sec=15 ;; esac
        [ "$timeout_sec" -gt 0 ] || timeout_sec=15
        [ "$timeout_sec" -gt 30 ] && timeout_sec=30
        local cmd
        for cmd in "${U_EXEC_STOP[@]}"; do
            MAINPID="${mpid}" run_exec_sync "$cmd" "$scope" "$unit" "$logf" || true
        done
    fi

    if pid_alive "$mpid" "$b_id" "$mstart"; then
        if [ "$U_KILL_MODE" != "process" ]; then
            kill -TERM -- "-$mpid" 2>/dev/null || true
        fi
        kill -TERM "$mpid" 2>/dev/null || true
    fi
    if pid_alive "$spid" "$b_id" "$sstart"; then
        kill -TERM "$spid" 2>/dev/null || true
    fi

    local loops=$(( timeout_sec * 5 ))
    local i=0
    while [ "$i" -lt "$loops" ]; do
        if ! pid_alive "$mpid" "$b_id" "$mstart" && ! pid_alive "$spid" "$b_id" "$sstart"; then
            break
        fi
        sleep 0.2 2>/dev/null || sleep 1
        i=$((i + 1))
    done

    if pid_alive "$mpid" "$b_id" "$mstart"; then
        if [ "$U_KILL_MODE" != "process" ]; then
            kill -KILL -- "-$mpid" 2>/dev/null || true
        fi
        kill -KILL "$mpid" 2>/dev/null || true
    fi
    if pid_alive "$spid" "$b_id" "$sstart"; then
        kill -KILL "$spid" 2>/dev/null || true
    fi

    rm -f "$sdir/main.pid" "$sdir/main.start" "$sdir/supervisor.pid" "$sdir/supervisor.start" "$sdir/stop_requested"
    echo "dead" > "$sdir/sub_state"
    return 0
}

reload_unit() {
    local scope="$1" unit="$2"
    unit="$(normalize_unit "$unit")"
    if ! load_unit "$scope" "$unit"; then
        echo "Unit $unit could not be found." >&2
        return 5
    fi
    read_unit_status "$scope" "$unit"
    local logf
    logf="$(unit_log_file "$scope" "$unit")"
    if [ "${#U_EXEC_RELOAD[@]}" -gt 0 ]; then
        local cmd
        for cmd in "${U_EXEC_RELOAD[@]}"; do
            MAINPID="${ST_MAIN_PID}" run_exec_sync "$cmd" "$scope" "$unit" "$logf" || return 1
        done
        return 0
    fi
    if pid_alive "$ST_MAIN_PID" "$ST_BOOT_ID" "$ST_MAIN_START"; then
        kill -HUP "$ST_MAIN_PID" 2>/dev/null || true
    fi
    return 0
}

enable_unit() {
    local scope="$1" unit="$2" now="$3" quiet="$4"
    unit="$(normalize_unit "$unit")"
    if ! load_unit "$scope" "$unit"; then
        echo "Failed to enable unit: Unit file $unit does not exist." >&2
        return 1
    fi

    local cfg target
    cfg="$(config_dir_for_scope "$scope")"
    if [ "${#U_WANTED_BY[@]}" -eq 0 ]; then
        if [ "$scope" = "user" ]; then
            U_WANTED_BY=("default.target")
        else
            U_WANTED_BY=("multi-user.target")
        fi
    fi

    for target in "${U_WANTED_BY[@]}"; do
        mkdir -p "$cfg/$target.wants"
        ln -sf "$UNIT_FILE_PATH" "$cfg/$target.wants/$unit"
        if [ "$quiet" -eq 0 ]; then
            echo "Created symlink $cfg/$target.wants/$unit -> $UNIT_FILE_PATH."
        fi
    done

    if [ "$now" -eq 1 ]; then
        start_unit "$scope" "$unit" || return $?
    fi
    return 0
}

disable_unit() {
    local scope="$1" unit="$2" now="$3" quiet="$4"
    unit="$(normalize_unit "$unit")"
    local cfg link
    cfg="$(config_dir_for_scope "$scope")"
    for link in "$cfg"/*.wants/"$unit"; do
        if [ -L "$link" ] || [ -f "$link" ]; then
            rm -f "$link"
            if [ "$quiet" -eq 0 ]; then
                echo "Removed \"$link\"."
            fi
        fi
    done
    if [ "$now" -eq 1 ]; then
        stop_unit "$scope" "$unit" || return $?
    fi
    return 0
}

show_unit_props() {
    local scope="$1" unit="$2" props_csv="$3" value_only="$4"
    unit="$(normalize_unit "$unit")"
    local load_state="not-found" frag="" desc="" enabled_state="not-found"
    if load_unit "$scope" "$unit" 2>/dev/null; then
        load_state="loaded"
        frag="$UNIT_FILE_PATH"
        desc="${U_DESC:-$unit}"
        enabled_state="$(unit_is_enabled_state "$scope" "$unit" || true)"
    fi
    read_unit_status "$scope" "$unit"
    local result="success"
    [ "$ST_ACTIVE" = "failed" ] && result="exit-code"

    if [ -z "$props_csv" ]; then
        props_csv="Id,Description,LoadState,ActiveState,SubState,MainPID,ActiveEnterTimestamp,ActiveEnterTimestampMonotonic,UnitFileState,FragmentPath,ExecMainStatus,Result"
    fi

    case "$ST_SINCE_MONO" in ''|*[!0-9]*) ST_SINCE_MONO="0" ;; esac
    local IFS=',' prop val
    for prop in $props_csv; do
        case "$prop" in
            Id) val="$unit" ;;
            Description) val="$desc" ;;
            LoadState) val="$load_state" ;;
            ActiveState) val="$ST_ACTIVE" ;;
            SubState) val="$ST_SUB" ;;
            MainPID) val="$ST_MAIN_PID" ;;
            ActiveEnterTimestamp) val="$ST_SINCE" ;;
            ActiveEnterTimestampMonotonic) val="$(( ST_SINCE_MONO * 1000000 ))" ;;
            UnitFileState) val="$enabled_state" ;;
            FragmentPath) val="$frag" ;;
            ExecMainStatus) val="$ST_EXIT" ;;
            Result) val="$result" ;;
            *) val="" ;;
        esac
        if [ "$value_only" -eq 1 ]; then
            printf '%s\n' "$val"
        else
            printf '%s=%s\n' "$prop" "$val"
        fi
    done
}

status_unit() {
    local scope="$1" unit="$2" lines="${3:-10}"
    unit="$(normalize_unit "$unit")"
    local load_state="not-found" frag="" desc="$unit" enabled_state="not-found"
    if load_unit "$scope" "$unit" 2>/dev/null; then
        load_state="loaded"
        frag="$UNIT_FILE_PATH"
        desc="${U_DESC:-$unit}"
        enabled_state="$(unit_is_enabled_state "$scope" "$unit" || true)"
    fi
    read_unit_status "$scope" "$unit"

    local bullet="○"
    [ "$ST_ACTIVE" = "active" ] && bullet="●"
    [ "$ST_ACTIVE" = "failed" ] && bullet="×"

    printf '%s %s - %s\n' "$bullet" "$unit" "$desc"
    if [ "$load_state" = "loaded" ]; then
        printf '     Loaded: loaded (%s; %s)\n' "$frag" "$enabled_state"
    else
        printf '     Loaded: not-found (Reason: Unit %s not found.)\n' "$unit"
        return 4
    fi
    if [ -n "$ST_SINCE" ] && [ "$ST_ACTIVE" = "active" ]; then
        printf '     Active: %s (%s) since %s\n' "$ST_ACTIVE" "$ST_SUB" "$ST_SINCE"
    else
        printf '     Active: %s (%s)\n' "$ST_ACTIVE" "$ST_SUB"
    fi
    if [ "$ST_MAIN_PID" != "0" ]; then
        printf '   Main PID: %s\n' "$ST_MAIN_PID"
    fi

    local logf
    logf="$(unit_log_file "$scope" "$unit")"
    if [ -s "$logf" ]; then
        if [ "$lines" = "all" ]; then
            printf '\n'
            cat "$logf"
        else
            case "$lines" in ''|*[!0-9]*) lines=10 ;; esac
            if [ "$lines" -gt 0 ]; then
                printf '\n'
                tail -n "$lines" "$logf"
            fi
        fi
    fi

    [ "$ST_ACTIVE" = "active" ] && return 0
    return 3
}

list_units_cmd() {
    local scope="$1" files_only="$2"
    local seen=" " dir f u st
    while IFS= read -r dir; do
        [ -d "$dir" ] || continue
        for f in "$dir"/*.service; do
            [ -f "$f" ] || continue
            u="$(basename "$f")"
            case "$seen" in *" $u "*) continue ;; esac
            seen+="$u "
            if [ "$files_only" -eq 1 ]; then
                st="$(unit_is_enabled_state "$scope" "$u" || true)"
                printf '%-42s %s\n' "$u" "$st"
            else
                read_unit_status "$scope" "$u"
                if [ "$ST_ACTIVE" = "active" ] || [ "$ST_ACTIVE" = "failed" ] || [ "$ST_ACTIVE" = "activating" ]; then
                    printf '%-42s %-8s %-10s %-12s\n' "$u" "loaded" "$ST_ACTIVE" "$ST_SUB"
                fi
            fi
        done
    done < <(unit_search_dirs "$scope")
}

cat_unit() {
    local scope="$1" unit="$2"
    unit="$(normalize_unit "$unit")"
    if ! load_unit "$scope" "$unit"; then
        echo "No files found for $unit." >&2
        return 1
    fi
    printf '# %s\n' "$UNIT_FILE_PATH"
    cat "$UNIT_FILE_PATH"
    local d
    while IFS= read -r d; do
        [ -f "$d" ] || continue
        printf '\n# %s\n' "$d"
        cat "$d"
    done < <(unit_dropin_files "$scope" "$unit")
}

# ── Boot Auto-Start ──────────────────────────────────────────────────────────

boot_autostart() {
    # Ensure shared runtime directory exists for both system and non-root user scopes
    mkdir -p /run/debianrunner-systemd/system /var/log/debianrunner-systemd /var/lib/systemd/linger 2>/dev/null || true
    chmod 1777 /run/debianrunner-systemd 2>/dev/null || true

    # fakefs /run persists across app launches while guest PIDs restart from 1.
    # Purge stale PID files whenever /proc/sys/kernel/random/boot_id changes.
    local cur_boot prev_boot=""
    cur_boot="$(current_boot_id)"
    if [ -n "$cur_boot" ]; then
        prev_boot="$(cat /run/debianrunner-systemd/boot_id 2>/dev/null || true)"
        if [ "$prev_boot" != "$cur_boot" ]; then
            local udir
            for udir in /run/debianrunner-systemd/system/units/* /run/debianrunner-systemd/user-*/units/*; do
                [ -d "$udir" ] || continue
                rm -f "$udir/main.pid" "$udir/main.start" "$udir/supervisor.pid" "$udir/supervisor.start" "$udir/stop_requested" 2>/dev/null || true
                echo "dead" > "$udir/sub_state" 2>/dev/null || true
            done
            echo "$cur_boot" > /run/debianrunner-systemd/boot_id 2>/dev/null || true
        fi
    fi

    # 1. Start enabled system services (deduplicated across wants directories)
    local link u seen_sys=" "
    for link in /etc/systemd/system/multi-user.target.wants/*.service /etc/systemd/system/default.target.wants/*.service; do
        [ -e "$link" ] || continue
        u="$(basename "$link")"
        case "$seen_sys" in *" $u "*) continue ;; esac
        seen_sys+="$u "
        start_unit "system" "$u" >/dev/null 2>&1 || true
    done

    # 2. Start enabled user services for root and regular users
    local uname _ uid gid _gecos home shell seen_usr
    while IFS=: read -r uname _ uid gid _gecos home shell; do
        [ -n "$uname" ] || continue
        case "$uid" in *[!0-9]*) continue ;; esac
        if [ "$uid" -ne 0 ] && [ "$uid" -lt 1000 ]; then
            continue
        fi
        [ -d "$home/.config/systemd/user" ] || continue
        seen_usr=" "
        for link in "$home/.config/systemd/user"/default.target.wants/*.service "$home/.config/systemd/user"/multi-user.target.wants/*.service; do
            [ -e "$link" ] || continue
            u="$(basename "$link")"
            case "$seen_usr" in *" $u "*) continue ;; esac
            seen_usr+="$u "
            if [ "$uid" -eq 0 ]; then
                HOME="$home" USER="root" LOGNAME="root" "$SELF_PATH" _systemctl --user start "$u" >/dev/null 2>&1 || true
            else
                su -s /bin/bash "$uname" -c 'HOME="$1" USER="$2" LOGNAME="$2" PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin" "$3" _systemctl --user start "$4"' \
                    -- debianrunner-boot "$home" "$uname" "$SELF_PATH" "$u" >/dev/null 2>&1 || true
            fi
        done
    done < /etc/passwd
    return 0
}

# ── Command Dispatchers ──────────────────────────────────────────────────────

cmd_systemctl() {
    local scope="system" quiet=0 now=0 value_only=0 lines=10
    local props=""
    local -a pos=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user) scope="user" ;;
            --system) scope="system" ;;
            -q|--quiet) quiet=1 ;;
            --now) now=1 ;;
            --value) value_only=1 ;;
            -p|--property)
                shift
                [ "$#" -gt 0 ] && props="${props:+$props,}$1"
                ;;
            --property=*)
                props="${props:+$props,}${1#--property=}"
                ;;
            -p*)
                props="${props:+$props,}${1#-p}"
                ;;
            -n|--lines)
                shift
                [ "$#" -gt 0 ] && lines="$1"
                ;;
            --lines=*)
                lines="${1#--lines=}"
                ;;
            -n*)
                lines="${1#-n}"
                ;;
            --no-pager|--no-legend|--no-ask-password|--no-block|--full|-l|--plain|--all|-a|--runtime|--force|-f|--wait|--global)
                ;;
            --type|--state|-t|-o|--output)
                [ "$#" -gt 1 ] && shift
                ;;
            --type=*|--state=*|--output=*)
                ;;
            --version)
                echo "systemd 256 (debianrunner service-manager)"
                return 0
                ;;
            -h|--help)
                echo "Usage: systemctl [--user|--system] COMMAND [UNIT...]"
                echo "Commands: start stop restart reload enable disable is-active is-enabled is-failed status show cat daemon-reload reset-failed list-units list-unit-files is-system-running"
                return 0
                ;;
            --)
                shift
                while [ "$#" -gt 0 ]; do pos+=("$1"); shift; done
                break
                ;;
            -*)
                ;;
            *)
                pos+=("$1")
                ;;
        esac
        shift
    done

    local subcmd="${pos[0]:-list-units}"
    local -a units=("${pos[@]:1}")
    local rc=0 u

    case "$subcmd" in
        daemon-reload|daemon-reexec)
            return 0
            ;;
        is-system-running)
            [ "$quiet" -eq 0 ] && echo "running"
            return 0
            ;;
        reset-failed)
            if [ "${#units[@]}" -eq 0 ]; then
                local sroot
                sroot="$(state_root_for_scope "$scope")/units"
                for u in "$sroot"/*; do
                    [ -f "$u/sub_state" ] && [ "$(cat "$u/sub_state" 2>/dev/null)" = "failed" ] && echo "dead" > "$u/sub_state"
                done
            else
                for u in "${units[@]}"; do
                    u="$(normalize_unit "$u")"
                    local sdir
                    sdir="$(unit_state_dir "$scope" "$u")"
                    [ -f "$sdir/sub_state" ] && [ "$(cat "$sdir/sub_state" 2>/dev/null)" = "failed" ] && echo "dead" > "$sdir/sub_state"
                done
            fi
            return 0
            ;;
        start)
            [ "${#units[@]}" -gt 0 ] || { echo "Too few arguments." >&2; return 1; }
            for u in "${units[@]}"; do start_unit "$scope" "$u" || rc=$?; done
            return "$rc"
            ;;
        stop)
            [ "${#units[@]}" -gt 0 ] || { echo "Too few arguments." >&2; return 1; }
            for u in "${units[@]}"; do stop_unit "$scope" "$u" || rc=$?; done
            return "$rc"
            ;;
        restart|reload-or-restart)
            [ "${#units[@]}" -gt 0 ] || { echo "Too few arguments." >&2; return 1; }
            for u in "${units[@]}"; do
                stop_unit "$scope" "$u" || true
                start_unit "$scope" "$u" || rc=$?
            done
            return "$rc"
            ;;
        try-restart|condrestart|try-reload-or-restart)
            [ "${#units[@]}" -gt 0 ] || { echo "Too few arguments." >&2; return 1; }
            for u in "${units[@]}"; do
                u="$(normalize_unit "$u")"
                read_unit_status "$scope" "$u"
                if [ "$ST_ACTIVE" = "active" ]; then
                    stop_unit "$scope" "$u" || true
                    start_unit "$scope" "$u" || rc=$?
                fi
            done
            return "$rc"
            ;;
        reload)
            [ "${#units[@]}" -gt 0 ] || { echo "Too few arguments." >&2; return 1; }
            for u in "${units[@]}"; do reload_unit "$scope" "$u" || rc=$?; done
            return "$rc"
            ;;
        enable)
            [ "${#units[@]}" -gt 0 ] || { echo "Too few arguments." >&2; return 1; }
            for u in "${units[@]}"; do enable_unit "$scope" "$u" "$now" "$quiet" || rc=$?; done
            return "$rc"
            ;;
        disable)
            [ "${#units[@]}" -gt 0 ] || { echo "Too few arguments." >&2; return 1; }
            for u in "${units[@]}"; do disable_unit "$scope" "$u" "$now" "$quiet" || rc=$?; done
            return "$rc"
            ;;
        is-active)
            [ "${#units[@]}" -gt 0 ] || { echo "Too few arguments." >&2; return 1; }
            rc=0
            for u in "${units[@]}"; do
                u="$(normalize_unit "$u")"
                read_unit_status "$scope" "$u"
                [ "$quiet" -eq 0 ] && echo "$ST_ACTIVE"
                [ "$ST_ACTIVE" = "active" ] || rc=3
            done
            return "$rc"
            ;;
        is-failed)
            [ "${#units[@]}" -gt 0 ] || { echo "Too few arguments." >&2; return 1; }
            rc=1
            for u in "${units[@]}"; do
                u="$(normalize_unit "$u")"
                read_unit_status "$scope" "$u"
                [ "$quiet" -eq 0 ] && echo "$ST_ACTIVE"
                [ "$ST_ACTIVE" = "failed" ] && rc=0
            done
            return "$rc"
            ;;
        is-enabled)
            [ "${#units[@]}" -gt 0 ] || { echo "Too few arguments." >&2; return 1; }
            rc=0
            for u in "${units[@]}"; do
                u="$(normalize_unit "$u")"
                local es
                es="$(unit_is_enabled_state "$scope" "$u")" || rc=1
                [ "$quiet" -eq 0 ] && echo "$es"
            done
            return "$rc"
            ;;
        show)
            for u in "${units[@]}"; do
                show_unit_props "$scope" "$u" "$props" "$value_only"
            done
            return 0
            ;;
        status)
            if [ "${#units[@]}" -eq 0 ]; then
                echo "● $(hostname 2>/dev/null || echo debian)"
                echo "    State: running (DebianRunner service-manager)"
                return 0
            fi
            for u in "${units[@]}"; do status_unit "$scope" "$u" "$lines" || rc=$?; done
            return "$rc"
            ;;
        cat)
            for u in "${units[@]}"; do cat_unit "$scope" "$u" || rc=$?; done
            return "$rc"
            ;;
        list-units)
            list_units_cmd "$scope" 0
            return 0
            ;;
        list-unit-files)
            list_units_cmd "$scope" 1
            return 0
            ;;
        *)
            echo "systemctl: unsupported command '$subcmd'" >&2
            return 1
            ;;
    esac
}

cmd_journalctl() {
    local scope="system" unit="" lines=100 follow=0 reverse=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user) scope="user" ;;
            --system) scope="system" ;;
            --user-unit)
                scope="user"
                [ "$#" -gt 1 ] && { shift; unit="$1"; }
                ;;
            --user-unit=*)
                scope="user"
                unit="${1#--user-unit=}"
                ;;
            -u|--unit)
                [ "$#" -gt 1 ] && { shift; unit="$1"; }
                ;;
            --unit=*)
                unit="${1#--unit=}"
                ;;
            -n|--lines)
                [ "$#" -gt 1 ] && { shift; lines="$1"; }
                ;;
            --lines=*)
                lines="${1#--lines=}"
                ;;
            -f|--follow) follow=1 ;;
            -r|--reverse) reverse=1 ;;
            --no-pager|-e|-q|--quiet|-a|--all|-x|--catalog|-b|--boot|--utc) ;;
            -o|--output|-S|--since|-U|--until|-p|--priority|-t|--identifier)
                [ "$#" -gt 1 ] && shift
                ;;
            --output=*|--since=*|--until=*|--priority=*|--identifier=*) ;;
            -h|--help)
                echo "Usage: journalctl [--user|--system] [-u UNIT] [-n LINES] [-f] [-r]"
                return 0
                ;;
            -[!-]*)
                # Unpack bundled short flags such as -fu, -xeu, -fn 50
                local flags="${1#-}" idx=0 flen=${#flags} fc rest
                while [ "$idx" -lt "$flen" ]; do
                    fc="${flags:$idx:1}"
                    rest="${flags:$((idx + 1))}"
                    case "$fc" in
                        f) follow=1 ;;
                        r) reverse=1 ;;
                        e|q|a|x|b) ;;
                        u)
                            if [ -n "$rest" ]; then unit="$rest"; break
                            elif [ "$#" -gt 1 ]; then shift; unit="$1"; break
                            fi
                            ;;
                        n)
                            if [ -n "$rest" ]; then lines="$rest"; break
                            elif [ "$#" -gt 1 ]; then shift; lines="$1"; break
                            fi
                            ;;
                        o|S|U|p|t)
                            if [ -z "$rest" ] && [ "$#" -gt 1 ]; then shift; fi
                            break
                            ;;
                    esac
                    idx=$((idx + 1))
                done
                ;;
        esac
        shift
    done

    local tail_arg
    if [ "$lines" = "all" ]; then
        tail_arg="+1"
    else
        case "$lines" in ''|*[!0-9]*) lines=100 ;; esac
        tail_arg="$lines"
    fi

    local logd
    logd="$(log_dir_for_scope "$scope")"
    mkdir -p "$logd" 2>/dev/null || true

    if [ -n "$unit" ]; then
        unit="$(normalize_unit "$unit")"
        local logf="$logd/$unit.log"
        if [ "$follow" -eq 1 ]; then
            touch "$logf" 2>/dev/null || true
            exec tail -n "$tail_arg" -F "$logf"
        fi
        if [ ! -f "$logf" ]; then
            echo "-- No entries --"
            return 0
        fi
        if [ "$reverse" -eq 1 ] && command -v tac >/dev/null 2>&1; then
            tail -n "$tail_arg" "$logf" | tac
        else
            tail -n "$tail_arg" "$logf"
        fi
        return 0
    fi

    local has_any=0 f
    for f in "$logd"/*.log; do
        [ -f "$f" ] && has_any=1 && break
    done
    if [ "$has_any" -eq 0 ]; then
        echo "-- No entries --"
        return 0
    fi
    if [ "$follow" -eq 1 ]; then
        exec tail -n "$tail_arg" -F "$logd"/*.log
    fi
    tail -n "$tail_arg" "$logd"/*.log
}

resolve_linger_username() {
    local target="$1"
    if [ -r /etc/passwd ]; then
        case "$target" in
            *[!0-9]*)
                printf '%s' "$target"
                ;;
            *)
                local resolved
                resolved="$(awk -F: -v u="$target" '$3==u {print $1; exit}' /etc/passwd 2>/dev/null || true)"
                printf '%s' "${resolved:-$target}"
                ;;
        esac
    else
        printf '%s' "$target"
    fi
}

linger_dir_for_user() {
    local target
    target="$(resolve_linger_username "$1")"
    if [ "$target" = "$(current_user)" ] && [ -n "${XDG_STATE_HOME:-}" ]; then
        printf '%s/debianrunner-systemd' "$XDG_STATE_HOME"
    else
        local home
        home="$(awk -F: -v u="$target" '$1==u {print $6; exit}' /etc/passwd 2>/dev/null || true)"
        [ -n "$home" ] || home="${HOME:-/root}"
        printf '%s/.local/state/debianrunner-systemd' "$home"
    fi
}

linger_state_for_user() {
    local target
    target="$(resolve_linger_username "$1")"
    local ldir
    ldir="$(linger_dir_for_user "$target")"
    if [ -f "$ldir/linger" ] || [ -f "/var/lib/systemd/linger/$target" ]; then
        printf 'yes'
    else
        printf 'no'
    fi
}

cmd_loginctl() {
    local value_only=0 props=""
    local -a pos=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --value) value_only=1 ;;
            -p|--property)
                shift
                [ "$#" -gt 0 ] && props="${props:+$props,}$1"
                ;;
            --property=*)
                props="${props:+$props,}${1#--property=}"
                ;;
            --no-pager|--no-legend|--no-ask-password) ;;
            -h|--help)
                echo "Usage: loginctl enable-linger|disable-linger|show-user|user-status [USER]"
                return 0
                ;;
            -*) ;;
            *) pos+=("$1") ;;
        esac
        shift
    done

    local sub="${pos[0]:-list-users}"
    local target
    target="$(resolve_linger_username "${pos[1]:-$(current_user)}")"
    local ldir
    ldir="$(linger_dir_for_user "$target")"

    case "$sub" in
        enable-linger)
            if [ "$(current_uid)" -eq 0 ] && [ "$target" != "root" ]; then
                mkdir -p /var/lib/systemd/linger 2>/dev/null || true
                touch "/var/lib/systemd/linger/$target" || return 1
            else
                mkdir -p "$ldir" 2>/dev/null || true
                touch "$ldir/linger" 2>/dev/null || true
                mkdir -p /var/lib/systemd/linger 2>/dev/null || true
                touch "/var/lib/systemd/linger/$target" 2>/dev/null || true
            fi
            [ "$(linger_state_for_user "$target")" = "yes" ]
            return $?
            ;;
        disable-linger)
            rm -f "$ldir/linger" "/var/lib/systemd/linger/$target" 2>/dev/null || true
            if [ "$(linger_state_for_user "$target")" = "yes" ]; then
                echo "Failed to disable linger for $target: permission denied" >&2
                return 1
            fi
            return 0
            ;;
        show-user)
            local ling uid
            ling="$(linger_state_for_user "$target")"
            uid="$(id -u "$target" 2>/dev/null || current_uid)"
            [ -n "$props" ] || props="UID,Name,Linger,State"
            local IFS=',' p v
            for p in $props; do
                case "$p" in
                    UID) v="$uid" ;;
                    Name) v="$target" ;;
                    Linger) v="$ling" ;;
                    State) v="active" ;;
                    *) v="" ;;
                esac
                if [ "$value_only" -eq 1 ]; then
                    printf '%s\n' "$v"
                else
                    printf '%s=%s\n' "$p" "$v"
                fi
            done
            return 0
            ;;
        user-status|list-users)
            printf '%s (%s) active linger=%s\n' "$target" "$(id -u "$target" 2>/dev/null || current_uid)" "$(linger_state_for_user "$target")"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# ── Entrypoint ───────────────────────────────────────────────────────────────

if [ "${1:-}" = "_supervise" ]; then
    shift
    run_supervisor "$@"
    exit $?
fi

case "$INVOKED_AS" in
    systemctl)  cmd_systemctl "$@" ;;
    journalctl) cmd_journalctl "$@" ;;
    loginctl)   cmd_loginctl "$@" ;;
    *)
        case "${1:-}" in
            _supervise)     shift; run_supervisor "$@" ;;
            _systemctl)     shift; cmd_systemctl "$@" ;;
            _journalctl)    shift; cmd_journalctl "$@" ;;
            _loginctl)      shift; cmd_loginctl "$@" ;;
            boot-autostart) boot_autostart ;;
            systemctl)      shift; cmd_systemctl "$@" ;;
            journalctl)     shift; cmd_journalctl "$@" ;;
            loginctl)       shift; cmd_loginctl "$@" ;;
            *)              cmd_systemctl "$@" ;;
        esac
        ;;
esac
