#!/usr/bin/env bash
# edit.sh — Editar el timestamp de un momento guardado.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

if [[ ! -d "$DATA" ]] || [[ -z "$(ls -A "$DATA" 2>/dev/null)" ]]; then
    echo "Sin datos aún. Agregá líneas a momentos.txt y corré ./momento.sh"
    exit 0
fi

# Pide un nuevo timestamp al usuario.
# Muestra el nombre/descripción del momento que se está editando.
# $1 = descripción del momento actual (para mostrar al usuario)
# $2 = timestamp actual (para mostrarlo)
# Variables de salida: NUEVO_MINUTO, NUEVO_TOTAL
# Retorna: 0=ok, 2=volver, 3=salir
pedir_timestamp() {
    local desc_actual="$1"
    local minuto_actual="$2"
    local nuevo rc=0

    while true; do
        printf '\nEditando: "%s"  [actual: %s]\n' "$desc_actual" "$minuto_actual"
        read -rp "Nuevo minuto (ej. 1:45 o 0:05:30, 'v' volver, 's' salir): " nuevo || { return 3; }
        case "$nuevo" in
            v|V) return 2 ;;
            s|S) return 3 ;;
        esac
        local total
        if ! total="$(timestamp_a_segundos "$nuevo")"; then
            echo "Formato inválido o fuera de rango (minutos y segundos <= 59)."
            continue
        fi
        NUEVO_MINUTO="$(formatear_minuto "$nuevo")"
        NUEVO_TOTAL="$total"
        return 0
    done
}

# Busca el archivo .md que contiene el momento y lo actualiza.
# Identifica la fila por URL, segundos y descripción (evita problemas de formato del minuto).
# $1=streamer $2=secs_old $3=desc $4=url
editar_en_archivo() {
    local streamer="$1" secs_old="$2" desc="$3" url="$4"
    local archivo="" f f_url
    while IFS= read -r f; do
        f_url="$(grep -m1 '^\*\*URL:\*\*' "$f" | sed 's/^\*\*URL:\*\* //')"
        [[ "$f_url" != "$url" ]] && continue
        if grep -qF "| $secs_old |" "$f" && grep -qF "| $desc |" "$f"; then
            archivo="$f"
            break
        fi
    done < <(find "$DATA/$streamer" -type f -name '*.md' 2>/dev/null)

    if [[ -z "$archivo" ]]; then
        echo "No se encontró el archivo del video. Abortando." >&2
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    head -n 7 "$archivo" > "$tmp_file"
    tail -n +8 "$archivo" | awk -F'|' \
        -v old_secs="$secs_old" -v old_desc="$desc" \
        -v new_secs="$NUEVO_TOTAL" -v new_min="$NUEVO_MINUTO" '
        {
            s=$2; gsub(/^ +| +$/,"",s)
            d=$4; gsub(/^ +| +$/,"",d)
            if (s==old_secs && d==old_desc)
                printf "| %s | %s | %s |\n", new_secs, new_min, old_desc
            else
                print
        }' >> "$tmp_file"
    mv "$tmp_file" "$archivo"
}

# ---------------------------------------------------------------------------
# Bucle principal: streamer → momento → pedir timestamp → editar
# ---------------------------------------------------------------------------
tmp=""
trap 'rm -f "${tmp:-}"' EXIT

while true; do
    set +e
    menu_streamers "=== Editar — Streamers ===" "s"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] && exit 0

    filtro=""
    [[ "$SELECCION" != "__ALL__" ]] && filtro="$SELECCION"

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
        rm -f "$tmp"; tmp=""

        if [[ $rc -eq 2 ]]; then
            break
        elif [[ $rc -ne 0 ]]; then
            exit 0
        fi

        # Parsear la selección
        IFS='|' read -r _ streamer secs_old minuto_old desc url fecha fecha_iso <<< "$SELECCION_LINEA"
        minuto_old_fmt="$(formatear_minuto "$minuto_old")"

        NUEVO_MINUTO=""
        NUEVO_TOTAL=""
        set +e
        pedir_timestamp "$desc" "$minuto_old_fmt"
        rc=$?
        set -e

        if [[ $rc -eq 2 ]]; then
            continue   # volver a la lista de momentos
        elif [[ $rc -ne 0 ]]; then
            exit 0
        fi

        set +e
        editar_en_archivo "$streamer" "$secs_old" "$desc" "$url"
        set -e

        echo "✓ Editado: $streamer — \"$desc\"  $minuto_old_fmt → $NUEVO_MINUTO"
    done
done
