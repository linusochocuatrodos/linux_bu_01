#!/usr/bin/env bash
#
# procesar_live.sh (Versión Definitiva)
# -------------------------------------
# Automatiza el procesado de live VODs (probado para Nobara/Fedora KDE + NVIDIA):
#   1) Extrae el audio del video (ffmpeg)
#   2) Separa voz / música con Demucs (llamando a demuc_ffmpeg.sh)
#   3) Ajusta volumen, pitch (rubberband), normalización opcional y mezcla
#   4) Ajusta velocidad de audio (atempo encadenado) y video (setpts + CFR)
#   5) Renderiza por GPU con NVENC (H.264 / HEVC) con progreso en vivo y control térmico
#
# Características clave:
#   - 100% compatible con procesar_live_auto.conf, historial_procesar_live.txt y demuc_ffmpeg.sh
#   - Menú principal inmediato (no pide video solo para ver historial, editar auto o diagnosticar)
#   - Caché de pruebas: re-probar el mismo minuto con otros ajustes NO repite Demucs
#   - Reanudación (checkpoint): si falla el render tras Demucs, podés reanudar sin rehacer Demucs
#   - Alineación automática A/V cuando el VOD original tiene distinto start_time entre video y audio
#   - NVDEC (-hwaccel cuda) autodetectado con fallback transparente a CPU ante fallos
#   - Btrfs NOCOW automático (chattr +C) sobre _temp_procesamiento para máximo I/O sin fragmentación
#   - Cola / Procesamiento por lotes (Batch), Perfiles (Presets), Estadísticas del historial y Doctor
#   - Modo CLI completo (--auto, --batch, --preset, --doctor, --dry-run, etc.)

set -uo pipefail
export LC_NUMERIC=C

OUTPUT_BASE_DIR="${OUTPUT_BASE_DIR:-$HOME}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
DEMUCS_SCRIPT="${DEMUCS_SCRIPT:-}"

# ---------- Archivos y constantes ----------
TEMP_NAME="_temp_procesamiento"
CONFIG_FILE="${SCRIPT_DIR}/procesar_live_auto.conf"
HISTORY_FILE="${SCRIPT_DIR}/historial_procesar_live.txt"
PRESETS_DIR="${SCRIPT_DIR}/presets_procesar_live"

TEST_SECONDS=120          # duración del modo prueba
GPU_REST_SECONDS=15       # pausa previa al render NVENC
GPU_REST_DEMUCS_FULL=30   # reposo tras Demucs (completo)
GPU_REST_DEMUCS_TEST=10   # reposo tras Demucs (prueba)
GPU_MAX_TEMP=78           # °C límite antes de esperar enfriamiento extra (si nvidia-smi existe)
GPU_COOL_TIMEOUT=90       # segundos máx. de espera extra térmica
TOL_DEMUCS_WARN=1         # s de diferencia tolerada entre audio y stems
TOL_DEMUCS_FATAL=30       # s de diferencia considerada error grave
TOL_AV=1                  # s de diferencia tolerada entre video y audio final

# ---------- Colores adaptativos ----------
USE_COLOR=true
if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
    USE_COLOR=false
