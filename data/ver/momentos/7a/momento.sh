#!/usr/bin/env bash
# momento.sh — Importa momentos desde momentos.txt (o CLI / modo interactivo) hacia data/<streamer>/<video>.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

uso() {
    cat <<'EOF'
Uso:
  ./momento.sh                               Procesa momentos.txt
  ./momento.sh <archivo.txt>                 Procesa un archivo específico
  ./momento.sh -i | --interactivo            Carga momentos interactivamente
  ./momento.sh <streamer> <url> <min> <desc> Agrega un momento directo por CLI

Notas:
  - Formato de línea: <streamer> <url> <M:SS o H:MM:SS> <descripción>
  - Si usás '-' como minuto y la URL trae #t=SEG o ?t=SEG, extrae el tiempo automático.
  - Los momentos nuevos suben automáticamente arriba del todo (orden de llegada).
EOF
}

ya_existe_desc() {
    local file="$1" desc="$2"
    [[ -f "$file" ]] || return 1
    DESC="$desc" awk '
    NR <= 7 { next }
    /^\|/ {
        line = $0
        sub(/\r$/, "", line)
        sub(/^\|[ \t]*/, "", line)
        p1 = index(line, "|")
        if (p1 == 0) next
        rest = substr(line, p1 + 1)
        p2 = index(rest, "|")
        if (p2 == 0) next
        d = substr(rest, p2 + 1)
        sub(/[ \t]*\|[ \t]*$/, "", d)
        gsub(/^[ \t]+|[ \t]+$/, "", d)
        if (d == ENVIRON["DESC"]) { found = 1; exit 0 }
    }
    END { exit (found ? 0 : 1) }
    ' "$file"
}

insertar_fila_md() {
    local file="$1" total="$2" minuto="$3" desc="$4"
    local tmp
    tmp="$(mktemp)"
    head -n 7 "$file" > "$tmp"
    printf '| %s | %s | %s |\n' "$total" "$minuto" "$desc" >> "$tmp"
    tail -n +8 "$file" >> "$tmp"
    mv "$tmp" "$file"
}

