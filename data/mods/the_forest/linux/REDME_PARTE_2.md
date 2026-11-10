# Guía: Cómo Agregar Nuevos Mods en The Forest (Linux / Proton)
### Método Optimizado con Accesos Directos Separados en Steam

Esta guía complementa la documentación inicial explicando el flujo de trabajo rápido y definitivo para instalar y acumular nuevos mods (como *Easy Building*, mods de balance, etc.) en **The Forest (v1.12)** bajo **Linux (Proton)** sin alterar la configuración del acceso directo principal del juego.

---

## 1. Concepto Fundamental de ModAPI

- ModAPI descarga los mods individuales en formato `.mod`.
- ModAPI almacena una copia limpia del juego original en su caché interna (`ModAPI/gamefiles/original/`).
- Cada vez que se presiona **"Start Game"**, ModAPI toma esa base limpia y compila un nuevo `Assembly-CSharp.dll` inyectando **todos los mods que tengan su casilla marcada activada**.
- **Regla:** Para no perder mods anteriores (ej. *Bigger Backpack*), mantén marcadas las casillas de todos los mods que quieras activos en tu partida.

---

## 2. Configuración de Accesos Directos en Steam (Dual Launcher)

Para no tener que cambiar la ruta de destino cada vez que quieras añadir o quitar un mod, crea dos accesos directos de "Juego que no es de Steam":

1. **Acceso Directo 1 (Para Jugar):**
   - **Nombre:** `The Forest`
   - **Destino:** `"$HOME/Games/the_forest/The-Forest-SteamRIP/The Forest v.1.12/TheForest.exe"`
   - **Iniciar en:** `"$HOME/Games/the_forest/The-Forest-SteamRIP/The Forest v.1.12/"`
   - **Compatibilidad:** Proton Experimental / Proton-GE.

2. **Acceso Directo 2 (Herramienta ModAPI):**
   - **Nombre:** `The Forest - ModAPI Launcher`
   - **Destino:** `"$HOME/Games/the_forest/The-Forest-SteamRIP/The Forest v.1.12/ModAPI/ModAPI.exe"`
   - **Iniciar en:** `"$HOME/Games/the_forest/The-Forest-SteamRIP/The Forest v.1.12/ModAPI/"`
   - **Compatibilidad:** Proton Experimental / Proton-GE.

---

## 3. Flujo de Trabajo para Añadir un Nuevo Mod