fi
setup_colors() {
    if [[ $USE_COLOR == true ]]; then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[31;1m'
        C_GREEN=$'\033[32;1m'
        C_YELLOW=$'\033[33;1m'
        C_CYAN=$'\033[36;1m'
    else
        C_RESET=""; C_BOLD=""; C_DIM=""
        C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
    fi
}

# ---------- Estado global ----------
INPUT=""; OUT_DIR=""; TEMP_DIR=""; WORK=""; ORIG_LINK=""; CODE=""; LOG_FILE=""; LOCK_FILE=""
TEMP_READY=false
PROBLEMS=(); LOG_DETAILS=""; FULL_PROBLEMS=0; PHASE="Inicio"

SRC_DUR=0; SRC_W=0; SRC_H=0; DISP_W=0; DISP_H=0; SRC_ROT=0; FPS=30
V_START=0; A_START=0; V_DUR=0; A_DUR=0; AV_START_DIFF=0; AV_DUR_DIFF=0
FULL_RANGE=false; IS_HDR=false; SRC_SIG=""

COLOR_ARGS=(); DECODE_ARGS=(); VF=""; AUDIO_FC=""; AUDIO_ORDER=()
CLIP_START=0; CLIP_LEN=0; CLIP_IN_ARGS=()
LAST_ERR=""; REPLY_VAL=""; MODE_NAME=""
ACTIVE_CHILD_PID=""

# Parámetros de edición (valores por defecto si no existe .conf)
VOC_ON=true; VOC_GAIN=0; PITCH_VOC_INT=1000
NOV_ON=true; NOV_GAIN=0; PITCH_INT=1000
SPEED_INT=100; CQ=26
VIDEO_CODEC="h264_nvenc"  # h264_nvenc | hevc_nvenc
NVENC_PRESET="p5"         # p4 (rápido) | p5 (equilibrado) | p6 (máx calidad)
NVDEC_MODE="auto"         # auto | off
AUDIO_BR="160k"           # 128k | 160k | 192k | 256k | 320k
LOUDNORM_ON=false         # false | true
NAMING_MODE="code"        # code | name_code
ALIMITER_VAL="0.95"       # margen seguro contra clipping inter-muestra AAC

PITCH_VOC_F="1.000"; PITCH_F="1.000"; SPEED_F="1.0000"

# Capacidades detectadas
TOOLS_OK=false
FILTERS_CACHE=""; ENCODERS_CACHE=""
HAS_NVIDIA_SMI=false; HAS_NOTIFY=false; HAS_TONEMAP=false
GPU_NAME=""

# Tiempos y estado de corrida
T_START=$SECONDS
PROC_START=$SECONDS; T_PROC=0
T_DEMUCS=-1; T_AUDIO=-1; T_RENDER=-1
FINAL_OUT=""; RUN_KIND=""
HISTORY_ACTIVE=false; HISTORY_RECORDED=false
RESUMED_FROM_CACHE=false

# CLI overrides
CLI_MODE=""
CLI_INPUT=""; CLI_OUT=""; CLI_PRESET=""
CLI_BATCH_FILES=()
CLI_SET_VOC_ON=""; CLI_SET_VOC_GAIN=""; CLI_SET_VOC_PITCH=""
CLI_SET_NOV_ON=""; CLI_SET_NOV_GAIN=""; CLI_SET_NOV_PITCH=""
CLI_SET_SPEED=""; CLI_SET_CQ=""; CLI_SET_CODEC=""; CLI_SET_PRESET=""

# =====================================================================
#  UI y Utilidades generales
# =====================================================================
say()  { printf '%s[%s]%s %s\n' "$C_DIM" "$(date '+%H:%M:%S')" "$C_RESET" "$1"; }
ok()   { printf '%s✅ %s%s\n' "$C_GREEN" "$1" "$C_RESET"; }
warn() { printf '%s⚠️  %s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
err()  { printf '%s❌ %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; }
hr()   { printf '%s──────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"; }

fmt_dur() {
    local t=${1%.*}; t=${t:-0}
    (( t < 0 )) && t=0
    printf '%dh %02dm %02ds' $((t / 3600)) $(((t % 3600) / 60)) $((t % 60))
}

hsize() {
    numfmt --to=iec-i --suffix=B --format="%.1f" "$1" 2>/dev/null || echo "${1} B"
}

fps_disp() {
    awk -v f="$1" 'BEGIN{n=split(f,a,"/"); v=(n==2 && a[2]>0)? a[1]/a[2] : f+0; printf "%.4g", v}'
}

stage_time() {
    if (( $1 < 0 )); then echo "—"; else fmt_dur "$1"; fi
}

get_duration() {
    local d
    d=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1)
    [[ $d =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$d" || echo 0
}

get_stream_duration() {
    local d
    d=$(ffprobe -v error -select_streams "$2" -show_entries stream=duration -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n1)
    if [[ $d =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "$d"
    else
        get_duration "$1"
    fi
}

diff_gt() {
    awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d>t)}'
}

ask_yn() {
    local prompt=$1 def=${2:-S} ans hint="[S/n]"
    [[ $def == N ]] && hint="[s/N]"
    while true; do
        read -r -p "$prompt $hint: " ans || { echo; return 1; }
        ans=${ans:-$def}
        case "${ans,,}" in
            s|si|sí|y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
        echo "  Respondé con s o n."
    done
}

ask_int() {
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
            warn "Escribí solo números enteros, sin puntos ni comas (ej: 1020)."
        fi
    done
}

ask_db() {
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

url_decode_pct() {
    awk -v s="$1" 'BEGIN{
        out=""
        for(i=1; i<=length(s); i++){
            c=substr(s,i,1)
            if(c=="%" && substr(s,i+1,2) ~ /^[0-9A-Fa-f]{2}$/){
                h=tolower(substr(s,i+1,2)); v=0
                for(j=1;j<=2;j++){
                    d=index("0123456789abcdef", substr(h,j,1))-1
                    v=v*16+d
                }
                out=out sprintf("%c", v); i+=2
            } else { out=out c }
        }
        printf "%s", out
    }'
}

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
        p=${p#file://}; p=${p#localhost}
        p=$(url_decode_pct "$p")
    elif [[ $quoted == false ]]; then
        p=$(printf '%s' "$p" | sed -E 's/\\(.)/\1/g')
    fi
    if [[ $p == "~" ]]; then p=$HOME
    elif [[ $p == "~/"* ]]; then p="$HOME/${p:2}"
    fi
    printf '%s' "$p"
}

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

notify_user() {
    local title=$1 body=$2
    printf '\a' 2>/dev/null || true
    if [[ $HAS_NOTIFY == true ]]; then
        notify-send -a "procesar_live.sh" "$title" "$body" 2>/dev/null || true
    fi
}

# =====================================================================
#  Problemas, log, lockfile y señales
# =====================================================================
reset_run_state() {
    PROBLEMS=()
    LOG_DETAILS=""
    FULL_PROBLEMS=0
    LOG_FILE=""
    FINAL_OUT=""
    T_DEMUCS=-1; T_AUDIO=-1; T_RENDER=-1; T_PROC=0
    RESUMED_FROM_CACHE=false
    TEMP_READY=false
}

add_problem() {
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
        echo "Parámetros:     vocal=$VOC_ON (${VOC_GAIN} dB, pitch ${PITCH_VOC_INT}) | no-vocal=$NOV_ON (${NOV_GAIN} dB, pitch ${PITCH_INT}) | velocidad=${SPEED_INT} | ${VIDEO_CODEC} ${NVENC_PRESET} CQ=${CQ} | AAC ${AUDIO_BR}"
        echo
        echo "Resumen:"
        printf '  - %s\n' "${PROBLEMS[@]}"
        echo
        echo "Detalles:"
        printf '%s\n' "$LOG_DETAILS"
    } > "$LOG_FILE" 2>/dev/null || LOG_FILE=""
}

release_lock() {
    [[ -n $LOCK_FILE && -f $LOCK_FILE ]] && rm -f -- "$LOCK_FILE" 2>/dev/null || true
    LOCK_FILE=""
}

acquire_lock() {
    local lf="$TEMP_DIR/.lock" old_pid
    if [[ -f $lf ]]; then
        old_pid=$(head -n1 "$lf" 2>/dev/null || true)
        if [[ $old_pid =~ ^[0-9]+$ ]] && [[ $old_pid -ne $$ ]] && kill -0 "$old_pid" 2>/dev/null; then
            fatal "Hay otra instancia de procesar_live.sh usando $TEMP_DIR (PID $old_pid)."
            return 1
        fi
    fi
    printf '%s\n%s\n' "$$" "$(date '+%F %T')" > "$lf" 2>/dev/null || return 1
    LOCK_FILE="$lf"
    return 0
}

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

fatal() {
    local msg=$1 detail=${2:-}
    add_problem "ERROR: $msg" "$detail"
    write_log
    release_lock
    if [[ ${HISTORY_ACTIVE:-false} == true && ${HISTORY_RECORDED:-false} != true ]]; then
        history_record "Procesamiento finalizado con error" "$msg"
        HISTORY_ACTIVE=false
    fi
    echo
    echo "======================================================"
    err "El proceso falló: $msg"
    if [[ -n $TEMP_DIR && -d $TEMP_DIR ]]; then
        echo "   Se conservó la carpeta temporal (y caché de Demucs si ya terminó):"
        echo "     $TEMP_DIR"
        echo "   Podés reanudar el proceso volviendo a elegir la misma carpeta de salida,"
        echo "   o borrarla a mano si ya no la necesitás."
    fi
    [[ -n $LOG_FILE ]] && echo "   Log con los detalles: $LOG_FILE"
    echo "======================================================"
    notify_user "Error en procesar_live.sh" "$msg"
    return 1
}

kill_descendants() {
    local pid=$1 c
    if command -v pgrep >/dev/null 2>&1; then
        for c in $(pgrep -P "$pid" 2>/dev/null || true); do
            kill_descendants "$c"
        done
    fi
    [[ $pid -ne $$ ]] && kill -TERM "$pid" 2>/dev/null || true
    return 0
}

on_interrupt() {
    trap - INT TERM
    echo
    warn "Cancelado por el usuario (Ctrl+C)."
    if [[ -n $ACTIVE_CHILD_PID ]] && kill -0 "$ACTIVE_CHILD_PID" 2>/dev/null; then
        kill -TERM "$ACTIVE_CHILD_PID" 2>/dev/null || true
    fi
    kill_descendants $$
    sleep 1
    release_lock
    if [[ -n $TEMP_DIR && -d $TEMP_DIR ]]; then
        add_problem "Proceso cancelado por el usuario (Ctrl+C)"
        write_log
        echo "   Se conservó la carpeta temporal: $TEMP_DIR"
        [[ -n $LOG_FILE ]] && echo "   Log: $LOG_FILE"
    fi
    if [[ ${HISTORY_ACTIVE:-false} == true && ${HISTORY_RECORDED:-false} != true ]]; then
        history_record "Procesamiento cancelado" "Cancelado por el usuario"
        HISTORY_ACTIVE=false
    fi
    exit 130
}

# =====================================================================
#  GPU y Monitoreo Térmico
# =====================================================================
detect_gpu_tools() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)
        [[ -n $GPU_NAME ]] && HAS_NVIDIA_SMI=true
    fi
    command -v notify-send >/dev/null 2>&1 && HAS_NOTIFY=true
}

gpu_temp_now() {
    [[ $HAS_NVIDIA_SMI == true ]] || { echo ""; return 0; }
    nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -dc '0-9' || true
}

gpu_cool_rest() {
    local min_sec=$1 label=$2
    local t
    t=$(gpu_temp_now)
    if [[ -n $t ]]; then
        say "$label (${min_sec}s mínimos; GPU actual: ${t}°C)..."
    else
        say "$label (${min_sec}s)..."
    fi
    sleep "$min_sec"

    if [[ $HAS_NVIDIA_SMI == true ]]; then
        local waited=0
        while true; do
            t=$(gpu_temp_now)
            [[ -z $t ]] && break
            (( t <= GPU_MAX_TEMP )) && break
            (( waited >= GPU_COOL_TIMEOUT )) && { warn "GPU aún a ${t}°C tras ${GPU_COOL_TIMEOUT}s extra; continúo igual."; break; }
            printf '\r   🌡️  GPU a %s°C (>%s°C): esperando enfriamiento (%ds/%ds)... ' "$t" "$GPU_MAX_TEMP" "$waited" "$GPU_COOL_TIMEOUT"
            sleep 5
            waited=$((waited + 5))
        done
        (( waited > 0 )) && echo
    fi
}

# =====================================================================
#  Ejecución de FFmpeg (barra compacta para Warp + log limpio)
# =====================================================================
QUIET_RC=0
quiet_ffmpeg() {
    LAST_ERR=$(ffmpeg -nostdin -hide_banner -loglevel error "$@" 2>&1)
    QUIET_RC=$?
}

run_ffmpeg() {
    local expected_dur=$1
    shift
    local errf="$WORK/ffmpeg_err.log"
    local progf="$WORK/ffmpeg_progress.txt"
    local rc=0 ff_pid stats_line cur_us cur_s pct eta speed fps_now bsize elapsed

    : > "$errf"
    : > "$progf"

    ffmpeg -nostdin -hide_banner -loglevel error -progress "$progf" "$@" </dev/null >/dev/null 2>"$errf" &
    ff_pid=$!
    ACTIVE_CHILD_PID=$ff_pid

    local t_begin=$SECONDS last_print=0 cols
    cols=$(tput cols 2>/dev/null || echo 80)
    (( cols < 50 )) && cols=80

    while kill -0 "$ff_pid" 2>/dev/null; do
        sleep 0.5
        if [[ -s $progf ]]; then
            stats_line=$(awk -F= '
                $1=="out_time_us" {us=$2}
                $1=="speed"       {sp=$2}
                $1=="fps"         {fp=$2}
                $1=="total_size"  {sz=$2}
                END { printf "%s|%s|%s|%s", us, sp, fp, sz }
            ' "$progf" 2>/dev/null || true)

            IFS='|' read -r cur_us speed fps_now bsize <<<"$stats_line"
            [[ $cur_us =~ ^-?[0-9]+$ ]] || cur_us=0
            (( cur_us < 0 )) && cur_us=0
            cur_s=$(awk -v u="$cur_us" 'BEGIN{printf "%.2f", u/1000000}')
            elapsed=$((SECONDS - t_begin))

            if [[ -t 1 ]]; then
                local bar="" pct_str="" extra="" line_out=""
                if awk -v d="$expected_dur" 'BEGIN{exit !(d>0)}'; then
                    pct=$(awk -v c="$cur_s" -v d="$expected_dur" 'BEGIN{p=int(c*100/d); if(p>100)p=100; if(p<0)p=0; print p}')
                    pct_str=$(printf '%3d%%' "$pct")
                    local filled=$((pct * 16 / 100))
                    local empty=$((16 - filled))
                    bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
                    eta=$(awk -v c="$cur_s" -v d="$expected_dur" -v e="$elapsed" 'BEGIN{
                        if(c>1 && e>1){
                            rem=int((d-c)*(e/c)); if(rem<0) rem=0;
                            printf "%dh%02dm%02ds", int(rem/3600), int((rem%3600)/60), rem%60
                        } else { printf "--" }
                    }')
                    extra="ETA $eta"
                else
                    bar="================"
                    pct_str="---%"
                    extra="$(fmt_dur "$elapsed")"
                fi
                [[ -n $fps_now && $fps_now != "0.0" && $fps_now != "0" ]] && extra+=" | ${fps_now}fps"
                [[ -n $speed && $speed != "N/A" ]] && extra+=" | ${speed}"
                [[ $bsize =~ ^[0-9]+$ && $bsize -gt 0 ]] && extra+=" | $(hsize "$bsize")"

                line_out="  [$bar] $pct_str $extra"
                printf '\r%-*.*s' $((cols - 2)) $((cols - 2)) "$line_out"
            else
                if (( elapsed - last_print >= 15 )); then
                    last_print=$elapsed
                    say "   Progreso: ${cur_s}s / ${expected_dur}s (${speed:-?})"
                fi
            fi
        fi
    done

    wait "$ff_pid"
    rc=$?
    ACTIVE_CHILD_PID=""

    if [[ -t 1 ]]; then
        if (( rc == 0 )); then
            local done_msg="  [################] 100% Completado en $(fmt_dur $((SECONDS - t_begin)))"
            printf '\r%-*.*s\n' $((cols - 2)) $((cols - 2)) "$done_msg"
        else
            echo
        fi
    fi

    if (( rc != 0 )); then
        LAST_ERR=$(tail -n 35 "$errf")
        return "$rc"
    fi
    return 0
}

# =====================================================================
#  Comprobación de herramientas y Doctor
# =====================================================================
find_demucs_script() {
    local candidate
    if [[ -n $DEMUCS_SCRIPT ]]; then
        DEMUCS_SCRIPT=$(readlink -f -- "$DEMUCS_SCRIPT" 2>/dev/null || true)
        return 0
    fi
    for candidate in \
        "$SCRIPT_DIR/demuc_ffmpeg.sh" \
        "$SCRIPT_DIR/../../audio/codigo/demuc_ffmpeg.sh" \
        "$OUTPUT_BASE_DIR/Documents/audio/codigo/demuc_ffmpeg.sh"; do
        if [[ -f $candidate && -r $candidate ]]; then
            DEMUCS_SCRIPT=$(readlink -f -- "$candidate")
            return 0
        fi
    done
    if command -v demuc_ffmpeg.sh >/dev/null 2>&1; then
        DEMUCS_SCRIPT=$(command -v demuc_ffmpeg.sh)
    fi
}

preflight_tools() {
    [[ $TOOLS_OK == true ]] && return 0
    local c f
    say "Comprobando herramientas del sistema..."
    for c in ffmpeg ffprobe demucs awk sed numfmt readlink stat df; do
        command -v "$c" >/dev/null 2>&1 || {
            err "No se encontró el comando '$c'. Instalalo o revisá tu PATH."
            return 1
        }
    done

    find_demucs_script
    if [[ -z $DEMUCS_SCRIPT || ! -f $DEMUCS_SCRIPT || ! -r $DEMUCS_SCRIPT ]]; then
        err "No encuentro demuc_ffmpeg.sh legible. Definí DEMUCS_SCRIPT=/ruta/demuc_ffmpeg.sh o ubicalo junto al script."
        return 1
    fi

    FILTERS_CACHE=$(ffmpeg -hide_banner -filters 2>/dev/null || true)
    ENCODERS_CACHE=$(ffmpeg -hide_banner -encoders 2>/dev/null || true)

    for f in rubberband amix atempo alimiter; do
        grep -Eq "^ [A-Z.]+ +$f " <<<"$FILTERS_CACHE" || {
            err "Tu ffmpeg no tiene el filtro '$f'."
            return 1
        }
    done
    if grep -Eq "^ [A-Z.]+ +zscale " <<<"$FILTERS_CACHE" && grep -Eq "^ [A-Z.]+ +tonemap " <<<"$FILTERS_CACHE"; then
        HAS_TONEMAP=true
    fi
    grep -q h264_nvenc <<<"$ENCODERS_CACHE" || {
        err "Tu ffmpeg no tiene el codificador h264_nvenc."
        return 1
    }

    detect_gpu_tools
    TOOLS_OK=true
    ok "Herramientas listas (Demucs aux: $DEMUCS_SCRIPT${GPU_NAME:+ | GPU: $GPU_NAME})"
    return 0
}

run_doctor() {
    echo
    echo "${C_BOLD}================ DIAGNÓSTICO DEL SISTEMA ================${C_RESET}"
    local c f ok_all=true
    for c in ffmpeg ffprobe demucs awk sed numfmt readlink stat df pgrep chattr notify-send nvidia-smi; do
        if command -v "$c" >/dev/null 2>&1; then
            printf '  %-15s : %sOK%s (%s)\n' "$c" "$C_GREEN" "$C_RESET" "$(command -v "$c")"
        else
            if [[ $c == notify-send || $c == nvidia-smi || $c == pgrep || $c == chattr ]]; then
                printf '  %-15s : %sOpcional (no instalado)%s\n' "$c" "$C_YELLOW" "$C_RESET"
            else
                printf '  %-15s : %sFALTA%s\n' "$c" "$C_RED" "$C_RESET"
                ok_all=false
            fi
        fi
    done

    find_demucs_script
    if [[ -n $DEMUCS_SCRIPT && -r $DEMUCS_SCRIPT ]]; then
        printf '  %-15s : %sOK%s (%s)\n' "demuc_ffmpeg.sh" "$C_GREEN" "$C_RESET" "$DEMUCS_SCRIPT"
    else
        printf '  %-15s : %sFALTA%s\n' "demuc_ffmpeg.sh" "$C_RED" "$C_RESET"
        ok_all=false
    fi

    if command -v ffmpeg >/dev/null 2>&1; then
        echo
        echo "  FFmpeg versión  : $(ffmpeg -version 2>/dev/null | head -n1)"
        FILTERS_CACHE=$(ffmpeg -hide_banner -filters 2>/dev/null || true)
        ENCODERS_CACHE=$(ffmpeg -hide_banner -encoders 2>/dev/null || true)
        for f in rubberband amix atempo alimiter loudnorm zscale tonemap; do
            if grep -Eq "^ [A-Z.]+ +$f " <<<"$FILTERS_CACHE"; then
                printf '  Filtro %-9s: %sDisponible%s\n' "$f" "$C_GREEN" "$C_RESET"
            else
                printf '  Filtro %-9s: %sNo disponible%s\n' "$f" "$C_YELLOW" "$C_RESET"
            fi
        done
        for f in h264_nvenc hevc_nvenc; do
            if grep -q "$f" <<<"$ENCODERS_CACHE"; then
                printf '  Encoder %-8s: %sDisponible%s\n' "$f" "$C_GREEN" "$C_RESET"
            else
                printf '  Encoder %-8s: %sNo disponible%s\n' "$f" "$C_YELLOW" "$C_RESET"
            fi
        done
    fi

    detect_gpu_tools
    if [[ $HAS_NVIDIA_SMI == true ]]; then
        echo
        echo "  GPU NVIDIA:"
        nvidia-smi --query-gpu=name,driver_version,memory.total,memory.free,temperature.gpu \
            --format=csv,noheader 2>/dev/null | sed 's/^/    /'
    fi

    echo
    echo "  Discos / FS:"
    df -hT "$HOME" 2>/dev/null | awk 'NR==2{printf "    %s (%s) Libre: %s / Total: %s\n", $7, $2, $5, $3}'
    echo "========================================================="
    [[ $ok_all == true ]] && ok "Todo lo esencial está operativo." || warn "Faltan componentes esenciales."
}

# =====================================================================
#  Validación y Análisis de Video / Rutas
# =====================================================================
validate_input_path() {
    local p=$1
    [[ -n $p ]] || { warn "No escribiste nada."; return 1; }
    [[ -f $p ]] || { warn "No existe ese archivo: $p"; return 1; }
    [[ -r $p ]] || { warn "No tengo permiso de lectura sobre ese archivo."; return 1; }
    if [[ -z $(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$p" 2>/dev/null | head -n1) ]]; then
        warn "El archivo no tiene pista de video (o ffprobe no puede leerlo)."; return 1
    fi
    if [[ -z $(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 "$p" 2>/dev/null | head -n1) ]]; then
        warn "El archivo no tiene pista de audio."; return 1
    fi
    if [[ $(get_duration "$p") == 0 ]]; then
        warn "No pude leer la duración del video."; return 1
    fi
    INPUT=$(readlink -f -- "$p")
    return 0
}

validate_output_dir() {
    local p=$1
    [[ -n $p ]] || { warn "No escribiste nada."; return 1; }
    [[ $p != "/" ]] && p=${p%/}
    if [[ -e $p && ! -d $p ]]; then
        warn "Esa ruta existe pero no es una carpeta."; return 1
    fi
    if [[ ! -d $p ]]; then
        if mkdir -p -- "$p" 2>/dev/null; then
            say "Carpeta creada: $p"
        else
            warn "No pude crear la carpeta: $p"; return 1
        fi
    fi
    if [[ ! -w $p || ! -x $p ]]; then
        warn "No tengo permiso de escritura en esa carpeta."; return 1
    fi
    OUT_DIR=$(readlink -f -- "$p")
    if [[ $OUT_DIR == "/" ]]; then
        warn "No uso la raíz del sistema como carpeta de salida."; return 1
    fi
    if [[ -n $INPUT && $INPUT == "$OUT_DIR/$TEMP_NAME"/* ]]; then
        warn "El video original está dentro de la carpeta temporal: elegí otra carpeta de salida."; return 1
    fi
    TEMP_DIR="$OUT_DIR/$TEMP_NAME"
    return 0
}

ask_input_file() {
    if [[ -n $CLI_INPUT ]]; then
        local cp
        cp=$(clean_path "$CLI_INPUT")
        validate_input_path "$cp" && return 0
        CLI_INPUT=""
    fi
    local raw p
    while true; do
        echo
        echo "Ruta del VIDEO ORIGINAL (Tab autocompleta; también podés arrastrar el archivo):"
        read -e -r -p "> " raw || return 1
        p=$(clean_path "$raw")
        validate_input_path "$p" && return 0
    done
}

ask_output_dir() {
    if [[ -n $CLI_OUT ]]; then
        local cp
        cp=$(clean_path "$CLI_OUT")
        validate_output_dir "$cp" && return 0
        CLI_OUT=""
    fi
    local raw p
    while true; do
        echo
        echo "Carpeta donde se guardará el video renderizado (y se hará el trabajo temporal):"
        read -e -r -p "> " raw || return 1
        p=$(clean_path "$raw")
        validate_output_dir "$p" && return 0
    done
}

generate_code() {
    local letters=abcdefghijklmnopqrstuvwxyz
    while true; do
        CODE="${letters:RANDOM%26:1}${letters:RANDOM%26:1}$(printf '%02d' $((RANDOM % 100)))"
        [[ -e "$OUT_DIR/${CODE}_procesado.mp4" ]] && continue
        [[ -e "$OUT_DIR/log_${CODE}.txt" ]] && continue
        compgen -G "$OUT_DIR/*_${CODE}_procesado.mp4" >/dev/null && continue
        compgen -G "$OUT_DIR/prueba_${CODE}*.mp4" >/dev/null && continue
        return 0
    done
}

build_final_out_path() {
    local mode=$1 base_name candidate n=2
    if [[ $mode == test ]]; then
        candidate="$OUT_DIR/prueba_${CODE}.mp4"
        while [[ -e $candidate ]]; do
            candidate="$OUT_DIR/prueba_${CODE}_${n}.mp4"
            n=$((n + 1))
        done
    else
        if [[ $NAMING_MODE == "name_code" ]]; then
            base_name=$(basename -- "$INPUT")
            base_name="${base_name%.*}"
            base_name=$(printf '%s' "$base_name" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+|_+$//g')
            [[ -z $base_name ]] && base_name="video"
            candidate="$OUT_DIR/${base_name}_${CODE}_procesado.mp4"
        else
            candidate="$OUT_DIR/${CODE}_procesado.mp4"
        fi
        while [[ -e $candidate ]]; do
            candidate="${candidate%.mp4}_${n}.mp4"
            n=$((n + 1))
        done
    fi
    printf '%s' "$candidate"
}

probe_source() {
    local info cs cp ct rng pixfmt rot_tag rot_sd a_info
    info=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height,pix_fmt,avg_frame_rate,r_frame_rate,color_range,color_space,color_primaries,color_transfer,start_time,duration:stream_tags=rotate \
        -of default=noprint_wrappers=1 "$INPUT" 2>/dev/null)
    pf() { awk -F= -v k="$1" '$1==k{print substr($0,length(k)+2); exit}' <<<"$info"; }

    SRC_W=$(pf width); SRC_H=$(pf height)
    pixfmt=$(pf pix_fmt); rng=$(pf color_range)
    cs=$(pf color_space); cp=$(pf color_primaries); ct=$(pf color_transfer)
    rot_tag=$(pf rotate)
    V_START=$(pf start_time); V_DUR=$(pf duration)

    a_info=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=start_time,duration \
        -of default=noprint_wrappers=1 "$INPUT" 2>/dev/null)
    A_START=$(awk -F= '$1=="start_time"{print $2; exit}' <<<"$a_info")
    A_DUR=$(awk -F= '$1=="duration"{print $2; exit}' <<<"$a_info")

    [[ $V_START =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || V_START=0
    [[ $A_START =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || A_START=0

    if [[ -z $rot_tag ]]; then
        rot_sd=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=rotation -of default=nw=1:nk=1 "$INPUT" 2>/dev/null | head -n1 || true)
        rot_tag=$rot_sd
    fi
    SRC_ROT=${rot_tag%.*}
    [[ $SRC_ROT =~ ^-?[0-9]+$ ]] || SRC_ROT=0
    if (( SRC_ROT == 90 || SRC_ROT == -90 || SRC_ROT == 270 || SRC_ROT == -270 )); then
        DISP_W=$SRC_H; DISP_H=$SRC_W
    else
        DISP_W=$SRC_W; DISP_H=$SRC_H
    fi

    FPS=$(snap_fps "$(pf avg_frame_rate)")
    [[ -z $FPS ]] && FPS=$(snap_fps "$(pf r_frame_rate)")
    [[ -z $FPS ]] && FPS=30

    if [[ $rng == "pc" || $pixfmt == yuvj* ]]; then FULL_RANGE=true; else FULL_RANGE=false; fi
    if [[ $ct == "smpte2084" || $ct == "arib-std-b67" ]]; then IS_HDR=true; else IS_HDR=false; fi

    valid_tag() { [[ -n $1 && $1 != unknown && $1 != "N/A" && $1 =~ ^[a-z0-9_.-]+$ ]]; }
    if [[ $IS_HDR == true ]]; then
        COLOR_ARGS=(-color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709)
    else
        COLOR_ARGS=(-color_range tv)
        valid_tag "$cs" && COLOR_ARGS+=(-colorspace "$cs")
        valid_tag "$cp" && COLOR_ARGS+=(-color_primaries "$cp")
        valid_tag "$ct" && COLOR_ARGS+=(-color_trc "$ct")
    fi

    SRC_DUR=$(get_duration "$INPUT")
    [[ $V_DUR =~ ^[0-9]+(\.[0-9]+)?$ ]] || V_DUR=$SRC_DUR
    [[ $A_DUR =~ ^[0-9]+(\.[0-9]+)?$ ]] || A_DUR=$SRC_DUR

    AV_START_DIFF=$(awk -v v="$V_START" -v a="$A_START" 'BEGIN{printf "%.3f", v-a}')
    AV_DUR_DIFF=$(awk -v v="$V_DUR" -v a="$A_DUR" 'BEGIN{d=v-a; if(d<0)d=-d; printf "%.3f", d}')

    SRC_SIG=$(stat -L -c '%s:%Y' "$INPUT" 2>/dev/null || echo "0:0")
    SRC_SIG+=":${SRC_DUR}"
}

test_decode_source() {
    say "Probando decodificación del video (primeros 5 s)..."
    quiet_ffmpeg -t 5 -i "$INPUT" -map 0:v:0 -map 0:a:0 -f null -
    if (( QUIET_RC != 0 )); then
        fatal "ffmpeg no pudo decodificar el video. Si faltan códecs (Fedora): sudo dnf swap ffmpeg-free ffmpeg --allowerasing" "$LAST_ERR"
        return 1
    fi
    return 0
}

check_disk() {
    local dur=$1 cached_ok=${2:-false}
    local audio_bytes src_bytes need avail mult=7
    [[ $cached_ok == true ]] && mult=2
    audio_bytes=$(awk -v d="$dur" 'BEGIN{printf "%d", d*176400}')
    src_bytes=$(stat -L -c %s "$INPUT")
    need=$(( audio_bytes * mult + src_bytes * 2 + 1073741824 ))
    avail=$(df -PB1 "$OUT_DIR" | awk 'NR==2{print $4}')
    say "Espacio temporal requerido: ~$(hsize "$need") | Libre en destino: $(hsize "$avail")."
    if (( avail < need )); then
        fatal "No hay espacio suficiente en la carpeta de salida." "Necesario ~$need bytes, disponible $avail bytes."
        return 1
    fi
    return 0
}

# =====================================================================
#  Construcción de filtros y códecs
# =====================================================================
compute_factors() {
    PITCH_VOC_F=$(awk -v p="$PITCH_VOC_INT" 'BEGIN{printf "%.3f", p/1000}')
    PITCH_F=$(awk -v p="$PITCH_INT" 'BEGIN{printf "%.3f", p/1000}')
    SPEED_F=$(awk -v s="$SPEED_INT" 'BEGIN{printf "%.4f", s/100}')
}

ENC_ARGS=()
build_enc_args() {
    local simple=${1:-false}
    local codec=$VIDEO_CODEC
    if ! grep -q "$codec" <<<"$ENCODERS_CACHE"; then
        warn "$codec no disponible; uso h264_nvenc."
        codec="h264_nvenc"
    fi
    if [[ $codec == "hevc_nvenc" ]]; then
        if [[ $simple == true ]]; then
            ENC_ARGS=(-c:v hevc_nvenc -rc vbr -cq "$CQ" -b:v 0 -profile:v main -tag:v hvc1 -pix_fmt yuv420p)
        else
            ENC_ARGS=(-c:v hevc_nvenc -preset "$NVENC_PRESET" -tune hq -rc vbr -cq "$CQ" -b:v 0
                      -spatial-aq 1 -temporal-aq 1 -profile:v main -tag:v hvc1 -pix_fmt yuv420p)
        fi
    else
        if [[ $simple == true ]]; then
            ENC_ARGS=(-c:v h264_nvenc -rc vbr -cq "$CQ" -b:v 0 -profile:v high -pix_fmt yuv420p)
        else
            ENC_ARGS=(-c:v h264_nvenc -preset "$NVENC_PRESET" -tune hq -rc vbr -cq "$CQ" -b:v 0
                      -spatial-aq 1 -temporal-aq 1 -bf 2 -profile:v high -pix_fmt yuv420p)
        fi
    fi
}

build_video_filter() {
    local vf=""
    local need_start_align=false
    if [[ $MODE_NAME == "completo" ]] && awk -v d="$AV_START_DIFF" 'BEGIN{exit !(d > 0.15)}'; then
        need_start_align=true
    fi

    if [[ $MODE_NAME == "prueba" ]]; then
        if (( SPEED_INT != 100 )); then
            vf+="setpts=(PTS-STARTPTS)/${SPEED_F},"
        else
            vf+="setpts=PTS-STARTPTS,"
        fi
        vf+="fps=${FPS},"
    elif [[ $need_start_align == true ]]; then
        # El video empieza después que el audio: alinea T=A_START a 0 y rellena fps desde start_time=0
        vf+="setpts=if(isnan(T)\\,NAN\\,(T-(${A_START}))/${SPEED_F}/TB),fps=${FPS}:start_time=0,"
    else
        (( SPEED_INT != 100 )) && vf+="setpts=PTS/${SPEED_F},"
        vf+="fps=${FPS},"
    fi

    if [[ $IS_HDR == true && $HAS_TONEMAP == true ]]; then
        vf+="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,"
    fi
    if [[ $FULL_RANGE == true && $IS_HDR != true ]]; then
        vf+="scale=trunc(iw/2)*2:trunc(ih/2)*2:in_range=pc:out_range=tv,"
    else
        vf+="scale=trunc(iw/2)*2:trunc(ih/2)*2,"
    fi
    vf+="format=yuv420p"
    VF="$vf"
}

build_atempo_chain() {
    awk -v s="$1" 'BEGIN{
        chain=""
        while (s > 2.0) { chain = chain (chain==""?"":",") "atempo=2.0"; s /= 2.0 }
        while (s < 0.5) { chain = chain (chain==""?"":",") "atempo=0.5"; s *= 2.0 }
        chain = chain (chain==""?"":",") sprintf("atempo=%.4f", s)
        print chain
    }'
}

build_audio_graph() {
    local idx=0 parts=() labels=() chain post=()
    AUDIO_ORDER=()

    if [[ $VOC_ON != true && $NOV_ON != true ]]; then
        AUDIO_FC=""
        return 0
    fi

    if [[ $VOC_ON == true ]]; then
        chain="[${idx}:a]volume=${VOC_GAIN}dB"
        (( PITCH_VOC_INT != 1000 )) && chain+=",rubberband=pitch=${PITCH_VOC_F}"
        chain+=",aresample=48000[v]"
        parts+=("$chain")
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

    # Si el audio original empieza después que el video (A_START > V_START + 0.15), compensar silencio inicial
    if [[ $MODE_NAME == "completo" ]] && awk -v d="$AV_START_DIFF" 'BEGIN{exit !(d < -0.15)}'; then
        local delay_ms
        delay_ms=$(awk -v d="$AV_START_DIFF" 'BEGIN{printf "%d", (-d)*1000}')
        post+=("adelay=${delay_ms}|${delay_ms}")
    fi

    (( SPEED_INT != 100 )) && post+=("$(build_atempo_chain "$SPEED_F")")
    if [[ $LOUDNORM_ON == true ]] && grep -Eq "^ [A-Z.]+ +loudnorm " <<<"$FILTERS_CACHE"; then
        post+=("loudnorm=I=-16:TP=-1.5:LRA=11")
    fi
    post+=("alimiter=limit=${ALIMITER_VAL}:level=0")
    parts+=("[m]$(IFS=,; echo "${post[*]}")[out]")

    AUDIO_FC=$(IFS=';'; echo "${parts[*]}")
}

preflight_render() {
    local test_inputs=() o
    DECODE_ARGS=()
    say "Probando filtros de audio, video, NVDEC y NVENC con tu archivo..."

    if (( ${#AUDIO_ORDER[@]} > 0 )); then
        for o in "${AUDIO_ORDER[@]}"; do
            test_inputs+=(-f lavfi -i "sine=frequency=440:duration=2:sample_rate=44100")
        done
        quiet_ffmpeg "${test_inputs[@]}" -filter_complex "$AUDIO_FC" -map "[out]" -f null -
        if (( QUIET_RC != 0 )); then
            fatal "Falló la prueba de filtros de audio." "$LAST_ERR"
            return 1
        fi
    fi

    # 1) Probar etiquetas de color + NVENC
    quiet_ffmpeg -ss "$CLIP_START" -t 3 -i "$INPUT" -map 0:v:0 -filter:v "$VF" \
        "${ENC_ARGS[@]}" "${COLOR_ARGS[@]}" -f null -
    if (( QUIET_RC != 0 )); then
        local first_err=$LAST_ERR
        quiet_ffmpeg -ss "$CLIP_START" -t 3 -i "$INPUT" -map 0:v:0 -filter:v "$VF" \
            "${ENC_ARGS[@]}" -color_range tv -f null -
        if (( QUIET_RC == 0 )); then
            COLOR_ARGS=(-color_range tv)
            add_problem "No se pudieron conservar etiquetas de color del original (se usó color_range=tv)." "$first_err"
            warn "Etiquetas de color ajustadas a color_range=tv."
        else
            build_enc_args true
            quiet_ffmpeg -ss "$CLIP_START" -t 3 -i "$INPUT" -map 0:v:0 -filter:v "$VF" \
                "${ENC_ARGS[@]}" -color_range tv -f null -
            if (( QUIET_RC != 0 )); then
                fatal "Falló la prueba de video/NVENC." "$LAST_ERR"
                return 1
            fi
            COLOR_ARGS=(-color_range tv)
            add_problem "Se activó modo compatible NVENC." "$first_err"
            warn "NVENC funcionando en modo compatible."
        fi
    fi

    # 2) Probar decodificación por GPU (NVDEC) si está en auto
    if [[ $NVDEC_MODE == "auto" ]]; then
        quiet_ffmpeg -hwaccel cuda -ss "$CLIP_START" -t 3 -i "$INPUT" -map 0:v:0 -filter:v "$VF" \
            "${ENC_ARGS[@]}" "${COLOR_ARGS[@]}" -f null -
        if (( QUIET_RC == 0 )); then
            DECODE_ARGS=(-hwaccel cuda)
            say "   Decodificación GPU (NVDEC) activada (-hwaccel cuda)."
        else
            DECODE_ARGS=()
            say "   Decodificación por CPU (NVDEC no compatible con este stream)."
        fi
    fi

    if [[ $IS_HDR == true ]]; then
        if [[ $HAS_TONEMAP == true ]]; then
            say "   Video HDR detectado: se aplicará tonemapping automático a SDR (bt709)."
        else
            add_problem "Video HDR convertido a 8-bit SDR sin filtro tonemap."
            warn "Video HDR sin zscale/tonemap."
        fi
    fi
    if awk -v d="$AV_START_DIFF" 'BEGIN{if(d<0)d=-d; exit !(d > 0.15)}'; then
        say "   Desfase inicial original detectado (V=${V_START}s, A=${A_START}s): compensación automática activada."
    fi
    if awk -v d="$AV_DUR_DIFF" 'BEGIN{exit !(d > 2.0)}'; then
        warn "El archivo original ya tiene distinta duración entre pistas (Video=${V_DUR}s vs Audio=${A_DUR}s)."
        add_problem "El video original tiene pistas de distinta duración (V=${V_DUR}s, A=${A_DUR}s)."
    fi
    ok "Preflight superado."
    return 0
}

# =====================================================================
#  Caché de Demucs y Reanudación (Checkpointing)
# =====================================================================
cache_key_for() {
    local mode=$1
    if [[ $mode == test ]]; then
        printf 'test_%s_%s' "$CLIP_START" "$CLIP_LEN"
    else
        printf 'full'
    fi
}

checkpoint_matches() {
    local meta="$TEMP_DIR/checkpoint.meta" saved_sig=""
    [[ -r $meta ]] || return 1
    saved_sig=$(awk -F= '$1=="SRC_SIG"{print substr($0,9); exit}' "$meta" 2>/dev/null || true)
    [[ -n $saved_sig && $saved_sig == "$SRC_SIG" ]]
}

checkpoint_save() {
    local meta="$TEMP_DIR/checkpoint.meta"
    {
        printf 'INPUT=%s\n' "$INPUT"
        printf 'SRC_SIG=%s\n' "$SRC_SIG"
        printf 'UPDATED=%s\n' "$(date '+%F %T')"
    } > "$meta"
}

cache_dir_for() {
    printf '%s/cache_demucs/%s' "$TEMP_DIR" "$(cache_key_for "$1")"
}

cache_has_stems() {
    local cdir
    cdir=$(cache_dir_for "$1")
    [[ -s "$cdir/audio_vocals.wav" && -s "$cdir/audio_no_vocals.wav" ]]
}

# =====================================================================
#  Pipeline Principal
# =====================================================================
prepare_temp() {
    local mode=$1 ext can_reuse=false
    if [[ $TEMP_READY != true ]]; then
        if [[ -e $TEMP_DIR ]]; then
            if checkpoint_matches; then
                if cache_has_stems "$mode"; then
                    if [[ -n $CLI_MODE ]] || ask_yn "Se detectaron stems de Demucs ya procesados para este video en $TEMP_DIR. ¿Reutilizarlos y saltar Demucs?" S; then
                        can_reuse=true
                    fi
                elif [[ -z $CLI_MODE ]]; then
                    warn "Existe una carpeta temporal previa del mismo video (sin stems completos)."
                    ask_yn "¿La borro y empiezo de cero?" S || return 1
                fi
            else
                warn "Ya existe una carpeta temporal de otro video o ejecución anterior: $TEMP_DIR"
                if [[ -z $CLI_MODE ]] && ask_yn "¿La borro y empiezo de cero?" N; then
                    :
                else
                    err "Cancelado para proteger los datos de $TEMP_DIR."
                    return 1
                fi
            fi

            if [[ $can_reuse != true ]]; then
                safe_rm "$TEMP_DIR" || { err "No pude borrarla de forma segura."; return 1; }
            fi
        fi

        if [[ ! -d $TEMP_DIR ]]; then
            mkdir -p -- "$TEMP_DIR" || { fatal "No pude crear la carpeta temporal."; return 1; }
            # En Btrfs (/home), desactivar CoW sobre la carpeta temporal vacía evita fragmentación en WAV/MP4 grandes
            if command -v chattr >/dev/null 2>&1; then
                chattr +C "$TEMP_DIR" 2>/dev/null || true
            fi
        fi

        mkdir -p -- "$TEMP_DIR/cache_demucs" || { fatal "No pude crear la carpeta de caché."; return 1; }
        acquire_lock || return 1
        ext=${INPUT##*.}
        [[ $ext =~ ^[A-Za-z0-9]{1,5}$ ]] || ext=mp4
        ORIG_LINK="$TEMP_DIR/original.$ext"
        ln -sfn -- "$INPUT" "$ORIG_LINK" || { fatal "No pude crear el enlace simbólico al original."; return 1; }
        checkpoint_save
        TEMP_READY=true
    fi

    WORK="$TEMP_DIR/trabajo"
    safe_rm "$WORK" || { fatal "Ruta de trabajo no segura."; return 1; }
    mkdir -p -- "$WORK" || { fatal "No pude crear la carpeta de trabajo."; return 1; }
    return 0
}

run_pipeline() {
    local mode=$1 vocals nov final_out rc cdir
    local has_audio=false use_cache=false
    [[ $VOC_ON == true || $NOV_ON == true ]] && has_audio=true

    reset_run_state
    compute_factors
    build_enc_args false

    if [[ $mode == test ]]; then
        PHASE="Prueba"; MODE_NAME="prueba"
        CLIP_IN_ARGS=(-ss "$CLIP_START" -t "$CLIP_LEN")
    else
        PHASE="Completo"; MODE_NAME="completo"
        CLIP_START=0; CLIP_LEN=$SRC_DUR; CLIP_IN_ARGS=()
    fi

    build_video_filter
    build_audio_graph
    PROC_START=$SECONDS

    echo
    echo "${C_BOLD}=== Procesando ($MODE_NAME): $(fmt_dur "$CLIP_LEN") de video ===${C_RESET}"
    prepare_temp "$mode" || return 1

    cdir=$(cache_dir_for "$mode")
    if [[ $has_audio == true ]] && cache_has_stems "$mode"; then
        use_cache=true
        RESUMED_FROM_CACHE=true
    fi

    check_disk "$CLIP_LEN" "$use_cache" || return 1
    preflight_render || return 1

    local out_expected_dur
    out_expected_dur=$(awk -v c="$CLIP_LEN" -v f="$SPEED_F" 'BEGIN{printf "%.3f", c/f}')

    # ---- Pasos 1 y 2: Audio + Demucs (con caché) ----
    if [[ $has_audio == true ]]; then
        if [[ $use_cache == true ]]; then
            say "[1-2/5] Reutilizando stems ya separados desde caché (0s)."
            vocals="$cdir/audio_vocals.wav"
            nov="$cdir/audio_no_vocals.wav"
            T_DEMUCS=0
        else
            mkdir -p -- "$cdir" || { fatal "No pude crear directorio de caché."; return 1; }
            say "[1/5] Extrayendo el audio a WAV (44,1 kHz, estéreo)..."
            run_ffmpeg "$CLIP_LEN" -y "${CLIP_IN_ARGS[@]}" -i "$ORIG_LINK" -map 0:a:0 -vn -sn -dn \
                -c:a pcm_s16le -ar 44100 -ac 2 -rf64 auto "$WORK/audio.wav" \
                || { fatal "ffmpeg falló al extraer el audio." "$LAST_ERR"; return 1; }

            say "[2/5] Separando voz y música con Demucs (puede tardar varios minutos)..."
            local t0=$SECONDS
            ( cd "$WORK" && bash "$DEMUCS_SCRIPT" audio.wav ) </dev/null 2>&1 | tee "$WORK/demucs_general.log"
            rc=${PIPESTATUS[0]}
            if (( rc != 0 )); then
                fatal "demuc_ffmpeg.sh terminó con error (código $rc)." "$(tail -n 40 "$WORK/demucs_general.log")"
                return 1
            fi

            T_DEMUCS=$((SECONDS - t0))
            local raw_v="$WORK/demucs_work_audio/resultado_final/audio_vocals.wav"
            local raw_n="$WORK/demucs_work_audio/resultado_final/audio_no_vocals.wav"
            if [[ ! -f $raw_v || ! -f $raw_n ]]; then
                fatal "Demucs no generó los archivos vocals / no_vocals esperados." "$(tail -n 40 "$WORK/demucs_general.log")"
                return 1
            fi

            if grep -Eq 'fallaron|Demucs falló|Falta vocals' "$WORK/demucs_general.log"; then
                add_problem "Demucs reportó segmentos con errores." "$(grep -E 'fallaron|Demucs falló|Falta vocals' "$WORK/demucs_general.log")"
            fi

            local d_a d_v d_n
            d_a=$(get_duration "$WORK/audio.wav")
            d_v=$(get_duration "$raw_v"); d_n=$(get_duration "$raw_n")
            if diff_gt "$d_a" "$d_v" "$TOL_DEMUCS_FATAL" || diff_gt "$d_a" "$d_n" "$TOL_DEMUCS_FATAL"; then
                fatal "Faltan segmentos de Demucs: difiere en más de ${TOL_DEMUCS_FATAL}s del original." \
                      "audio.wav=${d_a}s  vocals=${d_v}s  no_vocals=${d_n}s"
                return 1
            fi
            if diff_gt "$d_a" "$d_v" "$TOL_DEMUCS_WARN" || diff_gt "$d_a" "$d_n" "$TOL_DEMUCS_WARN"; then
                add_problem "La duración de stems difiere en >${TOL_DEMUCS_WARN}s del original." \
                            "audio.wav=${d_a}s  vocals=${d_v}s  no_vocals=${d_n}s"
            fi

            mv -f -- "$raw_v" "$cdir/audio_vocals.wav"
            mv -f -- "$raw_n" "$cdir/audio_no_vocals.wav"
            cp -f -- "$WORK/demucs_general.log" "$cdir/demucs_general.log" 2>/dev/null || true
            rm -rf -- "$WORK/demucs_work_audio" "$WORK/audio.wav"
            vocals="$cdir/audio_vocals.wav"
            nov="$cdir/audio_no_vocals.wav"

            local rest=$GPU_REST_DEMUCS_FULL
            [[ $mode == test ]] && rest=$GPU_REST_DEMUCS_TEST
            gpu_cool_rest "$rest" "Reposo de GPU tras Demucs"
        fi

        # ---- Paso 3: Audio final ----
        say "[3/5] Armando el audio final (volumen, pitch, mezcla, velocidad)..."
        local t0=$SECONDS inputs=() o
        for o in "${AUDIO_ORDER[@]}"; do
            [[ $o == voc ]] && inputs+=(-i "$vocals")
            [[ $o == nov ]] && inputs+=(-i "$nov")
        done
        run_ffmpeg "$out_expected_dur" -y "${inputs[@]}" -filter_complex "$AUDIO_FC" -map "[out]" \
            -c:a pcm_s16le -ar 48000 -ac 2 -rf64 auto "$WORK/audio_final.wav" \
            || { fatal "ffmpeg falló al armar el audio final." "$LAST_ERR"; return 1; }
        T_AUDIO=$((SECONDS - t0))

        [[ $use_cache == false ]] && gpu_cool_rest "$GPU_REST_SECONDS" "Pausa previa al render NVENC"
    else
        say "[1-3/5] Sin audio (vocal y no-vocal quitados): se omiten Demucs y mezcla."
    fi

    # ---- Paso 4: Render (con fallback automático de NVDEC a CPU) ----
    say "[4/5] Renderizando video con ${VIDEO_CODEC} (${NVENC_PRESET}, CQ ${CQ})..."
    local t_r=$SECONDS render_args=()
    build_render_cmd() {
        render_args=(-y "${DECODE_ARGS[@]}" "${CLIP_IN_ARGS[@]}" -i "$ORIG_LINK")
        if [[ $has_audio == true ]]; then
            render_args+=(-i "$WORK/audio_final.wav" -map 0:v:0 -map 1:a:0
                          -c:a aac -b:a "$AUDIO_BR" -ar 48000 -ac 2)
        else
            render_args+=(-map 0:v:0 -an)
        fi
        render_args+=(-filter:v "$VF" "${ENC_ARGS[@]}" "${COLOR_ARGS[@]}"
                      -movflags +faststart "$WORK/salida.mp4")
    }

    build_render_cmd
    if ! run_ffmpeg "$out_expected_dur" "${render_args[@]}"; then
        if (( ${#DECODE_ARGS[@]} > 0 )); then
            local nvdec_err=$LAST_ERR
            warn "NVDEC falló durante el render; reintentando con decodificación por CPU..."
            add_problem "NVDEC (-hwaccel cuda) falló en medio del render; se completó por CPU." "$nvdec_err"
            DECODE_ARGS=()
            rm -f -- "$WORK/salida.mp4"
            build_render_cmd
            run_ffmpeg "$out_expected_dur" "${render_args[@]}" \
                || { fatal "ffmpeg falló durante el render con ${VIDEO_CODEC}." "$LAST_ERR"; return 1; }
        else
            fatal "ffmpeg falló durante el render con ${VIDEO_CODEC}." "$LAST_ERR"
            return 1
        fi
    fi
    T_RENDER=$((SECONDS - t_r))

    # ---- Paso 5: Verificación y entrega ----
    say "[5/5] Verificando el resultado..."
    [[ -s "$WORK/salida.mp4" ]] || { fatal "El archivo renderizado no existe o está vacío."; return 1; }

    local tol vd ad
    tol=$(awk -v e="$out_expected_dur" 'BEGIN{printf "%.3f", 2 + e*0.001}')
    vd=$(get_stream_duration "$WORK/salida.mp4" v:0)
    if [[ $has_audio == true ]]; then
        ad=$(get_stream_duration "$WORK/salida.mp4" a:0)
        if diff_gt "$vd" "$ad" "$TOL_AV"; then
            add_problem "El video (${vd}s) y el audio (${ad}s) difieren en más de ${TOL_AV}s."
        fi
    fi
    if diff_gt "$vd" "$out_expected_dur" "$tol"; then
        add_problem "La duración del video (${vd}s) difiere de la esperada (${out_expected_dur}s)."
    fi

    final_out=$(build_final_out_path "$mode")
    mv -- "$WORK/salida.mp4" "$final_out" || { fatal "No pude mover el resultado a la carpeta de salida."; return 1; }
    [[ -f $final_out ]] || { fatal "El resultado no llegó a la carpeta de salida."; return 1; }

    FINAL_OUT=$final_out
    T_PROC=$((SECONDS - PROC_START))
    safe_rm "$WORK"
    return 0
}

# =====================================================================
#  Configuración, Presets e Historial (+ Estadísticas)
# =====================================================================
default_auto_config() {
    AUTO_VOC_ON=true; AUTO_VOC_GAIN=0; AUTO_PITCH_VOC_INT=1000
    AUTO_NOV_ON=true; AUTO_NOV_GAIN=0; AUTO_PITCH_INT=1000
    AUTO_SPEED_INT=100; AUTO_CQ=26
    AUTO_VIDEO_CODEC="h264_nvenc"; AUTO_NVENC_PRESET="p5"; AUTO_NVDEC_MODE="auto"
    AUTO_AUDIO_BR="160k"; AUTO_LOUDNORM_ON=false; AUTO_NAMING_MODE="code"
}

validate_loaded_params() {
    awk -v v="$VOC_GAIN" 'BEGIN{exit !(v>=-60 && v<=20)}' || VOC_GAIN=0
    awk -v v="$NOV_GAIN" 'BEGIN{exit !(v>=-60 && v<=20)}' || NOV_GAIN=0
    (( PITCH_VOC_INT >= 500 && PITCH_VOC_INT <= 2000 )) || PITCH_VOC_INT=1000
    (( PITCH_INT >= 500 && PITCH_INT <= 2000 )) || PITCH_INT=1000
    (( SPEED_INT >= 25 && SPEED_INT <= 400 )) || SPEED_INT=100
    (( CQ >= 15 && CQ <= 35 )) || CQ=26
    [[ $VIDEO_CODEC == "h264_nvenc" || $VIDEO_CODEC == "hevc_nvenc" ]] || VIDEO_CODEC="h264_nvenc"
    [[ $NVENC_PRESET =~ ^p[1-7]$ ]] || NVENC_PRESET="p5"
    [[ $NVDEC_MODE == "auto" || $NVDEC_MODE == "off" ]] || NVDEC_MODE="auto"
    [[ $AUDIO_BR =~ ^(128k|160k|192k|256k|320k)$ ]] || AUDIO_BR="160k"
    [[ $LOUDNORM_ON == true || $LOUDNORM_ON == false ]] || LOUDNORM_ON=false
    [[ $NAMING_MODE == "code" || $NAMING_MODE == "name_code" ]] || NAMING_MODE="code"
}

load_config_file() {
    local file=$1
    [[ -r $file ]] || return 1
    local key value
    while IFS='=' read -r key value; do
        [[ -z $key || $key == \#* ]] && continue
        case "$key" in
            VOC_ON) [[ $value == true || $value == false ]] && VOC_ON=$value ;;
            VOC_GAIN) [[ $value =~ ^[+-]?[0-9]+(\.[0-9]+)?$ ]] && VOC_GAIN=$value ;;
            PITCH_VOC_INT) [[ $value =~ ^[0-9]+$ ]] && PITCH_VOC_INT=$value ;;
            NOV_ON) [[ $value == true || $value == false ]] && NOV_ON=$value ;;
            NOV_GAIN) [[ $value =~ ^[+-]?[0-9]+(\.[0-9]+)?$ ]] && NOV_GAIN=$value ;;
            PITCH_INT) [[ $value =~ ^[0-9]+$ ]] && PITCH_INT=$value ;;
            SPEED_INT) [[ $value =~ ^[0-9]+$ ]] && SPEED_INT=$value ;;
            CQ) [[ $value =~ ^[0-9]+$ ]] && CQ=$value ;;
            VIDEO_CODEC) VIDEO_CODEC=$value ;;
            NVENC_PRESET) NVENC_PRESET=$value ;;
            NVDEC_MODE) NVDEC_MODE=$value ;;
            AUDIO_BR) AUDIO_BR=$value ;;
            LOUDNORM_ON) LOUDNORM_ON=$value ;;
            NAMING_MODE) NAMING_MODE=$value ;;
        esac
    done < "$file"
    validate_loaded_params
    return 0
}

save_config_file() {
    local file=$1 comment=${2:-"Configuración persistente de la edición automática."}
    local tmp="${file}.tmp.$$"
    mkdir -p -- "$(dirname -- "$file")" 2>/dev/null || return 1
    {
        echo "# $comment"
        printf 'VOC_ON=%s\n' "$VOC_ON"
        printf 'VOC_GAIN=%s\n' "$VOC_GAIN"
        printf 'PITCH_VOC_INT=%s\n' "$PITCH_VOC_INT"
        printf 'NOV_ON=%s\n' "$NOV_ON"
        printf 'NOV_GAIN=%s\n' "$NOV_GAIN"
        printf 'PITCH_INT=%s\n' "$PITCH_INT"
        printf 'SPEED_INT=%s\n' "$SPEED_INT"
        printf 'CQ=%s\n' "$CQ"
        printf 'VIDEO_CODEC=%s\n' "$VIDEO_CODEC"
        printf 'NVENC_PRESET=%s\n' "$NVENC_PRESET"
        printf 'NVDEC_MODE=%s\n' "$NVDEC_MODE"
        printf 'AUDIO_BR=%s\n' "$AUDIO_BR"
        printf 'LOUDNORM_ON=%s\n' "$LOUDNORM_ON"
        printf 'NAMING_MODE=%s\n' "$NAMING_MODE"
    } > "$tmp" 2>/dev/null || return 1
    mv -f -- "$tmp" "$file" 2>/dev/null
}

set_auto_defaults() {
    default_auto_config
    VOC_ON=$AUTO_VOC_ON; VOC_GAIN=$AUTO_VOC_GAIN; PITCH_VOC_INT=$AUTO_PITCH_VOC_INT
    NOV_ON=$AUTO_NOV_ON; NOV_GAIN=$AUTO_NOV_GAIN; PITCH_INT=$AUTO_PITCH_INT
    SPEED_INT=$AUTO_SPEED_INT; CQ=$AUTO_CQ
    VIDEO_CODEC=$AUTO_VIDEO_CODEC; NVENC_PRESET=$AUTO_NVENC_PRESET; NVDEC_MODE=$AUTO_NVDEC_MODE
    AUDIO_BR=$AUTO_AUDIO_BR; LOUDNORM_ON=$AUTO_LOUDNORM_ON; NAMING_MODE=$AUTO_NAMING_MODE
    load_config_file "$CONFIG_FILE" || true
}

save_auto_config() {
    save_config_file "$CONFIG_FILE" "Configuración persistente de la edición automática."
}

apply_cli_overrides() {
    [[ -n $CLI_SET_VOC_ON ]]    && VOC_ON=$CLI_SET_VOC_ON
    [[ -n $CLI_SET_VOC_GAIN ]]  && VOC_GAIN=$CLI_SET_VOC_GAIN
    [[ -n $CLI_SET_VOC_PITCH ]] && PITCH_VOC_INT=$CLI_SET_VOC_PITCH
    [[ -n $CLI_SET_NOV_ON ]]    && NOV_ON=$CLI_SET_NOV_ON
    [[ -n $CLI_SET_NOV_GAIN ]]  && NOV_GAIN=$CLI_SET_NOV_GAIN
    [[ -n $CLI_SET_NOV_PITCH ]] && PITCH_INT=$CLI_SET_NOV_PITCH
    [[ -n $CLI_SET_SPEED ]]     && SPEED_INT=$CLI_SET_SPEED
    [[ -n $CLI_SET_CQ ]]        && CQ=$CLI_SET_CQ
    [[ -n $CLI_SET_CODEC ]]     && VIDEO_CODEC=$CLI_SET_CODEC
    [[ -n $CLI_SET_PRESET ]]    && NVENC_PRESET=$CLI_SET_PRESET
    validate_loaded_params
}

# ---- Presets ----
presets_menu() {
    mkdir -p -- "$PRESETS_DIR" 2>/dev/null || true
    local opt name files i
    while true; do
        files=()
        shopt -s nullglob
        for i in "$PRESETS_DIR"/*.conf; do files+=("$i"); done
        shopt -u nullglob

        echo
        echo "${C_BOLD}=============== PERFILES (PRESETS) ===============${C_RESET}"
        if (( ${#files[@]} == 0 )); then
            echo "  (Todavía no hay perfiles guardados)"
        else
            for (( i=0; i<${#files[@]}; i++ )); do
                printf '  • %s\n' "$(basename -- "${files[i]}" .conf)"
            done
        fi
        echo
        echo " 1) Cargar un perfil como nueva edición automática"
        echo " 2) Guardar la edición automática actual como perfil"
        echo " 3) Eliminar un perfil"
        echo " 4) Volver"
        echo "=================================================="
        read -r -p "Opción [1-4]: " opt || return 0
        case "$opt" in
            1)
                (( ${#files[@]} == 0 )) && { warn "No hay perfiles guardados."; continue; }
                for (( i=0; i<${#files[@]}; i++ )); do
                    printf ' %2d) %s\n' $((i+1)) "$(basename -- "${files[i]}" .conf)"
                done
                ask_int "Número de perfil (0 = cancelar)" 0 0 "${#files[@]}"
                (( REPLY_VAL == 0 )) && continue
                set_auto_defaults
                load_config_file "${files[REPLY_VAL-1]}"
                if save_auto_config; then
                    ok "Perfil '$(basename -- "${files[REPLY_VAL-1]}" .conf)' fijado como edición automática."
                else
                    warn "No pude guardar la configuración automática."
                fi
                ;;
            2)
                set_auto_defaults
                read -r -p "Nombre del perfil (ej: emikukis_102): " name || continue
                name=$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+|_+$//g')
                [[ -z $name ]] && { warn "Nombre inválido."; continue; }
                if save_config_file "$PRESETS_DIR/${name}.conf" "Preset: $name"; then
                    ok "Perfil guardado en $PRESETS_DIR/${name}.conf"
                else
                    warn "No pude guardar el perfil."
                fi
                ;;
            3)
                (( ${#files[@]} == 0 )) && { warn "No hay perfiles para eliminar."; continue; }
                for (( i=0; i<${#files[@]}; i++ )); do
                    printf ' %2d) %s\n' $((i+1)) "$(basename -- "${files[i]}" .conf)"
                done
                ask_int "Número a eliminar (0 = cancelar)" 0 0 "${#files[@]}"
                (( REPLY_VAL == 0 )) && continue
                if ask_yn "¿Eliminar '$(basename -- "${files[REPLY_VAL-1]}" .conf)'?" N; then
                    rm -f -- "${files[REPLY_VAL-1]}" && ok "Perfil eliminado."
                fi
                ;;
            4) return 0 ;;
            *) warn "Elegí 1, 2, 3 o 4." ;;
        esac
    done
}

# ---- Historial ----
ensure_history_file() {
    [[ -e $HISTORY_FILE ]] && return 0
    {
        echo "# Historial de procesar_live.sh"
        echo "# Se agregan registros debajo de este encabezado."
        echo
    } >> "$HISTORY_FILE" 2>/dev/null || warn "No pude crear el historial en $HISTORY_FILE"
}

cq_label() {
    local q=$1
    if   (( q <= 21 )); then echo "calidad muy alta, archivo grande"
    elif (( q <= 24 )); then echo "calidad alta"
    elif (( q <= 27 )); then echo "equilibrado"
    elif (( q <= 29 )); then echo "más liviano"
    else echo "calidad baja, archivo chico"; fi
}

history_record() {
    local event=$1 status=$2 p
    ensure_history_file
    compute_factors
    {
        echo "================ HISTORIAL ================"
        echo "Fecha:          $(date '+%F %T')"
        echo "Evento:         $event"
        echo "Estado:         $status"
        [[ -n $RUN_KIND ]] && echo "Tipo:           $RUN_KIND"
        [[ -n $INPUT ]] && echo "Video original: $INPUT"
        [[ -n $OUT_DIR ]] && echo "Carpeta salida: $OUT_DIR"
        [[ -n $CODE ]] && echo "Código:         $CODE"
        if [[ $VOC_ON == true ]]; then
            echo "Vocal:          incluido | ganancia ${VOC_GAIN} dB | pitch ${PITCH_VOC_INT} (x${PITCH_VOC_F})"
        else
            echo "Vocal:          quitado"
        fi
        if [[ $NOV_ON == true ]]; then
            echo "No-vocal:       incluido | ganancia ${NOV_GAIN} dB | pitch ${PITCH_INT} (x${PITCH_F})"
        else
            echo "No-vocal:       quitado"
        fi
        echo "Velocidad:      ${SPEED_INT} (x${SPEED_F})"
        echo "Calidad:        CQ ${CQ} ($(cq_label "$CQ")) | ${VIDEO_CODEC} ${NVENC_PRESET} | AAC ${AUDIO_BR}"
        [[ -n $FINAL_OUT ]] && echo "Resultado:      $FINAL_OUT"
        if awk -v d="$SRC_DUR" 'BEGIN{exit !(d+0 > 0)}'; then
            echo "Duración origen: $(fmt_dur "$SRC_DUR")"
        fi
        (( T_PROC > 0 )) && echo "Tiempo proceso:  $(fmt_dur "$T_PROC")"
        (( T_DEMUCS >= 0 )) && echo "Tiempo Demucs:   $(fmt_dur "$T_DEMUCS")"
        (( T_AUDIO >= 0 )) && echo "Tiempo audio:    $(fmt_dur "$T_AUDIO")"
        (( T_RENDER >= 0 )) && echo "Tiempo render:   $(fmt_dur "$T_RENDER")"
        echo "Avisos:"
        if (( ${#PROBLEMS[@]} == 0 )); then
            echo "  ninguno"
        else
            for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
        fi
        echo "============================================"
        echo
    } >> "$HISTORY_FILE" 2>/dev/null || warn "No pude escribir en $HISTORY_FILE"
    HISTORY_RECORDED=true
}

begin_history_execution() {
    HISTORY_ACTIVE=true
    HISTORY_RECORDED=false
}

HIST_RECORDS=()
load_history_records() {
    ensure_history_file
    HIST_RECORDS=()
    local record="" line
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "================ HISTORIAL"* ]]; then
            [[ -n $record ]] && HIST_RECORDS+=("$record")
            record="$line"$'\n'
        elif [[ -n $record ]]; then
            record+="$line"$'\n'
        fi
    done < "$HISTORY_FILE"
    [[ -n $record ]] && HIST_RECORDS+=("$record")
}

show_history_file() {
    load_history_records
    echo
    echo "# Historial de procesar_live.sh (más antiguo primero)"
    if (( ${#HIST_RECORDS[@]} == 0 )); then
        echo "Todavía no hay registros."
        return 0
    fi
    local i
    for (( i=0; i<${#HIST_RECORDS[@]}; i++ )); do
        printf '%s\n' "${HIST_RECORDS[i]}"
    done
}

show_history_stats() {
    ensure_history_file
    echo
    echo "${C_BOLD}=========== ESTADÍSTICAS DEL HISTORIAL ===========${C_RESET}"
    awk '
    function parse_hms(s,   a,n) {
        gsub(/[^0-9hms ]/, "", s)
        if (match(s, /([0-9]+)h[[:space:]]*([0-9]+)m[[:space:]]*([0-9]+)s/, a)) {
            return a[1]*3600 + a[2]*60 + a[3]
        }
        return 0
    }
    function fmt(sec,   h,m,s) {
        sec = int(sec)
        h = int(sec / 3600); m = int((sec % 3600) / 60); s = sec % 60
        return sprintf("%dh %02dm %02ds", h, m, s)
    }
    /^================ HISTORIAL/ {
        ev=""; st=""; dur=0; proc=0; dem=0; aud=0; ren=0; in_av=0; av=0; next
    }
    /^Evento:/          { ev=$0; sub(/^Evento:[[:space:]]*/, "", ev); in_av=0; next }
    /^Estado:/          { st=$0; sub(/^Estado:[[:space:]]*/, "", st); in_av=0; next }
    /^Duración origen:/ { dur=parse_hms($0); in_av=0; next }
    /^Tiempo proceso:/  { proc=parse_hms($0); in_av=0; next }
    /^Tiempo Demucs:/   { dem=parse_hms($0); in_av=0; next }
    /^Tiempo audio:/    { aud=parse_hms($0); in_av=0; next }
    /^Tiempo render:/   { ren=parse_hms($0); in_av=0; next }
    /^Avisos:/          { in_av=1; next }
    in_av && /^[[:space:]]*- / { av++; next }
    /^============================================/ {
        total++
        if (ev ~ /Video completo procesado/ && st == "Completado") {
            done++
            sum_dur += dur; sum_proc += proc
            sum_dem += dem; sum_aud += aud; sum_ren += ren
            if (av == 0) clean++; else with_warn++
        } else if (ev ~ /Prueba/) {
            tests++
        } else if (st ~ /error|Cancelado/) {
            fails++
        } else {
            configs++
        }
        in_av=0
    }
    END {
        if (total == 0) { print "  Todavía no hay registros."; exit }
        printf "  Registros totales      : %d\n", total
        printf "  Videos completados     : %d (%d sin avisos, %d con avisos)\n", done, clean, with_warn
        printf "  Pruebas / Configs      : %d pruebas | %d cambios de config\n", tests, configs
        if (fails > 0) printf "  Fallidos / Cancelados  : %d\n", fails
        if (done > 0 && sum_proc > 0) {
            printf "  ──────────────────────────────────────────────\n"
            printf "  VODs procesados (total): %s (%.1f horas)\n", fmt(sum_dur), sum_dur/3600
            printf "  Tiempo de PC invertido : %s (%.1f horas)\n", fmt(sum_proc), sum_proc/3600
            printf "    • Demucs             : %s (%.0f%%)\n", fmt(sum_dem), sum_dem*100/sum_proc
            printf "    • Audio final        : %s (%.0f%%)\n", fmt(sum_aud), sum_aud*100/sum_proc
            printf "    • Render NVENC       : %s (%.0f%%)\n", fmt(sum_ren), sum_ren*100/sum_proc
            printf "  Velocidad media global : %.2fx (1h de live se procesa en %.1f min)\n", sum_dur/sum_proc, 60.0/(sum_dur/sum_proc)
        }
    }
    ' "$HISTORY_FILE"
    echo "=================================================="
}

history_line_value() {
    local record=$1 prefix=$2
    awk -v p="$prefix" 'index($0,p)==1 {v=substr($0,length(p)+1); sub(/^[[:space:]]+/,"",v); print v; exit}' <<<"$record"
}

show_history_summary() {
    local number=$1 record=$2 date event kind vocal nov speed quality
    date=$(history_line_value "$record" "Fecha:")
    event=$(history_line_value "$record" "Evento:")
    kind=$(history_line_value "$record" "Tipo:")
    vocal=$(history_line_value "$record" "Vocal:")
    nov=$(history_line_value "$record" "No-vocal:")
    speed=$(history_line_value "$record" "Velocidad:")
    quality=$(history_line_value "$record" "Calidad:")
    printf '\n[%d] %s\n' "$number" "${date:-sin fecha} | ${event:-sin evento}"
    [[ -n $kind ]] && printf '    Tipo: %s\n' "$kind"
    printf '    Vocal: %s\n' "${vocal:-sin datos}"
    printf '    No-vocal: %s\n' "${nov:-sin datos}"
    printf '    Video: velocidad %s | %s\n' "${speed:-sin datos}" "${quality:-sin datos}"
}

history_parse_record() {
    local record=$1 line value
    HIST_VOC_ON=false; HIST_VOC_GAIN=0; HIST_PITCH_VOC_INT=1000
    HIST_NOV_ON=false; HIST_NOV_GAIN=0; HIST_PITCH_INT=1000
    HIST_SPEED_INT=100; HIST_CQ=26
    HIST_CODEC="h264_nvenc"; HIST_PRESET="p5"; HIST_AUDIO_BR="160k"

    while IFS= read -r line; do
        case "$line" in
            Vocal:*)
                value=${line#Vocal:}; value="${value#"${value%%[![:space:]]*}"}"
                if [[ $value == incluido* ]]; then
                    HIST_VOC_ON=true
                    [[ $value =~ ganancia[[:space:]]+([+-]?[0-9]+(\.[0-9]+)?) ]] && HIST_VOC_GAIN=${BASH_REMATCH[1]}
                    [[ $value =~ pitch[[:space:]]+([0-9]+) ]] && HIST_PITCH_VOC_INT=${BASH_REMATCH[1]}
                fi
                ;;
            No-vocal:*)
                value=${line#No-vocal:}; value="${value#"${value%%[![:space:]]*}"}"
                if [[ $value == incluido* ]]; then
                    HIST_NOV_ON=true
                    [[ $value =~ ganancia[[:space:]]+([+-]?[0-9]+(\.[0-9]+)?) ]] && HIST_NOV_GAIN=${BASH_REMATCH[1]}
                    [[ $value =~ pitch[[:space:]]+([0-9]+) ]] && HIST_PITCH_INT=${BASH_REMATCH[1]}
                fi
                ;;
            Velocidad:*)
                value=${line#Velocidad:}; value="${value#"${value%%[![:space:]]*}"}"
                [[ $value =~ ^([0-9]+) ]] && HIST_SPEED_INT=${BASH_REMATCH[1]}
                ;;
            Calidad:*)
                value=${line#Calidad:}; value="${value#"${value%%[![:space:]]*}"}"
                [[ $value =~ CQ[[:space:]]+([0-9]+) ]] && HIST_CQ=${BASH_REMATCH[1]}
                [[ $value =~ (h264_nvenc|hevc_nvenc) ]] && HIST_CODEC=${BASH_REMATCH[1]}
                [[ $value =~ [[:space:]](p[1-7]) ]] && HIST_PRESET=${BASH_REMATCH[1]}
                [[ $value =~ AAC[[:space:]]+([0-9]+k) ]] && HIST_AUDIO_BR=${BASH_REMATCH[1]}
                ;;
        esac
    done <<<"$record"

    (( HIST_PITCH_VOC_INT >= 500 && HIST_PITCH_VOC_INT <= 2000 )) || return 1
    (( HIST_PITCH_INT >= 500 && HIST_PITCH_INT <= 2000 )) || return 1
    (( HIST_SPEED_INT >= 25 && HIST_SPEED_INT <= 400 )) || return 1
    (( HIST_CQ >= 15 && HIST_CQ <= 35 )) || return 1
    awk -v v="$HIST_VOC_GAIN" 'BEGIN{exit !(v>=-60 && v<=20)}' || return 1
    awk -v v="$HIST_NOV_GAIN" 'BEGIN{exit !(v>=-60 && v<=20)}' || return 1
}

apply_history_menu() {
    local opt selected display_index
    load_history_records
    if (( ${#HIST_RECORDS[@]} == 0 )); then
        echo "Todavía no hay registros para aplicar."
        return 0
    fi

    while true; do
        echo
        echo "======= APLICAR REGISTRO (más antiguo primero) ======="
        for (( display_index=0; display_index<${#HIST_RECORDS[@]}; display_index++ )); do
            show_history_summary "$((display_index + 1))" "${HIST_RECORDS[display_index]}"
        done
        echo
        echo " 0) Volver"
        read -r -p "Número del registro [0-${#HIST_RECORDS[@]}]: " opt || return 0
        [[ $opt == 0 ]] && return 0
        if [[ ! $opt =~ ^[0-9]+$ ]] || (( 10#$opt < 1 || 10#$opt > ${#HIST_RECORDS[@]} )); then
            warn "Elegí un número válido o 0 para volver."
            continue
        fi

        selected="${HIST_RECORDS[10#$opt-1]}"
        echo
        echo "Registro seleccionado:"
        show_history_summary "$opt" "$selected"
        ask_yn "¿Aplicar este registro como nueva edición automática?" S || continue

        if ! history_parse_record "$selected"; then
            warn "El registro no tiene valores compatibles."
            continue
        fi

        VOC_ON=$HIST_VOC_ON; VOC_GAIN=$HIST_VOC_GAIN; PITCH_VOC_INT=$HIST_PITCH_VOC_INT
        NOV_ON=$HIST_NOV_ON; NOV_GAIN=$HIST_NOV_GAIN; PITCH_INT=$HIST_PITCH_INT
        SPEED_INT=$HIST_SPEED_INT; CQ=$HIST_CQ
        VIDEO_CODEC=$HIST_CODEC; NVENC_PRESET=$HIST_PRESET; AUDIO_BR=$HIST_AUDIO_BR
        if save_auto_config; then
            RUN_KIND="Configuración automática"
            FINAL_OUT=""; T_PROC=0; T_DEMUCS=-1; T_AUDIO=-1; T_RENDER=-1
            SRC_DUR=0
            history_record "Registro histórico aplicado como edición automática" "Guardado"
            ok "Registro aplicado y guardado como nueva edición automática."
            return 0
        fi
        warn "No pude guardar la configuración automática."
    done
}

history_menu() {
    local opt
    ensure_history_file
    while true; do
        echo
        echo "============= HISTORIAL ============="
        echo " 1) Ver historial completo"
        echo " 2) Ver estadísticas de rendimiento"
        echo " 3) Aplicar registro a edición automática"
        echo " 4) Volver"
        echo "======================================"
        read -r -p "Opción [1-4]: " opt || return 0
        case "$opt" in
            1) show_history_file ;;
            2) show_history_stats ;;
            3) apply_history_menu ;;
            4) return 0 ;;
            *) warn "Elegí 1, 2, 3 o 4." ;;
        esac
    done
}

# =====================================================================
#  Menús de Edición y Resúmenes
# =====================================================================
show_summary() {
    compute_factors
    echo
    echo "${C_BOLD}================ RESUMEN DE CONFIGURACIÓN ================${C_RESET}"
    if [[ -n $INPUT ]]; then
        echo " Video original : $INPUT"
        local rot_note=""
        (( SRC_ROT != 0 )) && rot_note=" (rotación ${SRC_ROT}°)"
        echo "                  ${DISP_W}x${DISP_H}${rot_note}, $(fps_disp "$FPS") fps, $(fmt_dur "$SRC_DUR")$( [[ $IS_HDR == true ]] && echo " [HDR]" )"
        echo " Carpeta salida : $OUT_DIR"
        echo " Salida         : $(basename -- "$(build_final_out_path full)")"
    else
        echo " (Configuración global / sin video cargado aún)"
    fi
    hr
    if [[ $VOC_ON == true ]]; then
        echo " Vocal          : incluido | ${VOC_GAIN} dB | pitch ${PITCH_VOC_INT} (x${PITCH_VOC_F})"
    else
        echo " Vocal          : QUITADO"
    fi
    if [[ $NOV_ON == true ]]; then
        echo " No-vocal       : incluido | ${NOV_GAIN} dB | pitch ${PITCH_INT} (x${PITCH_F})"
    else
        echo " No-vocal       : QUITADO"
    fi
    local dur_est=""
    if [[ -n $INPUT ]]; then
        dur_est=" -> duración aprox: $(fmt_dur "$(awk -v d="$SRC_DUR" -v f="$SPEED_F" 'BEGIN{printf "%d", d/f}')")"
    fi
    echo " Velocidad      : ${SPEED_INT} (x${SPEED_F})${dur_est}"
    echo " Video / NVENC  : ${VIDEO_CODEC}, preset ${NVENC_PRESET}, VBR CQ ${CQ} ($(cq_label "$CQ")), NVDEC ${NVDEC_MODE}"
    echo " Audio / Nombre : AAC ${AUDIO_BR}$( [[ $LOUDNORM_ON == true ]] && echo ", loudnorm" ) | $( [[ $NAMING_MODE == name_code ]] && echo "Nombre_CODIGO_procesado.mp4" || echo "CODIGO_procesado.mp4" )"
    echo "=========================================================="
}

edit_no_vocal_menu() {
    local opt def
    while true; do
        compute_factors
        echo
        echo "--------- NO-VOCAL (música / instrumental) ---------"
        [[ $NOV_ON == true ]] && echo "Estado: incluido" || echo "Estado: quitado"
        echo "Ganancia: ${NOV_GAIN} dB | Pitch: ${PITCH_INT} (x${PITCH_F})"
        echo " 1) Incluir o quitar"
        echo " 2) Cambiar ganancia"
        echo " 3) Cambiar pitch"
        echo " 4) Volver"
        read -r -p "Opción [1-4]: " opt || return 0
        case "$opt" in
            1)
                [[ $NOV_ON == true ]] && def=S || def=N
                if ask_yn "¿Incluir el no-vocal?" "$def"; then NOV_ON=true; else NOV_ON=false; fi
                ;;
            2) ask_db "Ganancia del no-vocal (-15 = bajo, 0 = original, +3 = más alto)" "$NOV_GAIN" -60 20; NOV_GAIN=$REPLY_VAL ;;
            3) ask_int "Pitch del no-vocal (950 = más grave, 1000 = original, 1035 = +3,5%)" "$PITCH_INT" 500 2000; PITCH_INT=$REPLY_VAL ;;
            4) return 0 ;;
            *) warn "Elegí 1, 2, 3 o 4." ;;
        esac
    done
}

edit_vocal_menu() {
    local opt def
    while true; do
        compute_factors
        echo
        echo "---------------- VOCAL ----------------"
        [[ $VOC_ON == true ]] && echo "Estado: incluido" || echo "Estado: quitado"
        echo "Ganancia: ${VOC_GAIN} dB | Pitch: ${PITCH_VOC_INT} (x${PITCH_VOC_F})"
        echo " 1) Incluir o quitar"
        echo " 2) Cambiar ganancia"
        echo " 3) Cambiar pitch"
        echo " 4) Volver"
        read -r -p "Opción [1-4]: " opt || return 0
        case "$opt" in
            1)
                [[ $VOC_ON == true ]] && def=S || def=N
                if ask_yn "¿Incluir el vocal?" "$def"; then VOC_ON=true; else VOC_ON=false; fi
                ;;
            2) ask_db "Ganancia del vocal (-6 = bajo, 0 = original, +3 = más alto)" "$VOC_GAIN" -60 20; VOC_GAIN=$REPLY_VAL ;;
            3) ask_int "Pitch del vocal (950 = más grave, 1000 = original, 1020 = +2%)" "$PITCH_VOC_INT" 500 2000; PITCH_VOC_INT=$REPLY_VAL ;;
            4) return 0 ;;
            *) warn "Elegí 1, 2, 3 o 4." ;;
        esac
    done
}

