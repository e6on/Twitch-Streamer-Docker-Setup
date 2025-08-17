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
readonly STALL_MONITOR_INTERVAL=${STALL_MONITOR_INTERVAL:-15}
# How many times the speed must be 0/s before we declare it stalled and restart.
# (e.g., 4 * 15s = 60 seconds of zero activity before restart).
readonly STALL_THRESHOLD=${STALL_THRESHOLD:-4}

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
readonly ENABLE_SHUFFLE=${ENABLE_SHUFFLE:-"false"}
readonly ENABLE_FFMPEG_LOG_FILE=${ENABLE_FFMPEG_LOG_FILE:-"false"}
readonly MUSIC_VOLUME=${MUSIC_VOLUME:-"1.0"} # Music volume. 1.0 is 100%, 0.5 is 50%.
readonly ENABLE_SCRIPT_LOG_FILE=${ENABLE_SCRIPT_LOG_FILE:-"false"}
readonly script_log_file=${script_log_file:-"/data/script_warnings_errors.log"}

# --- Global Variables ---
video_file_list=""
music_file_list=""
validated_video_file_list=""
validated_music_file_list=""
filtered_video_file_list=""
excluded_video_file_path="/data/excluded_videos.txt"
premature_loop_signal_file="/data/premature_loop.signal"
new_video_timestamp_file="/data/new_video_started.tmp"
ffmpeg_log_file=""
ffmpeg_pid=""
ffmpeg_pipe=""
currently_playing_video_basename=""
monitor_pid=""
log_processor_pid=""
playlist_loop_count=0
FIRST_VIDEO_FILE=""
current_video_index=0
video_duration=""
video_file_count=0

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
            echo "${timestamp} [${level}] ${message}" >> "${script_log_file}"
        fi
    fi
}

# Cleanup function to be called on script exit.
cleanup() {
    log INFO "Cleaning up and exiting..."
    kill_ffmpeg
    kill_monitor
    kill_log_processor
    if [[ -n "${ffmpeg_pipe:-}" ]] && [[ -p "${ffmpeg_pipe}" ]]; then
        rm -f "${ffmpeg_pipe}"
    fi
    if [[ -n "${progress_pipe:-}" ]] && [[ -p "${progress_pipe}" ]]; then
        rm -f "${progress_pipe}"
    fi
    if [[ -f "${premature_loop_signal_file:-}" ]]; then rm -f "${premature_loop_signal_file}"; fi
    if [[ -f "${premature_loop_signal_file:-}.tmp" ]]; then rm -f "${premature_loop_signal_file}.tmp"; fi
}

# Check for required commands.
check_dependencies() {
    log INFO "Checking for required dependencies..."
    for cmd in ffmpeg ffprobe inotifywait awk; do
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

    local sort_or_shuffle_cmd
    if [[ "${media_type}" == "Video" && "${ENABLE_SHUFFLE}" == "true" ]]; then
        log INFO "Shuffle mode is enabled for videos."
        sort_or_shuffle_cmd=(shuf -z)
    else
        sort_or_shuffle_cmd=(sort -z)
    fi

    # Use find -print0 and read -d '' to robustly handle filenames with special characters.
    #{ find "${find_args[@]}" -print0 | sort -z | while IFS= read -r -d '' file; do echo "file '$file'"; done; } > "${output_file}"
    { find "${find_args[@]}" -print0 | "${sort_or_shuffle_cmd[@]}" | while IFS= read -r -d '' file; do echo "file '$file'"; done; } > "${output_file}"
    log INFO "${media_type} file list generated at ${output_file}"
}

# Wrapper function to generate the video playlist.
generate_videolist() {
    generate_playlist "${VIDEO_DIR}" "${VIDEO_FILE_TYPES}" "${video_file_list}" "Video"
}

# Wrapper function to generate the music playlist.
generate_musiclist() {
    if [[ "${ENABLE_MUSIC}" != "true" ]]; then
        return
    fi
    generate_playlist "${MUSIC_DIR}" "${MUSIC_FILE_TYPES}" "${music_file_list}" "Music"
}

