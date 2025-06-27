# Base image
FROM ubuntu:latest

SHELL ["/bin/bash", "-e", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Tallinn

# Install dependencies
RUN <<EOT
apt update
apt full-upgrade -y --no-install-recommends
apt install -y ca-certificates
apt install -y xz-utils
apt install -y libdrm2
apt install -y libdrm-dev
apt install -y vainfo
apt install -y libva-drm2
apt install -y libva-x11-2
apt install -y libva2
apt install -y tzdata
apt install -y inotify-tools
rm -rf /var/lib/apt/lists/*
EOT

# Set timezone
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Copy and extract the ffmpeg binary archive
COPY ffmpeg-6.1.2-linux-amd64.tar.xz /tmp/
RUN <<EOT
tar -xf /tmp/ffmpeg-6.1.2-linux-amd64.tar.xz -C /usr/local --strip-components=1
rm /tmp/ffmpeg-6.1.2-linux-amd64.tar.xz
EOT

# Copy the shell script into the container
COPY twitch_streamer.sh /usr/local/bin/

# Set execute permissions for the script
RUN chmod +x /usr/local/bin/twitch_streamer.sh

# Set the entrypoint to the shell script
ENTRYPOINT ["/usr/local/bin/twitch_streamer.sh"]
