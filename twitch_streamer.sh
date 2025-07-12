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

# --- Music & Feature Flags ---
readonly ENABLE_MUSIC=${ENABLE_MUSIC:-"false"}
readonly ENABLE_FFMPEG_LOG_FILE=${ENABLE_FFMPEG_LOG_FILE:-"false"}
readonly MUSIC_VOLUME=${MUSIC_VOLUME:-"1.0"} # Music volume. 1.0 is 100%, 0.5 is 50%.

# --- Global Variables ---
VIDEO_FILE_LIST=""
MUSIC_FILE_LIST=""
VALIDATED_VIDEO_FILE_LIST=""
VALIDATED_MUSIC_FILE_LIST=""
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
    for cmd in ffmpeg ffprobe inotifywait bc; do
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

# Validate music files for compatibility to prevent stream freezes.
# It checks for consistent sample rate and channel layout.
validate_music_files() {
    if [[ "${ENABLE_MUSIC}" != "true" ]]; then
        # Music is disabled, so there is nothing to validate.
        return
    fi

    if [[ ! -s "${MUSIC_FILE_LIST}" ]]; then
        # Music is enabled, but no files were found. Ensure the validated list is empty.
        > "${VALIDATED_MUSIC_FILE_LIST}"
        return
    fi

    log INFO "Validating music files for stream compatibility..."
    > "${VALIDATED_MUSIC_FILE_LIST}" # Start with a clean slate.

    local reference_sample_rate=""
    local reference_channels=""
    local reference_file=""

    # Read the generated playlist file line by line.
    while IFS= read -r line; do
        # Extract file path from the format: file '/path/to/file.mp3'
        if ! [[ "$line" =~ ^file\ \'(.*)\'$ ]]; then
            continue
        fi
        local current_file="${BASH_REMATCH[1]}"

        # Get audio properties using ffprobe.
        local probe_output
        # Use the CSV output format to get a single line of comma-separated values.
        if ! probe_output=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate,channels -of csv=p=0 "${current_file}"); then
            log WARNING "Could not probe audio stream for '$(basename "${current_file}")'. Skipping."
            continue
        fi

        local current_sample_rate current_channels="" # Initialize to prevent using value from previous iteration on error.
        IFS=',' read -r current_sample_rate current_channels <<< "${probe_output}"

        # The first valid file sets the standard for the playlist.
        if [[ -z "${reference_sample_rate}" ]]; then
            reference_sample_rate="${current_sample_rate}"
            reference_channels="${current_channels}"
            reference_file="$(basename "${current_file}")"
            log INFO "Music compatibility reference set by '${reference_file}': Sample Rate=${reference_sample_rate}, Channels=${reference_channels}"
            echo "$line" >> "${VALIDATED_MUSIC_FILE_LIST}"
            continue
        fi

        # Validate subsequent files against the reference.
        local is_compatible=true
        if [[ "${current_sample_rate}" != "${reference_sample_rate}" ]]; then
            log WARNING "Skipping '$(basename "${current_file}")' due to mismatched sample rate. Expected: ${reference_sample_rate}, Found: ${current_sample_rate}."
            is_compatible=false
        fi
        if [[ "${current_channels}" != "${reference_channels}" ]]; then
            log WARNING "Skipping '$(basename "${current_file}")' due to mismatched audio channels. Expected: ${reference_channels}, Found: ${current_channels}."
            is_compatible=false
        fi

        if [[ "$is_compatible" == true ]]; then
            echo "$line" >> "${VALIDATED_MUSIC_FILE_LIST}"
        fi
    done < "${MUSIC_FILE_LIST}"

    if [[ ! -s "${VALIDATED_MUSIC_FILE_LIST}" ]]; then
        log WARNING "No compatible music files found after validation. Music will be disabled for this stream."
    fi
}

# Validates video files for stream compatibility.
# It checks for consistent resolution and pixel format.
# If background music is disabled, it also validates audio for consistent sample rate and channels.
validate_video_files() {
    if [[ ! -s "${VIDEO_FILE_LIST}" ]]; then
        > "${VALIDATED_VIDEO_FILE_LIST}"
        return
    fi

    log INFO "Validating video files for stream compatibility..."
    > "${VALIDATED_VIDEO_FILE_LIST}" # Start with a clean slate.

    local reference_width=""
    local reference_height=""
    local reference_pix_fmt=""
    local reference_frame_rate=""
    local reference_sample_rate=""
    local reference_channels=""
    local reference_file=""

    local validate_audio=true
    if [[ "${ENABLE_MUSIC}" == "true" ]]; then
        validate_audio=false
        log INFO "Music is enabled; skipping video audio validation."
    fi

    while IFS= read -r line; do
        if ! [[ "$line" =~ ^file\ \'(.*)\'$ ]]; then
            continue
        fi
        local current_file="${BASH_REMATCH[1]}"

        # --- Video Validation ---
        local video_probe_output
        if ! video_probe_output=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,pix_fmt,r_frame_rate -of csv=p=0 "${current_file}"); then
            log WARNING "Could not probe video stream for '$(basename "${current_file}")'. Skipping."
            continue
        fi
        local current_width current_height current_pix_fmt current_frame_rate
        IFS=',' read -r current_width current_height current_pix_fmt current_frame_rate <<< "${video_probe_output}"

        # --- Audio Validation (if applicable) ---
        local audio_probe_output current_sample_rate current_channels
        if [[ "$validate_audio" == "true" ]]; then
            if ! audio_probe_output=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate,channels -of csv=p=0 "${current_file}"); then
                log WARNING "Could not probe audio stream for video '$(basename "${current_file}")'. It might not have audio. Skipping."
                continue
            fi
            IFS=',' read -r current_sample_rate current_channels <<< "${audio_probe_output}"
        fi

        # --- Set Reference from First File ---
        if [[ -z "${reference_width}" ]]; then
            reference_width="${current_width}"
            reference_height="${current_height}"
            reference_pix_fmt="${current_pix_fmt}"
            reference_frame_rate="${current_frame_rate}"
            reference_file="$(basename "${current_file}")"
            local ref_log_msg="Video compatibility reference set by '${reference_file}': Resolution=${reference_width}x${reference_height}, PixelFormat=${reference_pix_fmt}, FrameRate=${reference_frame_rate}"

            if [[ "$validate_audio" == "true" ]]; then
                reference_sample_rate="${current_sample_rate}"
                reference_channels="${current_channels}"
                ref_log_msg+=", AudioSampleRate=${reference_sample_rate}, AudioChannels=${reference_channels}"
            fi
            log INFO "${ref_log_msg}"
            echo "$line" >> "${VALIDATED_VIDEO_FILE_LIST}"
            continue
        fi

        # --- Compare Subsequent Files to Reference ---
        local is_compatible=true
        # Video checks
        if [[ "${current_width}" != "${reference_width}" ]] || [[ "${current_height}" != "${reference_height}" ]]; then
            log WARNING "Skipping video '$(basename "${current_file}")' due to mismatched resolution. Expected: ${reference_width}x${reference_height}, Found: ${current_width}x${current_height}."
            is_compatible=false
        fi
        if [[ "${current_pix_fmt}" != "${reference_pix_fmt}" ]]; then
            log WARNING "Skipping video '$(basename "${current_file}")' due to mismatched pixel format. Expected: ${reference_pix_fmt}, Found: ${current_pix_fmt}."
            is_compatible=false
        fi
        # Frame rate check: allow exact matches or integer multiples (e.g., 60fps is ok if reference is 30fps).
        if [[ "${current_frame_rate}" != "${reference_frame_rate}" ]]; then
            local ref_num ref_den cur_num cur_den
            IFS='/' read -r ref_num ref_den <<< "${reference_frame_rate}"
            IFS='/' read -r cur_num cur_den <<< "${current_frame_rate}"
            ref_den=${ref_den:-1}
            cur_den=${cur_den:-1}

            # Use 'bc' for floating-point math to handle common near-integer framerates like 29.97 (30000/1001) vs 30.
            # We calculate the ratio and check if it's very close to an integer (e.g., 1.0, 2.0, etc.).
            local denominator_val
            denominator_val=$(echo "${cur_den} * ${ref_num}" | bc)

            if (( $(echo "${denominator_val} == 0" | bc -l) )); then
                log WARNING "Skipping video '$(basename "${current_file}")' due to invalid reference frame rate resulting in division by zero."
                is_compatible=false
            else
                local ratio
                ratio=$(echo "scale=5; (${cur_num} * ${ref_den}) / ${denominator_val}" | bc)
                local rounded_ratio
                rounded_ratio=$(printf "%.0f" "${ratio}")
                local diff
                diff=$(echo "scale=5; d = ${ratio} - ${rounded_ratio}; if (d < 0) d = -d; d" | bc)

                # Allow if the ratio is a multiple (>= 1) and the difference from a whole number is negligible (e.g., 0.999 or 2.001).
                if (( $(echo "${ratio} >= 0.99 && ${diff} < 0.01" | bc -l) )); then
                    log INFO "Video '$(basename "${current_file}")' has a compatible frame rate (${current_frame_rate}). Accepting."
                else
                    log WARNING "Skipping video '$(basename "${current_file}")' due to incompatible frame rate. Expected: ${reference_frame_rate} or a multiple, Found: ${current_frame_rate}."
                    is_compatible=false
                fi
            fi
        fi

        # Audio checks
        if [[ "$validate_audio" == "true" ]]; then
            if [[ "${current_sample_rate}" != "${reference_sample_rate}" ]]; then
                log WARNING "Skipping video '$(basename "${current_file}")' due to mismatched audio sample rate. Expected: ${reference_sample_rate}, Found: ${current_sample_rate}."
                is_compatible=false
            fi
            if [[ "${current_channels}" != "${reference_channels}" ]]; then
                log WARNING "Skipping video '$(basename "${current_file}")' due to mismatched audio channels. Expected: ${reference_channels}, Found: ${current_channels}."
                is_compatible=false
            fi
        fi

        if [[ "$is_compatible" == true ]]; then
            echo "$line" >> "${VALIDATED_VIDEO_FILE_LIST}"
        fi
    done < "${VIDEO_FILE_LIST}"

    if [[ ! -s "${VALIDATED_VIDEO_FILE_LIST}" ]]; then
        log WARNING "No videos with compatible properties found after validation. The stream will not start."
    fi
}

# Kill FFmpeg process safely
kill_ffmpeg() {
    if [[ -n "$FFMPEG_PID" ]] && kill -0 "$FFMPEG_PID" &>/dev/null; then
        log WARNING "Stopping FFmpeg process (PID: $FFMPEG_PID)..."
        kill "$FFMPEG_PID"
        # Wait for the process to terminate, suppressing errors if it's already gone.
        wait "$FFMPEG_PID" &>/dev/null || true
    fi
    FFMPEG_PID=""
    # The log processor will exit on its own when the pipe is broken.
}

# Calculates and logs the total duration of a playlist.
# Arguments:
#   $1: Path to the validated playlist file.
#   $2: Media type for logging (e.g., "Video", "Music").
log_total_playlist_duration() {
    local playlist_file="$1"
    local media_type="$2"
    # Use scale=4 for bc to handle floating point numbers from ffprobe.
    local total_duration_seconds="0.0"

    if [[ ! -s "${playlist_file}" ]]; then
        # This is not an error, just means an empty playlist.
        return
    fi

    log INFO "Calculating total ${media_type} playlist duration..."
    while IFS= read -r line; do
        if ! [[ "$line" =~ ^file\ \'(.*)\'$ ]]; then
            continue
        fi
        local current_file="${BASH_REMATCH[1]}"

        local duration
        if ! duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "${current_file}"); then
            log WARNING "Could not get duration for '$(basename "${current_file}")'. Skipping from total calculation."
            continue
        fi
        if [[ -z "$duration" ]]; then
            log WARNING "Could not get duration for '$(basename "${current_file}")' (duration was empty). Skipping from total calculation."
            continue
        fi
        total_duration_seconds=$(echo "scale=4; ${total_duration_seconds} + ${duration}" | bc)
    done < "${playlist_file}"

    # Format the duration into Dd HH:MM:SS
    if (( $(echo "${total_duration_seconds} > 0" | bc -l) )); then
        local total_seconds_int
        total_seconds_int=$(printf "%.0f" "${total_duration_seconds}")
        local days=$((total_seconds_int / 86400)); local hours=$(((total_seconds_int % 86400) / 3600)); local minutes=$(((total_seconds_int % 3600) / 60)); local seconds=$((total_seconds_int % 60))
        local formatted_duration=""
        if (( days > 0 )); then formatted_duration+="${days}d "; fi
        formatted_duration+=$(printf "%02d:%02d:%02d" "${hours}" "${minutes}" "${seconds}")
        log INFO "Total ${media_type} playlist duration: ${YELLOW}${formatted_duration}${NC}"
    fi
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
    if [[ ! -s "${VALIDATED_VIDEO_FILE_LIST}" ]]; then
        log WARNING "No compatible video files found to stream. Waiting for files to be added or corrected."
        return
    fi

    local -a ffmpeg_opts
    local music_enabled_and_found=false
    if [[ "${ENABLE_MUSIC}" == "true" ]] && [[ -s "${VALIDATED_MUSIC_FILE_LIST}" ]]; then
        music_enabled_and_found=true
        log INFO "Music is enabled and compatible music files were found. Replacing video audio with validated playlist."
    fi

    # Common options
    # Set loglevel to debug to get maximum information, which should include the 'Opening file...' messages.
    ffmpeg_opts+=(-nostdin -v debug -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -fflags +genpts)

    # Input options
    # The -re flag is crucial for the video input to simulate a live stream. It should NOT be applied to the audio input.
    ffmpeg_opts+=(-re -stream_loop -1 -f concat -safe 0 -i "${VALIDATED_VIDEO_FILE_LIST}") # Video input
    if [[ "$music_enabled_and_found" == "true" ]]; then
        ffmpeg_opts+=(-stream_loop -1 -f concat -safe 0 -i "${VALIDATED_MUSIC_FILE_LIST}") # Music input
    fi

    # Video filter chain definition
    local video_filter_chain="format=nv12,hwupload,scale_vaapi=w=${STREAM_RESOLUTION%x*}:h=${STREAM_RESOLUTION#*x}"

    # Mapping and filtering options
    if [[ "$music_enabled_and_found" == "true" ]]; then
        log INFO "Setting music volume to ${MUSIC_VOLUME}"
        local audio_filter_chain="volume=${MUSIC_VOLUME},asetpts=PTS-STARTPTS"
        # Use filter_complex to apply video filters and ensure seamless audio looping.
        # The 'asetpts=PTS-STARTPTS' filter resets audio timestamps each time the playlist loops,
        # creating a continuous stream and preventing ffmpeg from terminating.
        ffmpeg_opts+=(-filter_complex "[0:v]${video_filter_chain}[v];[1:a]${audio_filter_chain}[a]" -map "[v]" -map "[a]")
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
        log WARNING "Change detected (${last_event} on ${last_path}${last_file}). Debouncing for ${RESTART_DEBOUNCE_SECONDS}s..."

        # Consume subsequent events for the debounce period.
        while read -r -t "${RESTART_DEBOUNCE_SECONDS}" path event file; do
            last_path="${path}"
            last_event="${event}"
            last_file="${file}"
            log WARNING "Further change detected (${last_event} on ${last_path}${last_file}). Resetting debounce timer."
        done

        log WARNING "Debounce timer finished. Final change was: ${last_event} on ${last_path}${last_file}. Restarting stream..."
        kill_ffmpeg
        generate_videolist
        validate_video_files
        generate_musiclist
        validate_music_files
        log_total_playlist_duration "${VALIDATED_VIDEO_FILE_LIST}" "Video"
        [[ "${ENABLE_MUSIC}" == "true" ]] && log_total_playlist_duration "${VALIDATED_MUSIC_FILE_LIST}" "Music"
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
    VALIDATED_VIDEO_FILE_LIST="/data/validated_videolist.txt"
    log INFO "Using videolist, which will be available on the host at ./data/videolist.txt"

    if [[ "${ENABLE_MUSIC}" == "true" ]]; then
        MUSIC_FILE_LIST="/data/musiclist.txt"
        VALIDATED_MUSIC_FILE_LIST="/data/validated_musiclist.txt"
        log INFO "Using musiclist, which will be available on the host at ./data/musiclist.txt"
    fi

    if [[ "${ENABLE_FFMPEG_LOG_FILE}" == "true" ]]; then
        FFMPEG_LOG_FILE="/data/ffmpeg.log"
        log WARNING "FFmpeg debug logs will be written to a file, accessible on the host at ./data/ffmpeg.log"
        # Overwrite the log file on start to prevent it from growing indefinitely across container restarts.
        > "${FFMPEG_LOG_FILE}"
    fi
    # Initial setup
    generate_videolist
    validate_video_files
    generate_musiclist
    validate_music_files
    log_total_playlist_duration "${VALIDATED_VIDEO_FILE_LIST}" "Video"
    [[ "${ENABLE_MUSIC}" == "true" ]] && log_total_playlist_duration "${VALIDATED_MUSIC_FILE_LIST}" "Music"
    start_streaming
    watch_for_changes
}

main "$@"
