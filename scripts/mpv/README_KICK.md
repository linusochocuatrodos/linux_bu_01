# mpv-kick-setup: Streaming fluido y baja latencia en Kick con `mpv`

Configuración optimizada e instalador automatizado para ver streams en vivo de **Kick** usando `mpv` + `yt-dlp` en Linux, minimizando el retraso respecto al directo sin sacrificar fluidez visual.

---

## 1. Registro del proceso: del problema inicial a la solución final

### 1.1 El problema inicial (atraso acumulado)
El comando original presentaba varios minutos de atraso respecto al stream en vivo:

```bash
mpv --hwdec=auto-safe \
    --cache=yes \
    --cache-secs=60 \
    --demuxer-max-bytes=512MiB \
    --cache-pause=yes \
    --cache-pause-initial=yes \
    --cache-pause-wait=12 \
    "https://kick.com/aquino"
```

**Causas del retraso:**
- `--cache-pause-initial=yes` + `--cache-pause-wait=12` obligaban a `mpv` a esperar 12 segundos antes de iniciar y pausar otros 12 segundos ante cada microcorte.
- `--cache-secs=60` permitía que ese atraso se acumulara indefinidamente.
- Por defecto, el demuxer HLS de FFmpeg arranca 3 segmentos detrás del borde en vivo (`live_start_index=-3`), sumando otros 6 a 12 segundos extra.

### 1.2 Error detectado durante las pruebas (`HTTP 416` / `End of file`)
En una primera iteración se agregaron opciones HTTP de FFmpeg (`reconnect=1`, `reconnect_streamed=1`, `reconnect_on_network_error=1`, `reconnect_delay_max=3`). Esto provocó que el stream se cerrara solo tras ~30–60 segundos con el siguiente error:

```text
[ffmpeg] https: Will reconnect at 1459256 in 0 second(s), error=End of file.
[ffmpeg] https: Unexpected offset: expected 1459256, got 0
[ffmpeg] https: HTTP error 416 Requested Range Not Satisfiable
[ffmpeg/demuxer] hls: Failed to reload playlist 0
Exiting... (End of file)
```

**Causa raíz:**
Kick distribuye HLS mediante Amazon IVS (`live-video.net`). Al finalizar cada playlist o segmento, el servidor cierra la conexión HTTP normalmente (`End of file`). Con `reconnect=1` y `reconnect_streamed=1`, FFmpeg interpretaba ese cierre como una caída e intentaba reanudar pidiendo un rango de bytes (`Range`). Como las playlists dinámicas `.m3u8` no admiten ese rango, el servidor respondía `HTTP 416` o reiniciaba en `0`, rompiendo la recarga del stream.

**Solución:**
- Eliminar todas las opciones `--stream-lavf-o-append=reconnect*`.
- Dejar que el demuxer HLS recargue normalmente usando solo `seg_max_retry=3` y `live_start_index=-2`.
- Ajustar el búfer a `--cache-secs=5` y `--cache-pause-wait=1.5` (en pruebas reales mantuvo ~5 segundos de diferencia con el directo sin cortes).

### 1.3 Ajuste final de fluidez (Wayland, hardware moderno y monitores de 75 Hz / >60 Hz)
Para evitar tirones de fotogramas (*judder*) cuando un stream a `59.94 fps` se reproduce en monitores de distinta frecuencia (por ejemplo `75 Hz`), y para aprovechar decodificación por hardware sin copias innecesarias:
- `vo=gpu-next` + `hwdec=auto-safe`: utiliza el renderizador moderno de `mpv` y elige automáticamente Vulkan Video / VA-API / NVDEC según la GPU.
- `video-sync=display-resample` + `interpolation=yes` + `tscale=oversample`: suaviza únicamente la cadencia entre los FPS del video y los Hz del monitor, sin efecto "telenovela".
- `force-window=immediate` + `ytdl_hook-try_ytdl_first=yes`: abre la ventana al instante mientras `yt-dlp` resuelve el stream.

