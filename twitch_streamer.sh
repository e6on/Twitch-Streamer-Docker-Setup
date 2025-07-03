#!/bin/bash

# Exit on error, undefined variable, or pipe failure.
set -euo pipefail

# --- Configuration ---
# Define color codes for logging.
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

# Time to wait after a file change before restarting, to batch multiple changes.
readonly RESTART_DEBOUNCE_SECONDS=5

# --- Stream Configuration (can be overridden by environment variables) ---
readonly STREAM_RESOLUTION=${STREAM_RESOLUTION:-"960x540"}
readonly STREAM_FRAMERATE=${STREAM_FRAMERATE:-"25"}
readonly VIDEO_BITRATE=${VIDEO_BITRATE:-"1800k"}
readonly AUDIO_BITRATE=${AUDIO_BITRATE:-"64k"}
readonly VIDEO_FILE_TYPES=${VIDEO_FILE_TYPES:-"mp4 mkv mpg"} # Space-separated list of file extensions.
readonly GOP_SIZE=$((STREAM_FRAMERATE * 2)) # Keyframe every 2 seconds, as recommended by Twitch.
readonly TWITCH_INGEST_URL=${TWITCH_INGEST_URL:-"rtmp://live.twitch.tv/app/"}

# --- Global Variables ---
FILE_LIST=""
FFMPEG_PID=""

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp
    local color="${NC}"
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    case "$level" in
        INFO) color="${GREEN}" ;;
        WARNING) color="${YELLOW}" ;;
        ERROR) color="${RED}" ;;
    esac
    # Log to stderr to not interfere with other command outputs.
    >&2 echo -e "${color}${timestamp} [${level}] ${message}${NC}"
}

# Cleanup function to be called on script exit.
cleanup() {
    log INFO "Cleaning up and exiting..."
    kill_ffmpeg
}

# Check for required commands.
check_dependencies() {
    log INFO "Checking for required dependencies..."
    for cmd in ffmpeg inotifywait; do
        if ! command -v "$cmd" &> /dev/null; then
            log ERROR "Required command '$cmd' is not installed. Please install it and try again."
            exit 1
        fi
    done
}

# Check required environment variables.
check_env_vars() {
    log INFO "Checking for required environment variables..."
    if [[ -z "${VIDEO_DIR:-}" ]]; then
        log ERROR "Required environment variable VIDEO_DIR is not set."
        exit 1
    fi
    if [[ ! -d "${VIDEO_DIR}" ]]; then
        log ERROR "VIDEO_DIR (${VIDEO_DIR}) is not a valid directory."
        exit 1
    fi
    if [[ -z "${TWITCH_STREAM_KEY:-}" ]]; then
        log ERROR "Required environment variable TWITCH_STREAM_KEY is not set."
        exit 1
    fi
    if [[ -z "${STREAM_RESOLUTION:-}" ]]; then
        log ERROR "Required environment variable STREAM_RESOLUTION is not set."
        exit 1
    fi
    if [[ -z "${STREAM_FRAMERATE:-}" ]]; then
        log ERROR "Required environment variable STREAM_FRAMERATE is not set."
        exit 1
    fi
    if [[ -z "${VIDEO_BITRATE:-}" ]]; then
        log ERROR "Required environment variable VIDEO_BITRATE is not set."
        exit 1
    fi
    if [[ -z "${AUDIO_BITRATE:-}" ]]; then
        log ERROR "Required environment variable AUDIO_BITRATE is not set."
        exit 1
    fi
    if [[ -z "${VIDEO_FILE_TYPES:-}" ]]; then
        log ERROR "Required environment variable VIDEO_FILE_TYPES is not set."
        exit 1
    fi
}

# Generate file list
generate_filelist() {
    log INFO "Generating file list from ${VIDEO_DIR} for types: ${VIDEO_FILE_TYPES}..."
    # Sanitize VIDEO_FILE_TYPES to handle values passed with quotes from docker-compose, e.g., "mp4 mkv mov"
    local sanitized_file_types="${VIDEO_FILE_TYPES%\"}" # Remove trailing quote
    sanitized_file_types="${sanitized_file_types#\"}"   # Remove leading quote

    local -a find_args
    find_args=("${VIDEO_DIR}" -type f)

    # Dynamically build the -iname parts of the find command.
    local first=true
    for ext in ${sanitized_file_types}; do
        if [ "$first" = true ]; then
            find_args+=(\( -iname "*.${ext}")
            first=false
        else
            find_args+=(-o -iname "*.${ext}")
        fi
    done
    find_args+=(\))

    # Use find -print0 and read -d '' to robustly handle filenames with special characters.
    {
        find "${find_args[@]}" -print0 |
        sort -z |
        while IFS= read -r -d '' file; do
            echo "file '$file'"
        done
    } > "${FILE_LIST}"
    log INFO "File list generated at ${FILE_LIST}"
}

