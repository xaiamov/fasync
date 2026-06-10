#!/bin/bash

delay=60
dir="$(realpath $1)"
target="$2"
shift 2

function error() {
	[ -n "$1" ] && echo "$1" && echo
	echo "Usage: $0 <source dir> <rsync target> [options]"
	echo "	-d <seconds>   Delay to batch events (default $delay)"
	echo "	-q             Quiet mode – do not print each file path"
	exit 1
}

[ ! -d "$dir" ] && error "Source is not a dir"
[ -z "$target" ] && error "Target directory not specified"
quiet=

# Parse arguments
while getopts "d:s:t:q" opt; do
	case $opt in
	q) quiet=ON ;;
	d)
		delay=$OPTARG
		[[ $OPTARG =~ ^[0-9]+$ ]] || error "Delay must be a number"
		;;
	*) error ;;
	esac
done

# Start fawatch as a co-process – its stdout is connected to ${FAWATCH[0]}
cd "$(dirname "$0")"
coproc FAWATCH { ./fawatch "$dir"; }
echo "[$(date)] Started fawatch (PID ${FAWATCH_PID}) on $dir"

declare -a events
function flush() {
	(
		echo -n "[$(date)] Processing ${#events[@]} "
		if [ ${#events[@]} -eq 1 ]; then
			echo event
		else
			echo events
		fi
		# -a = -rlptgoD
		printf '%s\n' "${events[@]}" | rsync --delete --delete-missing-args -lptgoD --files-from=- "$dir" "$target"
	) &
	events=()
}

last_flush=$(date +%s)
while true; do
	# Read from the co‑process stdout with a 1‑second timeout
	if read -t 1 -r path <&${FAWATCH[0]}; then

		if [ ${#events[@]} -eq 0 ]; then
			last_flush=$(date +%s)
		fi

		case "$path" in
		"$dir" | "$dir"/*)
			[ -z "$quiet" ] && echo $path
			events+=("${path#$dir/}")
			;;
		esac
	fi

	# Flush if delay has passed and there are buffered events
	if (($(date +%s) - $last_flush >= $delay)); then
		[ ${#events[@]} -gt 0 ] && flush
		last_flush=$(date +%s)
	fi

	# Check if fawatch is still alive
	if ! kill -0 ${FAWATCH_PID} 2>/dev/null; then
		echo "[$(date)] ERROR: fawatch (PID ${FAWATCH_PID}) died unexpectedly"
		exit 1
	fi
done
