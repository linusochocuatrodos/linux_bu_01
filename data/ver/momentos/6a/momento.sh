#!/usr/bin/env bash
# momento.sh — Importa momentos desde momentos.txt hacia data/<streamer>/<video>.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

INPUT="${1:-$ROOT/momentos.txt}"
[[ -f "$INPUT" ]] || { echo "No existe: $INPUT" >&2; exit 1; }

mkdir -p "$DATA"

processed=0
skipped=0

while IFS= read -r line || [[ -n "$line" ]]; do
    # Ignorar líneas vacías y comentarios
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Separar campos (descripción puede tener espacios)
    read -r streamer url minuto desc <<< "$line" || continue

    # Validar campos obligatorios
    if [[ -z "$streamer" || -z "$url" || -z "$minuto" || -z "$desc" ]]; then
        echo "Línea inválida (faltan campos): $line" >&2
        skipped=$((skipped+1))
        continue
    fi

    # Convertir timestamp a segundos
    local_total=""
    if ! local_total="$(timestamp_a_segundos "$minuto")"; then
        echo "Timestamp inválido '$minuto' en: $line" >&2
        skipped=$((skipped+1))
        continue
    fi
    local_minuto="$(formatear_minuto "$minuto")"

    # Extraer ID de video de la URL (último segmento)
    video_id="${url##*/}"
    [[ -z "$video_id" || "$video_id" == "$url" ]] && video_id="$url"

    dir="$DATA/$streamer"
    mkdir -p "$dir"

    file="$dir/$video_id.md"
    fecha="$(date +%Y-%m-%d)"

    # Crear archivo si no existe
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
        # Crear backup inicial
        mkdir -p "$BACKUP/$streamer"
        cp "$file" "$BACKUP/$streamer/$video_id.md"
    fi

    # Evitar duplicados (por descripción)
    if grep -qF "| $desc |" "$file" 2>/dev/null; then
        echo "Duplicado omitido: $streamer/$video_id — $desc"
        skipped=$((skipped+1))
        continue
    fi

    # Insertar nueva línea debajo del header (línea 7)
    local_tmp="$(mktemp)"
    head -n 7 "$file" > "$local_tmp"
    echo "| $local_total | $local_minuto | $desc |" >> "$local_tmp"
    tail -n +8 "$file" >> "$local_tmp"
    mv "$local_tmp" "$file"

    # Agregar al backup si no está ya
    backup_file="$BACKUP/$streamer/$video_id.md"
    if ! grep -qF "| $desc |" "$backup_file" 2>/dev/null; then
        local_tmp_bk="$(mktemp)"
        head -n 7 "$backup_file" > "$local_tmp_bk"
        echo "| $local_total | $local_minuto | $desc |" >> "$local_tmp_bk"
        tail -n +8 "$backup_file" >> "$local_tmp_bk"
        mv "$local_tmp_bk" "$backup_file"
    fi

    echo "OK: $streamer → $video_id @ $local_minuto — $desc"
    processed=$((processed+1))
done < "$INPUT"

# Vaciar el archivo de entrada
> "$INPUT"

echo
echo "Procesados: $processed | Omitidos: $skipped"