# Validate music files for compatibility to prevent stream freezes.
# It checks for consistent sample rate and channel layout.
validate_music_files() {
    if [[ "${ENABLE_MUSIC}" != "true" ]]; then
        # Music is disabled, so there is nothing to validate.
        return
    fi

    if [[ ! -s "${music_file_list}" ]]; then
        # Music is enabled, but no files were found. Ensure the validated list is empty.
        > "${validated_music_file_list}"
        return
    fi

    log INFO "Validating music files for stream compatibility..."
    > "${validated_music_file_list}" # Start with a clean slate.

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
            log INFO "Music compatibility reference set by '${reference_file}', ${reference_sample_rate} Hz, ${reference_channels} ch"
            echo "$line" >> "${validated_music_file_list}"
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
            echo "$line" >> "${validated_music_file_list}"
        fi
    done < "${music_file_list}"

    if [[ ! -s "${validated_music_file_list}" ]]; then
        log WARNING "No compatible music files found after validation. Music will be disabled for this stream."
    fi
}

# Validates video files for stream compatibility.
# It checks for consistent resolution and pixel format.
# If background music is disabled, it also validates audio for consistent sample rate and channels.
validate_video_files() {
    if [[ ! -s "${video_file_list}" ]]; then
        > "${validated_video_file_list}"
        return
    fi

    log INFO "Validating video files for stream compatibility..."
    > "${validated_video_file_list}" # Start with a clean slate.

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
            local ref_log_msg="Video compatibility reference set by '${reference_file}', ${reference_width}x${reference_height}, ${reference_frame_rate} FPS, ${reference_pix_fmt}"

            if [[ "$validate_audio" == "true" ]]; then
                reference_sample_rate="${current_sample_rate}"
                reference_channels="${current_channels}"
                ref_log_msg+=", AudioSampleRate=${reference_sample_rate}, AudioChannels=${reference_channels}"
            fi
            log INFO "${ref_log_msg}"
            echo "$line" >> "${validated_video_file_list}"
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
            # Check for compatible pixel formats
            if ! { [[ "${reference_pix_fmt}" == "yuv420p" && "${current_pix_fmt}" == "yuvj420p" ]] || [[ "${reference_pix_fmt}" == "yuvj420p" && "${current_pix_fmt}" == "yuv420p" ]]; }; then
                log WARNING "Skipping video '$(basename "${current_file}")' due to mismatched pixel format. Expected: ${reference_pix_fmt}, Found: ${current_pix_fmt}."
                is_compatible=false
            fi
        fi
        # Frame rate check: allow if one frame rate is an integer multiple of the other (e.g., 30/60, 60/30, 24/48).
        if [[ "${current_frame_rate}" != "${reference_frame_rate}" ]]; then
            local ref_num ref_den cur_num cur_den
            IFS='/' read -r ref_num ref_den <<< "${reference_frame_rate}"
            ref_den=${ref_den:-1} # Default denominator to 1 if not specified (e.g. 30 instead of 30/1)
            IFS='/' read -r cur_num cur_den <<< "${current_frame_rate}"
            cur_den=${cur_den:-1} # Default denominator to 1
            
            # Use shell arithmetic to check for zero values to avoid division by zero in awk.
            if (( cur_den * ref_num == 0 || ref_den * cur_num == 0 )); then
                log WARNING "Skipping video '$(basename "${current_file}")' due to zero value in frame rate calculation. Ref: ${reference_frame_rate}, Current: ${current_frame_rate}."
                is_compatible=false
            else
                # Use a single awk command for efficient floating-point math.
                # This is much faster than forking 'bc' multiple times for every file.
                # This script is POSIX-compliant to work with any awk version (e.g., mawk, busybox awk).
                if awk -v ref_num="${ref_num}" -v ref_den="${ref_den}" -v cur_num="${cur_num}" -v cur_den="${cur_den}" 'BEGIN {
                        # Check for division by zero.
                        if ( (cur_den * ref_num) == 0 || (ref_den * cur_num) == 0 ) {
                            exit 1;
                        }
                        # Calculate both ratios.
                        ratio1 = (cur_num * ref_den) / (cur_den * ref_num);
                        ratio2 = (ref_num * cur_den) / (ref_den * cur_num);
                        # Check if either ratio is a multiple (>=1 and close to an integer).
                        is_multiple = 0;
                        diff1 = ratio1 - sprintf("%.0f", ratio1);
                        if (ratio1 >= 0.99 && (diff1 * diff1) < 0.0001) {
                            is_multiple = 1;
                        }
                        if (is_multiple == 0) {
                            diff2 = ratio2 - sprintf("%.0f", ratio2);
                            if (ratio2 >= 0.99 && (diff2 * diff2) < 0.0001) {
                                is_multiple = 1;
                            }
                        }
                        if (is_multiple == 1) { exit 0; } else { exit 1; }
                    }'; then
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
            echo "$line" >> "${validated_video_file_list}"
        fi
    done < "${video_file_list}"

    if [[ ! -s "${validated_video_file_list}" ]]; then
        log WARNING "No videos with compatible properties found after validation. The stream will not start."
    fi
}

