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
readonly STREAM_FRAMERATE=${STREAM_FRAMERATE:-"30"}
readonly VIDEO_BITRATE=${VIDEO_BITRATE:-"1800k"}
readonly AUDIO_BITRATE=${AUDIO_BITRATE:-"64k"}
readonly GOP_SIZE=$((STREAM_FRAMERATE * 2)) # Keyframe every 2 seconds, as recommended by Twitch.
readonly TWITCH_INGEST_URL=${TWITCH_INGEST_URL:-"rtmp://live.twitch.tv/app/"}

# --- File Type Configuration ---
readonly VIDEO_FILE_TYPES=${VIDEO_FILE_TYPES:-"mp4 mkv mpg mov"} # Space-separated list of video file extensions.
readonly MUSIC_FILE_TYPES=${MUSIC_FILE_TYPES:-"mp3 flac wav ogg"} # Space-separated list of music file extensions.

# --- Feature Flags ---
readonly ENABLE_MUSIC=${ENABLE_MUSIC:-"false"}
readonly ENABLE_FFMPEG_LOG_FILE=${ENABLE_FFMPEG_LOG_FILE:-"false"}

# --- Global Variables ---
VIDEO_FILE_LIST=""
MUSIC_FILE_LIST=""
FFMPEG_LOG_FILE=""
FFMPEG_PID=""
FFMPEG_PIPE=""

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
    if [[ -n "${FFMPEG_PIPE:-}" ]] && [[ -p "${FFMPEG_PIPE}" ]]; then
        rm -f "${FFMPEG_PIPE}"
    fi
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

    if [[ "${ENABLE_MUSIC}" == "true" ]]; then
        log INFO "Music is enabled. Checking music-related variables..."
        if [[ -z "${MUSIC_DIR:-}" ]]; then
            log ERROR "ENABLE_MUSIC is true, but MUSIC_DIR is not set."
            exit 1
        fi
        if [[ ! -d "${MUSIC_DIR}" ]]; then
            log ERROR "MUSIC_DIR (${MUSIC_DIR}) is not a valid directory."
            exit 1
        fi
    fi
}

# Generic function to generate a playlist file from a directory of media files.
# Arguments:
#   $1: The directory to scan for files (e.g., /videos).
#   $2: A space-separated string of file extensions (e.g., "mp4 mkv").
#   $3: The path to the output playlist file (e.g., /data/videolist.txt).
#   $4: The type of media for logging purposes (e.g., "Video").
generate_playlist() {
    local source_dir="$1"
    local file_types="$2"
    local output_file="$3"
    local media_type="$4"

    log INFO "Generating ${media_type} list from ${source_dir} for types: ${file_types}..."
    # Sanitize file_types to handle values passed with quotes from docker-compose, e.g., "mp4 mkv mov"
    local sanitized_file_types="${file_types%\"}" # Remove trailing quote
    sanitized_file_types="${sanitized_file_types#\"}"   # Remove leading quote

    if [[ -z "${sanitized_file_types}" ]]; then
        log WARNING "No file types specified for ${media_type}. Playlist will be empty."
        # Create an empty file and return to prevent find from listing all files.
        > "${output_file}"
        return
    fi

    local -a find_args
    find_args=("${source_dir}" -type f)

    # Dynamically build the -iname parts of the find command.
    local first=true
    for ext in ${sanitized_file_types}; do
        if [ "$first" = true ]; then
            # Start the expression group
            find_args+=(\( -iname "*.${ext}")
            first=false
        else
            # Append other extensions with an "or" operator
            find_args+=(-o -iname "*.${ext}")
        fi
    done
    find_args+=(\)) # Close the expression group

    # Use find -print0 and read -d '' to robustly handle filenames with special characters.
    { find "${find_args[@]}" -print0 | sort -z | while IFS= read -r -d '' file; do echo "file '$file'"; done; } > "${output_file}"
    log INFO "${media_type} file list generated at ${output_file}"
}

