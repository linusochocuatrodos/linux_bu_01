# procesar_live.sh

Script Bash para Linux (probado en Nobara/Fedora, KDE) que automatiza el procesado de **live VODs de TikTok**: separa la voz de la música con Demucs, ajusta volumen y pitch de la música, mezcla, acelera el video un poco y lo renderiza con **NVENC H.264**. Reemplaza el flujo manual que antes se hacía en Kdenlive. **Kdenlive no participa**: todo se hace con `ffmpeg`, `ffprobe` y `demucs`.

- El video original **nunca se modifica**.
- Todo el trabajo intermedio ocurre en una subcarpeta temporal que se borra al terminar bien.
- Todos los mensajes están en español.
- La edición automática se puede personalizar y sus valores quedan guardados junto al script.
- Se mantiene un historial detallado de configuraciones, pruebas y procesamientos.

---

## 1. Requisitos

| Requisito | Detalle |
|---|---|
| `ffmpeg` y `ffprobe` | Con los filtros `rubberband`, `amix`, `atempo`, `alimiter` y el codificador `h264_nvenc`. Probado con ffmpeg 8.1.2. |
| `demucs` | En el `PATH`. Lo usa `demuc_ffmpeg.sh`. |
| `demuc_ffmpeg.sh` | Script propio del usuario. Se detecta automáticamente en la carpeta hermana `audio/codigo/` de tu instalación, en la misma carpeta del script, o se puede indicar con `DEMUCS_SCRIPT`. |
| GPU NVIDIA | Con NVENC. Probado con GTX 1660 SUPER (Turing). |
| Utilidades | `awk`, `sed`, `numfmt`, `pgrep`, `df`, `stat` (vienen con Fedora). |
| Opcional | `systemd-inhibit` (evita que la PC se suspenda). `tmux` o `screen` (recomendado). |

Comprobar que ffmpeg tiene lo necesario:

```bash
ffmpeg -filters 2>/dev/null | grep -E " (rubberband|amix|atempo|alimiter) "
ffmpeg -encoders 2>/dev/null | grep h264_nvenc
```

## 2. Uso

```bash
chmod +x procesar_live.sh
./procesar_live.sh
```

Recomendado dentro de `tmux` o `screen`, por si se cierra la terminal.

El script pregunta, en este orden:

1. **Ruta del video original.** Acepta Tab para autocompletar, `~`, comillas, espacios escapados y archivos arrastrados a la terminal.
2. **Carpeta de salida.** Si no existe, la crea. Ahí quedará el video final y se hará el trabajo temporal.
3. **Menú principal:** edición automática, modificación de la edición automática, edición manual, historial o salida.
4. Configuración, resumen y confirmación según la opción elegida.

## 3. Modos

### Edición automática

Muestra este submenú:

```text
========= EDICIÓN AUTOMÁTICA =========
 1) Mostrar estructura
 2) Empezar
 3) Volver
======================================
```

Antes de empezar, `Mostrar estructura` enseña la configuración completa.
Los valores iniciales son:

| Parámetro | Valor |
|---|---|
| Vocal | incluido, 0 dB, pitch 1000 (x1.000) |
| No-vocal | incluido, 0 dB, pitch 1000 (x1.000) |
| Velocidad | 100 (x1.0000, original) |
| Calidad de video (CQ) | 26 |

Estos valores se pueden cambiar desde `Modificar edición automática` y quedan
guardados en `procesar_live_auto.conf`, junto a este script.

### Modificar edición automática

Permite cambiar y guardar el perfil automático mediante un configurador con
estas secciones:

```text
 1) Modificar no-vocal
 2) Modificar vocal
 3) Modificar video
 4) Mostrar configuración actual
 5) Aplicar cambios
 6) Volver (descartar cambios)
```

Los cambios solo se guardan al elegir `Aplicar cambios`. `Volver` restaura los
valores que había al entrar.

### Edición manual

Cada pregunta muestra el valor por defecto entre corchetes (Enter lo acepta). Si el valor está fuera de rango, avisa y vuelve a preguntar.

