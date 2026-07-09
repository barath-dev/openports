#!/usr/bin/env bash
#
# openports - lightweight interactive terminal tool to view listening
# ports on this machine and close (kill) the processes behind them.
#
# Works with the stock /bin/bash shipped on macOS (3.2) - no bash4+
# features (no associative arrays, no mapfile) are used on purpose.

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

ORIG_STTY=""
CURSOR=0
OFFSET=0
STATUS=""

# Parallel arrays describing the current list of listening ports.
PIDS=()
CMDS=()
USERS=()
PROTOS=()
PORTS=()
ADDRS=()
SELECTED=()   # 1/0 flag per row, same index as PIDS

# ---------------------------------------------------------------------------
# Terminal helpers
# ---------------------------------------------------------------------------

supports_color() {
    [[ -t 1 ]] && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]
}

if supports_color; then
    C_RESET=$(tput sgr0)
    C_BOLD=$(tput bold)
    C_DIM=$(tput dim)
    C_REV=$(tput rev)
    C_GREEN=$(tput setaf 2)
    C_CYAN=$(tput setaf 6)
    C_YELLOW=$(tput setaf 3)
    C_RED=$(tput setaf 1)
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_REV=""; C_GREEN=""; C_CYAN=""; C_YELLOW=""; C_RED=""
fi

