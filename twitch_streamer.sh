#!/bin/bash

# Exit on error, undefined variable, or pipe failure.
set -euo pipefail

# --- Configuration ---
# Define color codes for logging.
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[1;36m'
readonly NC='\033[0m' # No Color

# Time to wait after a file change before restarting, to batch multiple changes.
readonly RESTART_DEBOUNCE_SECONDS=5

# --- Stall Detection Configuration ---
# How often (in seconds) to check if ffmpeg is stalled.
readonly STALL_MONITOR_INTERVAL=15
# How many times the speed must be 0/s before we declare it stalled and restart.
# (e.g., 4 * 15s = 60 seconds of zero activity before restart).
readonly STALL_THRESHOLD=4

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
readonly ENABLE_SCRIPT_LOG_FILE=${ENABLE_SCRIPT_LOG_FILE:-"false"}
readonly SCRIPT_LOG_FILE=${SCRIPT_LOG_FILE:-"/data/script_warnings_errors.log"}

# --- Global Variables ---
VIDEO_FILE_LIST=""
MUSIC_FILE_LIST=""
VALIDATED_VIDEO_FILE_LIST=""
VALIDATED_MUSIC_FILE_LIST=""
FILTERED_VIDEO_FILE_LIST=""
EXCLUDED_VIDEO_FILE_PATH="/data/excluded_videos.txt"
NEW_VIDEO_TIMESTAMP_FILE="/data/new_video_started.tmp"
FFMPEG_LOG_FILE=""
FFMPEG_PID=""
FFMPEG_PIPE=""
CURRENTLY_PLAYING_VIDEO_BASENAME=""
MONITOR_PID=""
LOG_PROCESSOR_PID=""
PLAYLIST_LOOP_COUNT=0
FIRST_VIDEO_FILE=""
VIDEO_DURATION=""
VIDEO_FILE_COUNT=0

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp
    local color="${NC}"
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    case "$level" in
        INFO) color="${GREEN}" ;;
        MUSIC) color="${GREEN}" ;;
        WARNING) color="${YELLOW}" ;;
        VIDEO) color="${CYAN}" ;;
        ERROR) color="${RED}" ;;
    esac
    # Log to stderr to not interfere with other command outputs.
    >&2 echo -e "${color}${timestamp} [${level}] ${message}${NC}"

    if [[ "${ENABLE_SCRIPT_LOG_FILE}" == "true" ]]; then
        if [[ "$level" == "WARNING" ]] || [[ "$level" == "ERROR" ]] || [[ "$level" == "VIDEO" ]]; then
            # Write uncolored message to the log file.
            echo "${timestamp} [${level}] ${message}" >> "${SCRIPT_LOG_FILE}"
        fi
    fi
}

