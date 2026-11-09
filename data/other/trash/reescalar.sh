#!/usr/bin/env bash
#
# reescalar.sh
# ------------
# Reescala UNA imagen por vez (la que vos elijas, arrastrándola o
# pegando su ruta) a un tamaño máximo definido, y la guarda en una
# carpeta nueva nombrada según la resolución elegida.
#
# No toca ni recorre carpetas enteras: solo procesa la imagen que
# vos le des, cuando se la des.
#
# Uso:
#   ./reescalar.sh                  -> modo interactivo (arrastrás/pegás)
#   ./reescalar.sh imagen1.jpg ...  -> procesa directo las que pases

set -uo pipefail

# ---------- Configuración ----------
# Lado más largo (ancho o alto, lo que sea mayor) al que se va a
# limitar cada imagen. No se agranda nada, solo se achica si es
# más grande que esto.
TARGET_LONG_EDGE=2200

# Nombre de la carpeta de salida. Si lo dejás vacío (""), el script
# arma el nombre solo a partir de TARGET_LONG_EDGE (ej: "2200px").
FOLDER_NAME=""

# Calidad para JPG (1-100). Los PNG no usan esto, se guardan sin
# pérdida igual, solo más chicos por tener menos píxeles.
JPG_QUALITY=92

# Carpeta fija donde SIEMPRE se va a guardar el resultado, sin importar
# desde dónde corras el script ni dónde esté guardado.
OUTPUT_BASE_DIR="${OUTPUT_BASE_DIR:-$HOME}"

# ---------- Utilidades ----------
log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
}

fail() {
    printf '\n❌ ERROR: %s\n' "$1" >&2
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

# Nombre de carpeta final (siempre dentro de OUTPUT_BASE_DIR)
if [[ -z "$FOLDER_NAME" ]]; then
    OUT_DIR="${OUTPUT_BASE_DIR}/Pictures/kdenlive/imagenes/usados/${TARGET_LONG_EDGE}px"
else
    OUT_DIR="${OUTPUT_BASE_DIR}/Pictures/kdenlive/imagenes/usados/${FOLDER_NAME}"
fi

mkdir -p "$OUT_DIR" || { fail "No pude crear la carpeta '$OUT_DIR'."; exit 1; }

# ---------- Función principal: procesa una imagen ----------
procesar_imagen() {
    local input="$1"

    # Limpieza por si se pegó con comillas o backslashes de escape
    input="${input%\"}"
    input="${input#\"}"
    input="${input%\'}"
    input="${input#\'}"

    if [[ ! -f "$input" ]]; then
        fail "No encontré el archivo: '$input'"
        return 1
    fi

    local basename
    basename="$(basename "$input")"
    local name_no_ext="${basename%.*}"
    local file_ext="${basename##*.}"
    local output="${OUT_DIR}/${basename}"

    # Si ya existe un archivo con ese nombre en la carpeta de salida,
    # le agregamos un número al final (_01, _02, ...) para no pisarlo.
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

    # Dimensiones y peso originales
    local dims_orig size_orig
    dims_orig=$("$IM_CMD" identify -format "%wx%h" "$input" 2>/dev/null)
    size_orig=$(du -h "$input" | cut -f1)

    if [[ -z "$dims_orig" ]]; then
        fail "'$input' no parece ser una imagen válida."
        return 1
    fi

    log "Procesando: $basename  (original: ${dims_orig}, ${size_orig})"

    # Extensión para decidir si aplica calidad JPG
    local ext="${basename##*.}"
    local ext_lower
    ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

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

# ---------- Modo 1: se pasaron imágenes como argumentos ----------
if [[ $# -gt 0 ]]; then
    log "=== Reescalando ${#} imagen(es) a máx. ${TARGET_LONG_EDGE}px, carpeta '$OUT_DIR/' ==="
    echo ""
    for img in "$@"; do
        procesar_imagen "$img"
    done
    log "=== Terminado ==="
    exit 0
fi

# ---------- Modo 2: interactivo (arrastrar o pegar de a una) ----------
echo "======================================================"
echo "  reescalar.sh  -  Reescala imágenes de a una"
echo "  Carpeta de salida: $OUT_DIR/  (máx. ${TARGET_LONG_EDGE}px de lado largo)"
echo "======================================================"
echo ""

while true; do
    echo "Arrastrá una imagen a esta terminal (o pegá su ruta) y presioná Enter."
    echo "Dejá vacío y presioná Enter para salir."
    read -r -p "> " ruta

    if [[ -z "$ruta" ]]; then
        log "Salida solicitada por el usuario."
        break
    fi

    procesar_imagen "$ruta"
done

log "=== Listo. Revisá la carpeta '$OUT_DIR/' ==="