# Kill FFmpeg process safely
kill_ffmpeg() {
    if [[ -n "$FFMPEG_PID" ]] && kill -0 "$FFMPEG_PID" &>/dev/null; then
        log INFO "Stopping FFmpeg process (PID: $FFMPEG_PID)..."
        kill "$FFMPEG_PID"
        # Wait for the process to terminate, suppressing errors if it's already gone.
        wait "$FFMPEG_PID" &>/dev/null || true
    fi
    FFMPEG_PID=""
}

# Start FFmpeg streaming
start_streaming() {
    if [[ ! -s "${FILE_LIST}" ]]; then
        log WARNING "No video files found in ${VIDEO_DIR}. Waiting for files to be added."
        return
    fi

    log INFO "Starting FFmpeg stream..."
    # Use an array for ffmpeg arguments for clarity and safety.
    local -a ffmpeg_opts
    ffmpeg_opts=(
        -re                   # Read input at native frame rate
        -stream_loop -1       # Loop playlist indefinitely
        -nostdin              # Disable interaction on stdin
        -hwaccel vaapi        # Use VA-API for hardware acceleration
        -vaapi_device /dev/dri/renderD128
        -fflags +genpts       # Generate PTS
        -f concat             # Use concat demuxer
        -safe 0               # Allow unsafe file paths in the list
        -i "${FILE_LIST}"     # Input file list
        -map 0:v:0            # Map first video stream
        -map 0:a:0            # Map first audio stream
        -flags +global_header # Needed for some formats
        -c:a aac              # Audio codec
        -b:a "${AUDIO_BITRATE}" # Audio bitrate
        -ar 44100             # Audio sample rate
        -vf "format=nv12,hwupload,scale_vaapi=w=${STREAM_RESOLUTION%x*}:h=${STREAM_RESOLUTION#*x}" # Video filter
        -c:v h264_vaapi       # Video codec
        -r "${STREAM_FRAMERATE}"  # Video framerate
        -b:v "${VIDEO_BITRATE}"   # Video bitrate
        -minrate "${VIDEO_BITRATE}" # Min video bitrate
        -maxrate "${VIDEO_BITRATE}" # Max video bitrate
        -bufsize "${VIDEO_BITRATE}" # VBV buffer size
        -g "${GOP_SIZE}"          # GOP size (keyframe interval in frames)
        -keyint_min "${GOP_SIZE}" # Min keyframe interval
        -f flv                # Output format
        "${TWITCH_INGEST_URL}${TWITCH_STREAM_KEY}"
    )

    # Run ffmpeg in the background.
    ffmpeg "${ffmpeg_opts[@]}" &
    FFMPEG_PID=$!
    log INFO "FFmpeg started with PID: ${FFMPEG_PID}"
}

# Watch for changes and signal restart with debouncing.
watch_for_changes() {
    log INFO "Watching for changes in ${VIDEO_DIR}..."
    # Watch for events that indicate a file has been completely written or moved into the directory.
    # - close_write: A file opened for writing was closed (for direct copies).
    # - moved_to: A file was moved/renamed into the directory (for atomic "safe copy" operations).
    # - delete: A file was deleted.
    inotifywait -mq -e close_write -e moved_to -e delete "${VIDEO_DIR}" |
    while true; do
        # Wait for the first event. If the read fails, the pipe has closed.
        if ! read -r path event file; then
            log ERROR "inotifywait process finished unexpectedly."
            break
        fi

        # Store the details of the last seen event.
        local last_path="${path}"
        local last_event="${event}"
        local last_file="${file}"
        log INFO "Change detected (${last_event} on ${last_path}${last_file}). Debouncing for ${RESTART_DEBOUNCE_SECONDS}s..."

        # Consume subsequent events for the debounce period.
        while read -r -t "${RESTART_DEBOUNCE_SECONDS}" path event file; do
            last_path="${path}"
            last_event="${event}"
            last_file="${file}"
            log INFO "Further change detected (${last_event} on ${last_path}${last_file}). Resetting debounce timer."
        done

        log INFO "Debounce timer finished. Final change was: ${last_event} on ${last_path}${last_file}. Restarting stream..."
        kill_ffmpeg
        generate_filelist
        start_streaming
    done
}

main() {
    # Trap EXIT signal to ensure cleanup runs, regardless of how the script exits.
    trap cleanup EXIT

    check_dependencies
    check_env_vars

    # Use a persistent file in the /data volume for the playlist.
    FILE_LIST="/data/filelist.txt"
    log INFO "Using filelist, which will be available on the host at ./data/filelist.txt"

    # Initial setup
    generate_filelist
    start_streaming
    watch_for_changes
}

main "$@"
