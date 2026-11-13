#!/usr/bin/env bash
# lib.sh — Librería compartida. No ejecutar directamente.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$ROOT/data"
BACKUP="$DATA/backup"
ORDEN_FILE="$DATA/.orden"

# Separador interno ASCII Unit Separator (nunca choca con '|' ni espacios)
SEP=$'\x1f'

# Códigos de retorno estandarizados:
#   0 = selección / acción completada
#   2 = volver al menú anterior
#   3 = salir de la aplicación
#   4 = volver hasta el menú de streamers (usado al vaciar un streamer)
SELECCION=""
SELECCION_LINEA=""
SUBMENU_ARGS=()

# Banner de estado persistente entre redraws con clear
MENSAJE_ESTADO=""
MENSAJE_TIPO=""

# Colores ANSI solo si stdout es una terminal interactiva
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'
else
    C_RESET="" C_BOLD="" C_DIM="" C_GREEN="" C_YELLOW="" C_RED="" C_CYAN=""
fi

# ---------------------------------------------------------------------------
# Utilidades básicas y mensajes
# ---------------------------------------------------------------------------

limpiar() {
    [[ -t 1 ]] && clear || true
}

set_estado() {
    MENSAJE_TIPO="$1"
    MENSAJE_ESTADO="$2"
}

mostrar_estado() {
    [[ -z "$MENSAJE_ESTADO" ]] && return 0
    case "$MENSAJE_TIPO" in
        ok)   printf '%b%s%b\n\n' "$C_GREEN" "$MENSAJE_ESTADO" "$C_RESET" ;;
        warn) printf '%b%s%b\n\n' "$C_YELLOW" "$MENSAJE_ESTADO" "$C_RESET" ;;
        err)  printf '%b%s%b\n\n' "$C_RED" "$MENSAJE_ESTADO" "$C_RESET" ;;
        *)    printf '%b%s%b\n\n' "$C_CYAN" "$MENSAJE_ESTADO" "$C_RESET" ;;
    esac
    MENSAJE_ESTADO=""
    MENSAJE_TIPO=""
}

# Trim de espacios/tabs al inicio y fin (bash puro)
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
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

