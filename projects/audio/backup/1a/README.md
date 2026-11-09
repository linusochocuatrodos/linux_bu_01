# demuc_ffmpeg.sh

Script para separar un audio largo en **voces** e **instrumental/no-voces**
usando [Demucs](https://github.com/facebookresearch/demucs), procesándolo
en segmentos de 10 minutos para evitar que el sistema se cuelgue en audios
largos (ver el resumen técnico al final de este documento para el porqué).

## Qué hace

1. Toma un archivo de audio (`.wav` u otro formato que `ffmpeg` entienda)
   y detecta su duración real con `ffprobe` — funciona con cualquier
   duración, no hay un máximo fijo.
2. Lo corta en segmentos de 10 minutos con `ffmpeg` (sin recodificar,
   usa `-c copy`, así que es instantáneo y sin pérdida de calidad).
3. Corre `demucs --two-stems=vocals` en cada segmento, uno por uno, con
   una pausa de 8 segundos entre cada uno (para darle tiempo a la GPU de
   bajar a estado de reposo de forma gradual — ver el resumen técnico).
4. Une todos los `vocals.wav` de cada segmento en un solo archivo final,
   y lo mismo con los `no_vocals.wav`.
5. Deja todo organizado en una carpeta de trabajo propia, sin tocar el
   archivo original.

## Uso

```bash
chmod +x demuc_ffmpeg.sh      # solo la primera vez, o si perdiste el permiso de ejecución
./demuc_ffmpeg.sh nombre_del_audio.wav
```

Correlo desde la misma carpeta donde está el archivo de audio.

## Estructura de salida

Para un archivo `mi_audio.wav`, el script crea:

```
demucs_work_mi_audio/
├── chunks/                        # segmentos de 10 min + logs de cada corrida de demucs
│   ├── parte_000.wav
│   ├── parte_000_demucs.log
│   ├── ...
│   └── separated/htdemucs/        # salida cruda de demucs por segmento
├── lista_vocals.txt               # listas internas usadas por ffmpeg para concatenar
├── lista_no_vocals.txt
└── resultado_final/
    ├── mi_audio_vocals.wav        # ← archivo final de voces (streamer + diálogos)
    └── mi_audio_no_vocals.wav     # ← archivo final de instrumental/banda sonora
```

**Los archivos que importan son los de `resultado_final/`.** La carpeta
`chunks/` se puede borrar una vez que confirmás que el resultado está
bien, para liberar espacio en disco (ocupa aproximadamente lo mismo que
el audio original, dos veces):

```bash
rm -rf demucs_work_mi_audio/chunks
```

## Configuración (al principio del script)

| Variable | Default | Qué hace |
|---|---|---|
| `SEGMENT_SECONDS` | `600` (10 min) | Duración de cada trozo en que se corta el audio |
| `DEMUCS_SEGMENT` | `7` | Límite interno del modelo Transformer de Demucs (`htdemucs`). No tocar salvo que cambies de modelo. |
| `DEMUCS_DEVICE` | `cuda` | Dispositivo para Demucs (`cuda` = GPU NVIDIA, `cpu` si no tenés GPU) |
| `INTER_CHUNK_PAUSE_SECONDS` | `8` | Pausa entre segmentos para evitar el cuelgue de GPU (ver resumen técnico) |

## Requisitos

- `ffmpeg` y `ffprobe` en el PATH
- `demucs` instalado (vía pip, con soporte CUDA si vas a usar GPU)

## Manejo de errores

- Si un segmento falla al procesarse con Demucs, el script **no se
  detiene**: lo anota, sigue con los demás, y al final te avisa qué
  segmentos fallaron. El resultado final se arma con lo que sí se pudo
  procesar.
- Si no hay ningún segmento procesado válido, el script se corta con un
  mensaje de error claro.

---

<!--
====================================================================
RESUMEN DE CONTEXTO PARA OTRA IA / PARA RETOMAR EN EL FUTURO
====================================================================
Este bloque documenta todo el proceso de diagnóstico y desarrollo que
llevó a este script, para que cualquier IA (u otra persona) que lea
este archivo entienda el panorama completo sin tener que repetir el
diagnóstico desde cero.

CONTEXTO DEL PROYECTO
----------------------
El usuario edita un video de reacción a una película (Spider-Man) en
Kdenlive, para subir a YouTube sin que lo bloqueen por Content ID. La
voz del streamer y el audio de la película están grabados juntos en
una única pista. La estrategia es usar Demucs (separación de fuentes
por IA) para dividir esa pista en:
  - vocals.wav: voces del streamer + diálogos de los actores
  - no_vocals.wav: banda sonora/orquesta de la película (lo que activa
    el Content ID)
Luego en Kdenlive se reemplaza el audio original por vocals.wav y se
le aplica un cambio de tono (+1 semitono) para alterar la huella
acústica.

HARDWARE DEL USUARIO
----------------------
- Linux Nobara 44 (base Fedora 44), KDE Plasma 6.7.4, Wayland
- CPU: AMD Ryzen 5 5600X (6 núcleos/12 hilos)
- GPU: NVIDIA GeForce GTX 1660 Super (6GB VRAM, arquitectura Turing)
- Driver: nvidia-driver 595.99.02 (rama Open GPU Kernel Module, DKMS,
  versión reciente/bleeding-edge con fecha de compilación 20/sep/2026)
- RAM: 16GB físicos (15.5 GiB)
- Swap: 25GB (8GB zram + 17GB partición en NVMe)
- Discos: Kingston NVMe 931GB (sistema), más varios discos adicionales
- Software: Demucs 4.1.0 vía pip, PyTorch 2.14, CUDA

EL PROBLEMA ORIGINAL
----------------------
Al correr `demucs --two-stems=vocals audio_recortado.wav` sobre un
archivo de audio de 1h45m (1.2GB, WAV sin comprimir), el sistema se
colgaba por completo (sin responder mouse/teclado) por hasta 2 horas,
forzando un reinicio con el botón de encendido.

PROCESO DE DIAGNÓSTICO (en orden cronológico)
----------------------
1. Primer intento con el comando estándar de Demucs: crasheó por
   OOM-kill del kernel (systemd-oomd mató la terminal Warp) al llegar
   la RAM física al 96-98% con el navegador Brave abierto en paralelo.
   La carpeta de salida quedó vacía (0 bytes) — el proceso murió antes
   de terminar de escribir.

2. Segundo intento con `--shifts=0 --overlap=0.1` (reducido para bajar
   uso de RAM) y cerrando programas pesados: el sistema se tildó por
   2 horas igual, sin ningún proceso visible muerto. Hubo que forzar
   el reinicio con el botón de power.

3. Se recolectó información de hardware (inxi, dmidecode, lscpu,
   nvidia-smi) y se activó el journal persistente de systemd
   (`/var/log/journal`) que no estaba habilitado — por eso el primer
   cuelgue no dejó rastro en los logs.

4. Se descubrió que `--segment=10` no es válido: el modelo Transformer
   `htdemucs` tiene un máximo de 7.8 segundos de segment. Se corrigió
   a `--segment=7`.

5. Con un clip de prueba de 2 minutos, `--segment=7` funcionó sin
   problemas (7 segundos de proceso).

6. Al correr el audio completo de 1h45m con `--segment=7` vía `nohup`
   (desacoplado de la terminal) y monitoreo en paralelo (`free -h` +
   `nvidia-smi` cada 10s a un log), SÍ terminó de separar el audio en
   apenas 5 minutos (confirmado en el log de demucs: barra de progreso
   al 100% en 5:10), PERO el sistema se colgó 25 minutos después sin
   haber escrito ningún archivo de salida a disco. El monitoreo mostró
   el proceso demucs con 44.7 GiB leídos pero solo 640 KiB escritos, y
   el swap llegando al 93% de uso (23.3 de 25 GiB) — indicando swap
   thrashing severo en la fase final de escritura. Causa hipotetizada:
   Demucs arma el audio de salida completo en RAM (como tensor, no en
   streaming) antes de escribirlo, lo cual para 1h45m de audio desborda
   los 16GB de RAM física del usuario.

7. SOLUCIÓN DE DIVISIÓN EN SEGMENTOS: se creó `demuc_ffmpeg.sh`, que
   corta el audio en trozos de 10 minutos con ffmpeg, corre Demucs
   trozo por trozo (liberando memoria entre cada uno), y concatena los
   resultados al final con ffmpeg. Esto redujo el pico de RAM/swap
   drásticamente: en la siguiente corrida con el audio completo de
   1h45m, el swap usado bajó del 93% anterior a apenas el 4% (934 MiB
   de 25 GiB), y la RAM nunca pasó del 30% de uso.

8. PERO el sistema igual se colgó al final de esa corrida (proceso
   terminado correctamente según los logs, archivos de salida
   perfectos y sin fallos al escucharlos después) — aunque esta vez el
   audio de una ventana de Brave seguía sonando durante el cuelgue,
   indicando que el kernel y PipeWire seguían vivos, y que el problema
   estaba aislado a la capa gráfica (Wayland/kwin) o al driver NVIDIA.

9. Se había activado el journal persistente a tiempo, así que esta vez
   SÍ quedó registro del cuelgue. Se encontró:
     NVRM: Xid (PCI:0000:0b:00): 79, pid=2158, name=kwin_wayland,
     GPU has fallen off the bus.
   Xid 79 = la GPU dejó de responder al bus PCIe por completo. Es un
   error de hardware/driver grave sin recuperación posible por
   software; requiere reinicio físico. Ocurrió ~27 segundos después de
   que el script terminara (toda la carga CUDA ya había cesado),
   consistente con un problema en la transición de carga alta → idle.

10. Se descartó que fuera un problema específico de carga gráfica:
    `glxgears` corrió varios minutos sin cuelgues. Se descartó también
    que fuera cualquier carga CUDA sostenida: un script de stress test
    con PyTorch (multiplicaciones de matrices 8000x8000 en loop, ~200
    iteraciones) en GPU terminó sin problema. Esto sugiere que el
    patrón específico de Demucs (quizás transferencias de memoria
    CPU↔GPU particulares, o el patrón de inicio/fin de cada segmento)
    es lo que dispara el Xid 79 — no la carga CUDA en sí de forma
    genérica.

11. Se investigaron posibles causas de Xid 79 bajo carga sostenida:
    alimentación eléctrica insuficiente/inestable de la fuente de
    poder (PSU) en el momento de transición de carga, mal contacto
    físico de la GPU, o inestabilidad del driver Open Kernel Module
    reciente (versión 595.99.02, fecha de compilación muy nueva,
    20/sep/2026). El usuario no tiene acceso a los datos de su PSU
    (perdió la caja/papeles) ni presupuesto para reemplazarla, así que
    se descartó esa vía y se buscaron mitigaciones por software.

12. MITIGACIONES APLICADAS AL SCRIPT (sin tocar el driver ni el
    kernel, para no arriesgar romper el arranque gráfico):
    a) Pausa de 8 segundos entre cada segmento procesado, para que la
       GPU baje a idle de forma gradual.
    b) (Descartado luego) Límite de potencia de GPU vía
       `nvidia-smi -pl 100` y persistence mode vía `nvidia-smi -pm 1`,
       aplicados con `sudo -n` (no interactivo) al inicio del script y
       restaurados al final con un `trap EXIT`. Estas NUNCA llegaron a
       aplicarse en la práctica porque el usuario no tiene configurado
       sudo sin contraseña para nvidia-smi — el script avisaba del
       fallo pero continuaba igual (diseño "best effort", sin abortar
       el script por esto).

