# Fix para Bluetooth RTL8761BU en Nobara Linux 44

Este documento describe el diagnóstico y la solución aplicada al chip Bluetooth
Realtek RTL8761BU (USB ID `0bda:a728`) en una distribución **Nobara Linux 44
(KDE Plasma Desktop Edition)** con kernel `7.2.0-202.nobara.fc44.x86_64`.

> **Nota:** toda la información personal (nombre de host, MAC del controlador,
> dispositivo emparejado, usuario, etc.) fue removida de este archivo para que
> pueda publicarse en GitHub sin exponer datos privados.

---

## 1. Contexto y síntoma

El Bluetooth dejaba de funcionar correctamente en el sistema:

- El servicio `bluetooth.service` aparecía como `active (running)`, pero el
  controlador HCI (`hci0`) no respondía a ningún comando.
- `bluetoothctl power on` devolvía `Failed to set power on: org.bluez.Error.Failed`.
- `bluetoothctl show` mostraba `Powered: no` y `PowerState: on`.
- Cualquier intento de escaneo devolvía `Failed to start discovery: org.bluez.Error.NotReady`.
- Al usar auriculares Bluetooth con audio (música, videos, directos), el audio
  se cortaba al pausar y el dispositivo se desconectaba y reconectaba
  automáticamente cada 10–20 segundos.

---

## 2. Recolección de información

### 2.1. Sistema operativo

```bash
cat /etc/os-release
```

```bash
# Salida (parcial):
NAME="Nobara Linux"
VERSION="44 (KDE Plasma Desktop Edition)"
ID=nobara
ID_LIKE="rhel centos fedora"
VERSION_ID=44
```

### 2.2. Kernel

```bash
uname -r
```

```bash
# Salida:
7.2.0-202.nobara.fc44.x86_64
```

### 2.3. Identificación del hardware Bluetooth

```bash
lsusb | grep -i bluetooth
```

```bash
# Salida:
Bus 005 Device 002: ID 0bda:a728 Realtek Semiconductor Corp. Bluetooth 5.4 Radio
```

- **Vendor:** `0x0bda` (Realtek Semiconductor Corp.)
- **Product:** `0xa728`
- **Chip:** RTL8761BU (confirmado por `lmp_subver=8761` en los logs del kernel).

### 2.4. Estado de `rfkill`

```bash
rfkill list
```

```bash
# Salida:
0: hci0: Bluetooth
    Soft blocked: yes
    Hard blocked: no
```

> El dispositivo estaba **soft-blocked** desde el inicio. Eso ya impedía
> encenderlo, pero no era la única causa del problema.

### 2.5. Módulos del kernel cargados

```bash
lsmod | grep -i bluetooth
lsmod | grep -i btusb
```

```bash
# Salida:
bluetooth   1277952  44 btrtl,btmtk,btintel,btbcm,bnep,btusb,rfcomm
btusb          86016  0
btmtk          40960  1 btusb
btrtl          40960  1 btusb
btbcm          24576  1 btusb
btintel        77824  1 btusb
```

> Todos los módulos necesarios estaban cargados correctamente.

### 2.6. Servicio systemd

```bash
systemctl status bluetooth
```

```bash
# Salida (parcial):
● bluetooth.service - Bluetooth service
     Loaded: loaded (/usr/lib/systemd/system/bluetooth.service; enabled; preset: enabled)
     Active: active (running) since ...
       Docs: man:bluetoothd(8)
     Main PID: 5124 (bluetoothd)
```

> El servicio estaba corriendo sin errores de inicio.

### 2.7. Logs del kernel durante el arranque

```bash
journalctl -k --no-pager -n 100 | grep -iE "bluetooth|btusb|rtl|firmware"
```

```bash
# Salida:
kernel: usbcore: registered new interface driver btusb
kernel: Bluetooth: hci0: RTL: examining hci_ver=0a hci_rev=000b lmp_ver=0a lmp_subver=8761
kernel: Bluetooth: hci0: RTL: rom_version status=0 version=1
kernel: Bluetooth: hci0: RTL: btrtl_initialize: key id 0
kernel: Bluetooth: hci0: RTL: loading rtl_bt/rtl8761bu_fw.bin
kernel: Bluetooth: hci0: RTL: loading rtl_bt/rtl8761bu_config.bin
kernel: Bluetooth: hci0: RTL: cfg_sz 6, total sz 30210
kernel: Bluetooth: hci0: RTL: fw version 0xdfc6d922
```

> El firmware se cargó correctamente (`rtl8761bu_fw.bin` + `rtl8761bu_config.bin`).
> Versión final `0xdfc6d922`. Esto descartaba un problema de firmware
> inexistente o corrupto.

