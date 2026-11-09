#!/bin/bash
# Minesweeper - versión corregida

rows=8
cols=8
mines=10

declare -A board      # valor real (M o número)
declare -A revealed   # estado: . = oculto, R = revelado, F = bandera

# Inicializar tablero
for ((i=0; i<rows; i++)); do
  for ((j=0; j<cols; j++)); do
    board[$i,$j]=0
    revealed[$i,$j]="."
  done
done

# Colocar minas
mines_placed=0
while (( mines_placed < mines )); do
  r=$((RANDOM % rows))
  c=$((RANDOM % cols))
  if [[ ${board[$r,$c]} != "M" ]]; then
    board[$r,$c]="M"
    ((mines_placed++))
  fi
done

# Calcular números adyacentes
for ((i=0; i<rows; i++)); do
  for ((j=0; j<cols; j++)); do
    if [[ ${board[$i,$j]} != "M" ]]; then
      count=0
      for ((dx=-1; dx<=1; dx++)); do
        for ((dy=-1; dy<=1; dy++)); do
          if (( dx != 0 || dy != 0 )); then
            ni=$((i + dx))
            nj=$((j + dy))
            if (( ni >= 0 && ni < rows && nj >= 0 && nj < cols )); then
              if [[ ${board[$ni,$nj]} == "M" ]]; then
                ((count++))
              fi
            fi
          fi
        done
      done
      board[$i,$j]=$count
    fi
  done
done

# Función de flood-fill (revelar celdas vacías)
flood_fill() {
  local r=$1 c=$2
  # Fuera de límites o ya revelada/bandera → salir
  if (( r < 0 || r >= rows || c < 0 || c >= cols )); then return; fi
  if [[ ${revealed[$r,$c]} == "R" || ${revealed[$r,$c]} == "F" ]]; then return; fi

  revealed[$r,$c]="R"

  # Si no es 0, no seguir expandiendo
  if [[ ${board[$r,$c]} != "0" ]]; then return; fi

  # Expandir a los 8 vecinos
  for ((dx=-1; dx<=1; dx++)); do
    for ((dy=-1; dy<=1; dy++)); do
      if (( dx != 0 || dy != 0 )); then
        flood_fill $((r + dx)) $((c + dy))
      fi
    done
  done
}

# Mostrar tablero
print_board() {
  clear
  echo -e "\n  Minesweeper  ${rows}x${cols}  (${mines} minas)\n"
  echo -n "    "
  for ((j=0; j<cols; j++)); do printf "%2d " $j; done
  echo
  echo -n "   +"
  for ((j=0; j<cols; j++)); do echo -n "---"; done
  echo "+"

  for ((i=0; i<rows; i++)); do
    printf "%2d |" $i
    for ((j=0; j<cols; j++)); do
      case ${revealed[$i,$j]} in
        "F") printf " F " ;;
        "R")
          if [[ ${board[$i,$j]} == "0" ]]; then
            printf "   "
          else
            printf " %s " "${board[$i,$j]}"
          fi
          ;;
        *)   printf " . " ;;
      esac
    done
    echo "|"
  done
  echo -n "   +"
  for ((j=0; j<cols; j++)); do echo -n "---"; done
  echo -e "+\n"
}

# Comprobar victoria
check_win() {
  for ((i=0; i<rows; i++)); do
    for ((j=0; j<cols; j++)); do
      if [[ ${board[$i,$j]} != "M" && ${revealed[$i,$j]} != "R" ]]; then
        return 1  # todavía hay celdas seguras sin revelar
      fi
    done
  done
  return 0
}

# Bucle principal
turns=0
while true; do
  print_board
  echo -n "Coordenadas (fila,col)  |  f fila,col (bandera)  |  q (salir): "
  read -r input

  # Salir
  if [[ $input == "q" || $input == "Q" ]]; then
    echo "Adiós!"
    exit 0
  fi

  # Bandera
  if [[ $input == f* || $input == F* ]]; then
    coord="${input:1}"          # quitar la 'f'
    coord="${coord// /}"        # quitar espacios
    IFS=',' read -r row col <<< "$coord"

    if [[ $row =~ ^[0-9]+$ && $col =~ ^[0-9]+$ ]] && \
       (( row >= 0 && row < rows && col >= 0 && col < cols )); then
      if [[ ${revealed[$row,$col]} == "F" ]]; then
        revealed[$row,$col]="."   # quitar bandera
      elif [[ ${revealed[$row,$col]} != "R" ]]; then
        revealed[$row,$col]="F"
      fi
    else
      echo "Coordenadas inválidas."
      sleep 1
    fi
  else
    # Revelar celda
    input="${input// /}"
    IFS=',' read -r row col <<< "$input"

    if [[ $row =~ ^[0-9]+$ && $col =~ ^[0-9]+$ ]] && \
       (( row >= 0 && row < rows && col >= 0 && col < cols )); then

      if [[ ${revealed[$row,$col]} == "F" ]]; then
        echo "Primero quita la bandera."
        sleep 1
        continue
      fi

      if [[ ${board[$row,$col]} == "M" ]]; then
        # Mostrar todas las minas
        for ((i=0; i<rows; i++)); do
          for ((j=0; j<cols; j++)); do
            if [[ ${board[$i,$j]} == "M" ]]; then
              revealed[$i,$j]="R"
            fi
          done
        done
        print_board
        echo "¡BOOM! Pisaste una mina. Game Over."
        exit 1
      fi

      # Revelar (con flood-fill si es 0)
      flood_fill $row $col
      ((turns++))

      if check_win; then
        print_board
        echo "¡Felicidades! Ganaste en $turns turnos."
        exit 0
      fi
    else
      echo "Coordenadas inválidas. Usa el formato: fila,columna"
      sleep 1
    fi
  fi
done
