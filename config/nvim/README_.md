# Configuración mínima de Neovim (`init.vim`)

Una configuración personal mínima de Neovim escrita en **Vimscript** (un solo archivo `init.vim`). Sin gestor de plugins ni carpetas adicionales: una base limpia sobre la que se puede crecer.

- **Ruta:** `~/.config/nvim/init.vim`
- **Estilo:** Vimscript, archivo único, sin plugins

---

## Tabla de contenidos

1. [Estructura](#estructura)
2. [Teclas leader](#teclas-leader)
3. [Opciones generales](#opciones-generales)
4. [Portapapeles del sistema](#portapapeles-del-sistema)
5. [Atajos](#atajos)
6. [Notas](#notas)

---

## Estructura

```
~/.config/nvim/
└── init.vim
```

No hay carpetas `lua/`, `plugin/`, `autoload/` ni `colors/`. Todo se carga desde el único `init.vim`.

---

## Teclas leader

```vim
let mapleader = " "
let maplocalleader = " "
```

Se usa **espacio** como `<leader>` y `<localleader>`. Se define **antes** de cualquier mapeo para que se expanda correctamente al cargar el archivo.

---

## Opciones generales

### Interfaz

| Opción | Valor | Motivo |
|---|---|---|
| `number` | activo | Muestra el número de línea absoluto. |
| `relativenumber` | activo | Muestra el conteo relativo a la línea del cursor. |
| `cursorline` | activo | Resalta la línea actual. |
| `signcolumn` | `yes` | Reserva siempre la columna lateral para iconos (diagnósticos LSP, signos de git, etc., cuando se agreguen plugins). |
| `termguicolors` | activo | Activa color de 24 bits en terminales compatibles. |
| `mouse` | `a` | Habilita el ratón en todos los modos. |
| `confirm` | activo | Pide confirmación antes de descartar cambios sin guardar. |

### Indentación

| Opción | Valor | Motivo |
|---|---|---|
| `expandtab` | activo | Las tabulaciones se convierten en espacios. |
| `tabstop` | `2` | Ancho visual del tabulador. |
| `shiftwidth` | `2` | Espacios para `>>`, `<<`, `==` y autoindent. |
| `softtabstop` | `2` | El retroceso elimina 2 espacios. |
| `smartindent` | activo | Autoindent inteligente al pulsar Enter. |

Resultado: sangrado de 2 espacios, sin tabuladores reales.

### Búsqueda

| Opción | Valor | Motivo |
|---|---|---|
| `hlsearch` | activo | Resalta todas las coincidencias. |
| `incsearch` | activo | Busca mientras se escribe el patrón. |
| `ignorecase` | activo | Búsqueda insensible a mayúsculas por defecto. |
| `smartcase` | activo | Sensible a mayúsculas si el patrón incluye alguna. |

### Comportamiento del editor

| Opción | Valor | Motivo |
|---|---|---|
| `scrolloff` | `8` | Mantiene 8 líneas de contexto arriba y abajo. |
| `sidescrolloff` | `8` | Mantiene 8 columnas de contexto a los lados. |
| `updatetime` | `250` | Retardo (ms) del evento `CursorHold`. |
| `timeoutlen` | `400` | Tiempo (ms) entre teclas de una secuencia de mapeo. |
| `wrap` | activo | Ajuste visual de línea. |
| `linebreak` | activo | Ajusta por palabras, no por columnas. |
| `splitright` | activo | `:vsplit` abre a la derecha. |
| `splitbelow` | activo | `:split` abre abajo. |

### Archivos y respaldos

| Opción | Valor | Motivo |
|---|---|---|
| `nobackup` | activo | No crea archivos `archivo~`. |
| `nowritebackup` | activo | No crea `archivo.bak` al guardar. |
| `noswapfile` | activo | Sin archivos `.swp`. |
| `undofile` | activo | Historial de deshacer persistente. |

Resultado: directorio de trabajo limpio, pero con `u` / `Ctrl-R` persistentes entre sesiones.

---

## Portapapeles del sistema

`set clipboard=unnamedplus` por sí solo **no es suficiente en Wayland**: solo afecta al pegar dentro de Neovim, no a copiar desde él.

Para que `y`, `d`, `x` y `c` escriban realmente en el portapapeles de Wayland, los siguientes mapeos vuelcan el registro sin nombre en `wl-copy`:

```vim
vnoremap <silent> y y<bar>:call system('wl-copy --primary', getreg('"'))<cr>
vnoremap <silent> d d<bar>:call system('wl-copy --primary', getreg('"'))<cr>
vnoremap <silent> x x<bar>:call system('wl-copy --primary', getreg('"'))<cr>
vnoremap <silent> c c<bar>:call system('wl-copy --primary', getreg('"'))<cr>
```

- `vnoremap` evita que el mapeo sea recursivo.
- `<silent>` oculta el comando en la línea de estado.
- `--primary` apunta al búfer de selección estilo X11 (clic medio). Quítalo para usar el portapapeles principal de `Ctrl-C` / `Ctrl-V`.

> Requiere `wl-clipboard` (proporciona `wl-copy`). En distribuciones basadas en Fedora suele venir preinstalado o disponible en los repositorios.

Si necesitas un fallback para X11, reemplaza la llamada a `system(...)` por una función que detecte el tipo de sesión.

---

## Atajos

Todos comienzan con **`<leader>` = Espacio**.

### Guardar y cerrar

| Atajo | Acción |
|---|---|
| `<leader>w` | `:w` — guardar archivo. |
| `<leader>q` | `:q` — cerrar ventana/buffer. |
| `<leader>Q` | `:qa` — cerrar Neovim. |
| `<leader>x` | `:bdelete` — cerrar buffer, mantener ventana. |

### Navegación entre buffers

| Atajo | Acción |
|---|---|
| `<S-h>` | `:bprevious` — buffer anterior. |
| `<S-l>` | `:bnext` — buffer siguiente. |

### Navegación entre ventanas

| Atajo | Acción |
|---|---|
| `<C-h>` | Ir a la ventana de la izquierda. |
| `<C-j>` | Ir a la ventana de abajo. |
| `<C-k>` | Ir a la ventana de arriba. |
| `<C-l>` | Ir a la ventana de la derecha. |

---

## Notas

- Inicialmente partí de una configuración modular en `init.lua` (`lua/config/`, `lua/plugins/`), pero era excesiva para una base. La elección final es un único `init.vim`.
- El portapapeles fue el principal bloqueo: por defecto, Neovim en Wayland no comparte el portapapeles del sistema con otras aplicaciones. La combinación de `unnamedplus` + `wl-copy` lo soluciona.
- Planes a futuro: agregar un gestor de plugins (probablemente `lazy.nvim`) cuando se necesiten LSP, Treesitter, Telescope y un tema de colores.
