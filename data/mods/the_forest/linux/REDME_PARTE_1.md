# Guía Técnica: ModAPI & Bigger Backpack en The Forest (Linux / Proton)

Documentación técnica y cronológica para instalar y ejecutar **ModAPI** y el mod **Bigger Backpack (v1.0)** en **The Forest (v1.12)** bajo **Linux (Nobara / Steam Proton)**, manteniendo la compatibilidad con el crack multijugador online (Steamworks Emulator / Spacewar AppID 480).

---

## 1. Entorno del Sistema y Contexto

- **Sistema Operativo:** Linux (Nobara / Fedora base).
- **Capa de compatibilidad:** Steam con Proton (Proton-GE / Proton Experimental) agregando el ejecutable como *"Juego que no es de Steam"*.
- **Juego:** *The Forest* (v1.12 final, Unity 5.6.5p4).
- **Ruta de instalación base:** `$HOME/Games/the_forest/The-Forest-SteamRIP/The Forest v.1.12`
- **Emulador Multijugador:** Crack online basado en CreamAPI / UberPsyX / Redirector / CSteamworks (AppID 480).
  - *Condición crítica:* El crack multijugador opera exclusivamente sobre los binarios de 32 bits (`TheForest32.exe` y `TheForest32_Data`).
- **Objetivo:** Inyectar y calibrar el mod *Bigger Backpack* con un factor multiplicador base de x4 para objetos acumulables, sin romper el juego online ni la interfaz física del inventario.

---

## 2. Cronología de Problemas Técnicos y Soluciones