# Filters the validated video list based on EXCLUDED_VIDEO_FILES
filter_excluded_files() {
    local input_list="${validated_video_file_list}"
    local output_list="${filtered_video_file_list}"

    log INFO "Filtering excluded video files from ${input_list} to ${output_list}..."
    > "${output_list}" # Start with a clean slate.

    # Initialize EXCLUDED_VIDEO_FILES as an empty array
    local -a EXCLUDED_VIDEO_FILES=()

    if [[ -f "${excluded_video_file_path}" ]]; then
        mapfile -t EXCLUDED_VIDEO_FILES < "${excluded_video_file_path}"
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
    ffmpeg_pid=""
}

# Kill monitor_for_stall process
kill_monitor() {
    if [[ -n "${monitor_pid}" ]] && kill -0 "${monitor_pid}" &>/dev/null; then
        log WARNING "Killing Stall Monitor process with PID: ${monitor_pid}"
        kill "${monitor_pid}" || true
        sleep 1 # Give it a moment to clean up
        if kill -0 "${monitor_pid}" &>/dev/null; then
            log WARNING "Stall Monitor PID ${monitor_pid} did not terminate. Sending SIGKILL..."
            kill -9 "${monitor_pid}" || true
        fi
        wait "${monitor_pid}" 2>/dev/null || true
    fi
    monitor_pid=""
}

# Kill log processor process
kill_log_processor() {
    if [[ -n "${log_processor_pid}" ]] && kill -0 "${log_processor_pid}" &>/dev/null; then
        log WARNING "Killing Log Processor process with PID: ${log_processor_pid}"
        kill "${log_processor_pid}" || true
        sleep 1 # Give it a moment to clean up
        if kill -0 "${log_processor_pid}" &>/dev/null; then
            log WARNING "Log Processor PID ${log_processor_pid} did not terminate. Sending SIGKILL..."
            kill -9 "${log_processor_pid}" || true
        fi
        wait "${log_processor_pid}" 2>/dev/null || true
    fi
    log_processor_pid=""
}

# Rebuilds all playlists from source files, including validation and filtering.
rebuild_playlists() {
    log INFO "Rebuilding and validating all playlists..."
    generate_videolist
    validate_video_files
    filter_excluded_files
    generate_musiclist
    validate_music_files
    log_total_playlist_duration "${filtered_video_file_list}" "Video"
    [[ "${ENABLE_MUSIC}" == "true" ]] && log_total_playlist_duration "${validated_music_file_list}" "Music"
}

# Handles stream restarts to reduce code duplication.
# Arguments:
#   $1: The type of restart.
#       "hard": Kills ffmpeg, rebuilds playlists, and restarts. Used for stalls or file changes.
#       "soft": Kills and restarts ffmpeg with existing playlists. Used for clean exits or unexpected crashes.
#   $2 (optional): The basename of a file to exclude if the restart is due to a stall.
restart_stream() {
    local restart_type="$1"
    local file_to_exclude="${2:-}"

    log WARNING "Restarting stream (type: ${restart_type})..."

    # Always kill the old processes
    kill_ffmpeg
    kill_log_processor

    if [[ -n "$file_to_exclude" ]]; then
        log WARNING "Adding '${file_to_exclude}' to exclusion list."
        echo "${file_to_exclude}" >> "${excluded_video_file_path}"
    fi

    if [[ "$restart_type" == "hard" ]]; then
        # A hard restart involves re-reading the file system.
        rebuild_playlists
    fi

    # Reset counters and start the new stream.
    # These are reset for both hard and soft restarts to ensure the count is accurate.
    playlist_loop_count=0
    current_video_index=0
    start_streaming
}


