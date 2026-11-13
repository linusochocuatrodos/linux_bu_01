#!/usr/bin/env bash
#
# demuc_ffmpeg.sh
# ----------------
# Separa un audio largo en voces / no-voces usando Demucs, procesándolo
# en segmentos de 10 minutos para evitar que el paso final de escritura
# (que Demucs arma en RAM) sature la memoria y cuelgue el sistema.
#
# Uso:
#   ./demuc_ffmpeg.sh nombre_del_audio.wav
#
# Requiere: ffmpeg, ffprobe, demucs (en PATH)

set -uo pipefail
# (no uso "set -e" a propósito: si un chunk falla quiero seguir con los
#  demás y avisar al final, en vez de cortar todo el script de golpe)

# ---------- Configuración ----------
SEGMENT_SECONDS=600     # 10 minutos por segmento
DEMUCS_SEGMENT=7        # límite del modelo Transformer (htdemucs), no tocar sin verificar el modelo
DEMUCS_DEVICE="cuda"

# --- Mitigación para el error "Xid 79: GPU has fallen off the bus" ---
# Una pausa entre segmentos le da tiempo a la GPU de bajar a idle de
# forma gradual en vez de cortar la carga de golpe. Esto solo (sin tocar
# power limit ni persistence mode) resultó suficiente en las pruebas.
INTER_CHUNK_PAUSE_SECONDS=8

# ---------- Utilidades ----------
log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
}

fail() {
    printf '\n❌ ERROR: %s\n' "$1" >&2
    exit 1
}

format_duration() {
    local total_seconds=$1
    local h=$(( total_seconds / 3600 ))
    local m=$(( (total_seconds % 3600) / 60 ))
    local s=$(( total_seconds % 60 ))
    printf '%dh %dm %ds' "$h" "$m" "$s"
}

# ---------- Validaciones iniciales ----------
SCRIPT_START=$(date +%s)

