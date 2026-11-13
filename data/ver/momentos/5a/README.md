# Stream Moments

Registro de momentos guardados de streams, organizado por streamer y por video. Permite agregar momentos desde un archivo plano y luego verlos, abrirlos en el navegador, editarlos o eliminarlos desde menús interactivos en la terminal.

## Scripts

- `momento.sh` — procesa `momentos.txt` y guarda en `data/`
- `ver.sh` — lista todos los momentos con URLs `#t=<segundos>`
- `abrir.sh` — menú interactivo para abrir un momento en el navegador
- `edit.sh` — menú interactivo para editar el timestamp de un momento
- `remover.sh` — menú interactivo para eliminar momentos
- `lib.sh` — funciones compartidas (no ejecutar directamente)

## Estructura de archivos

```
.
├── momento.sh        # Importador desde momentos.txt
├── ver.sh            # Listado plano
├── abrir.sh          # UI: abrir en navegador
├── edit.sh           # UI: editar timestamp
├── remover.sh        # UI: eliminar
├── lib.sh            # Librería compartida (menús, parseo, navegación)
├── momentos.txt      # Entrada plana (se vacía al procesar)
├── data/             # Almacén persistente
│   ├── <streamer>/
│   │   └── <video-id>.md
│   └── backup/
│       └── <streamer>/
│           └── <video-id>.md
└── README.md         # Este archivo
```

## Uso

### 1. Agregar momentos: `momento.sh`

`momento.sh` lee `momentos.txt` línea por línea, valida cada entrada, crea o actualiza el archivo del streamer/video correspondiente, ordena los momentos por timestamp, evita duplicados y vacía el archivo de entrada.

**Formato de cada línea:**
```
<streamer> <url> <timestamp> <descripción>
```

- `streamer`: nombre del streamer (sin espacios), se usa como nombre de carpeta.
- `url`: URL completa del video en Kick (u otra plataforma). El último segmento de la URL se usa como ID del video y nombre del archivo.
- `timestamp`: `M:SS` o `H:MM:SS`. Rango válido: minutos y segundos entre 0 y 59.
- `descripción`: texto libre.

**Ejemplo:**
```bash
echo "aquino https://kick.com/aquino/videos/UUID 12:34 preguntas de webones" >> momentos.txt
./momento.sh
```

**Salida esperada:**
```
OK: aquino → UUID @ 12:34 — preguntas de webones
...
Procesados: N | Omitidos: M
```

- Las líneas vacías o que empiezan con `#` se ignoran.
- Si el timestamp es inválido, la línea se omite y se cuenta en "Omitidos".
- Si la descripción ya existe en el archivo del video, se omite (duplicado).
- Tras procesar, `momentos.txt` se vacía.

### 2. Ver todos los momentos: `ver.sh`

Lista todos los momentos guardados en una tabla plana, ordenados por streamer y por timestamp.

```bash
./ver.sh
```

**Salida esperada:**
```
aquino-0:57  preguntas de webones en party quiz  ->  https://kick.com/aquino/videos/UUID1#t=57
aquino-2:37  los webones en tiktok               ->  https://kick.com/aquino/videos/UUID2#t=157
auronplay-1:48  tortillando con los amigos       ->  https://kick.com/auronplay/videos/abc123#t=108
```

El formato es `streamer-minuto  descripción  ->  URL#t=segundos`. La URL incluye el fragmento `#t=segundos` que los navegadores usan para abrir el video en un punto específico.

### 3. Abrir en el navegador: `abrir.sh`

Menú interactivo para seleccionar un momento y abrirlo en el navegador con el `#t=` ya puesto. Tras abrir un momento, el menú se re-muestra con `clear` para que puedas abrir varios seguidos sin volver al inicio.

```bash
./abrir.sh
```

**Flujo:**

1. Menú de streamers (raíz). Opciones: `1..N` streamers, `0) Todos`, `s) Salir`.
2. Menú de momentos (submenú). Opciones: `1..N` momentos, `v) Volver`, `s) Salir`.
3. Al elegir un momento, se abre en el navegador y el menú se re-muestra con los mismos datos actualizados.

**Navegador:** se intenta abrir con `xdg-open`, luego `gio open`, luego `firefox`, `google-chrome`, `chromium` (en ese orden). Si no hay ninguno, se imprime la URL para abrir manualmente.

### 4. Editar timestamp: `edit.sh`

Menú interactivo para cambiar el timestamp de un momento existente. Tras editar, el menú se re-muestra con el cambio aplicado para que puedas seguir editando otros momentos.

```bash
./edit.sh
```

**Flujo:**

