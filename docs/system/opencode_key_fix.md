# Guía de Solución de Problemas: OpenCode + OpenRouter / Requesty en Linux

Esta guía documenta la resolución del error común `401 Unauthorized: "User not found."` al utilizar proveedores de modelos de lenguaje (como OpenRouter o Requesty) dentro del CLI de **OpenCode** en entornos basados en Debian/Kali Linux.

---

## 1. Descripción del Problema

Al intentar enviar un prompt a un modelo gratuito (por ejemplo, `Gemma` o `LFM3-1.7B (free)`), OpenCode devuelve el siguiente error:

```text
User not found.

Este mensaje corresponde a una respuesta HTTP 401 Unauthorized originada por el
proveedor (generalmente OpenRouter), indicando que la clave de API utilizada no
existe, fue revocada o no tiene los permisos adecuados para inferencia.

2. Causas Raíz Identificadas

1.  Uso de "Management Key" en lugar de "API Key":
    OpenRouter divide sus claves en dos categorías:
      - Management Keys (is_management_key: true): Solo sirven para tareas
        administrativas de la cuenta (aprovisionamiento, facturación). Rebotan
        si se usan para inferencia/chat.
      - Standard API Keys (is_management_key: false): Son las únicas habilitadas
        para llamadas a modelos de IA.
2.  Conflicto de precedencia en variables de entorno:
    OpenCode prioriza las variables de entorno ($OPENROUTER_API_KEY) sobre las
    credenciales guardadas en ~/.local/share/opencode/auth.json. Si en la
    terminal o en el archivo de inicio (~/.bashrc / ~/.zshrc) existe una
    variable con una clave obsoleta, OpenCode ignorará cualquier configuración
    hecha mediante /connect.
3.  Persistencia de sesión en la terminal:
    Modificar un archivo de inicio de sesión (.bashrc / .zshrc) no actualiza las
    terminales que ya están abiertas, manteniendo en memoria la clave anterior.
4.  Límite diario de modelos gratuitos (Free Tier):
    Las cuentas de OpenRouter poseen un límite diario (generalmente 50
    solicitudes al día para modelos :free). Al agotarse, cualquier petición a un
    modelo :free de OpenRouter será rechazada.

3. Diagnóstico Paso a Paso

A. Listar credenciales cargadas en OpenCode

opencode auth list

Permite comprobar si las credenciales provienen de variables de entorno
(Environment) o del archivo de configuración (Credentials).

B. Validar la API Key de OpenRouter

Ejecuta la siguiente petición para verificar el estado de la clave:

curl -s https://openrouter.ai/api/v1/auth/key \
  -H "Authorization: Bearer <TU_API_KEY>"

Qué revisar en la respuesta JSON:

  - "is_management_key": false \rightarrow Clave correcta para inferencia.
  - "free_model_daily_requests": {"used": X, "limit": 50, "remaining": Y}
    \rightarrow Muestra el consumo de peticiones gratuitas restantes para el
    día.

C. Validar la API Key de Requesty

curl -s https://router.requesty.ai/v1/models \
  -H "Authorization: Bearer <TU_REQUESTY_KEY>" | head -n 15

4. Solución

Paso 1: Generar la clave adecuada en OpenRouter

1.  Acceder a OpenRouter API Keys (asegurarse de no estar en la sección
    Management keys).
2.  Hacer clic en Create Key.
3.  En Credit limit, seleccionar Unlimited o definir un cupo.
4.  Copiar la clave generada (sk-or-v1-...).

Paso 2: Actualizar el entorno del sistema

Identifica el shell en uso:

echo $SHELL

  - Si usas Bash (/bin/bash): Editar ~/.bashrc
  - Si usas ZSH (/bin/zsh en Kali Linux): Editar ~/.zshrc

Agregar o actualizar la línea:

export OPENROUTER_API_KEY="sk-or-v1-tu-clave-aqui"

Aplicar los cambios a la terminal activa:

source ~/.bashrc   # o source ~/.zshrc

Paso 3: Actualizar la autenticación dentro de OpenCode

Inicia OpenCode:

opencode

1.  Escribe /connect y presiona Enter.
2.  Selecciona OpenRouter.
3.  Pega la clave estándar recién generada.

Paso 4: Alternar proveedores si se agota la cuota diaria

Si OpenRouter agotó las 50 solicitudes gratuitas diarias (remaining: 0):

1.  Dentro de OpenCode, escribe /models.
2.  Selecciona un modelo provisto por Requesty o por OpenCode Zen.
3.  La cuota de OpenRouter se reiniciará automáticamente a las 00:00 UTC.

Estructura de Archivos Afectados

~/.bashrc                            # Variables de entorno para Bash
~/.zshrc                             # Variables de entorno para ZSH
~/.local/share/opencode/auth.json     # Almacenamiento local de credenciales de OpenCode


---

### Cómo crearlo directamente en tu terminal:

Puedes generar el archivo directamente ejecutando este comando en la carpeta de tu repositorio:

```bash
cat << 'EOF' > README.md
# Guía de Solución de Problemas: OpenCode + OpenRouter / Requesty en Linux

