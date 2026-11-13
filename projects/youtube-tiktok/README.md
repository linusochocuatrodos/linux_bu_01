# procesar_live.sh

Script Bash para Linux (probado en Nobara/Fedora, KDE Plasma Wayland) que automatiza de principio a fin el procesado de **live VODs** (por ejemplo, directos guardados de TikTok): separa la voz de la música con **Demucs**, ajusta volumen y pitch de cada pista, mezcla, modifica la velocidad y renderiza por GPU con **NVENC** (`H.264` o `HEVC`).

Reemplaza el flujo manual que antes se hacía en Kdenlive, usando exclusivamente herramientas de línea de comandos (`ffmpeg`, `ffprobe` y `demucs`).

- **El video original nunca se modifica** ni se duplica (se trabaja mediante un enlace simbólico).
- **Nunca sobrescribe resultados previos** (usa códigos únicos y verificación antes de mover archivos).
- **Todo el trabajo temporal** ocurre dentro de `_temp_procesamiento/` en la carpeta de salida, con limpieza automática al terminar bien y conservación ante errores para poder reanudar.
- **Totalmente configurable**, con perfiles guardados, edición automática persistente, caché de pruebas, cola por lotes (*batch*), historial con estadísticas y soporte completo por CLI.

---

## Tabla de contenidos

