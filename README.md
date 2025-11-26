# Twitch Streamer Docker Setup

A simple, efficient, and Docker-based solution for streaming a playlist of video files 24/7 to Twitch using FFmpeg with Intel Quick Sync Video (QSV) hardware acceleration via VA-API (or a compatible AMD GPU). This setup is ideal for low-power systems like UGREEN NASync DXP4800 with an Intel N100 Quad-core CPU.

## Features

-   **24/7 Streaming:** Automatically finds and streams all videos in a directory, looping them continuously.
-   **Hardware Accelerated:** Utilizes Intel QSV (VA-API) for efficient video encoding, keeping CPU usage low.
-   **Dynamic Playlist:** Automatically detects new, deleted, or moved videos and restarts the stream to update the playlist.
-   **Stall Detection & Auto-Recovery:** Automatically detects if the stream has frozen (e.g., due to a corrupted video file) and restarts FFmpeg to keep the stream online.
-   **Problematic File Exclusion:** When a stall is detected, the problematic video is automatically added to an exclusion list (`./data/excluded_videos.txt`) to prevent it from disrupting the stream again.
-   **Dockerized:** Easy to set up and run on any Linux system with Docker and a supported Intel GPU.
-   **Media Validation:** Automatically validates video and audio tracks to prevent stream freezes from incompatible formats.
-   **Highly Customizable:** Easily change stream resolution, framerate, bitrates, and ingest server via environment variables.
-   **Persistent Playlist:** The generated playlist is stored in the `./data` volume for easy inspection.
-   **Shuffle Modes:** Supports shuffling the video playlist on startup and optionally reshuffling every time the playlist loops.
-   **Optional Background Music:** Replace the original video audio with a separate, continuously looping playlist of your own music.

You can use ready made Docker image from here https://hub.docker.com/r/e6on/twitch-streamer or make your own.
Follow me on Twitch https://www.twitch.tv/egon_p.

## Prerequisites

Before you begin, ensure you have the following installed and configured on your host system:

