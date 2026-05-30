#!/usr/bin/env python3
"""Cliente Wayland mínimo - envía todo sin esperar respuestas intermedias"""
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

# IDs hardcodeados — coinciden con el orden de globals de Blacksea
WL_DISPLAY=1; REGISTRY=2; COMPOSITOR=3; SHM=4; SURFACE=5; SHM_POOL=6; BUFFER=7

W, H, STRIDE = 400, 300, 400*4
SIZE = STRIDE * H

# Buffer rojo en archivo
shm_path = "/tmp/bs_buf"
with open(shm_path, 'wb') as f:
    f.write(b'\x00\x00\xFF\x00' * (W * H))  # XRGB: rojo
fd = os.open(shm_path, os.O_RDWR)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(SOCKET)
print("Conectado!")

# Enviar todo de una sola vez en orden
# 1. get_registry
sock.sendall(msg(WL_DISPLAY, 1, u32(REGISTRY)))
# 2. bind wl_compositor (global name=1)
sock.sendall(msg(REGISTRY, 0, u32(1)+wl_str("wl_compositor")+u32(4)+u32(COMPOSITOR)))
# 3. bind wl_shm (global name=2)
sock.sendall(msg(REGISTRY, 0, u32(2)+wl_str("wl_shm")+u32(1)+u32(SHM)))
# 4. create_surface
sock.sendall(msg(COMPOSITOR, 0, u32(SURFACE)))
# 5. create_pool - enviamos fd como u32 en payload (protocolo custom)
# Blacksea lee /tmp/bs_buf directamente
sock.sendall(msg(SHM, 0, u32(SHM_POOL) + u32(fd) + u32(SIZE)))
# 6. create_buffer
sock.sendall(msg(SHM_POOL, 0, u32(BUFFER)+u32(0)+i32(W)+i32(H)+i32(STRIDE)+u32(1)))
# 7. attach + commit
sock.sendall(msg(SURFACE, 1, u32(BUFFER)+i32(100)+i32(100)))
sock.sendall(msg(SURFACE, 6))

print("Todo enviado! Mirá la VM...")
time.sleep(10)
sock.close()
os.close(fd)
