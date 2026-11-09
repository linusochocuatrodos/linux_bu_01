# reescalar.sh

Script en bash para reescalar imágenes **de a una, a elección del usuario** (no procesa carpetas enteras automáticamente), pensado para achicar imágenes sobredimensionadas antes de usarlas como overlays/fondos en proyectos de Kdenlive, sin perder calidad visible y sin cargar al render con píxeles de más que nunca se van a mostrar.

## Qué hace

1. Recibe una imagen (como argumento o pegando/arrastrando su ruta en modo interactivo).
2. La reescala para que su **lado más largo** (ancho o alto, según si es horizontal o vertical) no supere un máximo configurable. **Nunca agranda** una imagen que ya sea más chica que ese máximo.
3. Guarda el resultado en una **carpeta fija**, siempre la misma, sin importar desde dónde se ejecute el script.
4. Si el nombre de archivo ya existe en esa carpeta, le agrega un sufijo numérico (`_01`, `_02`, ...) en vez de sobrescribir.
5. Muestra en pantalla la comparación de dimensiones y peso (antes → después) de cada imagen procesada.

## Requisitos

- **ImageMagick** instalado (`magick` o `convert`, detecta automáticamente cuál tenés). Instalar con:
  ```bash
  sudo dnf install ImageMagick
  ```

## Configuración (editable al principio del script)

| Variable | Qué controla | Valor actual |
|---|---|---|
| `TARGET_LONG_EDGE` | Lado más largo máximo en píxeles al que se reescala | `2200` |
| `FOLDER_NAME` | Nombre de la subcarpeta de salida. Si se deja `""`, se arma solo como `"${TARGET_LONG_EDGE}px"` | `""` (→ `2200px`) |
| `JPG_QUALITY` | Calidad de compresión para salidas `.jpg`/`.jpeg` (1-100). Los `.png` no usan esto | `92` |
| `OUTPUT_BASE_DIR` | Base donde se crea la carpeta de salida (por defecto `$HOME`), sin importar desde dónde se ejecute el script; la salida queda en `$OUTPUT_BASE_DIR/Pictures/kdenlive/imagenes/usados/` | `$OUTPUT_BASE_DIR/Pictures/kdenlive/imagenes/usados/` |

## Uso

**Modo interactivo** (pide una imagen, la procesa, pregunta por la siguiente, hasta que dejás vacío y Enter para salir):
```bash
./reescalar.sh
```

**Modo directo** (pasás una o varias imágenes como argumento, por ejemplo arrastrándolas a la terminal después del nombre del script):
```bash
./reescalar.sh imagen1.jpg imagen2.png
```

**Resultado final**, siempre en:
```
$HOME/Pictures/kdenlive/imagenes/usados/2200px/
```

## Alias recomendado (`~/.bashrc`)

```bash
alias rees='bash $HOME/Documents/kdenlive/codigo/reescalar.sh'
```
Permite correr `rees` desde cualquier carpeta. Como `OUTPUT_BASE_DIR` es una ruta absoluta fija (no relativa a dónde está el script ni a dónde se lo invoca), el resultado siempre cae en el mismo lugar sin importar desde dónde se use el alias.

---

<!--
RESUMEN DE CONTEXTO CONVERSACIONAL — solo sobre "reescalar.sh"
(para que otro asistente de IA entienda el panorama completo sin
leer toda la conversación original)

ORIGEN DEL PROBLEMA:
El usuario edita videos largos (1h40min-2h+) en Kdenlive (Linux Nobara,
GPU NVIDIA GTX 1660 SUPER) con timelines de 6-7 pistas de video
compuestas simultáneamente (picture-in-picture, overlays, logos,
fondos, efectos de Transform/Flip/Crop/Scale/Saturation/Hue, etc.).
El renderizado final pasó de ~2.5h (proyecto simple) a 8h, y luego
a 15-17h al agregar una pista más y una imagen de fondo.

DIAGNÓSTICO PREVIO (contexto, no es sobre el script en sí):
Se estableció que Kdenlive NO puede componer efectos/timeline por GPU
(Movit está permanentemente deshabilitado por los propios desarrolladores
de Kdenlive por inestabilidad, confirmado en su documentación oficial).
Solo la codificación final (NVENC H264) usa GPU; decodificación y
compositing de capas siempre corren por CPU. Esto es estructural y no
se puede cambiar por configuración.

