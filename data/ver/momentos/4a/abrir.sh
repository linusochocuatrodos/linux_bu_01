#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

if [[ ! -d "$DATA" ]] || [[ -z "$(ls -A "$DATA" 2>/dev/null)" ]]; then
    echo "Sin datos aún. Agregá líneas a momentos.txt y corré ./momento.sh"
    exit 0
fi

tmp=""
trap 'rm -f "${tmp:-}"' EXIT

while true; do
    set +e
    menu_streamers "=== Streamers ===" "s"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] && exit 0

    filtro=""
    [[ "$SELECCION" != "__ALL__" ]] && filtro="$SELECCION"

    while true; do
        tmp="$(cargar_momentos "$filtro")"
        set +e
        if [[ -z "$filtro" ]]; then
            menu_momentos "=== Momentos ===" "$tmp" "n" "todos"
        else
            menu_momentos "=== Momentos ===" "$tmp" "n" "streamer"
        fi
        rc=$?
        set -e
        if [[ $rc -eq 2 ]]; then
            break
        elif [[ $rc -eq 3 || $rc -ne 0 ]]; then
            exit 0
        fi

        IFS='|' read -r _ streamer secs minuto desc url fecha fecha_iso <<<"$SELECCION_LINEA"
        target="${url}#t=${secs}"
        abrir_en_navegador "$target" || true
    done
done