edit_video_menu() {
    local opt
    while true; do
        compute_factors
        echo
        echo "---------------- VIDEO / NVENC ----------------"
        echo "Velocidad: ${SPEED_INT} (x${SPEED_F}) | CQ: ${CQ} | Códec: ${VIDEO_CODEC} | Preset: ${NVENC_PRESET}"
        echo " 1) Cambiar velocidad (25 a 400; 100 = 1.0x)"
        echo " 2) Cambiar CQ (15 a 35)"
        echo " 3) Cambiar códec NVENC (h264_nvenc / hevc_nvenc)"
        echo " 4) Cambiar preset NVENC (p4 rápido / p5 equilibrado / p6 calidad)"
        echo " 5) Volver"
        read -r -p "Opción [1-5]: " opt || return 0
        case "$opt" in
            1) ask_int "Velocidad (100 = original, 102 = +2%, 103 = +3%)" "$SPEED_INT" 25 400; SPEED_INT=$REPLY_VAL ;;
            2)
                echo "CQ: menor número = más calidad y más peso. (23 = alta, 26 = equilibrado, 30 = liviano)"
                ask_int "CQ (15 a 35)" "$CQ" 15 35; CQ=$REPLY_VAL
                ;;
            3)
                if [[ $VIDEO_CODEC == "h264_nvenc" ]]; then
                    if ask_yn "¿Cambiar a hevc_nvenc (H.265, archivos más chicos a igual calidad)?" S; then
                        VIDEO_CODEC="hevc_nvenc"
                    fi
                else
                    if ask_yn "¿Volver a h264_nvenc (H.264, máxima compatibilidad)?" S; then
                        VIDEO_CODEC="h264_nvenc"
                    fi
                fi
                ;;
            4)
                echo "Presets NVENC: 1) p4 (más rápido en 1080p60)  2) p5 (equilibrado, defecto)  3) p6 (más lento/calidad)"
                ask_int "Elegí" 2 1 3
                case "$REPLY_VAL" in
                    1) NVENC_PRESET="p4" ;; 2) NVENC_PRESET="p5" ;; 3) NVENC_PRESET="p6" ;;
                esac
                ;;
            5) return 0 ;;
            *) warn "Elegí 1, 2, 3, 4 o 5." ;;
        esac
    done
}

