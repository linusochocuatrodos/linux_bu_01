#!/usr/bin/env bash
# remover.sh — Menú interactivo para eliminar momentos.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

if [[ ! -d "$DATA" ]] || [[ -z "$(ls -A "$DATA" 2>/dev/null)" ]]; then
    echo "Sin datos aún. Agregá líneas a momentos.txt y corré ./momento.sh"
    exit 0
fi

# Elimina una línea del archivo .md que corresponde al momento.
# Busca por URL, segundos y descripción (el minuto puede tener variaciones de formato).
quitar_momento() {
    local streamer="$1" secs="$2" desc="$3" url="$4"
    local archivo="" f f_url
    while IFS= read -r f; do
        f_url="$(grep -m1 '^\*\*URL:\*\*' "$f" | sed 's/^\*\*URL:\*\* //')"
        [[ "$f_url" != "$url" ]] && continue
        if grep -qF "| $secs |" "$f" && grep -qF "| $desc |" "$f"; then
            archivo="$f"
            break
        fi
    done < <(find "$DATA/$streamer" -type f -name '*.md' 2>/dev/null)

    if [[ -z "$archivo" ]]; then
        echo "No se encontró el archivo. Abortando." >&2
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    head -n 7 "$archivo" > "$tmp_file"
    tail -n +8 "$archivo" | awk -F'|' -v s="$secs" -v d="$desc" '
        {
            sf=$2; gsub(/^ +| +$/,"",sf)
            df=$4; gsub(/^ +| +$/,"",df)
            if (sf=="Segundos" || sf=="") next
            if (sf==s && df==d) next
            print
        }' >> "$tmp_file"
    mv "$tmp_file" "$archivo"

    # Si el archivo quedó solo con el header (7 líneas), eliminarlo
    if [[ "$(wc -l < "$archivo")" -le 7 ]]; then
        rm "$archivo"
        rmdir "$DATA/$streamer" 2>/dev/null || true
    fi

    if [[ -z "$(listar_streamers)" ]]; then
        echo "No quedan streamers guardados."
        exit 0
    fi
}

eliminar_todos_de_streamer() {
    local sub="$1"
    local count
    count=$(find "$DATA/$sub" -type f -name '*.md' 2>/dev/null | wc -l)
    echo
    echo "Vas a eliminar TODOS los momentos de: $sub ($count archivo(s))"
    set +e
    confirmar "¿Continuar?"
    local rc=$?
    set -e
    case $rc in
        0)
            while IFS= read -r f; do
                rm "$f"
            done < <(find "$DATA/$sub" -type f -name '*.md' 2>/dev/null)
            rmdir "$DATA/$sub" 2>/dev/null || true
            echo "Eliminados $count archivo(s) de $sub."
            if [[ -z "$(listar_streamers)" ]]; then
                echo "No quedan streamers guardados."
                exit 0
            fi
            ;;
        1) echo "Cancelado." ;;
        2) return 2 ;;
        *) exit 0 ;;
    esac
}

eliminar_momento_interactivo() {
    local filtro="${1:-}"
    local rc tmp
    while true; do
        tmp="$(cargar_momentos "$filtro")"
        set +e
        if [[ -z "$filtro" ]]; then
            menu_momentos "=== Remover — Momento ===" "$tmp" "n" "todos"
        else
            menu_momentos "=== Remover — Momento ===" "$tmp" "n" "streamer"
        fi
        rc=$?
        set -e
        rm -f "$tmp"

        if [[ $rc -eq 2 ]]; then
            return 2
        elif [[ $rc -ne 0 ]]; then
            exit 0
        fi

        IFS='|' read -r _ streamer secs minuto desc url fecha fecha_iso <<< "$SELECCION_LINEA"
        minuto="$(formatear_minuto "$minuto")"
        echo
        echo "Vas a eliminar:"
        if [[ -z "$filtro" ]]; then
            printf '  [%s — %s — %s] %s\n  %s\n' "$fecha" "$streamer" "$minuto" "$desc" "$url"
        else
            printf '  [%s — %s] %s\n  %s\n' "$fecha" "$minuto" "$desc" "$url"
        fi
        set +e
        confirmar "¿Continuar?"
        rc=$?
        set -e
        case $rc in
            0) quitar_momento "$streamer" "$secs" "$desc" "$url"
               echo "✓ Eliminado." ;;
            1) echo "Cancelado." ;;
            2) continue ;;
            *) exit 0 ;;
        esac
    done
}

accion_elegir_momento() {
    local filtro="${1:-}"
    set +e
    eliminar_momento_interactivo "$filtro"
    local rc=$?
    set -e
    return $rc
}

accion_eliminar_todos() {
    local filtro="${1:-}"
    if [[ -z "$filtro" ]]; then
        set +e
        menu_streamers "=== ¿De qué streamer? ===" "n"
        local rc=$?
        set -e
        case $rc in
            2) return 0 ;;
            3) exit 0 ;;
        esac
        if [[ "$SELECCION" == "__ALL__" ]]; then
            echo "Tiene que ser un streamer específico."
            return 0
        fi
        filtro="$SELECCION"
    fi
    set +e
    eliminar_todos_de_streamer "$filtro"
    local rc=$?
    set -e
    return $rc
}

# ---------------------------------------------------------------------------
# Bucle principal
# ---------------------------------------------------------------------------
while true; do
    set +e
    menu_streamers "=== Remover — Streamers ===" "s"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] && exit 0

    if [[ "$SELECCION" == "__ALL__" ]]; then
        set +e
        submenu_acciones "" \
            "1" "Elegir un momento específico" "accion_elegir_momento" \
            "2" "Eliminar TODOS los momentos de un streamer" "accion_eliminar_todos"
        rc=$?
        set -e
    else
        SUBMENU_ARGS=("$SELECCION")
        set +e
        submenu_acciones "$SELECCION" \
            "1" "Elegir un momento a eliminar" "accion_elegir_momento" \
            "2" "Eliminar TODOS los momentos" "accion_eliminar_todos"
        rc=$?
        set -e
    fi
    case $rc in
        2) continue ;;
        3) exit 0 ;;
    esac
done