timestamp_a_segundos() {
    local ts
    ts="$(trim "$1")"
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

segundos_a_timestamp() {
    local total=$(( 10#$1 ))
    local h=$(( total / 3600 ))
    local m=$(( (total % 3600) / 60 ))
    local s=$(( total % 60 ))
    if (( h > 0 )); then
        printf '%02d:%02d:%02d' "$h" "$m" "$s"
    else
        printf '%02d:%02d' "$m" "$s"
    fi
}

# Limpia fragmentos #t=... y barra final de una URL
limpiar_url() {
    local u="$1"
    u="${u%%#*}"
    u="${u%/}"
    printf '%s' "$u"
}

# Extrae un ID seguro para nombre de archivo .md desde una URL
extraer_video_id() {
    local url="$1" id=""
    url="$(limpiar_url "$url")"
    if [[ "$url" =~ [\?\&]v=([^\&]+) ]]; then
        id="${BASH_REMATCH[1]}"
    else
        id="${url##*/}"
        id="${id%%\?*}"
    fi
    id="${id//\//_}"
    id="${id// /_}"
    [[ -z "$id" ]] && id="video_$(date +%s)"
    printf '%s' "$id"
}

# ---------------------------------------------------------------------------
# Navegador
# ---------------------------------------------------------------------------

abrir_en_navegador() {
    local url="$1"
    local is_macos=0
    [[ "$(uname -s)" == "Darwin" ]] && is_macos=1

    if [[ $is_macos -eq 0 && -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        printf 'Sin entorno gráfico detectado. Abrí manualmente:\n  %s\n' "$url" >&2
        return 1
    fi

    local launchers=()
    if [[ $is_macos -eq 1 ]]; then
        launchers=(open)
    else
        launchers=(xdg-open gio)
    fi

    local browsers=(firefox firefox-esr google-chrome google-chrome-stable
                    chromium brave-browser brave microsoft-edge edge
                    helium-browser helium)
    local cmd
    for cmd in "${launchers[@]}" "${browsers[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            nohup "$cmd" "$url" </dev/null >/dev/null 2>&1 &
            return 0
        fi
    done

    printf 'No se encontró navegador. Abrí manualmente:\n  %s\n' "$url" >&2
    return 1
}

# ---------------------------------------------------------------------------
# Índice de orden de llegada (data/.orden)
# Formato: seq<TAB>epoch<TAB>relpath<TAB>desc
# ---------------------------------------------------------------------------

obtener_next_seq() {
    local last=0
    if [[ -f "$ORDEN_FILE" ]]; then
        last=$(awk -F'\t' 'BEGIN{m=0} ($1+0) > m {m=$1+0} END{print m}' "$ORDEN_FILE" 2>/dev/null || echo 0)
    fi
    printf '%d' "$(( last + 1 ))"
}

registrar_orden() {
    local relpath="$1" desc="$2"
    mkdir -p "$DATA"
    # Si existiera entrada huérfana previa del mismo momento, la reemplaza con seq nuevo
    eliminar_orden "$relpath" "$desc"
    local seq epoch
    seq="$(obtener_next_seq)"
    epoch="$(date +%s)"
    printf '%d\t%s\t%s\t%s\n' "$seq" "$epoch" "$relpath" "$desc" >> "$ORDEN_FILE"
}

actualizar_orden_desc() {
    local relpath="$1" old_desc="$2" new_desc="$3"
    [[ -f "$ORDEN_FILE" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    REL="$relpath" OLD_D="$old_desc" NEW_D="$new_desc" \
    awk -F'\t' 'BEGIN{OFS="\t"} {
        if ($3 == ENVIRON["REL"] && $4 == ENVIRON["OLD_D"]) $4 = ENVIRON["NEW_D"]
        print
    }' "$ORDEN_FILE" > "$tmp"
    mv "$tmp" "$ORDEN_FILE"
}

# $2 vacío => borra todas las entradas del archivo relpath
# $2 == "__ALL_STREAMER__" => borra todo lo del streamer $1
eliminar_orden() {
    local relpath="$1" desc="${2:-}"
    [[ -f "$ORDEN_FILE" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    REL="$relpath" DESC="$desc" \
    awk -F'\t' '{
        if (ENVIRON["DESC"] == "__ALL_STREAMER__") {
            if (index($3, ENVIRON["REL"] "/") == 1) next
        } else if (ENVIRON["DESC"] == "") {
            if ($3 == ENVIRON["REL"]) next
        } else {
            if ($3 == ENVIRON["REL"] && $4 == ENVIRON["DESC"]) next
        }
        print
    }' "$ORDEN_FILE" > "$tmp"
    mv "$tmp" "$ORDEN_FILE"
}

# ---------------------------------------------------------------------------
# Lectura optimizada de datos (single-pass awk)
# ---------------------------------------------------------------------------

listar_streamers() {
    [[ -d "$DATA" ]] || return 0
    local d name
    for d in "$DATA"/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        [[ "$name" == "backup" || "$name" == .* ]] && continue
        printf '%s\n' "$name"
    done | sort
}

# Carga momentos ordenados por orden de llegada (más reciente primero) en un tmpfile.
# Formato de salida ($SEP = \x1f):
#   1:seq | 2:fecha_iso | 3:file_idx | 4:fnr | 5:streamer | 6:secs | 7:minuto | 8:desc | 9:url | 10:fecha_ddmm | 11:relpath
# Parámetros: $1 = filtro_streamer (opcional), $2 = filtro_texto (opcional)
cargar_momentos() {
    local filtro_streamer="${1:-}"
    local filtro_texto="${2:-}"
    local tmp
    tmp="$(mktemp)"

    [[ -d "$DATA" ]] || { printf '%s\n' "$tmp"; return 0; }

    local search_root="$DATA"
    if [[ -n "$filtro_streamer" ]]; then
        search_root="$DATA/$filtro_streamer"
        [[ -d "$search_root" ]] || { printf '%s\n' "$tmp"; return 0; }
    fi

    local -a md_files=()
    local path=""
    if find "$search_root" -maxdepth 0 -printf '' >/dev/null 2>&1; then
        while IFS=$'\t' read -r _ path; do
            [[ -n "$path" ]] && md_files+=("$path")
        done < <(find "$search_root" -type f -name '*.md' -not -path "$BACKUP/*" -printf '%T@\t%p\n' | sort -nr)
    else
        while IFS=$'\t' read -r _ path; do
            [[ -n "$path" ]] && md_files+=("$path")
        done < <(find "$search_root" -type f -name '*.md' -not -path "$BACKUP/*" -exec stat -f '%m	%N' {} + | sort -nr)
    fi

    if [[ ${#md_files[@]} -eq 0 ]]; then
        printf '%s\n' "$tmp"
        return 0
    fi

    local orden_arg=""
    [[ -f "$ORDEN_FILE" ]] && orden_arg="$ORDEN_FILE"

    ORDEN_PATH="$orden_arg" \
    DATA_PREFIX="$DATA/" \
    QUERY_LOWER="$(printf '%s' "$filtro_texto" | tr '[:upper:]' '[:lower:]')" \
    awk '
    BEGIN {
        orden_file = ENVIRON["ORDEN_PATH"]
        data_prefix = ENVIRON["DATA_PREFIX"]
        q_lower = ENVIRON["QUERY_LOWER"]
        if (orden_file != "") {
            while ((getline oline < orden_file) > 0) {
                sub(/\r$/, "", oline)
                n_ord = split(oline, op, "\t")
                if (n_ord >= 4) {
                    seq_map[op[3] SUBSEP op[4]] = op[1] + 0
                }
            }
            close(orden_file)
        }
        file_idx = 0
    }
    FNR == 1 {
        file_idx++
        rel = FILENAME
        if (substr(rel, 1, length(data_prefix)) == data_prefix) {
            rel = substr(rel, length(data_prefix) + 1)
        }
        slash_pos = index(rel, "/")
        streamer = (slash_pos > 0) ? substr(rel, 1, slash_pos - 1) : ""
        url = ""
        fecha_raw = ""
        fecha_ddmm = "??/??"
        fecha_iso = "0000-00-00"
    }
    /^\*\*URL:\*\*/ {
        url = $0
        sub(/^\*\*URL:\*\*[ \t]*/, "", url)
        sub(/\r$/, "", url)
        next
    }
    /^\*\*Fecha:\*\*/ {
        fecha_raw = $0
        sub(/^\*\*Fecha:\*\*[ \t]*/, "", fecha_raw)
        sub(/\r$/, "", fecha_raw)
        if (match(fecha_raw, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/)) {
            fecha_iso = substr(fecha_raw, 1, 10)
            fecha_ddmm = substr(fecha_raw, 9, 2) "/" substr(fecha_raw, 6, 2)
        }
        next
    }
    /^\|/ {
        line = $0
        sub(/\r$/, "", line)
        sub(/^\|[ \t]*/, "", line)
        p1 = index(line, "|")
        if (p1 == 0) next
        secs = substr(line, 1, p1 - 1)
        gsub(/^[ \t]+|[ \t]+$/, "", secs)
        if (secs !~ /^[0-9]+$/) next

        rest = substr(line, p1 + 1)
        p2 = index(rest, "|")
        if (p2 == 0) next
        minuto = substr(rest, 1, p2 - 1)
        gsub(/^[ \t]+|[ \t]+$/, "", minuto)

        desc = substr(rest, p2 + 1)
        sub(/[ \t]*\|[ \t]*$/, "", desc)
        gsub(/^[ \t]+|[ \t]+$/, "", desc)
        gsub(/\t/, " ", desc)
        if (desc == "") next

        n_m = split(minuto, mp, ":")
        if (n_m == 3) {
            minuto_fmt = sprintf("%02d:%02d:%02d", mp[1]+0, mp[2]+0, mp[3]+0)
        } else if (n_m == 2) {
            minuto_fmt = sprintf("%02d:%02d", mp[1]+0, mp[2]+0)
        } else {
            minuto_fmt = minuto
        }

        if (q_lower != "") {
            haystack = tolower(desc " " streamer " " fecha_ddmm " " rel)
            if (index(haystack, q_lower) == 0) next
        }

        seq = 0
        key = rel SUBSEP desc
        if (key in seq_map) {
            seq = seq_map[key]
        }

        printf "%d\037%s\037%09d\037%09d\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", \
            seq, fecha_iso, file_idx, FNR, streamer, secs, minuto_fmt, desc, url, fecha_ddmm, rel
    }
    ' "${md_files[@]}" \
    | LC_ALL=C sort -t"$SEP" -k1,1nr -k2,2r -k3,3n -k4,4n > "$tmp"

    printf '%s\n' "$tmp"
}

# ---------------------------------------------------------------------------
# Menús interactivos
# ---------------------------------------------------------------------------

# Menú de selección de streamer con contador de momentos.
# $1 = prompt título
# $2 = "s" si es el menú raíz (oculta "v) Volver")
# Resultado en $SELECCION ("__ALL__" para Todos).
# Retorna: 0=selección, 1=sin datos, 2=volver, 3=salir
menu_streamers() {
    local prompt="$1"
    local es_raiz="${2:-n}"
    SELECCION=""

    local -a streamers=()
    mapfile -t streamers < <(listar_streamers)

    if [[ ${#streamers[@]} -eq 0 ]]; then
        echo "No hay streamers guardados."
        return 1
    fi

    # Contar momentos por streamer en una sola pasada
    local tmp_all total_all=0
    tmp_all="$(cargar_momentos)"
    declare -A counts=()
    local st
    while IFS="$SEP" read -r _ _ _ _ st _; do
        [[ -z "$st" ]] && continue
        counts["$st"]=$(( ${counts["$st"]:-0} + 1 ))
        total_all=$(( total_all + 1 ))
    done < "$tmp_all"
    rm -f "$tmp_all"

    while true; do
        limpiar
        mostrar_estado
        printf '%b%s%b\n\n' "$C_BOLD" "$prompt" "$C_RESET"
        local i cnt
        for i in "${!streamers[@]}"; do
            st="${streamers[$i]}"
            cnt="${counts[$st]:-0}"
            printf '  %d) %s %b(%d)%b\n' "$((i+1))" "$st" "$C_DIM" "$cnt" "$C_RESET"
        done
        printf '  0) Todos los streamers %b(%d)%b\n' "$C_DIM" "$total_all" "$C_RESET"
        [[ "$es_raiz" != "s" ]] && printf '  v) Volver\n'
        printf '  s) Salir\n\n'

        local opt
        if ! read -rp "> " opt; then
            return 3
        fi
        opt="$(trim "$opt")"
        case "$opt" in
            s|S) return 3 ;;
            v|V)
                if [[ "$es_raiz" != "s" ]]; then
                    return 2
                else
                    set_estado warn "Opción inválida."
                fi
                ;;
            0) SELECCION="__ALL__"; return 0 ;;
            *)
                if [[ "$opt" =~ ^[0-9]+$ ]]; then
                    local idx=$((10#$opt))
                    if (( idx >= 1 && idx <= ${#streamers[@]} )); then
                        SELECCION="${streamers[$((idx-1))]}"
                        return 0
                    fi
                fi
                set_estado warn "Opción inválida: '$opt'"
                ;;
        esac
    done
}

# Menú de momentos con búsqueda en vivo ('b' o '/texto') y paginación automática.
# $1 = prompt título
# $2 = filtro_streamer ("" para todos)
# $3 = "s" si es raíz (sin "v) Volver")
# $4 = modo: "todos" | "streamer" | "auto"
# Resultado en $SELECCION_LINEA ($SEP-delimitado):
#   num | streamer | secs | minuto | desc | url | fecha_ddmm | fecha_iso | relpath
# Retorna: 0=selección, 1=vacío en raíz, 2=volver, 3=salir
menu_momentos() {
    local prompt="$1"
    local filtro_streamer="${2:-}"
    local es_raiz="${3:-n}"
    local modo="${4:-auto}"
    SELECCION_LINEA=""

    local filtro_texto=""
    local page=1
    local -a items=()

    _recargar_items() {
        local tmp
        tmp="$(cargar_momentos "$filtro_streamer" "$filtro_texto")"
        items=()
        mapfile -t items < "$tmp"
        rm -f "$tmp"
    }

    _recargar_items

    if [[ ${#items[@]} -eq 0 ]]; then
        set_estado warn "No hay momentos para mostrar."
        [[ "$es_raiz" != "s" ]] && return 2
        return 1
    fi

    while true; do
        local n=${#items[@]}
        local es_todos=0
        case "$modo" in
            todos)    es_todos=1 ;;
            streamer) es_todos=0 ;;
            *)
                local prev_st="" st_cur="" line_it
                for line_it in "${items[@]}"; do
                    IFS="$SEP" read -r _ _ _ _ st_cur _ <<< "$line_it"
                    if [[ -n "$prev_st" && "$st_cur" != "$prev_st" ]]; then
                        es_todos=1
                        break
                    fi
                    prev_st="$st_cur"
                done
                ;;
        esac

        # Calcular tamaño de página según altura actual de la terminal
        local term_lines page_size total_pages
        term_lines=$(tput lines 2>/dev/null || echo "${LINES:-24}")
        page_size=$(( term_lines - 10 ))
        (( page_size < 10 )) && page_size=10
        total_pages=$(( (n + page_size - 1) / page_size ))
        (( page > total_pages )) && page=$total_pages
        (( page < 1 )) && page=1

        local start_idx=$(( (page - 1) * page_size ))
        local end_idx=$(( start_idx + page_size - 1 ))
        (( end_idx >= n )) && end_idx=$(( n - 1 ))

        limpiar
        mostrar_estado

        if [[ -n "$filtro_texto" ]]; then
            printf '%b%s%b  %b[Filtro: "%s" — %d resultado(s)]%b\n\n' \
                "$C_BOLD" "$prompt" "$C_RESET" "$C_CYAN" "$filtro_texto" "$n" "$C_RESET"
        elif (( total_pages > 1 )); then
            printf '%b%s%b  %b(Página %d/%d — %d momentos)%b\n\n' \
                "$C_BOLD" "$prompt" "$C_RESET" "$C_DIM" "$page" "$total_pages" "$n" "$C_RESET"
        else
            printf '%b%s%b  %b(%d)%b\n\n' \
                "$C_BOLD" "$prompt" "$C_RESET" "$C_DIM" "$n" "$C_RESET"
        fi

        local i num streamer secs minuto desc url fecha fecha_iso relpath
        for (( i = start_idx; i <= end_idx; i++ )); do
            IFS="$SEP" read -r _ fecha_iso _ _ streamer secs minuto desc url fecha relpath <<< "${items[$i]}"
            num=$(( i + 1 ))
            if [[ $es_todos -eq 1 ]]; then
                printf '  %2d) [%s — %s — %s] %s\n' "$num" "$fecha" "$streamer" "$minuto" "$desc"
            else
                printf '  %2d) [%s — %s] %s\n' "$num" "$fecha" "$minuto" "$desc"
            fi
        done

        echo
        if (( total_pages > 1 )); then
            local nav=""
            (( page > 1 )) && nav+="  -) Pág. anterior"
            (( page < total_pages )) && nav+="  +) Pág. siguiente"
            printf '%s\n' "${nav#  }"
        fi
        if [[ -n "$filtro_texto" ]]; then
            printf '  b) Buscar otro texto   l) Limpiar filtro\n'
        else
            printf '  b) Buscar (o /texto)\n'
        fi
        [[ "$es_raiz" != "s" ]] && printf '  v) Volver\n'
        printf '  s) Salir\n\n'

        local opt
        if ! read -rp "> " opt; then
            return 3
        fi
        opt="$(trim "$opt")"

        case "$opt" in
            s|S) return 3 ;;
            v|V)
                if [[ "$es_raiz" != "s" ]]; then
                    return 2
                else
                    set_estado warn "Opción inválida."
                fi
                ;;
            b|B)
                local nueva_busq=""
                if ! read -rp "Buscar texto (vacío para cancelar): " nueva_busq; then
                    return 3
                fi
                nueva_busq="$(trim "$nueva_busq")"
                if [[ -n "$nueva_busq" ]]; then
                    local old_busq="$filtro_texto"
                    filtro_texto="$nueva_busq"
                    _recargar_items
                    if [[ ${#items[@]} -eq 0 ]]; then
                        set_estado warn "Sin resultados para '$filtro_texto'."
                        filtro_texto="$old_busq"
                        _recargar_items
                    else
                        page=1
                    fi
                fi
                ;;
            /*)
                local q_slash="${opt#/}"
                q_slash="$(trim "$q_slash")"
                if [[ -n "$q_slash" ]]; then
                    local old_busq="$filtro_texto"
                    filtro_texto="$q_slash"
                    _recargar_items
                    if [[ ${#items[@]} -eq 0 ]]; then
                        set_estado warn "Sin resultados para '$filtro_texto'."
                        filtro_texto="$old_busq"
                        _recargar_items
                    else
                        page=1
                    fi
                fi
                ;;
            l|L)
                if [[ -n "$filtro_texto" ]]; then
                    filtro_texto=""
                    page=1
                    _recargar_items
                else
                    set_estado warn "No hay filtro activo."
                fi
                ;;
            +|">")
                if (( page < total_pages )); then
                    page=$(( page + 1 ))
                else
                    set_estado warn "Ya estás en la última página."
                fi
                ;;
            -|"<")
                if (( page > 1 )); then
                    page=$(( page - 1 ))
                else
                    set_estado warn "Ya estás en la primera página."
                fi
                ;;
            *)
                if [[ "$opt" =~ ^[0-9]+$ ]]; then
                    local idx=$((10#$opt))
                    if (( idx >= 1 && idx <= n )); then
                        IFS="$SEP" read -r _ fecha_iso _ _ streamer secs minuto desc url fecha relpath <<< "${items[$((idx-1))]}"
                        SELECCION_LINEA="${idx}${SEP}${streamer}${SEP}${secs}${SEP}${minuto}${SEP}${desc}${SEP}${url}${SEP}${fecha}${SEP}${fecha_iso}${SEP}${relpath}"
                        return 0
                    fi
                fi
                set_estado warn "Opción inválida: '$opt'"
                ;;
        esac
    done
}

# Menú genérico de acciones.
# $1 = título del menú
# $2..$N = triplets: "opción" "descripción" "función"
# Retorna: 0=acción ejecutada, 2=volver al menú anterior, 3=salir
submenu_acciones() {
    local titulo="$1"
    shift
    local -a raw=("$@")
    local n=${#raw[@]}
    local -a nums=() descs=() fns=()
    local i
    for ((i=0; i<n; i+=3)); do
        nums+=("${raw[$i]}")
        descs+=("${raw[$i+1]}")
        fns+=("${raw[$i+2]}")
    done

    local opt
    while true; do
        limpiar
        mostrar_estado
        if [[ -n "$titulo" ]]; then
            printf '%b== %s ==%b\n\n' "$C_BOLD" "${titulo^^}" "$C_RESET"
        else
            printf '%b== TODOS ==%b\n\n' "$C_BOLD" "$C_RESET"
        fi
        for i in "${!nums[@]}"; do
            printf '  %s) %s\n' "${nums[$i]}" "${descs[$i]}"
        done
        echo "  v) Volver"
        echo "  s) Salir"
        echo
        if ! read -rp "> " opt; then
            return 3
        fi
        opt="$(trim "$opt")"
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
                    set +e
                    if (( ${#SUBMENU_ARGS[@]} > 0 )); then
                        "$fn" "${SUBMENU_ARGS[@]}"
                    else
                        "$fn"
                    fi
                    fn_rc=$?
                    set -e
                    case $fn_rc in
                        2) continue 2 ;;
                        3) return 3 ;;
                        4) return 2 ;;
                        *) return 0 ;;
                    esac
                fi
                break
            fi
        done
        [[ $found -eq 0 ]] && set_estado warn "Opción inválida: '$opt'"
    done
}

# Confirmación interactiva.
# Retorna: 0=sí, 1=no, 2=volver, 3=salir
confirmar() {
    local prompt="$1"
    local r
    while true; do
        if ! read -rp "$prompt (y/n, 'v' volver, 's' salir): " r; then
            return 3
        fi
        r="$(trim "$r")"
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
    echo "Este archivo es una librería. Ejecutá abrir.sh, edit.sh, remover.sh, ver.sh o momento.sh." >&2
    exit 1
fi
