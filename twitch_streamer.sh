#!/bin/bash

# Define color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    case "$level" in
        INFO) echo -e "${GREEN}${timestamp} [INFO] $message${NC}" ;;
        WARNING) echo -e "${YELLOW}${timestamp} [WARNING] $message${NC}" ;;
        ERROR) echo -e "${RED}${timestamp} [ERROR] $message${NC}" ;;
        *) echo -e "${timestamp} [UNKNOWN] $message" ;;
    esac
}

# Check required environment variables
if [[ -z "${VIDEO_DIR}" || -z "${TWITCH_STREAM_KEY}" ]]; then
    log ERROR "Required environment variables not set."
    exit 1
fi

# Generate file list
generate_filelist() {
    log INFO "Generating filelist.txt..."
    > filelist.txt
    find "${VIDEO_DIR}" -type f \( -iname '*.mp4' -o -iname '*.mkv' \) | sort | while read -r file; do
        echo "file '$file'" >> filelist.txt
    done
}

# Start steaming to Twitch
start_streaming() {
    generate_filelist

    # Check that the file list is not empty
    if [[ ! -s filelist.txt ]]; then
        log WARNING "No video files found. Waiting for files..."
        return
    fi

    # Looped FFmpeg. Automatically restarts if the stream fails or times out.
    while true; do
        log INFO "Starting FFmpeg streaming..."
        ffmpeg -re -stream_loop -1 -nostdin -hwaccel vaapi -vaapi_device /dev/dri/renderD128 \
            -fflags +genpts -f concat -safe 0 -i filelist.txt \
            -map 0:v:0 -map 0:a:0 -flags +global_header -c:a aac \
            -minrate 1800k -maxrate 1800k -bufsize 1800k -g 50 -keyint_min 50 \
            -b:a 64k -ar 44100 -vf 'format=nv12,hwupload,scale_vaapi=w=960:h=540' \
            -c:v h264_vaapi -r 25 -b:v 1800k -f flv "rtmp://live.twitch.tv/app/${TWITCH_STREAM_KEY}" &

        FFMPEG_PID=$!
        wait $FFMPEG_PID

        log WARNING "FFmpeg exited unexpectedly. Retrying in 10 seconds..."
        sleep 10
    done
}

# Watches the folder for changes (new files, deletions, moves).
watch_directory() {
    log INFO "Watching for changes in ${VIDEO_DIR}..."
    inotifywait -m -e create -e delete -e moved_to -e moved_from "${VIDEO_DIR}" |
    while read -r _; do
        log INFO "Change detected. Restarting stream..."
        kill $FFMPEG_PID 2>/dev/null
        wait $FFMPEG_PID 2>/dev/null
        start_streaming
    done
}

# Initial start
start_streaming &
watch_directory
