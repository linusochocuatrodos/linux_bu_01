# Condiciones para futuros scripts/archivos (repo noba / linux)

Condiciones acordadas para crear o modificar scripts y archivos en este repo, para que sean portables entre usuarios y no expongan rutas personales.

## Regla general
- Reemplazar rutas absolutas del usuario (p. ej. `/home/<usuario>/...`) por variables de entorno.

## Por tipo de archivo
- **Scripts `.sh`**:
  - Agregar al inicio: `OUTPUT_BASE_DIR="${OUTPUT_BASE_DIR:-$HOME}"`.
  - Reemplazar la ruta absoluta por `"$OUTPUT_BASE_DIR"`.
- **`.md` y `.txt`** (README, docs, historial):
  - Usar `$HOME` o rutas relativas al repo. No usar `OUTPUT_BASE_DIR`.
- **`Modelfile*` y `config/shortcuts/first.kksrc`**:
  - NO editar (no expanden variables). Solo mostrar líneas afectadas y proponer alternativa.

## Casos específicos
- **`reescalar.sh`** (2 copias):
  - L34 → `OUTPUT_BASE_DIR="${OUTPUT_BASE_DIR:-$HOME}"`.
  - L58/L60 → agregar `/Pictures/kdenlive/imagenes/usados` a `OUT_DIR`.
- **`procesar_live.sh`**:
  - Agregar `OUTPUT_BASE_DIR="${OUTPUT_BASE_DIR:-$HOME}"` cerca del inicio (tras shebang y comentarios).
  - Cambiar candidato L411 a `"$OUTPUT_BASE_DIR/Documents/audio/codigo/demuc_ffmpeg.sh"`.

## READMEs
- Reemplazar la ruta absoluta por `$HOME`.
- Ajustar tabla L27 (en los 2 READMEs de reescalar) para explicar que `OUTPUT_BASE_DIR` es la base (`$HOME`) y la salida queda en `$OUTPUT_BASE_DIR/Pictures/kdenlive/imagenes/usados/`.

## Verificación
- `bash -n` en los scripts.
- `grep -rn '<ruta>' . --exclude-dir=.git` → solo `first.kksrc`.
- `git grep -ni '<patron>'`.

## Estado
- `first.kksrc`: no editar.
- No hacer commit ni push.