| Parámetro | Formato | Rango |
|---|---|---|
| No-vocal: incluir o quitar | s / n | |
| No-vocal: ganancia | dB, con decimales (`-15`, `-7.5`, `0`, `+3`) | -60 a +20 |
| No-vocal: pitch | entero (`950` = más grave, `1000` = original, `1035` = +3,5%) | 500 a 2000 |
| Vocal: incluir o quitar | s / n | |
| Vocal: ganancia | dB (`-6` = más bajo, `0` = original, `+3` = más alto) | -60 a +20 |
| Vocal: pitch | entero (`950` = más grave, `1000` = original, `1050` = más agudo) | 500 a 2000 |
| Velocidad | entero (`100` = original, `103` = +3%, `110` = +10%) | 50 a 200 |
| CQ (calidad) | entero (`23` = alta, `26` = equilibrado, `30` = liviano) | 15 a 35 |

Notas:
- Si se quita el no-vocal, no se aplican su ganancia ni su pitch.
- Si se quita el vocal, no se aplican su ganancia ni su pitch.
- En todas las preguntas, Enter acepta el valor que aparece entre corchetes.
- Si se quitan **ambos** audios, avisa que el video quedaría sin audio y pide confirmación. En ese caso se omiten Demucs y todo el procesado de audio.
- **CQ:** menor número = más calidad y más peso. Guía que muestra el script: 20-22 muy alta, 23 alta, 26 equilibrada, 28 más liviana, 30+ calidad baja.

Tras el resumen, el menú manual ofrece:

1. **Prueba de 2 minutos** con los valores elegidos.
2. **Procesar el video completo.**
3. Cambiar los valores.
4. Volver al menú principal.
5. Salir.

Todos los submenús tienen una opción `Volver`. Al volver desde el configurador
se descartan los cambios pendientes de esa sesión de edición.

### Modo prueba (solo manual)

- Procesa 2 minutos del video (por defecto desde el inicio; pregunta desde qué minuto). Si queda menos, usa lo que haya.
- Corre el flujo completo, incluido Demucs, pero solo sobre ese fragmento.
- Guarda `prueba_XXNN.mp4` en la carpeta de salida (si existe, `prueba_XXNN_2.mp4`, etc.).
- Al terminar muestra el **peso estimado del video completo** con el CQ elegido, calculado con el archivo de prueba (aproximado, depende del movimiento del fragmento).
- Después se puede probar otra vez con otros valores, procesar el completo o salir.

## 4. Qué hace por dentro

### Antes de procesar

1. Valida el video: existe, es legible, tiene pista de video y de audio, y se puede leer su duración.
2. Mide con `ffprobe` la resolución, los **fps reales** (usa `avg_frame_rate`; si está a menos de 1% de un valor estándar como 24, 25, 29.97, 30, 50 o 60, lo ajusta; si no, usa el valor medido), el rango de color (`yuvj420p` o `color_range=pc` = rango completo) y las etiquetas de color (colorspace, primaries, transfer).
3. Comprueba herramientas, filtros y codificador, y decodifica 5 segundos del video real. **Se juzga por el código de salida de ffmpeg**, no por si imprimió avisos (los videos de TikTok suelen dar avisos inofensivos).
4. Comprueba espacio en disco y prueba, con 3 segundos del video real, los filtros de audio, los de video y NVENC. Así cualquier fallo aparece **antes** de gastar tiempo en Demucs.

### Pipeline (5 pasos)

1. **Audio a WAV.** `-map 0:a:0 -vn -c:a pcm_s16le -ar 44100 -ac 2 -rf64 auto`. El video original no se copia: se crea un **enlace simbólico** `original.ext` dentro de la carpeta temporal. No se crea un "video sin audio": el render final toma solo la pista de video del original (`-map 0:v:0`).
2. **Demucs.** Ejecuta `bash demuc_ffmpeg.sh audio.wav` desde dentro de la carpeta de trabajo. Ese script normaliza y corta el audio en segmentos de 10 minutos, corre `demucs --two-stems=vocals`, une los resultados y genera `demucs_work_audio/resultado_final/audio_vocals.wav` y `audio_no_vocals.wav`. Después hay un **reposo de GPU** de 30 s (10 s en la prueba).
   - Si falla un segmento o falta uno de sus dos stems, `demuc_ffmpeg.sh` termina con error y no arma un resultado incompleto. Además, el script principal compara las duraciones de los stems con `audio.wav`: diferencia mayor a 1 s se registra como problema; mayor a 30 s es **error grave**.
