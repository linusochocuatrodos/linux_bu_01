#!/usr/bin/env bash
#
# procesar_live.sh
# ----------------
# Automatiza lo que se hacía a mano en Kdenlive con un live VOD:
#   1) separa el audio del video (ffmpeg)
#   2) separa voz / música con Demucs (llamando a demuc_ffmpeg.sh, sin modificarlo)
#   3) baja el volumen de la música, le sube el pitch (rubberband) y mezcla
#   4) acelera todo (por defecto +3%) manteniendo el tono (atempo)
#   5) renderiza con NVENC H.264 (calidad constante, VBR)
#
# Uso:
#   ./procesar_live.sh
#   (recomendado dentro de tmux o screen)
#
# Requisitos: ffmpeg (con librubberband y h264_nvenc), ffprobe, demucs,
#             y demuc_ffmpeg.sh en la MISMA carpeta que este script.
#
# Nunca modifica el video original. Todo el trabajo se hace en una subcarpeta
# "_temp_procesamiento" dentro de la carpeta de salida, que se borra al terminar
# bien (y se conserva si algo falla).

set -uo pipefail
export LC_NUMERIC=C   # que awk/printf usen punto decimal, sin importar el idioma del sistema

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
DEMUCS_SCRIPT="${SCRIPT_DIR}/demuc_ffmpeg.sh"

# ---------- Configuración ----------
TEMP_NAME="_temp_procesamiento"
TEST_SECONDS=120          # duración del modo prueba
GPU_REST_SECONDS=15       # pausa justo antes del render NVENC
GPU_REST_DEMUCS_FULL=30   # reposo de la GPU al terminar Demucs (video completo)
GPU_REST_DEMUCS_TEST=10   # reposo de la GPU al terminar Demucs (prueba)
TOL_DEMUCS_WARN=1         # s de diferencia tolerada entre audio y stems de Demucs
TOL_DEMUCS_FATAL=30       # s de diferencia a partir de la cual se considera fallo grave
TOL_AV=1                  # s de diferencia tolerada entre video y audio del resultado

# ---------- Estado global ----------
INPUT=""; OUT_DIR=""; TEMP_DIR=""; WORK=""; ORIG_LINK=""; CODE=""; LOG_FILE=""
TEMP_READY=false
PROBLEMS=(); LOG_DETAILS=""; FULL_PROBLEMS=0; PHASE="Inicio"
SRC_DUR=0; SRC_W=0; SRC_H=0; FPS=30; FULL_RANGE=false
COLOR_ARGS=(); VF=""; AUDIO_FC=""; AUDIO_ORDER=()
CLIP_START=0; CLIP_LEN=0; CLIP_IN_ARGS=()
LAST_ERR=""; REPLY_VAL=""; MODE_NAME=""
VOC_ON=true; VOC_GAIN=0; NOV_ON=true; NOV_GAIN=-15; PITCH_INT=1035; SPEED_INT=103
PITCH_F="1.035"; SPEED_F="1.0300"
T_START=$SECONDS          # momento en que se abrió el script
PROC_START=$SECONDS; T_PROC=0
T_DEMUCS=-1; T_AUDIO=-1; T_RENDER=-1
CQ=26                     # calidad NVENC (menor = más calidad y más peso)
FINAL_OUT=""

ENC_ARGS=()
build_enc_args() {
    ENC_ARGS=(-c:v h264_nvenc -preset p5 -tune hq -rc vbr -cq "$CQ" -b:v 0
              -spatial-aq 1 -temporal-aq 1 -bf 2 -profile:v high -pix_fmt yuv420p)
}

# =====================================================================
#  Utilidades generales
# =====================================================================
say()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1"; }
warn() { printf '   ⚠️  %s\n' "$1"; }

fmt_dur() {
    local t=${1%.*}; t=${t:-0}
    printf '%dh %02dm %02ds' $((t / 3600)) $(((t % 3600) / 60)) $((t % 60))
}

