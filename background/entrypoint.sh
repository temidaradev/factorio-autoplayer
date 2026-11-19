#!/bin/sh
set -eu
executable=""
for candidate in /game/bin/arm64/factorio /game/bin/aarch64/factorio /game/bin/x64/factorio; do
    if [ -x "$candidate" ]; then executable=$candidate; break; fi
done
[ -n "$executable" ] || { echo "Mount an extracted Linux Factorio client at /game." >&2; exit 1; }

mkdir -p /profile/saves
if [ ! -e /profile/config.ini ]; then
    printf '; version=13\n[path]\nread-data=/game/data\nwrite-data=/profile\n' > /profile/config.ini
fi
export XDG_RUNTIME_DIR=/tmp/factorio-runtime
mkdir -m 700 "$XDG_RUNTIME_DIR"
Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp &
for attempt in $(seq 1 60); do
    if xdpyinfo >/dev/null 2>&1; then break; fi
    sleep 0.2
done
xdpyinfo >/dev/null
openbox --sm-disable >/tmp/openbox.log 2>&1 &

if [ -r /seed/start.zip ]; then
    if [ ! -e /profile/saves/start.zip ]; then
        cp /seed/start.zip /profile/saves/start.zip
    fi
    set -- --load-game /profile/saves/start.zip
fi
"$executable" --config /profile/config.ini --fullscreen=true --disable-audio \
    --force-graphics-preset very-low "$@" &
game_pid=$!
printf '%s\n' "$game_pid" > /tmp/factorio.pid
trap 'kill -TERM "$game_pid" 2>/dev/null || true; wait "$game_pid" || true' TERM INT
wait "$game_pid"