# Cleanup function to be called on script exit.
cleanup() {
    log INFO "Cleaning up and exiting..."
    kill_ffmpeg
    kill_monitor
    kill_log_processor
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
            FIRST_VIDEO_FILE="${reference_file}"
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
        # Frame rate check: allow if one frame rate is an integer multiple of the other (e.g., 30/60, 60/30, 24/48).
        if [[ "${current_frame_rate}" != "${reference_frame_rate}" ]]; then
            local ref_num ref_den cur_num cur_den
            IFS='/' read -r ref_num ref_den <<< "${reference_frame_rate}"
            ref_den=${ref_den:-1} # Default denominator to 1 if not specified (e.g. 30 instead of 30/1)
            IFS='/' read -r cur_num cur_den <<< "${current_frame_rate}"
            cur_den=${cur_den:-1} # Default denominator to 1

            # Use 'bc' for floating-point math to handle fractional frame rates like 29.97 (30000/1001).
            # To avoid division by zero if a frame rate is reported as 0/0 or similar.
            if (( $(echo "(${cur_den} * ${ref_num}) == 0" | bc -l) )) || (( $(echo "(${ref_den} * ${cur_num}) == 0" | bc -l) )); then
                log WARNING "Skipping video '$(basename "${current_file}")' due to zero value in frame rate calculation. Ref: ${reference_frame_rate}, Current: ${current_frame_rate}."
                is_compatible=false
            else
                # Calculate two ratios: current/reference and reference/current.
                local ratio_cur_over_ref ratio_ref_over_cur
                ratio_cur_over_ref=$(echo "scale=5; (${cur_num} * ${ref_den}) / (${cur_den} * ${ref_num})" | bc)
                ratio_ref_over_cur=$(echo "scale=5; (${ref_num} * ${cur_den}) / (${ref_den} * ${cur_num})" | bc)

                # Check if either ratio is close to an integer >= 1.
                local is_multiple=0
                for ratio in "${ratio_cur_over_ref}" "${ratio_ref_over_cur}"; do
                    local rounded_ratio
                    rounded_ratio=$(printf "%.0f" "${ratio}")
                    local diff
                    diff=$(echo "scale=5; d = ${ratio} - ${rounded_ratio}; if (d < 0) d = -d; d" | bc)
                    # A ratio is considered a valid multiple if it's >= 1 (within a tolerance) and close to a whole number.
                    if (( $(echo "${ratio} >= 0.99 && ${diff} < 0.01" | bc -l) )); then
                        is_multiple=1
                        break
                    fi
                done
                if [[ "${is_multiple}" -eq 1 ]]; then
                    log INFO "Video '$(basename "${current_file}")' has a frame rate (${current_frame_rate}). Accepting."
                else
                    log WARNING "Skipping video '$(basename "${current_file}")' due to incompatible frame rate. Expected a multiple or divisor of ${reference_frame_rate}, but found ${current_frame_rate}."
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

# Filters the validated video list based on EXCLUDED_VIDEO_FILES
filter_excluded_files() {
    local input_list="${VALIDATED_VIDEO_FILE_LIST}"
    local output_list="${FILTERED_VIDEO_FILE_LIST}"

    log INFO "Filtering excluded video files from ${input_list} to ${output_list}..."
    > "${output_list}" # Start with a clean slate.

    # Initialize EXCLUDED_VIDEO_FILES as an empty array
    local -a EXCLUDED_VIDEO_FILES=()

    if [[ -f "${EXCLUDED_VIDEO_FILE_PATH}" ]]; then
        mapfile -t EXCLUDED_VIDEO_FILES < "${EXCLUDED_VIDEO_FILE_PATH}"
    fi

    if [[ ${#EXCLUDED_VIDEO_FILES[@]} -eq 0 ]]; then # Check if array is empty
        log INFO "No video files to exclude."
        cp "${input_list}" "${output_list}" || true # Copy if no exclusions
        return
    fi

    # Read the validated list line by line and filter
    while IFS= read -r line; do
        if ! [[ "$line" =~ ^file\ \'(.*)\'$ ]]; then
            continue
        fi
        local current_file_path="${BASH_REMATCH[1]}"
        local current_file_basename=$(basename "${current_file_path}")

        local is_excluded=false
        for excluded_file in "${EXCLUDED_VIDEO_FILES[@]}"; do
            # Compare basename for exclusion
            if [[ "${current_file_basename}" == "${excluded_file}" ]]; then
                log WARNING "Excluding video: '${current_file_basename}' (previously caused stall)."
                is_excluded=true
                break
            fi
        done

        if [[ "$is_excluded" == false ]]; then
            echo "$line" >> "${output_list}"
        fi
    done < "${input_list}"

    if [[ ! -s "${output_list}" ]]; then
        log ERROR "No video files remaining after exclusion. Stream might not start."
    else
        log INFO "Filtered video playlist created at ${output_list}."
    fi
}

# Kill FFmpeg process safely
kill_ffmpeg() {
    ffmpeg_pids=$(pidof ffmpeg || true)
    if [[ -n "$ffmpeg_pids" ]]; then
        for pid in $ffmpeg_pids; do
            log WARNING "Killing FFmpeg process with PID: $pid"
            kill "$pid" || true
            sleep 2
            if kill -0 "$pid" &>/dev/null; then
                log WARNING "FFmpeg PID $pid did not terminate. Sending SIGKILL..."
                kill -9 "$pid" || true
            fi
            wait "$pid" 2>/dev/null || true
        done
    fi
    FFMPEG_PID=""
    PLAYLIST_LOOP_COUNT=0
}

# Kill monitor_for_stall process
kill_monitor() {
    if [[ -n "${MONITOR_PID}" ]] && kill -0 "${MONITOR_PID}" &>/dev/null; then
        log WARNING "Killing Stall Monitor process with PID: ${MONITOR_PID}"
        kill "${MONITOR_PID}" || true
        sleep 1 # Give it a moment to clean up
        if kill -0 "${MONITOR_PID}" &>/dev/null; then
            log WARNING "Stall Monitor PID ${MONITOR_PID} did not terminate. Sending SIGKILL..."
            kill -9 "${MONITOR_PID}" || true
        fi
        wait "${MONITOR_PID}" 2>/dev/null || true
    fi
    MONITOR_PID=""
}

# Kill log processor process
kill_log_processor() {
    if [[ -n "${LOG_PROCESSOR_PID}" ]] && kill -0 "${LOG_PROCESSOR_PID}" &>/dev/null; then
        log WARNING "Killing Log Processor process with PID: ${LOG_PROCESSOR_PID}"
        kill "${LOG_PROCESSOR_PID}" || true
        sleep 1 # Give it a moment to clean up
        if kill -0 "${LOG_PROCESSOR_PID}" &>/dev/null; then
            log WARNING "Log Processor PID ${LOG_PROCESSOR_PID} did not terminate. Sending SIGKILL..."
            kill -9 "${LOG_PROCESSOR_PID}" || true
        fi
        wait "${LOG_PROCESSOR_PID}" 2>/dev/null || true
    fi
    LOG_PROCESSOR_PID=""
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
    local file_count=0

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
        file_count=`expr $file_count + 1`
    done < "${playlist_file}"

    # Format the duration into Dd HH:MM:SS
    if (( $(echo "${total_duration_seconds} > 0" | bc -l) )); then
        local total_seconds_int
        total_seconds_int=$(printf "%.0f" "${total_duration_seconds}")
        local days=$((total_seconds_int / 86400))
        local hours=$(((total_seconds_int % 86400) / 3600))
        local minutes=$(((total_seconds_int % 3600) / 60))
        local seconds=$((total_seconds_int % 60))
        local formatted_duration=""
        if (( days > 0 )); then formatted_duration+="${days}d "; fi
        formatted_duration+=$(printf "%02dh:%02dm:%02ds" "${hours}" "${minutes}" "${seconds}")
        log INFO "Total ${media_type} playlist duration: ${YELLOW}${formatted_duration}${NC} (${file_count} files)"
        if [[ "$media_type" == "Video" ]]; then
            VIDEO_DURATION="${formatted_duration}"
            VIDEO_FILE_COUNT=$file_count
        fi
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
            local playing_file="${BASH_REMATCH[2]}"
            if [[ "$playing_file" == "${VIDEO_DIR}"* ]]; then
                log VIDEO "Now Playing Video: $(basename "${playing_file}")"
                CURRENTLY_PLAYING_VIDEO_BASENAME="$(basename "${playing_file}")"
                if [[ "$FIRST_VIDEO_FILE" == "$CURRENTLY_PLAYING_VIDEO_BASENAME" ]]; then
                    PLAYLIST_LOOP_COUNT=`expr $PLAYLIST_LOOP_COUNT + 1`
                    log VIDEO "Playlist loop count: $PLAYLIST_LOOP_COUNT ($VIDEO_DURATION - $VIDEO_FILE_COUNT files)."
                fi
                # Signal that a new video has started playing
                touch "${NEW_VIDEO_TIMESTAMP_FILE}"
            elif [[ "${ENABLE_MUSIC}" == "true" && "$playing_file" == "${MUSIC_DIR}"* ]]; then
                log MUSIC "Now Playing Music: $(basename "${playing_file}")"
            fi
        fi
    done
}

# Start FFmpeg streaming
start_streaming() {
    if [[ ! -s "${FILTERED_VIDEO_FILE_LIST}" ]]; then
        log WARNING "No compatible video files found to stream after exclusion. Waiting for files to be added or corrected."
        return
    fi

    local -a ffmpeg_opts
    local music_enabled_and_found=false
    if [[ "${ENABLE_MUSIC}" == "true" ]] && [[ -s "${VALIDATED_MUSIC_FILE_LIST}" ]]; then
        music_enabled_and_found=true
        log INFO "Music is enabled and music files were found. Replacing video audio with validated playlist."
    fi

    # Common options
    # Set loglevel to debug to get maximum information, which should include the 'Opening file...' messages.
    ffmpeg_opts+=(-nostdin -v debug -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -fflags +genpts)

    # Input options
    # The -re flag is crucial for the video input to simulate a live stream. It should NOT be applied to the audio input.
    ffmpeg_opts+=(-re -stream_loop -1 -f concat -safe 0 -i "${FILTERED_VIDEO_FILE_LIST}") # Video input
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

    # Kill any existing log processor before starting a new one
    kill_log_processor

    # Start the log processor in the background, reading from our named pipe.
    if [[ "${ENABLE_FFMPEG_LOG_FILE}" == "true" ]]; then
        # If file logging is enabled, tee the output from the pipe to the log file and to the processor.
        <"${FFMPEG_PIPE}" tee -a "${FFMPEG_LOG_FILE}" | process_ffmpeg_output &
    else
        # Otherwise, just pipe from the named pipe to the processor.
        <"${FFMPEG_PIPE}" process_ffmpeg_output &
    fi
    LOG_PROCESSOR_PID=$! # Capture PID of the log processor

    # Start ffmpeg, redirect its output to the named pipe, and get its actual PID.
    ffmpeg "${ffmpeg_opts[@]}" >"${FFMPEG_PIPE}" 2>&1 &
    FFMPEG_PID=$!
    log INFO "FFmpeg started with PID: ${FFMPEG_PID}"
}

# Monitors the running FFmpeg process for stalls and restarts it if needed.
monitor_for_stall() {
    set +e  # Disable exit on error inside stall monitor loop
    local stall_counter=0
    local last_progress_percentage=0.0
    local last_video_start_timestamp=$(stat -c %Y "${NEW_VIDEO_TIMESTAMP_FILE}") # Initialize with current timestamp
    log INFO "Starting FFmpeg stall monitor."
    # The while loop will continue until the parent script tells it to stop.
    while true; do
        sleep "${STALL_MONITOR_INTERVAL}"

        if [[ -n "${FFMPEG_PID}" ]] && kill -0 "${FFMPEG_PID}" &>/dev/null; then
            # log INFO "[Stall Monitor] Heartbeat - loop is running."

            # Check for new video file start via timestamp file
            local current_video_start_timestamp=$(stat -c %Y "${NEW_VIDEO_TIMESTAMP_FILE}")
            if [[ "$current_video_start_timestamp" -gt "$last_video_start_timestamp" ]]; then
                # log INFO "[Stall Monitor] New video file detected. Resetting progress monitor."
                last_progress_percentage=0.0
                stall_counter=0
                last_video_start_timestamp="$current_video_start_timestamp"
                continue # Skip current progress check as new video just started
            fi

            local progress_output
            progress_output=$(progress -c ffmpeg 2>&1 || true) # Add || true to prevent set -e from exiting if progress fails

            local current_progress_percentage="" # Initialize as empty
            # Check if progress_output indicates ffmpeg is not running (e.g., "No such process" or empty output)
            if echo "$progress_output" | grep -q "No such process"; then
                # FFmpeg is not running, so reset stall counter and continue.
                # log INFO "[Stall Monitor] FFmpeg process not found. Resetting stall counter."
                stall_counter=0
                last_progress_percentage=0.0
                last_video_start_timestamp=$(stat -c %Y "${NEW_VIDEO_TIMESTAMP_FILE}") # Reset timestamp if FFmpeg is not running
                continue # Skip the rest of the loop and wait for next interval
            fi
            # log INFO "[Stall Monitor] $progress_output"

            # Extract the percentage value. Example: "0.4% (64.0 KiB / 16.3 MiB)" -> "0.4"
            current_progress_percentage=$(echo "$progress_output" | grep -oE '[0-9]+(\.[0-9]+)?%' | head -n 1 | sed 's/%//')

            # Validate that current_progress_percentage is a number before using it in bc
            if ! [[ "$current_progress_percentage" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                log WARNING "[Stall Monitor] Invalid progress percentage: '${current_progress_percentage}'. Resetting stall counter."
                stall_counter=0
                last_progress_percentage=0.0
                continue # Skip current progress check as value is invalid
			fi

            # Extract currently playing file from progress output
            local playing_file_from_progress=""
            
            if [[ "$progress_output" =~ ffmpeg\ ([^[:space:]]+) ]]; then
                playing_file_from_progress="${BASH_REMATCH[1]}"
                # Extract basename only
                CURRENTLY_PLAYING_VIDEO_BASENAME=$(basename "${playing_file_from_progress}")
                # log INFO "---- Currently playing: ${CURRENTLY_PLAYING_VIDEO_BASENAME}"
            fi


            # log INFO "[Stall Monitor] Current progress: ${current_progress_percentage}% (Last: ${last_progress_percentage}%)"

            if (( $(echo "$current_progress_percentage <= $last_progress_percentage" | bc -l) )); then
                ((stall_counter++))
                log WARNING "[Stall Monitor] FFmpeg is not playing. Counter: ${stall_counter}/${STALL_THRESHOLD}."
                log WARNING "[Stall Monitor] $progress_output"
                if (( stall_counter >= STALL_THRESHOLD )); then
                    log ERROR "FFmpeg appears to be stalled. Restarting stream..."
                    log WARNING "Last played file was: '${CURRENTLY_PLAYING_VIDEO_BASENAME}'."
                    if [[ -n "${CURRENTLY_PLAYING_VIDEO_BASENAME}" ]]; then
                        log ERROR "Adding '${CURRENTLY_PLAYING_VIDEO_BASENAME}' to exclusion list due to stall."
						echo "${CURRENTLY_PLAYING_VIDEO_BASENAME}" >> "${EXCLUDED_VIDEO_FILE_PATH}"
                    else
                        log WARNING "Could not identify currently playing file to add to exclusion list."
                    fi
                    kill_ffmpeg
                    # No need to kill monitor here, as it's the one detecting and initiating restart.
                    # It will just continue its loop, and the next start_streaming will ensure a clean state.
                    
                    # Re-generate and validate playlists after updating exclusion list
                    generate_videolist
                    validate_video_files
                    filter_excluded_files # Apply exclusion
                    generate_musiclist
                    validate_music_files
                    log_total_playlist_duration "${FILTERED_VIDEO_FILE_LIST}" "Video" # Log from the filtered list
                    [[ "${ENABLE_MUSIC}" == "true" ]] && log_total_playlist_duration "${VALIDATED_MUSIC_FILE_LIST}" "Music"
                    start_streaming
                    stall_counter=0
                    last_progress_percentage=0.0
                    last_video_start_timestamp=$(stat -c %Y "${NEW_VIDEO_TIMESTAMP_FILE}") # Reset timestamp after restart
                fi
            else
                stall_counter=0
                last_progress_percentage=$current_progress_percentage
            fi
        else
            # FFmpeg process is not running. This could be due to a crash or failure to start.
            log ERROR "[Stall Monitor] FFmpeg process with PID ${FFMPEG_PID:-not set} is not running. Attempting to restart the stream..."
            # Attempt to restart the stream. We don't need to kill ffmpeg since it's already gone.
            # We also don't re-generate playlists here, as the crash might be unrelated to a specific file.
            # If a file is truly problematic, it will likely cause a stall eventually, which has its own recovery logic.
            start_streaming
            # Reset monitor state after restart attempt.
            stall_counter=0
            last_progress_percentage=0.0
            last_video_start_timestamp=$(stat -c %Y "${NEW_VIDEO_TIMESTAMP_FILE}") # Reset timestamp after restart
        fi
    done
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
        kill_monitor # Explicitly kill the old monitor process
        kill_log_processor # Explicitly kill the old log processor process

        # Re-initialize exclusion list on file system changes as files might have been fixed or replaced.
        # This prevents permanent exclusion if a problematic file is overwritten.
        generate_videolist
        validate_video_files
        filter_excluded_files # Apply exclusion
        generate_musiclist
        CURRENTLY_PLAYING_VIDEO_BASENAME=""
        validate_music_files
        log_total_playlist_duration "${FILTERED_VIDEO_FILE_LIST}" "Video" # Log from the filtered list
        [[ "${ENABLE_MUSIC}" == "true" ]] && log_total_playlist_duration "${VALIDATED_MUSIC_FILE_LIST}" "Music"
        start_streaming
        monitor_for_stall 2>&1 & # Restart the monitor
        MONITOR_PID=$! # Capture PID of the new monitor process
    done
}

main() {
    # Trap EXIT signal to ensure cleanup runs, regardless of how the script exits.
    trap cleanup EXIT

    # Create a named pipe for reliable PID capture and log processing.
    FFMPEG_PIPE=$(mktemp -u)
    mkfifo "${FFMPEG_PIPE}"
    touch "${NEW_VIDEO_TIMESTAMP_FILE}" # Ensure the timestamp file exists initially

    check_dependencies
    check_env_vars

    # Use persistent files in the /data volume for the playlists.
    VIDEO_FILE_LIST="/data/videolist.txt"
    VALIDATED_VIDEO_FILE_LIST="/data/validated_videolist.txt"
    FILTERED_VIDEO_FILE_LIST="/data/filtered_videolist.txt"
    NEW_VIDEO_TIMESTAMP_FILE="/data/new_video_started.tmp"
    log INFO "Using videolist ./data/videolist.txt"
    log INFO "Using validated videolist ./data/validated_videolist.txt"
    log INFO "Using filtered videolist ./data/filtered_videolist.txt"

    if [[ "${ENABLE_MUSIC}" == "true" ]]; then
        MUSIC_FILE_LIST="/data/musiclist.txt"
        VALIDATED_MUSIC_FILE_LIST="/data/validated_musiclist.txt"
        log INFO "Using musiclist ./data/musiclist.txt"
    fi

    if [[ "${ENABLE_FFMPEG_LOG_FILE}" == "true" ]]; then
        FFMPEG_LOG_FILE="/data/ffmpeg.log"
        log WARNING "FFmpeg debug logs will be written to a file ./data/ffmpeg.log"
        # Overwrite the log file on start to prevent it from growing indefinitely across container restarts.
        > "${FFMPEG_LOG_FILE}"
    fi

    if [[ "${ENABLE_SCRIPT_LOG_FILE}" == "true" ]]; then
        log WARNING "Script WARNING and ERROR logs will be written to ${SCRIPT_LOG_FILE}"
        # Overwrite the log file on start to prevent it from growing indefinitely across container restarts.
        > "${SCRIPT_LOG_FILE}"
    fi
    # Initial setup
    generate_videolist
    validate_video_files
    filter_excluded_files # Apply exclusion for the initial run
    generate_musiclist
    validate_music_files
    log_total_playlist_duration "${FILTERED_VIDEO_FILE_LIST}" "Video" # Log from the filtered list
    [[ "${ENABLE_MUSIC}" == "true" ]] && log_total_playlist_duration "${VALIDATED_MUSIC_FILE_LIST}" "Music"
    
    # Start the initial stream.
    start_streaming

    # Launch the stall monitor in the background.
    monitor_for_stall 2>&1 &
    MONITOR_PID=$! # Capture PID here

    # Start the file watcher in the foreground. This will block and handle restarts on file changes.
    watch_for_changes
}

main "$@"