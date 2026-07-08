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
deleted_log="$dir/.fasync_deleted.log"

# --------------------------- Start fawatch as a co-process ----------------
cd "$(dirname "$0")" || exit 1
coproc FAWATCH { ./fawatch "$dir"; }
echo "[$(date)] Started fawatch (PID ${FAWATCH_PID}) on $dir"

declare -a events=()
declare -a events_delete=()
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
            # $path is relative to $dir
            if [ ! -e "$dir/$path" ]; then
                events_delete+=("$path")
                count=$((count + 1))
            fi
        else
            printf "%s\t%s\n" "$ts" "$path" >> "$temp_file"
        fi
    done < "$deleted_log"

    mv "$temp_file" "$deleted_log"
    if [ $count -gt 0 ]; then
        echo "[$(date)] Marked $count file(s) for deletion"
    fi
}

# --------------------------- Function to flush the buffer ----------------
flush() {
    # Subsequent exeution in bg
    (
        if [ ${#events[@]} -gt 0 ]; then
						local -a files
						mapfile -t files < <(printf '%s\n' "${events[@]}" | sort -u)
            echo "[$(date)] Syncing ${#files[@]} file(s)"
            printf '%s\n' "${files[@]}" | rsync -lptgoD --delete-missing-args --files-from=- "$dir" "$target"
        fi
        if [ ${#events_delete[@]} -gt 0 ]; then
						local -a del_files
						mapfile -t del_files < <(printf '%s\n' "${events_delete[@]}" | sort -u)
            echo "[$(date)] Removing ${#del_files[@]} file(s)"
            printf '%s\n' "${del_files[@]}" | rsync --delete --delete-missing-args -lptgoD --files-from=- "$dir" "$target"
        fi
    ) &
    events=()
    events_delete=()
}

# --------------------------- Main loop ---------------------------------
while true; do
    current_time=$(date +%s)

    if read -t 1 -r line <&${FAWATCH[0]}; then
        # If both buffers are empty, starting new delay window
        if [ ${#events[@]} -eq 0 ] && [ ${#events_delete[@]} -eq 0 ]; then
            last_flush=$current_time
        fi

				operation="${line%%$'\t'*}"
				path="${line#*$'\t'}"

				# Ignoring watching dir events
				rel_path="${path#$dir/}"
				if [ -z "$rel_path" ]; then
						continue
				fi

				if [[ "$path" == "$deleted_log" && "$operation" == "DELETE" ]]; then
						continue
				fi

				[ -z "$quiet" ] && echo "$line"

				if [ "$operation" = "DELETE" ]; then
						if [ $delete_delay -gt 0 ]; then
								printf "%s\t%s\n" "$current_time" "$rel_path" >> "$deleted_log"
						else
								events_delete+=("$rel_path")
						fi
				else
						events+=("$rel_path")
				fi
    fi

    if ((current_time - last_delete_check >= delete_check_interval)); then
        process_deleted_events
        last_delete_check=$current_time
    fi

    # Flush buffers
    if ((current_time - last_flush >= delay)) && ((${#events[@]} > 0 || ${#events_delete[@]} > 0)); then
        flush
        last_flush=$current_time
    fi

    if ! kill -0 ${FAWATCH_PID} 2>/dev/null; then
        echo "[$(date)] ERROR: fawatch (PID ${FAWATCH_PID}) died unexpectedly"
        exit 1
    fi
done