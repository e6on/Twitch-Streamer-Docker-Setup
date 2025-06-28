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
    log INFO "Generating /data/filelist.txt..."
    > /data/filelist.txt
    find "${VIDEO_DIR}" -type f \( -iname '*.mp4' -o -iname '*.mkv' \) | sort | while read -r file; do
        echo "file '$file'" >> /data/filelist.txt
    done
}

# Kill FFmpeg process safely
kill_ffmpeg() {
    if [[ -n "$FFMPEG_PID" ]] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log INFO "Killing FFmpeg process $FFMPEG_PID..."
        kill "$FFMPEG_PID"
        wait "$FFMPEG_PID" 2>/dev/null
    fi
}

# Start FFmpeg streaming
start_streaming() {
    if [[ ! -s /data/filelist.txt ]]; then
        log WARNING "No video files found. Waiting for files..."
        return
    fi

    log INFO "Starting FFmpeg streaming..."
    ffmpeg -re -stream_loop -1 -nostdin -hwaccel vaapi -vaapi_device /dev/dri/renderD128 \
        -fflags +genpts -f concat -safe 0 -i /data/filelist.txt \
        -map 0:v:0 -map 0:a:0 -flags +global_header -c:a aac \
        -minrate 1800k -maxrate 1800k -bufsize 1800k -g 50 -keyint_min 50 \
        -b:a 64k -ar 44100 -vf 'format=nv12,hwupload,scale_vaapi=w=960:h=540' \
        -c:v h264_vaapi -r 25 -b:v 1800k -f flv "rtmp://live.twitch.tv/app/${TWITCH_STREAM_KEY}" &
    FFMPEG_PID=$!
}

# Watch for changes and signal restart
watch_for_changes() {
    inotifywait -mq -e create -e delete -e moved_to -e moved_from "${VIDEO_DIR}" |
    while read -r _; do
        log INFO "Change detected in ${VIDEO_DIR}. Restarting stream..."
        kill_ffmpeg
        generate_filelist
        start_streaming
    done
}

# Initial setup
generate_filelist
start_streaming
watch_for_changes
