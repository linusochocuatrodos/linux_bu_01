#!/usr/bin/env bash
#
# reescalar.sh
# ------------
# Reescala las imágenes que vos elijas (arrastrándolas o pegando su
# ruta, de a una) a un tamaño máximo definido.
#
# Flujo:
#   1) El script te pide la carpeta DESTINO (arrastrala o pegá su ruta).
#   2) Vas agregando imágenes de a una (arrastrás o pegás la ruta).
#   3) Después de cada imagen agregada, elegís:
#        - Enter vacío  -> seguís agregando más imágenes
#        - escribir "yes" -> reescala todas las que ya agregaste
#
# No recorre carpetas enteras: solo procesa las imágenes que vos
# le vayas dando una por una.
#
# Uso:
#   ./reescalar.sh                              -> modo interactivo completo
#   ./reescalar.sh carpeta_destino img1 img2 ... -> modo directo (sin menú)

set -uo pipefail

# ---------- Configuración ----------
# Lado más largo (ancho o alto, lo que sea mayor) al que se va a
# limitar cada imagen. No se agranda nada, solo se achica si es
# más grande que esto.
TARGET_LONG_EDGE=2200

# Calidad para JPG (1-100). Los PNG no usan esto, se guardan sin
# pérdida igual, solo más chicos por tener menos píxeles.
JPG_QUALITY=92

# ---------- Utilidades ----------
log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
}

fail() {
    printf '\n❌ ERROR: %s\n' "$1" >&2
}

# Limpia una ruta pegada/arrastrada: saca comillas y espacios de sobra
limpiar_ruta() {
    local r="$1"
    r="${r%\"}"; r="${r#\"}"
    r="${r%\'}"; r="${r#\'}"
    r="$(echo -e "${r}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    echo "$r"
}

# Detecta si existe 'magick' (ImageMagick 7) o 'convert' (ImageMagick 6)
if command -v magick >/dev/null 2>&1; then
    IM_CMD="magick"
elif command -v convert >/dev/null 2>&1; then
    IM_CMD="convert"
else
    fail "No encontré ImageMagick instalado ('magick' ni 'convert')."
    echo "Instalalo con: sudo dnf install ImageMagick"
    exit 1
fi

# ---------- Función: procesa una imagen hacia OUT_DIR ----------
procesar_imagen() {
    local input="$1"

    if [[ ! -f "$input" ]]; then
        fail "No encontré el archivo: '$input'"
        return 1
    fi

    local basename name_no_ext file_ext output
    basename="$(basename "$input")"
    name_no_ext="${basename%.*}"
    file_ext="${basename##*.}"
    output="${OUT_DIR}/${basename}"

    # Si ya existe un archivo con ese nombre en destino, agregamos un
    # número al final (_01, _02, ...) para no pisarlo.
    if [[ -f "$output" ]]; then
        local n=1
        local candidate
        while true; do
            candidate="${OUT_DIR}/${name_no_ext}_$(printf '%02d' "$n").${file_ext}"
            if [[ ! -f "$candidate" ]]; then
                output="$candidate"
                basename="$(basename "$output")"
                break
            fi
            n=$((n + 1))
        done
        log "   (ya existía un archivo con ese nombre, se guarda como: $basename)"
    fi

    local dims_orig size_orig
    dims_orig=$("$IM_CMD" identify -format "%wx%h" "$input" 2>/dev/null)
    size_orig=$(du -h "$input" | cut -f1)

    if [[ -z "$dims_orig" ]]; then
        fail "'$input' no parece ser una imagen válida."
        return 1
    fi

    log "Procesando: $basename  (original: ${dims_orig}, ${size_orig})"

    local ext_lower
    ext_lower=$(echo "$file_ext" | tr '[:upper:]' '[:lower:]')

    if [[ "$ext_lower" == "jpg" || "$ext_lower" == "jpeg" ]]; then
        "$IM_CMD" "$input" -resize "${TARGET_LONG_EDGE}x${TARGET_LONG_EDGE}>" \
            -quality "$JPG_QUALITY" "$output"
    else
        "$IM_CMD" "$input" -resize "${TARGET_LONG_EDGE}x${TARGET_LONG_EDGE}>" \
            "$output"
    fi

    if [[ $? -ne 0 || ! -f "$output" ]]; then
        fail "Falló el reescalado de '$basename'."
        return 1
    fi

    local dims_new size_new
    dims_new=$("$IM_CMD" identify -format "%wx%h" "$output" 2>/dev/null)
    size_new=$(du -h "$output" | cut -f1)

    log "   ✅ Listo -> ${dims_orig} (${size_orig}) ➜ ${dims_new} (${size_new})"
    log "   Guardado en: $output"
    echo ""
}

