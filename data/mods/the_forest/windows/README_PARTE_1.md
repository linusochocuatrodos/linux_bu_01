# Guía Completa: ModAPI & Bigger Backpack en The Forest (Windows 11)
### Compatible con Crack Multijugador Online (CreamAPI / UberPsyX / Spacewar AppID 480)

Esta guía documenta de forma exhaustiva cómo instalar, parchar y calibrar el mod **Bigger Backpack (v1.0)** usando **ModAPI** en la versión final de **The Forest (v1.12)** bajo **Windows 11**, conservando el funcionamiento pleno del multijugador online cooperativo y evitando los crasheos clásicos del motor Unity.

---

## Índice
1. [Requisitos Previos y Advertencia de Antivirus](#1-requisitos-previos-y-advertencia-de-antivirus)
2. [Descarga Correcta de ModAPI](#2-descarga-correcta-de-modapi)
3. [El Truco de Renombrado (Arquitectura 32-bit vs 64-bit)](#3-el-truco-de-renombrado-arquitectura-32-bit-vs-64-bit)
4. [Validación de Steam en ModAPI](#4-validación-de-steam-en-modapi)
5. [Prevención de Error: UberPsyX.ini not found](#5-prevención-de-error-uberpsyxini-not-found)
6. [Inyección del Mod con ModAPI](#6-inyección-del-mod-con-modapi)
7. [Despliegue Manual de Librerías y Assets](#7-despliegue-manual-de-librerías-y-assets)
8. [Configuración Calibrada de la Mochila (Evitar Crashes)](#8-configuración-calibrada-de-la-mochila-evitar-crashes)
9. [Lanzamiento Final y Multijugador en Steam](#9-lanzamiento-final-y-multijugador-en-steam)
10. [Solución de Problemas Frecuentes](#10-solución-de-problemas-frecuentes)

---

## 1. Requisitos Previos y Advertencia de Antivirus

- **Juego:** *The Forest* (v1.12, motor Unity 5.6.5p4).
- **Crack Multijugador:** Emulador de Steam de PiviGames / CreamAPI / UberPsyX / Spacewar (AppID 480).
  > **Nota Crítica:** Este crack multijugador fue desarrollado exclusivamente para el binario de **32 bits** (`TheForest32.exe` y `TheForest32_Data`).
- **Exclusión de Seguridad en Windows 11:**
  Windows Defender suele emitir falsos positivos con herramientas que usan `Mono.Cecil` (como ModAPI) y con librerías emuladoras (`CreamAPI.dll`, `Redirector.dll`).
  - Ve a: **Inicio $\rightarrow$ Configuración $\rightarrow$ Privacidad y seguridad $\rightarrow$ Seguridad de Windows $\rightarrow$ Protección contra virus y amenazas**.
  - En *Configuración de Protección contra virus y amenazas*, selecciona **Administrar la configuración**.
  - Baja hasta **Exclusiones** $\rightarrow$ **Agregar o quitar exclusiones** $\rightarrow$ **Agregar una exclusión $\rightarrow$ Carpeta**.
  - Selecciona la carpeta raíz donde tienes instalado *The Forest*.

---

## 2. Descarga Correcta de ModAPI

> ⚠️ **Advertencia importante sobre la descarga:**
> Si descargas el mod directamente desde la página individual del mod, solo obtendrás un archivo suelto `.mod` sin el ejecutable principal `ModAPI.exe`.

1. Entra a la página principal de ModAPI para *The Forest*:
   👉 **[https://modapi.survivetheforest.net/game/TheForest/](https://modapi.survivetheforest.net/game/TheForest/)**
2. En la lista de mods disponibles, busca y marca la casilla del mod **Bigger Backpack**.
3. Haz clic en el botón de descarga del paquete completo (usualmente identificado como *Download* o el botón flotante inferior).
4. El archivo descargado contendrá la herramienta `ModAPI.exe` junto con el mod pre-empaquetado dentro de `mods/TheForest/BiggerBackpack-*.mod`.
5. Extrae el contenido en una subcarpeta llamada `ModAPI` dentro del directorio principal del juego:
   ```text
   <Carpeta del Juego>\ModAPI\

3. El Truco de Renombrado (Arquitectura 32-bit vs 64-bit)

  - El Problema: El crack multijugador solo funciona en el binario de 32 bits
    (TheForest32.exe). Sin embargo, ModAPI tiene bloqueado su selector de
    archivos para aceptar estrictamente TheForest.exe y la carpeta
    TheForest_Data (la versión de 64 bits sin crack).
  - La Solución: Unity asocia de forma nativa el nombre del ejecutable con la
    carpeta <NombreExe>_Data. Renombraremos los binarios para que ModAPI procese
    los archivos de 32 bits creyendo que son de 64 bits:

Abre el explorador de archivos en la carpeta de The Forest:

1.  Respaldar versión de 64 bits:
      - Renombra TheForest.exe \rightarrow TheForest_original64.exe
      - Renombra TheForest_Data \rightarrow TheForest_Data_original64
2.  Promover versión de 32 bits (con online):
      - Renombra TheForest32.exe \rightarrow TheForest.exe
      - Renombra TheForest32_Data \rightarrow TheForest_Data

(A partir de este momento, TheForest.exe es el ejecutable con el crack online
listo para recibir el mod).

4. Validación de Steam en ModAPI

Al abrir ModAPI.exe, el programa realiza una verificación estricta de que exista
un archivo Steam.exe de Windows válido (con encabezados PE reales y más de 1 MB
de tamaño).

1.  Abre ModAPI\ModAPI.exe.
2.  Ve a la pestaña Ajustes (Settings).
3.  En la casilla de ruta de Steam:
      - Selecciona el ejecutable oficial de tu instalación de Steam
        (habitualmente en C:\Program Files (x86)\Steam\steam.exe).
      - Alternativa de respaldo: Si ModAPI arroja NoProjectWarning: Steam is not
        installed, copia el archivo respaldado TheForest_original64.exe (22 MB),
        pégalo en la raíz del juego con el nombre Steam.exe, y selecciónalo en
        ModAPI.
4.  MUY IMPORTANTE: Mantén DESMARCADA la casilla "Conexión con Steam" (Steam
    Connection).
5.  En la sección del juego The Forest, selecciona tu nuevo TheForest.exe.
6.  Verifica que la herramienta muestre: Steam OK y Game OK.

5. Prevención de Error: UberPsyX.ini not found

Cuando ModAPI lanza el juego como subproceso, el directorio de trabajo activo
pasa a ser .\ModAPI\. El emulador multijugador (Redirector.dll / CreamAPI.dll)
buscará sus archivos de configuración en la carpeta actual y en la de plugins.

Para prevenir que el juego falle al arrancar:

1.  Localiza en la raíz del juego los archivos del crack:
      - UberPsyX.ini
      - cream_api.ini
      - steam_appid.txt
      - CreamAPI.dll
      - Redirector.dll
2.  Copia y pega esos 5 archivos dentro de la carpeta: ModAPI\
3.  Copia y pega esos mismos archivos dentro de: TheForest_Data\Plugins\

6. Inyección del Mod con ModAPI

1.  En la pestaña principal de ModAPI, asegúrate de que esté seleccionada la
    casilla del mod Bigger Backpack.
2.  Haz clic en el botón inferior Start Game (Iniciar Juego).
3.  ModAPI ejecutará Mono.Cecil, decompilará
    TheForest_Data\Managed\Assembly-CSharp.dll, inyectará el código del mod e
    insertará BaseModLib.dll.
4.  En cuanto el juego intente arrancar (o si muestra el logo de Unity y se
    cierra), ciérralo de inmediato.
5.  Cierra ModAPI.exe por completo.
    ¿Por qué no dejar ModAPI abierto? ModAPI es únicamente una herramienta de
    parcheo en disco. Mantenerlo abierto mientras juegas genera un conflicto de
    sockets IPC con el emulador de Spacewar, provocando el error 0xc0000005
    (violación de acceso de memoria).

7. Despliegue Manual de Librerías y Assets

Para garantizar que el cargador de mods (BaseModLib) funcione de forma autónoma
al iniciar el juego:

1.  Entra a la carpeta: ModAPI\libs\
2.  Selecciona todos los archivos .dll (ej. AsyncBridge.dll, BaseModLib.dll,
    Ionic.Zip.dll, System.Threading.dll, I18N*.dll) y cópialos a:
    TheForest_Data\Managed\
3.  Copia el archivo GUI.assetbundle de ModAPI\libs\ y pégalo en:
    TheForest_Data\

8. Configuración Calibrada de la Mochila (Evitar Crashes)

La Arquitectura del Inventario de The Forest

En el motor Unity de The Forest, los ítems funcionan con dos lógicas distintas:

  - Pilas Virtuales (Tienen número en pantalla): Palos, piedras, flechas,
    medicinas, comida empaquetada. Soportan multiplicadores altos (x4) sin
    problemas.
  - Ítems Físicos de Tapete (NO tienen número en pantalla):
      - Molotovs: El tapete solo tiene coordenadas 3D para renderizar un máximo
        de 9 botellas físicas. Al intentar crear una décima botella, el juego
        colapsa por desbordamiento (IndexOutOfRangeException).
      - Carnes / Pescados frescos: Cada trozo posee un script individual con
        cronómetro de putrefacción (Raw, Cooked, Spoiled). Multiplicar la carne
        congela el sistema de cocción y secadores.

Instrucciones de Configuración

1.  En la raíz del juego, entra a la carpeta Mods\ (si no existe, créala).
2.  Crea o abre con el Bloc de notas el archivo BiggerBackpack.settings.
3.  Pega exactamente el siguiente bloque calibrado:

[Items]
aircanister=16
aloe=40
animalhead_boar=-1
animalhead_crocodile=-1
animalhead_deer=-1
animalhead_goose=-1
animalhead_lizard=-1
animalhead_rabbit=-1
animalhead_racoon=-1
animalhead_seagul=-1
animalhead_shark=-1
animalhead_squirrel=-1
animalhead_tortoise=-1
arm=2
arrows=120
artifactball=1
artifactkey=1
artifactphoto=0
axe climbing=1
axe plane=1
axecrafted=1
axemodern=1
axerusty=1
battery=0
bible=0
biblepage1=0
biblepage2=0
biblepage3=0
blackberry=120
blueberry=120
bluepaint=12
boarskin=40
bombtimed=5
bone=60
bonearmor=40
bookdarkhaired=1
booze=28
bow=1
bowcross=1
camcorder=1
camcordertape1=1
camcordertape2=1
camcordertape3=1
camcordertape4=1
camcordertape5=1
camcordertape6=1
cash=40000
cassette 1=1
cassette 2=1
cassette 3=1
cassette 4=1
cassette 5=1
cavemap=1
cboard=20
chainsaw=1
chainsawad=10
chicory=40
chocolatebar=60
cloth=0
club=1
clubcrafted=1
cod=3
coins=0
compass=1
coneflower=40
creepyhead_armsy=-1
creepyhead_baby=-1
creepyhead_fat=-1
creepyhead_vag=-1
creepyskin=40
cross=1
crossbowammo=10
deerskin=40
dynamite=20
emailphoto=0
emailplane=0
energymix=20
energymixplus=20
feather=0
firestick=1
flare=40
flaregun=1
flaregunammo=0
flintlock=1
flintlock part 1=1
flintlock part 2=1
flintlock part 3=1
flintlock part 4=1
flintlock part 5=1
flintlock part 6=1
flintlock part 7=1
flintlock part 8=1
flintlockammo=0
fortune=1
fuel=20
genericmeat=4
glass=0
hairspray=1
head=1
headbomb=1
katana=1
keycard=1
keycardelevator=1
leaf=40000
leg=2
lighter=1
lizard=3
lizardskin=40
log=-1
machete=1
magazine=0
magazine_reality=10
magazine_science=10
magazinecaver=0
magazinelimestone=0
map_cave2=6
mapfull=1
mappiece_1=1
mappiece_2=1
mappiece_3=1
mappiece_4=1
marigold=40
medicinecrafted=20
medicinecraftedplus=20
meds=20
megancrayons=0
megandrawingdaddy=0
megandrawingdino=0
megandrawingflower=0
megandrawingunicorn=0
metaltintray=1
milkcarton=1
molotov=9
morguereport=0
mushroomamanita=40
mushroomchanterelle=40
mushroomdeermush=40
mushroomjack=40
mushroomlibertycap=40
mushroompuffmush=40
newspaperstripper=0
orangepaint=12
oyster=10
pagechurch=0
pageglider=0
pagerollercoaster=0
pagetower=0
paintbrush=1
passengermanifest=1
pedometer=1
photocache1=0
photocache2=0
photocache3=0
photocache4=0
photocache5=0
photocache6=0
photocache8=0
photocache9=0
phototimmy=1
planefood=1
plastictorch=2
plastictorch_bow=1
plastictorch_chainsaw=1
plastictorch_flintlock=1
plastictorch_modernbow=1
polaroidkeycard1=0
polaroidkeycard2=0
polaroidkeycard3=0
polaroidmegan=0
polaroidteddy=0
polaroidvagz=0
polaroidyacht=0
pot=1
pouch=1
quiver=1
rabbit alive=-1
rabbit dead=3
rabbitfurboots=1
rabbitskin=40
racoonskin=40
rebreather=1
recurvebow=1
repairtool=1
restrainingorder=0
rock=20
rockbag=1
rockupgraded=1
rope=16
seed_aloe=0
seed_blueberry=120
seed_coneflower=0
shippingmanifest=0
sketchartifact=10
sketchartifact4=10
sketchsinkhole=0
sketchvagz=0
skull=16
slingshot=1
small rock=40
smallgenericmeat=3
smallrockbag=1
snowberry=120
snowshoes=1
soda=40
spear=1
spearbag=1
spearupgraded=1
stealtharmor=40
stick=40
stickbag=1
stickupgraded=1
survivalbook=1
tapesticky=0
tennis ball=-1
tennisraquet=1
terminationletter=0
timmydrawing=10
tooth=0
toy_arm=2
toy_head=1
toy_leg=2
toy_torso=1
toyfull=1
treesap=0
turtleshell=1
twinberry=120
walkman=1
walkytalky=1
warmsuit=1
watch=16
waterskin=1

4.  Guarda el archivo.
5.  Copia BiggerBackpack.settings y pégalo también en:
    ModAPI\mods\BiggerBackpack.settings

📌 Nota Matemática sobre las Bolsas: En el código de The Forest, las bolsas suman
un bono plano fijo:

  - Bolsa de palos: suma +10 fijos. Con base 40, tendrás 50 palos con bolsa. (Si
    quieres ver 80 palos exactos con bolsa equipada, cambia la línea a
    stick=70).
  - Bolsa de piedras: suma +5 fijos. Con base 20, tendrás 25 piedras con bolsa.

9. Lanzamiento Final y Multijugador en Steam

A partir de este punto, nunca inicies el juego desde ModAPI.

1.  Abre tu cliente oficial de Steam e inicia sesión con cualquier cuenta.
2.  En la barra de menús de Steam, ve a: Productos \rightarrow Añadir un
    producto que no es de Steam a mi biblioteca...
3.  Haz clic en Buscar..., navega hasta la carpeta del juego y selecciona:
    TheForest.exe
4.  Inicia el juego directamente haciendo clic en Jugar dentro de Steam.
5.  Verás que en tu estado de Steam figurará: "Jugando a Spacewar".
6.  Ya puedes crear o unirte a salas multijugador online con amigos: el mod de
    inventario ampliado y el crack cooperativo funcionarán juntos en perfecta
    sincronía.

10. Solución de Problemas Frecuentes

  - El juego crashea en el menú principal tras iniciar desde ModAPI: Cierra
    ModAPI por completo. Ejecuta siempre el juego a través del acceso directo de
    Steam.
  - Los palos o piedras no suben más allá del valor vainilla: Verifica que el
    archivo Mods\BiggerBackpack.settings exista en la raíz del juego y que
    contenga los valores modificados.
  - Crasheo al craftear Molotovs: Verifica que en BiggerBackpack.settings la
    línea molotov=9 esté en 9 y no en un número mayor.
  - Steam muestra error al unirse a amigos: Asegúrate de que ambos jugadores
    tengan agregada la misma cuenta de Steam como amigos y que ambos vean en su
    perfil que están jugando a Spacewar.