3. **Audio final** (WAV de 48 kHz, comando aparte para no rehacerlo si NVENC falla):
   - Vocal: `volume=<dB>dB`, `rubberband=pitch=<factor>` (se omite si el pitch es 1000), `aresample=48000`
   - No-vocal: `volume=<dB>dB`, `rubberband=pitch=<factor>` (se omite si el pitch es 1000), `aresample=48000`
   - Mezcla: `amix=inputs=2:normalize=0:duration=longest` (suma las pistas como Kdenlive; con una sola pista activa no se usa)
   - Velocidad: `atempo=<factor>` (conserva el tono; se omite si la velocidad es 100)
   - Protección: `alimiter=limit=0.98:level=0` (solo evita el clipping; no normaliza)
   - Luego, **pausa de 15 s** para que la GPU baje a reposo.
4. **Render de video.**
   - Filtros: `setpts=PTS/<factor>` (se omite si la velocidad es 100), `fps=<fps del original>` (fuerza fps constantes; conserva 25 o 30), escala a dimensiones pares (si la fuente es rango completo, convierte a rango limitado con `in_range=pc:out_range=tv`) y `format=yuv420p`.
   - Codificador: `h264_nvenc -preset p5 -tune hq -rc vbr -cq <CQ> -b:v 0 -spatial-aq 1 -temporal-aq 1 -bf 2 -profile:v high`.
   - Etiquetas de color del original preservadas (`-color_range tv` más colorspace, primaries y trc). Si alguna etiqueta fuera inválida, el script lo detecta en la prueba previa, sigue sin ellas y lo registra como problema.
   - Audio: AAC 160k, 48 kHz, estéreo. Contenedor MP4 con `+faststart`.
   - Se renderiza a `trabajo/salida.mp4` y solo después se mueve a la carpeta de salida.
5. **Verificación.**
   - Duración del video y del audio del resultado: tolerancia de 1 s.
   - Duración final contra la esperada (original ÷ factor de velocidad): tolerancia de 2 s + 0,1%.
   - Una diferencia se registra como problema, no detiene el proceso.

### Archivos y carpetas

```
<carpeta de salida>/
├── XXNN_procesado.mp4        ← resultado final (ej: ka13_procesado.mp4)
├── prueba_XXNN.mp4           ← solo si se hizo una prueba
├── log_XXNN.txt              ← solo si hubo problemas
└── _temp_procesamiento/      ← se borra al terminar bien
    ├── original.mp4          ← enlace simbólico al video original
    └── trabajo/              ← WAV intermedios, Demucs, salida.mp4
```

- `XXNN` es un código aleatorio de 2 letras y 2 números. Se verifica que no exista, así que **nunca se sobrescribe nada**.
- Antes de cualquier `rm -rf`, el script comprueba que la ruta sea exactamente la subcarpeta `_temp_procesamiento` (o algo dentro de ella) y que esté directamente dentro de la carpeta de salida. Nunca toca la carpeta de salida ni el original. Borrar el enlace simbólico no borra el video original.

Junto a `procesar_live.sh` también se crean:

```text
procesar_live_auto.conf       ← configuración persistente de la edición automática
historial_procesar_live.txt   ← historial de configuraciones y procesamientos
```

## 5. Resultado, log y errores

Al terminar un render completo, muestra un resumen:

- **Original vs resultado:** peso (con % de cambio), duración, resolución, fps, bitrate medio.
- **Ajustes usados:** ganancias, pitch, velocidad, CQ.
- **Tiempos:** Demucs, audio final, render final (NVENC), procesamiento completo, y tiempo total desde que se abrió el script.
- **Archivos:** ruta del video final y del log, si hubo.

## 6. Historial

La opción `Historial` del menú principal muestra:

```text
============= HISTORIAL =============
 1) Ver historial completo
 2) Aplicar registro
 3) Volver
======================================
```

`Ver historial completo` muestra los registros de arriba hacia abajo, desde el
más antiguo hasta el más reciente. Cada registro incluye fecha, tipo de
edición, video, carpeta de salida, vocal, no-vocal, pitch, ganancias, velocidad,
CQ, resultado, tiempos y avisos.

