# Twitch Streamer Docker Setup

A simple, efficient, and Docker-based solution for streaming a playlist of video files 24/7 to Twitch using FFmpeg with Intel Quick Sync Video (QSV) hardware acceleration via VA-API. This setup is ideal for low-power systems like those with an Intel N100 CPU.

## Features

-   **24/7 Streaming:** Automatically finds and streams all videos in a directory, looping them continuously.
-   **Hardware Accelerated:** Utilizes Intel QSV (VA-API) for efficient video encoding, keeping CPU usage low.
-   **Dynamic Playlist:** Automatically detects new, deleted, or moved videos and restarts the stream to update the playlist.
-   **Dockerized:** Easy to set up and run on any Linux system with Docker and a supported Intel GPU.
-   **Customizable:** Easily change your stream configuration via environment variables.

## Prerequisites

Before you begin, ensure you have the following installed and configured on your host system:

-   [Docker](https://docs.docker.com/get-docker/)
-   [Docker Compose](https://docs.docker.com/compose/install/) (usually included with Docker Desktop or installed as a plugin)
-   A modern Intel CPU with Quick Sync Video support.
-   **Intel VA-API Drivers:**
    -   For modern GPUs (Broadwell and newer), install `intel-media-driver`.
    -   On Debian/Ubuntu: `sudo apt-get install intel-media-driver-non-free i965-va-driver-shaders`
    -   On Arch Linux: `sudo pacman -S intel-media-driver`
-   **Verification Tool (Optional but Recommended):**
    -   Install `vainfo` to check if VA-API is configured correctly.
    -   On Debian/Ubuntu: `sudo apt-get install vainfo`
    -   On Arch Linux: `sudo pacman -S libva-utils`
-   A Twitch account and your **Stream Key**.

### Verify VA-API on Host

Run the following command to ensure your host system recognizes the GPU and VA-API is working.

```bash
vainfo
```

You should see output listing supported profiles, including `VAProfileH264ConstrainedBaseline`, `VAProfileH264Main`, and `VAProfileH264High`. If you see an error, your drivers are not set up correctly.

## Getting Started

Follow these steps to get your stream up and running.

### 1. Clone the Repository

If you haven't already, clone this repository to your local machine.

### 2. Configure Your Stream Key

Create a `.env` file to store your Twitch Stream Key.

```dotenv
# .env
TWITCH_STREAM_KEY=your_stream_key_here
```

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

### 4. Add Your Videos

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
