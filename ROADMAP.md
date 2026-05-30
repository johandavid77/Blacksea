# Blacksea — Roadmap

## ✅ Fase 1: Framebuffer directo
- /dev/fb0 mapeado directamente
- Render de píxeles sin GPU abstraction
- Barra de estado superior

## ✅ Fase 2: Input desde /dev/input
- evdev crudo, sin libinput
- Mouse, teclado, eventos raw
- Poll de dispositivos

## ✅ Fase 3: Protocolo Wayland wire format
- Unix socket desde cero
- wl_display, wl_registry, globals
- wl_shm, wl_surface, wl_compositor
- SCM_RIGHTS para buffers compartidos
- Primer cliente Python renderizando píxeles

## ✅ Fase 4: xdg_shell + clientes reales
- xdg_wm_base, xdg_surface, xdg_toplevel
- configure/ack_configure flow
- wl_subcompositor, wl_data_device_manager
- foot terminal conectada y renderizando ventana
- Doble buffer con offset correcto

## 🔄 Fase 5: wl_seat — teclado y puntero
- wl_keyboard con xkb keymaps
- wl_pointer con enter/leave/motion/button
- Foco de ventana
- foot recibe input y muestra prompt

## 📋 Fase 6: Window management
- Mover ventanas con mouse
- Stack/raise de ventanas
- Múltiples clientes simultáneos
- Cerrar ventanas

## 📋 Fase 7: Configuración Lua
- Embeber Lua (~200KB)
- keybinds configurables
- gaps, colores, layouts
- spawn de aplicaciones

## 📋 Fase 8: Layout engine
- Tiling automático
- Scrolling layout (inspirado en PaperWM)
- Floating mode

## Stack técnico
| Capa | Tecnología |
|------|-----------|
| Lenguaje | Zig 0.16 |
| Display | /dev/fb0 directo |
| Input | /dev/input/eventX |
| Protocolo | Wayland wire format manual |
| Config | Lua (Fase 7) |
| Deps | Zero |
