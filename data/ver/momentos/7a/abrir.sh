#!/usr/bin/env bash
# abrir.sh — Menú interactivo para abrir un momento en el navegador.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

if [[ ! -d "$DATA" ]] || [[ -z "$(listar_streamers)" ]]; then
    echo "Sin datos aún. Agregá líneas a momentos.txt y corré ./momento.sh"
    exit 0
fi

while true; do
    set +e
    menu_streamers "=== Abrir — Streamers ===" "s"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] && exit 0

    filtro=""
    modo="todos"
    if [[ "$SELECCION" != "__ALL__" ]]; then
        filtro="$SELECCION"
        modo="streamer"
    fi

    while true; do
        set +e
        menu_momentos "=== Abrir — Momentos ===" "$filtro" "n" "$modo"
        rc=$?
        set -e

        if [[ $rc -eq 2 ]]; then
            break
        elif [[ $rc -ne 0 ]]; then
            exit 0
        fi

        IFS="$SEP" read -r _ streamer secs minuto desc url fecha fecha_iso relpath <<< "$SELECCION_LINEA"
        base_url="$(limpiar_url "$url")"
        target="${base_url}#t=${secs}"

        if abrir_en_navegador "$target"; then
            set_estado ok "✓ Abriendo: [$fecha — $streamer — $minuto] $desc"
        else
            set_estado warn "Abrí manualmente: $target"
        fi
    done
done