get_duration() {
    local d
    d=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1)
    [[ $d =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$d" || echo 0
}

get_stream_duration() {   # archivo, selector (v:0 / a:0)
    local d
    d=$(ffprobe -v error -select_streams "$2" -show_entries stream=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1)
    [[ $d =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$d" || echo 0
}

# Devuelve 0 (verdadero) si |a-b| > tolerancia
diff_gt() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d>t)}'; }

ask_yn() {   # texto, defecto (S|N). Retorna 0 = sí
    local prompt=$1 def=${2:-S} ans hint="[S/n]"
    [[ $def == N ]] && hint="[s/N]"
    while true; do
        read -r -p "$prompt $hint: " ans || { echo; exit 1; }
        ans=${ans:-$def}
        case "${ans,,}" in
            s|si|sí|y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
        echo "  Respondé con s o n."
    done
}

ask_int() {   # texto, defecto, min, max  -> REPLY_VAL
    local prompt=$1 def=$2 min=$3 max=$4 ans
    while true; do
        read -r -p "$prompt [$def]: " ans || { echo; exit 1; }
        ans=${ans:-$def}
        if [[ $ans =~ ^[0-9]+$ ]]; then
            if (( 10#$ans >= min && 10#$ans <= max )); then
                REPLY_VAL=$((10#$ans)); return 0
            fi
            warn "Fuera de rango: tiene que estar entre $min y $max."
        else
            warn "Escribí solo números enteros, sin puntos ni comas (ej: 1035)."
        fi
    done
}

ask_db() {    # texto, defecto, min, max -> REPLY_VAL (dB, con decimales opcionales)
    local prompt=$1 def=$2 min=$3 max=$4 ans
    while true; do
        read -r -p "$prompt [$def]: " ans || { echo; exit 1; }
        ans=${ans:-$def}; ans=${ans//,/.}; ans=${ans// /}
        if [[ $ans =~ ^[+-]?[0-9]+(\.[0-9]+)?$ ]]; then
            if awk -v v="$ans" -v a="$min" -v b="$max" 'BEGIN{exit !(v>=a && v<=b)}'; then
                REPLY_VAL=$(awk -v v="$ans" 'BEGIN{r=sprintf("%g", v+0); if(r=="-0") r="0"; print r}')
                return 0
            fi
            warn "Fuera de rango: tiene que estar entre $min y $max dB."
        else
            warn "Formato inválido. Ejemplos: -15   -7.5   +3"
        fi
    done
}

# Limpia lo que llega de "read -e": comillas, espacios escapados, ~, file://
clean_path() {
    local p=$1 quoted=false
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    if (( ${#p} >= 2 )); then
        if [[ ${p:0:1} == "'" && ${p: -1} == "'" ]] || [[ ${p:0:1} == '"' && ${p: -1} == '"' ]]; then
            p=${p:1:${#p}-2}; quoted=true
        fi
    fi
    if [[ $p == file://* ]]; then
        p=${p#file://}
        p=$(printf '%b' "${p//%/\\x}")
    elif [[ $quoted == false ]]; then
        p=$(printf '%s' "$p" | sed -E 's/\\(.)/\1/g')
    fi
    if [[ $p == "~" ]]; then p=$HOME
    elif [[ $p == "~/"* ]]; then p="$HOME/${p:2}"
    fi
    printf '%s' "$p"
}

# Ajusta los fps medidos a un valor estándar (25, 30, 29.97, etc.)
snap_fps() {
    awk -v f="$1" 'BEGIN{
        n=split(f,a,"/"); v=(n==2)? ((a[2]>0)? a[1]/a[2] : 0) : f+0;
        if (v<=0) { print ""; exit }
        split("24 24000/1001 25 30 30000/1001 50 60 60000/1001", c, " ");
        best=""; bd=1e9;
        for (i=1;i<=8;i++) {
            m=split(c[i],b,"/"); cv=(m==2)? b[1]/b[2] : b[1]+0;
            d=(v>cv? v-cv : cv-v)/cv;
            if (d<bd) { bd=d; best=c[i] }
        }
        if (bd<=0.01) print best; else printf "%.3f\n", v
    }'
}

# =====================================================================
#  Problemas, log y errores
# =====================================================================
add_problem() {   # resumen [detalle]
    local msg=$1 detail=${2:-}
    PROBLEMS+=("[$PHASE] $msg")
    [[ $PHASE != "Prueba" ]] && FULL_PROBLEMS=$((FULL_PROBLEMS + 1))
    LOG_DETAILS+=$'\n'"### [$PHASE] $msg"$'\n'
    [[ -n $detail ]] && LOG_DETAILS+="$detail"$'\n'
    return 0
}

write_log() {
    [[ ${#PROBLEMS[@]} -gt 0 && -n $OUT_DIR && -n $CODE ]] || return 0
    LOG_FILE="$OUT_DIR/log_${CODE}.txt"
    {
        echo "Log de problemas - procesar_live.sh"
        echo "Fecha:          $(date '+%F %T')"
        echo "Video original: $INPUT"
        echo "Código:         $CODE"
        echo "Parámetros:     vocal=$VOC_ON (${VOC_GAIN} dB) | no-vocal=$NOV_ON (${NOV_GAIN} dB, pitch ${PITCH_INT}) | velocidad=${SPEED_INT} | CQ=${CQ}"
        echo
        echo "Resumen:"
        printf '  - %s\n' "${PROBLEMS[@]}"
        echo
        echo "Detalles:"
        printf '%s\n' "$LOG_DETAILS"
    } > "$LOG_FILE" 2>/dev/null || LOG_FILE=""
}

fatal() {   # mensaje [detalle]
    local msg=$1 detail=${2:-}
    add_problem "ERROR: $msg" "$detail"
    write_log
    echo
    echo "======================================================"
    echo "❌ El proceso falló: $msg"
    if [[ -n $TEMP_DIR && -d $TEMP_DIR ]]; then
        echo "   Se conservó la carpeta temporal para revisar qué pasó:"
        echo "     $TEMP_DIR"
        echo "   Cuando termines de revisarla, borrala a mano."
    fi
    [[ -n $LOG_FILE ]] && echo "   Log con los detalles: $LOG_FILE"
    echo "======================================================"
    exit 1
}

# Borra SOLO la carpeta temporal (o algo dentro de ella), con todas las verificaciones.
safe_rm() {
    local target=$1
    [[ -n $TEMP_DIR && -n $OUT_DIR && -n $target ]] || return 1
    [[ $OUT_DIR != "/" && $TEMP_DIR != "/" ]] || return 1
    [[ "$(basename -- "$TEMP_DIR")" == "$TEMP_NAME" ]] || return 1
    [[ "$(dirname -- "$TEMP_DIR")" == "$OUT_DIR" ]] || return 1
    [[ $target == *"/../"* || $target == *"/.." ]] && return 1
    case "$target" in
        "$TEMP_DIR"|"$TEMP_DIR"/*) ;;
        *) return 1 ;;
    esac
    rm -rf -- "$target"
}

kill_descendants() {
    local pid=$1 c
    for c in $(pgrep -P "$pid" 2>/dev/null); do kill_descendants "$c"; done
    [[ $pid -ne $$ ]] && kill -TERM "$pid" 2>/dev/null
    return 0
}

on_interrupt() {
    trap - INT TERM
    echo
    echo "⚠️  Cancelado por el usuario (Ctrl+C)."
    kill_descendants $$
    sleep 1
    if command -v nvidia-smi >/dev/null 2>&1; then
        timeout 10 nvidia-smi -pl default >/dev/null 2>&1 && echo "   GPU: límite de potencia restaurado."
    fi
    if [[ -n $TEMP_DIR && -d $TEMP_DIR ]]; then
        add_problem "Proceso cancelado por el usuario (Ctrl+C)"
        write_log
        echo "   Se conservó la carpeta temporal: $TEMP_DIR (borrala a mano)."
        [[ -n $LOG_FILE ]] && echo "   Log: $LOG_FILE"
    fi
    exit 130
}

# Ejecuta ffmpeg mostrando el progreso y guardando los errores en LAST_ERR
run_ffmpeg() {   # args de ffmpeg...
    local errf="$WORK/ffmpeg_err.log" rc
    ffmpeg -nostdin -hide_banner -loglevel error -stats "$@" 2>&1 | tee "$errf"
    rc=${PIPESTATUS[0]}
    echo
    if (( rc != 0 )); then
        LAST_ERR=$(tr '\r' '\n' < "$errf" | grep -Ev '^\s*(frame|size|Lsize|video:|audio:)' | tail -n 30)
        return "$rc"
    fi
    return 0
}

# Ejecuta ffmpeg en silencio (para pruebas). Deja el error en LAST_ERR.
quiet_ffmpeg() {
    LAST_ERR=$(ffmpeg -nostdin -hide_banner -loglevel error "$@" 2>&1)
}

# =====================================================================
#  Entrada de rutas
# =====================================================================
ask_input_file() {
    local raw p
    while true; do
        echo
        echo "Ruta del VIDEO ORIGINAL (Tab autocompleta; también podés arrastrar el archivo acá):"
        read -e -r -p "> " raw || { echo; exit 1; }
        p=$(clean_path "$raw")
        [[ -n $p ]] || { warn "No escribiste nada."; continue; }
        [[ -f $p ]] || { warn "No existe ese archivo: $p"; continue; }
        [[ -r $p ]] || { warn "No tengo permiso de lectura sobre ese archivo."; continue; }
        if [[ -z $(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$p" 2>/dev/null | head -n1) ]]; then
            warn "El archivo no tiene pista de video (o ffprobe no puede leerlo)."; continue
        fi
        if [[ -z $(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$p" 2>/dev/null | head -n1) ]]; then
            warn "El archivo no tiene pista de audio."; continue
        fi
        if [[ $(get_duration "$p") == 0 ]]; then
            warn "No pude leer la duración del video."; continue
        fi
        INPUT=$(readlink -f -- "$p")
        return 0
    done
}

ask_output_dir() {
    local raw p
    while true; do
        echo
        echo "Carpeta donde se guardará el video renderizado (y se hará el trabajo temporal):"
        read -e -r -p "> " raw || { echo; exit 1; }
        p=$(clean_path "$raw")
        [[ -n $p ]] || { warn "No escribiste nada."; continue; }
        [[ $p != "/" ]] && p=${p%/}
        if [[ -e $p && ! -d $p ]]; then
            warn "Esa ruta existe pero no es una carpeta."; continue
        fi
        if [[ ! -d $p ]]; then
            if mkdir -p -- "$p" 2>/dev/null; then
                echo "   Carpeta creada: $p"
            else
                warn "No pude crear la carpeta."; continue
            fi
        fi
        if [[ ! -w $p || ! -x $p ]]; then
            warn "No tengo permiso de escritura en esa carpeta."; continue
        fi
        OUT_DIR=$(readlink -f -- "$p")
        if [[ $OUT_DIR == "/" ]]; then
            warn "No uso la raíz del sistema como carpeta de salida."; continue
        fi
        if [[ $OUT_DIR == *"'"* ]]; then
            warn "La ruta no puede contener comillas simples (rompería la concatenación de demuc_ffmpeg.sh)."; continue
        fi
        if [[ $INPUT == "$OUT_DIR/$TEMP_NAME"/* ]]; then
            warn "El video original está dentro de la carpeta temporal: elegí otra carpeta de salida."; continue
        fi
        TEMP_DIR="$OUT_DIR/$TEMP_NAME"
        return 0
    done
}

generate_code() {
    local letters=abcdefghijklmnopqrstuvwxyz
    while true; do
        CODE="${letters:RANDOM%26:1}${letters:RANDOM%26:1}$(printf '%02d' $((RANDOM % 100)))"
        [[ -e "$OUT_DIR/${CODE}_procesado.mp4" ]] && continue
        [[ -e "$OUT_DIR/log_${CODE}.txt" ]] && continue
        compgen -G "$OUT_DIR/prueba_${CODE}*.mp4" >/dev/null && continue
        return 0
    done
}

# =====================================================================
#  Análisis del video y comprobaciones previas
# =====================================================================
probe_source() {
    local info cs cp ct rng pixfmt
    info=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height,pix_fmt,avg_frame_rate,r_frame_rate,color_range,color_space,color_primaries,color_transfer \
        -of default=noprint_wrappers=1 "$INPUT" 2>/dev/null)
    pf() { awk -F= -v k="$1" '$1==k{print substr($0,length(k)+2); exit}' <<<"$info"; }

    SRC_W=$(pf width); SRC_H=$(pf height)
    pixfmt=$(pf pix_fmt); rng=$(pf color_range)
    cs=$(pf color_space); cp=$(pf color_primaries); ct=$(pf color_transfer)

    FPS=$(snap_fps "$(pf avg_frame_rate)")
    [[ -z $FPS ]] && FPS=$(snap_fps "$(pf r_frame_rate)")
    [[ -z $FPS ]] && FPS=30

    if [[ $rng == "pc" || $pixfmt == yuvj* ]]; then FULL_RANGE=true; else FULL_RANGE=false; fi

    valid_tag() { [[ -n $1 && $1 != unknown && $1 != "N/A" && $1 =~ ^[a-z0-9_.-]+$ ]]; }
    COLOR_ARGS=(-color_range tv)
    valid_tag "$cs" && COLOR_ARGS+=(-colorspace "$cs")
    valid_tag "$cp" && COLOR_ARGS+=(-color_primaries "$cp")
    valid_tag "$ct" && COLOR_ARGS+=(-color_trc "$ct")

    SRC_DUR=$(get_duration "$INPUT")
}

fail_early() { PHASE="Inicio"; fatal "$@"; }

preflight_basic() {
    local c f
    say "Comprobando herramientas..."
    for c in ffmpeg ffprobe demucs awk sed; do
        command -v "$c" >/dev/null 2>&1 || fail_early "No se encontró el comando '$c'. Instalalo o revisá tu PATH."
    done
    [[ -f $DEMUCS_SCRIPT ]] || fail_early "No encuentro demuc_ffmpeg.sh en ${SCRIPT_DIR}/ (tiene que estar junto a este script)."

    # Se guarda la salida en variables ANTES de usar grep: con "pipefail", un
    # "ffmpeg | grep -q" falla con código 141 (SIGPIPE) aunque el filtro exista.
    local filters_out encoders_out
    filters_out=$(ffmpeg -hide_banner -filters 2>/dev/null)
    encoders_out=$(ffmpeg -hide_banner -encoders 2>/dev/null)
    for f in rubberband amix atempo alimiter; do
        grep -Eq "^ [A-Z.]+ +$f " <<<"$filters_out" \
            || fail_early "Tu ffmpeg no tiene el filtro '$f'."
    done
    grep -q h264_nvenc <<<"$encoders_out" \
        || fail_early "Tu ffmpeg no tiene el codificador h264_nvenc."

    say "Probando que ffmpeg pueda decodificar tu video (primeros 5 s)..."
    quiet_ffmpeg -t 5 -i "$INPUT" -map 0:v:0 -map 0:a:0 -f null -
    [[ -z $LAST_ERR ]] || fail_early "ffmpeg no pudo decodificar el video. Si es un problema de códecs, probá: sudo dnf swap ffmpeg-free ffmpeg --allowerasing" "$LAST_ERR"
    say "   OK — herramientas y decodificación funcionan."
}

check_disk() {   # segundos de audio a procesar
    local dur=$1 audio_bytes src_bytes need avail
    audio_bytes=$(awk -v d="$dur" 'BEGIN{printf "%d", d*176400}')
    src_bytes=$(stat -L -c %s "$INPUT")
    need=$(( audio_bytes * 7 + src_bytes * 2 + 1073741824 ))
    avail=$(df -PB1 "$OUT_DIR" | awk 'NR==2{print $4}')
    say "Espacio temporal necesario: ~$(numfmt --to=iec "$need") (incluye los WAV intermedios y el video final; se libera al terminar). Libre: $(numfmt --to=iec "$avail")."
    (( avail >= need )) || fatal "No hay espacio suficiente en la carpeta de salida." "Necesario ~$need bytes, disponible $avail bytes."
}

# =====================================================================
#  Construcción de filtros
# =====================================================================
compute_factors() {
    PITCH_F=$(awk -v p="$PITCH_INT" 'BEGIN{printf "%.3f", p/1000}')
    SPEED_F=$(awk -v s="$SPEED_INT" 'BEGIN{printf "%.4f", s/100}')
}

build_video_filter() {
    local vf=""
    (( SPEED_INT != 100 )) && vf+="setpts=PTS/${SPEED_F},"
    vf+="fps=${FPS},"
    if [[ $FULL_RANGE == true ]]; then
        vf+="scale=trunc(iw/2)*2:trunc(ih/2)*2:in_range=pc:out_range=tv,"
    else
        vf+="scale=trunc(iw/2)*2:trunc(ih/2)*2,"
    fi
    vf+="format=yuv420p"
    VF="$vf"
}

# Deja en AUDIO_FC el filtergraph y en AUDIO_ORDER el orden de las entradas (voc / nov)
build_audio_graph() {
    local idx=0 parts=() labels=() chain post=()
    AUDIO_ORDER=()

    if [[ $VOC_ON == true ]]; then
        parts+=("[${idx}:a]aresample=48000,volume=${VOC_GAIN}dB[v]")
        labels+=("[v]"); AUDIO_ORDER+=(voc); idx=$((idx + 1))
    fi
    if [[ $NOV_ON == true ]]; then
        chain="[${idx}:a]volume=${NOV_GAIN}dB"
        (( PITCH_INT != 1000 )) && chain+=",rubberband=pitch=${PITCH_F}"
        chain+=",aresample=48000[n]"
        parts+=("$chain")
        labels+=("[n]"); AUDIO_ORDER+=(nov); idx=$((idx + 1))
    fi

    if (( ${#labels[@]} == 2 )); then
        parts+=("${labels[0]}${labels[1]}amix=inputs=2:normalize=0:duration=longest[m]")
    else
        parts+=("${labels[0]}anull[m]")
    fi

    (( SPEED_INT != 100 )) && post+=("atempo=${SPEED_F}")
    post+=("alimiter=limit=0.98:level=0")
    parts+=("[m]$(IFS=,; echo "${post[*]}")[out]")

    AUDIO_FC=$(IFS=';'; echo "${parts[*]}")
}

# Prueba en pocos segundos los filtros y NVENC con TU video real, antes de gastar tiempo en Demucs
preflight_render() {
    local test_inputs=() o

    say "Probando filtros de audio, filtros de video y NVENC con tu video real..."

    if (( ${#AUDIO_ORDER[@]} > 0 )); then
        for o in "${AUDIO_ORDER[@]}"; do
            test_inputs+=(-f lavfi -i "sine=frequency=440:duration=2:sample_rate=44100")
        done
        quiet_ffmpeg "${test_inputs[@]}" -filter_complex "$AUDIO_FC" -map "[out]" -f null -
        [[ -z $LAST_ERR ]] || fatal "Falló la prueba de los filtros de audio (rubberband/amix/atempo/alimiter)." "$LAST_ERR"
    fi

    quiet_ffmpeg -ss "$CLIP_START" -t 3 -i "$INPUT" -map 0:v:0 -filter:v "$VF" \
        "${ENC_ARGS[@]}" "${COLOR_ARGS[@]}" -f null -
    if [[ -n $LAST_ERR ]]; then
        # Reintento sin las etiquetas de color del original (por si alguna no es válida)
        local first_err=$LAST_ERR
        quiet_ffmpeg -ss "$CLIP_START" -t 3 -i "$INPUT" -map 0:v:0 -filter:v "$VF" \
            "${ENC_ARGS[@]}" -color_range tv -f null -
        if [[ -n $LAST_ERR ]]; then
            fatal "Falló la prueba de video/NVENC." "$LAST_ERR"
        fi
        COLOR_ARGS=(-color_range tv)
        add_problem "No se pudieron conservar las etiquetas de color del original (se usó solo color_range=tv)." "$first_err"
        warn "No se pudieron copiar las etiquetas de color del original; sigo sin ellas."
    fi
    say "   OK — todo funciona con tu video y tu GPU."
}

# =====================================================================
#  Pipeline
# =====================================================================
prepare_temp() {
    local ext
    if [[ $TEMP_READY != true ]]; then
        if [[ -e $TEMP_DIR ]]; then
            warn "Ya existe una carpeta temporal de una ejecución anterior: $TEMP_DIR"
            if ask_yn "¿La borro y empiezo de cero?" N; then
                safe_rm "$TEMP_DIR" || { echo "No pude borrarla de forma segura. Cancelo."; exit 1; }
            else
                echo "Cancelado. Revisá o borrá esa carpeta y volvé a ejecutar."; exit 1
            fi
        fi
        mkdir -p -- "$TEMP_DIR" || fatal "No pude crear la carpeta temporal."
        ext=${INPUT##*.}
        [[ $ext =~ ^[A-Za-z0-9]{1,5}$ ]] || ext=mp4
        ORIG_LINK="$TEMP_DIR/original.$ext"
        ln -sfn -- "$INPUT" "$ORIG_LINK" || fatal "No pude crear el enlace simbólico al video original."
        TEMP_READY=true
    fi
    WORK="$TEMP_DIR/trabajo"
    safe_rm "$WORK" || fatal "Ruta de trabajo no segura, no se borra nada."
    mkdir -p -- "$WORK" || fatal "No pude crear la carpeta de trabajo."
}

run_pipeline() {   # test | full
    local mode=$1 vocals nov final_out rc
    local has_audio=false
    [[ $VOC_ON == true || $NOV_ON == true ]] && has_audio=true

    compute_factors
    build_enc_args
    build_video_filter
    build_audio_graph
    PROC_START=$SECONDS
    T_DEMUCS=-1; T_AUDIO=-1; T_RENDER=-1

    if [[ $mode == test ]]; then
        PHASE="Prueba"; MODE_NAME="prueba"
        CLIP_IN_ARGS=(-ss "$CLIP_START" -t "$CLIP_LEN")
    else
        PHASE="Completo"; MODE_NAME="completo"
        CLIP_START=0; CLIP_LEN=$SRC_DUR; CLIP_IN_ARGS=()
    fi

    echo
    echo "=== Procesando ($MODE_NAME): $(fmt_dur "$CLIP_LEN") de video ==="
    prepare_temp
    check_disk "$CLIP_LEN"
    preflight_render

    # ---- Paso 1: audio ----
    if [[ $has_audio == true ]]; then
        say "[1/5] Extrayendo el audio a WAV (44,1 kHz, estéreo)..."
        run_ffmpeg -y "${CLIP_IN_ARGS[@]}" -i "$ORIG_LINK" -map 0:a:0 -vn -sn -dn \
            -c:a pcm_s16le -ar 44100 -ac 2 -rf64 auto "$WORK/audio.wav" \
            || fatal "ffmpeg falló al extraer el audio." "$LAST_ERR"

        # ---- Paso 2: Demucs ----
        say "[2/5] Separando voz y música con Demucs (puede tardar unos minutos)..."
        local t0=$SECONDS
        ( cd "$WORK" && bash "$DEMUCS_SCRIPT" audio.wav ) </dev/null 2>&1 | tee "$WORK/demucs_general.log"
        rc=${PIPESTATUS[0]}
        (( rc == 0 )) || fatal "demuc_ffmpeg.sh terminó con error (código $rc)." "$(tail -n 40 "$WORK/demucs_general.log")"

        T_DEMUCS=$((SECONDS - t0))
        vocals="$WORK/demucs_work_audio/resultado_final/audio_vocals.wav"
        nov="$WORK/demucs_work_audio/resultado_final/audio_no_vocals.wav"
        [[ -f $vocals && -f $nov ]] || fatal "Demucs no generó los archivos de voz / no-voz esperados." "$(tail -n 40 "$WORK/demucs_general.log")"

        if grep -Eq 'fallaron|Demucs falló|Falta vocals' "$WORK/demucs_general.log"; then
            add_problem "Demucs reportó segmentos con errores." "$(grep -E 'fallaron|Demucs falló|Falta vocals' "$WORK/demucs_general.log")"
        fi

        local d_a d_v d_n
        d_a=$(get_duration "$WORK/audio.wav")
        d_v=$(get_duration "$vocals"); d_n=$(get_duration "$nov")
        if diff_gt "$d_a" "$d_v" "$TOL_DEMUCS_FATAL" || diff_gt "$d_a" "$d_n" "$TOL_DEMUCS_FATAL"; then
            fatal "Faltan segmentos de Demucs: el audio separado difiere en más de ${TOL_DEMUCS_FATAL}s del original (quedaría desincronizado)." \
                  "audio.wav=${d_a}s  vocals=${d_v}s  no_vocals=${d_n}s"
        fi
        if diff_gt "$d_a" "$d_v" "$TOL_DEMUCS_WARN" || diff_gt "$d_a" "$d_n" "$TOL_DEMUCS_WARN"; then
            add_problem "La duración de los audios separados no coincide con el audio original (>${TOL_DEMUCS_WARN}s)." \
                        "audio.wav=${d_a}s  vocals=${d_v}s  no_vocals=${d_n}s"
        fi

        # Reposo extra de la GPU al terminar Demucs
        local rest=$GPU_REST_DEMUCS_FULL
        [[ $mode == test ]] && rest=$GPU_REST_DEMUCS_TEST
        say "Reposo de la GPU tras Demucs: ${rest}s..."
        sleep "$rest"

        # ---- Paso 3: audio final ----
        say "[3/5] Armando el audio final (volumen, pitch, mezcla, velocidad)..."
        t0=$SECONDS
        local inputs=() o
        for o in "${AUDIO_ORDER[@]}"; do
            [[ $o == voc ]] && inputs+=(-i "$vocals")
            [[ $o == nov ]] && inputs+=(-i "$nov")
        done
        run_ffmpeg -y "${inputs[@]}" -filter_complex "$AUDIO_FC" -map "[out]" \
            -c:a pcm_s16le -ar 48000 -ac 2 -rf64 auto "$WORK/audio_final.wav" \
            || fatal "ffmpeg falló al armar el audio final." "$LAST_ERR"
        T_AUDIO=$((SECONDS - t0))

        say "Pausa de ${GPU_REST_SECONDS}s para que la GPU baje a reposo antes del render..."
        sleep "$GPU_REST_SECONDS"
    else
        say "[1-3/5] Sin audio (vocal y no-vocal desactivados): se omiten Demucs y el audio."
    fi

    # ---- Paso 4: render ----
    say "[4/5] Renderizando video con NVENC H.264 (CQ $CQ)..."
    local t_r=$SECONDS
    local render_args=(-y "${CLIP_IN_ARGS[@]}" -i "$ORIG_LINK")
    if [[ $has_audio == true ]]; then
        render_args+=(-i "$WORK/audio_final.wav" -map 0:v:0 -map 1:a:0
                      -c:a aac -b:a 160k -ar 48000 -ac 2)
    else
        render_args+=(-map 0:v:0 -an)
    fi
    render_args+=(-filter:v "$VF" "${ENC_ARGS[@]}" "${COLOR_ARGS[@]}"
                  -movflags +faststart "$WORK/salida.mp4")
    run_ffmpeg "${render_args[@]}" || fatal "ffmpeg falló durante el render con NVENC." "$LAST_ERR"
    T_RENDER=$((SECONDS - t_r))

    # ---- Paso 5: verificaciones ----
    say "[5/5] Verificando el resultado..."
    [[ -s "$WORK/salida.mp4" ]] || fatal "El archivo renderizado no existe o está vacío."
    local expected tol vd ad
    expected=$(awk -v c="$CLIP_LEN" -v f="$SPEED_F" 'BEGIN{printf "%.3f", c/f}')
    tol=$(awk -v e="$expected" 'BEGIN{printf "%.3f", 2 + e*0.001}')
    vd=$(get_stream_duration "$WORK/salida.mp4" v:0)
    if [[ $has_audio == true ]]; then
        ad=$(get_stream_duration "$WORK/salida.mp4" a:0)
        if diff_gt "$vd" "$ad" "$TOL_AV"; then
            add_problem "El video (${vd}s) y el audio (${ad}s) del resultado difieren en más de ${TOL_AV}s."
        fi
    fi
    if diff_gt "$vd" "$expected" "$tol"; then
        add_problem "La duración del video (${vd}s) no coincide con la esperada (${expected}s = original / ${SPEED_F})."
    fi

    # ---- Entrega ----
    if [[ $mode == test ]]; then
        final_out="$OUT_DIR/prueba_${CODE}.mp4"
        local n=2
        while [[ -e $final_out ]]; do final_out="$OUT_DIR/prueba_${CODE}_${n}.mp4"; n=$((n + 1)); done
    else
        final_out="$OUT_DIR/${CODE}_procesado.mp4"
    fi
    mv -n -- "$WORK/salida.mp4" "$final_out" || fatal "No pude mover el resultado a la carpeta de salida."
    [[ -f $final_out ]] || fatal "El resultado no llegó a la carpeta de salida."
    FINAL_OUT=$final_out
    T_PROC=$((SECONDS - PROC_START))
    safe_rm "$WORK"
    return 0
}

# =====================================================================
#  Menús y resumen
# =====================================================================
set_auto_defaults() {
    VOC_ON=true; VOC_GAIN=0
    NOV_ON=true; NOV_GAIN=-15; PITCH_INT=1035
    SPEED_INT=103
    CQ=26
}

cq_label() {
    local q=$1
    if   (( q <= 21 )); then echo "calidad muy alta, archivo grande"
    elif (( q <= 24 )); then echo "calidad alta"
    elif (( q <= 27 )); then echo "equilibrado"
    elif (( q <= 29 )); then echo "más liviano"
    else echo "calidad baja, archivo chico"; fi
}

show_summary() {
    compute_factors
    echo
    echo "================ RESUMEN ================"
    echo " Video original : $INPUT"
    echo "                  ${SRC_W}x${SRC_H}, ${FPS} fps, $(fmt_dur "$SRC_DUR")"
    echo " Carpeta salida : $OUT_DIR"
    echo " Código         : $CODE  ->  ${CODE}_procesado.mp4"
    if [[ $VOC_ON == true ]]; then echo " Vocal          : incluido, ${VOC_GAIN} dB"
    else echo " Vocal          : QUITADO"; fi
    if [[ $NOV_ON == true ]]; then echo " No-vocal       : incluido, ${NOV_GAIN} dB, pitch ${PITCH_INT} (x${PITCH_F})"
    else echo " No-vocal       : QUITADO"; fi
    echo " Velocidad      : ${SPEED_INT} (x${SPEED_F})  ->  duración final ~ $(fmt_dur "$(awk -v d="$SRC_DUR" -v f="$SPEED_F" 'BEGIN{printf "%d", d/f}')")"
    echo " Render         : NVENC H.264, VBR, CQ ${CQ} ($(cq_label "$CQ")), AAC 160k"
    echo "========================================="
}

collect_manual_params() {
    local def
    while true; do
        echo
        echo "--- NO-VOCAL (música / instrumental) ---"
        [[ $NOV_ON == true ]] && def=S || def=N
        if ask_yn "¿Incluir el no-vocal?" "$def"; then
            NOV_ON=true
            ask_db  "Ganancia de volumen en dB (negativo = más bajo, positivo = más alto)" "$NOV_GAIN" -60 20; NOV_GAIN=$REPLY_VAL
            ask_int "Escala de pitch (1000 = sin cambio, 1035 = +3,5%, sin puntos ni comas)" "$PITCH_INT" 500 2000; PITCH_INT=$REPLY_VAL
        else
            NOV_ON=false
        fi

        echo
        echo "--- VOCAL ---"
        [[ $VOC_ON == true ]] && def=S || def=N
        if ask_yn "¿Incluir el vocal?" "$def"; then
            VOC_ON=true
            ask_db "Ganancia de volumen en dB" "$VOC_GAIN" -60 20; VOC_GAIN=$REPLY_VAL
        else
            VOC_ON=false
        fi

        if [[ $VOC_ON == false && $NOV_ON == false ]]; then
            warn "Quitaste vocal y no-vocal: el video final quedaría SIN AUDIO."
            ask_yn "¿Continuar así de todos modos?" N || continue
        fi

        echo
        echo "--- VIDEO ---"
        ask_int "Velocidad final (100 = original, 103 = +3%)" "$SPEED_INT" 50 200; SPEED_INT=$REPLY_VAL
        echo
        echo "Calidad del render (CQ): MENOR número = MÁS calidad y archivo más pesado."
        echo "   20-22 = calidad muy alta (archivo grande)"
        echo "   23    = alta"
        echo "   26    = equilibrada (valor de la edición automática)"
        echo "   28    = más liviana (algo menos de calidad)"
        echo "   30+   = calidad baja, archivo chico"
        ask_int "CQ (15 a 35)" "$CQ" 15 35; CQ=$REPLY_VAL
        return 0
    done
}

ask_test_clip() {
    local max_min=$(( ${SRC_DUR%.*} / 60 ))
    ask_int "Minuto del video donde empieza la prueba (0 = desde el principio)" 0 0 "$max_min"
    CLIP_START=$((REPLY_VAL * 60))
    CLIP_LEN=$(awk -v d="$SRC_DUR" -v s="$CLIP_START" -v t="$TEST_SECONDS" 'BEGIN{r=d-s; if(r>t)r=t; printf "%.3f", r}')
    if awk -v l="$CLIP_LEN" 'BEGIN{exit !(l<5)}'; then
        CLIP_START=0
        CLIP_LEN=$(awk -v d="$SRC_DUR" -v t="$TEST_SECONDS" 'BEGIN{r=d; if(r>t)r=t; printf "%.3f", r}')
        warn "Muy cerca del final: uso el inicio del video."
    fi
}

hsize() { numfmt --to=iec-i --suffix=B --format="%.1f" "$1" 2>/dev/null || echo "$1 B"; }
fps_disp() { awk -v f="$1" 'BEGIN{n=split(f,a,"/"); v=(n==2 && a[2]>0)? a[1]/a[2] : f+0; printf "%.4g", v}'; }
stage_time() { if (( $1 < 0 )); then echo "—"; else fmt_dur "$1"; fi; }

final_report() {
    local p n=0 line="------------------------------------------------------"
    local o_size r_size o_dur r_dur o_w o_h r_w r_h r_fps o_br r_br pct info

    o_size=$(stat -L -c %s "$INPUT"); r_size=$(stat -c %s "$FINAL_OUT")
    o_dur=$SRC_DUR; r_dur=$(get_duration "$FINAL_OUT")
    o_w=$SRC_W; o_h=$SRC_H
    info=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,avg_frame_rate \
           -of default=noprint_wrappers=1 "$FINAL_OUT" 2>/dev/null)
    r_w=$(awk -F= '$1=="width"{print $2; exit}' <<<"$info")
    r_h=$(awk -F= '$1=="height"{print $2; exit}' <<<"$info")
    r_fps=$(fps_disp "$(snap_fps "$(awk -F= '$1=="avg_frame_rate"{print $2; exit}' <<<"$info")")")
    o_br=$(awk -v s="$o_size" -v d="$o_dur" 'BEGIN{printf "%.2f", (d>0)? s*8/d/1000000 : 0}')
    r_br=$(awk -v s="$r_size" -v d="$r_dur" 'BEGIN{printf "%.2f", (d>0)? s*8/d/1000000 : 0}')
    pct=$(awk -v o="$o_size" -v r="$r_size" 'BEGIN{printf "%+.0f%%", (o>0)? (r-o)/o*100 : 0}')

    echo
    echo "======================================================"
    if (( FULL_PROBLEMS == 0 )); then
        echo "✅ Todo salió correcto y sin problemas."
    else
        echo "⚠️  El video se generó, pero hubo problemas:"
        for p in "${PROBLEMS[@]}"; do
            [[ $p == "[Prueba]"* ]] && continue
            echo "   - $p"; n=$((n + 1)); (( n >= 8 )) && break
        done
    fi
    echo "$line"
    printf ' %-16s %-18s %-18s\n' "" "ORIGINAL" "RESULTADO"
    printf ' %-16s %-18s %-18s\n' "Peso" "$(hsize "$o_size")" "$(hsize "$r_size") ($pct)"
    printf ' %-17s %-18s %-18s\n' "Duración" "$(fmt_dur "$o_dur")" "$(fmt_dur "$r_dur")"
    printf ' %-17s %-18s %-18s\n' "Resolución" "${o_w}x${o_h}" "${r_w}x${r_h}"
    printf ' %-16s %-18s %-18s\n' "Fps" "$(fps_disp "$FPS")" "$r_fps"
    printf ' %-16s %-18s %-18s\n' "Bitrate medio" "${o_br} Mbit/s" "${r_br} Mbit/s"
    echo "$line"
    echo " Ajustes usados"
    if [[ $VOC_ON == true ]]; then echo "   Vocal      : ${VOC_GAIN} dB"; else echo "   Vocal      : quitado"; fi
    if [[ $NOV_ON == true ]]; then echo "   No-vocal   : ${NOV_GAIN} dB, pitch ${PITCH_INT} (x${PITCH_F})"; else echo "   No-vocal   : quitado"; fi
    echo "   Velocidad  : ${SPEED_INT} (x${SPEED_F})"
    echo "   Calidad    : CQ ${CQ} ($(cq_label "$CQ"))"
    echo "$line"
    echo " Tiempos"
    echo "   Demucs                     : $(stage_time "$T_DEMUCS")"
    echo "   Audio final                : $(stage_time "$T_AUDIO")"
    echo "   Render final (NVENC)       : $(stage_time "$T_RENDER")"
    echo "   Procesamiento completo     : $(fmt_dur "$T_PROC")"
    echo "   Desde que abriste el script: $(fmt_dur $((SECONDS - T_START)))"
    echo "$line"
    echo " Archivos"
    echo "   Video final: $FINAL_OUT"
    [[ -n $LOG_FILE ]] && echo "   Log        : $LOG_FILE"
    echo "======================================================"
}

# Estima el peso del video completo a partir del archivo de prueba
estimate_full_size() {
    local t_size t_dur full_dur est
    [[ -f $FINAL_OUT ]] || return 0
    t_size=$(stat -c %s "$FINAL_OUT"); t_dur=$(get_duration "$FINAL_OUT")
    full_dur=$(awk -v d="$SRC_DUR" -v f="$SPEED_F" 'BEGIN{printf "%.3f", d/f}')
    est=$(awk -v s="$t_size" -v t="$t_dur" -v f="$full_dur" 'BEGIN{printf "%d", (t>0)? s*f/t : 0}')
    (( est > 0 )) || return 0
    echo "   Peso estimado del video completo con CQ ${CQ}: ~$(hsize "$est")"
    echo "   (aproximado: depende del movimiento de esta parte del video; el original pesa $(hsize "$(stat -L -c %s "$INPUT")"))"
}

finish_full() {
    safe_rm "$TEMP_DIR" || add_problem "No pude borrar la carpeta temporal: $TEMP_DIR (borrala a mano)."
    write_log
    final_report
}

flow_auto() {
    set_auto_defaults
    show_summary
    echo
    read -r -p "Presioná Enter para empezar (Ctrl+C para cancelar)... " _ || exit 1
    run_pipeline full
    finish_full
}

flow_manual() {
    local opt
    set_auto_defaults
    collect_manual_params
    while true; do
        show_summary
        echo
        echo "¿Qué querés hacer?"
        echo "  1) Prueba de $((TEST_SECONDS / 60)) minutos con estos valores"
        echo "  2) Procesar el video completo"
        echo "  3) Cambiar los valores"
        echo "  4) Salir"
        read -r -p "Opción [1-4]: " opt || exit 1
        case "$opt" in
            1)
                ask_test_clip
                run_pipeline test
                echo
                echo "✅ Prueba lista: $FINAL_OUT"
                estimate_full_size
                (( ${#PROBLEMS[@]} > 0 )) && warn "Hubo avisos en la prueba (se guardarán en el log)."
                echo "   Escuchala/mirala y después elegí qué hacer."
                ;;
            2)
                run_pipeline full
                finish_full
                return 0
                ;;
            3) collect_manual_params ;;
            4)
                if [[ -d $TEMP_DIR ]]; then safe_rm "$TEMP_DIR"; fi
                write_log
                echo "Saliendo. Lo que se generó (pruebas / log) quedó en: $OUT_DIR"
                return 0
                ;;
            *) warn "Elegí 1, 2, 3 o 4." ;;
        esac
    done
}

main_menu() {
    local opt
    while true; do
        echo
        echo "=============== MENÚ ==============="
        echo " 1) Edición automática"
        echo " 2) Edición manual"
        echo " 3) Salir"
        echo "===================================="
        read -r -p "Opción [1-3]: " opt || exit 1
        case "$opt" in
            1) flow_auto; return 0 ;;
            2) flow_manual; return 0 ;;
            3) echo "Hasta luego."; return 0 ;;
            *) warn "Elegí 1, 2 o 3." ;;
        esac
    done
}

# Evita que KDE suspenda la PC durante el proceso (si systemd-inhibit funciona)
reexec_with_inhibit() {
    if [[ -z "${PROCESAR_LIVE_INHIBIDO:-}" ]] && command -v systemd-inhibit >/dev/null 2>&1; then
        if systemd-inhibit --what=sleep:idle --who="procesar_live" --why="prueba" true >/dev/null 2>&1; then
            export PROCESAR_LIVE_INHIBIDO=1
            exec systemd-inhibit --what=sleep:idle --who="procesar_live.sh" \
                --why="Procesando video (Demucs + NVENC)" bash "$SELF" "$@"
        fi
    fi
}

main() {
    reexec_with_inhibit "$@"
    trap on_interrupt INT TERM

    echo "======================================================"
    echo "  procesar_live.sh  -  Demucs + pitch + velocidad + NVENC"
    echo "  Tip: correlo dentro de tmux o screen por si se cierra la terminal."
    echo "======================================================"

    command -v ffprobe >/dev/null 2>&1 || { echo "❌ Falta ffprobe."; exit 1; }

    ask_input_file
    ask_output_dir
    generate_code
    probe_source
    preflight_basic
    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