13. VALIDACIÓN: con la pausa de 8s entre segmentos únicamente (sin el
    power limit, que nunca se aplicó), se corrieron exitosamente y SIN
    NINGÚN CUELGUE:
      - Un audio de 1h45m (7m 24s de proceso total)
      - Un audio corto de ~3m36s (14s de proceso, sin pausas porque
        solo hubo 1 segmento)
      - Un audio de 2h30m, 16 segmentos (11m 32s de proceso total)
    Las tres corridas terminaron limpias, sin Xid, y los archivos de
    salida se escucharon correctamente.

14. Dado que la pausa sola demostró ser suficiente en múltiples
    pruebas, y que el usuario no quería requerir `sudo`/contraseña
    cada vez que corre el script, se SIMPLIFICÓ el script quitando por
    completo la lógica de power limit y persistence mode (funciones
    apply_gpu_mitigations/restore_gpu_defaults, el trap EXIT, y las
    variables GPU_PM_APPLIED/GPU_PL_APPLIED/GPU_POWER_LIMIT_WATTS/
    GPU_MITIGATIONS_ENABLED). El script actual en este repo es esa
    versión simplificada: solo corta, procesa con pausas, y concatena.

ESTADO ACTUAL / PENDIENTE
----------------------
- El script en su forma actual (solo con la pausa de 8s) funcionó sin
  fallos en 3 pruebas consecutivas de distinta duración (incluidas dos
  de más de 1h45m y 2h30m). Se considera la solución funcional
  "oficial" del usuario.
