**`git reset`** mueve el puntero `HEAD` (y opcionalmente el índice y el working directory) a un commit anterior. Tiene tres modos principales:

### 1. `--soft`
```bash
git reset --soft <commit>
```
- Solo mueve `HEAD` al commit indicado.
- **No toca** el índice (staging area) ni los archivos del working directory.
- Todos los cambios de los commits que “deshaces” quedan **staged** (listos para un nuevo commit).

**Útil cuando:** quieres rehacer el último commit (o varios) manteniendo los cambios preparados. Ejemplo clásico: `git reset --soft HEAD~1` para deshacer el último commit y volver a commitear con otro mensaje o incluyendo más archivos.

---

### 2. `--mixed` (es el valor por defecto)
```bash
git reset --mixed <commit>
# o simplemente
git reset <commit>
```
- Mueve `HEAD` al commit.
- **Resetea el índice** para que coincida con ese commit.
- **No toca** el working directory (los archivos siguen con los cambios).

Los cambios quedan **unstaged** (modificados pero no preparados para commit).

**Útil cuando:** quieres deshacer commits y dejar los cambios en el working directory para decidir qué volver a stagear.

---

### 3. `--hard`
```bash
git reset --hard <commit>
```
- Mueve `HEAD`.
- Resetea el **índice**.
- Resetea el **working directory** para que coincida exactamente con el commit.
- **Descarta** todos los cambios no committeados (staged y unstaged).

**Es destructivo.** Úsalo solo cuando estés seguro de que quieres tirar los cambios a la basura.

---

### Resumen rápido

| Modo     | HEAD | Índice (staging) | Working directory | Cambios |
|----------|------|------------------|-------------------|---------|
| `--soft` | ✓    | No cambia        | No cambia         | Quedan staged |
| `--mixed`| ✓    | Se resetea       | No cambia         | Quedan unstaged |
| `--hard` | ✓    | Se resetea       | Se resetea        | Se pierden |

**Consejo de seguridad:** antes de un `--hard`, asegúrate de no tener trabajo importante sin commit (o haz un `git stash` por si acaso).
