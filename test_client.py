#!/usr/bin/env python3
"""
Cliente Wayland mínimo para probar Blacksea.
Se conecta al socket, bindea wl_compositor + wl_shm,
crea una superficie y muestra un rectángulo rojo.
"""
import socket, struct, os, mmap, tempfile

SOCKET = "/run/user/1000/wayland-0"

def pack_msg(obj_id, opcode, *args):
    payload = b""
    for a in args:
        if isinstance(a, int):   payload += struct.pack("<I", a)
        elif isinstance(a, str):
            s = a.encode() + b"\x00"
            pad = (4 - len(s) % 4) % 4
            payload += struct.pack("<I", len(s)) + s + bytes(pad)
        elif isinstance(a, bytes): payload += a
    size = 8 + len(payload)
    return struct.pack("<IHH", obj_id, size, opcode) + payload

def recv_msg(sock):
    h = sock.recv(8)
    if len(h) < 8: return None, None, None
    obj, size_op = struct.unpack("<II", h)
    size = size_op >> 16
    op   = size_op & 0xFFFF
    payload = sock.recv(size - 8) if size > 8 else b""
    return obj, op, payload

# Conectar
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(SOCKET)
print("Conectado a Blacksea!")

# IDs
WL_DISPLAY    = 1
WL_REGISTRY   = 2
WL_COMPOSITOR = 3
WL_SHM        = 4
WL_SURFACE    = 5
WL_SHM_POOL   = 6
WL_BUFFER     = 7

# get_registry
sock.sendall(pack_msg(WL_DISPLAY, 1, WL_REGISTRY))

# Leer globals
sock.settimeout(1.0)
compositor_name = shm_name = None
try:
    while True:
        obj, op, payload = recv_msg(sock)
        if obj == WL_REGISTRY and op == 0:  # global
            name = struct.unpack("<I", payload[:4])[0]
            iface_len = struct.unpack("<I", payload[4:8])[0]
            iface = payload[8:8+iface_len-1].decode()
            print(f"  global {name}: {iface}")
            if iface == "wl_compositor": compositor_name = name
            if iface == "wl_shm":        shm_name = name
except: pass

# Bind
sock.settimeout(None)
sock.sendall(pack_msg(WL_REGISTRY, 0, compositor_name, b"\x00"*4 + b"\x04\x00\x00\x00", WL_COMPOSITOR))
sock.sendall(pack_msg(WL_REGISTRY, 0, shm_name,        b"\x00"*4 + b"\x01\x00\x00\x00", WL_SHM))

# Crear superficie
sock.sendall(pack_msg(WL_COMPOSITOR, 0, WL_SURFACE))

# Crear shm pool con memfd
WIDTH, HEIGHT = 200, 200
STRIDE = WIDTH * 4
SIZE   = STRIDE * HEIGHT

fd = os.memfd_create("blacksea-test", 0)
os.ftruncate(fd, SIZE)
mm = mmap.mmap(fd, SIZE)

# Pintar rojo brillante
for y in range(HEIGHT):
    for x in range(WIDTH):
        # ARGB8888: alpha=FF, R=FF, G=00, B=00
        mm.write(struct.pack("<I", 0xFFFF0000))
mm.seek(0)

# create_pool(fd, size) — enviar fd via SCM_RIGHTS
import array
fds_array = array.array('i', [fd])
ancdata = [(socket.SOL_SOCKET, socket.SCM_RIGHTS, fds_array)]
msg = pack_msg(WL_SHM, 0, WL_SHM_POOL, SIZE)
sock.sendmsg([msg], ancdata)

# create_buffer(pool, offset, width, height, stride, format)
sock.sendall(pack_msg(WL_SHM_POOL, 0, WL_BUFFER, 0, WIDTH, HEIGHT, STRIDE, 1))  # format=XRGB8888

# attach + commit
sock.sendall(pack_msg(WL_SURFACE, 1, WL_BUFFER, 100, 50))  # attach en (100, 50)
sock.sendall(pack_msg(WL_SURFACE, 6))  # commit

print("Superficie enviada! Debería aparecer un rectángulo rojo en Blacksea.")
import time; time.sleep(5)
sock.close()
