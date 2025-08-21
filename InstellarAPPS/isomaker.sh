#!/bin/bash
set -euo pipefail

# ==============================
# InstellarOS ISO Builder
# ==============================

# Nombre y ruta de salida
ISO_NAME="instellarOS"
OUTPUT_DIR="$HOME/isos"
WORK_DIR="$HOME/instellar-iso"

# 1. Instalar dependencias
echo "[+] Instalando archiso..."
sudo pacman -S --needed --noconfirm archiso rsync

# 2. Crear directorio base copiando plantilla oficial de Arch
echo "[+] Preparando plantilla..."
rm -rf "$WORK_DIR"
cp -r /usr/share/archiso/configs/releng "$WORK_DIR"

# 3. Guardar lista de paquetes actuales en el sistema
echo "[+] Extrayendo paquetes instalados..."
pacman -Qq > "$WORK_DIR/packages.x86_64"

# 4. Copiar configuraciones personales al ISO (ejemplo: XFCE, wallpapers, etc.)
echo "[+] Copiando configuraciones de usuario..."
rsync -aAXv /etc/skel/ "$WORK_DIR/airootfs/etc/skel/"
rsync -aAXv /home/$USER/.config/ "$WORK_DIR/airootfs/etc/skel/.config/" || true

# 5. Opcional: mensaje de bienvenida
echo "Bienvenido a $ISO_NAME Live 🚀" | sudo tee "$WORK_DIR/airootfs/etc/motd"

# 6. Construir la ISO
echo "[+] Construyendo la ISO..."
mkdir -p "$OUTPUT_DIR"
cd "$WORK_DIR"
sudo mkarchiso -v -o "$OUTPUT_DIR" .

echo "[+] ISO creada en: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
