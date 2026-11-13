# Stream Moments

Registro de momentos guardados de streams, organizado por streamer y por video. Permite agregar momentos desde un archivo plano, por CLI o de forma interactiva, y luego verlos, buscarlos, abrirlos en el navegador, editarlos o eliminarlos desde menús en la terminal.

Todos los listados respetan **orden de llegada estricto** (los momentos agregados más recientemente aparecen arriba del todo).

## Scripts

- `menu.sh` — menú principal unificado (opcional, nuclea todos los scripts)
- `momento.sh` — procesa `momentos.txt`, archivo custom, CLI directa o modo interactivo
- `ver.sh` — listado plano, búsqueda, últimos N, solo URLs y estadísticas
- `abrir.sh` — menú interactivo para abrir un momento en el navegador
- `edit.sh` — menú interactivo para editar minuto, descripción o fecha
- `remover.sh` — menú interactivo para eliminar momentos
- `lib.sh` — funciones compartidas (no ejecutar directamente)

## Estructura de archivos

```
.
├── menu.sh           # Hub unificado (opcional)
├── momento.sh        # Importador (txt / CLI / interactivo)
├── ver.sh            # Listado plano, búsqueda y stats
├── abrir.sh          # UI: abrir en navegador
├── edit.sh           # UI: editar minuto, descripción o fecha
├── remover.sh        # UI: eliminar
├── lib.sh            # Librería compartida (parseo awk, menús, orden)
├── momentos.txt      # Entrada plana (se vacía al procesar líneas válidas)
├── data/             # Almacén persistente
│   ├── .orden        # Índice incremental de orden de llegada
│   ├── <streamer>/
│   │   └── <video-id>.md
│   └── backup/
│       └── <streamer>/
│           └── <video-id>.md
└── README.md         # Este archivo
```

## Uso

### 1. Agregar momentos: `momento.sh`

Modos disponibles:
```bash
./momento.sh                                          # Procesa momentos.txt
./momento.sh otro_archivo.txt                         # Procesa un archivo específico
./momento.sh -i                                       # Modo interactivo paso a paso
./momento.sh aquino https://kick.com/aquino/videos/UUID 12:34 preguntas de webones
```

**Formato de cada línea:**
```
<streamer> <url> <timestamp> <descripción>
```

- `streamer`: nombre del streamer (sin espacios ni `/`), se usa como nombre de carpeta.
- `url`: URL del video (Kick, Twitch, YouTube, etc.). Cualquier `#t=...` previo en la URL se limpia automáticamente.
- `timestamp`: `M:SS` o `H:MM:SS`. Rango válido: minutos y segundos entre 0 y 59. Si ponés `-` y la URL ya trae `#t=SEG` o `?t=SEG`, extrae el minuto automáticamente.
- `descripción`: texto libre (si contiene `|`, se convierte en `│` para no romper la tabla markdown).

**Ejemplo:**
```bash
echo "aquino https://kick.com/aquino/videos/UUID 12:34 preguntas de webones" >> momentos.txt
./momento.sh
```

**Manejo de errores y duplicados:**
- Las líneas vacías o que empiezan con `#` se ignoran.
- Si la descripción ya existe en el archivo del video, se omite (duplicado).
- Si todas las líneas son válidas (o duplicadas), `momentos.txt` queda vacío. Si hay líneas con errores de formato o timestamp, **solo las líneas con error quedan en `momentos.txt`** para que las corrijas sin perder lo que escribiste.

### 2. Ver y buscar momentos: `ver.sh`

Lista todos los momentos guardados por orden de llegada (más recientes arriba).

```bash
./ver.sh                  # Todos los momentos (más recientes arriba)
./ver.sh minecraft        # Buscar texto en descripciones/streamers/fechas
./ver.sh -s aquino        # Solo momentos de aquino
./ver.sh -n 10            # Últimos 10 momentos agregados
./ver.sh -u               # Solo URLs con #t=segundos (útil para copiar/pipes)
./ver.sh --stats          # Resumen total y por streamer
```

### 3. Abrir en el navegador: `abrir.sh`

Menú interactivo para seleccionar un momento y abrirlo en el navegador con `#t=<segundos>`. Tras abrir un momento, el menú se re-muestra con un banner de confirmación.

```bash
./abrir.sh
```

**Opciones dentro de la lista de momentos:**
- `1..N` → abrir momento en el navegador.
- `b` o `/texto` → buscar/filtrar en vivo (`l` limpia el filtro).
- `+` / `-` → cambiar de página (aparece automáticamente si hay más momentos que el alto de la terminal).
- `v` → volver / `s` → salir.

### 4. Editar: `edit.sh`

