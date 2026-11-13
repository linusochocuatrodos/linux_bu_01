#!/usr/bin/env bash
# ver.sh — Lista los momentos guardados por orden de llegada (más recientes arriba).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

uso() {
    cat <<'EOF'
Uso:
  ./ver.sh                     Lista todos los momentos (más recientes arriba)
  ./ver.sh <texto>             Filtra por palabra clave
  ./ver.sh -s <streamer>       Filtra por streamer
  ./ver.sh -b <texto>          Filtra por palabra clave
  ./ver.sh -n <cantidad>       Muestra solo los últimos N momentos agregados
  ./ver.sh -u | --urls         Imprime solo las URLs con #t=segundos
  ./ver.sh --stats             Muestra estadísticas de momentos por streamer
  ./ver.sh -h | --help         Muestra esta ayuda
EOF
}

filtro_streamer=""
filtro_texto=""
limite=0
solo_urls=0
ver_stats=0

while (( $# > 0 )); do
    case "$1" in
        -h|--help) uso; exit 0 ;;
        -s|--streamer)
            [[ $# -lt 2 ]] && { echo "Falta nombre de streamer tras $1" >&2; exit 1; }
            filtro_streamer="$2"; shift 2 ;;
        -b|--buscar)
            [[ $# -lt 2 ]] && { echo "Falta texto tras $1" >&2; exit 1; }
            filtro_texto="$2"; shift 2 ;;
        -n|--ultimos)
            [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]] && { echo "Cantidad inválida tras $1" >&2; exit 1; }
            limite="$2"; shift 2 ;;
        -u|--urls) solo_urls=1; shift ;;
        --stats)   ver_stats=1; shift ;;
        -*)
            echo "Opción desconocida: $1" >&2; uso >&2; exit 1 ;;
        *)
            filtro_texto="${filtro_texto:+$filtro_texto }$1"; shift ;;
    esac
done

if [[ ! -d "$DATA" ]] || [[ -z "$(listar_streamers)" ]]; then
    echo "Sin datos aún. Agregá líneas a momentos.txt y corré ./momento.sh"
    exit 0
fi

tmp="$(cargar_momentos "$filtro_streamer" "$filtro_texto")"
trap 'rm -f "${tmp:-}"' EXIT

if [[ ! -s "$tmp" ]]; then
    echo "Sin momentos guardados${filtro_texto:+ para \"$filtro_texto\"}."
    exit 0
fi

if [[ $ver_stats -eq 1 ]]; then
    awk -F"$SEP" '
    {
        total++
        st[$5]++
        vid[$11] = 1
    }
    END {
        n_vids = 0
        for (v in vid) n_vids++
        printf "Total momentos : %d\n", total
        printf "Total videos   : %d\n", n_vids
        printf "\nPor streamer:\n"
        for (s in st) printf "  %-18s %d\n", s, st[s]
    }' "$tmp" | sort -k2,2nr
    exit 0
fi

awk -F"$SEP" -v solo_urls="$solo_urls" -v lim="$limite" '
{
    if (lim > 0 && NR > lim) exit
    url_base = $9
    sub(/#.*$/, "", url_base)
    target = sprintf("%s#t=%d", url_base, $6 + 0)
    if (solo_urls == 1) {
        print target
    } else {
        printf "%s-%s-%s  %s  ->  %s\n", $5, $10, $7, $8, target
    }
}' "$tmp"
