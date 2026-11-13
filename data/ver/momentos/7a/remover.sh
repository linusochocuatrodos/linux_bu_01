#!/usr/bin/env bash
# remover.sh — Menú interactivo para eliminar momentos (sin tocar data/backup/).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

if [[ ! -d "$DATA" ]] || [[ -z "$(listar_streamers)" ]]; then
    echo "Sin datos aún. Agregá líneas a momentos.txt y corré ./momento.sh"
    exit 0
fi

quitar_momento() {
    local streamer="$1" secs="$2" desc="$3" relpath="$4"
    local archivo="$DATA/$relpath"

    if [[ ! -f "$archivo" ]]; then
        echo "No se encontró el archivo: $archivo" >&2
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    S_TARGET="$secs" D_TARGET="$desc" \
    awk '
    BEGIN { removed = 0 }
    NR <= 7 { print; next }
    /^\|/ {
        line = $0
        sub(/\r$/, "", line)
        body = line
        sub(/^\|[ \t]*/, "", body)
        p1 = index(body, "|")
        if (p1 > 0) {
            s = substr(body, 1, p1 - 1)
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            rest = substr(body, p1 + 1)
            p2 = index(rest, "|")
            if (p2 > 0) {
                d = substr(rest, p2 + 1)
                sub(/[ \t]*\|[ \t]*$/, "", d)
                gsub(/^[ \t]+|[ \t]+$/, "", d)
                if (!removed && s == ENVIRON["S_TARGET"] && d == ENVIRON["D_TARGET"]) {
                    removed = 1
                    next
                }
            }
        }
    }
    { print }
    ' "$archivo" > "$tmp_file"

    touch -r "$archivo" "$tmp_file"
    mv "$tmp_file" "$archivo"

    eliminar_orden "$relpath" "$desc"

    # Si no quedan filas de momentos después del header (7 líneas), eliminar archivo y carpeta vacía
    local quedan
    quedan=$(awk 'NR > 7 && /^\|[ \t]*[0-9]+/ { c++ } END { print c+0 }' "$archivo")
    if (( quedan == 0 )); then
        rm -f "$archivo"
        rmdir "$DATA/$streamer" 2>/dev/null || true
    fi
}

eliminar_todos_de_streamer() {
    local sub="$1"
    local count
    count=$(find "$DATA/$sub" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    echo
    echo "Vas a eliminar TODOS los momentos de: $sub ($count archivo(s))"
    set +e
    confirmar "¿Continuar?"
    local rc=$?
    set -e
    case $rc in
        0)
            find "$DATA/$sub" -type f -name '*.md' -delete 2>/dev/null || true
            rmdir "$DATA/$sub" 2>/dev/null || true
            eliminar_orden "$sub" "__ALL_STREAMER__"
            if [[ -z "$(listar_streamers)" ]]; then
                echo "Eliminados $count archivo(s) de $sub. No quedan streamers guardados."
                exit 0
            fi
            set_estado ok "✓ Eliminados $count archivo(s) de $sub."
            return 0
            ;;
        1)
            set_estado info "Eliminación cancelada."
            return 0
            ;;
        2) return 2 ;;
        *) exit 0 ;;
    esac
}

eliminar_momento_interactivo() {
    local filtro="${1:-}"
    local modo="todos"
    [[ -n "$filtro" ]] && modo="streamer"

    while true; do
        local rc
        set +e
        menu_momentos "=== Remover — Momento ===" "$filtro" "n" "$modo"
        rc=$?
        set -e

        if [[ $rc -eq 2 ]]; then
            return 2
        elif [[ $rc -ne 0 ]]; then
            exit 0
        fi

        IFS="$SEP" read -r _ streamer secs minuto desc url fecha fecha_iso relpath <<< "$SELECCION_LINEA"
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
            0)
                quitar_momento "$streamer" "$secs" "$desc" "$relpath"
                if [[ -z "$(listar_streamers)" ]]; then
                    echo "✓ Eliminado. No quedan más momentos guardados."
                    exit 0
                fi
                if [[ -n "$filtro" && ! -d "$DATA/$filtro" ]]; then
                    set_estado ok "✓ Eliminado el último momento de $filtro."
                    return 4
                fi
                set_estado ok "✓ Eliminado: \"$desc\""
                ;;
            1) set_estado info "Cancelado." ;;
            2) continue ;;
            *) exit 0 ;;
        esac
    done
}

accion_elegir_momento() {
    local filtro="${1:-}"
    local rc=0
    set +e
    eliminar_momento_interactivo "$filtro"
    rc=$?
    set -e
    return $rc
}

accion_eliminar_todos() {
    local filtro="${1:-}"
    if [[ -z "$filtro" ]]; then
        while true; do
            local rc=0
            set +e
            menu_streamers "=== ¿De qué streamer? ===" "n"
            rc=$?
            set -e
            case $rc in
                2) return 2 ;;
                3) exit 0 ;;
                1) return 2 ;;
            esac
            if [[ "$SELECCION" == "__ALL__" ]]; then
                set_estado warn "Tenés que elegir un streamer específico."
                continue
            fi
            set +e
            eliminar_todos_de_streamer "$SELECCION"
            rc=$?
            set -e
            [[ $rc -eq 2 ]] && continue
            return $rc
        done
    else
        local rc=0
        set +e
        eliminar_todos_de_streamer "$filtro"
        rc=$?
        set -e
        return $rc
    fi
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
        SUBMENU_ARGS=()
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
