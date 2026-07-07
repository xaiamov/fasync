#!/bin/bash

# ======================================================================
# fasync – asynchronous synchronization with buffering and delayed deletion
# ======================================================================

set -euo pipefail
trap 'echo "[$(date)] ERROR: command failed on line $LINENO" >&2' ERR
trap 'echo "EXIT at line $LINENO"' EXIT
trap 'echo "[$(date)] Received SIGINT/SIGTERM, exiting..."; exit 1' SIGINT SIGTERM

# --------------------------- Default parameters ---------------------------
delay=60                     # buffer delay (seconds)
delete_delay=0               # deletion delay (0 – immediate)
quiet=                       # quiet mode (do not print each event)
delete_check_interval=60     # interval for checking deletion log (seconds)

# --------------------------- Argument parsing ---------------------------
if [ $# -lt 2 ]; then
    echo "Usage: $0 <source dir> <rsync target> [options]"
    echo "  -d <seconds>   Delay to batch events (default 60)"
    echo "  -D <seconds>   Delay for DELETE events (default 0 – immediate)"
    echo "  -q             Quiet mode – do not print each file path"
    exit 1
fi

dir="$(realpath "$1")"
target="$2"
shift 2

while getopts "d:D:q" opt; do
    case $opt in
        q) quiet=ON ;;
        d)
            delay=$OPTARG
            [[ $OPTARG =~ ^[0-9]+$ ]] || { echo "Delay must be a number"; exit 1; }
            ;;
        D)
            delete_delay=$OPTARG
            [[ $OPTARG =~ ^[0-9]+$ ]] || { echo "Delete delay must be a number"; exit 1; }
            ;;
        *) exit 1 ;;
    esac
done

[ ! -d "$dir" ] && { echo "Source is not a directory"; exit 1; }
[ -z "$target" ] && { echo "Target directory not specified"; exit 1; }

# --------------------------- Service file for delayed deletions ----------
script_hash=$(echo "$(realpath "$0")" | md5sum | cut -c1-16)
deleted_log="$dir/.deleted.${script_hash}.log"

# --------------------------- Start fawatch as a co-process ----------------
cd "$(dirname "$0")" || exit 1
coproc FAWATCH { ./fawatch "$dir"; }
echo "[$(date)] Started fawatch (PID ${FAWATCH_PID}) on $dir"

declare -a events=()
last_flush=$(date +%s)
last_delete_check=$(date +%s)

# --------------------------- Function to process delayed DELETEs ---------
process_deleted_events() {
    [ $delete_delay -eq 0 ] && return
    [ ! -f "$deleted_log" ] && return

    local now=$(date +%s)
    local threshold=$((now - delete_delay))
    local temp_file=$(mktemp)
    local count=0

    while IFS=$'\t' read -r ts path; do
        if [ "$ts" -le "$threshold" ]; then
            if [ ! -e "$path" ]; then
                events+=("${path#$dir/}")
                count=$((count + 1))
            fi
        else
            printf "%s\t%s\n" "$ts" "$path" >> "$temp_file"
        fi
    done < "$deleted_log"

    mv "$temp_file" "$deleted_log"
    if [ $count -gt 0 ]; then
        echo "[$(date)] Marked $count file(s) for deletion (will be removed during next sync)"
    fi
}

# --------------------------- Function to flush the buffer ----------------
flush() {
    local -a files

    mapfile -t files < <(printf '%s\n' "${events[@]}" | sort -u)
    events=()    # clear global buffer

    [ ${#files[@]} -eq 0 ] && return

    echo "[$(date)] Processing ${#files[@]} file(s)"
    (
        # -a = -rlptgoD
        printf '%s\n' "${files[@]}" | rsync --delete --delete-missing-args -lptgoD --files-from=- "$dir" "$target"
    ) &
}

# --------------------------- Main loop ---------------------------------
while true; do
    current_time=$(date +%s)

    # Read event with a 1‑second timeout
    if read -t 1 -r line <&${FAWATCH[0]}; then
        # If buffer is empty, reset flush timer
        if [ ${#events[@]} -eq 0 ]; then
            last_flush=$current_time
        fi

        operation="${line%%$'\t'*}"
        path="${line#*$'\t'}"

        # Process only events inside the monitored directory
        case "$path" in
        "$dir" | "$dir"/*)
            # Ignore service log file (only DELETE events are skipped)
            [[ "$path" == "$deleted_log" && "$operation" == "DELETE" ]] && continue

            [ -z "$quiet" ] && echo "$line"

            if [ "$operation" = "DELETE" ] && [ $delete_delay -gt 0 ]; then
                # Postpone deletion
                printf "%s\t%s\n" "$(date +%s)" "$path" >> "$deleted_log"
            else
                # Normal event (or DELETE with zero delay) – add to buffer
                events+=("${path#$dir/}")
            fi
            ;;
        esac
    fi

    # Check delayed deletions every delete_check_interval seconds
    if ((current_time - last_delete_check >= delete_check_interval)); then
        process_deleted_events
        last_delete_check=$current_time
    fi

    # Flush buffer after delay if there are events
    if ((current_time - last_flush >= delay)) && [ ${#events[@]} -gt 0 ]; then
        flush
        last_flush=$current_time
    fi

    # Check if fawatch is still alive
    if ! kill -0 ${FAWATCH_PID} 2>/dev/null; then
        echo "[$(date)] ERROR: fawatch (PID ${FAWATCH_PID}) died unexpectedly"
        exit 1
    fi
done