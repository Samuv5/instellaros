#!/bin/bash
set -euo pipefail

# ===============================
# InstellarOS ISO Builder (Penguins' Eggs)
# ===============================

# Verificar dependencias
if ! command -v whiptail &>/dev/null; then
    echo "Instalando whiptail..."
    sudo pacman -S --needed --noconfirm libnewt
fi

if ! command -v eggs &>/dev/null; then
    whiptail --title "Dependencias" --msgbox "Debes instalar Penguins' Eggs desde AUR:\n\n yay -S penguins-eggs \n\nLuego vuelve a ejecutar este script." 12 60
    exit 1
fi

# Carpeta de salida
OUTPUT_DIR="$HOME/isos"
mkdir -p "$OUTPUT_DIR"

# Preguntar nombre de la ISO
ISO_NAME=$(whiptail --inputbox "Nombre para la ISO:" 10 60 "instellarOS" 3>&1 1>&2 2>&3)

# Preguntar compresión
COMP=$(whiptail --title "Compresión" --radiolist "Elige el tipo de compresión:" 15 60 3 \
"gzip"   "Rápido, ocupa más espacio" ON \
"xz"     "Más lento, ocupa menos espacio" OFF \
"zstd"   "Equilibrado (recomendado)" OFF 3>&1 1>&2 2>&3)

# Confirmar inicio
if whiptail --yesno "Se creará una ISO live de tu sistema:\n\nNombre: $ISO_NAME\nCompresión: $COMP\nSalida: $OUTPUT_DIR\n\n¿Continuar?" 15 60; then
    echo "[+] Iniciando snapshot con Penguins' Eggs..."
else
    echo "Cancelado."
    exit 1
fi

# Inicializar configuración si no existe
if [ ! -f /etc/eggs.d/eggs.yaml ]; then
    sudo eggs config --hostname "$ISO_NAME" --username live --fullname "InstellarOS User" --desktop xfce
fi

# Ejecutar la “puesta” (crear ISO)
sudo eggs produce --compression "$COMP" --name "$ISO_NAME"

# Mover ISO a la carpeta final
ISO_PATH=$(ls /var/lib/eggs/*.iso | tail -n1)
mv "$ISO_PATH" "$OUTPUT_DIR/"

# Mostrar mensaje final
whiptail --title "ISO creada" --msgbox "✅ ISO creada exitosamente:\n\n$OUTPUT_DIR/$ISO_NAME.iso\n\nPuedes grabarla en un USB con Ventoy o dd." 12 60
