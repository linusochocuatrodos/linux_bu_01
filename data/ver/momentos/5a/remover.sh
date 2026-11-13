#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

if [[ ! -d "$DATA" ]] || [[ -z "$(ls -A "$DATA" 2>/dev/null)" ]]; then
    echo "Sin datos aún. Agregá líneas a momentos.txt y corré ./momento.sh"
    exit 0
fi

quitar_momento() {
    local streamer="$1" secs="$2" minuto="$3" desc="$4" url="$5"
    local archivo=""
    while IFS= read -r f; do
        f_url="$(grep -m1 '^\*\*URL:\*\*' "$f" | sed 's/^\*\*URL:\*\* //')"
        [[ "$f_url" != "$url" ]] && continue
        if grep -q "^| $secs | $minuto | $desc |" "$f"; then
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
    tail -n +8 "$archivo" | awk -F'|' -v s="$secs" -v m="$minuto" -v d="$desc" '
        {
            sf=$2; gsub(/^ +| +$/,"",sf);
            mf=$3; gsub(/^ +| +$/,"",mf);
            df=$4; gsub(/^ +| +$/,"",df);
            if (sf=="Segundos" || sf=="") next;
            if (sf==s && mf==m && df==d) next;
            print
        }' >> "$tmp_file"
    mv "$tmp_file" "$archivo"

    if [[ "$(wc -l < "$archivo")" -le 7 ]]; then
        rm "$archivo"
        rmdir "$DATA/$streamer" 2>/dev/null || true
    fi
    if [[ -z "$(listar_streamers)" ]]; then
        echo "No quedan streamers guardados."
        exit 0
    fi
}

confirmar() {
    local prompt="$1"
    while true; do
        read -rp "$prompt (yes/no, 'v' volver, 's' salir): " r
        case "$r" in
            yes|YES|y|Y) return 0 ;;
            no|NO|n|N) return 1 ;;
            v|V) return 2 ;;
            s|S|salir|SALIR|exit|quit|q|Q) return 3 ;;
            *) echo "Respondé yes, no, v o s." ;;
        esac
    done
}

eliminar_todos_de_streamer() {
    local sub="$1"
    local count
    count=$(find "$DATA/$sub" -type f -name '*.md' 2>/dev/null | wc -l)
    echo
    echo "Vas a eliminar TODOS los momentos de: $sub ($count archivo(s))"
    echo "Esta acción no se puede deshacer."
    set +e
    confirmar "¿Continuar?"
    local rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        while IFS= read -r f; do
            rm "$f"
        done < <(find "$DATA/$sub" -type f -name '*.md' 2>/dev/null)
        rmdir "$DATA/$sub" 2>/dev/null || true
        echo "Eliminados $count archivo(s) de $sub."
        if [[ -z "$(listar_streamers)" ]]; then
            echo "No quedan streamers guardados."
            exit 0
        fi
    elif [[ $rc -eq 1 ]]; then
        echo "Cancelado."
    elif [[ $rc -eq 2 ]]; then
        set +e
        return 2
    else
        exit 0
    fi
}

eliminar_momento_interactivo() {
    local filtro="${1:-}"
    local rc
    while true; do
        local tmp
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
            set +e
            return 2
        elif [[ $rc -eq 3 || $rc -ne 0 ]]; then
            exit 0
        fi
        IFS='|' read -r _ streamer secs minuto desc url fecha fecha_iso <<<"$SELECCION_LINEA"
        minuto="$(formatear_minuto "$minuto")"
        echo
        echo "Vas a eliminar:"
        if [[ -z "$filtro" ]]; then
            printf '  [%s-%s-%s] %s\n  %s\n' "$fecha" "$minuto" "$streamer" "$desc" "$url"
        else
            printf '  [%s-%s-%s] %s\n  %s\n' "$streamer" "$fecha" "$minuto" "$desc" "$url"
        fi
        set +e
        confirmar "¿Continuar?"
        rc=$?
        set -e
        if [[ $rc -eq 0 ]]; then
            quitar_momento "$streamer" "$secs" "$minuto" "$desc" "$url"
            echo "Eliminado."
            continue
        elif [[ $rc -eq 1 ]]; then
            echo "Cancelado."
            set +e
            return 0
        elif [[ $rc -eq 2 ]]; then
            continue
        else
            exit 0
        fi
    done
}

# Acciones invocadas por submenu_acciones (1 y 2)
accion_elegir_momento() {
    local filtro="${1:-}"
    set +e
    eliminar_momento_interactivo "$filtro"
    local rc=$?
    set -e
    set +e
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
    set +e
    return $rc
}

# Bucle principal
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
        case $rc in
            2) continue ;;
            3) exit 0 ;;
        esac
    else
        SUBMENU_ARGS=("$SELECCION")
        set +e
        submenu_acciones "$SELECCION" \
            "1" "Elegir un momento a eliminar" "accion_elegir_momento" \
            "2" "Eliminar TODOS los momentos" "accion_eliminar_todos"
        rc=$?
        set -e
        case $rc in
            2) continue ;;
            3) exit 0 ;;
        esac
    fi
done
