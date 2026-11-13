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
