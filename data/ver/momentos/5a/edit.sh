#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

if [[ ! -d "$DATA" ]] || [[ -z "$(ls -A "$DATA" 2>/dev/null)" ]]; then
    echo "Sin datos aún. Agregá líneas a momentos.txt y corré ./momento.sh"
    exit 0
fi

pedir_timestamp() {
    while true; do
        read -rp "Nuevo minuto (ej. 1:45 o 0:05:30, 'v' volver, 's' salir): " nuevo
        case "$nuevo" in
            v|V) return 2 ;;
            s|S) return 3 ;;
        esac
        if [[ "$nuevo" =~ ^([0-9]+):([0-9]+)$ ]]; then
            h=0; m="${BASH_REMATCH[1]}"; s="${BASH_REMATCH[2]}"
        elif [[ "$nuevo" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
            h="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; s="${BASH_REMATCH[3]}"
        else
            echo "Formato inválido."
            continue
        fi
        if (( 10#$m > 59 || 10#$s > 59 )); then
            echo "Fuera de rango (minutos y segundos <= 59)."
            continue
        fi
        total=$(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
        NUEVO_MINUTO="$(formatear_minuto "$nuevo")"
        NUEVO_TOTAL="$total"
        return 0
    done
}

tmp=""
trap 'rm -f "${tmp:-}"' EXIT

# Bucle principal: streamer → momento → editar
while true; do
    set +e
    menu_streamers "=== Editar — Streamers ===" "s"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] && exit 0

    filtro=""
    [[ "$SELECCION" != "__ALL__" ]] && filtro="$SELECCION"

    # Bucle de selección de momento + edición
    while true; do
        tmp="$(cargar_momentos "$filtro")"
        set +e
        if [[ -z "$filtro" ]]; then
            menu_momentos "=== Editar — Momentos ===" "$tmp" "n" "todos"
        else
            menu_momentos "=== Editar — Momentos ===" "$tmp" "n" "streamer"
        fi
        rc=$?
        set -e
        if [[ $rc -eq 2 ]]; then
            break
        elif [[ $rc -eq 3 || $rc -ne 0 ]]; then
            exit 0
        fi

        IFS='|' read -r _ streamer secs_old minuto_old desc url fecha fecha_iso <<<"$SELECCION_LINEA"

        # Si vienes de una edición, mostrar mensaje
        if [[ -n "${EDIT_MSG:-}" ]]; then
            echo
            echo "$EDIT_MSG"
            echo "URL: ${EDIT_URL:-}"
            EDIT_MSG=""
            EDIT_URL=""
        fi

        NUEVO_MINUTO=""
        NUEVO_TOTAL=""
        set +e
        pedir_timestamp
        rc=$?
        set -e
        if [[ $rc -eq 2 ]]; then
            continue
        elif [[ $rc -eq 3 || $rc -ne 0 ]]; then
            exit 0
        fi

        archivo=""
        while IFS= read -r f; do
            f_url="$(grep -m1 '^\*\*URL:\*\*' "$f" | sed 's/^\*\*URL:\*\* //')"
            [[ "$f_url" != "$url" ]] && continue
            if grep -q "^| $secs_old | $minuto_old | $desc |" "$f"; then
                archivo="$f"
                break
            fi
        done < <(find "$DATA/$streamer" -type f -name '*.md' 2>/dev/null)

        if [[ -z "$archivo" ]]; then
            echo "No se encontró el archivo del video. Abortando." >&2
            exit 1
        fi

        tmp_file="$(mktemp)"
        head -n 7 "$archivo" > "$tmp_file"
        tail -n +8 "$archivo" | awk -F'|' -v old_secs="$secs_old" -v old_min="$minuto_old" -v old_desc="$desc" \
            -v new_secs="$NUEVO_TOTAL" -v new_min="$NUEVO_MINUTO" '
            {
                s=$2; gsub(/^ +| +$/,"",s);
                mi=$3; gsub(/^ +| +$/,"",mi);
                d=$4; gsub(/^ +| +$/,"",d);
                if (s==old_secs && mi==old_min && d==old_desc) {
                    printf "| %s | %s | %s |\n", new_secs, new_min, old_desc
                } else {
                    print
                }
            }' >> "$tmp_file"
        mv "$tmp_file" "$archivo"

        # no reordenar por minuto: se respeta orden por fecha / modificación
        EDIT_MSG="Editado: $streamer $minuto_old -> $NUEVO_MINUTO ($desc)"
        EDIT_URL="$url"
    done
done
