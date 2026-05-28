# Blacksea — Documentación Técnica

## Visión general

Blacksea habla directamente con el kernel sin capas de abstracción:

```
App Wayland → [Fase 2: wayland.zig] → main.zig → drm.zig → /dev/dri/card1
                                                 → evdev.zig → /dev/input/eventX
```

---

## drm.zig

### ¿Qué es DRM/KMS?

**DRM** (Direct Rendering Manager) es el subsistema del kernel que gestiona el hardware de display y GPU. **KMS** (Kernel Mode Setting) es la parte que permite configurar resoluciones y mandar frames a pantalla desde userspace.

Sin libdrm, todo se hace con `ioctl()` directamente sobre `/dev/dri/cardX`.

### Flujo de inicialización

```
open("/dev/dri/card1")
    → DRM_IOCTL_GET_RESOURCES      — cuántos connectors/CRTCs hay
    → DRM_IOCTL_GET_CONNECTOR      — estado del monitor (conectado/desconectado)
    → DRM_IOCTL_GET_ENCODER        — qué CRTC usa este connector
    → DRM_IOCTL_CREATE_DUMB        — crear framebuffer en RAM
    → DRM_IOCTL_ADD_FB             — registrarlo en DRM
    → DRM_IOCTL_MAP_DUMB           — obtener offset para mmap
    → mmap()                       — mapear píxeles en nuestro espacio de memoria
    → DRM_IOCTL_SET_CRTC           — apuntar el CRTC a nuestro framebuffer
```

### Double buffering

Blacksea crea **dos framebuffers** (front y back):

- **front**: lo que está en pantalla ahora mismo
- **back**: donde dibujamos el próximo frame

Cuando terminamos de dibujar, llamamos `DRM_IOCTL_PAGE_FLIP` para intercambiarlos atómicamente en el siguiente vsync. Esto elimina el tearing.

```
Frame N:   dibujar en back → page_flip → back se convierte en front
Frame N+1: dibujar en el nuevo back → page_flip → ...
```

### Structs clave

| Struct | Propósito |
|--------|-----------|
| `DrmModeResources` | Lista de connectors, CRTCs, encoders disponibles |
| `DrmModeGetConnector` | Estado de un monitor: resoluciones, estado de conexión |
| `DrmModeInfo` | Un modo de video: resolución, refresh rate, timings |
| `DrmModeCreateDumb` | Crear un dumb buffer (framebuffer en RAM) |
| `DrmModeCrtc` | Configurar un CRTC: qué framebuffer mostrar |
| `DrmModePageFlip` | Solicitar page flip en el próximo vsync |

### Funciones públicas

| Función | Descripción |
|---------|-------------|
| `Device.autoDetect()` | Busca `/dev/dri/card0..9`, retorna el primero disponible |
| `Device.open(path)` | Abre un device DRM específico y toma el DRM master |
| `Device.detectOutput()` | Detecta el primer monitor conectado, crea los framebuffers |
| `Device.close()` | Libera framebuffers, suelta el DRM master |
| `Framebuffer.create()` | Crea dumb buffer + mmap + registra en DRM |
| `Framebuffer.setPixel()` | Escribir un píxel (inline, muy rápido) |
| `Framebuffer.fillRect()` | Rellenar un rectángulo con color sólido |
| `Framebuffer.clear()` | Limpiar todo el framebuffer a un color |
| `Output.pageFlip()` | Intercambiar front/back buffer |
| `Output.drawBuffer()` | Retorna el buffer donde hay que dibujar ahora |
| `ioctl()` | Helper que wrappea `linux.ioctl` con manejo de errores Zig |

### Formato de píxel

Usamos **ARGB8888** (32 bits por píxel):
```
Bit 31..24: Alpha (ignorado por DRM en modo opaco)
Bit 23..16: Red
Bit 15..8:  Green
Bit 7..0:   Blue

Ejemplo: 0xFF1F6FEB = azul Blacksea
         0xFF0D1117 = negro azulado (background)
```

### ioctls utilizados

| ioctl | Número | Propósito |
|-------|--------|-----------|
| `DRM_IOCTL_GET_RESOURCES` | 0xA0 | Listar recursos del display |
| `DRM_IOCTL_GET_CONNECTOR` | 0xA7 | Info de un monitor |
| `DRM_IOCTL_GET_ENCODER` | 0xA6 | Qué CRTC usa un connector |
| `DRM_IOCTL_SET_CRTC` | 0xA2 | Configurar display |
| `DRM_IOCTL_CREATE_DUMB` | 0xB2 | Crear framebuffer |
| `DRM_IOCTL_MAP_DUMB` | 0xB3 | Obtener offset para mmap |
| `DRM_IOCTL_DESTROY_DUMB` | 0xB4 | Liberar framebuffer |
| `DRM_IOCTL_ADD_FB` | 0xAE | Registrar framebuffer en DRM |
| `DRM_IOCTL_RM_FB` | 0xAF | Desregistrar framebuffer |
| `DRM_IOCTL_PAGE_FLIP` | 0xB0 | Solicitar vsync swap |
| `DRM_IOCTL_SET_MASTER` | 0x1E | Tomar control exclusivo del display |
| `DRM_IOCTL_DROP_MASTER` | 0x1F | Liberar control del display |

---

## evdev.zig

### ¿Qué es evdev?

El kernel expone cada dispositivo de input como un archivo en `/dev/input/eventX`. Cada `read()` devuelve structs `input_event` de 24 bytes con el tipo de evento, código y valor.

### Struct input_event (kernel)