### A. Conflicto de Arquitectura: ModAPI (64-bit) vs. Crack Online (32-bit)
- **Problema:** ModAPI busca de forma estricta `TheForest.exe` y la carpeta `TheForest_Data` (64 bits). Sin embargo, el multijugador sólo funciona con los binarios de 32 bits (`TheForest32.exe`).
- **Solución (El truco de vinculación de Unity):** Unity asocia automáticamente el ejecutable principal con la carpeta `<NombreExe>_Data`. Se respaldaron los archivos de 64 bits y se renombraron los de 32 bits para que ModAPI los procese:
  ```bash
  # Respaldar originales de 64 bits
  mv "TheForest.exe" "TheForest_original64.exe"
  mv "TheForest_Data" "TheForest_Data_original64"

  # Convertir los binarios de 32 bits en los principales
  mv "TheForest32.exe" "TheForest.exe"
  mv "TheForest32_Data" "TheForest_Data"

B. Validación de Steam en ModAPI (NoProjectWarning)

  - Problema: ModAPI exige validar la presencia de un binario Steam.exe con
    cabeceras PE válidas de Windows y un tamaño superior a 1 MB. En Linux, Steam
    corre nativamente en el host y no existe un Steam.exe dentro del prefijo de
    Wine/Proton.
  - Solución: Se duplicó el ejecutable respaldado TheForest_original64.exe (22
    MB) renombrándolo como Steam.exe en la raíz del juego y se enlazó en la
    pestaña Ajustes de ModAPI (manteniendo desactivada la casilla "Conexión con
    Steam"):
    cp "TheForest_original64.exe" "Steam.exe"

C. Error UberPsyX.ini not found al lanzar procesos hijos

  - Problema: Al intentar ejecutar el juego desde ModAPI, el subproceso adoptaba
    como directorio de trabajo ./ModAPI/. El emulador multijugador
    (Redirector.dll / CreamAPI.dll) no encontraba sus ficheros de configuración
    en la ruta local.
  - Solución: Se duplicaron los archivos del crack a la subcarpeta de ModAPI y
    al directorio de plugins:
    cp UberPsyX.ini cream_api.ini steam_appid.txt CreamAPI.dll Redirector.dll ModAPI/
    cp UberPsyX.ini cream_api.ini steam_appid.txt TheForest_Data/Plugins/

D. Cierre inesperado en Menú Principal (Conflicto IPC en Proton)

  - Problema: Si el juego es lanzado como un proceso secundario desde ModAPI
    dentro de Wine/Proton, el socket IPC virtual de Steam colapsa al llamar a
    SteamAPI_Init(), arrojando un error de puntero nulo 0xc0000005.
  - Solución: ModAPI utiliza Mono.Cecil para decompilar e inyectar
    permanentemente el código en disco dentro de
    TheForest_Data/Managed/Assembly-CSharp.dll. No requiere estar abierto en
    segundo plano. Una vez parcheado:
    1.  Se copiaron las dependencias auxiliares de ModAPI al directorio
        administrado:
        cp -n ModAPI/libs/*.dll TheForest_Data/Managed/
        cp ModAPI/libs/GUI.assetbundle TheForest_Data/
    2.  Se configuró Steam para lanzar directamente TheForest.exe sin
        intermediarios.

E. Arquitectura del Inventario: Crash con Molotovs y Comida

  - Problema: Al aplicar un multiplicador masivo (x4) a todos los elementos, el
    juego colapsaba y congelaba el sistema operativo al fabricar un Molotov o
    manipular carne.
  - Causa Raíz: En Unity 5, los objetos del inventario de The Forest se dividen
    en dos categorías:
    1.  Objetos de Pila Virtual (Tienen contador numérico en pantalla): Palos,
        piedras, flechas, medicinas, munición, etc. Solo modifican una variable
        entera de texto. Toleran multiplicadores sin problemas.
    2.  Objetos Físicos de Tapete (NO tienen contador numérico):
          - Molotovs y bombas: El tapete posee coordenadas fijas
            pre-renderizadas para un máximo estricto de 9 botellas físicas. Al
            intentar instanciar la botella #10 en un índice inexistente, Unity
            genera un desbordamiento de memoria (IndexOutOfRangeException).
          - Carnes / Pescados: Cada trozo posee un script independiente con
            cronómetro de putrefacción (Fresh, Cooked, Spoiled), incompatible
            con la expansión de pilas.
  - Regla de Solución: Los objetos sin indicador numérico visual en el
    inventario deben conservarse estrictamente en sus valores originales /
    vanilla.

F. Calibración del Bono Fijo de las Bolsas (Sticks & Rocks)

  - Comportamiento interno: En el código de The Forest, las bolsas de mejora no
    multiplican la capacidad, sino que suman un valor fijo sobre la base
    (_maxAmount):
      - Bolsa de palos (Stick Bag): Suma exactamente +10.
      - Bolsa de rocas (Rock Bag): Suma exactamente +5.
  - Resultado:
      - Multiplicando la base original por 4 (stick=40), un jugador sin bolsa
        almacena 40 palos, y con la bolsa equipada almacena 50 palos (40 + 10).

3. Estructura de Archivos Resultante

The Forest v.1.12/
├── Mods/
│   ├── BiggerBackpack.settings       # Configuración calibrada de límites de inventario
│   ├── GUI.assetbundle               # Interfaz del cargador de mods
│   └── Logs/
│       └── Core.log                  # Registro de inicialización de BaseModLib
├── TheForest_Data/
│   ├── Managed/
│   │   ├── Assembly-CSharp.dll       # Ensamblado principal parcheado con Mono.Cecil
│   │   ├── BaseModLib.dll            # Biblioteca base del cargador de mods
│   │   └── BiggerBackpack.dll        # Lógica del mod Bigger Backpack
│   └── Plugins/                      # DLLs del crack multijugador online (32-bit)
├── TheForest.exe                     # Binario ejecutable de 32 bits (renombrado)
└── Steam.exe                         # PE de validación estática para ModAPI

4. Recuperación en Linux ante bloqueos de Proton

Si un juego de Proton se congela e inhabilita el entorno gráfico, no es
necesario reiniciar físicamente el equipo:

1.  Acceder a un TTY secundario mediante: Ctrl + Alt + F3
2.  Iniciar sesión y terminar el proceso forzosamente:
    killall -9 TheForest.exe ModAPI.exe
3.  Regresar a la sesión de escritorio: Ctrl + Alt + F2 (o F1).
