#!/usr/bin/env bash
# lib.sh — Librería compartida. No ejecutar directamente.
set -euo pipefail

# ROOT = directorio donde vive lib.sh (y todos los scripts del proyecto)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$ROOT/data"
BACKUP="$DATA/backup"

# Códigos de retorno de los menús:
#   0 = selección hecha (resultado en SELECCION / SELECCION_LINEA)
#   2 = volver (al menú anterior)
#   3 = salir (de toda la app)
SELECCION=""
SELECCION_LINEA=""

# ---------------------------------------------------------------------------
# Utilidades básicas
# ---------------------------------------------------------------------------

limpiar() { clear; }

# Trim de espacios al inicio y fin (puro bash, sin subshell)
trim() {
    local s="$1"
    s="${s#"${s%%[! ]*}"}"
    s="${s%"${s##*[! ]}"}"
    printf '%s' "$s"
}

formatear_minuto() {
    local m="$1"
    if [[ "$m" =~ ^([0-9]+):([0-9]{1,2}):([0-9]{1,2})$ ]]; then
        printf "%02d:%02d:%02d" \
            "$((10#${BASH_REMATCH[1]}))" \
            "$((10#${BASH_REMATCH[2]}))" \
            "$((10#${BASH_REMATCH[3]}))"
    elif [[ "$m" =~ ^([0-9]+):([0-9]{1,2})$ ]]; then
        printf "%02d:%02d" \
            "$((10#${BASH_REMATCH[1]}))" \
            "$((10#${BASH_REMATCH[2]}))"
    else
        printf '%s' "$m"
    fi
}

# Convierte timestamp (M:SS o H:MM:SS) a segundos totales.
# Escribe el resultado en stdout. Retorna 1 si el formato es inválido.
timestamp_a_segundos() {
    local ts="$1"
    local h=0 m=0 s=0
    if [[ "$ts" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        h="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; s="${BASH_REMATCH[3]}"
    elif [[ "$ts" =~ ^([0-9]+):([0-9]+)$ ]]; then
        m="${BASH_REMATCH[1]}"; s="${BASH_REMATCH[2]}"
    else
        return 1
    fi
    if (( 10#$m > 59 || 10#$s > 59 )); then
        return 1
    fi
    printf '%d' "$(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))"
}

# ---------------------------------------------------------------------------
# Navegador
# ---------------------------------------------------------------------------

abrir_en_navegador() {
    local url="$1"
    # Launchers genéricos del sistema (respetan el navegador por defecto)
    local launchers=(xdg-open gio)
    # Navegadores específicos como fallback
    local browsers=(firefox firefox-esr google-chrome google-chrome-stable
                    chromium brave-browser brave microsoft-edge edge
                    helium-browser helium)
    local cmd
    for cmd in "${launchers[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            "$cmd" "$url" >/dev/null 2>&1 &
            return 0
        fi
    done
    for cmd in "${browsers[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            "$cmd" "$url" >/dev/null 2>&1 &
            return 0
        fi
    done
    printf 'No se encontró navegador. Abrí manualmente:\n  %s\n' "$url" >&2
    return 1
}

# ---------------------------------------------------------------------------
# Datos
# ---------------------------------------------------------------------------

listar_streamers() {
    local d name
    for d in "$DATA"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        [[ "$name" == "backup" ]] && continue
        printf '%s\n' "$name"
    done | sort
}

# Carga momentos en un archivo temporal y devuelve su ruta (stdout).
# Formato de cada línea: streamer|segundos|minuto|desc|url|fecha_ddmm|fecha_iso
# $1 (opcional) = filtrar por ese streamer
cargar_momentos() {
    local filtro="${1:-}"
    local tmp
    tmp="$(mktemp)"
    local f streamer url fecha_raw fecha_ddmm fecha_iso title
    local secs minuto desc
    while IFS= read -r f; do
        title="$(head -n1 "$f" | sed 's/^# //')"
        streamer="${title%% — *}"
        # Quitar espacios sin subshell costoso
        streamer="${streamer// /}"
        url="$(grep -m1 '^\*\*URL:\*\*' "$f" | sed 's/^\*\*URL:\*\* //')"
        fecha_raw="$(grep -m1 '^\*\*Fecha:\*\*' "$f" | sed 's/^\*\*Fecha:\*\* //')"
        fecha_ddmm="??/??"
        fecha_iso="0000-00-00"
        if [[ "$fecha_raw" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
            fecha_ddmm="${BASH_REMATCH[3]}/${BASH_REMATCH[2]}"
            fecha_iso="${fecha_raw}"
        fi
        [[ -n "$filtro" && "$streamer" != "$filtro" ]] && continue
        while IFS='|' read -r _ secs minuto desc _; do
            secs="$(trim "$secs")"
            minuto="$(trim "$minuto")"
            desc="$(trim "$desc")"
            [[ -z "$secs" || "$secs" =~ ^-+$ || "$secs" == "Segundos" ]] && continue
            [[ -z "$desc" || ! "$secs" =~ ^[0-9]+$ ]] && continue
            printf '%s|%s|%s|%s|%s|%s|%s\n' \
                "$streamer" "$secs" "$minuto" "$desc" "$url" "$fecha_ddmm" "$fecha_iso" >> "$tmp"
        done < <(tail -n +8 "$f")
    done < <(find "$DATA" -type f -name '*.md' -not -path "$BACKUP/*" \
                -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
    printf '%s\n' "$tmp"
}

# ---------------------------------------------------------------------------
# Menús
# ---------------------------------------------------------------------------

# Menú de selección de streamer.
# $1 = prompt título
# $2 = "s" si es el menú raíz (no muestra "v) Volver")
# Resultado en $SELECCION ("__ALL__" para Todos).
# Retorna: 0=selección, 2=volver, 3=salir
menu_streamers() {
    local prompt="$1"
    local es_raiz="${2:-n}"
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
        local i
        for i in "${!streamers[@]}"; do
            printf '  %d) %s\n' "$((i+1))" "${streamers[$i]}"
        done
        printf '  0) Todos los streamers\n'
        [[ "$es_raiz" != "s" ]] && printf '  v) Volver\n'
        printf '  s) Salir\n'
        echo
        local opt
        if ! read -rp "> " opt; then
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

# Menú de lista de momentos.
# $1 = prompt título
# $2 = ruta al archivo temporal con momentos (formato cargar_momentos)
# $3 = "s" si es raíz (sin "v) Volver")
# $4 = modo: "todos" | "streamer" | "auto"
# Resultado en $SELECCION_LINEA.
# Retorna: 0=selección, 2=volver, 3=salir
menu_momentos() {
    local prompt="$1"
    local tmp="$2"
    local es_raiz="${3:-n}"
    local modo="${4:-auto}"
    SELECCION_LINEA=""

    local n
    n=$(wc -l < "$tmp" 2>/dev/null || echo 0)
    if [[ $n -eq 0 ]]; then
        echo "No hay momentos para mostrar."
        return 1
    fi

    # Ordenar: fecha más reciente primero, luego por segundos ascendente
    local tmp2 tmp3
    tmp2="$(mktemp)"
    sort -t'|' -k7,7r -k2,2n "$tmp" > "$tmp2"

    # Numerar las filas
    tmp3="$(mktemp)"
    local i=0
    while IFS='|' read -r streamer secs minuto desc url fecha fecha_iso; do
        [[ -z "$streamer" ]] && continue
        i=$((i+1))
        printf '%d|%s|%s|%s|%s|%s|%s|%s\n' \
            "$i" "$streamer" "$secs" "$minuto" "$desc" "$url" "$fecha" "$fecha_iso" >> "$tmp3"
    done < "$tmp2"
    rm -f "$tmp2"
    n=$i

    # Detectar modo de visualización
    local es_todos=0
    case "$modo" in
        todos)    es_todos=1 ;;
        streamer) es_todos=0 ;;
        *)
            local distintos
            distintos=$(cut -d'|' -f2 "$tmp3" | sort -u | wc -l)
            [[ $distintos -gt 1 ]] && es_todos=1
            ;;
    esac

    local opt minuto_fmt
    while true; do
        limpiar
        echo "$prompt"
        echo
        while IFS='|' read -r num streamer secs minuto desc url fecha fecha_iso; do
            minuto_fmt="$(formatear_minuto "$minuto")"
            if [[ $es_todos -eq 1 ]]; then
                printf '  %s) [%s — %s — %s] %s\n' "$num" "$fecha" "$streamer" "$minuto_fmt" "$desc"
            else
                printf '  %s) [%s — %s] %s\n' "$num" "$fecha" "$minuto_fmt" "$desc"
            fi
        done < "$tmp3"
        [[ "$es_raiz" != "s" ]] && printf '  v) Volver\n'
        printf '  s) Salir\n'
        echo
        if ! read -rp "> " opt; then
            rm -f "$tmp3"
            return 3
        fi
        case "$opt" in
            s|S) rm -f "$tmp3"; return 3 ;;
            v|V) [[ "$es_raiz" != "s" ]] && { rm -f "$tmp3"; return 2; } ;;
            *)
                if [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= n )); then
                    SELECCION_LINEA="$(grep "^${opt}|" "$tmp3" | head -n1)"
                    rm -f "$tmp3"
                    return 0
                fi
                echo "Opción inválida."
                ;;
        esac
    done
}

# Menú de acciones (opciones numeradas/letras + v/s).
# $1 = título del menú
# $2..$N = triplets: "letra" "descripción" "nombre_función"
# La función invocada recibe los argumentos en $SUBMENU_ARGS[@] si está definido.
# Retorna: 0=acción ejecutada, 2=volver, 3=salir
submenu_acciones() {
    local titulo="$1"
    shift
    local -a raw=("$@")
    local n=${#raw[@]}
    local -a nums descs fns
    local i
    for ((i=0; i<n; i+=3)); do
        nums+=("${raw[$i]}")
        descs+=("${raw[$i+1]}")
        fns+=("${raw[$i+2]}")
    done

    local opt
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
                found=1
                local fn="${fns[$i]}"
                local fn_rc=0
                if declare -F "$fn" >/dev/null; then
                    "$fn" "${SUBMENU_ARGS[@]:-}" || fn_rc=$?
                    case $fn_rc in
                        2) continue 2 ;;
                        3) return 3 ;;
                        *) return 0 ;;
                    esac
                fi
                break
            fi
        done
        [[ $found -eq 0 ]] && echo "Opción inválida."
    done
}

# Confirmación interactiva.
# $1 = prompt
# Retorna: 0=sí, 1=no, 2=volver, 3=salir
confirmar() {
    local prompt="$1"
    local r
    while true; do
        read -rp "$prompt (y/n, 'v' volver, 's' salir): " r
        case "$r" in
            y|Y|si|SI|yes|YES) return 0 ;;
            n|N|no|NO)         return 1 ;;
            v|V)               return 2 ;;
            s|S|q|Q|salir|exit|quit) return 3 ;;
            *) echo "Respondé y, n, v o s." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Guard: no ejecutar directamente
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Este archivo es una librería. Ejecutá abrir.sh, edit.sh o remover.sh." >&2
    exit 1
fi