```
┌──────────────┬──────────────┬────────┬────────┬─────────┐
│  time_sec    │  time_usec   │  type  │  code  │  value  │
│   (8 bytes)  │   (8 bytes)  │ 2 bytes│ 2 bytes│ 4 bytes │
└──────────────┴──────────────┴────────┴────────┴─────────┘
Total: 24 bytes
```

### Tipos de evento

| Tipo | Valor | Descripción |
|------|-------|-------------|
| `EV_SYN` | 0x00 | Separador entre grupos de eventos |
| `EV_KEY` | 0x01 | Teclado y botones de mouse |
| `EV_REL` | 0x02 | Movimiento relativo (mouse) |
| `EV_ABS` | 0x03 | Posición absoluta (touchpad) |

### Códigos de tecla relevantes

| Constante | Código | Tecla |
|-----------|--------|-------|
| `KEY_SUPER` | 125 | Tecla Windows/Meta |
| `KEY_Q` | 16 | Q |
| `KEY_SPACE` | 57 | Espacio |
| `KEY_LEFTCTRL` | 29 | Ctrl izquierdo |
| `KEY_LEFTALT` | 56 | Alt izquierdo |
| `KEY_LEFTSHIFT` | 42 | Shift izquierdo |

### Funcionamiento de InputManager

```
scanDevices():
    prueba /dev/input/event0 .. event31
    abre cada uno con O_RDONLY | O_NONBLOCK
    guarda los fd en devices[]

poll() (en el event loop):
    read() non-blocking de cada fd
    filtra EV_KEY y EV_REL
    actualiza estado de modificadores (Modifiers)
    dispara callbacks del compositor
```

### Struct Modifiers

Mantiene el estado actual de las teclas modificadoras:
```zig
pub const Modifiers = struct {
    ctrl : bool = false,
    shift: bool = false,
    alt  : bool = false,
    super: bool = false,
};
```

---

## main.zig

### Entry point y event loop

```
main()
  │
  ├── Device.autoDetect()     — abrir /dev/dri/card1
  ├── device.detectOutput()   — configurar monitor + framebuffers
  ├── InputManager.scanDevices() — abrir /dev/input/event*
  ├── drawFrame()             — pintar primer frame
  ├── output.pageFlip()       — mostrar en pantalla
  │
  └── loop:
        ├── leer eventos de input (non-blocking)
        ├── procesar keybinds (Super+Q, Super+Space)
        ├── actualizar cursor_x, cursor_y
        ├── si dirty: drawFrame() + pageFlip()
        └── nanosleep(16ms)  → ~60fps
```

### Sistema de layout

```zig
pub const LayoutMode = enum {
    scrolling,  // columnas infinitas (estilo niri) — por implementar
    tiling,     // mosaico (estilo dwm) — por implementar
};
```

El modo actual se indica visualmente con el cuadrado en la barra superior:
- **Azul** (`0xFF1F6FEB`) = modo scrolling
- **Verde** (`0xFF3FB950`) = modo tiling

### Paleta de colores

| Constante | Valor hex | Descripción |
|-----------|-----------|-------------|
| `Colors.background` | `0xFF0D1117` | Fondo principal (negro azulado) |
| `Colors.surface` | `0xFF161B22` | Superficies elevadas (barra, ventanas) |
| `Colors.accent` | `0xFF1F6FEB` | Color de acento (azul GitHub) |
| `Colors.white` | `0xFFE6EDF3` | Texto principal |

---

## build.zig

Zero dependencias externas. Solo `link_libc = true` para acceder a las funciones de libc (mmap, etc.).

```zig
exe.addExecutable(.{
    .name        = "blacksea",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target           = target,
        .optimize         = optimize,
        .link_libc        = true,   // único "external"
    }),
});
```

### Comandos

```bash
zig build          # compilar
zig build run      # compilar y ejecutar
zig build -Doptimize=ReleaseFast  # build optimizado
```

---

## Notas de compatibilidad — Zig 0.16

Zig 0.16 introdujo cambios de API que afectan este proyecto:

| API antigua | API en 0.16 |
|-------------|-------------|
| `std.heap.GeneralPurposeAllocator` | `std.heap.DebugAllocator` |
| `std.posix.open()` | `std.posix.openatZ()` |
| `std.posix.close()` | `linux.close()` |
| `std.time.sleep()` | `linux.nanosleep()` |
| `std.fs.openDirAbsolute()` | iterar por índice numérico |
| `root_source_file` en addExecutable | movido a `createModule()` |
| `exe.linkLibC()` | `link_libc = true` en el módulo |
| `std.posix.PROT.READ \| WRITE` | `std.posix.PROT{ .READ=true, .WRITE=true }` |

---

## Glosario

| Término | Definición |
|---------|------------|
| **DRM** | Direct Rendering Manager — subsistema del kernel para GPU y display |
| **KMS** | Kernel Mode Setting — configuración de modos de video desde userspace |
| **CRTC** | Cathode Ray Tube Controller — hardware que escanea el framebuffer a pantalla |
| **Connector** | Representa una salida de video (HDMI, DP, eDP, VGA) |
| **Encoder** | Convierte señal digital del CRTC al formato del connector |
| **Dumb buffer** | Framebuffer simple en RAM, sin aceleración GPU |
| **Page flip** | Intercambio atómico de framebuffers en vsync |
| **evdev** | Event device — interfaz del kernel para dispositivos de input |
| **DRM master** | Proceso con control exclusivo del display (solo uno a la vez) |
| **Wayland** | Protocolo de display moderno para Linux |
| **Compositor** | El proceso que combina las superficies de todas las apps en la pantalla final |
