# 🌊 Blacksea

> A Wayland compositor written from scratch in Zig. No libdrm, no libwayland, no libinput — pure kernel syscalls.

```
  ~~  Blacksea  ~~
  compositor wayland desde cero
  escrito en Zig 0.16
```

## ¿Qué es Blacksea?

Blacksea es un compositor Wayland construido completamente desde cero, sin depender de ninguna librería de abstracción. Habla directamente con el kernel Linux vía ioctls DRM/KMS para controlar el display, lee eventos de input desde `/dev/input/` sin libinput, y tiene su propio sistema de layout con dos modos: **scrolling** (estilo niri) y **tiling** (estilo dwm), con cambio dinámico entre ellos.

## Características

- **Zero dependencias externas** — solo el kernel Linux y libc
- **DRM/KMS directo** — ioctls a mano, dumb buffers, double buffering, page flip
- **evdev directo** — lee `/dev/input/eventX` sin libinput
- **Software renderer** — píxeles ARGB8888 escritos directamente al framebuffer
- **Dual layout** — modo scrolling (columnas) y tiling (mosaico), cambiable con `Super+Space`
- **Escrito en Zig 0.16** — compilado a nativo, sin GC, sin runtime

## Requisitos

- Linux con DRM/KMS (cualquier GPU moderna)
- Zig 0.16.0
- Usuario en el grupo `video` e `input`
- Correr desde TTY (no dentro de otro compositor)

```bash
sudo usermod -aG video,input $USER
```

## Build

```bash
git clone https://github.com/johandavid77/blacksea.git
cd blacksea
zig build run
```

## Controles

| Atajo | Acción |
|-------|--------|
| `Super+Space` | Cambiar modo de layout (scrolling ↔ tiling) |
| `Super+Q` | Salir |

## Estructura del proyecto

```
blacksea/
├── build.zig        — sistema de build, zero dependencias externas
└── src/
    ├── main.zig     — entry point, event loop, render loop
    ├── drm.zig      — DRM/KMS: ioctls, dumb buffers, page flip, double buffering
    └── evdev.zig    — input: lectura directa de /dev/input/eventX
```

## Arquitectura

```
┌─────────────────────────────────────┐
│           main.zig                  │
│   event loop · render · keybinds    │
└──────────┬──────────────┬───────────┘
           │              │
    ┌──────▼──────┐  ┌────▼──────┐
    │   drm.zig   │  │ evdev.zig │
    │  DRM/KMS    │  │  /dev/    │
    │  ioctls     │  │  input/   │
    └──────┬──────┘  └───────────┘
           │
    ┌──────▼──────────────────────┐
    │      Kernel Linux           │
    │  DRM/KMS · evdev · mmap     │
    └─────────────────────────────┘
```

## Roadmap

- [x] **Fase 1** — DRM/KMS, evdev, software render, dual layout mode
- [ ] **Fase 2** — Protocolo Wayland desde cero (wire format, Unix socket)
- [ ] **Fase 3** — wl_compositor, wl_surface, wl_shm — primeros clientes
- [ ] **Fase 4** — xdg_shell, ventanas reales, foco de teclado
- [ ] **Fase 5** — Layout engine: scrolling columns + tiling
- [ ] **Fase 6** — IPC socket, config file, decoraciones

## Inspiración

- [niri](https://github.com/YaLTeR/niri) — scrolling columns layout
- [dwm](https://dwm.suckless.org/) — tiling simplicity
- [tinywl](https://gitlab.freedesktop.org/wlroots/wlroots/-/tree/master/tinywl) — minimal compositor reference
- [Wayland Book](https://wayland-book.com) — protocolo Wayland

## Autor

**johandavid77** — construido con paciencia, ioctls y mucho debug desde Arch Linux.