1. Menú de streamers (raíz). Opciones: `1..N` streamers, `0) Todos`, `s) Salir`.
2. Menú de momentos (submenú). Opciones: `1..N` momentos, `v) Volver`, `s) Salir`.
3. Prompt "Nuevo minuto (ej. 1:45 o 0:05:30, 'v' volver, 's' salir):". Acepta:
   - `M:SS` o `H:MM:SS` → editar.
   - `v` → volver al menú de momentos.
   - `s` → salir del script.
4. Tras editar, se muestra el mensaje "Editado: ..." y el menú de momentos se re-muestra con el cambio aplicado.

**Validación del timestamp:** minutos y segundos deben ser `<= 59`.

### 5. Remover: `remover.sh`

Menú interactivo para eliminar momentos. Tras eliminar, el menú se re-muestra para que puedas seguir eliminando otros momentos del mismo streamer.

```bash
./remover.sh
```

**Flujo desde un streamer específico:**

1. Menú de streamers (raíz). Opciones: `1..N` streamers, `0) Todos`, `s) Salir`.
2. Submenú del streamer (`== STREAMER ==`):
   - `1) Elegir un momento a eliminar`
   - `2) Eliminar TODOS los momentos`
   - `v) Volver` (al menú de streamers)
   - `s) Salir`
3. Al elegir `1`: menú de momentos. Eliges uno, aparece el prompt de confirmación:
   - `yes` / `y` → eliminar
   - `no` / `n` → cancelar
   - `v` → volver al menú de momentos
   - `s` → salir del script
   Tras eliminar, el menú de momentos se re-muestra.
4. Al elegir `2`: prompt "Vas a eliminar TODOS los momentos de: <streamer> (N archivo(s))". Mismas opciones de confirmación. Tras eliminar, vuelve al menú de streamers.

**Flujo desde "Todos":**

1. Menú de streamers. Eliges `0) Todos los streamers`.
2. Submenú `== TODOS ==`:
   - `1) Elegir un momento específico` (muestra momentos de todos los streamers)
   - `2) Eliminar TODOS los momentos de un streamer` (pide elegir streamer)
   - `v) Volver` / `s) Salir`

**Eliminación de archivos:** si tras quitar un momento el archivo del video queda vacío (solo el header), se elimina. Si la carpeta del streamer queda vacía, también se elimina.

## Estructura de datos

Cada momento se almacena en `data/<streamer>/<video-id>.md`. El archivo tiene:

```markdown
# <streamer> — <video-id>

**URL:** <url completa>
**Fecha:** <YYYY-MM-DD>

| Segundos | Minuto | Momento |
|---:|---:|:---|
| <segundos> | <M:SS o H:MM:SS> | <descripción> |
| ... |
```

- Las primeras 7 líneas son el header (no se modifican al editar/eliminar, salvo el orden de las líneas 6 y 7 que se invierte al reordenar — esto es intencional para que el sort por columna 2 funcione).
- A partir de la línea 8 van los momentos, ordenados por la columna "Segundos" (numérica).
- Cada momento es una fila de la tabla markdown.

## Mecánica interna

### `lib.sh` (librería)

Funciones compartidas:

- `limpiar()`: ejecuta `clear`. Se llama al inicio de cada menú para que solo se vea un menú a la vez en la terminal.
- `abrir_en_navegador(url)`: intenta abrir la URL con varios navegadores en orden de preferencia.
- `listar_streamers()`: lista las carpetas dentro de `data/`.
- `cargar_momentos(filtro)`: lee todos los `.md` de `data/` y devuelve un archivo temporal con formato `streamer|segundos|minuto|desc|url` por línea. Si se pasa un `filtro` (streamer), solo incluye los de ese streamer.
- `menu_streamers(prompt, es_raiz)`: muestra el menú de streamers. `es_raiz="s"` muestra solo `s) Salir`; cualquier otro valor muestra `s) Salir` y `v) Volver`.
- `menu_momentos(prompt, tmp, es_raiz)`: muestra el menú de momentos. Mismo manejo de `v`/`s` según `es_raiz`.
- `submenu_acciones(titulo, ...)`: menú genérico con opciones numeradas `1)`, `2)`, etc. El `titulo` se muestra en mayúsculas como `== TITULO ==`. Las acciones se pasan como triplets `(numero, descripcion, nombre_funcion)`.
- `confirmar_accion(prompt)`: prompt de confirmación con `yes/no`, `v` (volver), `q` (salir). Nota: esta función está en `lib.sh` pero `remover.sh` usa su propia función `confirmar` con `s` en vez de `q` para salir.

### Códigos de retorno de los menús

Todos los menús y acciones devuelven un código de retorno estandarizado:

- `0` = selección hecha (el resultado está en `SELECCION` o `SELECCION_LINEA`).
- `2` = volver al menú anterior.
- `3` = salir del script entero.