edit_advanced_menu() {
    local opt def
    while true; do
        echo
        echo "------------- OPCIONES AVANZADAS -------------"
        echo "Decodificación GPU (NVDEC) : $NVDEC_MODE"
        echo "Bitrate AAC                : $AUDIO_BR"
        echo "Normalización EBU          : $LOUDNORM_ON"
        echo "Nombre de salida           : $NAMING_MODE"
        echo " 1) Cambiar NVDEC (-hwaccel cuda: auto / off)"
        echo " 2) Cambiar bitrate de audio AAC (128k/160k/192k/256k/320k)"
        echo " 3) Activar/desactivar normalización loudnorm (-16 LUFS)"
        echo " 4) Cambiar estilo de nombre (código vs nombre_código)"
        echo " 5) Volver"
        read -r -p "Opción [1-5]: " opt || return 0
        case "$opt" in
            1)
                if [[ $NVDEC_MODE == "auto" ]]; then
                    if ask_yn "¿Desactivar NVDEC (forzar decodificación solo por CPU)?" N; then NVDEC_MODE="off"; fi
                else
                    if ask_yn "¿Activar NVDEC automático (acelera decodificación por GPU)?" S; then NVDEC_MODE="auto"; fi
                fi
                ;;
            2)
                echo "Opciones: 1) 128k  2) 160k  3) 192k  4) 256k  5) 320k"
                ask_int "Elegí" 2 1 5
                case "$REPLY_VAL" in
                    1) AUDIO_BR="128k" ;; 2) AUDIO_BR="160k" ;; 3) AUDIO_BR="192k" ;;
                    4) AUDIO_BR="256k" ;; 5) AUDIO_BR="320k" ;;
                esac
                ;;
            3)
                [[ $LOUDNORM_ON == true ]] && def=S || def=N
                if ask_yn "¿Activar normalización loudnorm (volumen parejo -16 LUFS)?" "$def"; then
                    LOUDNORM_ON=true
                else
                    LOUDNORM_ON=false
                fi
                ;;
            4)
                if [[ $NAMING_MODE == "code" ]]; then
                    if ask_yn "¿Usar 'NombreOriginal_CODIGO_procesado.mp4'?" S; then NAMING_MODE="name_code"; fi
                else
                    if ask_yn "¿Usar solo 'CODIGO_procesado.mp4'?" S; then NAMING_MODE="code"; fi
                fi
                ;;
            5) return 0 ;;
            *) warn "Elegí 1, 2, 3, 4 o 5." ;;
        esac
    done
}

