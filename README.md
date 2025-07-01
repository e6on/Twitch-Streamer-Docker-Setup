# Twitch Streamer Docker Setup

A simple, efficient, and Docker-based solution for streaming a playlist of video files 24/7 to Twitch using FFmpeg with Intel Quick Sync Video (QSV) hardware acceleration via VA-API. This setup is ideal for low-power systems like UGREEN NASync DXP4800 with an Intel N100 Quad-core CPU.

## Features

-   **24/7 Streaming:** Automatically finds and streams all videos in a directory, looping them continuously.
-   **Hardware Accelerated:** Utilizes Intel QSV (VA-API) for efficient video encoding, keeping CPU usage low.
-   **Dynamic Playlist:** Automatically detects new, deleted, or moved videos and restarts the stream to update the playlist.
-   **Dockerized:** Easy to set up and run on any Linux system with Docker and a supported Intel GPU.
-   **Highly Customizable:** Easily change stream resolution, framerate, bitrates, and ingest server via environment variables.
-   **Persistent Playlist:** The generated playlist is stored in the `./data` volume for easy inspection.

## Prerequisites

Before you begin, ensure you have the following installed and configured on your host system:

-   Docker & Docker Compose
-   [FFmpeg - ffmpeg-6.1.2-linux-amd64.tar.xz](https://github.com/AkashiSN/ffmpeg-docker/releases) pre-built binary files.
-   A modern Intel CPU with Quick Sync Video support.
-   **Intel VA-API Drivers:**
    -   For modern GPUs (Broadwell and newer), install `intel-media-driver`.
    -   On Debian/Ubuntu: `sudo apt-get install intel-media-va-driver-non-free`
    -   On Arch Linux: `sudo pacman -S intel-media-driver`
-   **Verification Tool (Optional but Recommended):**
    -   Install `vainfo` to check if VA-API is configured correctly.
    -   On Debian/Ubuntu: `sudo apt-get install vainfo`
    -   On Arch Linux: `sudo pacman -S libva-utils`
-   A Twitch account and your **Stream Key**

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

The container needs access to your host's GPU. This is done by passing device files and matching user group IDs.

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

Place all the video files you want to stream into the `videos/` directory. The script will automatically find all `.mp4`, `.mkv`, and `.mpg` files. The playlist is automatically regenerated and updated whenever you add, remove, or move videos in this directory.

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

You can customize the stream's quality and destination by editing the environment section in the docker-compose.yaml file.

### Stream Quality

Uncomment and modify these variables to change the output stream quality. The defaults are set for a stable 960x540 @ 25fps stream.

```yaml
# docker-compose.yaml
# --- Optional Stream Quality Settings ---
# Uncomment and adjust these to change stream quality.
# - STREAM_RESOLUTION=1280x720 # e.g., 720p
# - STREAM_FRAMERATE=30
# - VIDEO_BITRATE=3000k # Recommended: 3000k for 720p30, 4500k for 720p60
# - AUDIO_BITRATE=160k # Recommended: 128k or 160k for good quality
```

### Twitch Ingest Server

For the best performance, you should use the Twitch ingest server closest to your location. Choose a server close to you from https://help.twitch.tv/s/twitch-ingest-recommendation.

Uncomment and change the `TWITCH_INGEST_URL` to your preferred server.

```yaml
# docker-compose.yaml
# --- Optional Ingest Server ---
# For best results, choose a server close to you from https://help.twitch.tv/s/twitch-ingest-recommendation
TWITCH_INGEST_URL=rtmp://hel03.contribute.live-video.net/app/ # Example: Europe, Finland, Helsinki
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