> **Nota sobre FreeSync / Adaptive Sync (VRR):** Si tenés VRR activado en tu escritorio (por ejemplo KDE Plasma en Wayland) y notás frames perdidos con `display-resample`, cambiá `video-sync=display-resample` por `video-sync=audio` y quitá `interpolation=yes`.

---

## 2. Perfiles incluidos

| Perfil | `live_start_index` | `cache-secs` | `cache-pause` | Uso recomendado |
| :--- | :---: | :---: | :---: | :--- |
| `[kick]` | `-2` | `5` | `yes` (`1.5s`) | Balance ideal (~4–5s detrás del vivo, muy estable). |
| `[kick-realtime]` | `-1` | `3` | `no` | Mínima latencia (~2–3s para leer el chat) en conexiones por cable/fibra estables. |

---

## 3. Instalación y uso

### Requisitos
- `mpv`
- `yt-dlp`
- `bash`

### Instalación automática
```bash
chmod +x setup_mpv_kick.sh
./setup_mpv_kick.sh
source "$HOME/.bashrc"
```

### Uso diario
```bash
# Modo estándar (estable, ~4-5s de latencia)
kick aquino

# Modo tiempo real (mínima latencia para chat)
kick -r aquino

# También acepta URLs completas
kick https://kick.com/aquino
```

### Desinstalación
```bash
./setup_mpv_kick.sh --uninstall
```

### Atajos útiles dentro de `mpv`
- **`Shift + i`** seguido de **`2`**: muestra estadísticas de frames perdidos o desincronizados (`Dropped` / `Mistimed`).
- **`Shift + i`** seguido de **`3`**: muestra el estado de la caché en tiempo real.
- **`]`** y luego **`Backspace`**: acelera momentáneamente a `1.1x`/`1.2x` para alcanzar la cola del vivo si pausaste el stream, y vuelve a `1.0x`.

---

## 4. Código completo

### 4.1 Script automatizado (`setup_mpv_kick.sh`)

