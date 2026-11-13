#!/usr/bin/env bash
# edit.sh — Editar minuto, descripción o fecha de un momento guardado.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

if [[ ! -d "$DATA" ]] || [[ -z "$(listar_streamers)" ]]; then
    echo "Sin datos aún. Agregá líneas a momentos.txt y corré ./momento.sh"
    exit 0
fi

editar_timestamp_en_archivo() {
    local relpath="$1" secs_old="$2" desc="$3" new_secs="$4" new_min="$5"
    local archivo="$DATA/$relpath"
    if [[ ! -f "$archivo" ]]; then
        echo "No se encontró el archivo: $archivo" >&2
        return 1
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    OLD_SECS="$secs_old" OLD_DESC="$desc" \
    NEW_SECS="$new_secs" NEW_MIN="$new_min" \
    awk '
    BEGIN { updated = 0 }
    NR <= 7 { print; next }
    /^\|/ {
        line = $0
        sub(/\r$/, "", line)
        body = line
        sub(/^\|[ \t]*/, "", body)
        p1 = index(body, "|")
        if (p1 > 0) {
            s = substr(body, 1, p1 - 1)
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            rest = substr(body, p1 + 1)
            p2 = index(rest, "|")
            if (p2 > 0) {
                d = substr(rest, p2 + 1)
                sub(/[ \t]*\|[ \t]*$/, "", d)
                gsub(/^[ \t]+|[ \t]+$/, "", d)
                if (!updated && s == ENVIRON["OLD_SECS"] && d == ENVIRON["OLD_DESC"]) {
                    printf "| %s | %s | %s |\n", ENVIRON["NEW_SECS"], ENVIRON["NEW_MIN"], ENVIRON["OLD_DESC"]
                    updated = 1
                    next
                }
            }
        }
    }
    { print }
    ' "$archivo" > "$tmp_file"

    touch -r "$archivo" "$tmp_file"
    mv "$tmp_file" "$archivo"
}