configure_settings_menu() {
    local title=$1 opt
    local old_voc_on=$VOC_ON old_voc_gain=$VOC_GAIN old_pitch_voc=$PITCH_VOC_INT
    local old_nov_on=$NOV_ON old_nov_gain=$NOV_GAIN old_pitch=$PITCH_INT
    local old_speed=$SPEED_INT old_cq=$CQ old_codec=$VIDEO_CODEC old_preset=$NVENC_PRESET
    local old_nvdec=$NVDEC_MODE old_br=$AUDIO_BR old_ln=$LOUDNORM_ON old_nm=$NAMING_MODE

    while true; do
        echo
        echo "========== CONFIGURAR $title =========="
        echo " 1) Modificar no-vocal"
        echo " 2) Modificar vocal"
        echo " 3) Modificar video / NVENC"
        echo " 4) Opciones avanzadas (NVDEC, AAC, loudnorm, nombre)"
        echo " 5) Mostrar configuración actual"
        echo " 6) Aplicar cambios"
        echo " 7) Volver (descartar cambios)"
        echo "========================================"
        read -r -p "Opción [1-7]: " opt || return 1
        case "$opt" in
            1) edit_no_vocal_menu ;;
            2) edit_vocal_menu ;;
            3) edit_video_menu ;;
            4) edit_advanced_menu ;;
            5) show_summary ;;
            6)
                if [[ $VOC_ON != true && $NOV_ON != true ]]; then
                    warn "Quitaste vocal Y no-vocal: el video resultante NO tendrá audio."
                    ask_yn "¿Confirmar que querés generar el video sin sonido?" N || continue
                fi
                return 0
                ;;
            7)
                VOC_ON=$old_voc_on; VOC_GAIN=$old_voc_gain; PITCH_VOC_INT=$old_pitch_voc
                NOV_ON=$old_nov_on; NOV_GAIN=$old_nov_gain; PITCH_INT=$old_pitch
                SPEED_INT=$old_speed; CQ=$old_cq; VIDEO_CODEC=$old_codec; NVENC_PRESET=$old_preset
                NVDEC_MODE=$old_nvdec; AUDIO_BR=$old_br; LOUDNORM_ON=$old_ln; NAMING_MODE=$old_nm
                echo "Cambios descartados."
                return 1
                ;;
            *) warn "Elegí una opción del 1 al 7." ;;
        esac
    done
}