# Procesa una línea con formato: streamer url minuto desc
# Retorna: 0=agregado, 1=error de formato/validación, 2=duplicado omitido
procesar_linea() {
    local raw_line="$1"
    raw_line="${raw_line%$'\r'}"
    raw_line="$(trim "$raw_line")"

    local streamer="" url="" minuto="" desc=""
    read -r streamer url minuto desc <<< "$raw_line" || true
    desc="$(trim "$desc")"

    if [[ -z "$streamer" || -z "$url" || -z "$minuto" || -z "$desc" ]]; then
        echo "Línea inválida (faltan campos): $raw_line" >&2
        return 1
    fi

    if [[ "$streamer" == "backup" || "$streamer" == "." || "$streamer" == ".." || "$streamer" == */* ]]; then
        echo "Nombre de streamer inválido '$streamer' en: $raw_line" >&2
        return 1
    fi

    if [[ "$url" != *.*/* ]]; then
        echo "URL inválida '$url' en: $raw_line" >&2
        return 1
    fi

    # Si minuto == "-" intenta extraer ?t= o #t= desde la URL
    if [[ "$minuto" == "-" ]]; then
        if [[ "$url" =~ [\#\?\&]t=([0-9]+) ]]; then
            minuto="$(segundos_a_timestamp "${BASH_REMATCH[1]}")"
        else
            echo "No se pudo extraer timestamp de la URL en: $raw_line" >&2
            return 1
        fi
    fi

    local total=""
    if ! total="$(timestamp_a_segundos "$minuto")"; then
        echo "Timestamp inválido '$minuto' en: $raw_line" >&2
        return 1
    fi
    local minuto_fmt
    minuto_fmt="$(formatear_minuto "$minuto")"

    # Limpiar #t=... y sanitizar descripción para tablas markdown y .orden
    url="$(limpiar_url "$url")"
    desc="${desc//|/│}"
    desc="${desc//$'\t'/ }"
    desc="$(trim "$desc")"

    local video_id
    video_id="$(extraer_video_id "$url")"

    local dir="$DATA/$streamer"
    mkdir -p "$dir"
    local file="$dir/$video_id.md"
    local fecha
    fecha="$(date +%Y-%m-%d)"

    if [[ ! -f "$file" ]]; then
        {
            echo "# $streamer — $video_id"
            echo
            echo "**URL:** $url"
            echo "**Fecha:** $fecha"
            echo
            echo "| Segundos | Minuto | Momento |"
            echo "|---:|---:|:---|"
        } > "$file"
    fi

    # Crear backup inicial SOLO si no existía (jamás sobrescribir backups previos)
    local backup_dir="$BACKUP/$streamer"
    local backup_file="$backup_dir/$video_id.md"
    if [[ ! -f "$backup_file" ]]; then
        mkdir -p "$backup_dir"
        head -n 7 "$file" > "$backup_file"
    fi

    if ya_existe_desc "$file" "$desc"; then
        echo "Duplicado omitido: $streamer/$video_id — $desc"
        return 2
    fi

    insertar_fila_md "$file" "$total" "$minuto_fmt" "$desc"

    if ! ya_existe_desc "$backup_file" "$desc"; then
        insertar_fila_md "$backup_file" "$total" "$minuto_fmt" "$desc"
    fi

    # Registrar orden de llegada en data/.orden
    registrar_orden "$streamer/$video_id.md" "$desc"

    printf '%bOK:%b %s → %s @ %s — %s\n' "$C_GREEN" "$C_RESET" "$streamer" "$video_id" "$minuto_fmt" "$desc"
    return 0
}

modo_interactivo() {
    local processed=0 skipped=0
    echo "=== Agregar momentos (interactivo) ==="
    echo "Dejá el streamer vacío o presioná Ctrl+C para terminar."
    echo

    while true; do
        local st url min desc
        read -rp "Streamer: " st || break
        st="$(trim "$st")"
        [[ -z "$st" ]] && break

        read -rp "URL del video: " url || break
        url="$(trim "$url")"

        read -rp "Minuto (M:SS, H:MM:SS, o '-' si URL tiene #t=): " min || break
        min="$(trim "$min")"

        read -rp "Descripción: " desc || break
        desc="$(trim "$desc")"

        local rc=0
        procesar_linea "$st $url $min $desc" || rc=$?
        if [[ $rc -eq 0 ]]; then
            processed=$((processed+1))
        else
            skipped=$((skipped+1))
        fi
        echo
    done

    echo "Procesados: $processed | Omitidos: $skipped"
}

# ---------------------------------------------------------------------------
# Entrada principal
# ---------------------------------------------------------------------------

mkdir -p "$DATA"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    uso
    exit 0
fi

if [[ "${1:-}" == "-i" || "${1:-}" == "--interactivo" ]]; then
    modo_interactivo
    exit 0
fi

# Carga directa por CLI: ./momento.sh streamer url minuto descripción...
if (( $# >= 4 )); then
    st="$1"; url="$2"; min="$3"
    shift 3
    desc="$*"
    rc=0
    procesar_linea "$st $url $min $desc" || rc=$?
    [[ $rc -eq 0 ]] && exit 0 || exit 1
fi

INPUT="${1:-$ROOT/momentos.txt}"
if [[ ! -f "$INPUT" ]]; then
    if [[ $# -eq 0 ]]; then
        : > "$INPUT"
    else
        echo "No existe: $INPUT" >&2
        exit 1
    fi
fi

# Verificar si hay al menos una línea útil antes de procesar
tiene_lineas=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$(trim "$line")" || "$line" =~ ^[[:space:]]*# ]] && continue
    tiene_lineas=1
    break
done < "$INPUT"

if [[ $tiene_lineas -eq 0 ]]; then
    if [[ $# -eq 0 && -t 0 ]]; then
        read -rp "momentos.txt está vacío. ¿Querés agregar un momento ahora? (y/n): " resp || exit 0
        if [[ "$resp" =~ ^(y|Y|si|SI|yes|YES)$ ]]; then
            modo_interactivo
            exit 0
        fi
    fi
    echo "Procesados: 0 | Omitidos: 0"
    exit 0
fi

processed=0
skipped=0
error_lines=()

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$(trim "$line")" || "$line" =~ ^[[:space:]]*# ]] && continue

    rc=0
    procesar_linea "$line" || rc=$?
    case $rc in
        0) processed=$((processed+1)) ;;
        2) skipped=$((skipped+1)) ;;
        *)
            skipped=$((skipped+1))
            error_lines+=("$line")
            ;;
    esac
done < "$INPUT"

# Si todas las líneas fueron válidas (o duplicados ya guardados), vacía el archivo.
# Si hubo errores de sintaxis/timestamp, conserva solo las líneas con error para no perderlas.
if [[ -w "$INPUT" && "$INPUT" != "/dev/stdin" ]]; then
    if (( ${#error_lines[@]} == 0 )); then
        : > "$INPUT"
    else
        printf '%s\n' "${error_lines[@]}" > "$INPUT"
        printf '\n%b⚠ %d línea(s) con error quedaron en %s para que las corrijas.%b\n' \
            "$C_YELLOW" "${#error_lines[@]}" "$INPUT" "$C_RESET" >&2
    fi
fi

echo
echo "Procesados: $processed | Omitidos: $skipped"