if [[ $# -lt 1 ]]; then
    fail "Falta el nombre del archivo de audio. Uso: $0 nombre_del_audio.wav"
fi

INPUT_FILE="$1"

if [[ ! -f "$INPUT_FILE" ]]; then
    fail "No se encontró el archivo '$INPUT_FILE' en esta carpeta."
fi

for cmd in ffmpeg ffprobe demucs; do
    command -v "$cmd" >/dev/null 2>&1 || fail "No se encontró el comando '$cmd'. Instalalo o revisá tu PATH."
done

BASENAME="$(basename "$INPUT_FILE")"
NAME_NO_EXT="${BASENAME%.*}"
WORKDIR="demucs_work_${NAME_NO_EXT}"
CHUNKS_DIR="${WORKDIR}/chunks"
SEPARATED_DIR="${CHUNKS_DIR}/separated/htdemucs"
OUTPUT_DIR="${WORKDIR}/resultado_final"

log "=== Iniciando procesamiento de '$INPUT_FILE' ==="

DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT_FILE" 2>/dev/null)
if [[ -z "$DURATION" ]]; then
    fail "No pude leer la duración del audio con ffprobe. ¿Es un archivo de audio válido?"
fi
DURATION_INT=${DURATION%.*}
log "Duración detectada del audio: $(format_duration "$DURATION_INT") (${DURATION}s)"

mkdir -p "$CHUNKS_DIR" || fail "No pude crear la carpeta de trabajo '$CHUNKS_DIR'."
log "Carpeta de trabajo creada: $WORKDIR/"

# ---------- Paso 1: Cortar el audio en segmentos ----------
log "--- Paso 1/3: Cortando el audio en segmentos de $((SEGMENT_SECONDS / 60)) minutos ---"

ffmpeg -y -v error -i "$INPUT_FILE" -f segment -segment_time "$SEGMENT_SECONDS" \
    -c copy "${CHUNKS_DIR}/parte_%03d.wav"

if [[ $? -ne 0 ]]; then
    fail "ffmpeg falló al cortar el audio en segmentos."
fi

CHUNK_LIST=("${CHUNKS_DIR}"/parte_*.wav)
NUM_CHUNKS=${#CHUNK_LIST[@]}

if [[ $NUM_CHUNKS -eq 0 ]]; then
    fail "No se generó ningún segmento. Revisá el archivo de entrada."
fi

log "Se crearon $NUM_CHUNKS segmento(s) en '$CHUNKS_DIR/'."

# ---------- Paso 2: Procesar cada segmento con Demucs ----------
log "--- Paso 2/3: Separando voces/instrumental con Demucs (segmento por segmento) ---"

FAILED_CHUNKS=()
CHUNK_NUM=0

for chunk in "${CHUNK_LIST[@]}"; do
    CHUNK_NUM=$((CHUNK_NUM + 1))
    CHUNK_BASENAME="$(basename "$chunk")"
    log "  -> Procesando segmento $CHUNK_NUM/$NUM_CHUNKS: $CHUNK_BASENAME"

    CHUNK_START=$(date +%s)

    (
        cd "$CHUNKS_DIR" && \
        demucs --two-stems=vocals --segment="$DEMUCS_SEGMENT" -d "$DEMUCS_DEVICE" "$CHUNK_BASENAME" \
            > "${CHUNK_BASENAME%.wav}_demucs.log" 2>&1
    )
    DEMUCS_EXIT=$?

    CHUNK_END=$(date +%s)
    CHUNK_ELAPSED=$((CHUNK_END - CHUNK_START))

    if [[ $DEMUCS_EXIT -ne 0 ]]; then
        log "     ⚠️  Demucs falló en '$CHUNK_BASENAME' (ver ${CHUNK_BASENAME%.wav}_demucs.log). Sigo con el resto."
        FAILED_CHUNKS+=("$CHUNK_BASENAME")
        continue
    fi

    log "     OK — listo en $(format_duration "$CHUNK_ELAPSED")"

    # Pausa entre segmentos: le da tiempo a la GPU de bajar a idle de
    # forma gradual en vez de cortar la carga de golpe.
    if [[ "$CHUNK_NUM" -lt "$NUM_CHUNKS" ]]; then
        log "     Pausa de ${INTER_CHUNK_PAUSE_SECONDS}s antes del siguiente segmento..."
        sleep "$INTER_CHUNK_PAUSE_SECONDS"
    fi
done

if [[ ${#FAILED_CHUNKS[@]} -gt 0 ]]; then
    log "⚠️  ${#FAILED_CHUNKS[@]} segmento(s) fallaron: ${FAILED_CHUNKS[*]}"
    log "El script va a seguir e intentar armar el resultado final con lo que sí se procesó."
fi

# ---------- Paso 3: Concatenar los resultados ----------
log "--- Paso 3/3: Uniendo los segmentos procesados ---"

if [[ ! -d "$SEPARATED_DIR" ]]; then
    fail "No existe la carpeta de resultados de Demucs ('$SEPARATED_DIR'). Nada para unir."
fi

mkdir -p "$OUTPUT_DIR"

VOCALS_LIST="${WORKDIR}/lista_vocals.txt"
NO_VOCALS_LIST="${WORKDIR}/lista_no_vocals.txt"
> "$VOCALS_LIST"
> "$NO_VOCALS_LIST"

# Orden natural (parte_000, parte_001, ...) asegurado por el sort -V
for dir in $(find "$SEPARATED_DIR" -mindepth 1 -maxdepth 1 -type d | sort -V); do
    v="${dir}/vocals.wav"
    nv="${dir}/no_vocals.wav"
    if [[ -f "$v" && -f "$nv" ]]; then
        printf "file '%s'\n" "$(readlink -f "$v")" >> "$VOCALS_LIST"
        printf "file '%s'\n" "$(readlink -f "$nv")" >> "$NO_VOCALS_LIST"
    else
        log "  ⚠️  Falta vocals.wav o no_vocals.wav en '$dir', se omite del resultado final."
    fi
done

VOCALS_COUNT=$(wc -l < "$VOCALS_LIST")
if [[ "$VOCALS_COUNT" -eq 0 ]]; then
    fail "No hay ningún segmento procesado válido para concatenar."
fi

log "Uniendo $VOCALS_COUNT segmento(s) de voces..."
ffmpeg -y -v error -f concat -safe 0 -i "$VOCALS_LIST" -c copy "${OUTPUT_DIR}/${NAME_NO_EXT}_vocals.wav" \
    || fail "ffmpeg falló al concatenar las pistas de voces."

log "Uniendo $VOCALS_COUNT segmento(s) de instrumental..."
ffmpeg -y -v error -f concat -safe 0 -i "$NO_VOCALS_LIST" -c copy "${OUTPUT_DIR}/${NAME_NO_EXT}_no_vocals.wav" \
    || fail "ffmpeg falló al concatenar las pistas instrumentales."

log "Archivos finales creados en '$OUTPUT_DIR/':"
log "   - ${NAME_NO_EXT}_vocals.wav"
log "   - ${NAME_NO_EXT}_no_vocals.wav"

# ---------- Resumen final ----------
SCRIPT_END=$(date +%s)
TOTAL_ELAPSED=$((SCRIPT_END - SCRIPT_START))

echo ""
echo "======================================================"
if [[ ${#FAILED_CHUNKS[@]} -gt 0 ]]; then
    echo "✅ Proceso terminado CON ADVERTENCIAS."
    echo "   Segmentos fallidos: ${FAILED_CHUNKS[*]}"
else
    echo "✅ Todos los procesos terminaron correctamente."
fi
echo "   Tiempo total: $(format_duration "$TOTAL_ELAPSED")"
echo "   Resultado en: ${OUTPUT_DIR}/"
echo "======================================================"