# =====================================================================
#  Reportes y Estimaciones
# =====================================================================
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

estimate_full_size() {
    local t_size t_dur full_dur est
    [[ -f $FINAL_OUT ]] || return 0
    t_size=$(stat -c %s "$FINAL_OUT"); t_dur=$(get_duration "$FINAL_OUT")
    full_dur=$(awk -v d="$SRC_DUR" -v f="$SPEED_F" 'BEGIN{printf "%.3f", d/f}')
    est=$(awk -v s="$t_size" -v t="$t_dur" -v f="$full_dur" 'BEGIN{printf "%d", (t>0)? s*f/t : 0}')
    (( est > 0 )) || return 0
    echo "   Peso estimado completo (CQ ${CQ}, ${VIDEO_CODEC}): ~$(hsize "$est")"
    echo "   (original pesa $(hsize "$(stat -L -c %s "$INPUT")"))"
}

final_report() {
    local p n=0 line="------------------------------------------------------"
    local o_size r_size o_dur r_dur o_w o_h r_w r_h r_fps o_br r_br pct info

    o_size=$(stat -L -c %s "$INPUT"); r_size=$(stat -c %s "$FINAL_OUT")
    o_dur=$SRC_DUR; r_dur=$(get_duration "$FINAL_OUT")
    o_w=$DISP_W; o_h=$DISP_H
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
        ok "Todo salió correcto y sin problemas."
    else
        warn "El video se generó, pero hubo avisos:"
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
    if [[ $VOC_ON == true ]]; then echo "   Vocal      : ${VOC_GAIN} dB, pitch ${PITCH_VOC_INT} (x${PITCH_VOC_F})"; else echo "   Vocal      : quitado"; fi
    if [[ $NOV_ON == true ]]; then echo "   No-vocal   : ${NOV_GAIN} dB, pitch ${PITCH_INT} (x${PITCH_F})"; else echo "   No-vocal   : quitado"; fi
    echo "   Velocidad  : ${SPEED_INT} (x${SPEED_F})"
    echo "   Render     : ${VIDEO_CODEC} ${NVENC_PRESET}, CQ ${CQ} ($(cq_label "$CQ")), AAC ${AUDIO_BR}"
    echo "$line"
    echo " Tiempos"
    echo "   Demucs                     : $(stage_time "$T_DEMUCS")$( [[ $RESUMED_FROM_CACHE == true ]] && echo " (desde caché)" )"
    echo "   Audio final                : $(stage_time "$T_AUDIO")"
    echo "   Render final (NVENC)       : $(stage_time "$T_RENDER")"
    echo "   Procesamiento completo     : $(fmt_dur "$T_PROC")"
    echo "   Tiempo total sesión        : $(fmt_dur $((SECONDS - T_START)))"
    echo "$line"
    echo " Archivos"
    echo "   Video final: $FINAL_OUT"
    [[ -n $LOG_FILE ]] && echo "   Log        : $LOG_FILE"
    echo "======================================================"
    notify_user "Video listo - procesar_live.sh" "$(basename -- "$FINAL_OUT") ($(hsize "$r_size"), $pct)"
}