1. [Requisitos y dependencias](#1-requisitos-y-dependencias)
2. [Instalación y ubicación de `demuc_ffmpeg.sh`](#2-instalación-y-ubicación-de-demuc_ffmpegsh)
3. [Inicio rápido](#3-inicio-rápido)
4. [Uso por línea de comandos (CLI)](#4-uso-por-línea-de-comandos-cli)
5. [Guía completa del menú interactivo](#5-guía-completa-del-menú-interactivo)
6. [Parámetros configurables y rangos](#6-parámetros-configurables-y-rangos)
7. [Caché de pruebas y reanudación ante fallos](#7-caché-de-pruebas-y-reanudación-ante-fallos)
8. [Arquitectura interna: qué hace paso a paso](#8-arquitectura-interna-qué-hace-paso-a-paso)
9. [Estructura de archivos y carpetas](#9-estructura-de-archivos-y-carpetas)
10. [Historial, estadísticas y perfiles (Presets)](#10-historial-estadísticas-y-perfiles-presets)
11. [Constantes ajustables](#11-constantes-ajustables)
12. [Rendimiento de referencia](#12-rendimiento-de-referencia)
13. [Solución de problemas y limitaciones](#13-solución-de-problemas-y-limitaciones)

---

## 1. Requisitos y dependencias

### Obligatorios

| Requisito | Detalle |
|---|---|
| `bash` | Bash 4.4+ / 5.x. |
| `ffmpeg` y `ffprobe` | Con filtros `rubberband`, `amix`, `atempo`, `alimiter` y encoder `h264_nvenc`. |
| `demucs` | Instalado y accesible en `$PATH` (lo invoca `demuc_ffmpeg.sh`). |
| `demuc_ffmpeg.sh` | Script auxiliar encargado de segmentar y ejecutar Demucs por tramos. |
| GPU NVIDIA | Compatible con NVENC (drivers propietarios NVIDIA funcionando). |
| Utilidades estándar | `awk`, `sed`, `numfmt`, `readlink`, `stat`, `df`, `find` (incluidas en Fedora/Nobara). |

### Opcionales (activan funciones extra si están presentes)

| Herramienta | Qué aporta |
|---|---|
| `nvidia-smi` | Monitoreo térmico automático entre Demucs y NVENC + info detallada en `--doctor`. |
| `hevc_nvenc` (en `ffmpeg`) | Permite renderizar en H.265/HEVC para archivos más livianos. |
| `loudnorm` (en `ffmpeg`) | Normalización de sonoridad EBU R128 (`-16 LUFS`). |
| `zscale` + `tonemap` (en `ffmpeg`) | Tonemapping automático de fuentes HDR a SDR (`bt709`). |
| `chattr` | Desactiva Copy-on-Write (`chattr +C`) sobre `_temp_procesamiento` en sistemas **Btrfs**, evitando fragmentación con archivos WAV de varios GiB. |
| `systemd-inhibit` | Evita que el entorno de escritorio suspenda la PC durante procesamientos largos. |
| `notify-send` | Notificaciones de escritorio al finalizar o fallar un video/lote. |
| `pgrep` | Limpieza ordenada de subprocesos al cancelar con `Ctrl+C`. |
| `tmux` o `screen` | Recomendado para sesiones largas sin riesgo de cierre accidental de terminal. |

---

## 2. Instalación y ubicación de `demuc_ffmpeg.sh`

1. Dar permiso de ejecución al script:

   ```bash
   chmod +x procesar_live.sh
   ```

2. Comprobar que el sistema cumple con todos los requisitos usando el diagnóstico integrado:

   ```bash
   ./procesar_live.sh --doctor
   ```

### Cómo detecta `demuc_ffmpeg.sh`

Si no definís manualmente la variable de entorno `DEMUCS_SCRIPT`, el script busca `demuc_ffmpeg.sh` en este orden:

1. `./demuc_ffmpeg.sh` (en la misma carpeta que `procesar_live.sh`).
2. `../../audio/codigo/demuc_ffmpeg.sh` (ruta hermana relativa dentro del repositorio).
3. `$HOME/Documents/audio/codigo/demuc_ffmpeg.sh`.
4. En cualquier directorio listado en `$PATH`.

También podés indicar una ruta puntual al ejecutar:

```bash
DEMUCS_SCRIPT="$HOME/ruta/personalizada/demuc_ffmpeg.sh" ./procesar_live.sh
```

> El script auxiliar se invoca con `bash`, así que no requiere permiso de ejecución propio. Se espera que genere `demucs_work_audio/resultado_final/audio_vocals.wav` y `audio_no_vocals.wav` dentro del directorio de trabajo temporal.

---

## 3. Inicio rápido

### Modo interactivo completo

```bash
./procesar_live.sh
```

*(Recomendado correrlo dentro de `tmux` o `screen` si vas a procesar videos de 2–3 horas).*

El menú principal arranca directamente sin pedir rutas por adelantado, por lo que podés revisar el historial, editar la configuración automática, gestionar perfiles o correr `--doctor` antes de elegir ningún archivo.

### Si arrastrás o pasás un video como único argumento

```bash
./procesar_live.sh "$HOME/Videos/mi_directo.mp4"
```

Entra directamente en el flujo de **Edición manual** con ese archivo ya validado.

### Procesamiento automático directo (un comando)

```bash
./procesar_live.sh --auto -i "$HOME/Videos/mi_directo.mp4" -o "$HOME/Videos/salida"
```

---

## 4. Uso por línea de comandos (CLI)

```text
Uso: procesar_live.sh [OPCIONES] [VIDEO]
```

### Opciones principales

| Opción | Descripción |
|---|---|
| `-i, --input FILE` | Video original de entrada. |
| `-o, --output DIR` | Carpeta de salida (se crea si no existe). |
| `--auto` | Ejecuta la edición automática directamente sin menú interactivo. |
| `--batch RUTA...` | Procesa múltiples videos en cola (acepta varios archivos y/o carpetas). |
| `--preset NOMBRE` | Carga un perfil guardado en `./presets_procesar_live/` antes de ejecutar. |
| `--dry-run` | Muestra el resumen, los filtros exactos y parámetros NVENC sin renderizar. |
| `--doctor` | Audita herramientas, filtros, encoders, GPU NVIDIA y disco, y sale. |
| `--no-color` | Desactiva colores ANSI en la salida. |
| `-h, --help` | Muestra la ayuda rápida. |

### Sobreescritura rápida de parámetros por CLI

Permiten modificar temporalmente la configuración cargada para esa ejecución sin alterar `procesar_live_auto.conf`:

| Flag | Descripción |
|---|---|
| `--cq N` | Calidad NVENC (`15` a `35`). |
| `--speed N` | Velocidad en porcentaje (`25` a `400`; ej. `102` = `1.02x`). |
| `--codec h264\|hevc` | Encoder NVENC (`h264_nvenc` o `hevc_nvenc`). |
| `--nvenc-preset p4\|p5\|p6` | Preset NVENC (`p4` rápido, `p5` equilibrado, `p6` mayor calidad). |
| `--voc-gain DB` | Ganancia de pista vocal en dB (activa vocal si estaba quitado). |
| `--no-voc` | Quita la pista vocal. |
| `--nov-gain DB` | Ganancia de pista no-vocal en dB (activa no-vocal si estaba quitado). |
| `--no-nov` | Quita la pista no-vocal. |
| `--voc-pitch N` | Pitch vocal (`500` a `2000`; ej. `1020` = `+2%`). |
| `--nov-pitch N` | Pitch no-vocal (`500` a `2000`; ej. `1035` = `+3,5%`). |

### Ejemplos útiles por CLI

```bash
# Auditar sistema y GPU
./procesar_live.sh --doctor

# Ver qué filtros exactos aplicaría sin renderizar nada
./procesar_live.sh --dry-run -i "$HOME/Videos/live.mp4" -o "$HOME/Videos/out"

# Procesar automáticamente usando un perfil guardado y sobreescribiendo CQ y códec
./procesar_live.sh --auto --preset nocturno --codec hevc --cq 25 -i "$HOME/Videos/live.mp4" -o "$HOME/Videos/out"

# Procesar todos los videos de una carpeta durante la noche
./procesar_live.sh --batch "$HOME/Videos/pendientes" -o "$HOME/Videos/procesados"
```

---

## 5. Guía completa del menú interactivo

Al ejecutar `./procesar_live.sh` sin argumentos verás el menú principal:

```text
=============== MENÚ PRINCIPAL ===============
 1) Edición automática (procesar video)
 2) Modificar edición automática
 3) Edición manual (con pruebas y caché)
 4) Procesamiento por lotes (Cola / Batch)
 5) Perfiles guardados (Presets)
 6) Historial y estadísticas
 7) Diagnóstico del sistema (Doctor)
 8) Limpiar carpetas temporales huérfanas
 9) Salir
==============================================
```

### Opción 1: Edición automática
Usa la configuración persistente de `procesar_live_auto.conf`.
- Permite **mostrar la configuración actual** antes de pedir archivos.
- Al elegir **Elegir video y empezar**, valida el archivo de entrada (podés usar `Tab`, `~`, comillas o arrastrar el archivo a la terminal), pide la carpeta de salida, muestra el resumen completo y pide confirmación antes de iniciar.

### Opción 2: Modificar edición automática
Abre el configurador completo sin exigir que cargues ningún video:

```text
========== CONFIGURAR EDICIÓN AUTOMÁTICA ==========
 1) Modificar no-vocal
 2) Modificar vocal
 3) Modificar video / NVENC
 4) Opciones avanzadas (NVDEC, AAC, loudnorm, nombre)
 5) Mostrar configuración actual
 6) Aplicar cambios
 7) Volver (descartar cambios)
===================================================
```

- Solo guarda en `procesar_live_auto.conf` y registra el cambio en el historial si elegís `6) Aplicar cambios`.
- `7) Volver` descarta cualquier modificación hecha en esa sesión.

### Opción 3: Edición manual (con pruebas y caché)
Ideal para ajustar parámetros finos sobre un video puntual:
1. Pide el video original y la carpeta de salida.
2. Abre el configurador con los valores actuales precargados.
3. Una vez aplicados los ajustes, ofrece:
   - **Prueba de 2 minutos:** pregunta desde qué minuto iniciar, procesa el fragmento completo (incluyendo Demucs) y guarda `prueba_XXNN.mp4` en la carpeta de salida. Al terminar, calcula el **peso estimado del video completo** con ese CQ y códec.
   - **Procesar el video completo:** genera el archivo final definitivo y limpia `_temp_procesamiento` al concluir.
   - **Cambiar los valores:** vuelve al configurador para ajustar ganancia, pitch, velocidad, CQ, etc. (y volver a probar sin repetir Demucs gracias al caché).
   - **Volver al menú principal** / **Salir**.

> Si quitás **ambas pistas** (vocal y no-vocal), el script advierte que el video quedará mudo y pide confirmación explícita. En ese modo omite extracción de audio, Demucs y mezcla.

### Opción 4: Procesamiento por lotes (Cola / Batch)
Permite encolar varios archivos individuales o carpetas enteras (busca `.mp4`, `.mkv`, `.mov`, `.webm`, `.ts`):
- Podés usar la configuración automática o personalizar ajustes para toda la cola.
- Elige una carpeta de salida común.
- Procesa uno por uno con pausa térmica entre videos.
- Si un archivo falla o no se puede decodificar, **no detiene la cola**: continúa con el resto y al final muestra una tabla resumen de completados y fallidos.

### Opción 5: Perfiles guardados (Presets)
Administra configuraciones reutilizables en `./presets_procesar_live/*.conf`:
- Cargar un perfil y fijarlo como nueva edición automática.
- Guardar la configuración automática actual bajo un nombre.
- Eliminar perfiles guardados.

### Opción 6: Historial y estadísticas
- **Ver historial completo:** lista todos los registros desde el más antiguo al más reciente.
- **Ver estadísticas de rendimiento:** analiza todo `historial_procesar_live.txt` y muestra cantidad de videos completados, pruebas, errores, total de horas de VOD procesadas, horas invertidas por la PC, porcentaje de tiempo por etapa (Demucs / Audio / Render) y velocidad media global.
- **Aplicar registro a edición automática:** permite elegir cualquier corrida pasada por número, inspeccionar sus parámetros y copiarlos a `procesar_live_auto.conf`.

### Opción 7: Diagnóstico del sistema (Doctor)
Audita binarios (`ffmpeg`, `ffprobe`, `demucs`, `chattr`, `nvidia-smi`, etc.), script `demuc_ffmpeg.sh`, filtros de audio/video disponibles, encoders NVENC, estado de la GPU (modelo, driver, VRAM libre, temperatura) y espacio libre en disco.

### Opción 8: Limpiar carpetas temporales huérfanas
Busca carpetas `_temp_procesamiento` abandonadas (por ejemplo en `$HOME/Videos`), muestra cuánto espacio ocupan y pregunta una por una si querés eliminarlas de forma segura.

---

## 6. Parámetros configurables y rangos

En cualquier pregunta interactiva, **presionar Enter acepta el valor actual** mostrado entre corchetes `[...]`.

### Pistas de audio (Vocal y No-vocal)

| Parámetro | Formato | Rango | Valor base |
|---|---|---|---|
| Incluir / quitar | `s` / `n` | — | Vocal: `true`, No-vocal: `true` |
| Ganancia | dB (acepta decimales, ej. `-15`, `-7.5`, `+3`) | `-60` a `+20` | `0` dB |
| Pitch (`rubberband`) | Entero (`1000` = `1.000x`, `1020` = `+2%`, `950` = `-5%`) | `500` a `2000` | `1000` |

### Video y NVENC

| Parámetro | Opciones / Rango | Notas |
|---|---|---|
| Velocidad | `25` a `400` (`100` = `1.0000x`, `102` = `+2%`) | Cambia velocidad manteniendo el tono del audio con `atempo`. |
| Calidad (`CQ`) | `15` a `35` (defecto: `26`) | Menor número = más calidad y archivo más pesado (`23` alta, `26` equilibrado, `30` liviano). |
| Códec NVENC | `h264_nvenc` / `hevc_nvenc` | `h264_nvenc` maximiza compatibilidad; `hevc_nvenc` reduce peso. |
| Preset NVENC | `p4` / `p5` / `p6` (defecto: `p5`) | `p4` acelera renders en 1080p60; `p5` es equilibrado; `p6` prioriza compresión/calidad. |

### Opciones avanzadas

| Parámetro | Opciones | Defecto | Qué hace |
|---|---|---|---|
| Decodificación GPU (NVDEC) | `auto` / `off` | `auto` | Prueba `-hwaccel cuda` en el preflight; si falla en runtime reintenta por CPU. |
| Bitrate AAC | `128k`, `160k`, `192k`, `256k`, `320k` | `160k` | Bitrate del audio final en el MP4. |
| Normalización EBU | `true` / `false` | `false` | Activa filtro `loudnorm=I=-16:TP=-1.5:LRA=11` antes del limitador. |
| Estilo de nombre | `code` / `name_code` | `code` | `XXNN_procesado.mp4` o `NombreOriginal_XXNN_procesado.mp4`. |

> **Nota sobre CQ:** Los streams descargados de TikTok suelen venir muy comprimidos (~1,5–2 Mbit/s). Bajar el CQ por debajo de 23 no recupera detalle perdido y puede duplicar o triplicar el peso del archivo final. Para uso habitual, `CQ 26` ofrece un buen equilibrio.

---

## 7. Caché de pruebas y reanudación ante fallos

El directorio `_temp_procesamiento/` guarda una estructura organizada:

```text
<carpeta de salida>/_temp_procesamiento/
├── .lock                     ← evita que dos instancias escriban en la misma carpeta
├── checkpoint.meta           ← firma del video original (tamaño, fecha, duración)
├── original.<ext>            ← enlace simbólico al video original
├── cache_demucs/
│   ├── full/                 ← stems completos (audio_vocals.wav / audio_no_vocals.wav)
│   └── test_<seg>_<dur>/     ← stems de pruebas por minuto inicial y duración
└── trabajo/                  ← audio_final.wav, salida.mp4 y logs de ffmpeg
```

- **En Modo Prueba:** si probás el minuto `10`, escuchás el resultado y querés ajustar volumen, pitch, velocidad o CQ volviendo a probar el mismo minuto `10`, el script **reutiliza los stems ya separados en `cache_demucs/`** y salta Demucs por completo (0 segundos).
- **Ante un fallo o `Ctrl+C` en un video largo:** si Demucs ya había terminado antes de cortarse el render NVENC, la carpeta temporal se conserva. Al volver a ejecutar sobre el mismo video y la misma carpeta de salida, el script verifica `checkpoint.meta` y te ofrece **reanudar saltando extracción y Demucs**.

---

## 8. Arquitectura interna: qué hace paso a paso

### Fase previa (Preflight)
1. **Validación de entrada y salida:** verifica lectura del original, existencia de pistas de video y audio, duración válida y permisos de escritura.
2. **Sondeo (`probe_source`):** lee con `ffprobe` dimensiones reales (ajustando por metadata de rotación `90°`/`270°`), FPS reales (`avg_frame_rate` con ajuste `snap_fps` si está a `<1%` de valores estándar como 24, 25, 29.97, 30, 50 o 60), rango de color (`pc` vs `tv`), etiquetas de color, HDR (`smpte2084` / `arib-std-b67`), y `start_time`/`duration` individuales de video y audio.
3. **Prueba de decodificación (5 s):** evalúa estrictamente el **código de salida** de `ffmpeg` (ignorando avisos inofensivos frecuentes en MP4 de TikTok como timestamps repetidos).
4. **Control de disco y Btrfs:** estima espacio temporal máximo necesario y, al crear `_temp_procesamiento`, aplica `chattr +C` si está disponible para evitar fragmentación CoW en Btrfs.
5. **Preflight de filtros, NVENC y NVDEC (3 s reales):**
   - Valida todo el grafo de audio con una señal sintética.
   - Prueba el render de 3 s del video real. Si fallan etiquetas de color del original, ajusta a `-color_range tv` y lo registra; si fallan opciones avanzadas NVENC (como AQ o `p5` en drivers antiguos), cambia a perfil NVENC compatible automáticamente.
   - Comprueba si `-hwaccel cuda` (NVDEC) funciona con el stream real.
   - Si detecta desfase inicial (`|v_start - a_start| > 0.15 s`), activa compensación automática para mantener sincronía A/V.

### Pipeline de 5 pasos
1. **Extracción de audio a WAV:** `-map 0:a:0 -vn -c:a pcm_s16le -ar 44100 -ac 2 -rf64 auto`.
2. **Separación con Demucs:** ejecuta `bash "$DEMUCS_SCRIPT" audio.wav`, verifica logs y compara duraciones de `vocals` y `no_vocals` contra `audio.wav` (diferencia `>1 s` genera aviso; `>30 s` aborta como fallo grave). Al finalizar mueve los stems a `cache_demucs/` y realiza reposo térmico de GPU (`nvidia-smi`).
3. **Mezcla y procesado de audio (48 kHz):**
   - Por pista activa: `volume=<dB>dB` → `rubberband=pitch=<factor>` (si pitch != `1000`) → `aresample=48000`.
   - Mezcla: `amix=inputs=2:normalize=0:duration=longest` (o `anull` si hay una sola pista activa).
   - Post-proceso: `adelay` (solo si el audio original empezaba después del video) → `atempo` encadenado automáticamente si velocidad != `100` → `loudnorm` (si está activo) → `alimiter=limit=0.95:level=0` (margen de seguridad contra clipping en AAC).
   - Pausa térmica previa al render NVENC.
4. **Render NVENC con progreso en vivo:**
   - Filtros de video: `setpts` (ajustado según velocidad y alineación) → `fps=<fps>` (CFR) → tonemapping HDR→SDR (si aplica y hay `zscale`/`tonemap`) → `scale` a dimensiones pares (convirtiendo `in_range=pc:out_range=tv` si era rango completo) → `format=yuv420p`.
   - Codificación: `h264_nvenc` o `hevc_nvenc` en VBR con `-cq`, `-b:v 0`, AQ espacial/temporal, audio AAC 48 kHz estéreo y `-movflags +faststart`.
   - Si NVDEC (`-hwaccel cuda`) falla a mitad del render por un frame atípico, reintenta automáticamente el paso 4 por CPU.
   - Muestra barra de progreso en vivo con porcentaje, FPS, velocidad (`x`), tamaño parcial y ETA.
5. **Verificación y entrega:**
   - Compara duración de pista de video vs pista de audio (tolerancia `1 s`) y contra duración esperada (`2 s + 0.1%`).
   - Mueve `salida.mp4` al destino final verificando que no exista colisión y limpia `trabajo/` (y `_temp_procesamiento/` al finalizar un render completo).

---

## 9. Estructura de archivos y carpetas

### En el repositorio / junto a `procesar_live.sh`

```text
./
├── procesar_live.sh              ← script principal
├── procesar_live_auto.conf       ← configuración persistente de edición automática
├── historial_procesar_live.txt   ← historial completo de corridas, pruebas y configs
├── presets_procesar_live/        ← perfiles guardados (.conf)
└── README.md
```

### En la carpeta de salida elegida

```text
<carpeta de salida>/
├── XXNN_procesado.mp4            ← resultado final (o Nombre_XXNN_procesado.mp4)
├── prueba_XXNN.mp4               ← solo si se ejecutaron pruebas de 2 min
├── log_XXNN.txt                  ← solo si hubo avisos o errores
└── _temp_procesamiento/          ← se elimina al terminar bien; se conserva si falla
```

---

## 10. Historial, estadísticas y perfiles (Presets)

- El archivo `./historial_procesar_live.txt` almacena cada ejecución, prueba, cambio de configuración o cancelación en bloques estructurados con fecha, evento, estado, parámetros usados, duraciones, tiempos por etapa y avisos.
- Desde el menú **Historial y estadísticas** podés:
  - Leer el historial completo en orden cronológico.
  - Consultar métricas agregadas de todas tus corridas completadas.
  - Aplicar cualquier registro antiguo como nueva configuración automática (se guarda automáticamente en `./procesar_live_auto.conf`).

### Comportamiento de logs y temporales según el resultado

| Situación | Carpeta `_temp_procesamiento` | Archivo `log_XXNN.txt` | Historial y notificación |
|---|---|---|---|
| **Todo OK** | Se borra automáticamente. | No se crea. | Registrado como `Completado` + notificación. |
| **Terminó con avisos** | Se borra automáticamente. | Se crea con resumen y detalle técnico. | Registrado con lista de avisos + notificación. |
| **Error grave** | **Se conserva** (incluye caché Demucs). | Se crea con el error y últimas líneas de log. | Registrado como error + notificación. |
| **`Ctrl+C`** | **Se conserva** y detiene subprocesos. | Se crea marcando cancelación. | Registrado como cancelado. |

---

## 11. Constantes ajustables

Se encuentran al inicio de `procesar_live.sh`:

| Constante | Valor por defecto | Qué controla |
|---|---|---|
| `TEST_SECONDS` | `120` | Duración en segundos del modo prueba. |
| `GPU_REST_SECONDS` | `15` | Pausa mínima antes del render NVENC. |
| `GPU_REST_DEMUCS_FULL` | `30` | Reposo mínimo tras Demucs en video completo. |
| `GPU_REST_DEMUCS_TEST` | `10` | Reposo mínimo tras Demucs en prueba. |
| `GPU_MAX_TEMP` | `78` | Temperatura máxima objetivo (°C) monitoreada con `nvidia-smi`. |
| `GPU_COOL_TIMEOUT` | `90` | Segundos máximos extra esperando enfriamiento de GPU. |
| `TOL_DEMUCS_WARN` | `1` | Diferencia tolerada (s) entre audio extraído y stems. |
| `TOL_DEMUCS_FATAL` | `30` | Diferencia (s) considerada fallo grave de Demucs. |
| `TOL_AV` | `1` | Diferencia tolerada (s) entre video y audio del archivo final. |
| `ALIMITER_VAL` | `0.95` | Techo lineal del limitador previo a AAC (~`-0.45 dBFS`). |

---

## 12. Rendimiento de referencia

Valores medidos en equipo de referencia (**AMD Ryzen 5 5600X, 16 GiB RAM, NVIDIA GTX 1660 SUPER 6 GB, NVMe Btrfs**):

| Duración origen | Resolución / Parámetros | Demucs | Audio final | Render NVENC | Total |
|---|---|---|---|---|---|
| `0h 37m` | 720p, no-vocal `-10 dB`, pitch `1020`, vel `103`, CQ `23` | `2m 39s` | `0m 57s` | `2m 01s` | `6m 25s` |
| `1h 42m` | 720p, solo vocal pitch `1035`, vel `103`, CQ `26` | `7m 19s` | `2m 33s` | `5m 29s` | `16m 10s` |
| `2h 51m` | 720p, solo vocal pitch `1020`, vel `102`, CQ `26` | `12m 43s` | `4m 15s` | `9m 17s` | `27m 13s` |
| `3h 23m` | 720p, solo vocal pitch `1035`, vel `103`, CQ `26` | `14m 26s` | `5m 00s` | `10m 52s` | `31m 12s` |

En fuentes `1080p` o `60 fps`, el tiempo de render puede aumentar; en esos casos se recomienda probar **NVDEC automático** (`auto`) junto con el preset **`p4`** si buscás mayor velocidad.

---

## 13. Solución de problemas y limitaciones

### Solución de problemas

| Síntoma | Causa probable y solución |
|---|---|
| `No encuentro demuc_ffmpeg.sh` | Colocalo junto a `procesar_live.sh`, en `../../audio/codigo/demuc_ffmpeg.sh`, en `$HOME/Documents/audio/codigo/demuc_ffmpeg.sh` o definí `DEMUCS_SCRIPT=/ruta/demuc_ffmpeg.sh`. |
| `Tu ffmpeg no tiene el filtro X` o falta `h264_nvenc` | En Fedora/Nobara instalá el paquete completo de RPM Fusion: `sudo dnf swap ffmpeg-free ffmpeg --allowerasing`. |
| `Ya existe una carpeta temporal` | Corresponde a una ejecución anterior. Si es del mismo video con stems completos, el script ofrecerá reanudar; si es de otro video, podés borrarla o usar la opción `8` del menú principal. |
| Desfase A/V en archivos viejos | Algunos VODs de TikTok traen cortes o `start_time` distinto entre pistas. El script ahora detecta y compensa automáticamente el desfase inicial; si el stream de video original está truncado en el medio, quedará registrado en `log_XXNN.txt`. |
| Falla NVDEC a mitad del video | El script captura el fallo y reintenta automáticamente el render decodificando por CPU. Podés forzar CPU siempre desde Opciones avanzadas (`NVDEC = off`). |
| Error grave en Demucs | Revisá `demucs_general.log` dentro de `_temp_procesamiento/trabajo/` o `cache_demucs/`. |

### Limitaciones conocidas

- Procesa únicamente la primera pista de video (`v:0`) y la primera pista de audio (`a:0`).
- La estimación de peso completo tras una prueba de 2 minutos es aproximada, ya que depende de la complejidad visual del tramo elegido.
- Un video fuente muy comprimido en HEVC recodificado a H.264 suele resultar más pesado que el original (para reducir tamaño, considerá `hevc_nvenc`).
- Las rutas de ejemplo en documentación e historial usan `$HOME` para mantener portabilidad entre equipos.