### Manejo de `set -e`

Los scripts usan `set -euo pipefail` al inicio. Para evitar que `set -e` mate el script cuando una función retorna un código no-cero, cada llamada a menú/acción se envuelve con `set +e` antes y `set -e` después, capturando el código en una variable. Esto es necesario porque bash mata el script si una función retorna no-cero aunque el `return` esté dentro de un `if`.

### Prompts intermedios sin `clear`

Los prompts intermedios (`pedir_timestamp`, `confirmar`) no hacen `clear` antes de mostrar el detalle. Esto permite que el usuario vea el menú anterior justo arriba del prompt y tome una decisión con más contexto.

## Comportamiento de los menús

### Opción `v` (volver)

Solo aparece en submenús. En el menú raíz, solo aparece `s) Salir`.

### Opción `s` (salir)

Aparece en todos los menús y submenús. Sale del script completo.

### Re-mostrado tras acciones

- `abrir.sh`: tras abrir un momento, el menú de momentos se re-muestra con `clear` y los datos actualizados.
- `edit.sh`: tras editar, el menú de momentos se re-muestra con el cambio aplicado. El mensaje "Editado: ..." se muestra antes del prompt de timestamp en la siguiente iteración.
- `remover.sh`: tras eliminar un momento, el menú de momentos se re-muestra sin el momento eliminado.

## Compatibilidad

Los scripts están escritos en bash puro y funcionan en cualquier distribución Linux moderna (y en macOS). No requieren dependencias adicionales más allá de bash ≥ 4 y las herramientas estándar de GNU coreutils (`find`, `grep`, `sed`, `awk`, `sort`, `wc`, `head`, `tail`, `mktemp`).

### Distribuciones testeadas

- **Kali Linux** ✅ (basado en Debian, trae `bash 5.x`, `xdg-utils`, `firefox-esr` preinstalados).
- **Nobara Linux** ✅ (basado en Fedora/RHEL, mismo entorno que donde se desarrollaron los scripts).
- Cualquier distro con bash ≥ 4 y los binarios listados arriba.

### Navegadores soportados

`abrir.sh` usa la función `abrir_en_navegador()` que intenta abrir la URL con los siguientes navegadores, en orden de prioridad:

1. **Launchers genéricos del sistema** (respetan el navegador por defecto configurado):
   - `xdg-open` (Linux estándar, paquete `xdg-utils`).
   - `gio open` (entornos GTK/GNOME).
2. **Navegadores específicos** (si no hay launcher):
   - `firefox` y `firefox-esr` (Kali trae el ESR por defecto).
   - `google-chrome` y `google-chrome-stable`.
   - `chromium`.
   - `brave-browser` y `brave`.
   - `microsoft-edge` y `edge` (Microsoft Edge para Linux).
   - `helium-browser` y `helium` (Helium Browser, fork de Chromium).

Si ninguno está disponible, la función imprime la URL en pantalla para que la abras manualmente:

```
No se encontró navegador. Abrí manualmente: https://kick.com/...
```

### Cómo instalar navegadores adicionales

Los scripts no requieren un navegador específico, pero si querés usar uno que no está en tu sistema:

**En Kali (basado en Debian):**
```bash
# Google Chrome
wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo dpkg -i google-chrome-stable_current_amd64.deb
sudo apt -f install

# Brave
sudo apt install curl
sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" | sudo tee /etc/apt/sources.list.d/brave-browser-release.list
sudo apt update && sudo apt install brave-browser

# Microsoft Edge
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft-edge.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" | sudo tee /etc/apt/sources.list.d/microsoft-edge.list
sudo apt update && sudo apt install microsoft-edge-stable

# Chromium (alternativa libre a Chrome, disponible en repos)
sudo apt install chromium
```

**En Nobara (basado en Fedora):**
```bash
# Google Chrome
sudo dnf install fedora-workstation-repositories
sudo dnf config-manager --set-enabled google-chrome
sudo dnf install google-chrome-stable

# Brave
sudo dnf install dnf-plugins-core
sudo dnf config-manager --add-repo https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
sudo dnf install brave-browser

# Microsoft Edge
sudo dnf config-manager --add-repo https://packages.microsoft.com/yumrepos/edge
sudo dnf install microsoft-edge-stable

# Chromium
sudo dnf install chromium
```