finish_full() {
    release_lock
    safe_rm "$TEMP_DIR" || add_problem "No pude borrar la carpeta temporal: $TEMP_DIR (borrala a mano)."
    TEMP_READY=false
    write_log
    history_record "Video completo procesado" "Completado"
    HISTORY_ACTIVE=false
    final_report
}

dry_run_report() {
    compute_factors
    build_enc_args false
    MODE_NAME="completo"
    build_video_filter
    build_audio_graph
    show_summary
    echo
    echo "${C_BOLD}================ DRY-RUN (SIN EJECUTAR) ================${C_RESET}"
    echo "Filtro de video (-filter:v):"
    echo "  $VF"
    echo
    echo "Grafo de audio (-filter_complex):"
    echo "  ${AUDIO_FC:-"(sin audio)"}"
    echo
    echo "Argumentos de encoder NVENC:"
    echo "  ${ENC_ARGS[*]} ${COLOR_ARGS[*]}"
    echo "========================================================"
}

# =====================================================================
#  Flujos de ejecución (Auto, Manual, Batch, Limpieza)
# =====================================================================
prepare_single_video() {
    preflight_tools || return 1
    ask_input_file || return 1
    ask_output_dir || return 1
    generate_code
    probe_source
    test_decode_source || return 1
    return 0
}

flow_auto() {
    set_auto_defaults
    apply_cli_overrides

    if [[ -n $CLI_MODE ]]; then
        prepare_single_video || return 1
        show_summary
        RUN_KIND="Edición automática (CLI)"
        begin_history_execution
        run_pipeline full || return 1
        finish_full
        return 0
    fi

    local opt
    while true; do
        echo
        echo "========= EDICIÓN AUTOMÁTICA ========="
        echo " 1) Mostrar configuración automática"
        echo " 2) Elegir video y empezar"
        echo " 3) Volver"
        echo "======================================"
        read -r -p "Opción [1-3]: " opt || return 1
        case "$opt" in
            1) show_summary ;;
            2)
                prepare_single_video || return 1
                show_summary
                ask_yn "¿Confirmar e iniciar procesamiento completo?" S || continue
                RUN_KIND="Edición automática"
                begin_history_execution
                run_pipeline full || return 1
                finish_full
                return 0
                ;;
            3) return 1 ;;
            *) warn "Elegí 1, 2 o 3." ;;
        esac
    done
}

flow_modify_auto() {
    set_auto_defaults
    FINAL_OUT=""; T_PROC=0; T_DEMUCS=-1; T_AUDIO=-1; T_RENDER=-1; SRC_DUR=0
    RUN_KIND="Configuración automática"
    if configure_settings_menu "EDICIÓN AUTOMÁTICA"; then
        if save_auto_config; then
            history_record "Configuración de edición automática modificada" "Guardada"
            ok "Configuración automática guardada en: $CONFIG_FILE"
        else
            warn "No pude guardar la configuración en $CONFIG_FILE."
        fi
    fi
    return 1
}

