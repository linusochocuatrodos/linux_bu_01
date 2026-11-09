#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"
INPUT="${1:-$ROOT/momentos.txt}"
DATA="$ROOT/data"

[[ -f "$INPUT" ]] || { echo "No existe: $INPUT" >&2; exit 1; }

mkdir -p "$DATA"

tmp="$(mktemp)"
processed=0
skipped=0

while IFS= read -r line || [[ -n "$line" ]]; do
    # limpiar vacías y comentarios
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # separar campos
    read -r streamer url minuto desc <<<"$line" || continue

    # validar
    if [[ -z "$streamer" || -z "$url" || -z "$minuto" || -z "$desc" ]]; then
        echo "Línea inválida: $line" >&2
        skipped=$((skipped+1))
        continue
    fi

    # timestamp a segundos
    h=0
    m=0
    s=0
    if [[ "$minuto" =~ ^([0-9]+):([0-9]+)$ ]]; then
        m="${BASH_REMATCH[1]}"
        s="${BASH_REMATCH[2]}"
    elif [[ "$minuto" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        h="${BASH_REMATCH[1]}"
        m="${BASH_REMATCH[2]}"
        s="${BASH_REMATCH[3]}"
    else
        echo "Timestamp inválido '$minuto' en: $line" >&2
        skipped=$((skipped+1))
        continue
    fi
    total=$(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
    minuto="$(formatear_minuto "$minuto")"

    # extraer ID de video de la URL (último segmento)
    video_id="${url##*/}"
    [[ -z "$video_id" || "$video_id" == "$url" ]] && video_id="$url"

    dir="$DATA/$streamer"
    mkdir -p "$dir"

    # agregar al archivo del streamer (ordenado por timestamp)
    file="$dir/$video_id.md"
    fecha="$(date +%Y-%m-%d)"
    archivo_nuevo=0

    # si el archivo no existe, crear header
    if [[ ! -f "$file" ]]; then
        archivo_nuevo=1
        {
            echo "# $streamer — $video_id"
            echo
            echo "**URL:** $url"
            echo "**Fecha:** $fecha"
            echo
            echo "| Segundos | Minuto | Momento |"
            echo "|---:|---:|:---|"
        } > "$file"
        # crear backup inicial con el header
        mkdir -p "$BACKUP/$streamer"
        cp "$file" "$BACKUP/$streamer/$video_id.md"
    fi

    # si la descripción ya existe, no duplicar
    if grep -qF "| $desc |" "$file" 2>/dev/null; then
        echo "Duplicado omitido: $streamer/$video_id — $desc"
        skipped=$((skipped+1))
        continue
    fi

    # agregar línea al archivo actual (nuevo arriba tras el header)
    tmp_file="$(mktemp)"
    head -n 7 "$file" > "$tmp_file"
    echo "| $total | $minuto | $desc |" >> "$tmp_file"
    tail -n +8 "$file" >> "$tmp_file"
    mv "$tmp_file" "$file"

    # agregar también al backup (si no está ya), preservando todos los momentos originales
    backup_file="$BACKUP/$streamer/$video_id.md"
    if ! grep -qF "| $desc |" "$backup_file" 2>/dev/null; then
        # agregar al backup (nuevo arriba tras el header)
        tmp_bk="$(mktemp)"
        head -n 7 "$backup_file" > "$tmp_bk"
        echo "| $total | $minuto | $desc |" >> "$tmp_bk"
        tail -n +8 "$backup_file" >> "$tmp_bk"
        mv "$tmp_bk" "$backup_file"
    fi

    echo "OK: $streamer → $video_id @ $minuto — $desc"
    processed=$((processed+1))
done < "$INPUT"

# vaciar el archivo de entrada
> "$INPUT"

echo
echo "Procesados: $processed | Omitidos: $skipped"
