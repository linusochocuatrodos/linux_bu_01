#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DATA="$ROOT/data"
BACKUP="$DATA/backup"

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

if [[ ! -d "$DATA" ]]; then
    echo "Sin datos aún. Agregá líneas a momentos.txt y corré ./momento.sh"
    exit 0
fi

mapfile -t files < <(find "$DATA" -type f -name '*.md' -not -path "$DATA/backup/*" | sort)

if [[ ${#files[@]} -eq 0 ]]; then
    echo "Sin momentos guardados."
    exit 0
fi

# streamer|segundos|minuto|desc|url|fecha_ddmm|fecha_iso
for f in "${files[@]}"; do
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
        if [[ -z "$secs" || "$secs" =~ ^-+$ || "$secs" == "Segundos" ]]; then
            continue
        fi
        [[ -z "$desc" || ! "$secs" =~ ^[0-9]+$ ]] && continue
        minuto="$(formatear_minuto "$minuto")"
        printf '%s|%010d|%s|%s|%s|%s|%s\n' "$streamer" "$secs" "$minuto" "$desc" "$url" "$fecha_ddmm" "$fecha_iso"
    done < <(tail -n +8 "$f")
done | sort -t'|' -k7,7r -k2,2n | awk -F'|' '{
    printf "%s-%s-%s  %s  ->  %s#t=%d\n", $1, $6, $3, $4, $5, $2+0
}'
