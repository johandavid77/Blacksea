# Blacksea

Un compositor Wayland escrito en Zig, construido sobre wlroots.

```
          ~~  Blacksea  ~~
   un compositor, profundo y oscuro
```

## Dependencias

```bash
# Arch Linux
pacman -S zig wlroots wayland wayland-protocols libxkbcommon libinput

# Ubuntu/Debian (24.04+)
apt install zig libwlroots-dev libwayland-dev libxkbcommon-dev libinput-dev \
            wayland-protocols

# Fedora
dnf install zig wlroots-devel wayland-devel libxkbcommon-devel libinput-devel
```

> Requiere **wlroots 0.18** y **Zig 0.14**.

## Build

```bash
zig build          # compila
zig build run      # compila y lanza
zig build test     # corre los tests unitarios
```

## Desarrollo anidado (sin TTY)

Blacksea detecta automáticamente el entorno via `wlr_backend_autocreate`.
Si tenés `WAYLAND_DISPLAY` exportado (estás en GNOME/KDE/etc.), corre
como cliente Wayland dentro de tu sesión actual — perfecto para desarrollo.

```bash
# En tu sesión de escritorio normal:
zig build run
# → abre una ventana con el compositor anidado
```

## Estructura del proyecto

```
blacksea/
├── build.zig          — sistema de build, linkeo de C libs
└── src/
    ├── main.zig       — entry point, listeners globales, event loop
    ├── server.zig     — estado global: display, backend, renderer, scene
    ├── output.zig     — monitores (outputs): configuración y frame rendering
    ├── view.zig       — ventanas (xdg_toplevel): posición, foco, hit-test
    └── c.zig          — @cImport centralizado de wlroots/wayland/xkbcommon
```

## Roadmap

- [x] **Fase 1** — Andamio: compositor arranca, detecta outputs, event loop
- [ ] **Fase 2** — Superficies: clientes se conectan, ventanas se renderizan
- [ ] **Fase 3** — Input: teclado, mouse, foco de ventanas, keybindings
- [ ] **Fase 4** — Extras: XWayland, IPC socket, layer-shell, decoraciones

## Referencia

- [tinywl](https://gitlab.freedesktop.org/wlroots/wlroots/-/tree/master/tinywl) — compositor mínimo de ejemplo en C (nuestro norte)
- [wlroots docs](https://gitlab.freedesktop.org/wlroots/wlroots)
- [Wayland book](https://wayland-book.com)
- [Zig C interop](https://ziglang.org/documentation/master/#C)
