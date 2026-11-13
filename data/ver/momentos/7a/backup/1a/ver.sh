#!/usr/bin/env bash
# ver.sh — Lista todos los momentos guardados en formato plano.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

if [[ ! -d "$DATA" ]]; then
    echo "Sin datos aún. Agregá líneas a momentos.txt y corré ./momento.sh"
    exit 0
fi

mapfile -t files < <(find "$DATA" -type f -name '*.md' -not -path "$DATA/backup/*" | sort)

if [[ ${#files[@]} -eq 0 ]]; then
    echo "Sin momentos guardados."
    exit 0
fi

for f in "${files[@]}"; do
    local_title="$(head -n1 "$f" | sed 's/^# //')"
    local_streamer="${local_title%% — *}"
    local_streamer="${local_streamer// /}"
    local_url="$(grep -m1 '^\*\*URL:\*\*' "$f" | sed 's/^\*\*URL:\*\* //')"
    local_fecha_raw="$(grep -m1 '^\*\*Fecha:\*\*' "$f" | sed 's/^\*\*Fecha:\*\* //')"
    local_fecha_ddmm="??/??"
    local_fecha_iso="0000-00-00"
    if [[ "$local_fecha_raw" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
        local_fecha_ddmm="${BASH_REMATCH[3]}/${BASH_REMATCH[2]}"
        local_fecha_iso="$local_fecha_raw"
    fi

    while IFS='|' read -r _ secs minuto desc _; do
        secs="$(trim "$secs")"
        minuto="$(trim "$minuto")"
        desc="$(trim "$desc")"
        [[ -z "$secs" || "$secs" =~ ^-+$ || "$secs" == "Segundos" ]] && continue
        [[ -z "$desc" || ! "$secs" =~ ^[0-9]+$ ]] && continue
        minuto="$(formatear_minuto "$minuto")"
        printf '%s|%010d|%s|%s|%s|%s|%s\n' \
            "$local_streamer" "$secs" "$minuto" "$desc" "$local_url" "$local_fecha_ddmm" "$local_fecha_iso"
    done < <(tail -n +8 "$f")
done | sort -t'|' -k7,7r -k2,2n | awk -F'|' '{
    printf "%s-%s-%s  %s  ->  %s#t=%d\n", $1, $6, $3, $4, $5, $2+0
}'