# ---------- Modo directo: carpeta destino + imágenes como argumentos ----------
if [[ $# -gt 0 ]]; then
    OUT_DIR="$(limpiar_ruta "$1")"
    shift

    if [[ ! -d "$OUT_DIR" ]]; then
        fail "La carpeta destino no existe: '$OUT_DIR'"
        exit 1
    fi
    if [[ $# -eq 0 ]]; then
        fail "No pasaste ninguna imagen para reescalar."
        exit 1
    fi

    log "=== Reescalando ${#} imagen(es) a máx. ${TARGET_LONG_EDGE}px en '$OUT_DIR/' ==="
    echo ""
    for img in "$@"; do
        procesar_imagen "$(limpiar_ruta "$img")"
    done
    log "=== Terminado ==="
    exit 0
fi

# ---------- Modo interactivo completo ----------
echo "======================================================"
echo "  reescalar.sh  -  Reescala imágenes (máx. ${TARGET_LONG_EDGE}px de lado largo)"
echo "======================================================"
echo ""

# Paso 1: pedir carpeta destino (obligatoria, se vuelve a preguntar si
# está vacía o no existe)
while true; do
    echo "Arrastrá la carpeta DESTINO (donde se van a guardar las imágenes"
    echo "reescaladas) a esta terminal, o pegá su ruta, y presioná Enter:"
    read -r -p "> " destino_raw
    OUT_DIR="$(limpiar_ruta "$destino_raw")"

    if [[ -z "$OUT_DIR" ]]; then
        echo "No puede quedar vacío. Probá de nuevo."
        echo ""
        continue
    fi

    if [[ -d "$OUT_DIR" ]]; then
        break
    fi

    echo "Esa carpeta no existe: '$OUT_DIR'"
    read -r -p "¿Querés crearla ahora? [s/N]: " crear
    if [[ "$crear" =~ ^[sS]$ ]]; then
        if mkdir -p "$OUT_DIR"; then
            log "Carpeta creada: $OUT_DIR"
            break
        else
            echo "No pude crear esa carpeta. Probá otra ruta."
        fi
    fi
    echo ""
done

log "Carpeta destino: $OUT_DIR"
echo ""

# Paso 2: ir agregando imágenes de a una, con menú después de cada una
COLA=()

while true; do
    echo "Arrastrá una imagen a esta terminal (o pegá su ruta) y presioná Enter:"
    read -r -p "> " img_raw
    img_path="$(limpiar_ruta "$img_raw")"

    if [[ -z "$img_path" ]]; then
        echo "No ingresaste ninguna ruta, probá de nuevo."
        echo ""
        continue
    fi

    if [[ ! -f "$img_path" ]]; then
        fail "No encontré ese archivo: '$img_path'"
        echo ""
        continue
    fi

    COLA+=("$img_path")
    log "Agregada (${#COLA[@]} en cola): $(basename "$img_path")"
    echo ""

    echo "Presioná Enter para seguir agregando imágenes,"
    echo "o escribí 'yes' para reescalar las ${#COLA[@]} imagen(es) ya agregadas:"
    read -r -p "> " seguir

    if [[ "$seguir" == "yes" ]]; then
        break
    fi
    echo ""
done

# Paso 3: procesar todo lo que quedó en la cola
echo ""
log "=== Reescalando ${#COLA[@]} imagen(es) a máx. ${TARGET_LONG_EDGE}px en '$OUT_DIR/' ==="
echo ""

for img in "${COLA[@]}"; do
    procesar_imagen "$img"
done

log "=== Listo. Revisá la carpeta '$OUT_DIR/' ==="
