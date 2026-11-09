Acá va el resumen corregido y con datos genéricos:

---

## 🚀 Resumen: Git + GitHub desde cero (con token classic)

### 1. Identidad en Git (una sola vez por máquina)

```bash
git config --global user.name "TU_NOMBRE_DE_COMMIT"
git config --global user.email "tu_email@ejemplo.com"
```

> ⚠️ **Aclaración:** `user.name` es el nombre que aparece en el historial de commits (`git log`). Puede ser cualquier nombre (ej. `linus_842`). **NO** tiene que ser tu usuario de GitHub.
> Tu usuario de GitHub (el que usás para loguearte y para la URL del repo) es otro dato distinto.

Verificá:
```bash
git config --global --list
```

---

### 2. Iniciar repo local

```bash
cd ~/ruta/de/tu/proyecto
git init
git add .
git commit -m "first commit"
git branch -M main
```

---

### 3. Crear repo vacío en GitHub

Andá a [github.com/new](https://github.com/new), poné un nombre, dejalo **vacío** (sin README ni .gitignore) y crealo.

---

### 4. Conectar local con remoto

```bash
git remote add origin https://github.com/TU_USUARIO_GITHUB/NOMBRE_REPO.git
git remote -v
```

> `TU_USUARIO_GITHUB` = el nombre de tu cuenta (el que va en la URL de tu perfil), **no** el `user.name` de Git.

---

### 5. Crear Personal Access Token (classic)

1. Foto de perfil (arriba a la derecha) → **Settings**
2. Menú de la izquierda → scrolleá hasta abajo del todo → **Developer settings**
3. Menú de la izquierda → **Personal access tokens**
4. Click en **Tokens (classic)**
5. **Generate new token (classic)**
6. **Note:** poné un nombre para reconocerlo (ej. `mi_pc`)
7. **Expiration:** elegí una fecha (ej. 30 días)
8. **Scopes:** marcá solo ✅ `public_repo` (dentro del grupo `repo`)
9. Click en **Generate token**
10. **Copiá el token inmediatamente** (empieza con `ghp_...`) — GitHub solo lo muestra una vez

> 🔒 Tratalo como una contraseña. No lo compartas ni lo subas a ningún repo.

---

### 6. Primer push

```bash
git push -u origin main
```

Cuando pida credenciales:
- **Username:** tu usuario real de GitHub (`TU_USUARIO_GITHUB`)
- **Password:** el token que copiaste (`ghp_...`)

> Al pegar el token no se ve nada en pantalla — es normal.

---

### 7. Flujo de trabajo diario

```bash
git add .
git commit -m "descripción del cambio"
git push
```

Si elegiste **no guardar el token**, te va a pedir usuario y token en cada `push`.

---

### 📋 Todo junto (copiar y pegar)

```bash
# 1. Identidad (una sola vez)
git config --global user.name "TU_NOMBRE_DE_COMMIT"
git config --global user.email "tu_email@ejemplo.com"

# 2. Iniciar repo
cd ~/ruta/de/tu/proyecto
git init
git add .
git commit -m "first commit"
git branch -M main

# 3. Conectar con GitHub (repo ya creado en github.com/new)
git remote add origin https://github.com/TU_USUARIO_GITHUB/NOMBRE_REPO.git

# 4. Primer push (pide usuario de GitHub + token classic con public_repo)
git push -u origin main
```
