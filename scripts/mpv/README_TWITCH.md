# mpv-twitch-setup: Twitch fluido y en baja latencia con `mpv`

Configuración optimizada e instalador automatizado para ver streams en vivo de **Twitch** en Linux con `mpv`, priorizando mínima latencia respecto al directo y fluidez de imagen sin anuncios que rompan la reproducción.

---

## 1. Por qué Twitch se configura distinto que Kick

Aunque `mpv` puede abrir enlaces de Twitch usando `yt-dlp`, en Twitch directo suele quedarse ~10–15 segundos atrás del vivo y presentar desincronización o cortes cuando aparecen anuncios incrustados en el flujo HLS.

Por eso este proyecto utiliza **`streamlink` + `mpv`** como motor principal (y deja `yt-dlp` únicamente como respaldo automático):
- **`--twitch-low-latency`**: predescarga segmentos *prefetch* (`EXT-X-TWITCH-PREFETCH`) de Twitch y reduce el borde en vivo a 2 segmentos.
- **`--player-fifo`**: envía el flujo por una tubería FIFO con nombre en vez de `stdin`, evitando cierres inesperados con *Enhanced Broadcasting* (fMP4) en versiones recientes de FFmpeg.
- **Filtrado de anuncios HLS**: Streamlink 7.5+ filtra automáticamente segmentos publicitarios; en versiones anteriores, el comando añade `--twitch-disable-ads` de forma automática.
- **Fluidez en `mpv`**: `vo=gpu-next`, `hwdec=auto-safe`, `video-sync=display-resample`, `interpolation=yes` y `tscale=oversample` para evitar tirones incluso en monitores de 75 Hz o frecuencias no múltiples de 60 fps.

> **Nota sobre FreeSync / Adaptive Sync (VRR):** Si tenés VRR activado en tu entorno de escritorio (por ejemplo KDE Plasma en Wayland) y notás frames perdidos con `display-resample`, cambiá `video-sync=display-resample` por `video-sync=audio` y eliminá `interpolation=yes`.

---

## 2. Perfiles incluidos en `$HOME/.config/mpv/mpv.conf`

| Perfil | Motor | Búfer en `mpv` | Uso recomendado |
| :--- | :---: | :---: | :--- |
| `[twitch]` | `streamlink` (`live-edge=2`) | `2s` (`cache-pause=yes`) | Uso diario (~2–3s detrás del vivo, muy estable). |
| `[twitch-realtime]` | `streamlink` (`live-edge=1`) | `1s` (`cache-pause=no`) | Latencia mínima para leer el chat al segundo en conexiones por cable/fibra. |
| `[twitch-ytdl]` | `yt-dlp` (respaldo) | `5s` (`live_start_index=-2`) | Fallback automático si `streamlink` no está instalado. |

---

## 3. Instalación y uso

### Requisitos
- `mpv`
- `streamlink` *(altamente recomendado para baja latencia en Twitch)*
- `yt-dlp` *(opcional, usado como respaldo si falta `streamlink`)*
- `bash`

### Instalación automática
```bash
chmod +x setup_mpv_twitch.sh
./setup_mpv_twitch.sh
source "$HOME/.bashrc"
```

*(Es totalmente compatible con `setup_mpv_kick.sh`: usa bloques de marcadores independientes y no sobrescribe tus perfiles de Kick ni otras configuraciones previas).*

### Uso diario
```bash
# Modo estándar (baja latencia estable)
twitch nombre_del_canal

# Modo tiempo real (mínima latencia posible)
twitch -r nombre_del_canal

# Elegir calidad específica (ej. 1080p60, 720p60, best)
twitch -q 720p60 nombre_del_canal

# También acepta URLs completas
twitch https://www.twitch.tv/nombre_del_canal
```

### Desinstalación
```bash
./setup_mpv_twitch.sh --uninstall
```