# Wrapper function to generate the video playlist.
generate_videolist() {
    generate_playlist "${VIDEO_DIR}" "${VIDEO_FILE_TYPES}" "${VIDEO_FILE_LIST}" "Video"
}

# Wrapper function to generate the music playlist.
generate_musiclist() {
    if [[ "${ENABLE_MUSIC}" != "true" ]]; then
        return
    fi
    generate_playlist "${MUSIC_DIR}" "${MUSIC_FILE_TYPES}" "${MUSIC_FILE_LIST}" "Music"
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
    # The log processor will exit on its own when the pipe is broken.
}

# Process FFmpeg's stderr to log currently playing files.
process_ffmpeg_output() {
    # This function reads from FFmpeg's stderr line by line.
    while IFS= read -r line; do
        # Check if the line indicates a new file is being opened. FFmpeg logs this differently
        # depending on the context, so we check for both `concat` and `AVFormatContext`.
        # Example 1: [concat @ 0x...] Opening '/videos/video1.mp4' for reading
        # Example 2: [AVFormatContext @ 0x...] Opening '/videos/video1.mp4' for reading
        if [[ "$line" =~ \[(concat|AVFormatContext).*\]\ Opening\ \'(.+)\'\ for\ reading ]]; then
            local playing_file
            playing_file="${BASH_REMATCH[2]}"
            # Determine if it's a video or music file based on its path and log it.
            if [[ "$playing_file" == "${VIDEO_DIR}"* ]]; then
                log INFO "Now Playing Video: $(basename "${playing_file}")"
            elif [[ "${ENABLE_MUSIC}" == "true" && "$playing_file" == "${MUSIC_DIR}"* ]]; then
                log INFO "Now Playing Music: $(basename "${playing_file}")"
            fi
        fi
        # The raw ffmpeg output is intentionally not echoed here. This function's only job is to parse
        # the stream for "Now Playing" events, keeping the main container log clean. The full debug log
        # is either sent to a file (if enabled) or discarded.
    done
}

# Start FFmpeg streaming
start_streaming() {
    if [[ ! -s "${VIDEO_FILE_LIST}" ]]; then
        log WARNING "No video files found in ${VIDEO_DIR}. Waiting for files to be added."
        return
    fi

    local -a ffmpeg_opts
    local music_enabled_and_found=false
    if [[ "${ENABLE_MUSIC}" == "true" ]] && [[ -s "${MUSIC_FILE_LIST}" ]]; then
        music_enabled_and_found=true
        log INFO "Music is enabled and music files were found. Replacing video audio with music playlist."
    fi

    # Common options
    # Set loglevel to debug to get maximum information, which should include the 'Opening file...' messages.
    ffmpeg_opts+=(-nostdin -v debug -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -fflags +genpts)

    # Input options
    # The -re flag is crucial for the video input to simulate a live stream. It should NOT be applied to the audio input.
    ffmpeg_opts+=(-re -stream_loop -1 -f concat -safe 0 -i "${VIDEO_FILE_LIST}") # Video input
    if [[ "$music_enabled_and_found" == "true" ]]; then
        ffmpeg_opts+=(-stream_loop -1 -f concat -safe 0 -i "${MUSIC_FILE_LIST}") # Music input
    fi

    # Video filter chain definition
    local video_filter_chain="format=nv12,hwupload,scale_vaapi=w=${STREAM_RESOLUTION%x*}:h=${STREAM_RESOLUTION#*x}"

    # Mapping and filtering options
    if [[ "$music_enabled_and_found" == "true" ]]; then
        # Use filter_complex to apply video filters and ensure seamless audio looping.
        # The 'aresample=44100' filter standardizes all incoming audio to a 44.1kHz sample rate to prevent freezes with mixed-rate sources.
        # The 'asetpts=PTS-STARTPTS' filter then resets audio timestamps each time the playlist loops,
        # creating a continuous stream and preventing ffmpeg from terminating.
        ffmpeg_opts+=(-filter_complex "[0:v]${video_filter_chain}[v];[1:a]aresample=44100,asetpts=PTS-STARTPTS[a]" -map "[v]" -map "[a]")
    else
        # No music, so map video and its original audio, and apply the video filter directly.
        ffmpeg_opts+=(-map 0:v:0 -map 0:a:0 -vf "${video_filter_chain}")
    fi

    # Output options
    ffmpeg_opts+=(
        -flags +global_header
        -vsync cfr
        # Audio settings
        -c:a aac
        -b:a "${AUDIO_BITRATE}"
        -ar 44100
        # Video settings
        -c:v h264_vaapi
        -r "${STREAM_FRAMERATE}"
        -b:v "${VIDEO_BITRATE}"
        -minrate "${VIDEO_BITRATE}"
        -maxrate "${VIDEO_BITRATE}"
        -bufsize "${VIDEO_BITRATE}"
        -g "${GOP_SIZE}"
        -keyint_min "${GOP_SIZE}"
        # Format and destination
        -f flv
        "${TWITCH_INGEST_URL}${TWITCH_STREAM_KEY}"
    )

    log INFO "Starting FFmpeg stream..."

    # Start the log processor in the background, reading from our named pipe.
    if [[ "${ENABLE_FFMPEG_LOG_FILE}" == "true" ]]; then
        # If file logging is enabled, tee the output from the pipe to the log file and to the processor.
        <"${FFMPEG_PIPE}" tee -a "${FFMPEG_LOG_FILE}" | process_ffmpeg_output &
    else
        # Otherwise, just pipe from the named pipe to the processor.
        <"${FFMPEG_PIPE}" process_ffmpeg_output &
    fi

    # Start ffmpeg, redirect its output to the named pipe, and get its actual PID.
    ffmpeg "${ffmpeg_opts[@]}" >"${FFMPEG_PIPE}" 2>&1 &
    FFMPEG_PID=$!
    log INFO "FFmpeg started with PID: ${FFMPEG_PID}"
}

# Watch for changes and signal restart with debouncing.
watch_for_changes() {
    local -a watch_dirs
    watch_dirs=("${VIDEO_DIR}")
    if [[ "${ENABLE_MUSIC}" == "true" ]]; then
        watch_dirs+=("${MUSIC_DIR}")
    fi

    log INFO "Watching for changes in: ${watch_dirs[*]}..."
    # Watch for events that indicate a file has been added, removed, or changed.
    # - close_write: A file opened for writing was closed (for direct copies).
    # - moved_to: A file was moved/renamed into the directory (for atomic "safe copy" operations).
    # - delete: A file was deleted.
    # - moved_from: A file was moved out of the directory (e.g., to Trash).
    inotifywait -mqr -e close_write -e moved_to -e delete -e create -e moved_from "${watch_dirs[@]}" |
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
        generate_videolist
        generate_musiclist
        start_streaming
    done
}

main() {
    # Trap EXIT signal to ensure cleanup runs, regardless of how the script exits.
    trap cleanup EXIT

    # Create a named pipe for reliable PID capture and log processing.
    FFMPEG_PIPE=$(mktemp -u)
    mkfifo "${FFMPEG_PIPE}"

    check_dependencies
    check_env_vars

    # Use persistent files in the /data volume for the playlists.
    VIDEO_FILE_LIST="/data/videolist.txt"
    log INFO "Using videolist, which will be available on the host at ./data/videolist.txt"

    if [[ "${ENABLE_MUSIC}" == "true" ]]; then
        MUSIC_FILE_LIST="/data/musiclist.txt"
        log INFO "Using musiclist, which will be available on the host at ./data/musiclist.txt"
    fi

    if [[ "${ENABLE_FFMPEG_LOG_FILE}" == "true" ]]; then
        FFMPEG_LOG_FILE="/data/ffmpeg.log"
        log INFO "FFmpeg debug logs will be written to a file, accessible on the host at ./data/ffmpeg.log"
        # Overwrite the log file on start to prevent it from growing indefinitely across container restarts.
        > "${FFMPEG_LOG_FILE}"
    fi
    # Initial setup
    generate_videolist
    generate_musiclist
    start_streaming
    watch_for_changes
}

main "$@"
