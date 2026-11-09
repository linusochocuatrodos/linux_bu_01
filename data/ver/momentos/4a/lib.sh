#!/usr/bin/env bash
set -euo pipefail

# lib.sh vive siempre al lado de los scripts. Su directorio = directorio del proyecto.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$ROOT/data"
BACKUP="$DATA/backup"

# Códigos de retorno de los menús:
#   0 = selección hecha (resultado en SELECCION / SELECCION_LINEA)
#   2 = volver (al menú anterior)
#   3 = salir (de toda la app)
SELECCION=""
SELECCION_LINEA=""

limpiar() {
    clear
}

abrir_en_navegador() {
    local url="$1"
    # Primero intenta con los launchers genéricos del sistema (respetan el navegador por defecto).
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
    elif command -v gio >/dev/null 2>&1; then
        gio open "$url" >/dev/null 2>&1 &
    # Si no hay launcher, intenta con navegadores comunes en orden de probabilidad.
    elif command -v firefox >/dev/null 2>&1; then
        firefox --new-tab "$url" >/dev/null 2>&1 &
    elif command -v firefox-esr >/dev/null 2>&1; then
        firefox-esr --new-tab "$url" >/dev/null 2>&1 &
    elif command -v google-chrome >/dev/null 2>&1; then
        google-chrome "$url" >/dev/null 2>&1 &
    elif command -v google-chrome-stable >/dev/null 2>&1; then
        google-chrome-stable "$url" >/dev/null 2>&1 &
    elif command -v chromium >/dev/null 2>&1; then
        chromium "$url" >/dev/null 2>&1 &
    elif command -v brave-browser >/dev/null 2>&1; then
        brave-browser "$url" >/dev/null 2>&1 &
    elif command -v brave >/dev/null 2>&1; then
        brave "$url" >/dev/null 2>&1 &
    elif command -v microsoft-edge >/dev/null 2>&1; then
        microsoft-edge "$url" >/dev/null 2>&1 &
    elif command -v edge >/dev/null 2>&1; then
        edge "$url" >/dev/null 2>&1 &
    elif command -v helium-browser >/dev/null 2>&1; then
        helium-browser "$url" >/dev/null 2>&1 &
    elif command -v helium >/dev/null 2>&1; then
        helium "$url" >/dev/null 2>&1 &
    else
        echo "No se encontró navegador. Abrí manualmente: $url" >&2
        return 1
    fi
}