### Atajos útiles dentro de `mpv`
- **`Shift + i`** seguido de **`2`**: muestra frames perdidos o desincronizados (`Dropped` / `Mistimed`).
- **`Shift + i`** seguido de **`3`**: muestra el estado de la caché en tiempo real.
- **`]`** y luego **`Backspace`**: acelera momentáneamente la reproducción para recuperar el borde en vivo si pausaste el stream, y vuelve a `1.0x`.

### Solución de problemas

### Error `Urllib3UtilUrlPercentReOverride has no attribute 'sub'` en Streamlink
Si al ejecutar `twitch <canal>` aparece un error similar a este:

error: Unable to open URL: https://gql.twitch.tv/gql (type object 'Urllib3UtilUrlPercentReOverride' has no attribute 'sub')

Causa: Incompatibilidad conocida entre versiones de streamlink iguales o
inferiores a 8.6.0 y urllib3 2.8.0 (frecuente en distribuciones actualizadas
como Fedora / Nobara 44). Fue corregido a partir de streamlink 8.6.1.

Solución 1 — Actualizar streamlink desde los repositorios (Fedora / Nobara):

sudo dnf upgrade --refresh streamlink python3-streamlink

(En otras distribuciones, actualizá streamlink a la versión 8.6.1 o superior con
tu gestor de paquetes).

Solución 2 — Instalar la última versión oficial aislada con pipx (si el repo de
tu distro aún no se actualizó):

pipx install streamlink
pipx ensurepath

Luego reiniciá la terminal y verificá con streamlink --version que muestre 8.6.1
o superior.

---

## 4. Código completo (`setup_mpv_twitch.sh`)

