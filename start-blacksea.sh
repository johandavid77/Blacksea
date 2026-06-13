#!/bin/bash
# Arrancar Blacksea desde tty1 — foot tendrá PTYs independientes
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0

cd ~/blacksea
./zig-out/bin/blacksea 2>/tmp/bs.log &
sleep 2

foot &
sleep 2
foot &
wait
