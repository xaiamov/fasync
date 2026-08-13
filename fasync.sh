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
exclude_log=                 # option to exclude deletion logs from sync

# --------------------------- Argument parsing ---------------------------
if [ $# -lt 2 ]; then
    echo "Usage: $0 <source dir> <target (rsync path or s3://bucket/path)> [options]"
    echo "  -d <seconds>   Delay to batch events (default 60)"
    echo "  -D <seconds>   Delay for DELETE events (default 0 – immediate)"
    echo "  -s             Skip fasync deletion log from syncing to target (useful for s3 cloud sync)"
    echo "  -q             Quiet mode – do not print each file path"
    exit 1
fi

dir="$(realpath "$1")"
target="$2"
shift 2

while getopts "d:D:qs" opt; do
    case $opt in
        q) quiet=ON ;;
        s) exclude_log=ON ;;
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

# --------------------------- Determine target type and check tools --------
if [[ "$target" =~ ^s3:// ]]; then
    target_type="s3"
    if ! command -v s3cmd &> /dev/null; then
        echo "[$(date)] ERROR: 's3cmd' utility not found for S3 target" >&2
        exit 1
    fi
    echo "[$(date)] S3 target detected, 's3cmd' utility is available"
else
    target_type="rsync"
    if ! command -v rsync &> /dev/null; then
        echo "[$(date)] ERROR: 'rsync' utility not found" >&2
        exit 1
    fi
    echo "[$(date)] Local/remote target detected, 'rsync' utility is available"
fi

# --------------------------- Service file for delayed deletions ----------
safe_target="$(echo "$target" | tr -c '[:alnum:]' '_' | tr -s '_')"
deleted_log="$dir/.fasync_deleted_${safe_target}.log"
deleted_log_name="${deleted_log##*/}"
oldest_delete_ts=0

# --------------------------- Start fawatch as a co-process ----------------
cd "$(dirname "$0")" || exit 1
coproc FAWATCH { ./fawatch "$dir"; }
echo "[$(date)] Started fawatch (PID ${FAWATCH_PID}) on $dir"

declare -a events=()
declare -a events_delete=()
last_flush=$(date +%s)

# --------------------------- Function to process delayed DELETEs ---------
process_deleted_events() {
    local now=$(date +%s)
    local threshold=$((now - delete_delay))
    local temp_file=$(mktemp)
    
    # Reset tracking variable before processing the file
    oldest_delete_ts=0

    # Read log only if it exists and has content to avoid No such file error under set -e
    if [ -s "$deleted_log" ]; then
        while IFS=$'\t' read -r ts path; do
            if [ $ts -le $threshold ]; then
                # $path is relative to $dir
                if [ ! -e "$dir/$path" ]; then
                    events_delete+=("$path")
                fi
            else
                # Remember the timestamp of the first unexpired record to skip processing next time
                if [ $oldest_delete_ts -eq 0 ]; then
                    oldest_delete_ts=$ts
                fi
                printf "%s\t%s\n" "$ts" "$path" >> "$temp_file"
            fi
        done < "$deleted_log"
    fi

    mv "$temp_file" "$deleted_log"
}

# --------------------------- Function to flush the buffer ----------------
flush() {
    # Subsequent exeution in bg
    (
        local s3_opts=""
        if [ -n "$quiet" ]; then s3_opts="--quiet"; fi

        if [ ${#events[@]} -gt 0 ]; then
						local -a files
						mapfile -t files < <(printf '%s\n' "${events[@]}" | sort -u)
            echo "[$(date)] Syncing ${#files[@]} file(s)"
            if [ "$target_type" = "s3" ]; then
                local base_target="${target%/}/"
                for file in "${files[@]}"; do
                    if [ -f "$dir/$file" ]; then
                        s3cmd put $s3_opts "$dir/$file" "${base_target}${file}"
                    fi
                done
            else
                printf '%s\n' "${files[@]}" | rsync -lptgoD --delete-missing-args --files-from=- "$dir" "$target"
            fi
        fi
        if [ ${#events_delete[@]} -gt 0 ]; then
						local -a del_files
						mapfile -t del_files < <(printf '%s\n' "${events_delete[@]}" | sort -u)
            echo "[$(date)] Removing ${#del_files[@]} file(s)"
            if [ "$target_type" = "s3" ]; then
                local base_target="${target%/}/"
                for file in "${del_files[@]}"; do
                    s3cmd del $s3_opts "${base_target}${file}"
                done
            else
                printf '%s\n' "${del_files[@]}" | rsync --delete --delete-missing-args -lptgoD --files-from=- "$dir" "$target"
            fi
        fi
    ) &
    events=()
    events_delete=()
}

# Initial seed on startup only if the option is active and log has content
if [ $delete_delay -gt 0 ] && [ -s "$deleted_log" ]; then
    process_deleted_events
fi

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

				# Ignore changes to the specific fasync deletion log file completely if option is set
				if [ -n "$exclude_log" ] && [[ "$rel_path" == "$deleted_log_name" ]]; then
						continue
				fi
				
				[ -z "$quiet" ] && echo "$line"

				if [ "$operation" = "DELETE" ]; then
						if [ $delete_delay -gt 0 ]; then
								printf "%s\t%s\n" "$current_time" "$rel_path" >> "$deleted_log"
								
								# If the log was previously empty or fully processed, seed the tracking variable
								if [ $oldest_delete_ts -eq 0 ]; then
										oldest_delete_ts=$current_time
								fi
						else
								events_delete+=("$rel_path")
						fi
				else
						events+=("$rel_path")
				fi
    fi

    # Trigger log processing only if the delayed deletion option is enabled and the oldest record matures
    if [ $delete_delay -gt 0 ] && [ $oldest_delete_ts -gt 0 ] && (( current_time >= oldest_delete_ts + delete_delay )); then
        process_deleted_events
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