### 2.8. Logs posteriores al arranque (la pista clave)

```bash
journalctl -k --no-pager --since "1 hour ago" | grep -iE "bluetooth|btusb|rtl876|firmware"
```

```bash
# Salida (final):
... (firmware cargado correctamente) ...
kernel: Bluetooth: hci0: Opcode 0x0c03 failed: -110
kernel: Bluetooth: hci0: Opcode 0x0c03 failed: -110
... (repetido varias veces) ...
```

- El opcode `0x0c03` corresponde a comandos HCI de inicialización/control.
- El código `-110` es `ETIMEDOUT` (timeout en comunicación HCI).
- **Significado:** el chip no respondía a comandos porque estaba en suspensión.

### 2.9. Logs del servicio bluetoothd

```bash
journalctl -u bluetooth --no-pager -n 30
```

```bash
# Salida (errores clave):
bluetoothd: Failed to set mode: Authentication Failed (0x05)
bluetoothd: Failed to add device <MAC_REMOVED> (2): Failed (0x03)
```

> Estos errores son consecuencia del timeout HCI: bluez intenta configurar el
> radio y no obtiene respuesta, devolviendo un error genérico.

### 2.10. Estado de energía del puerto USB

```bash
cat /sys/bus/usb/devices/<BUS>-<PORT>/power/control
cat /sys/bus/usb/devices/<BUS>-<PORT>/power/autosuspend
```

```bash
# Salida:
auto
2
```

> **¡Causa raíz identificada!** El puerto USB del adaptador Bluetooth tenía
> `power/control=auto` y `autosuspend=2`. Esto significa que el kernel
> suspendía el dispositivo USB después de **2 segundos** de inactividad,
> apagando el chip RTL8761BU y haciendo que cualquier comando HCI falle con
> timeout.

### 2.11. uevent del dispositivo

```bash
cat /sys/class/bluetooth/hci0/device/uevent
```

```bash
# Salida:
DEVTYPE=usb_interface
DRIVER=btusb
PRODUCT=bda/a728/200
TYPE=224/1/1
INTERFACE=224/1/1
MODALIAS=usb:v0BDApA728d0200dcE0dsc01dp01icE0isc01ip01in00
```

> Confirmado: el driver es `btusb` y el dispositivo físico vive en dos
> interfaces USB del mismo puerto (`:1.0` y `:1.1`).

---

## 3. Diagnóstico final

| Capa | Estado | Observación |
|------|--------|-------------|
| Hardware (RTL8761BU) | OK | Detectado por `lsusb` |
| Driver (`btusb`) | OK | Cargado |
| Firmware | OK | Cargado, versión `0xdfc6d922` |
| Servicio `bluetoothd` | OK | Corriendo |
| `rfkill` | Bloqueado soft | Una parte del problema |
| **Energía USB** | **AUTO-suspendido cada 2s** | **Causa raíz principal** |

**Conclusión:** el chip Bluetooth USB se suspendía automáticamente por la
política de energía del kernel (USB autosuspend). Esto provocaba:

1. Que `bluetoothctl power on` fallara.
2. Que los auriculares se desconectaran cada pocos segundos al pausar el audio
   (el dispositivo perdía respuesta HCI).
3. Que el servicio bluetoothd reportara errores falsos de "Authentication
   Failed".

---

## 4. Solución aplicada

Se compone de **dos partes**: un fix inmediato y una regla udev persistente.

### 4.1. Fix inmediato (efectivo en la sesión actual)

```bash
# 1. Desbloquear el dispositivo (por si volvió a quedar soft-blocked)
sudo rfkill unblock bluetooth

# 2. Forzar el puerto USB del Bluetooth a permanecer encendido.
#    Reemplazar <BUS>-<PORT> por la ruta real del dispositivo
#    (en este caso era 5-3; se localiza con `lsusb -t`).
echo "on" | sudo tee /sys/bus/usb/devices/<BUS>-<PORT>/power/control
echo -1   | sudo tee /sys/bus/usb/devices/<BUS>-<PORT>/power/autosuspend

# 3. Reiniciar el servicio bluetooth para que tome el nuevo estado
sudo systemctl restart bluetooth
sleep 3
bluetoothctl power on
```

Después de esto:

```bash
[CHG] Controller <MAC_REMOVED> PowerState: off-enabling
[CHG] Controller <MAC_REMOVED> Class: 0x007c0104 (8126724)
Changing power on succeeded
```

`bluetoothctl show` ahora muestra:

```bash
Powered: yes
PowerState: on
```