`Aplicar registro` muestra una lista simplificada en el mismo orden, con el
registro más antiguo arriba y el más reciente abajo. Después de
elegir un número, enseña el registro seleccionado y pide confirmación. Si se
confirma, copia sus valores de vocal, no-vocal, pitch, ganancias, velocidad y CQ
a la edición automática y los guarda en `procesar_live_auto.conf`. La opción
`0) Volver` cancela la selección.

El archivo se guarda en:

```text
$HOME/Documents/youtube/codigo/historial_procesar_live.txt
```

La configuración automática se guarda separadamente en:

```text
$HOME/Documents/youtube/codigo/procesar_live_auto.conf
```

Comportamiento según el resultado:

| Situación | Qué pasa |
|---|---|
| Todo bien | Mensaje "Todo salió correcto y sin problemas". Se borra la carpeta temporal. No se crea log. |
| Terminó con avisos | Se genera el video, el mensaje final resume los problemas (hasta 8 líneas) y se crea `log_XXNN.txt` con los detalles. Se borra la carpeta temporal. |
| Error grave | Se aborta, se crea el log, **se conserva la carpeta temporal** y se indica dónde quedó para que se borre a mano. |
| Ctrl+C | Detiene los procesos descendientes, conserva la carpeta temporal y avisa. No cambia la configuración de la GPU. |

Los problemas de la prueba se marcan como `[Prueba]` en el log y no cuentan para el mensaje final del render completo.

## 7. Rendimiento de referencia

Hardware: GTX 1660 SUPER, Ryzen 5 5600X, 15 GiB de RAM.

| Caso | Resultado |
|---|---|
| Referencia hecha a mano en Kdenlive: video de 3h18m35s | 3h12m48s, 720x1280, 30 fps, 2,2 GiB (1,66 Mbit/s), ~20 min de render |
| Corrida del script: video de 1h29m58s, no-vocal -20 dB, pitch 1040, velocidad 104, CQ 23 | 1h26m30s, 2,8 GiB (4,59 Mbit/s) contra 1,2 GiB del original |
| Tiempos de esa corrida | Extracción de audio 5 s, Demucs 6m17s (9 segmentos de ~35 s con pausas de 8 s), audio final 2m18s, render 4m47s (18x), total 16m11s |

El original de TikTok viene comprimido a ~1,9 Mbit/s. Recodificar con CQ bajo no recupera detalle, solo agranda el archivo; por eso la edición automática usa CQ 26. El CQ no afecta los fps ni la sincronía audio/video.

## 8. Constantes ajustables

Están al inicio del script:

| Constante | Valor | Qué controla |
|---|---|---|
| `TEST_SECONDS` | 120 | Duración del modo prueba |
| `GPU_REST_DEMUCS_FULL` / `GPU_REST_DEMUCS_TEST` | 30 / 10 | Reposo de GPU tras Demucs |
| `GPU_REST_SECONDS` | 15 | Pausa antes del render NVENC |
| `TOL_DEMUCS_WARN` / `TOL_DEMUCS_FATAL` | 1 / 30 | Tolerancias (s) de duración de los stems |
| `TOL_AV` | 1 | Tolerancia (s) entre video y audio del resultado |
| `CQ` (en `procesar_live_auto.conf`) | 26 | CQ de la edición automática |

## 9. Solución de problemas

| Síntoma | Causa y solución |
|---|---|
| "No encuentro demuc_ffmpeg.sh" | Verificar que exista `$HOME/Documents/audio/codigo/demuc_ffmpeg.sh`, ponerlo junto a `procesar_live.sh`, o fijar `DEMUCS_SCRIPT` (sección 9). |
| "Tu ffmpeg no tiene el filtro X" o "h264_nvenc" | Instalar el ffmpeg completo: `sudo dnf swap ffmpeg-free ffmpeg --allowerasing`. |
| "ffmpeg no pudo decodificar el video" | Mirar el log. Si solo hay avisos y el código de salida es 0, usar la versión actual del script. |
| "Ya existe una carpeta temporal" | Es de una ejecución que falló. Revisarla o aceptar que el script la borre. |
| Error grave en Demucs | Revisar `trabajo/demucs_general.log` dentro de la carpeta temporal conservada. |
| Se cuelga la GPU (Xid 79) | El flujo usa pausas entre segmentos y reposos extra antes del render. Este script no modifica el límite de potencia ni persistence mode. |

## 10. Cómo encuentra `demuc_ffmpeg.sh`