```bash
#!/usr/bin/env bash
# Instalador portátil de perfiles de mpv optimizados para streams en vivo de Kick
# y función `kick <canal>` para Bash.

OUTPUT_BASE_DIR="${OUTPUT_BASE_DIR:-$HOME}"
set -euo pipefail

MPV_DIR="$OUTPUT_BASE_DIR/.config/mpv"
MPV_CONF="$MPV_DIR/mpv.conf"
BASHRC_FILE="$OUTPUT_BASE_DIR/.bashrc"

MARKER_START="# >>> mpv-kick-setup >>>"
MARKER_END="# <<< mpv-kick-setup <<<"

print_usage() {
    cat << 'EOF'
Uso: ./setup_mpv_kick.sh [opción]

Opciones:
  (sin opciones)   Instala o actualiza los perfiles [kick] y [kick-realtime] en mpv.conf
                   y la función `kick` en .bashrc.
  --uninstall      Elimina la configuración instalada por este script.
  -h, --help       Muestra esta ayuda.
EOF
}

check_dependencies() {
    local missing=0
    for cmd in mpv yt-dlp; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "[AVISO] No se encontró '$cmd' en el PATH. Instalalo antes de usar el comando."
            missing=1
        fi
    done

    if [[ "$missing" -eq 0 ]]; then
        echo "[OK] Dependencias detectadas: mpv y yt-dlp."
    fi
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -p "$file" "$backup"
        echo "[OK] Backup creado: $backup"
    fi
}

remove_managed_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    if grep -Fq "$MARKER_START" "$file"; then
        local tmp_file
        tmp_file="$(mktemp)"
        awk -v start="$MARKER_START" -v end="$MARKER_END" '
            $0 == start { skip=1; next }
            $0 == end   { skip=0; next }
            !skip { print }
        ' "$file" > "$tmp_file"
        cat "$tmp_file" > "$file"
        rm -f "$tmp_file"
    fi
}

install_mpv_profiles() {
    mkdir -p "$MPV_DIR"
    touch "$MPV_CONF"

    if ! grep -Fq "$MARKER_START" "$MPV_CONF" && grep -Eq '^\[(kick|kick-realtime)\]' "$MPV_CONF"; then
        echo "[AVISO] Ya existe un perfil [kick] manual en $MPV_CONF fuera del bloque gestionado."
        echo "        Revisalo si notás conflictos después de instalar."
    fi

    backup_file "$MPV_CONF"
    remove_managed_block "$MPV_CONF"

    cat << 'EOF' >> "$MPV_CONF"
# >>> mpv-kick-setup >>>
[kick]
vo=gpu-next
hwdec=auto-safe
vd-lavc-threads=0
video-sync=display-resample
interpolation=yes
tscale=oversample
framedrop=vo
force-window=immediate
cache=yes
cache-secs=5
demuxer-max-bytes=64MiB
demuxer-max-back-bytes=32MiB
cache-pause=yes
cache-pause-initial=no
cache-pause-wait=1.5
hls-bitrate=max
network-timeout=10
demuxer-lavf-o-append=live_start_index=-2
demuxer-lavf-o-append=seg_max_retry=3
script-opts-append=ytdl_hook-try_ytdl_first=yes

[kick-realtime]
vo=gpu-next
hwdec=auto-safe
vd-lavc-threads=0
video-sync=display-resample
interpolation=yes
tscale=oversample
framedrop=vo
force-window=immediate
cache=yes
cache-secs=3
demuxer-max-bytes=64MiB
demuxer-max-back-bytes=32MiB
cache-pause=no
cache-pause-initial=no
hls-bitrate=max
network-timeout=10
demuxer-lavf-o-append=live_start_index=-1
demuxer-lavf-o-append=seg_max_retry=3
script-opts-append=ytdl_hook-try_ytdl_first=yes
# <<< mpv-kick-setup <<<
EOF

    echo "[OK] Perfiles [kick] y [kick-realtime] instalados en $MPV_CONF"
}

install_bash_function() {
    touch "$BASHRC_FILE"
    backup_file "$BASHRC_FILE"
    remove_managed_block "$BASHRC_FILE"

    cat << 'EOF' >> "$BASHRC_FILE"
# >>> mpv-kick-setup >>>
kick() {
    local profile="kick"
    local target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--realtime)
                profile="kick-realtime"
                shift
                ;;
            -h|--help)
                echo "Uso: kick [-r|--realtime] <canal|url>"
                return 0
                ;;
            *)
                target="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$target" ]]; then
        echo "Uso: kick [-r|--realtime] <canal|url>"
        return 1
    fi

    if [[ "$target" != http://* && "$target" != https://* ]]; then
        target="https://kick.com/${target#/}"
    fi

    mpv --profile="$profile" "$target"
}
# <<< mpv-kick-setup <<<
EOF

    echo "[OK] Función 'kick' agregada a $BASHRC_FILE"
}

uninstall_all() {
    backup_file "$MPV_CONF"
    remove_managed_block "$MPV_CONF"
    backup_file "$BASHRC_FILE"
    remove_managed_block "$BASHRC_FILE"
    echo "[OK] Configuración de mpv-kick-setup eliminada."
}

main() {
    case "${1:-}" in
        "")
            check_dependencies
            install_mpv_profiles
            install_bash_function
            echo ""
            echo "Listo. Recargá tu shell o ejecutá:"
            echo "  source \"$BASHRC_FILE\""
            echo "Luego probá con:"
            echo "  kick <canal>"
            echo "  kick -r <canal>   # Modo ultra-cerca para leer chat en tiempo real"
            ;;
        --uninstall)
            uninstall_all
            ;;
        -h|--help)
            print_usage
            ;;
        *)
            echo "Opción no reconocida: $1" >&2
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
```

### 4.2 Verificación previa antes de subir al repositorio
```bash
bash -n setup_mpv_kick.sh
grep -rn '/home/' . --exclude-dir=.git
```
