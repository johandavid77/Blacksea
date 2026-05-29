# Blacksea — Roadmap

> Compositor Wayland desde cero en Zig. Sin libdrm, sin libwayland, sin libinput.

## Estado actual

```
Fase 1 ✅  →  Fase 2 ✅  →  Fase 3 🔜  →  Fase 4  →  Fase 5  →  Fase 6
Hardware      Protocolo     Superficies    Ventanas    Layout     Pulido
```

---

## ✅ Fase 1 — Hardware (COMPLETADA)

**Objetivo:** Blacksea toma control de la pantalla y dibuja píxeles reales.

- [x] Abrir `/dev/fb0` (framebuffer directo, virtio-gpu compatible)
- [x] Leer geometría con `FBIOGET_VSCREENINFO` / `FBIOGET_FSCREENINFO`
- [x] `mmap()` del framebuffer para acceso directo a píxeles ARGB8888
- [x] Software renderer: `fillRect`, `setPixel`, `clear`
- [x] Barra superior con indicador de modo de layout
- [x] Cursor en cruz que sigue al mouse
- [x] Lectura de input desde `/dev/input/eventX` sin libinput
- [x] Detección de modificadores: Super, Ctrl, Alt, Shift
- [x] `Super+Q` para salir, `Super+Space` para cambiar layout
- [x] Event loop a ~60fps con `nanosleep`
- [x] Doble modo: scrolling (azul) / tiling (verde)

**Archivos:** `drm.zig`, `evdev.zig`, `main.zig`

---

## ✅ Fase 2 — Protocolo Wayland (COMPLETADA)

**Objetivo:** Clientes Wayland pueden conectarse al compositor.

- [x] Unix domain socket en `/run/user/1000/wayland-0`
- [x] Wire format binario: header 8 bytes (object_id + size + opcode)
- [x] `MsgBuf`: serialización de mensajes sin heap allocation
- [x] `wl_display` (object 1): sync + get_registry
- [x] `wl_registry`: anuncio de globals (wl_compositor, wl_shm, xdg_wm_base, wl_seat, wl_output)
- [x] Accept de clientes en modo non-blocking
- [x] Dispatch de mensajes por object_id y opcode
- [x] Desconexión limpia de clientes

**Archivos:** `wayland.zig`

---

## 🔜 Fase 3 — Superficies (PRÓXIMA)

**Objetivo:** Un cliente puede crear una superficie y mostrar contenido.

- [ ] `wl_compositor.create_surface` → crear `wl_surface`
- [ ] `wl_shm` → memoria compartida via `memfd_create` + `mmap`
- [ ] `wl_shm_pool.create_buffer` → buffer de píxeles del cliente
- [ ] `wl_surface.attach` + `wl_surface.commit` → mostrar buffer en pantalla
- [ ] Blit de superficie del cliente al framebuffer del compositor
- [ ] `wl_surface.damage` → damage tracking básico
- [ ] Frame callbacks: `wl_surface.frame` → notificar vsync al cliente

**Meta:** `weston-simple-shm` o similar conecta y muestra un rectángulo de color.

---

## Fase 4 — Ventanas reales

**Objetivo:** Ventanas con título, que se pueden mover y cerrar.

- [ ] `xdg_wm_base` → protocolo de ventanas de escritorio
- [ ] `xdg_surface` + `xdg_toplevel` → ventana completa
- [ ] `xdg_toplevel.set_title` → nombre de ventana
- [ ] `configure` / `ack_configure` → handshake de tamaño
- [ ] Foco de teclado via `wl_seat` + `wl_keyboard`
- [ ] Foco de puntero via `wl_seat` + `wl_pointer`
- [ ] `wl_pointer.enter` / `leave` / `motion` / `button`
- [ ] Mover ventanas arrastrando con el mouse (Super+click)
- [ ] Z-ordering: traer ventana al frente al hacer click

**Meta:** `foot` o `weston-terminal` corre dentro de Blacksea.

---

## Fase 5 — Layout engine

**Objetivo:** El corazón de Blacksea — lo que lo hace único.

### Modo Scrolling (estilo niri)
- [ ] Columnas de ancho fijo organizadas horizontalmente
- [ ] Scroll horizontal animado entre columnas
- [ ] Animación de entrada/salida de ventanas
- [ ] Columna activa centrada en pantalla
- [ ] `Super+Left/Right` para navegar entre columnas
- [ ] `Super+Shift+Left/Right` para mover ventanas entre columnas

### Modo Tiling (estilo dwm)
- [ ] División automática de pantalla (horizontal/vertical)
- [ ] `Super+H/V` para dividir
- [ ] `Super+J/K` para navegar entre tiles
- [ ] Resize de tiles con el mouse

### Transición entre modos
- [ ] Animación suave al cambiar de scrolling a tiling
- [ ] `Super+Space` para alternar (ya funciona el indicador)

---

## Fase 6 — Pulido y extras

- [ ] **Fuentes bitmap** — texto en la barra (reloj, nombre de ventana activa)
- [ ] **Barra de estado** — hora, nombre de ventana, modo actual
- [ ] **IPC socket** — control externo (tipo i3-msg / swaymsg)
- [ ] **Config file** — `~/.config/blacksea/config` (keybinds, colores, gaps)
- [ ] **wl_output** — soporte multimonitor
- [ ] **layer-shell** — para barras externas (waybar, etc.)
- [ ] **XWayland** — apps Xorg legacy (opcional, complejidad alta)
- [ ] **Decoraciones** — bordes de ventana, server-side decorations
- [ ] **Animaciones** — apertura/cierre de ventanas

---

## Stack técnico

| Componente | Tecnología | Estado |
|------------|------------|--------|
| Lenguaje | Zig 0.16 | ✅ |
| Display | `/dev/fb0` framebuffer directo | ✅ |
| Input | `/dev/input/eventX` evdev directo | ✅ |
| Render | Software (ARGB8888 sobre mmap) | ✅ |
| Protocolo | Wire format Wayland desde cero | ✅ |
| Ventanas | xdg-shell (por implementar) | 🔜 |
| Layout | Scrolling + Tiling (por implementar) | 🔜 |
| Dependencias externas | **Ninguna** | ✅ |

---

## Filosofía del proyecto

- **Zero dependencias** — si el kernel lo expone, lo usamos directamente
- **Legible** — cada línea debe ser entendible, sin magia
- **Incremental** — cada fase agrega algo visible y funcional
- **Documentado** — `ARCHITECTURE.md` se actualiza con cada fase

---

## Cómo contribuir / continuar

```bash
git clone https://github.com/johandavid77/Blacksea.git
cd Blacksea
zig build run   # necesita TTY con /dev/fb0
```

Cada fase tiene su rama:
- `main` — código estable
- `fase-3` — trabajo en curso