-   Docker & Docker Compose
-   Download [FFmpeg - ffmpeg-6.1.2-linux-amd64.tar.xz](https://github.com/AkashiSN/ffmpeg-docker/releases) pre-built binary files.
-   A Twitch account and your **Stream Key**
-   **For Hardware Acceleration (Recommended):** A modern Intel CPU with Quick Sync Video support or a compatible AMD GPU.
-   **VA-API Drivers (for Intel or AMD):**
    -   **For Intel GPUs:** Install `intel-media-driver` for modern GPUs (Broadwell+).
        -   On Debian/Ubuntu: `sudo apt-get install intel-media-va-driver-non-free`
        -   On Arch Linux: `sudo pacman -S intel-media-driver`
    -   **For AMD GPUs:** Install the open-source Mesa VA-API drivers.
        -   On Debian/Ubuntu: `sudo apt-get install mesa-va-drivers`
        -   On Arch Linux: `sudo pacman -S libva-mesa-driver`
-   **Verification Tool (Optional but Recommended):**
    -   Install `vainfo` to check if VA-API is configured correctly.
    -   On Debian/Ubuntu: `sudo apt-get install vainfo`
    -   On Arch Linux: `sudo pacman -S libva-utils`

> **Note:** The GPU and driver requirements are optional if you plan to use software (CPU) encoding. See the configuration section for details.

## Setup

Follow these steps to get your stream up and running.

### 1. Clone the Repository

```bash
git clone https://github.com/Egon-p/Twitch-Streamer-Docker-Setup.git
cd Twitch-Streamer-Docker-Setup
```

### 2. Download FFmpeg

This project uses a pre-built static binary of FFmpeg to ensure compatibility. The `Dockerfile` expects this file to be present in the project's root directory.

Download `ffmpeg-6.1.2-linux-amd64.tar.xz` from this [release page](https://github.com/AkashiSN/ffmpeg-docker/releases) and place the `.tar.xz` file in the same directory as the `Dockerfile`.

### 3. Configure GPU Access for Docker

> **Note:** This step is only required for hardware acceleration (`ENABLE_HW_ACCEL=true`). If you are using CPU encoding, you can skip this and remove the `devices` and `group_add` sections from `docker-compose.yaml`.

The container needs access to your host's GPU for hardware acceleration. This is done by passing device files and matching user group IDs.

First, find the Group IDs (GIDs) for the `render` and `video` groups on your host system:

```bash
getent group render | cut -d: -f3
getent group video | cut -d: -f3
```

Take note of the numbers you get. Now, open the `docker-compose.yaml` file and update the `group_add` section with your GIDs.

```yaml
# docker-compose.yaml
services:
  twitch-streamer:
    # ... other settings
    group_add:
      - "GID_FROM_RENDER_COMMAND" # e.g., "105"
      - "GID_FROM_VIDEO_COMMAND"  # e.g., "44"
```

### 4. Configure Your Stream Key

Create a `.env` file in the project root to store your Twitch Stream Key. This file is ignored by Git, so your key will remain private.

```dotenv
# .env
TWITCH_STREAM_KEY=your_stream_key_here
```

### 5. Add Your Videos

Place all the video files you want to stream into the `videos/` directory. By default, the script finds all `.mp4`, `.mkv`, and `.mpg` files. You can customize the supported file types via the `VIDEO_FILE_TYPES` environment variable (see the Configuration section). The playlist is automatically regenerated and updated whenever you add, remove, or move videos in this directory.

### 6. (Optional) Add Background Music

If you want to replace the original audio from your videos with a custom background music track, you can use the music feature.

1.  Create a `music/` directory in the project root.
2.  Place your audio files (e.g., `.mp3`, `.flac`, `.wav`) into the `music/` directory. The music will loop continuously.
3.  Enable the feature in `docker-compose.yaml` by uncommenting the music-related environment variables.

## Usage

Once you have completed the setup, you can start the stream with a single command:

```bash
docker-compose up -d
```

You can view the logs (including FFmpeg's output) to monitor the stream:

```bash
docker-compose logs -f
```

To stop the stream:

```bash
docker-compose down
```

## Configuration

You can customize the stream's quality and destination by editing the environment section in the `docker-compose.yaml` file.

### Hardware Acceleration vs. CPU Encoding

By default, this setup uses VA-API hardware acceleration. You can switch to software (CPU) encoding if you don't have a compatible GPU or for troubleshooting. This is controlled by the `ENABLE_HW_ACCEL` variable.

```yaml
# docker-compose.yaml
# --- Hardware Acceleration ---
# Set to "false" to disable hardware acceleration and use CPU (software) encoding.
# This is useful for systems without a compatible Intel/AMD GPU.
# When disabled, the 'devices' and 'group_add' sections are not needed.
- ENABLE_HW_ACCEL=true

# --- Optional CPU Encoding Settings ---
# When ENABLE_HW_ACCEL is "false", you can tune the CPU usage vs. quality with the libx264 preset.
# Options: ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow
# 'veryfast' is a good balance for streaming.
# - CPU_PRESET=veryfast
```

When `ENABLE_HW_ACCEL` is set to `false`, the GPU-related prerequisites and setup steps are no longer required.

### Stream Quality

Uncomment and modify these variables to change the output stream quality. The defaults are set for a stable 960x540 @ 25fps stream.

```yaml
# docker-compose.yaml
# --- Optional Stream Quality Settings ---
# Uncomment and adjust these to change stream quality.
- STREAM_RESOLUTION=1280x720 # e.g., 720p
- STREAM_FRAMERATE=30
- VIDEO_BITRATE=3000k # Recommended: 3000k for 720p30, 4500k for 720p60
- AUDIO_BITRATE=160k # Recommended: 128k or 160k for good quality
```
### File Types

You can control which video file types are included in the stream by setting the `VIDEO_FILE_TYPES` environment variable in `docker-compose.yaml`. Provide a space-separated list of extensions.

```yaml
# docker-compose.yaml
- VIDEO_FILE_TYPES="mp4 mkv mpg mov" # Space-separated list of file extensions
```
### Shuffle Modes

Control the order of your video playlist with shuffle options. This is useful for creating a less predictable viewing experience, especially for 24/7 streams.

```yaml
# docker-compose.yaml
# --- Enable Video Shuffle Mode ---
- ENABLE_SHUFFLE=true
- RESHUFFLE_ON_LOOP=true
```

-   `ENABLE_SHUFFLE`:
    -   `true`: Randomizes the order of videos in your playlist when the stream first starts. The playlist is also re-shuffled automatically whenever you add, remove, or rename files in the videos directory.
    -   `false` (default): Videos are played in alphanumeric order.

-   `RESHUFFLE_ON_LOOP`:
    -   `true`: After the entire playlist has been played through once, it will be re-shuffled into a new random order for the next loop. This ensures the viewing experience remains fresh over long periods.
    -   Note: This setting only has an effect if ENABLE_SHUFFLE is also set to true.
    -   `false` (default): The shuffled playlist will loop with the same order until the stream is restarted (e.g., by a file change).

### Background Music

To enable the background music feature, uncomment the following lines in `docker-compose.yaml`. This will instruct the script to find all audio files in the `./music` directory and loop them over your video stream, replacing the original audio.

```yaml
# docker-compose.yaml
# --- Optional Background Music ---
# Uncomment to enable a separate, continuously looping music track over your videos.
- ENABLE_MUSIC=true
- MUSIC_DIR=/music
- MUSIC_FILE_TYPES="mp3 flac wav ogg"
- MUSIC_VOLUME=0.5 # Set music volume to 50%
```

#### Music Volume
You can also adjust the volume of the background music by setting the `MUSIC_VOLUME` variable.
- 1.0 is the original volume (100%, default).
- 0.5 is half volume (50%).
- 1.5 is 1.5x volume (150%).

You can customize the MUSIC_FILE_TYPES to include other audio formats.

### Stream Stability and Media Validation

To ensure a stable 24/7 stream, the script uses a two-pronged approach: proactive media validation before streaming begins, and active stall detection during the stream.

#### Media Pre-Validation

The script automatically validates all media files to prevent freezes caused by incompatible formats, which is especially important for hardware-accelerated encoding. The first valid file in a playlist sets a "gold standard" for properties. Any subsequent files with mismatched properties will be skipped, and a warning will be logged.

-   **Video Validation:** All videos are checked for consistent resolution (e.g., `1920x1080`) and pixel format (e.g., `yuv420p`). The framerate is also validated with flexibility: a video is considered compatible if its framerate is an integer multiple or divisor of the first video's framerate (e.g., 60fps is accepted if the reference is 30fps, and vice-versa).
-   **Audio Validation:**
    -   When background music is disabled, the audio from your video files is validated for consistent sample rate and channel count.
    -   When background music is enabled, the audio from your music files is validated instead.

This prevents the FFmpeg process from crashing when it encounters a video or audio stream that is different from the one it started with.

#### Stall Detection and Auto-Recovery

Even with validation, some media files can cause the FFmpeg process to stall or freeze without crashing. To combat this, the script includes a robust stall monitor:

-   **Constant Monitoring:** The script periodically checks if FFmpeg is making progress encoding the current video.
-   **Automatic Restart:** If no progress is detected for a configurable period (defaulting to 60 seconds), the script assumes FFmpeg is stalled. It will then kill the stuck process and restart the stream.
-   **Automatic File Exclusion:** To prevent a recurrence, the video file that was playing when the stall occurred is automatically added to an exclusion list located at `./data/excluded_videos.txt`. This file persists across container restarts. The stream will then resume, skipping the problematic file.

This combination of pre-validation and active stall detection ensures maximum uptime for your 24/7 stream.


### FFmpeg Log File

The main container log (`docker-compose logs -f`) is always kept clean, showing only important status messages and "Now Playing" information.

For advanced troubleshooting, you can enable a separate, verbose log file for FFmpeg's debug output.

```yaml
# docker-compose.yaml
# --- Optional FFmpeg File Logging ---
# The main container log is always clean. Uncomment the line below to also save
# the full, verbose FFmpeg debug output to a file at ./data/ffmpeg.log.
# This is useful for troubleshooting but can create large log files.
- ENABLE_FFMPEG_LOG_FILE=true
```

### Script Event Logging

In addition to the main container log, you can save important script events (warnings, errors, video changes) to a separate log file. This is useful for reviewing issues without parsing the full container log.

```yaml
# docker-compose.yaml
# --- Optional Script Event Logging ---
# Uncomment to save WARNING and ERROR level script messages to a log file.
# This is useful for reviewing issues without having to parse the main container log.
- ENABLE_SCRIPT_LOG_FILE=true
# - SCRIPT_LOG_FILE=/data/script_warnings_errors.log # Optional: customize log file path
```

## Verifying Hardware Acceleration

To confirm that Intel QSV hardware acceleration is being used, check the container logs for FFmpeg's initialization output.

```bash
docker-compose logs twitch-streamer
```

You should see lines indicating that a VA-API device was initialized and that the `h264_vaapi` encoder is being used.

You can also monitor your GPU's utilization on the host machine. A great tool for this is `intel_gpu_top`.

```bash
# First, install the tool (e.g., sudo apt-get install intel-gpu-tools)
sudo intel_gpu_top
```

You should see activity in the "Video" or "Render/3D" sections when the stream is active.