```bash
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
DEMUCS_SCRIPT="${DEMUCS_SCRIPT:-}"
```

Si no se define `DEMUCS_SCRIPT`, lo busca en este orden:

1. La misma carpeta que `procesar_live.sh`.
2. La carpeta hermana `../../audio/codigo/` relativa a `youtube/codigo/`.
3. `$HOME/Documents/audio/codigo/demuc_ffmpeg.sh`.

También podés forzar otra ubicación sin editar el script:

```bash
DEMUCS_SCRIPT="/ruta/completa/demuc_ffmpeg.sh" ./procesar_live.sh
```

Lo ejecuta con `bash`, así que no necesita permiso de ejecución. Espera que genere `demucs_work_audio/resultado_final/audio_vocals.wav` y `audio_no_vocals.wav` dentro del directorio donde se ejecuta.

## 11. Limitaciones conocidas

- Los nombres complejos de archivos y carpetas se normalizan en el directorio de trabajo de Demucs para evitar problemas con rutas de concatenación.
- Solo se procesa la primera pista de audio y la primera de video.
- Las estimaciones de peso son aproximadas.
- Un video HEVC recodificado a H.264 pesará más que el original.
- Un `kill` (SIGTERM) enviado al script mientras corre un comando largo puede tardar en surtir efecto; Ctrl+C funciona de inmediato.
- Fue validado en un entorno de prueba con un Demucs simulado y libx264. NVENC y Demucs reales los validó el usuario en su equipo.

<!--
=====================================================================
RESUMEN DE LA CONVERSACIÓN COMPLETA (para que otra IA entienda el panorama)
=====================================================================

IDIOMA Y ESTILO
Usuario: hispanohablante rioplatense (Buenos Aires). Respondérle en español con voseo. Suele pedir "aún no hagas el script" y quiere discutir y acordar condiciones antes de que se genere código. Valora que se le diga qué se cambia, qué se deja y qué falta saber. Le interesa que los mensajes del script sean legibles.

1) PUNTO DE PARTIDA
El usuario usa Nobara Linux (Fedora, KDE). Preguntó si Kdenlive se puede usar solo desde la terminal para separar el audio del video y renderizar solo el audio en WAV.
Respuesta: Kdenlive es una interfaz sobre el motor MLT. El binario kdenlive solo abre la app. Lo parecido a un modo terminal es melt (paquete mlt-tools), que renderiza proyectos .kdenlive o archivos sueltos, por ejemplo: melt entrada consumer avformat:salida.wav con vn=1 y acodec=pcm_s16le. Kdenlive también genera un script de render desde el diálogo Renderizar con "Generar script". Para extraer audio a WAV desde un video, ffmpeg es más simple: ffmpeg -i video -vn -acodec pcm_s16le -ar 44100 -ac 2 audio.wav.
Luego pidió un resumen detallado de los comandos de Kdenlive/melt; se le dio: opciones de kdenlive, melt (consumers, in/out, -attach filtros, -query), script de render y edición del XML .kdenlive.

2) EL FLUJO QUE QUIERE AUTOMATIZAR (visto en sus capturas de Kdenlive)
Timeline con V1 (video), A1 (audio vocals) y A2 (audio no_vocals) con efecto Volume (ganancia -15 dB) y efecto Rubberband Pitch Scale (pitch scale 1,035, latencia 52 ms, sin stretch) sobre la pista A2. Render con preset NVENC H264 (los parámetros eran ab=160k, acodec=aac, channels=2, f=mp4, rc=constqp, vcodec=h264_nvenc, vq=23). El video quedaba un 3% más rápido.
Objetivo: UN solo script que:
 1. separe audio y video (ffmpeg) y renderice el audio en WAV;
 2. use su demuc_ffmpeg.sh para separar vocal / no-vocal; permita configurar ganancia y rubberband pitch en ambas pistas; una vocal + no-vocal + el video;
 3. acelere el video completo un 3%;
 4. renderice en NVENC H264 VBR (es el más rápido en su PC).
Pidió que primero se evaluara la factibilidad, sin crear el script.