- La causa raíz de fondo (por qué Demucs específicamente dispara un
  Xid 79 en esta GPU/driver, cuando ni carga gráfica ni stress test
  CUDA genérico lo hacen) SIGUE SIN EXPLICARSE del todo. Hipótesis no
  descartadas: patrón específico de transferencias de memoria de
  Demucs/torchaudio, picos de corriente de la PSU en el momento exacto
  de transición post-segmento, o un bug del firmware GSP del driver
  Open Kernel Module en GPUs Turing (mitigación sugerida pero NO
  aplicada: `nvidia.NVreg_EnableGpuFirmware=0` vía grubby, requiere
  reinicio — el usuario no quiso tocar esto por miedo a romper el
  sistema).
- Si en el futuro el cuelgue volviera a repetirse a pesar de la pausa,
  los próximos pasos a probar en orden serían: (1) aumentar
  INTER_CHUNK_PAUSE_SECONDS, (2) retomar el power limit/persistence
  mode configurando sudoers sin contraseña para nvidia-smi, (3)
  desactivar el firmware GSP del driver, (4) considerar cambiar de
  rama de driver (propietario clásico vs Open Kernel Module) — esta
  última opción fue explícitamente rechazada por el usuario por miedo
  a romper el sistema, así que solo debería proponerse si el usuario
  lo pide de nuevo explícitamente.
====================================================================
-->
