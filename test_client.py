#!/usr/bin/env python3
import socket, struct, os, mmap, array, time

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

def recv_msgs(sock, timeout=3.0):
    """Leer todos los mensajes disponibles"""
    sock.settimeout(timeout)
    buf = b""
    try:
        while True:
            chunk = sock.recv(4096)
            if not chunk: break
            buf += chunk
            # Si recibimos el callback de sync, terminamos
            if len(buf) >= 8:
                break
    except socket.timeout:
        pass
    sock.settimeout(None)
    
    msgs = []
    while len(buf) >= 8:
        obj = struct.unpack("<I", buf[0:4])[0]
        so  = struct.unpack("<I", buf[4:8])[0]
        sz  = so >> 16
        op  = so & 0xFFFF
        if sz < 8 or len(buf) < sz: break
        msgs.append((obj, op, buf[8:sz]))
        buf = buf[sz:]
    return msgs

REGISTRY=2; COMPOSITOR=3; SHM=4; SURFACE=5; SHM_POOL=6; BUFFER=7

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(SOCKET)
print("Conectado a Blacksea!")

# get_registry
sock.sendall(msg(1, 1, u32(REGISTRY)))
# sync para saber cuando Blacksea terminó de enviar globals
sock.sendall(msg(1, 0, u32(100)))

# Esperar respuestas
time.sleep(0.05)
all_msgs = recv_msgs(sock, 2.0)

compositor_name = shm_name = None
for obj, op, payload in all_msgs:
    print(f"  msg obj={obj} op={op} len={len(payload)}")
    if obj == REGISTRY and op == 0 and len(payload) >= 8:
        name = struct.unpack("<I", payload[0:4])[0]
        slen = struct.unpack("<I", payload[4:8])[0]
        if slen > 0 and len(payload) >= 8 + slen:
            iface = payload[8:8+slen-1].decode(errors='ignore')
            print(f"    global {name}: {iface}")
            if iface == "wl_compositor": compositor_name = name
            if iface == "wl_shm":        shm_name = name

if compositor_name is None:
    print("ERROR: no recibimos globals")
    sock.close(); exit(1)

print(f"OK: compositor={compositor_name} shm={shm_name}")

# Bind y crear superficie
sock.sendall(msg(REGISTRY, 0, u32(compositor_name) + wl_str("wl_compositor") + u32(4) + u32(COMPOSITOR)))
sock.sendall(msg(REGISTRY, 0, u32(shm_name) + wl_str("wl_shm") + u32(1) + u32(SHM)))
time.sleep(0.2)
sock.sendall(msg(COMPOSITOR, 0, u32(SURFACE)))
time.sleep(0.1)

# Buffer azul 300x200
W, H, STRIDE = 300, 200, 300*4
SIZE = STRIDE * H
fd = os.memfd_create("bs", 0)
os.ftruncate(fd, SIZE)
mm = mmap.mmap(fd, SIZE)
mm.write(b"\xFF\x00\x00\xFF" * (W * H))

sock.sendmsg(
    [msg(SHM, 0, u32(SHM_POOL) + u32(SIZE))],
    [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i',[fd]))]
)
time.sleep(0.2)
sock.sendall(msg(SHM_POOL, 0, u32(BUFFER)+u32(0)+i32(W)+i32(H)+i32(STRIDE)+u32(0)))
sock.sendall(msg(SURFACE, 1, u32(BUFFER)+i32(100)+i32(50)))
sock.sendall(msg(SURFACE, 6))

print("Superficie enviada! Mirá la VM...")
time.sleep(10)
sock.close()