3) SU SCRIPT demuc_ffmpeg.sh (subido por el usuario)
Separa un audio largo con Demucs en segmentos de 10 minutos (SEGMENT_SECONDS=600) para no saturar la RAM: normaliza a WAV PCM, usa Demucs con segment 7 (límite del modelo htdemucs), dispositivo cuda y pausa de 8 s entre segmentos. No cambia el límite de potencia ni persistence mode. Usa nombres seguros para la carpeta de trabajo, conserva los logs ante errores y no concatena si falta un segmento o uno de sus stems. Concatena en el orden original y escapa rutas para que los espacios y comillas no rompan la lista de ffmpeg. No requiere sudo.

4) FACTIBILIDAD Y DECISIONES TÉCNICAS ACORDADAS
- Todo posible con ffmpeg, ffprobe y demucs; sin instalar nada nuevo.
- ffmpeg del usuario: 8.1.2 de Nobara/RPM Fusion con librubberband (filtro rubberband confirmado) y h264_nvenc. Aparece WARNING library configuration mismatch (y el build declara disable-decoder h264,hevc), pero la decodificación funciona; por eso el script prueba decodificar el video real.
- Pitch vs velocidad: se acelera con atempo (conserva el tono) para que el pitch lo defina solo el filtro rubberband (prioridad del usuario).
- Copia del original: se usa un ENLACE SIMBÓLICO original.ext dentro de la carpeta temporal (no gasta disco ni tiempo; borrar la carpeta no borra el original). El usuario aceptó y prefirió no renombrar su archivo.
- No se crea "video sin audio": el render toma solo la pista de video (map 0:v:0).
- Mezcla con amix normalize=0 (como Kdenlive), limitador final alimiter con level=0, WAV con rf64 auto.
- Los fps los controla el filtro fps con el valor real del original (25 o 30); no se fuerza 30. El "-30fps" del nombre del clip en Kdenlive era del perfil del proyecto.
- Rango de color: fuente yuvj420p (rango completo) se convierte a yuv420p rango limitado, como hizo Kdenlive; se conservan etiquetas de color del original (bt709 o smpte170m).
- Resolución: se conserva la del original (dimensiones pares).
- Hardware: GTX 1660 SUPER (6 GB, Turing, driver 595.99.02), Ryzen 5 5600X, 15 GiB de RAM (~3,4 libres), ~104-158 GiB de disco libre.
- Encoder: h264_nvenc preset p5, tune hq, VBR con cq, AQ espacial y temporal, B-frames; AAC 160k.

5) CONDICIONES DEL USUARIO PARA EL SCRIPT
- Pide 2 rutas (video original y carpeta de salida), PRIMERO las rutas y DESPUÉS el menú. Con read -e (Tab, arrastrar archivos).
- Menú: 1) Edición automática, 2) Modificar edición automática, 3) Edición manual, 4) Historial, 5) Salir. Vocal y no-vocal permiten incluir/quitar, ganancia y pitch; video permite velocidad y CQ. Enter acepta el valor predeterminado y Volver descarta cambios pendientes.
- Los videos pueden durar 15 min, 1 h, 3 h o más; fps 25 o 30. Ejemplos: H.264 720x1280 30 fps yuvj420p bt709 3h18m (2,8 GiB) y HEVC 960x1920 25 fps smpte170m 1h41m (1,3 GiB).
- Referencia manual aprobada en Kdenlive: 3h18m35s a 3h12m48s, 2,2 GiB, 1,66 Mbit/s, ~20 min de render. Demucs tardaba ~12 min por 3 h de audio.
- Todo el trabajo en una subcarpeta propia de la carpeta de salida; al terminar se borran los temporales y queda solo el video final. Antes de borrar se verifica la ruta.
- Nombre final con código simple aleatorio (ka13_procesado.mp4). Modo prueba de 2 minutos (solo en manual). Al terminar NO se pregunta si procesar otro video.
- Mensaje final: si todo salió bien, decirlo; si hubo problemas, resumirlos y crear un log en la carpeta de salida (log_XXNN.txt). Si algo falla a mitad, CONSERVAR la carpeta temporal.
- Ctrl+C seguro; systemd-inhibit para que KDE no suspenda la PC; recomendar tmux o screen.
- Se redactó una especificación completa y el usuario pidió finalmente que la IA actual (Claude) creara el script, que quedó como procesar_live.sh.