```bash
#!/usr/bin/env bash
# Instalador portátil de perfiles de mpv optimizados para Twitch (vía Streamlink o yt-dlp)
# y función `twitch <canal>` para Bash.

OUTPUT_BASE_DIR="${OUTPUT_BASE_DIR:-$HOME}"
set -euo pipefail

MPV_DIR="$OUTPUT_BASE_DIR/.config/mpv"
MPV_CONF="$MPV_DIR/mpv.conf"
BASHRC_FILE="$OUTPUT_BASE_DIR/.bashrc"

MARKER_START="# >>> mpv-twitch-setup >>>"
MARKER_END="# <<< mpv-twitch-setup <<<"

print_usage() {
    cat << 'EOF'
Uso: ./setup_mpv_twitch.sh [opción]

Opciones:
  (sin opciones)   Instala o actualiza los perfiles [twitch], [twitch-realtime] y [twitch-ytdl]
                   en mpv.conf y la función `twitch` en .bashrc.
  --uninstall      Elimina la configuración instalada por este script.
  -h, --help       Muestra esta ayuda.
EOF
}

check_dependencies() {
    if ! command -v mpv >/dev/null 2>&1; then
        echo "[AVISO] No se encontró 'mpv' en el PATH. Instalalo antes de usar el comando."
    else
        echo "[OK] mpv detectado."
    fi

    if command -v streamlink >/dev/null 2>&1; then
        echo "[OK] streamlink detectado (se usará modo baja latencia nativo de Twitch)."
    else
        echo "[AVISO] No se encontró 'streamlink'. Se recomienda instalarlo para baja latencia en Twitch."
        if command -v yt-dlp >/dev/null 2>&1; then
            echo "        Se detectó 'yt-dlp': la función 'twitch' lo usará como respaldo automático."
        else
            echo "        Tampoco se encontró 'yt-dlp'. Instalá 'streamlink' (recomendado) o 'yt-dlp'."
        fi
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

    if ! grep -Fq "$MARKER_START" "$MPV_CONF" && grep -Eq '^\[(twitch|twitch-realtime|twitch-ytdl)\]' "$MPV_CONF"; then
        echo "[AVISO] Ya existe un perfil [twitch] manual en $MPV_CONF fuera del bloque gestionado."
        echo "        Revisalo si notás conflictos después de instalar."
    fi

    backup_file "$MPV_CONF"
    remove_managed_block "$MPV_CONF"

    cat << 'EOF' >> "$MPV_CONF"
# >>> mpv-twitch-setup >>>
[twitch]
vo=gpu-next
hwdec=auto-safe
vd-lavc-threads=0
video-sync=display-resample
interpolation=yes
tscale=oversample
framedrop=vo
force-window=immediate
cache=yes
cache-secs=2
demuxer-max-bytes=32MiB
demuxer-max-back-bytes=16MiB
cache-pause=yes
cache-pause-initial=no
cache-pause-wait=1

[twitch-realtime]
vo=gpu-next
hwdec=auto-safe
vd-lavc-threads=0
video-sync=display-resample
interpolation=yes
tscale=oversample
framedrop=vo
force-window=immediate
cache=yes
cache-secs=1
demuxer-max-bytes=32MiB
demuxer-max-back-bytes=16MiB
cache-pause=no
cache-pause-initial=no

[twitch-ytdl]
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
# <<< mpv-twitch-setup <<<
EOF

    echo "[OK] Perfiles [twitch], [twitch-realtime] y [twitch-ytdl] instalados en $MPV_CONF"
}

install_bash_function() {
    touch "$BASHRC_FILE"
    backup_file "$BASHRC_FILE"
    remove_managed_block "$BASHRC_FILE"

    cat << 'EOF' >> "$BASHRC_FILE"
# >>> mpv-twitch-setup >>>
twitch() {
    local profile="twitch"
    local realtime=0
    local quality="best"
    local target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--realtime)
                profile="twitch-realtime"
                realtime=1
                shift
                ;;
            -q|--quality)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: falta el valor para $1 (ej. best, 1080p60, 720p60)." >&2
                    return 1
                fi
                quality="$2"
                shift 2
                ;;
            -h|--help)
                echo "Uso: twitch [-r|--realtime] [-q|--quality <calidad>] <canal|url>"
                echo "Ejemplo: twitch -r -q 1080p60 ibai"
                return 0
                ;;
            *)
                target="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$target" ]]; then
        echo "Uso: twitch [-r|--realtime] [-q|--quality <calidad>] <canal|url>"
        return 1
    fi

    if [[ "$target" != http://* && "$target" != https://* ]]; then
        target="https://www.twitch.tv/${target#/}"
    fi

    if command -v streamlink >/dev/null 2>&1; then
        local sl_args=(
            --twitch-low-latency
            --player=mpv
            --player-fifo
            --player-args="--profile=$profile"
        )
        if [[ "$realtime" -eq 1 ]]; then
            sl_args+=(--hls-live-edge=1)
        fi
        if streamlink --help 2>/dev/null | grep -Fq -- "--twitch-disable-ads"; then
            sl_args+=(--twitch-disable-ads)
        fi
        streamlink "${sl_args[@]}" "$target" "$quality"
    else
        echo "[AVISO] 'streamlink' no encontrado; usando yt-dlp (mayor latencia)." >&2
        mpv --profile=twitch-ytdl "$target"
    fi
}
# <<< mpv-twitch-setup <<<
EOF

    echo "[OK] Función 'twitch' agregada a $BASHRC_FILE"
}

uninstall_all() {
    backup_file "$MPV_CONF"
    remove_managed_block "$MPV_CONF"
    backup_file "$BASHRC_FILE"
    remove_managed_block "$BASHRC_FILE"
    echo "[OK] Configuración de mpv-twitch-setup eliminada."
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
            echo "  twitch <canal>"
            echo "  twitch -r <canal>          # Modo ultra-cerca para chat en tiempo real"
            echo "  twitch -q 720p60 <canal>   # Elegir calidad específica"
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

---

## 5. Verificación previa al commit
```bash
bash -n setup_mpv_twitch.sh
grep -rn '/home/' . --exclude-dir=.git
```