Menú interactivo para editar minuto, descripción o fecha de un momento guardado.

```bash
./edit.sh
```

Al elegir un momento podés:
- Escribir un minuto nuevo directamente (ej. `1:45` o `0:05:30`) → guarda al instante sin clics extra.
- `d` → editar la descripción (actualiza el `.md` y `data/.orden`).
- `f` → editar la fecha del video (`YYYY-MM-DD`).
- `a` → abrir el momento en el navegador desde ahí mismo para verificar el segundo exacto antes de editarlo.
- `v` → volver / `s` → salir.

### 5. Remover: `remover.sh`

Menú interactivo para eliminar momentos individuales o todos los momentos de un streamer (con confirmación `y/n`).

```bash
./remover.sh
```

Si tras quitar un momento el archivo del video queda vacío, se elimina. Si la carpeta del streamer queda vacía, también se elimina. **Nunca toca `data/backup/`.**

## Estructura de datos y orden de llegada

Cada momento se almacena en `data/<streamer>/<video-id>.md`:

```markdown
# <streamer> — <video-id>

**URL:** <url completa>
**Fecha:** <YYYY-MM-DD>

| Segundos | Minuto | Momento |
|---:|---:|:---|
| <segundos> | <MM:SS o HH:MM:SS> | <descripción> |
```

- Todo momento agregado por `momento.sh` se registra en `data/.orden` con un número de secuencia incremental (`seq`), por lo que **siempre sube al puesto #1 (orden de llegada)**, aunque pertenezca a un video de semanas anteriores.
- Los momentos previos que ya estaban en `data/` antes de existir `data/.orden` conservan automáticamente su orden `(fecha_iso DESC → mtime DESC → posición en el archivo)`.
- `edit.sh` y `remover.sh` preservan el `mtime` del `.md` (`touch -r`) para que editar o borrar un momento antiguo no altere el orden.

## Compatibilidad

Los scripts están escritos en bash puro y funcionan en cualquier distribución Linux moderna (y en macOS). Requieren bash ≥ 4 y las herramientas estándar (`find`, `grep`, `sed`, `awk`, `sort`, `wc`, `head`, `tail`, `mktemp`, `touch`).

### Distribuciones testeadas

- **Kali Linux** ✅ (Debian, `bash 5.x`, `xdg-utils`, `firefox-esr`).
- **Nobara Linux** ✅ (Fedora/RHEL).

### Navegadores soportados

`abrir_en_navegador()` intenta abrir la URL en este orden:

1. **Launchers del sistema:** `open` (macOS), `xdg-open`, `gio` (Linux).
2. **Navegadores específicos:** `firefox`, `firefox-esr`, `google-chrome`, `google-chrome-stable`, `chromium`, `brave-browser`, `brave`, `microsoft-edge`, `edge`, `helium-browser`, `helium`.

Si no hay entorno gráfico o navegador disponible, imprime la URL en pantalla para abrirla manualmente.

### Configurar el navegador por defecto

```bash
xdg-settings set default-web-browser firefox-esr.desktop
# o Chrome / Brave:
xdg-settings set default-web-browser google-chrome.desktop
xdg-settings set default-web-browser brave-browser.desktop
```

## Backup de momentos originales

Cada momento agregado se respalda en `data/backup/<streamer>/<video-id>.md`.
- `momento.sh` jamás sobrescribe un backup existente: si eliminaste un video en `data/` y después agregás otro momento de ese mismo video, el backup histórico se conserva y solo agrega el nuevo.
- `edit.sh` y `remover.sh` nunca modifican `data/backup/`.

### ⚠️ IMPORTANTE: no modificar el backup

El directorio `data/backup/` **NO debe ser modificado por ningún chat AI, script automático, ni intervención manual no deliberada del usuario**. Es la única red de seguridad para restaurar momentos editados o eliminados.

### Cómo restaurar un momento manualmente

1. Abrí `data/backup/<streamer>/<video-id>.md`.
2. Comparalo con `data/<streamer>/<video-id>.md`.
3. Copiá las filas que querés restaurar o reemplazá el archivo con `cp data/backup/<streamer>/<video-id>.md data/<streamer>/<video-id>.md`.
4. Verificá con `./ver.sh` o `./abrir.sh`.

## Nota para chat AI

Cuando un chat AI trabaje con este repositorio:

- **NO elimines ni modifiques** el directorio `data/backup/` ni su contenido.
- **NO elimines momentos** de `data/<streamer>/` a menos que el usuario lo pida explícitamente.
- **NO reescribas `momentos.txt`** con datos inventados ni de suposiciones.
- **NO modifiques la estructura del proyecto** ni el formato de los `.md` a menos que el usuario lo pida.
