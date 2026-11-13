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
