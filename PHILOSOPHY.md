# Filosofía de Blacksea 🌊

> *"El mar negro no pide permiso para existir."*

---

## Por qué existe Blacksea

El ecosistema de compositores Wayland está dominado por proyectos que dependen de wlroots,
libwayland, libdrm, libinput — capas sobre capas que abstraen el hardware hasta el punto donde
nadie sabe exactamente qué está pasando debajo. Blacksea nació de una pregunta simple:

**¿Qué tan lejos podemos llegar hablando directamente con el kernel?**

La respuesta es: todo el camino.

---

## Los cinco principios

### 1. Zero dependencias externas

Si Linux ya lo hace, Blacksea lo usa directamente.

- Framebuffer → `/dev/fb0` con `mmap`
- Input → `/dev/input/eventX` con `read`
- IPC → Unix sockets con `bind/listen/accept`
- Memoria compartida → `memfd_create`
- Tiempo → `nanosleep`

No hay `libdrm`. No hay `libwayland`. No hay `libinput`. No hay `libc` en el critical path.
Solo syscalls, ioctls, y píxeles.

### 2. El código es la documentación

Cada función en Blacksea tiene exactamente un trabajo y un nombre que lo describe.
No hay abstracciones por las abstracciones. Si tenés que leer tres archivos para entender
qué hace `blitSurface`, algo salió mal.

El objetivo: cualquier programador con conocimiento básico de C/Zig puede leer
`drm.zig` de arriba a abajo y entender exactamente cómo un compositor escribe píxeles
en pantalla. Sin magia. Sin indirección innecesaria.

### 3. Simplicidad sobre features

Blacksea no intenta ser Hyprland. No tiene animaciones de 120fps, shaders GLSL,
rounded corners, o notificaciones con blur. Hace bien estas cosas:

- Mostrar ventanas en pantalla
- Manejar input del teclado y mouse
- Organizar ventanas en columnas (scrolling) o mosaico (tiling)
- Dejar que Lua defina el resto

Si una feature no cabe en una función de menos de 50 líneas, probablemente
pertenece a un plugin Lua, no al núcleo.

### 4. El usuario es el compositor

La configuración en Lua no es un add-on — es parte del diseño desde el principio.
Blacksea provee los primitivos: superficies, outputs, seats, keybinds.
El usuario decide cómo se comportan.

```lua
-- Tu blacksea, tus reglas
blacksea.on_new_window(function(win)
    if win:title():match("Firefox") then
        win:move_to_column(1)
    end
end)
```

No hay un "modo correcto" de usar Blacksea. Hay el tuyo.

### 5. Construido para entenderse, no solo para usarse

Blacksea es un proyecto educativo tanto como funcional. El código está escrito
para ser leído. Los commits explican el *por qué*, no solo el *qué*.
El ARCHITECTURE.md existe para que alguien que nunca escribió un compositor
pueda entender cómo funciona uno.

Si alguien lee el código de Blacksea y aprende cómo funciona el protocolo Wayland,
cómo se habla con DRM, o cómo se transfieren buffers entre procesos — el proyecto
cumplió su propósito, independientemente de si lo usan como daily driver.

---

## Lo que Blacksea no es

- **No es un reemplazo de Sway o Hyprland** para usuarios que quieren todo listo
- **No es un proyecto de producción empresarial** con SLA y compatibilidad garantizada
- **No es un port de wlroots** — si querés wlroots, usá wlroots, es excelente
- **No es completo** — y eso está bien

---

## Stack técnico y por qué

| Componente | Elección | Razón |
|------------|----------|-------|
| Lenguaje   | Zig 0.16 | Control de memoria sin GC, interop C sin fricción, errores explícitos |
| Render     | Software (fb0) | Sin dependencias de GPU, funciona en cualquier hardware |
| Protocolo  | Wayland wire manual | Entender el protocolo, no abstraerlo |
| Config     | Lua (Fase 7) | Embebible, liviano, expresivo, probado en AwesomeWM |
| IPC        | Unix sockets | El estándar, sin sorpresas |

---

## El nombre

El Mar Negro es profundo, oscuro, y no tiene mareas apreciables — es uno de los
cuerpos de agua más estables del mundo. Un buen compositor debería ser igual:
profundo en lo que hace, invisible en su operación, estable ante cualquier carga.

Y porque `river` ya estaba tomado.

---

## Estado actual

| Fase | Estado | Descripción |
|------|--------|-------------|
| 1 — Hardware    | ✅ | fb0, evdev, software render |
| 2 — Protocolo   | ✅ | Unix socket, wire format, registry |
| 3 — Superficies | 🔄 | wl_shm, blit, cliente de prueba |
| 4 — Ventanas    | ⏳ | xdg_shell, foco, decoraciones |
| 5 — Layout      | ⏳ | Scrolling columns + tiling mode |
| 6 — Pulido      | ⏳ | Fuentes bitmap, barra de estado |
| 7 — Lua         | ⏳ | Config, keybinds, hooks |

---

*Blacksea es software libre. Tomalo, rompelo, aprendé de él.*
