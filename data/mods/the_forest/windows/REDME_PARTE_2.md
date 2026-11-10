# Guía Parte 2: Cómo Agregar Nuevos Mods en The Forest (Windows 11)
### Método para Acumular Mods mediante ModAPI (Online Spacewar / 32-bit)

Esta guía explica paso a paso cómo descargar, instalar y acumular múltiples mods (como *Easy Building*, mods de balance, mejoras de construcción, etc.) en **The Forest (v1.12)** bajo **Windows 11**, manteniendo el crack multijugador online cooperativo y el mod *Bigger Backpack* funcionando simultáneamente.

---

## 1. Regla de Oro de ModAPI

- Los mods individuales para *The Forest* se descargan en formato con extensión **`.mod`**.
- ModAPI guarda una copia limpia y original de los archivos del juego en su caché interna (`ModAPI\gamefiles\original\`).
- Cada vez que pulsas el botón **"Start Game"**, ModAPI toma esa base limpia y compila un nuevo archivo `TheForest_Data\Managed\Assembly-CSharp.dll` inyectando **todos los mods que tengan su casilla marcada (☑)**.
- **Importante:** Para no perder mods anteriores (como *Bigger Backpack*), debes mantener marcadas las casillas de todos los mods que quieras tener activos al mismo tiempo.

---

## 2. Flujo de Trabajo para Añadir un Nuevo Mod

### Paso 1: Descargar el archivo `.mod`
1. Entra al catálogo oficial de mods de *The Forest*:
   👉 **[https://modapi.survivetheforest.net/game/TheForest/](https://modapi.survivetheforest.net/game/TheForest/)**
2. Entra a la ficha del mod que quieras instalar (ejemplo: *Easy Building*).
3. En la columna lateral derecha, haz clic en el ícono de descarga (flecha hacia abajo) de la versión más reciente compatible.
4. Se descargará un archivo con extensión `.mod` (ejemplo: `EasyBuilding-1.0.1.mod`).

---

### Paso 2: Colocar el mod en la carpeta correcta
Copia el archivo `.mod` descargado y pégalo en la subcarpeta de mods de ModAPI dentro del directorio de instalación del juego:
```text
<Carpeta del Juego>\ModAPI\mods\TheForest\

(Si tienes el juego en tu carpeta de usuario, la ruta relativa sería por
ejemplo: %USERPROFILE%\Games\The Forest v.1.12\ModAPI\mods\TheForest\).

Paso 3: Inyectar los mods con ModAPI

1.  Ejecuta ModAPI.exe (ubicado en <Carpeta del Juego>\ModAPI\).
    Nota opcional: Si prefieres la comodidad de iniciarlo desde Steam como en
    Linux, también puedes agregar ModAPI.exe como "Juego que no es de Steam" en
    tu biblioteca de Steam.
2.  En la lista principal de mods, activa las casillas de todos los mods que
    quieras usar juntos:
      - ☑ Bigger Backpack
      - ☑ Easy Building (o el nuevo mod añadido)
3.  Haz clic en el botón inferior Start Game (Iniciar Juego).
4.  ModAPI procesará el nuevo ensamblado e inyectará ambos mods a la vez en el
    disco.
5.  En cuanto el juego intente abrirse (o muestre la pantalla de carga),
    ciérralo de inmediato.
6.  Cierra ModAPI.exe por completo. (Recuerda: ModAPI solo se usa para parchar;
    no debe quedarse abierto en segundo plano mientras juegas para evitar
    conflictos con Steam).

Paso 4: Despliegue de librerías secundarias (si el mod lo requiere)

Muchos mods funcionan directamente dentro del archivo inyectado, pero algunos
incluyen una librería .dll complementaria (por ejemplo EasyBuilding.dll):

1.  Revisa la carpeta:
    <Carpeta del Juego>\ModAPI\gamefiles\modded\TheForest\TheForest_data\Managed\
2.  Si ves algún archivo .dll nuevo perteneciente al mod que acabas de instalar,
    cópialo a:
    <Carpeta del Juego>\TheForest_Data\Managed\

Paso 5: Iniciar el juego en Steam (Multijugador Cooperativo)

1.  Abre tu cliente oficial de Steam con tu cuenta iniciada.
2.  Ve a tu biblioteca de juegos y localiza el acceso directo de The Forest (que
    apunta a TheForest.exe).
3.  Haz clic en Jugar.
4.  Tu estado de Steam indicará "Jugando a Spacewar".
5.  Entra a tu partida: todos los mods inyectados estarán funcionando de forma
    simultánea en multijugador online.

3. Configuración de Nuevos Mods

  - Si el nuevo mod incluye opciones configurables (atajos de teclado, valores
    numéricos, etc.), generará automáticamente su archivo .settings o .xml
    dentro de la carpeta:
    <Carpeta del Juego>\Mods\
  - Mods de construcción como Easy Building: No requieren configuración manual;
    reducen automáticamente a la mitad la madera y recursos necesarios de todas
    las construcciones de tu libro de supervivencia.