### 4.2. Regla udev permanente (sobrevive a reinicios)

Para que el cambio se aplique automáticamente cada vez que el sistema
reconozca el dispositivo USB, se creó una regla udev:

```bash
sudo tee /etc/udev/rules.d/50-bluetooth-usb-power.rules > /dev/null <<'EOF'
# Mantener el Bluetooth USB siempre encendido (evita autosuspend)
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="a728", \
  ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=0bda --attr-match=idProduct=a728
```

**Qué hace:**

- `ATTR{power/control}="on"` desactiva la gestión automática de energía del
  puerto USB específico del Bluetooth.
- `ATTR{power/autosuspend}="-1"` desactiva completamente el autosuspend.
- La regla usa `idVendor=0bda` y `idProduct=a728` para **solo** aplicarse al
  adaptador Bluetooth, sin afectar otros dispositivos USB.

### 4.3. Verificación posterior

```bash
cat /sys/bus/usb/devices/<BUS>-<PORT>/power/control
cat /sys/bus/usb/devices/<BUS>-<PORT>/power/autosuspend
rfkill list
```

```bash
# Salida esperada:
on
-1
0: hci0: Bluetooth
    Soft blocked: no
    Hard blocked: no
```

---

## 5. Por qué se cortaba el audio al pausar

1. Al pausar el audio, el kernel considera el dispositivo USB Bluetooth "inactivo".
2. Después de 2 segundos, el kernel suspende el puerto USB.
3. El chip RTL8761BU se apaga.
4. La conexión Bluetooth con los auriculares se pierde.
5. Bluez intenta reconectar (lo que se observa como reconexión automática).
6. Mientras tanto, los auriculares quedan sin audio.
7. Si bluez no logra configurar el dispositivo a tiempo, aparece el bucle de
   `Failed to set mode: Authentication Failed` y las desconexiones constantes.

Con la regla udev aplicada, el dispositivo USB nunca entra en suspensión y el
audio permanece estable al pausar/reproducir.

---

## 6. Resumen de comandos (cheatsheet)

```bash
# Ver el estado actual
rfkill list
cat /sys/bus/usb/devices/<BUS>-<PORT>/power/control
cat /sys/bus/usb/devices/<BUS>-<PORT>/power/autosuspend
bluetoothctl show

# Localizar el puerto USB donde está conectado el Bluetooth
lsusb -t | grep -i wireless
# (Buscar el bus/port asociado al dispositivo 0bda:a728)

# Aplicar el fix (rápido, hasta el próximo reinicio)
sudo rfkill unblock bluetooth
echo "on" | sudo tee /sys/bus/usb/devices/<BUS>-<PORT>/power/control
echo -1   | sudo tee /sys/bus/usb/devices/<BUS>-<PORT>/power/autosuspend
sudo systemctl restart bluetooth

# Aplicar el fix permanente (recomendado)
sudo tee /etc/udev/rules.d/50-bluetooth-usb-power.rules > /dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="a728", \
  ATTR{power/control}="on", ATTR{power/autosuspend}="-1"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger
```

---

## 7. Notas adicionales

- La ruta `<BUS>-<PORT>` (en este caso `5-3`) corresponde al bus USB donde
  está conectado el dispositivo. En otros sistemas puede variar (`1-1`,
  `3-2`, etc.). Se puede localizar con `lsusb -t` o con:
  ```bash
  find /sys/bus/usb/devices -name "idProduct" -exec grep -l "a728" {} \;
  ```
- Si en el futuro se cambia el adaptador Bluetooth por otro con distinto
  `idVendor`/`idProduct`, hay que actualizar la regla udev.
- Si el problema reaparece al **suspender/reanudar** el sistema, hace falta
  un hook `systemd-sleep` para reaplicar la configuración tras la reanudada.
- El error `dmesg: read kernel buffer failed: Operation not permitted` al
  intentar leer `dmesg` sin privilegios es **esperado** y no indica fallo.

---

## 8. Compatibilidad

Este fix ha sido verificado en:

- **SO:** Nobara Linux 44 (KDE Plasma Desktop Edition)
- **Kernel:** `7.2.0-202.nobara.fc44.x86_64`
- **Chip Bluetooth:** Realtek RTL8761BU (`0bda:a728`)

Debería funcionar en cualquier distribución basada en Fedora/RHEL con el mismo
kernel o uno compatible, y adaptarse fácilmente a otros chips Bluetooth USB
cambiando `idVendor` e `idProduct` en la regla udev.

Para encontrar el ID de tu propio dispositivo:

```bash
lsusb | grep -i bluetooth
```