**Helium Browser:**
Helium no está en los repos oficiales de la mayoría de distros. Se descarga desde [helium.computer](https://helium.computer) o su GitHub. Una vez instalado, el binario suele estar en `~/.local/bin/helium-browser` o `/usr/local/bin/helium-browser`. Si el script no lo encuentra, podés crear un symlink:
```bash
sudo ln -s /ruta/a/helium /usr/local/bin/helium-browser
```

### Verificar qué navegador usará el script

Para ver qué navegador detectará el script en tu sistema:
```bash
for cmd in xdg-open gio firefox firefox-esr google-chrome google-chrome-stable chromium brave-browser brave microsoft-edge edge helium-browser helium; do
  command -v "$cmd" >/dev/null 2>&1 && echo "✅ $cmd" || echo "❌ $cmd"
done
```

El primero que aparezca con ✅ será el que use `abrir.sh`. Si querés forzar uno específico, instalalo y asegurate de que aparezca antes que los otros en la lista de prioridad (los launchers genéricos como `xdg-open` tienen prioridad sobre los navegadores específicos).

### Configurar el navegador por defecto

Si tenés varios navegadores instalados y querés que `xdg-open` use uno específico:

**Kali (XFCE):**
```bash
sudo update-alternatives --set x-www-browser /usr/bin/firefox-esr
```

**Kali/Nobara (genérico):**
```bash
xdg-settings set default-web-browser firefox-esr.desktop
# o para Chrome:
xdg-settings set default-web-browser google-chrome.desktop
# o para Brave:
xdg-settings set default-web-browser brave-browser.desktop
```

## Backup de momentos originales

Cada momento que se agrega se respalda automáticamente en `data/backup/<streamer>/<video-id>.md`. Este backup es una copia de seguridad que conserva el estado original de cada momento para que puedas restaurarlo manualmente si lo editas o eliminas por error.

### Cómo funciona

- **Al agregar un momento** (`momento.sh`): si es la primera vez que se ve ese video, se crea el archivo de backup con el header + el momento nuevo. Si ya existe backup, se agrega la nueva línea al backup (sin duplicar si ya estaba).
- **Al editar un momento** (`edit.sh`): el archivo en `data/<streamer>/` se modifica, pero el backup queda intacto con el timestamp original. Así puedes ver cómo era antes de editarlo.
- **Al eliminar un momento** (`remover.sh`): el archivo en `data/<streamer>/` pierde la línea, pero el backup la conserva. Así puedes restaurar el momento eliminado desde el backup.

El backup **acumula** todos los momentos que se agregaron alguna vez, incluso si después se eliminan. Es decir, refleja el historial de agregaciones, no el estado actual.

### ⚠️ IMPORTANTE: no modificar el backup

El directorio `data/backup/` **NO debe ser modificado por ningún chat AI, script automático, ni intervención manual no deliberada del usuario**. Es la única red de seguridad para restaurar momentos editados o eliminados.

- No borrar archivos de `data/backup/` a menos que sea una decisión consciente del usuario.
- No editar archivos de `data/backup/` (cambiar timestamps, descripciones, etc.).
- No "limpiar" o "resetear" el backup como parte de una tarea de mantenimiento.

### Cómo restaurar un momento manualmente

Si editaste o eliminaste un momento y querés volver al estado original:

1. Abrí el archivo de backup: `data/backup/<streamer>/<video-id>.md`.
2. Comparalo con el archivo actual: `data/<streamer>/<video-id>.md`.
3. Copiá la línea o líneas que querés restaurar del backup al archivo actual, o reemplazá el archivo actual por completo con `cp data/backup/<streamer>/<video-id>.md data/<streamer>/<video-id>.md` (esto revierte todas las ediciones/eliminaciones de ese video al estado del backup).
4. Verificá con `./ver.sh` o `./abrir.sh` que el momento restaurado aparece correctamente.

## Nota para chat AI

Cuando un chat AI (como el que asiste al usuario) trabaje con este repositorio:

- **NO elimines ni modifiques** el directorio `data/backup/` ni su contenido. Es el respaldo del usuario para restaurar momentos editados o eliminados.
- **NO elimines momentos** del directorio `data/<streamer>/` (ni archivos `.md` ni líneas dentro de ellos) a menos que el usuario lo pida explícitamente. Si encontrás un momento "nuevo" o "diferente" que parece no pertenecer, **no lo borres**: puede ser un momento legítimo que el usuario agregó después. Si hay dudas, preguntale al usuario antes de eliminar cualquier cosa.
- **NO reescribas `momentos.txt` con datos de suposiciones o inventados**. Solo agregá líneas a `momentos.txt` si el usuario te las da explícitamente.
- **NO modifiques la estructura del proyecto** (no muevas archivos, no renombres carpetas, no cambies el formato de los `.md`) a menos que el usuario lo pida.

En resumen: el contenido de `data/` y `data/backup/` es del usuario. Tu trabajo es ayudar a operar los scripts, no a reorganizar o "limpiar" los datos del usuario.
