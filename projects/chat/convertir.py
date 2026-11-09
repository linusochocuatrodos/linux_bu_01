#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""convertir.py.

Convierte el chat JSON de Streamrecorder al esquema oficial de
TwitchDownloaderCore v1.56+.
Permite arrastrar archivos directamente al script o terminal, verifica dependencias
y ofrece renderizado automático optimizado para CPU/temperatura.
"""

import datetime
import json
import os
import shutil
import subprocess
import sys
from urllib.parse import unquote


# =====================================================================
#  Utilidades de Rutas y Arrastre
# =====================================================================
def limpiar_ruta(raw_path: str) -> str:
    """Limpia la ruta si fue arrastrada desde el explorador de archivos

    (elimina comillas, escapes, prefijos file:// y resuelve rutas relativas).
    """
    if not raw_path:
        return ""
    p = raw_path.strip().strip("'\"")
    if p.startswith("file://"):
        p = unquote(p[7:])
    return os.path.abspath(os.path.expanduser(p))


# =====================================================================
#  Verificación de Dependencias del Sistema
# =====================================================================
def verificar_dependencias() -> bool:
    print("\n🔍 Verificando herramientas necesarias...")
    errores = []

    # 1. FFmpeg
    if shutil.which("ffmpeg"):
        print("  [✔] ffmpeg detectado.")
    else:
        errores.append(
            "✖ 'ffmpeg' no está instalado o no se encuentra en el PATH.\n"
            "    Instálalo en Nobara/Fedora con: sudo dnf install ffmpeg"
        )

    # 2. FFprobe
    if shutil.which("ffprobe"):
        print("  [✔] ffprobe detectado.")
    else:
        errores.append(
            "✖ 'ffprobe' no está instalado.\n"
            "    Instálalo en Nobara/Fedora con: sudo dnf install ffmpeg-free o ffmpeg"
        )

    # 3. TwitchDownloaderCLI (busca en la carpeta actual o en PATH)
    cli_local = os.path.join(os.getcwd(), "TwitchDownloaderCLI")
    cli_en_path = shutil.which("TwitchDownloaderCLI")

    if os.path.isfile(cli_local) and os.access(cli_local, os.X_OK):
        print(f"  [✔] TwitchDownloaderCLI detectado en la carpeta actual ({cli_local}).")
    elif cli_en_path and os.access(cli_en_path, os.X_OK):
        print(f"  [✔] TwitchDownloaderCLI detectado en el sistema ({cli_en_path}).")
    else:
        errores.append(
            "✖ 'TwitchDownloaderCLI' no se encuentra o no tiene permisos de ejecución (+x).\n"
            "    Asegúrate de que el archivo 'TwitchDownloaderCLI' esté en esta carpeta y corre:\n"
            "    chmod +x TwitchDownloaderCLI"
        )

    # 4. Taskset (para control térmico en Linux)
    if shutil.which("taskset"):
        print("  [✔] taskset detectado (control de afinidad de CPU activo).")
    else:
        print("  [i] taskset no encontrado (el render usará todos los hilos).")

    if errores:
        print("\n❌ Faltan componentes para completar el flujo:")
        for err in errores:
            print(f"  {err}")
        print("\nPor favor instala los programas faltantes antes de continuar.\n")
        return False

    print("  Todos los programas requeridos están presentes.\n")
    return True


# =====================================================================
#  Conversión de Esquema JSON
# =====================================================================
def adaptar_chat_json(archivo_in: str, archivo_out: str) -> bool:
    if not os.path.isfile(archivo_in):
        print(f"❌ Error: El archivo de entrada '{archivo_in}' no existe.")
        return False

    print(f"📄 Procesando: {os.path.basename(archivo_in)}")
    try:
        with open(archivo_in, "r", encoding="utf-8") as f:
            datos_origen = json.load(f)
    except Exception as e:
        print(f"❌ Error al abrir o decodificar el JSON: {e}")
        return False

    if not isinstance(datos_origen, list):
        print("❌ Error: El archivo JSON no tiene el formato de lista de mensajes esperado.")
        return False

    comentarios_adaptados = []
    max_offset = 0.0
    channel_room_id = 0

    for item in datos_origen:
        ms = float(item.get("video_ts_ms", 0))
        offset_sec = round(ms / 1000.0, 3)
        if offset_sec > max_offset:
            max_offset = offset_sec

        tags = item.get("tags") or {}
        display_name = item.get("display_name") or tags.get("display-name") or "Anónimo"
        color = tags.get("color") or "#8A2BE2"
        mensaje_texto = item.get("message", "")

        if not channel_room_id and tags.get("room-id"):
            try:
                channel_room_id = int(tags.get("room-id"))
            except ValueError:
                pass

        # Procesar Badges
        lista_badges = []
        badges_str = tags.get("badges")
        if badges_str:
            for b in badges_str.split(","):
                if "/" in b:
                    b_id, b_ver = b.split("/", 1)
                    lista_badges.append({"_id": b_id, "version": b_ver})

        ahora_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
        comentario = {
            "_id": str(item.get("id")),
            "created_at": ahora_iso,
            "content_offset_seconds": offset_sec,
            "commenter": {
                "display_name": display_name,
                "_id": str(tags.get("user-id", "0")),
                "name": display_name.lower(),
                "type": "user",
            },
            "message": {
                "body": mensaje_texto,
                "fragments": [{"text": mensaje_texto, "emoticon": None}],
                "user_badges": lista_badges,
                "user_color": color,
            },
        }
        comentarios_adaptados.append(comentario)

    duracion_total = int(max_offset) + 5
    timestamp_utc = datetime.datetime.now(datetime.timezone.utc).isoformat()

    schema_final = {
        "FileInfo": {
            "Version": {"Major": 1, "Minor": 3, "Patch": 1},
            "CreatedAt": timestamp_utc,
            "UpdatedAt": "0001-01-01T00:00:00",
        },
        "streamer": {
            "name": "streamer",
            "id": channel_room_id if channel_room_id else 1,
        },
        "video": {
            "title": os.path.splitext(os.path.basename(archivo_in))[0],
            "description": None,
            "id": str(channel_room_id),
            "created_at": timestamp_utc,
            "start": 0,
            "end": duracion_total,
            "length": duracion_total,
            "view_count": 0,
            "game": "Just Chatting",
        },
        "comments": comentarios_adaptados,
        "embeddedData": None,
    }

    try:
        with open(archivo_out, "w", encoding="utf-8") as f:
            json.dump(schema_final, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"❌ Error guardando '{archivo_out}': {e}")
        return False

    print(f"✅ Conversión lista -> '{archivo_out}'")
    print(f"   Mensajes: {len(comentarios_adaptados)} | Duración estimada: {duracion_total}s")
    return True


# =====================================================================
#  Renderizado Automático con Control Térmico
# =====================================================================
def ejecutar_render(archivo_json_adaptado: str, archivo_salida_mov: str):
    cli = "./TwitchDownloaderCLI" if os.path.isfile("./TwitchDownloaderCLI") else "TwitchDownloaderCLI"

    cmd = [
        cli, "chatrender",
        "-i", archivo_json_adaptado,
        "-o", archivo_salida_mov,
        '--background-color=#00000000',
        '--output-args=-c:v qtrle -pix_fmt argb -threads 2 "{save_path}"',
        "-w", "380",
        "-h", "720",
        "--font-size", "18",
        "--framerate", "30",
        "--outline"
    ]

    # Si taskset existe, limitar a hilos 0-3 para evitar calentamiento en CPUs Ryzen
    if shutil.which("taskset"):
        cmd = ["taskset", "-c", "0-3"] + cmd

    print("\n🚀 Iniciando renderizado de video con transparencia...")
    print(f"Comando: {' '.join(cmd)}\n")

    try:
        subprocess.run(cmd, check=True)
        if os.path.isfile(archivo_salida_mov):
            peso_mb = os.path.getsize(archivo_salida_mov) / (1024 * 1024)
            print(f"\n🎉 ¡Video renderizado exitosamente!")
            print(f"   Archivo: {archivo_salida_mov} ({peso_mb:.1f} MB)")
            print("   Listo para importar a Kdenlive (pista V2).")
    except subprocess.CalledProcessError as e:
        print(f"\n❌ Error durante el renderizado (Código {e.returncode}).")


# =====================================================================
#  Punto de Entrada
# =====================================================================
def main():
    print("=" * 60)
    print("  Conversor y Renderizador de Chat (Streamrecorder -> Kdenlive)")
    print("=" * 60)

    # 1. Verificar herramientas instaladas
    herramientas_listas = verificar_dependencias()

    # 2. Obtener archivo por arrastre o por argumento
    if len(sys.argv) > 1:
        ruta_archivo = sys.argv[1]
    else:
        print("💡 Puedes arrastrar el archivo .json directamente aquí y presionar Enter:")
        ruta_archivo = input("Archivo JSON: ")

    ruta_archivo = limpiar_ruta(ruta_archivo)

    if not ruta_archivo or not os.path.isfile(ruta_archivo):
        print("❌ No se especificó un archivo JSON válido. Saliendo.")
        sys.exit(1)

    directorio = os.path.dirname(ruta_archivo) or "."
    nombre_base = os.path.splitext(os.path.basename(ruta_archivo))[0]

    json_salida = os.path.join(directorio, "chat_compatible.json")
    mov_salida = os.path.join(directorio, f"{nombre_base}_overlay.mov")

    # 3. Adaptar JSON
    ok = adaptar_chat_json(ruta_archivo, json_salida)
    if not ok:
        sys.exit(1)

    # 4. Ofrecer renderizado inmediato si las herramientas están listas
    if herramientas_listas:
        print("\n¿Deseas renderizar el video transparente (.mov) ahora mismo?")
        ans = input("Presiona Enter para SÍ [S/n]: ").strip().lower()
        if ans in ("", "s", "si", "yes", "y"):
            ejecutar_render(json_salida, mov_salida)
        else:
            print(f"\nOperación finalizada. El archivo convertido está en: {json_salida}")


if __name__ == "__main__":
    main()
