FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 xvfb xdotool openbox imagemagick x11-utils \
    libgl1 libgl1-mesa-dri libglx-mesa0 libgbm1 libsdl2-2.0-0 \
    libpulse0 libasound2t64 libxrandr2 libxinerama1 libxcursor1 libxi6 \
    ca-certificates fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
RUN install -d -m 1777 /tmp/.X11-unix
COPY entrypoint.sh mcp.py /opt/player/
ENV DISPLAY=:99 HOME=/profile LIBGL_ALWAYS_SOFTWARE=1 SDL_AUDIODRIVER=dummy
WORKDIR /profile
ENTRYPOINT ["/bin/sh", "/opt/player/entrypoint.sh"]
