# --- Build Stage ---
# This stage is only used to extract the ffmpeg binary from its archive.
# Its contents will be discarded and will not be part of the final image.
FROM debian:bookworm-slim AS builder

# Install the extraction tool
RUN apt-get update && apt-get install -y --no-install-recommends xz-utils

# Copy and extract the ffmpeg archive
COPY ffmpeg-6.1.2-linux-amd64.tar.xz /tmp/
RUN tar -xf /tmp/ffmpeg-6.1.2-linux-amd64.tar.xz -C /usr/local --strip-components=1


# --- Final Stage ---
# This is the final, optimized image that will be used.
FROM debian:bookworm-slim

# Set shell to bash and ensure commands exit on error.
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# Set non-interactive frontend for package installation.
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Tallinn

# Enable non-free repos and install only runtime dependencies.
RUN sed -i 's/ main/ main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    # Bash is used by the entrypoint script
    bash \
    # Runtime libs for VA-API hardware acceleration
    libva2 \
    libva-drm2 \
    libdrm2 \
    # Intel's non-free VA-API driver, often required for hardware encoding/decoding.
    intel-media-va-driver-non-free \
    # Script dependencies
    inotify-tools \
    # bc is used for floating point math in the script
    bc \
    # Timezone data
    tzdata \
    ca-certificates && \
    \
    # Set timezone
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
    \
    # Clean up apt caches
    rm -rf /var/lib/apt/lists/*

# Copy the extracted ffmpeg binaries from the build stage.
COPY --from=builder /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=builder /usr/local/bin/ffprobe /usr/local/bin/ffprobe

# Copy the shell script into the container
COPY twitch_streamer.sh /usr/local/bin/twitch_streamer.sh

# Set execute permissions for the script
RUN chmod +x /usr/local/bin/twitch_streamer.sh

# Set the entrypoint to run the streaming script
ENTRYPOINT ["/usr/local/bin/twitch_streamer.sh"]
