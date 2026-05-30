#!/usr/bin/env python3
"""Cliente xdg_shell — prueba ventana real"""
import socket, struct, os, array, time

SOCKET = "/run/user/1000/wayland-0"

def u32(v): return struct.pack("<I", v)
def i32(v): return struct.pack("<i", v)
def wl_str(s):
    b = s.encode() + b"\x00"
    pad = (4 - len(b) % 4) % 4
    return u32(len(b)) + b + bytes(pad)
def msg(obj, op, payload=b""):
    size = 8 + len(payload)
    return struct.pack("<II", obj, (size << 16) | op) + payload

# IDs
DISPLAY=1; REGISTRY=2; COMPOSITOR=3; SHM=4; XDG_WM=5
SURFACE=6; XDG_SURFACE=7; TOPLEVEL=8; SHM_POOL=9; BUFFER=10

W, H, STRIDE = 800, 600, 800*4
SIZE = STRIDE * H

# Buffer azul
with open("/tmp/bs_buf", "wb") as f:
    f.write(b'\xFF\x00\x00\xFF' * (W * H))  # ARGB azul
fd = os.open("/tmp/bs_buf", os.O_RDWR)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(SOCKET)
print("Conectado!")

# get_registry + bind todo
sock.sendall(msg(DISPLAY, 1, u32(REGISTRY)))
sock.sendall(msg(REGISTRY, 0, u32(1)+wl_str("wl_compositor")+u32(4)+u32(COMPOSITOR)))
sock.sendall(msg(REGISTRY, 0, u32(2)+wl_str("wl_shm")+u32(1)+u32(SHM)))
sock.sendall(msg(REGISTRY, 0, u32(3)+wl_str("xdg_wm_base")+u32(2)+u32(XDG_WM)))
# create_surface
sock.sendall(msg(COMPOSITOR, 0, u32(SURFACE)))
# get_xdg_surface
sock.sendall(msg(XDG_WM, 2, u32(XDG_SURFACE)+u32(SURFACE)))
# get_toplevel
sock.sendall(msg(XDG_SURFACE, 1, u32(TOPLEVEL)))
# set_title
sock.sendall(msg(TOPLEVEL, 2, wl_str("Blacksea 🌊")))
# shm pool + buffer
sock.sendall(msg(SHM, 0, u32(SHM_POOL)+u32(fd)+u32(SIZE)))
sock.sendall(msg(SHM_POOL, 0, u32(BUFFER)+u32(0)+i32(W)+i32(H)+i32(STRIDE)+u32(1)))
# ack_configure(serial=1) + attach + commit
sock.sendall(msg(XDG_SURFACE, 4, u32(1)))
sock.sendall(msg(SURFACE, 1, u32(BUFFER)+i32(0)+i32(0)))
sock.sendall(msg(SURFACE, 6))

print("Ventana xdg enviada!")
time.sleep(10)
sock.close()
os.close(fd)
