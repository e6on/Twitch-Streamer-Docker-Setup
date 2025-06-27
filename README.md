# Twitch Streamer Docker Setup

This project provides a Docker-based solution for streaming a playlist of video files to Twitch using FFmpeg with hardware acceleration.

π§± Base Image

Uses the latest official Ubuntu image as the base, providing a familiar and stable Linux environment.

βοΈ Shell and Environment Setup

Sets the shell to Bash with -e to exit on errors.
Disables interactive prompts during package installation.
Sets the timezone to Tallinn, Estonia.

π¦ System Dependencies Installation

Installs essential packages:
ca-certificates, xz-utils: for secure downloads and archive handling.
libdrm*, libva*, vainfo: for hardware-accelerated video encoding (VAAPI).
tzdata: for timezone configuration.
inotify-tools: for directory monitoring (used by the script).
Cleans up APT cache to reduce image size.

π Timezone Configuration

Ensures the container uses the correct local time (important for logging and scheduling).

ποΈ FFmpeg Installation

Copies a precompiled FFmpeg binary archive into the container.
Extracts it to /usr/local, making ffmpeg available system-wide.
Avoids building FFmpeg from source, saving time and complexity.

π Script Integration

Adds your streaming script to the container.
Makes it executable.

π Entrypoint

Sets the script as the default command when the container starts.

β Summary of Features

Hardware Acceleration - Supports VAAPI for efficient video encoding.
Timezone Awareness - Uses Europe/Tallinn for accurate timestamps.
Directory Monitoring - Uses inotify-tools to detect file changes.
Prebuilt FFmpeg - Uses a precompiled FFmpeg binary for simplicity and speed.
Minimal Image Size - Cleans up APT cache and avoids unnecessary packages.
Self-contained - Everything needed to stream to Twitch is bundled in the image.


## Γ°ΕΈβΒ¦ Files Included

- `Dockerfile`: Builds the container with FFmpeg and required tools.
- `twitch_streamer.sh`: Bash script to stream videos and monitor directory changes.
- `docker-compose.yml`: Defines the container setup and environment.
- `ffmpeg-6.1.2-linux-amd64.tar.xz`: Precompiled FFmpeg binary from https://github.com/AkashiSN/ffmpeg-docker

π¬ `twitch_streamer.sh`
This script automates the process of streaming a looped playlist of video files to Twitch using FFmpeg. It monitors a directory for changes and restarts the stream if new files are added or removed.

π§ Core Features
1. Environment Variable Validation
Checks for the presence of two required environment variables:
VIDEO_DIR: Directory containing video files (.mp4, .mkv)
TWITCH_STREAM_KEY: Your Twitch stream key
If either is missing, the script exits with an error.
2. Color-Coded Logging
Uses ANSI color codes for clear, readable log messages:
β Green for INFO
β οΈ Yellow for WARNING
β Red for ERROR
3. Dynamic Playlist Generation
Scans the VIDEO_DIR for video files.
Creates a filelist.txt formatted for FFmpeg's concat demuxer.
Ensures the playlist is sorted and updated before streaming.
4. Robust FFmpeg Streaming Loop
Streams the playlist to Twitch using hardware-accelerated encoding (vaapi).
Automatically restarts FFmpeg if it crashes or disconnects (e.g., due to Twitch timeouts).
Includes a 10-second delay before retrying to avoid rapid failure loops.
5. Directory Watcher
Uses inotifywait to monitor the video directory for changes:
File creation, deletion, or movement
On change, it:
Kills the current FFmpeg process
Regenerates the playlist
Restarts the stream
6. Graceful Process Management
Ensures FFmpeg is properly terminated before restarting.
Prevents zombie processes and ensures clean restarts.
π�οΈ Manual Usage
VIDEO_DIR="/path/to/videos" TWITCH_STREAM_KEY="your_stream_key" ./twitch_streamer.sh
Make sure the script is executable:
chmod +x twitch_streamer.sh