Esta guía documenta la resolución del error común `401 Unauthorized: "User not found."` al utilizar proveedores de modelos de lenguaje (como OpenRouter o Requesty) dentro del CLI de **OpenCode** en entornos basados en Debian/Kali Linux.

---

## 1. Descripción del Problema

Al intentar enviar un prompt a un modelo gratuito (por ejemplo, `Gemma` o `LFM3-1.7B (free)`), OpenCode devuelve el siguiente error:

```text
User not found.

Este mensaje corresponde a una respuesta HTTP 401 Unauthorized originada por el
proveedor (generalmente OpenRouter), indicando que la clave de API utilizada no
existe, fue revocada o no tiene los permisos adecuados para inferencia.

2. Causas Raíz Identificadas

1.  Uso de "Management Key" en lugar de "API Key":
    OpenRouter divide sus claves en dos categorías:
      - Management Keys (is_management_key: true): Solo sirven para tareas
        administrativas de la cuenta (aprovisionamiento, facturación). Rebotan
        si se usan para inferencia/chat.
      - Standard API Keys (is_management_key: false): Son las únicas habilitadas
        para llamadas a modelos de IA.
2.  Conflicto de precedencia en variables de entorno:
    OpenCode prioriza las variables de entorno ($OPENROUTER_API_KEY) sobre las
    credenciales guardadas en ~/.local/share/opencode/auth.json. Si en la
    terminal o en el archivo de inicio (~/.bashrc / ~/.zshrc) existe una
    variable con una clave obsoleta, OpenCode ignorará cualquier configuración
    hecha mediante /connect.
3.  Persistencia de sesión en la terminal:
    Modificar un archivo de inicio de sesión (.bashrc / .zshrc) no actualiza las
    terminales que ya están abiertas, manteniendo en memoria la clave anterior.
4.  Límite diario de modelos gratuitos (Free Tier):
    Las cuentas de OpenRouter poseen un límite diario (generalmente 50
    solicitudes al día para modelos :free). Al agotarse, cualquier petición a un
    modelo :free de OpenRouter será rechazada.

3. Diagnóstico Paso a Paso

A. Listar credenciales cargadas en OpenCode

opencode auth list

Permite comprobar si las credenciales provienen de variables de entorno
(Environment) o del archivo de configuración (Credentials).

B. Validar la API Key de OpenRouter

Ejecuta la siguiente petición para verificar el estado de la clave:

curl -s https://openrouter.ai/api/v1/auth/key \
  -H "Authorization: Bearer <TU_API_KEY>"

Qué revisar en la respuesta JSON:

  - "is_management_key": false \rightarrow Clave correcta para inferencia.
  - "free_model_daily_requests": {"used": X, "limit": 50, "remaining": Y}
    \rightarrow Muestra el consumo de peticiones gratuitas restantes para el
    día.

C. Validar la API Key de Requesty

curl -s https://router.requesty.ai/v1/models \
  -H "Authorization: Bearer <TU_REQUESTY_KEY>" | head -n 15

4. Solución

Paso 1: Generar la clave adecuada en OpenRouter

1.  Acceder a OpenRouter API Keys (asegurarse de no estar en la sección
    Management keys).
2.  Hacer clic en Create Key.
3.  En Credit limit, seleccionar Unlimited o definir un cupo.
4.  Copiar la clave generada (sk-or-v1-...).

Paso 2: Actualizar el entorno del sistema

Identifica el shell en uso:

echo $SHELL

  - Si usas Bash (/bin/bash): Editar ~/.bashrc
  - Si usas ZSH (/bin/zsh en Kali Linux): Editar ~/.zshrc

Agregar o actualizar la línea:

export OPENROUTER_API_KEY="sk-or-v1-tu-clave-aqui"

Aplicar los cambios a la terminal activa:

source ~/.bashrc   # o source ~/.zshrc

Paso 3: Actualizar la autenticación dentro de OpenCode

Inicia OpenCode:

opencode

1.  Escribe /connect y presiona Enter.
2.  Selecciona OpenRouter.
3.  Pega la clave estándar recién generada.

Paso 4: Alternar proveedores si se agota la cuota diaria

Si OpenRouter agotó las 50 solicitudes gratuitas diarias (remaining: 0):

1.  Dentro de OpenCode, escribe /models.
2.  Selecciona un modelo provisto por Requesty o por OpenCode Zen.
3.  La cuota de OpenRouter se reiniciará automáticamente a las 00:00 UTC.

Estructura de Archivos Afectados

~/.bashrc                            # Variables de entorno para Bash
~/.zshrc                             # Variables de entorno para ZSH
~/.local/share/opencode/auth.json     # Almacenamiento local de credenciales de OpenCode