CAUSA RAÍZ ESPECÍFICA ENCONTRADA:
Revisando las imágenes usadas como overlays/fondos en el proyecto, se
encontró que estaban MUY sobredimensionadas respecto a la resolución
del proyecto (1920x1080):
  - 99i9i9i.jpg (fondo, cubre TODO el video): 5000x9000 px (45 millones
    de píxeles, 22x más que los 2 millones del proyecto)
  - rayas_perfectas2.png: 3328x1856 px
  - fondo_wanos.png (usada 2 veces): 1856x3328 px
  - Logo_finalizado-upscaled.png: 2336x1568 px
Kdenlive tenía que recomponer y reescalar estas imágenes gigantes en
CADA FRAME, durante horas de metraje (la imagen de fondo cubre el
video completo) → esto se identificó como la causa principal probable
del tiempo de render desproporcionado.

SOLUCIÓN PROPUESTA: crear este script (reescalar.sh) para bajar esas
imágenes a un tamaño razonable (2200px de lado largo, con margen
~15% sobre los 1920px del proyecto) antes de usarlas en Kdenlive,
reemplazándolas en el timeline vía "Replace Clip" (función nativa de
Kdenlive que mantiene los efectos/Transform ya aplicados, solo cambia
el archivo fuente).

ITERACIONES DEL SCRIPT (en orden cronológico):
1. Primera versión: procesa UNA imagen por vez (nunca una carpeta
   entera), modo interactivo tipo "arrastrar y soltar" (mismo estilo
   que otro script del usuario, procesar_live.sh), carpeta de salida
   nombrada según la resolución (ej: "2200px/").
2. Corrección 1: el usuario pidió que si el nombre de archivo ya existe
   en destino, se agregue un sufijo numérico en vez de sobrescribir.
3. Corrección 2 (bug real encontrado por el usuario): la carpeta de
   salida se creaba relativa a la carpeta ACTUAL de la terminal al
   ejecutar el script, no relativa a dónde estaba guardado el script.
   Se corrigió usando $(dirname "${BASH_SOURCE[0]}") para anclarla
   a la ubicación del script.
4. Corrección 3 (cambio de requisito): el usuario después pidió que,
   en cambio, la salida fuera SIEMPRE a una ruta absoluta fija
   ($HOME/Pictures/kdenlive/imagenes/usados/), sin importar
   dónde esté guardado el script ni desde dónde se lo ejecute. Se
   reemplazó la lógica de SCRIPT_DIR por una variable OUTPUT_BASE_DIR
   con ruta absoluta hardcodeada. Esta es la versión actual/final.

PROBLEMA DE DESPLIEGUE (no del código del script en sí):
El usuario tiene el script guardado en dos ubicaciones distintas:
  - $HOME/Documents/kdenlive/codigo/reescalar.sh (la que usa
    el alias 'rees')
  - Carpeta de descargas del navegador (de donde lo baja cada vez
    que se le pasa una versión nueva)
Varias veces el usuario corrió una versión VIEJA del script sin haber
reemplazado el archivo en Documents/kdenlive/codigo/, causando que el
comportamiento no coincidiera con la última versión acordada (ej: la
carpeta de salida aparecía en $HOME/2200px en vez de donde debía).
La solución cada vez fue: borrar el viejo, mover el nuevo descargado
a esa ruta, y volver a dar permisos de ejecución (chmod +x), ya que
los permisos no se conservan al descargar/mover un archivo nuevo.
Recordatorio para el usuario: cada vez que se actualice el script,
tiene que reemplazar manualmente el archivo en
$HOME/Documents/kdenlive/codigo/reescalar.sh.

ESTADO ACTUAL:
El script funciona correctamente con la lógica de OUTPUT_BASE_DIR fija.
Falta confirmar en la conversación original si, tras reemplazar las
4 imágenes optimizadas en el proyecto de Kdenlive real (vía Replace
Clip), el tiempo de render bajó efectivamente de las 15-17h previas.
Esa verificación con un render de prueba corto (Selected zone, 2-3 min)
estaba pendiente al momento de este resumen.

PENDIENTE/NO RESUELTO (relacionado pero no sobre el script):
- Confirmar si alguna de las 4 imágenes tiene zoom/escala animada en
  el efecto Transform de Kdenlive (afecta si 2200px es suficiente o
  si conviene subir el valor a ~3000-3200px para esa imagen puntual).
- Un crash de Kdenlive al crear proyectos nuevos (no relacionado al
  script, causado por configuración corrupta tras una actualización
  del sistema) se resolvió por separado reseteando ~/.config/kdenliverc.
-->
