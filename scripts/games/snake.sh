#!/bin/bash

# Configuración
GRID_WIDTH=40
GRID_HEIGHT=20
SPEED=0.3

# Ocultar cursor y restaurarlo al salir
tput civis
trap "tput cnorm; echo; exit" INT TERM EXIT

head_x=$((GRID_WIDTH / 2))
head_y=$((GRID_HEIGHT / 2))
snake=("$head_x,$head_y")
dx=1   # Iniciamos moviéndose a la derecha
dy=0

score=0

# Generar comida
spawn_food() {
    while true; do
        food_x=$((RANDOM % GRID_WIDTH))
        food_y=$((RANDOM % GRID_HEIGHT))
        for segment in "${snake[@]}"; do
            if [[ "$segment" == "$food_x,$food_y" ]]; then
                continue 2
            fi
        done
        break
    done
}

spawn_food
clear

# Bucle principal
while true; do
    # 1. Dibujar el tablero en un solo buffer (evita parpadeos)
    buffer=""
    for (( y=0; y<GRID_HEIGHT; y++ )); do
        for (( x=0; x<GRID_WIDTH; x++ )); do
            if [[ "$x,$y" == "$head_x,$head_y" ]]; then
                buffer+="O"
            elif [[ "$x,$y" == "$food_x,$food_y" ]]; then
                buffer+="@"
            else
                is_body=false
                for (( s=1; s<${#snake[@]}; s++ )); do
                    if [[ "${snake[s]}" == "$x,$y" ]]; then
                        is_body=true
                        break
                    fi
                done
                if $is_body; then
                    buffer+="o"
                else
                    buffer+="."
                fi
            fi
        done
        buffer+="\n"
    done

    # Mover el cursor al inicio sin borrar toda la pantalla
    tput cup 0 0
    echo -e "$buffer"
    echo "Puntuación: $score | (WASD para mover, Q para salir)"

    # 2. Entrada de teclado
    read -s -t $SPEED -n 1 key
    case $key in
        w|W) [[ $dy -ne 1 ]] && { dy=-1; dx=0; } ;;
        s|S) [[ $dy -ne -1 ]] && { dy=1; dx=0; } ;;
        a|A) [[ $dx -ne 1 ]] && { dx=-1; dy=0; } ;;
        d|D) [[ $dx -ne -1 ]] && { dx=1; dy=0; } ;;
        q|Q) break ;;
    esac

    # 3. Calcular nueva cabeza
    new_head_x=$((head_x + dx))
    new_head_y=$((head_y + dy))

    # 4. Colisión con paredes
    if [[ $new_head_x -lt 0 || $new_head_x -ge GRID_WIDTH || $new_head_y -lt 0 || $new_head_y -ge GRID_HEIGHT ]]; then
        break
    fi

    # 5. Colisión con el cuerpo
    for (( s=0; s<${#snake[@]}-1; s++ )); do
        if [[ "${snake[s]}" == "$new_head_x,$new_head_y" ]]; then
            break 2
        fi
    done

    # 6. Movimiento / Comer
    if [[ "$new_head_x,$new_head_y" == "$food_x,$food_y" ]]; then
        score=$((score + 1))
        snake=("$new_head_x,$new_head_y" "${snake[@]}")
        spawn_food
    else
        unset 'snake[${#snake[@]}-1]'
        snake=("$new_head_x,$new_head_y" "${snake[@]}")
    fi

    head_x=$new_head_x
    head_y=$new_head_y
done

tput cup $((GRID_HEIGHT + 2)) 0
echo -e "¡Game Over! Puntuación final: $score"