6) HISTORIAL DE VERSIONES Y ERRORES
a) Versión inicial del script creada. Se probó solo sintaxis.
b) ERROR 1 (log_nc70): "Tu ffmpeg no tiene el filtro rubberband". Causa: grep -q en tubería con set -o pipefail; grep cierra la tubería, ffmpeg recibe SIGPIPE (código 141). Se confirmó con un bucle que dio 141 cinco veces. Corrección: guardar la salida de ffmpeg -filters y -encoders en variables y hacer grep sobre ellas.
c) PRIMER USO REAL EXITOSO (video 1h29m58s, 720x1280, 30 fps; manual: no-vocal -20 dB, pitch 1040, velocidad 104, vocal 0 dB, CQ 23): resultado 1h26m30s, 2,8 GiB (4,59 Mbit/s) contra 1,2 GiB del original (~1,9 Mbit/s). Tiempos: audio 5 s, Demucs 6m17s, audio final 2m18s, render 4m47s a 18x, total 16m11s (incluía el tiempo del menú). El usuario preguntó por qué la estimación de espacio decía ~9,7 GB cuando el video pesó 2,8 GB: era el espacio temporal máximo (WAV intermedios), no el peso final; decidió conservar la estimación pero con mejor redacción.
d) CAMBIOS pedidos tras esa corrida (todos aplicados): tiempo total desde abrir el script Y tiempo del render final; resumen final más detallado y legible (original vs resultado, ajustes, tiempos, rutas); reposo de GPU extra al terminar Demucs (30 s completo, 10 s prueba) además de 15 s antes del render; CQ: la edición automática pasa a CQ 26 y la manual permite elegirlo (15 a 35) con guía (20-22 muy alta, 23 alta, 26 equilibrada, 28 más liviana, 30+ baja; menor número = más calidad y más peso); estimación del peso del video completo al terminar la prueba. Se explicó que bajar el CQ casi no mejora la calidad real porque la fuente de TikTok ya está comprimida, y que el CQ no afecta fps ni sincronía audio/video.
e) Pruebas en el entorno de la IA: video sintético de 20 s con nombre con espacios, ñ y @, Demucs simulado y libx264 en lugar de NVENC; el flujo completo (prueba, estimación, render completo, resumen, limpieza) funcionó. NVENC y Demucs reales solo los probó el usuario.
f) ERROR 2 (log_eo73): "ffmpeg no pudo decodificar el video". Causa: la función de pruebas silenciosas daba el video por malo si ffmpeg escribía CUALQUIER mensaje; el log solo contenía avisos "non monotonically increasing dts ... 2 >= 2" del muxer null (un timestamp repetido cada 3 fotogramas, ~50 en 5 s), no errores de decodificación. Corrección: quiet_ffmpeg guarda el código de salida en QUIET_RC y se juzga por él; se aplicó a todas las pruebas previas (decodificación, filtros de audio, video+NVENC). Probado con un archivo dañado a propósito (QUIET_RC=0 con avisos; 254 con archivo inexistente). Se sospechó, sin confirmar, que ese video podría tener fps irregulares (~40) o timestamps repetidos; se le dio un comando ffprobe para revisarlo (codec_name, avg_frame_rate, r_frame_rate, time_base). Queda PENDIENTE confirmar si, con la versión corregida, ese video (tiktok_@antoniprime96 ... YA PUEDO PONER ANIMACIONES.mp4) se procesó bien y con qué fps.
g) La ruta de demuc_ffmpeg.sh se resuelve automáticamente en la carpeta del propio procesar_live.sh, en la carpeta hermana audio/codigo/ y en $HOME/Documents/audio/codigo/. También se puede fijar con DEMUCS_SCRIPT.

7) ESTADO FINAL Y PENDIENTES
- Archivos entregados: procesar_live.sh (versión actual con CQ, tiempos, reposo de GPU y la corrección de QUIET_RC) y este README.md.
- Comandos de referencia que dio el usuario/IA: ffmpeg -filters | grep rubberband; nvidia-smi con la opción query-gpu (name, driver_version, memory.total) y formato csv.
- Mejoras aplicadas: detección automática de la ruta real de demuc_ffmpeg.sh, posibilidad de fijarla con DEMUCS_SCRIPT, validación de herramientas y manejo seguro de rutas.
- Al modificar el script, mantener: nunca borrar fuera de _temp_procesamiento, nunca sobrescribir, conservar la carpeta temporal ante fallos, y probar con bash -n y un entorno de prueba antes de entregar.
=====================================================================
-->
