# wallflow

Rotación de video-wallpapers para **Omarchy** (Hyprland + quickshell) con theming
vivo, modo juego, selector visual y reset del countdown automático.

Nombre corto para: **wall**paper **flow** — el flujo completo de fondos de
pantalla del escritorio.

## Qué hace

| Pieza | Qué hace | Cómo se usa |
|---|---|---|
| `video-wallpaper-rotator.sh` | Elige un video random de `~/Wallpapers`, extrae frame versionado, genera `colors.toml` del tema `video-dark` con el color dominante, escribe `~/.config/displaywright/wallpapers.json` (los 3+ monitores, fix animación), lanza `mpvpaper` por salida | systemd timer cada 2h |
| `rotate-wall` | Aplica un video específico + **reinicia el countdown** del timer (marcador `.skip-once` + activación del servicio) | `SUPER+ALT+W` o `rotate-wall nombre.mp4` |
| `gamemode-toggle.sh` | Congela el frame actual en TODOS los monitores (displaywright), apaga blur/animaciones, congela rotación; al desactivar restaura todo y reinicia el countdown | botón gamepad en la barra (plugin `cristiansrc.gamemode`, incluido) |
| `cristiansrc.wallpicker` | Overlay grid con miniaturas de `~/Wallpapers`, búsqueda en vivo, badge del actual, entrada escalonada; click → pipeline completo | `SUPER+ALT+P` |
| `video-dark` (tema) | Dark base; `colors.toml` se regenera con el color dominante de cada video | automático |

Detalles clave:

- **Frames versionados** (`~/.local/state/omarchy/video-wallpaper/frames/<video>-<hash>.jpg`): cada video
  genera un path único → displaywright detecta el cambio (`signatureOf`) → la animación wipe corre en cada
  rotación, no solo tras boot.
- **Sin flash de wallpaper viejo**: el frame nuevo se extrae ANTES de matar `mpvpaper`; el update de
  displaywright va después del kill y antes del relanzamiento (sleep 0.45 para el wipe de 420ms).
- **NVIDIA**: `pkill -KILL` (SIGTERM crashea el teardown EGL de libGLX_nvidia) + `hwdec=no
  gpu-context=waylandvk` (decode por software, presentación acelerada).
- **Countdown**: toda rotación manual activa el servicio systemd con marcador skip → el
  `OnUnitActiveSec=2h` cuenta desde el último cambio (manual o automático).
- **Game mode**: usa `pkill -KILL` igual, respaldo del `wallpapers.json` de displaywright y restauración
  exacta al salir; pre-genera el frame del modo juego en cada rotación para que el toggle sea instantáneo.

## Instalación

Requisitos: Omarchy 4.x, Hyprland; deps: `mpvpaper ffmpeg imagemagick python` (el instalador verifica).
Se recomienda tener [displaywright](https://github.com/BlackKingBarOrg/displaywright) instalado
(fondo estático del modo juego + animación wipe); el instalador avisa si falta.

```bash
./install.sh                # instala y recarga sesión (hyprctl reload + shell restart)
```

Idempotente: re-correrlo actualiza sin duplicar binds ni entradas de `shell.json`.

## Uso

```bash
SUPER+ALT+W          # siguiente video random (y resetea las 2h)
SUPER+ALT+P          # selector visual → click en un video
rotate-wall          # igual que el hotkey, desde terminal
rotate-wall "Wallpaper (100).mp4"   # aplica ese video puntual
rotate-wall /ruta/video.mp4         # ruta absoluta también sirve
```

El timer automático (`video-wallpaper.timer`) rota cada 2h. `systemctl --user list-timers
video-wallpaper.timer` muestra el próximo cambio.

## Estructura

```
wallflow/
├── install.sh                  instalador idempotente (--remove soportado)
├── bin/
│   ├── video-wallpaper-rotator.sh   núcleo (rotación + theming + displaywright + mpvpaper)
│   ├── rotate-wall                    entrada manual + reset countdown
│   └── gamemode-toggle.sh             modo juego (toggle del botón de la barra)
├── systemd/user/
│   ├── video-wallpaper.service        oneshot (rotator)
│   └── video-wallpaper.timer          cada 2h, Persistent
├── theme/video-dark/               skeleton del tema (colors.toml dinámico)
└── omarchy/plugin/
    ├── cristiansrc.wallpicker/        overlay picker (QML + scripts)
    └── cristiansrc.gamemode/          botón modo juego (bar-widget)
```

## Desinstalar

```bash
./install.sh --remove
```

Deja `~/Wallpapers`, el estado (`~/.local/state/omarchy/{video-wallpaper,game-mode}`) y el cache de
miniaturas (`~/.cache/wallpicker`) intactos. Borralos a mano si querés limpieza total.

## Troubleshooting

- **No rota / timer no dispara**: `systemctl --user list-timers video-wallpaper.timer`,
  `journalctl --user -u video-wallpaper.service -e`
- **Crash de mpvpaper al rotar (NVIDIA)**: verificar que el rotator usa `hwdec=no
  gpu-context=waylandvk` y `pkill -KILL` (no SIGTERM)
- **Modo juego deja fondo viejo en un monitor**: displaywright instalado? El modo juego escribe
  `~/.config/displaywright/wallpapers.json` para todos los monitores detectados por `hyprctl`
- **Picker sin miniaturas la primera vez**: se generan en vivo (cache en `~/.cache/wallpicker`);
  la segunda apertura es instantánea
- **Editaste WallPicker.qml y no cambia**: el shell cachea el overlay → `omarchy restart shell`
- **Marcador skip-once huérfano** (no debería pasar): borrar
  `~/.local/state/omarchy/video-wallpaper/.skip-once`