listar_streamers() {
    local -a dirs=()
    for d in "$DATA"/*/; do
        [[ -d "$d" ]] || continue
        local name
        name="$(basename "$d")"
        [[ "$name" == "backup" ]] && continue
        dirs+=("$name")
    done
    if [[ ${#dirs[@]} -eq 0 ]]; then
        return
    fi
    printf '%s\n' "${dirs[@]}" | sort
}

formatear_minuto() {
    local m="$1"
    if [[ "$m" =~ ^([0-9]+):([0-9]{1,2}):([0-9]{1,2})$ ]]; then
        printf "%02d:%02d:%02d" "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
    elif [[ "$m" =~ ^([0-9]+):([0-9]{1,2})$ ]]; then
        printf "%02d:%02d" "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))"
    else
        printf "%s" "$m"
    fi
}

# Carga todos los momentos en un archivo temporal y devuelve la ruta.
# Formato: streamer|segundos|minuto|desc|url|fecha_ddmm|fecha_iso
# Si se pasa $1 = streamer, filtra por ese streamer.
cargar_momentos() {
    local filtro="${1:-}"
    local tmp
    tmp="$(mktemp)"
    while IFS= read -r f; do
        local title streamer url fecha_raw fecha_ddmm fecha_iso
        title="$(head -n1 "$f" | sed 's/^# //')"
        streamer="${title%% — *}"
        streamer="$(echo "$streamer" | tr -d ' ')"
        url="$(grep -m1 '^\*\*URL:\*\*' "$f" | sed 's/^\*\*URL:\*\* //')"
        fecha_raw="$(grep -m1 '^\*\*Fecha:\*\*' "$f" | sed 's/^\*\*Fecha:\*\* //')"
        fecha_ddmm="??/??"
        fecha_iso="0000-00-00"
        if [[ "$fecha_raw" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
            fecha_ddmm="${BASH_REMATCH[3]}/${BASH_REMATCH[2]}"
            fecha_iso="$fecha_raw"
        fi
        while IFS='|' read -r _ secs minuto desc _; do
            secs="$(echo "$secs" | xargs)"
            minuto="$(echo "$minuto" | xargs)"
            desc="$(echo "$desc" | xargs)"
            [[ -z "$secs" || "$secs" =~ ^-+$ || "$secs" == "Segundos" ]] && continue
            [[ -z "$desc" || ! "$secs" =~ ^[0-9]+$ ]] && continue
            if [[ -n "$filtro" && "$streamer" != "$filtro" ]]; then
                continue
            fi
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$streamer" "$secs" "$minuto" "$desc" "$url" "$fecha_ddmm" "$fecha_iso" >> "$tmp"
        done < <(tail -n +8 "$f")
    done < <(find "$DATA" -type f -name '*.md' -not -path "$BACKUP/*" -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
    printf '%s\n' "$tmp"
}

# $1 = prompt, $2 = "es_raiz" (s/n) -> muestra "s) Salir" si es raíz, "v) Volver" si no
menu_streamers() {
    local prompt="$1"
    local es_raiz="${2:-n}"
    set +e
    SELECCION=""
    local -a streamers
    mapfile -t streamers < <(listar_streamers)

    if [[ ${#streamers[@]} -eq 0 ]]; then
        echo "No hay streamers guardados."
        return 1
    fi

    while true; do
        limpiar
        echo "$prompt"
        echo
        for i in "${!streamers[@]}"; do
            printf '  %d) %s\n' "$((i+1))" "${streamers[$i]}"
        done
        printf '  0) Todos los streamers\n'
        if [[ "$es_raiz" != "s" ]]; then
            printf '  v) Volver\n'
        fi
        printf '  s) Salir\n'
        echo
        if ! read -rp "> " opt; then
            # EOF
            return 3
        fi
        case "$opt" in
            s|S) return 3 ;;
            v|V) [[ "$es_raiz" != "s" ]] && return 2 ;;
            0) SELECCION="__ALL__"; return 0 ;;
            *)
                if [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#streamers[@]} )); then
                    SELECCION="${streamers[$((opt-1))]}"
                    return 0
                fi
                echo "Opción inválida."
                ;;
        esac
    done
}

# $1 = prompt, $2 = archivo con momentos, $3 = es_raiz (s/n), $4 = modo (todos/streamer/auto)
menu_momentos() {
    local prompt="$1"
    local tmp="$2"
    local es_raiz="${3:-n}"
    local modo="${4:-auto}"
    set +e
    SELECCION_LINEA=""
    local n
    n=$(wc -l < "$tmp" 2>/dev/null || echo 0)

    if [[ $n -eq 0 ]]; then
        echo "No hay momentos para mostrar."
        return 1
    fi

    # Ordenar y numerar: fecha más reciente primero, luego minuto ascendente
    local tmp2
    tmp2="$(mktemp)"
    sort -s -t'|' -k7,7r "$tmp" -o "$tmp" 2>/dev/null || sort -s -t'|' -k7,7r "$tmp" > "$tmp"
    local i=0
    while IFS='|' read -r streamer secs minuto desc url fecha fecha_iso; do
        [[ -z "$streamer" ]] && continue
        i=$((i+1))
        printf '%d|%s|%s|%s|%s|%s|%s|%s\n' "$i" "$streamer" "$secs" "$minuto" "$desc" "$url" "$fecha" "$fecha_iso" >> "$tmp2"
    done < "$tmp"
    mv "$tmp2" "$tmp"
    n=$i

    # Determinar si es vista "Todos" (fecha primero) o streamer específico
    local es_todos=0
    if [[ "$modo" == "todos" ]]; then
        es_todos=1
    elif [[ "$modo" == "streamer" ]]; then
        es_todos=0
    else
        # auto: si hay >1 streamer distinto, es Todos
        local distintos
        distintos=$(cut -d'|' -f2 "$tmp" | sort -u | wc -l)
        [[ $distintos -gt 1 ]] && es_todos=1
    fi

    while true; do
        limpiar
        echo "$prompt"
        echo
        while IFS='|' read -r num streamer secs minuto desc url fecha fecha_iso; do
            local minuto_fmt
            minuto_fmt="$(formatear_minuto "$minuto")"
            if [[ $es_todos -eq 1 ]]; then
                printf '  %s) [%s-%s-%s] %s\n' "$num" "$fecha" "$minuto_fmt" "$streamer" "$desc"
            else
                printf '  %s) [%s-%s-%s] %s\n' "$num" "$streamer" "$fecha" "$minuto_fmt" "$desc"
            fi
        done < "$tmp"
        if [[ "$es_raiz" != "s" ]]; then
            printf '  v) Volver\n'
        fi
        printf '  s) Salir\n'
        echo
        if ! read -rp "> " opt; then
            return 3
        fi
        case "$opt" in
            s|S) return 3 ;;
            v|V) [[ "$es_raiz" != "s" ]] && return 2 ;;
            *)
                if [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= n )); then
                    SELECCION_LINEA="$(grep "^${opt}|" "$tmp" | head -n1)"
                    return 0
                fi
                echo "Opción inválida."
                ;;
        esac
    done
}

# Sub-menú genérico con opciones a/b/v. $1=prompt, $2..=pares "letra|descripción|función_a_llamar"
# Las funciones reciben los argumentos extra pasados a submenu_a_b.
submenu_a_b() {
    local prompt="$1"
    shift
    while true; do
        limpiar
        echo "$prompt"
        echo
        local -a entries=("$@")
        for ((i=0; i<${#entries[@]}; i+=3)); do
            printf '  %s) %s\n' "${entries[$i]}" "${entries[$i+1]}"
        done
        printf '  v) Volver\n'
        printf '  s) Salir\n'
        echo
        read -rp "> " opt
        case "$opt" in
            v|V) return 2 ;;
            s|S) return 3 ;;
        esac
        for ((i=0; i<${#entries[@]}; i+=3)); do
            if [[ "$opt" == "${entries[$i]}" ]]; then
                local fn="${entries[$i+2]}"
                if declare -F "$fn" >/dev/null; then
                    "$fn" "${SUBMENU_ARGS[@]:-}"
                    return $?
                fi
            fi
        done
        echo "Opción inválida."
    done
}

# $1 = nombre del streamer (o "" para vista "TODOS")
# args 2..N = triplets (num, desc, funcion) como args separados
submenu_acciones() {
    local titulo="$1"
    shift
    set +e
    local -a nums descs fns
    local -a raw=("$@")
    local n=${#raw[@]}
    local i
    for ((i=0; i<n; i+=3)); do
        nums+=("${raw[$i]}")
        descs+=("${raw[$i+1]}")
        fns+=("${raw[$i+2]}")
    done
    while true; do
        limpiar
        if [[ -n "$titulo" ]]; then
            echo "== ${titulo^^} =="
        else
            echo "== TODOS =="
        fi
        echo
        for i in "${!nums[@]}"; do
            printf '  %s) %s\n' "${nums[$i]}" "${descs[$i]}"
        done
        echo "  v) Volver"
        echo "  s) Salir"
        echo
        if ! read -rp "> " opt; then
            return 3
        fi
        case "$opt" in
            v|V) return 2 ;;
            s|S) return 3 ;;
        esac
        local found=0
        for i in "${!nums[@]}"; do
            if [[ "$opt" == "${nums[$i]}" ]]; then
                local fn="${fns[$i]}"
                if declare -F "$fn" >/dev/null; then
                    "$fn" "${SUBMENU_ARGS[@]:-}"
                    local fn_rc=$?
                    if [[ $fn_rc -eq 2 ]]; then
                        continue 2
                    elif [[ $fn_rc -eq 3 ]]; then
                        return 3
                    fi
                    return 0
                fi
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo "Opción inválida."
        fi
    done
}

# $1 = prompt. Devuelve 0 (sí), 1 (no), 2 (volver), 3 (salir).
confirmar_accion() {
    local prompt="$1"
    while true; do
        read -rp "$prompt (y/n, 'v' volver, 'q' salir): " r
        case "$r" in
            s|S|si|SI|yes|Y|y) return 0 ;;
            n|N|no|NO) return 1 ;;
            v|V) return 2 ;;
            q|Q|quit|exit) return 3 ;;
            *) echo "Respondé y, n, v o q." ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Este archivo es una librería. Ejecutá abrir.sh, edit.sh o remover.sh."
    exit 1
fi