# Calculates and logs the total duration of a playlist.
# Arguments:
#   $1: Path to the validated playlist file.
#   $2: Media type for logging (e.g., "Video", "Music").
log_total_playlist_duration() {
    local playlist_file="$1"
    local media_type="$2"
    local total_duration_seconds="0.0"
    local file_count=0
 
    if [[ ! -s "${playlist_file}" ]]; then return; fi

    log INFO "Calculating total ${media_type} playlist duration..."
    file_count=$(grep -c ^file "${playlist_file}")

    # Use a subshell and pipe to awk for efficient summation, avoiding multiple 'bc' calls.
    total_duration_seconds=$( (
        while IFS= read -r line; do
            if ! [[ "$line" =~ ^file\ \'(.*)\'$ ]]; then continue; fi
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
            echo "${duration}"
        done < "${playlist_file}"
    ) | awk '{s+=$1} END {if (s) print s; else print 0}' )

    # awk will output 0 if there's no input or the sum is zero.

    # Format the duration into Dd HH:MM:SS
    # Use awk for floating point comparison.
    if awk -v dur="${total_duration_seconds}" 'BEGIN {exit !(dur > 0)}'; then
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
            video_duration="${formatted_duration}"
            video_file_count=$file_count
        fi
    fi
}

# Process FFmpeg's stderr to log currently playing files.
process_ffmpeg_output() {
    local previous_video_basename=""
    # This function reads from FFmpeg's stderr line by line.
    while IFS= read -r line; do
        # Check if the line indicates a new file is being opened. FFmpeg logs this differently
        # depending on the context, so we check for both `concat` and `AVFormatContext`.
        # Example 1: [concat @ 0x...] Opening '/videos/video1.mp4' for reading
        # Example 2: [AVFormatContext @ 0x...] Opening '/videos/video1.mp4' for reading
        if [[ "$line" =~ \[(concat|AVFormatContext).*\]\ Opening\ \'(.+)\'\ for\ reading ]]; then
            local playing_file="${BASH_REMATCH[2]}"
            if [[ "$playing_file" == "${VIDEO_DIR}"* ]]; then
                currently_playing_video_basename="$(basename "${playing_file}")"
                if [[ "$FIRST_VIDEO_FILE" == "$currently_playing_video_basename" ]]; then
                    # A loop has occurred. Check if the previous loop completed fully.
                    # We check playlist_loop_count > 0 to avoid a false positive on the very first video.
                    if [[ "$playlist_loop_count" -gt 0 && "$current_video_index" -lt "$video_file_count" ]]; then
                        log ERROR "Premature playlist loop detected after '${previous_video_basename}'. The file is likely corrupt."
                        # Signal the monitor to restart and exclude the problematic file.
                        # Use a temp file and rename for an atomic operation to avoid race conditions with the monitor.
                        echo "${previous_video_basename}" > "${premature_loop_signal_file}.tmp" && mv "${premature_loop_signal_file}.tmp" "${premature_loop_signal_file}"
                    fi

                    let "playlist_loop_count+=1"
                    current_video_index=1 # Reset for new loop
                    log VIDEO "Playlist loop $playlist_loop_count ($video_duration - $video_file_count files)."

                else
                    let "current_video_index+=1"
                fi
				log VIDEO "Now Playing $playlist_loop_count [$current_video_index/$video_file_count]: $(basename "${playing_file}")"
                # Signal that a new video has started playing
                touch "${new_video_timestamp_file}"
                # Store the current video as the "previous" one for the next iteration.
                previous_video_basename="${currently_playing_video_basename}"
            elif [[ "${ENABLE_MUSIC}" == "true" && "$playing_file" == "${MUSIC_DIR}"* ]]; then
                log MUSIC "Now Playing: $(basename "${playing_file}")"
            fi
        fi
    done
}

# Start FFmpeg streaming
start_streaming() {
    if [[ ! -s "${filtered_video_file_list}" ]]; then
        log WARNING "No compatible video files found to stream after exclusion. Waiting for files to be added or corrected."
        return
    fi

    local -a ffmpeg_opts
    local music_enabled_and_found=false
    if [[ "${ENABLE_MUSIC}" == "true" ]] && [[ -s "${validated_music_file_list}" ]]; then
        music_enabled_and_found=true
        log INFO "Music is enabled and music files were found. Replacing video audio with validated playlist."
    fi

    # Common options
    # Set loglevel to debug to get maximum information, which should include the 'Opening file...' messages.
    ffmpeg_opts+=(-nostdin -v debug -hwaccel vaapi -vaapi_device /dev/dri/renderD128 -fflags +genpts)
    ffmpeg_opts+=(-progress "${progress_pipe}")

    # Input options
    # The -re flag is crucial for the video input to simulate a live stream. It should NOT be applied to the audio input.
    ffmpeg_opts+=(-re -stream_loop -1 -f concat -safe 0 -i "${filtered_video_file_list}") # Video input
    if [[ "$music_enabled_and_found" == "true" ]]; then
        ffmpeg_opts+=(-stream_loop -1 -f concat -safe 0 -i "${validated_music_file_list}") # Music input
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
        <"${ffmpeg_pipe}" tee -a "${ffmpeg_log_file}" | process_ffmpeg_output &
    else
        # Otherwise, just pipe from the named pipe to the processor.
        <"${ffmpeg_pipe}" process_ffmpeg_output &
    fi
    log_processor_pid=$! # Capture PID of the log processor

    # Start ffmpeg, redirect its output to the named pipe, and get its actual PID.
    ffmpeg "${ffmpeg_opts[@]}" >"${ffmpeg_pipe}" 2>&1 &
    ffmpeg_pid=$!
    log INFO "FFmpeg started with PID: ${ffmpeg_pid}"
}

# Monitors the running FFmpeg process for stalls and restarts it if needed.
monitor_for_stall() {
    set +e  # Disable exit on error inside stall monitor loop
    local stall_counter=0
    local last_video_start_timestamp=$(stat -c %Y "${new_video_timestamp_file}")
    
    log INFO "Starting FFmpeg stall monitor. Reading from ${progress_pipe}"
    
    # We will loop continuously and read from the progress pipe.
    # `read -r -t` is used to implement a timeout.
    while true; do
        # Check for a premature loop signal, which indicates a corrupt file.
        if [[ -f "${premature_loop_signal_file}" ]]; then
            local bad_file
            bad_file=$(<"${premature_loop_signal_file}")
            log ERROR "[Stall Monitor] Premature loop signal detected. Excluding '${bad_file}' and restarting."
            rm -f "${premature_loop_signal_file}"
            restart_stream "hard" "${bad_file}"
            continue # Restart the monitor's loop
        fi

        local key_value_pair="" read_status
        read -r -t "${STALL_MONITOR_INTERVAL}" key_value_pair < "${progress_pipe}"
        read_status=$?

        if [[ ${read_status} -eq 0 ]]; then
            # Read was successful, continue processing.
            : # No-op, fall through to the processing logic below.
        elif [[ ${read_status} -gt 128 ]]; then
            # A timeout occurred, which is the primary indicator of a stall.
            log WARNING "[Stall Monitor] No progress update received for ${STALL_MONITOR_INTERVAL}s. Checking FFmpeg status..."
            if [[ -n "${ffmpeg_pid}" ]] && kill -0 "${ffmpeg_pid}" &>/dev/null; then
                # The process is still alive but not making progress. This is a stall.
                let "stall_counter+=1"
                log WARNING "[Stall Monitor] FFmpeg is still running but silent. Counter: ${stall_counter}/${STALL_THRESHOLD}."
                if (( stall_counter >= STALL_THRESHOLD )); then
                    log ERROR "FFmpeg appears to be stalled (silent). Restarting stream..."
                    restart_stream "hard" # No specific file to exclude, but still a hard restart.
                    stall_counter=0
                    last_video_start_timestamp=$(stat -c %Y "${new_video_timestamp_file}")
                fi
            else
                # The process has died unexpectedly.
                log ERROR "[Stall Monitor] FFmpeg process is not running. Attempting to restart the stream..."
                restart_stream "soft" # Soft restart as the cause is unknown.
                stall_counter=0
                last_video_start_timestamp=$(stat -c %Y "${new_video_timestamp_file}")
            fi
            continue # Skip the regular progress processing below.
        else
            # An exit code of 1 means EOF (pipe closed by the writer). Other non-zero codes are errors.
            log ERROR "[Stall Monitor] Progress pipe read failed (status: ${read_status}). This likely means FFmpeg exited. Exiting monitor."
            break # Exit the monitor loop.
        fi

        # Reset stall counter on any progress update
        stall_counter=0

        # Check for new video file start via timestamp file
        local current_video_start_timestamp=$(stat -c %Y "${new_video_timestamp_file}")
        if [[ "$current_video_start_timestamp" -gt "$last_video_start_timestamp" ]]; then
            #log INFO "[Stall Monitor] New video file detected. Resetting monitor state."
            last_video_start_timestamp="$current_video_start_timestamp"
            continue # Skip the rest of the current loop as state has been reset
        fi

        # Process the key-value pair
        case "${key_value_pair}" in
            speed=*)
                local current_speed="${key_value_pair#speed=}"
                #log INFO "[Stall Monitor] Current speed: ${current_speed}"
                # A speed of '0x' indicates a stall.
                if [[ "${current_speed}" == "0.00x" || "${current_speed}" == "0x" ]]; then
                    let "stall_counter+=1"
                    log WARNING "[Stall Monitor] FFmpeg speed is 0x. Counter: ${stall_counter}/${STALL_THRESHOLD}."
                    if (( stall_counter >= STALL_THRESHOLD )); then
                        log ERROR "FFmpeg appears to be stalled (speed 0x). Restarting stream..."
                        restart_stream "hard" "${currently_playing_video_basename}"
                        stall_counter=0
                        last_video_start_timestamp=$(stat -c %Y "${new_video_timestamp_file}")
                    fi
                fi
                ;;
            progress=end)
                # FFmpeg finished cleanly (e.g., if stream_loop was not -1). Do a soft restart.
                log WARNING "[Stall Monitor] FFmpeg progress ended. Restarting stream..."
                restart_stream "soft"
                stall_counter=0
                last_video_start_timestamp=$(stat -c %Y "${new_video_timestamp_file}")
                ;;
            # No other specific case needed for this implementation, as the timeout handles general stalls.
        esac
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
        kill_monitor # Explicitly kill the old monitor process
        # A "hard" restart handles killing ffmpeg/log_processor, rebuilding playlists, and starting the stream.
        restart_stream "hard"
        currently_playing_video_basename=""
        monitor_for_stall & # Restart the monitor
        monitor_pid=$! # Capture PID of the new monitor process
    done
}

main() {
    # Trap EXIT, SIGINT (Ctrl+C), and SIGTERM (graceful kill).
    trap cleanup EXIT SIGINT SIGTERM

    # Create a named pipe for reliable PID capture and log processing.
    ffmpeg_pipe=$(mktemp -u)
    mkfifo "${ffmpeg_pipe}"

    # Create a named pipe for FFmpeg's progress output.
    progress_pipe=$(mktemp -u)
    mkfifo "${progress_pipe}"

    touch "${new_video_timestamp_file}" # Ensure the timestamp file exists initially
    rm -f "${premature_loop_signal_file}" # Ensure no stale signal file exists on start
    rm -f "${premature_loop_signal_file}.tmp" # Ensure no stale temp signal file exists on start

    check_dependencies
    check_env_vars

    # Use persistent files in the /data volume for the playlists.
    video_file_list="/data/videolist.txt"
    validated_video_file_list="/data/validated_videolist.txt"
    filtered_video_file_list="/data/filtered_videolist.txt"
    new_video_timestamp_file="/data/new_video_started.tmp"
    log INFO "Using videolist ./data/videolist.txt"
    log INFO "Using validated videolist ./data/validated_videolist.txt"
    log INFO "Using filtered videolist ./data/filtered_videolist.txt"

    if [[ "${ENABLE_MUSIC}" == "true" ]]; then
        music_file_list="/data/musiclist.txt"
        validated_music_file_list="/data/validated_musiclist.txt"
        log INFO "Using musiclist ./data/musiclist.txt"
    fi

    if [[ "${ENABLE_FFMPEG_LOG_FILE}" == "true" ]]; then
        ffmpeg_log_file="/data/ffmpeg.log"
        log WARNING "FFmpeg debug logs will be written to a file ./data/ffmpeg.log"
        # Overwrite the log file on start to prevent it from growing indefinitely across container restarts.
        > "${ffmpeg_log_file}"
    fi

    if [[ "${ENABLE_SCRIPT_LOG_FILE}" == "true" ]]; then
        log WARNING "Script WARNING and ERROR logs will be written to ${script_log_file}"
        # Overwrite the log file on start to prevent it from growing indefinitely across container restarts.
        > "${script_log_file}"
    fi
    # Initial setup
    rebuild_playlists
    
    # Start the initial stream.
    start_streaming

    # Launch the stall monitor in the background.
    monitor_for_stall 2>&1 &
    monitor_pid=$! # Capture PID here

    # Start the file watcher in the foreground. This will block and handle restarts on file changes.
    watch_for_changes
}

main "$@"