flow_manual() {
    local opt
    prepare_single_video || return 1
    set_auto_defaults
    apply_cli_overrides
    RUN_KIND="Edición manual"
    configure_settings_menu "EDICIÓN MANUAL" || return 1

    while true; do
        show_summary
        echo
        echo "¿Qué querés hacer?"
        echo "  1) Prueba de $((TEST_SECONDS / 60)) minutos (con caché de Demucs)"
        echo "  2) Procesar el video completo"
        echo "  3) Cambiar los valores"
        echo "  4) Volver al menú principal"
        echo "  5) Salir"
        read -r -p "Opción [1-5]: " opt || return 0
        case "$opt" in
            1)
                ask_test_clip
                RUN_KIND="Edición manual (prueba)"
                begin_history_execution
                if run_pipeline test; then
                    release_lock
                    history_record "Prueba de video" "Completada"
                    HISTORY_ACTIVE=false
                    echo
                    ok "Prueba lista: $FINAL_OUT"
                    estimate_full_size
                    (( ${#PROBLEMS[@]} > 0 )) && warn "Hubo avisos en la prueba."
                    echo "   Si volvés a probar el mismo minuto con otros ajustes, no se repetirá Demucs."
                fi
                ;;
            2)
                RUN_KIND="Edición manual"
                begin_history_execution
                run_pipeline full || return 1
                finish_full
                return 0
                ;;
            3) configure_settings_menu "EDICIÓN MANUAL" || true ;;
            4)
                if [[ -d $TEMP_DIR ]]; then
                    release_lock
                    if ask_yn "¿Borrar carpeta temporal ($TEMP_DIR) antes de volver?" N; then
                        safe_rm "$TEMP_DIR"
                        TEMP_READY=false
                    fi
                fi
                return 1
                ;;
            5)
                if [[ -d $TEMP_DIR ]]; then
                    release_lock
                    safe_rm "$TEMP_DIR"
                fi
                write_log
                echo "Saliendo. Lo generado quedó en: $OUT_DIR"
                return 0
                ;;
            *) warn "Elegí una opción del 1 al 5." ;;
        esac
    done
}

flow_batch() {
    preflight_tools || return 1
    set_auto_defaults
    apply_cli_overrides

    local queue=() item p raw opt f
    if (( ${#CLI_BATCH_FILES[@]} > 0 )); then
        for item in "${CLI_BATCH_FILES[@]}"; do
            p=$(clean_path "$item")
            if [[ -d $p ]]; then
                while IFS= read -r -d '' f; do queue+=("$f"); done < <(find "$p" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.webm' -o -iname '*.ts' \) -print0 | sort -z)
            elif [[ -f $p ]]; then
                queue+=("$p")
            fi
        done
    else
        echo
        echo "${C_BOLD}=========== COLA DE PROCESAMIENTO (BATCH) ===========${C_RESET}"
        echo "Podés ingresar rutas de archivos o una carpeta con videos."
        echo "Presioná Enter en blanco cuando termines de agregar."
        while true; do
            read -e -r -p "Video o carpeta (Enter para terminar): " raw || break
            p=$(clean_path "$raw")
            [[ -z $p ]] && break
            if [[ -d $p ]]; then
                local added=0
                while IFS= read -r -d '' f; do
                    queue+=("$f"); added=$((added + 1))
                done < <(find "$p" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.webm' -o -iname '*.ts' \) -print0 | sort -z)
                say "Agregados $added videos de la carpeta."
            elif [[ -f $p ]]; then
                queue+=("$p")
                say "Agregado: $(basename -- "$p")"
            else
                warn "No existe: $p"
            fi
        done

        (( ${#queue[@]} == 0 )) && { warn "Cola vacía."; return 1; }

        echo
        echo "Videos en cola: ${#queue[@]}"
        echo " 1) Usar configuración automática actual"
        echo " 2) Personalizar ajustes para toda esta cola"
        read -r -p "Opción [1-2]: " opt || return 1
        [[ $opt == 2 ]] && { configure_settings_menu "COLA BATCH" || return 1; }
    fi

    (( ${#queue[@]} == 0 )) && { err "No hay videos válidos para procesar en batch."; return 1; }
    ask_output_dir || return 1

    local batch_out_base=$OUT_DIR
    local ok_cnt=0 fail_cnt=0 idx=0 total=${#queue[@]}
    local results=() batch_start=$SECONDS

    for item in "${queue[@]}"; do
        idx=$((idx + 1))
        echo
        echo "${C_CYAN}======================================================${C_RESET}"
        echo "${C_BOLD}  LOTE [$idx/$total]: $(basename -- "$item")${C_RESET}"
        echo "${C_CYAN}======================================================${C_RESET}"

        CLI_INPUT=""
        if ! validate_input_path "$item"; then
            fail_cnt=$((fail_cnt + 1))
            results+=("FAIL | $(basename -- "$item") | Archivo inválido")
            continue
        fi
        OUT_DIR="$batch_out_base"
        TEMP_DIR="$OUT_DIR/$TEMP_NAME"
        generate_code
        probe_source
        if ! test_decode_source; then
            fail_cnt=$((fail_cnt + 1))
            results+=("FAIL | $(basename -- "$item") | Error al decodificar")
            continue
        fi

        RUN_KIND="Lote (Batch $idx/$total)"
        begin_history_execution
        if run_pipeline full; then
            finish_full
            ok_cnt=$((ok_cnt + 1))
            results+=("OK   | $(basename -- "$item") -> $(basename -- "$FINAL_OUT")")
        else
            fail_cnt=$((fail_cnt + 1))
            results+=("FAIL | $(basename -- "$item") | Fallo en pipeline")
        fi

        if (( idx < total )); then
            gpu_cool_rest "$GPU_REST_SECONDS" "Pausa entre videos del lote"
        fi
    done

    echo
    echo "${C_BOLD}================ RESUMEN FINAL DEL LOTE ================${C_RESET}"
    echo " Completados : $ok_cnt / $total"
    echo " Fallidos    : $fail_cnt"
    echo " Tiempo total: $(fmt_dur $((SECONDS - batch_start)))"
    hr
    printf '  %s\n' "${results[@]}"
    echo "========================================================"
    notify_user "Lote finalizado" "Completados: $ok_cnt/$total (Fallidos: $fail_cnt)"
    return 0
}

cleanup_orphans_menu() {
    local raw p d sz found=()
    echo
    read -e -r -p "Carpeta donde buscar '$TEMP_NAME' huérfanos [$HOME/Videos]: " raw || return 0
    p=$(clean_path "${raw:-$HOME/Videos}")
    [[ -d $p ]] || { warn "No es una carpeta válida."; return 0; }

    while IFS= read -r -d '' d; do
        found+=("$d")
    done < <(find "$p" -maxdepth 4 -type d -name "$TEMP_NAME" -print0 2>/dev/null)

    if (( ${#found[@]} == 0 )); then
        ok "No se encontraron carpetas temporales '$TEMP_NAME' en $p."
        return 0
    fi

    echo "Carpetas temporales encontradas:"
    for d in "${found[@]}"; do
        sz=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        echo "  • $d ($sz)"
        if ask_yn "  ¿Eliminar esta carpeta?" N; then
            OUT_DIR=$(dirname -- "$d")
            TEMP_DIR="$d"
            safe_rm "$d" && ok "Eliminada." || warn "No pude eliminarla de forma segura."
            OUT_DIR=""; TEMP_DIR=""
        fi
    done
}

# =====================================================================
#  Menú Principal y CLI
# =====================================================================
usage() {
    cat <<'EOF'
Uso: procesar_live.sh [OPCIONES] [VIDEO]

Sin argumentos inicia el menú interactivo completo.

Opciones principales:
  -i, --input FILE         Video original de entrada
  -o, --output DIR         Carpeta de salida
  --auto                   Ejecuta edición automática sin menú interactivo
  --batch RUTA...          Procesa múltiples videos (archivos o carpetas)
  --preset NOMBRE          Carga un perfil guardado antes de ejecutar
  --dry-run                Muestra los filtros y parámetros sin renderizar
  --doctor                 Audita herramientas, filtros, NVENC y GPU NVIDIA
  --no-color               Desactiva colores ANSI
  -h, --help               Muestra esta ayuda

Sobreescritura rápida de parámetros:
  --cq N                   Calidad NVENC (15..35)
  --speed N                Velocidad en % (25..400, ej: 102 = 1.02x)
  --codec h264|hevc        Encoder NVENC
  --nvenc-preset p4|p5|p6  Preset NVENC (p4 rápido, p5 defecto, p6 calidad)
  --voc-gain DB            Ganancia vocal en dB (o --no-voc para quitar)
  --nov-gain DB            Ganancia no-vocal en dB (o --no-nov para quitar)
  --voc-pitch N            Pitch vocal (500..2000, ej: 1020 = +2%)
  --nov-pitch N            Pitch no-vocal (500..2000, ej: 1035 = +3.5%)
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --no-color) USE_COLOR=false; setup_colors ;;
            --doctor) CLI_MODE="doctor" ;;
            --auto) CLI_MODE="auto" ;;
            --dry-run) CLI_MODE="dry_run" ;;
            -i|--input) shift; CLI_INPUT=${1:-} ;;
            -o|--output) shift; CLI_OUT=${1:-} ;;
            --preset) shift; CLI_PRESET=${1:-} ;;
            --cq) shift; CLI_SET_CQ=${1:-} ;;
            --speed) shift; CLI_SET_SPEED=${1:-} ;;
            --nvenc-preset) shift; CLI_SET_PRESET=${1:-} ;;
            --codec)
                shift
                case "${1:-}" in
                    h264|h264_nvenc) CLI_SET_CODEC="h264_nvenc" ;;
                    hevc|h265|hevc_nvenc) CLI_SET_CODEC="hevc_nvenc" ;;
                    *) err "Códec inválido: ${1:-}"; exit 1 ;;
                esac
                ;;
            --voc-gain) shift; CLI_SET_VOC_GAIN=${1:-}; CLI_SET_VOC_ON="true" ;;
            --no-voc) CLI_SET_VOC_ON="false" ;;
            --nov-gain) shift; CLI_SET_NOV_GAIN=${1:-}; CLI_SET_NOV_ON="true" ;;
            --no-nov) CLI_SET_NOV_ON="false" ;;
            --voc-pitch) shift; CLI_SET_VOC_PITCH=${1:-} ;;
            --nov-pitch) shift; CLI_SET_NOV_PITCH=${1:-} ;;
            --batch)
                CLI_MODE="batch"
                shift
                while (( $# > 0 )) && [[ $1 != -* ]]; do
                    CLI_BATCH_FILES+=("$1")
                    shift
                done
                continue
                ;;
            -*)
                err "Opción desconocida: $1"
                usage
                exit 1
                ;;
            *)
                if [[ -z $CLI_INPUT ]]; then
                    CLI_INPUT="$1"
                else
                    CLI_BATCH_FILES+=("$1")
                    CLI_MODE="batch"
                fi
                ;;
        esac
        shift
    done
}

main_menu() {
    local opt rc
    while true; do
        echo
        echo "${C_BOLD}=============== MENÚ PRINCIPAL ===============${C_RESET}"
        echo " 1) Edición automática (procesar video)"
        echo " 2) Modificar edición automática"
        echo " 3) Edición manual (con pruebas y caché)"
        echo " 4) Procesamiento por lotes (Cola / Batch)"
        echo " 5) Perfiles guardados (Presets)"
        echo " 6) Historial y estadísticas"
        echo " 7) Diagnóstico del sistema (Doctor)"
        echo " 8) Limpiar carpetas temporales huérfanas"
        echo " 9) Salir"
        echo "=============================================="
        read -r -p "Opción [1-9]: " opt || exit 0
        case "$opt" in
            1) flow_auto; rc=$?; (( rc == 0 )) && return 0 ;;
            2) flow_modify_auto ;;
            3) flow_manual; rc=$?; (( rc == 0 )) && return 0 ;;
            4) flow_batch ;;
            5) presets_menu ;;
            6) history_menu ;;
            7) run_doctor ;;
            8) cleanup_orphans_menu ;;
            9) echo "Hasta luego."; return 0 ;;
            *) warn "Elegí una opción del 1 al 9." ;;
        esac
    done
}

reexec_with_inhibit() {
    if [[ -z "${PROCESAR_LIVE_INHIBIDO:-}" ]] && command -v systemd-inhibit >/dev/null 2>&1; then
        if systemd-inhibit --what=sleep:idle --who="procesar_live" --why="check" true >/dev/null 2>&1; then
            export PROCESAR_LIVE_INHIBIDO=1
            exec systemd-inhibit --what=sleep:idle --who="procesar_live.sh" \
                --why="Procesando video (Demucs + NVENC)" bash "$SELF" "$@"
        fi
    fi
}

main() {
    setup_colors
    parse_args "$@"
    reexec_with_inhibit "$@"
    trap on_interrupt INT TERM

    if [[ $CLI_MODE == "doctor" ]]; then
        run_doctor
        exit 0
    fi

    echo "======================================================"
    echo "${C_BOLD}  procesar_live.sh${C_RESET} - Demucs + pitch + velocidad + NVENC"
    echo "${C_DIM}  Tip: ejecutalo dentro de tmux o screen en videos largos.${C_RESET}"
    echo "======================================================"

    ensure_history_file
    command -v ffprobe >/dev/null 2>&1 || { err "Falta ffprobe."; exit 1; }

    if [[ -n $CLI_PRESET ]]; then
        local pfile="$PRESETS_DIR/${CLI_PRESET%.conf}.conf"
        if [[ -r $pfile ]]; then
            set_auto_defaults
            load_config_file "$pfile"
            ok "Perfil cargado: $CLI_PRESET"
        else
            err "No existe el perfil '$CLI_PRESET' en $PRESETS_DIR"
            exit 1
        fi
    fi

    case "$CLI_MODE" in
        auto)
            flow_auto
            exit $?
            ;;
        batch)
            flow_batch
            exit $?
            ;;
        dry_run)
            set_auto_defaults
            apply_cli_overrides
            prepare_single_video || exit 1
            dry_run_report
            exit 0
            ;;
        *)
            if [[ -n $CLI_INPUT ]]; then
                flow_manual
            else
                main_menu
            fi
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
