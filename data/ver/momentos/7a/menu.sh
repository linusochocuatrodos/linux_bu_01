#!/usr/bin/env bash
# menu.sh — Menú principal unificado de Stream Moments.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/lib.sh"

pausar() {
    echo
    read -rp "Presioná Enter para continuar..." _ || true
}

while true; do
    limpiar
    mostrar_estado
    printf '%b=== Stream Moments ===%b\n\n' "$C_BOLD" "$C_RESET"
    echo "  1) Abrir momento en el navegador"
    echo "  2) Agregar momento (interactivo)"
    echo "  3) Procesar momentos.txt"
    echo "  4) Editar momento (minuto / descripción / fecha)"
    echo "  5) Remover momento(s)"
    echo "  6) Ver últimos 20 momentos"
    echo "  7) Ver estadísticas"
    echo "  s) Salir"
    echo
    if ! read -rp "> " opt; then
        exit 0
    fi
    opt="$(trim "$opt")"

    case "$opt" in
        1) "$ROOT/abrir.sh" || true ;;
        2) "$ROOT/momento.sh" --interactivo || true; pausar ;;
        3) "$ROOT/momento.sh" || true; pausar ;;
        4) "$ROOT/edit.sh" || true ;;
        5) "$ROOT/remover.sh" || true ;;
        6)
            limpiar
            echo "=== Últimos 20 momentos ==="
            echo
            "$ROOT/ver.sh" -n 20 || true
            pausar
            ;;
        7)
            limpiar
            echo "=== Estadísticas ==="
            echo
            "$ROOT/ver.sh" --stats || true
            pausar
            ;;
        s|S) exit 0 ;;
        *) set_estado warn "Opción inválida: '$opt'" ;;
    esac
done