editar_desc_en_archivo() {
    local relpath="$1" secs_old="$2" desc_old="$3" desc_new="$4"
    local archivo="$DATA/$relpath"
    if [[ ! -f "$archivo" ]]; then
        echo "No se encontró el archivo: $archivo" >&2
        return 1
    fi

    # Evitar colisión si ya existe esa descripción en el mismo video
    local dup=0
    dup=$(NEW_DESC="$desc_new" awk '
    NR <= 7 { next }
    /^\|/ {
        line = $0; sub(/\r$/, "", line); sub(/^\|[ \t]*/, "", line)
        p1 = index(line, "|"); if (p1 == 0) next
        rest = substr(line, p1 + 1); p2 = index(rest, "|"); if (p2 == 0) next
        d = substr(rest, p2 + 1); sub(/[ \t]*\|[ \t]*$/, "", d); gsub(/^[ \t]+|[ \t]+$/, "", d)
        if (d == ENVIRON["NEW_DESC"]) { print 1; exit }
    }' "$archivo")
    if [[ "$dup" == "1" ]]; then
        return 2
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    OLD_SECS="$secs_old" OLD_DESC="$desc_old" NEW_DESC="$desc_new" \
    awk '
    BEGIN { updated = 0 }
    NR <= 7 { print; next }
    /^\|/ {
        line = $0
        sub(/\r$/, "", line)
        body = line
        sub(/^\|[ \t]*/, "", body)
        p1 = index(body, "|")
        if (p1 > 0) {
            s = substr(body, 1, p1 - 1)
            gsub(/^[ \t]+|[ \t]+$/, "", s)
            rest = substr(body, p1 + 1)
            p2 = index(rest, "|")
            if (p2 > 0) {
                m = substr(rest, 1, p2 - 1)
                gsub(/^[ \t]+|[ \t]+$/, "", m)
                d = substr(rest, p2 + 1)
                sub(/[ \t]*\|[ \t]*$/, "", d)
                gsub(/^[ \t]+|[ \t]+$/, "", d)
                if (!updated && s == ENVIRON["OLD_SECS"] && d == ENVIRON["OLD_DESC"]) {
                    printf "| %s | %s | %s |\n", s, m, ENVIRON["NEW_DESC"]
                    updated = 1
                    next
                }
            }
        }
    }
    { print }
    ' "$archivo" > "$tmp_file"

    touch -r "$archivo" "$tmp_file"
    mv "$tmp_file" "$archivo"
    actualizar_orden_desc "$relpath" "$desc_old" "$desc_new"
}

editar_fecha_en_archivo() {
    local relpath="$1" nueva_fecha="$2"
    local archivo="$DATA/$relpath"
    [[ -f "$archivo" ]] || return 1

    local tmp_file
    tmp_file="$(mktemp)"
    NEW_F="$nueva_fecha" awk '
    /^\*\*Fecha:\*\*/ && !done {
        print "**Fecha:** " ENVIRON["NEW_F"]
        done = 1
        next
    }
    { print }
    ' "$archivo" > "$tmp_file"
    touch -r "$archivo" "$tmp_file"
    mv "$tmp_file" "$archivo"
}

# Prompt de edición para un momento seleccionado.
# Retorna: 0=editado, 2=volver, 3=salir
pedir_edicion() {
    local streamer="$1" secs_old="$2" minuto_old="$3" desc="$4" url="$5" fecha_ddmm="$6" fecha_iso="$7" relpath="$8"
    local entrada

    while true; do
        printf '\n%bEditando:%b [%s — %s — %s] "%s"\n' \
            "$C_BOLD" "$C_RESET" "$fecha_ddmm" "$streamer" "$minuto_old" "$desc"
        printf 'URL: %s#t=%s\n' "$(limpiar_url "$url")" "$secs_old"
        if ! read -rp "Nuevo minuto (ej. 1:45), 'd' desc, 'f' fecha, 'a' abrir, 'v' volver, 's' salir: " entrada; then
            return 3
        fi
        entrada="$(trim "$entrada")"

        case "$entrada" in
            v|V) return 2 ;;
            s|S) return 3 ;;
            a|A)
                local target
                target="$(limpiar_url "$url")#t=${secs_old}"
                abrir_en_navegador "$target" || true
                echo "→ Abriendo en navegador: $target"
                ;;
            d|D)
                local nueva_desc
                if ! read -rp "Nueva descripción (Enter cancela): " nueva_desc; then
                    return 3
                fi
                nueva_desc="${nueva_desc//|/│}"
                nueva_desc="${nueva_desc//$'\t'/ }"
                nueva_desc="$(trim "$nueva_desc")"
                if [[ -z "$nueva_desc" || "$nueva_desc" == "$desc" ]]; then
                    echo "Sin cambios."
                    continue
                fi
                local rc_d=0
                editar_desc_en_archivo "$relpath" "$secs_old" "$desc" "$nueva_desc" || rc_d=$?
                if [[ $rc_d -eq 2 ]]; then
                    echo "Ya existe otro momento con esa descripción en este video."
                    continue
                elif [[ $rc_d -ne 0 ]]; then
                    set_estado err "Error al editar descripción."
                    return 0
                fi
                set_estado ok "✓ Descripción editada: \"$desc\" → \"$nueva_desc\""
                return 0
                ;;
            f|F)
                local nueva_fecha
                if ! read -rp "Nueva fecha del video YYYY-MM-DD (actual $fecha_iso, Enter cancela): " nueva_fecha; then
                    return 3
                fi
                nueva_fecha="$(trim "$nueva_fecha")"
                [[ -z "$nueva_fecha" ]] && continue
                if [[ ! "$nueva_fecha" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || \
                   (( 10#${BASH_REMATCH[2]} < 1 || 10#${BASH_REMATCH[2]} > 12 || 10#${BASH_REMATCH[3]} < 1 || 10#${BASH_REMATCH[3]} > 31 )); then
                    echo "Fecha inválida. Usá formato YYYY-MM-DD (ej. 2026-11-13)."
                    continue
                fi
                editar_fecha_en_archivo "$relpath" "$nueva_fecha"
                set_estado ok "✓ Fecha actualizada para el video de $streamer: $fecha_iso → $nueva_fecha"
                return 0
                ;;
            *)
                local total=""
                if ! total="$(timestamp_a_segundos "$entrada")"; then
                    echo "Formato inválido o fuera de rango (minutos y segundos <= 59)."
                    continue
                fi
                local nuevo_min
                nuevo_min="$(formatear_minuto "$entrada")"
                editar_timestamp_en_archivo "$relpath" "$secs_old" "$desc" "$total" "$nuevo_min"
                set_estado ok "✓ Editado: $streamer — \"$desc\"  $minuto_old → $nuevo_min"
                return 0
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Bucle principal
# ---------------------------------------------------------------------------
while true; do
    set +e
    menu_streamers "=== Editar — Streamers ===" "s"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] && exit 0

    filtro=""
    modo="todos"
    if [[ "$SELECCION" != "__ALL__" ]]; then
        filtro="$SELECCION"
        modo="streamer"
    fi

    while true; do
        set +e
        menu_momentos "=== Editar — Momentos ===" "$filtro" "n" "$modo"
        rc=$?
        set -e

        if [[ $rc -eq 2 ]]; then
            break
        elif [[ $rc -ne 0 ]]; then
            exit 0
        fi

        IFS="$SEP" read -r _ streamer secs_old minuto_old desc url fecha fecha_iso relpath <<< "$SELECCION_LINEA"

        set +e
        pedir_edicion "$streamer" "$secs_old" "$minuto_old" "$desc" "$url" "$fecha" "$fecha_iso" "$relpath"
        rc=$?
        set -e

        if [[ $rc -eq 2 ]]; then
            continue
        elif [[ $rc -ne 0 ]]; then
            exit 0
        fi
    done
done