### Paso 1: Descargar el archivo `.mod`
1. Entra al catálogo oficial de mods:
   👉 **[https://modapi.survivetheforest.net/game/TheForest/](https://modapi.survivetheforest.net/game/TheForest/)**
2. Entra a la ficha del mod que desees (ejemplo: *Easy Building*).
3. En la columna lateral derecha, haz clic en el ícono de descarga de la versión más reciente compatible (se descargará un archivo con extensión `.mod`).

### Paso 2: Colocar el mod en el directorio de ModAPI
Mueve el archivo descargado a la carpeta de mods de *The Forest*:

# Ejemplo:
mv ~/Descargas/*.mod "$HOME/Games/the_forest/The-Forest-SteamRIP/The Forest v.1.12/ModAPI/mods/TheForest/"

Paso 3: Inyectar con ModAPI desde Steam

1.  Abre tu cliente de Steam.
2.  Inicia el acceso directo: The Forest - ModAPI Launcher.
3.  En la lista de mods disponibles, activa las casillas de todos los mods que
    desees:
      - ☑ Bigger Backpack
      - ☑ Easy Building (o el nuevo mod añadido)
4.  Haz clic en Start Game.
5.  ModAPI parchará Assembly-CSharp.dll en disco. En cuanto el juego intente
    arrancar (o si se cuelga en pantalla negra por el conflicto IPC de Proton):
    killall -9 TheForest.exe ModAPI.exe

Paso 4: Asegurar librerías nuevas (si aplica)

Algunos mods generan una librería .dll adicional (por ejemplo EasyBuilding.dll).
Verifica y copia cualquier librería generada al directorio administrado del
juego:

cd "$HOME/Games/the_forest/The-Forest-SteamRIP/The Forest v.1.12"
cp -n ModAPI/gamefiles/modded/TheForest/TheForest_data/Managed/*.dll TheForest_Data/Managed/ 2>/dev/null

Paso 5: Jugar

Inicia tu acceso directo principal de The Forest en Steam. Todos los mods
inyectados estarán operativos en multijugador online.

4. Notas de Configuración de Nuevos Mods

  - Si el nuevo mod incluye parámetros configurables (como límites o atajos de
    teclado), generará automáticamente su archivo .settings o .xml dentro de la
    carpeta Mods/ al cargar la partida por primera vez.
  - Mods de planos o balance como Easy Building dividen entre 2 los requisitos
    de madera/piedras de las construcciones y son 100% compatibles con el crack
    online.


---

### Archivo 2: `README_PARTE_2_WINDOWS.md`

```markdown
# Guía: Cómo Agregar Nuevos Mods en The Forest (Windows 11)
### Método para Acumular Mods mediante ModAPI

Esta guía explica el procedimiento para descargar, instalar y gestionar múltiples mods simultáneamente (ejemplo: *Easy Building*, mods de balance, mejoras visuales) en la versión final de **The Forest (v1.12)** bajo **Windows 11**, manteniendo el crack multijugador activo.

---

## 1. Regla de Acumulación de ModAPI

- Cada mod descargado de la web oficial tiene extensión **`.mod`**.
- ModAPI no borra tus mods anteriores siempre y cuando **mantengas marcadas sus casillas** al presionar **Start Game**.
- ModAPI toma la copia original y vuelve a compilar `Assembly-CSharp.dll` con todos los mods que tengan el visto bueno (☑).

---

## 2. Paso a Paso para Añadir un Nuevo Mod

### Paso 1: Descargar el mod
1. Entra a la web oficial de mods de The Forest:
   👉 **[https://modapi.survivetheforest.net/game/TheForest/](https://modapi.survivetheforest.net/game/TheForest/)**
2. Selecciona el mod que quieras añadir (por ejemplo: *Easy Building*).
3. En la esquina superior derecha de la página del mod, pulsa el botón de descarga junto a la versión más reciente (ej. *Version 1.0.1*).
4. Obtendrás un archivo `.mod` (ejemplo: `EasyBuilding-1.0.1.mod`).

### Paso 2: Ubicar el archivo `.mod`
Copia el archivo descargado y pégalo en la subcarpeta de mods de ModAPI:
```text
<Carpeta del Juego>\ModAPI\mods\TheForest\

Paso 3: Parchear con ModAPI

1.  Ejecuta directamente ModAPI.exe (ubicado en <Carpeta del Juego>\ModAPI\).
2.  En la lista de mods, asegúrate de activar:
      - ☑ Bigger Backpack
      - ☑ Easy Building (y cualquier otro mod que tengas)
3.  Haz clic en el botón inferior Start Game.
4.  ModAPI inyectará todos los mods seleccionados dentro de
    TheForest_Data\Managed\Assembly-CSharp.dll.
5.  En cuanto el juego comience a cargar, ciérralo.
6.  Cierra ModAPI.exe (no debe dejarse abierto en segundo plano mientras
    juegas).

Paso 4: Despliegue de librerías secundarias

Si el nuevo mod requiere una librería compilada propia (por ejemplo
EasyBuilding.dll):

1.  Revisa la carpeta: <Carpeta del
    Juego>\ModAPI\gamefiles\modded\TheForest\TheForest_data\Managed\
2.  Si aparece un nuevo .dll perteneciente al mod, cópialo a: <Carpeta del
    Juego>\TheForest_Data\Managed\

Paso 5: Iniciar el juego

1.  Abre tu cliente oficial de Steam.
2.  Dale a Jugar en el acceso directo de TheForest.exe que agregaste previamente
    como juego que no es de Steam.
3.  El estado de Steam mostrará Jugando a Spacewar y todos los mods estarán
    activos en cooperativo.

Configuración y Ajustes de los Nuevos Mods

Los mods que cuentan con opciones configurables crearán automáticamente un archivo con extensión .settings o .xml dentro de la carpeta:
<Carpeta del Juego>\Mods\