cleanup() {
    [[ -n "$ORIG_STTY" ]] && stty "$ORIG_STTY" 2>/dev/null
    tput cnorm 2>/dev/null   # show cursor
    tput sgr0 2>/dev/null
    printf '\n'
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Data gathering
# ---------------------------------------------------------------------------

gather_ports() {
    local raw
    raw=$( { lsof -nP -iTCP -sTCP:LISTEN -F pcLPn 2>/dev/null
             lsof -nP -iUDP -F pcLPn 2>/dev/null; } )

    PIDS=(); CMDS=(); USERS=(); PROTOS=(); PORTS=(); ADDRS=()

    local line
    while IFS=$'\t' read -r pid cmd user proto port addr; do
        [[ -z "$pid" ]] && continue
        PIDS+=("$pid")
        CMDS+=("$cmd")
        USERS+=("$user")
        PROTOS+=("$proto")
        PORTS+=("$port")
        ADDRS+=("$addr")
    done < <(printf '%s\n' "$raw" | awk '
        BEGIN { OFS="\t" }
        {
            tag = substr($0,1,1)
            val = substr($0,2)
            if (tag == "p") { pid = val }
            else if (tag == "c") { cmd = val }
            else if (tag == "L") { user = val }
            else if (tag == "P") { proto = val }
            else if (tag == "n") {
                name = val
                if (index(name, "->") > 0) next
                n = split(name, parts, ":")
                port = parts[n]
                gsub(/[^0-9]/, "", port)
                if (port == "") next
                key = pid SUBSEP proto SUBSEP port
                if (!(key in seen)) {
                    seen[key] = 1
                    print pid, cmd, user, proto, port, name
                }
            }
        }
    ' | sort -t $'\t' -k5,5n)

    SELECTED=()
    local i
    for ((i = 0; i < ${#PIDS[@]}; i++)); do
        SELECTED+=(0)
    done

    (( CURSOR >= ${#PIDS[@]} )) && CURSOR=$(( ${#PIDS[@]} > 0 ? ${#PIDS[@]} - 1 : 0 ))
    OFFSET=0
}

# ---------------------------------------------------------------------------
# Small utility: is $1 present in the remaining args?
# ---------------------------------------------------------------------------

contains() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

draw() {
    local rows cols viewport count i row_idx marker line_attr
    rows=$(tput lines)
    cols=$(tput cols)
    count=${#PIDS[@]}

    tput cup 0 0
    tput ed

    printf '%s%sopenports%s %s- listening ports on this machine%s\n' \
        "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '%s%-6s %-18s %-10s %-5s %-7s %-s%s\n' \
        "$C_BOLD" "PID" "PROCESS" "USER" "PROTO" "PORT" "ADDRESS" "$C_RESET"
    printf '%s%s%s\n' "$C_DIM" "$(printf '%*s' "$((cols>0?cols:60))" '' | tr ' ' '-')" "$C_RESET"

    viewport=$(( rows - 8 ))
    (( viewport < 1 )) && viewport=1

    if (( count == 0 )); then
        printf '\n  %sNo listening ports found.%s\n' "$C_DIM" "$C_RESET"
    else
        (( CURSOR < OFFSET )) && OFFSET=$CURSOR
        (( CURSOR >= OFFSET + viewport )) && OFFSET=$(( CURSOR - viewport + 1 ))
        (( OFFSET < 0 )) && OFFSET=0

        for ((i = OFFSET; i < count && i < OFFSET + viewport; i++)); do
            marker=" "
            [[ "${SELECTED[$i]}" == "1" ]] && marker="${C_GREEN}*${C_RESET}"

            local pname="${CMDS[$i]}"
            (( ${#pname} > 18 )) && pname="${pname:0:15}..."
            local addr="${ADDRS[$i]}"
            (( ${#addr} > cols - 55 )) && (( cols - 55 > 4 )) && addr="${addr:0:$((cols-58))}..."

            if (( i == CURSOR )); then
                printf '%s> %s %-6s %-18s %-10s %-5s %-7s %-s%s\n' \
                    "$C_REV" "$marker" "${PIDS[$i]}" "$pname" "${USERS[$i]}" "${PROTOS[$i]}" "${PORTS[$i]}" "$addr" "$C_RESET"
            else
                printf '  %s %-6s %-18s %-10s %s%-5s%s %s%-7s%s %s%-s%s\n' \
                    "$marker" "${PIDS[$i]}" "$pname" "${USERS[$i]}" \
                    "$C_YELLOW" "${PROTOS[$i]}" "$C_RESET" \
                    "$C_CYAN" "${PORTS[$i]}" "$C_RESET" \
                    "$C_DIM" "$addr" "$C_RESET"
            fi
        done
    fi

    printf '\n%s%s%s\n' "$C_DIM" "$(printf '%*s' "$((cols>0?cols:60))" '' | tr ' ' '-')" "$C_RESET"
    printf '%s j/k or arrows move  space select  enter kill  a all  n none  r refresh  q quit%s\n' "$C_DIM" "$C_RESET"
    if (( count > 0 )); then
        printf ' %s%d/%d ports%s' "$C_DIM" "$((count>0 ? CURSOR+1 : 0))" "$count" "$C_RESET"
    fi
    if [[ -n "$STATUS" ]]; then
        printf '   %s%s%s' "$C_GREEN" "$STATUS" "$C_RESET"
    fi
    printf '\n'
}

# ---------------------------------------------------------------------------
# Killing
# ---------------------------------------------------------------------------

prompt_line() {
    # Print a prompt on its own clean line at the bottom and read one line.
    # Everything visible is written straight to /dev/tty, never to stdout -
    # this function is called as `reply=$(prompt_line ...)`, and any printf
    # to stdout here would be captured into $reply instead of shown.
    local prompt="$1" reply
    tput cnorm >/dev/tty
    stty "$ORIG_STTY" </dev/tty 2>/dev/null
    printf '\n%s%s%s' "$C_YELLOW" "$prompt" "$C_RESET" >/dev/tty
    read -r reply </dev/tty
    stty -echo -icanon min 1 time 0 </dev/tty 2>/dev/null
    tput civis >/dev/tty
    printf '%s' "$reply"
}

kill_targets() {
    local -a target_rows=()
    local i

    local any_selected=0
    for ((i = 0; i < ${#SELECTED[@]}; i++)); do
        if [[ "${SELECTED[$i]}" == "1" ]]; then
            any_selected=1
            target_rows+=("$i")
        fi
    done
    if (( any_selected == 0 )) && (( ${#PIDS[@]} > 0 )); then
        target_rows=("$CURSOR")
    fi
    if (( ${#target_rows[@]} == 0 )); then
        STATUS="Nothing to kill."
        return
    fi

    # Reduce to unique PIDs, and collect all ports each one owns for the
    # confirmation message (killing a pid closes every port it holds).
    local -a unique_pids=() unique_cmds=()
    for i in "${target_rows[@]}"; do
        if ! contains "${PIDS[$i]}" "${unique_pids[@]}"; then
            unique_pids+=("${PIDS[$i]}")
            unique_cmds+=("${CMDS[$i]}")
        fi
    done

    local summary="" p
    for ((i = 0; i < ${#unique_pids[@]}; i++)); do
        local pid="${unique_pids[$i]}"
        local ports_for_pid="" j
        for ((j = 0; j < ${#PIDS[@]}; j++)); do
            if [[ "${PIDS[$j]}" == "$pid" ]]; then
                [[ -n "$ports_for_pid" ]] && ports_for_pid="${ports_for_pid},"
                ports_for_pid="${ports_for_pid}${PORTS[$j]}"
            fi
        done
        summary="${summary}\n   PID ${pid} (${unique_cmds[$i]}) - port(s) ${ports_for_pid}"
    done

    printf '\n%sAbout to kill:%s%b%s\n' "$C_YELLOW" "$C_BOLD" "$summary" "$C_RESET"
    local reply
    reply=$(prompt_line "Proceed? [y/N] ")
    printf '\n'
    if [[ "$reply" != "y" && "$reply" != "Y" ]]; then
        STATUS="Cancelled."
        return
    fi

    local killed=0 failed=0 forced=0
    for pid in "${unique_pids[@]}"; do
        if kill -TERM "$pid" 2>/dev/null; then
            local waited=0
            while kill -0 "$pid" 2>/dev/null && (( waited < 15 )); do
                sleep 0.1
                waited=$((waited + 1))
            done
            if kill -0 "$pid" 2>/dev/null; then
                if kill -KILL "$pid" 2>/dev/null; then
                    forced=$((forced + 1))
                else
                    failed=$((failed + 1))
                fi
            else
                killed=$((killed + 1))
            fi
        else
            failed=$((failed + 1))
        fi
    done

    STATUS="Killed ${killed}"
    (( forced > 0 )) && STATUS="${STATUS}, force-killed ${forced}"
    (( failed > 0 )) && STATUS="${STATUS}, ${failed} failed (try: sudo openports)"

    gather_ports
}

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

read_key() {
    local key rest
    IFS= read -rsn1 key
    if [[ "$key" == $'\x1b' ]]; then
        IFS= read -rsn2 -t 0.02 rest
        key="${key}${rest}"
    fi
    printf '%s' "$key"
}

main_loop() {
    local key
    while true; do
        draw
        key=$(read_key)
        STATUS=""
        case "$key" in
            $'\x1b[A'|k|K) (( CURSOR > 0 )) && CURSOR=$((CURSOR - 1)) ;;
            $'\x1b[B'|j|J) (( CURSOR < ${#PIDS[@]} - 1 )) && CURSOR=$((CURSOR + 1)) ;;
            ' ')
                if (( ${#PIDS[@]} > 0 )); then
                    if [[ "${SELECTED[$CURSOR]}" == "1" ]]; then
                        SELECTED[$CURSOR]=0
                    else
                        SELECTED[$CURSOR]=1
                    fi
                fi
                ;;
            a|A)
                local i
                for ((i = 0; i < ${#SELECTED[@]}; i++)); do SELECTED[$i]=1; done
                ;;
            n|N)
                local i
                for ((i = 0; i < ${#SELECTED[@]}; i++)); do SELECTED[$i]=0; done
                ;;
            r|R)
                gather_ports
                STATUS="Refreshed."
                ;;
            ''|$'\n'|$'\r')
                kill_targets
                ;;
            q|Q|$'\x1b')
                break
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ! command -v lsof >/dev/null 2>&1; then
    echo "openports: this tool requires 'lsof', which was not found on PATH." >&2
    exit 1
fi

ORIG_STTY=$(stty -g)
tput civis
stty -echo -icanon min 1 time 0

gather_ports
main_loop
