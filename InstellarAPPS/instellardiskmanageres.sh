#!/bin/bash
set -euo pipefail

# ============================================================
# Instellar OS Disk Manager (Semi-CLI) - using parted
# Added: Modify partition functionality
# ============================================================

# ---------- Colors ----------
if command -v tput >/dev/null 2>&1; then
  PURPLE="$(tput setaf 5 || true)"
  GREEN="$(tput setaf 2 || true)"
  YELLOW="$(tput setaf 3 || true)"
  RED="$(tput setaf 1 || true)"
  BOLD="$(tput bold || true)"
  DIM="$(tput dim || true)"
  RESET="$(tput sgr0 || true)"
else
  PURPLE=""; GREEN=""; YELLOW=""; RED=""; BOLD=""; DIM=""; RESET=""
fi

# ---------- State ----------
DISK=""
EFI_PART=""
ROOT_PART=""
MOUNT_DIR="/mnt"

# ---------- Safety ----------
trap 'echo -e "\n${RED}[!] Error inesperado. Revisa tu entrada o el estado del disco.${RESET}"' ERR

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo -e "${RED}[x] Ejecuta como root (sudo).${RESET}"
    exit 1
  fi
}

require_cmds() {
  local missing=()
  for c in lsblk parted blkid sed awk grep printf partprobe; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    echo -e "${RED}[x] Faltan comandos: ${missing[*]}${RESET}"
    echo "Instálalos y reintenta."
    exit 1
  fi
}

pause() { read -rp "${PURPLE}Pulsa ENTER para continuar...${RESET}"; }
confirm() {
  local msg="$1" ans=""
  read -rp "${YELLOW}${msg} [y/N]: ${RESET}" ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

header() {
  tput clear || true
  echo -e "${PURPLE}${BOLD}"
  echo " ___              _         _  _                ___   ____   "
  echo "|_ _| _ __   ___ | |_  ___ | || |  __ _  _ __  / _ \ / ___|  "
  echo " | | | '_ \ / __|| __|/ _ \| || | / _\` || '__|| | | |\___ \ "
  echo " | | | | | |\__ \| |_|  __/| || || (_| || |   | |_| | ___) | "
  echo "|___||_| |_||___/ \__|\___||_||_| \__,_||_|    \___/ |____/  "
  echo -e "\n        ${BOLD}Instellar OS Disk Manager (parted)${RESET}\n"
}

# ---------- Utils ----------
part_path_from_num() {
  local disk="$1" num="$2"
  # disk must be like /dev/sda or /dev/nvme0n1
  if [[ "$disk" =~ nvme|mmcblk|loop ]]; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

disk_has_gpt() {
  parted -s "$1" print 2>/dev/null | grep -q "gpt" || return 1
}

ensure_gpt() {
  if ! disk_has_gpt "$DISK"; then
    echo -e "${YELLOW}El disco no tiene tabla GPT.${RESET}"
    if confirm "¿Crear tabla de particiones GPT en $DISK? (Destructivo)"; then
      parted -s "$DISK" mklabel gpt
      partprobe "$DISK" || true
      echo -e "${GREEN}[+] Tabla GPT creada.${RESET}"
    else
      echo -e "${RED}[!] Operación cancelada. Algunas funciones requieren GPT.${RESET}"
    fi
  fi
}

ls_disks_cached=()
list_disks() {
  mapfile -t ls_disks_cached < <(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}')
  if ((${#ls_disks_cached[@]}==0)); then
    echo -e "${RED}[x] No se detectan discos físicos.${RESET}"
    echo "Si estás en una VM Live, asegúrate de tener un disco virtual adjunto."
    return 1
  fi
  echo -e "${GREEN}Discos disponibles:${RESET}"
  for i in "${!ls_disks_cached[@]}"; do
    local n="${ls_disks_cached[$i]}"
    local size model tran
    size=$(lsblk -d -n -o SIZE "/dev/$n")
    model=$(lsblk -d -n -o MODEL "/dev/$n" 2>/dev/null || echo "Unknown")
    tran=$(lsblk -d -n -o TRAN "/dev/$n" 2>/dev/null || echo "Unknown")
    printf "  %2d) /dev/%-10s  Tamaño: %-8s  Modelo: %-20s  Bus: %s\n" \
      "$((i+1))" "$n" "$size" "$model" "$tran"
  done
}

select_disk() {
  header
  if ! list_disks; then pause; return; fi
  local choice
  while :; do
    read -rp "${PURPLE}Selecciona disco por número: ${RESET}" choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Número inválido."; continue; }
    if (( choice >=1 && choice <= ${#ls_disks_cached[@]} )); then
      DISK="/dev/${ls_disks_cached[$((choice-1))]}"
      echo -e "${YELLOW}Seleccionado: ${DISK}${RESET}"
      confirm "Aviso: operaciones de particionado pueden afectar datos. ¿Continuar?" && break
    fi
  done
  ensure_gpt
}

list_partitions() {
  [[ -z "$DISK" ]] && { echo -e "${RED}[x] No hay disco seleccionado.${RESET}"; return; }
  echo -e "${GREEN}Particiones en ${DISK}:${RESET}"
  lsblk "$DISK" -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,PARTLABEL,PARTFLAGS
  echo
  echo -e "${DIM}Espacio libre detectado:${RESET}"
  parted -m "$DISK" unit MiB print free | awk -F: 'NR>2{printf "  %-10s %-12s %-12s %-10s\n",$1,$2,$3,$7}'
}

set_fs_label() {
  local dev="$1" label="$2"
  local fstype
  fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
  case "$fstype" in
    ext2|ext3|ext4) command -v e2label >/dev/null 2>&1 && e2label "$dev" "$label" || true ;;
    vfat|fat|fat16|fat32) command -v fatlabel >/dev/null 2>&1 && fatlabel "$dev" "$label" || (command -v dosfslabel >/dev/null 2>&1 && dosfslabel "$dev" "$label") ;;
    btrfs) command -v btrfs >/dev/null 2>&1 && btrfs filesystem label "$dev" "$label" || true ;;
    swap) command -v swaplabel >/dev/null 2>&1 && swaplabel --label "$label" "$dev" 2>/dev/null || true ;;
    *) echo -e "${YELLOW}[!] No se pudo etiquetar ($fstype no soportado/ausente).${RESET}" ;;
  esac
}

# ------------------------------
# Create (guided)
# ------------------------------
create_partition() {
  [[ -z "$DISK" ]] && { echo -e "${RED}[x] Selecciona un disco primero.${RESET}"; pause; return; }
  header
  echo -e "${BOLD}Crear partición en ${DISK}${RESET}"
  echo -e "${DIM}Tipos comunes:${RESET}"
  echo "  1) EFI  (512 MiB, FAT32, flags: boot,esp)"
  echo "  2) ROOT (tamaño personalizado, ext4)"
  echo "  3) SWAP (2 GiB por defecto)"
  echo "  4) HOME (tamaño personalizado, ext4)"
  echo "  5) Personalizado (FS, label, inicio/fin)"
  local opt; read -rp "${PURPLE}Elige tipo [1-5]: ${RESET}" opt

  local fs label start end flags size
  case "$opt" in
    1)
      fs="fat32"; label="EFI"; start="1MiB"; end="513MiB"; flags="boot,esp" ;;
    2)
      fs="ext4"; label="ROOT"
      read -rp "Tamaño ROOT (ej. 30GiB o 'resto'): " size
      if [[ "$size" == "resto" ]]; then start="0%"; end="100%"; else start="0%"; end="$size"; fi ;;
    3)
      fs="swap"; label="SWAP"
      read -rp "Tamaño SWAP (ej. 2GiB): " size; start="0%"; end="$size" ;;
    4)
      fs="ext4"; label="HOME"; read -rp "Tamaño HOME (ej. 100GiB o 'resto'): " size
      if [[ "$size" == "resto" ]]; then start="0%"; end="100%"; else start="0%"; end="$size"; fi ;;
    5)
      read -rp "Filesystem (ext4/fat32/btrfs/swap): " fs
      read -rp "Label (p.ej. DATA): " label
      echo -e "${DIM}Usa unidades (MiB/GiB) o % (ej. 1MiB 20GiB o 0% 100%).${RESET}"
      read -rp "Inicio: " start
      read -rp "Fin: " end ;;
    *)
      echo -e "${RED}[x] Opción inválida.${RESET}"; pause; return ;;
  esac

  echo
  echo -e "${YELLOW}Resumen de creación:${RESET}"
  echo "  FS:    $fs"
  echo "  Label: $label"
  echo "  Rango: $start -> $end"
  [[ -n "$flags" ]] && echo "  Flags: $flags"
  confirm "¿Crear partición?" || { echo "Cancelado."; pause; return; }

  ensure_gpt
  parted -s "$DISK" mkpart "$label" "$fs" "$start" "$end"
  partprobe "$DISK" || true

  # detect new partition number
  local lastnum
  lastnum=$(parted -m "$DISK" print | awk -F: 'NR>2 && $1 ~ /^[0-9]+$/ {n=$1} END{print n}')
  [[ -z "$lastnum" ]] && { echo -e "${RED}[!] No se pudo determinar número de partición.${RESET}"; pause; return; }
  local newpath; newpath="$(part_path_from_num "$DISK" "$lastnum")"

  if [[ -n "$flags" ]]; then
    IFS=',' read -ra F <<<"$flags"
    for f in "${F[@]}"; do parted -s "$DISK" set "$lastnum" "$f" on; done
  fi

  echo -e "${YELLOW}Formateando ${newpath} como ${fs}...${RESET}"
  case "$fs" in
    ext4) command -v mkfs.ext4 >/dev/null 2>&1 && mkfs.ext4 -F "$newpath" || { echo -e "${RED}mkfs.ext4 faltante.${RESET}"; } ;;
    fat32|vfat) command -v mkfs.fat >/dev/null 2>&1 && mkfs.fat -F32 "$newpath" || { echo -e "${RED}mkfs.fat faltante.${RESET}"; } ;;
    btrfs) command -v mkfs.btrfs >/dev/null 2>&1 && mkfs.btrfs -f "$newpath" || { echo -e "${RED}mkfs.btrfs faltante.${RESET}"; } ;;
    swap)  command -v mkswap >/dev/null 2>&1 && mkswap "$newpath" || { echo -e "${RED}mkswap faltante.${RESET}"; } ;;
    *) echo -e "${YELLOW}[!] FS desconocido: creado sin formatear.${RESET}" ;;
  esac

  if [[ "$fs" != "swap" && -n "$label" ]]; then set_fs_label "$newpath" "$label" || true; fi
  if [[ "$fs" == "swap" ]]; then mkswap -L "$label" "$newpath" >/dev/null 2>&1 || true; fi

  if [[ "$label" =~ ^EFI$|^ESP$ ]]; then EFI_PART="$newpath"; elif [[ "$label" =~ ^ROOT$ ]]; then ROOT_PART="$newpath"; fi

  echo -e "${GREEN}[+] Partición creada: ${newpath}${RESET}"
  pause
}

# ------------------------------
# Delete partition
# ------------------------------
delete_partition() {
  [[ -z "$DISK" ]] && { echo -e "${RED}[x] Selecciona un disco primero.${RESET}"; pause; return; }
  list_partitions
  local pnum; read -rp "${PURPLE}Número de partición a borrar: ${RESET}" pnum
  [[ "$pnum" =~ ^[0-9]+$ ]] || { echo "Número inválido."; pause; return; }
  local target; target="$(part_path_from_num "$DISK" "$pnum")"
  confirm "¿Borrar ${target}? (Destructivo)" || { echo "Cancelado."; pause; return; }
  umount "$target" 2>/dev/null || true
  swapoff "$target" 2>/dev/null || true
  parted -s "$DISK" rm "$pnum"
  partprobe "$DISK" || true
  echo -e "${GREEN}[+] Partición ${target} eliminada.${RESET}"
  pause
}

# ------------------------------
# Format partition
# ------------------------------
format_partition() {
  [[ -z "$DISK" ]] && { echo -e "${RED}[x] Selecciona un disco primero.${RESET}"; pause; return; }
  list_partitions
  local part fs
  read -rp "Dispositivo a formatear (ej. /dev/sda1): " part
  [[ -b "$part" ]] || { echo -e "${RED}[x] Dispositivo inválido.${RESET}"; pause; return; }
  read -rp "Filesystem (ext4/fat32/btrfs/swap): " fs
  confirm "¿Formatear ${part} como ${fs}?" || { echo "Cancelado."; pause; return; }

  umount "$part" 2>/dev/null || true
  swapoff "$part" 2>/dev/null || true

  case "$fs" in
    ext4) mkfs.ext4 -F "$part" ;;
    fat32|vfat) mkfs.fat -F32 "$part" ;;
    btrfs) mkfs.btrfs -f "$part" ;;
    swap) mkswap "$part" ;;
    *) echo -e "${RED}[x] FS desconocido.${RESET}"; pause; return ;;
  esac
  echo -e "${GREEN}[+] Formateado.${RESET}"
  pause
}

# ------------------------------
# Set flag
# ------------------------------
set_partition_flag() {
  [[ -z "$DISK" ]] && { echo -e "${RED}[x] Selecciona un disco primero.${RESET}"; pause; return; }
  list_partitions
  local pnum flag
  read -rp "Número de partición: " pnum
  read -rp "Flag (boot/esp/msftdata/lvm/raid): " flag
  parted -s "$DISK" set "$pnum" "$flag" on
  echo -e "${GREEN}[+] Flag $flag activada en partición $pnum.${RESET}"
  pause
}

# ------------------------------
# Rename partition (table & FS where possible)
# ------------------------------
rename_partition() {
  [[ -z "$DISK" ]] && { echo -e "${RED}[x] Selecciona un disco primero.${RESET}"; pause; return; }
  list_partitions
  local pnum label
  read -rp "Número de partición a renombrar: " pnum
  read -rp "Nuevo label (ej. ROOT, HOME, DATA): " label
  parted -s "$DISK" name "$pnum" "$label"
  local path; path="$(part_path_from_num "$DISK" "$pnum")"
  set_fs_label "$path" "$label" || true
  echo -e "${GREEN}[+] Renombrada en tabla y (si aplica) FS.${RESET}"
  pause
}

# ------------------------------
# Modify partition (resize + rename + flags + format)
# ------------------------------
modify_partition() {
  [[ -z "$DISK" ]] && { echo -e "${RED}[x] Selecciona un disco primero.${RESET}"; pause; return; }
  list_partitions
  local pnum
  read -rp "Número de partición a modificar: " pnum
  [[ "$pnum" =~ ^[0-9]+$ ]] || { echo "Número inválido."; pause; return; }
  local pdev; pdev="$(part_path_from_num "$DISK" "$pnum")"
  echo -e "${YELLOW}Partición seleccionada: $pdev${RESET}"
  echo "Qué quieres hacer:"
  echo "  1) Redimensionar (resize)"
  echo "  2) Renombrar label"
  echo "  3) Cambiar flags"
  echo "  4) Formatear (borrar datos)"
  echo "  5) Volver"
  read -rp "Elige [1-5]: " choice
  case "$choice" in
    1)
      echo -e "${DIM}Advertencia: redimensionar puede provocar pérdida de datos si no se hace correctamente.${RESET}"
      read -rp "Nuevo fin para la partición (ej. 30GiB o 100%): " newend
      confirm "¿Redimensionar ${pdev} hasta ${newend}? Asegúrate de respaldar datos." || { echo "Cancelado."; pause; return; }
      # parted resizepart expects partition number and end
      parted -s "$DISK" resizepart "$pnum" "$newend"
      partprobe "$DISK" || true
      echo -e "${GREEN}[+] resizepart ejecutado. Si la FS es ext4, ejecuta resize2fs dentro del sistema o desde live.${RESET}"
      pause
      ;;
    2)
      read -rp "Nuevo label: " newlabel
      confirm "¿Renombrar en tabla a ${newlabel}?" || { echo "Cancelado."; pause; return; }
      parted -s "$DISK" name "$pnum" "$newlabel"
      set_fs_label "$pdev" "$newlabel" || true
      echo -e "${GREEN}[+] Renombrada.${RESET}"; pause
      ;;
    3)
      read -rp "Flag (boot/esp/msftdata/lvm/raid): " flag
      read -rp "Estado (on/off): " state
      if [[ "$state" == "on" ]]; then parted -s "$DISK" set "$pnum" "$flag" on; else parted -s "$DISK" set "$pnum" "$flag" off; fi
      echo -e "${GREEN}[+] Flag actualizada.${RESET}"; pause
      ;;
    4)
      read -rp "FS a aplicar (ext4/fat32/btrfs/swap): " nfs
      confirm "Formatear ${pdev} como ${nfs}? Esto BORRA datos." || { echo "Cancelado."; pause; return; }
      umount "$pdev" 2>/dev/null || true
      swapoff "$pdev" 2>/dev/null || true
      case "$nfs" in
        ext4) mkfs.ext4 -F "$pdev" ;;
        fat32|vfat) mkfs.fat -F32 "$pdev" ;;
        btrfs) mkfs.btrfs -f "$pdev" ;;
        swap) mkswap "$pdev" ;;
        *) echo -e "${RED}[x] FS desconocido.${RESET}"; pause; return ;;
      esac
      echo -e "${GREEN}[+] Formateada ${pdev} como ${nfs}.${RESET}"; pause
      ;;
    5) return ;;
    *) echo "Opción inválida." ; pause ;;
  esac
}

# ------------------------------
# Choose EFI/ROOT
# ------------------------------
choose_efi() {
  list_partitions
  local p; read -rp "Dispositivo EFI (ej. /dev/sda1): " p
  [[ -b "$p" ]] || { echo "Inválido."; pause; return; }
  EFI_PART="$p"
  echo -e "${GREEN}[+] EFI = ${EFI_PART}${RESET}"; pause
}
choose_root() {
  list_partitions
  local p; read -rp "Dispositivo ROOT (ej. /dev/sda2): " p
  [[ -b "$p" ]] || { echo "Inválido."; pause; return; }
  ROOT_PART="$p"
  echo -e "${GREEN}[+] ROOT = ${ROOT_PART}${RESET}"; pause
}

# ------------------------------
# Mount / Unmount
# ------------------------------
mount_chosen() {
  [[ -z "$ROOT_PART" ]] && { echo -e "${RED}[x] Selecciona ROOT primero.${RESET}"; pause; return; }
  mkdir -p "$MOUNT_DIR"
  mount "$ROOT_PART" "$MOUNT_DIR"
  if [[ -n "$EFI_PART" ]]; then
    mkdir -p "$MOUNT_DIR/boot/efi"
    mount "$EFI_PART" "$MOUNT_DIR/boot/efi"
  fi
  echo -e "${GREEN}[+] Montado en ${MOUNT_DIR}${RESET}"; pause
}

umount_all() {
  umount -R "$MOUNT_DIR" 2>/dev/null || true
  echo -e "${GREEN}[+] Todo desmontado de ${MOUNT_DIR}${RESET}"; pause
}

# ------------------------------
# Menu
# ------------------------------
main_menu() {
  while :; do
    header
    echo -e "${BOLD}Menú del Gestor de Discos${RESET}"
    echo -e "${DIM}Consejo: las operaciones destructivas siempre piden confirmación.${RESET}\n"
    echo " 1) Seleccionar disco"
    echo " 2) Ver particiones y espacio libre"
    echo " 3) Crear partición (guiado)"
    echo " 4) Borrar partición"
    echo " 5) Formatear partición"
    echo " 6) Establecer flag en partición"
    echo " 7) Renombrar partición (label)"
    echo " 8) Modificar partición (resize/rename/flags/format)"
    echo " 9) Elegir partición EFI"
    echo "10) Elegir partición ROOT"
    echo "11) Montar EFI/ROOT en ${MOUNT_DIR}"
    echo "12) Desmontar todo de ${MOUNT_DIR}"
    echo " 0) Salir"
    echo
    [[ -n "$DISK" ]] && echo -e "${YELLOW}Disco actual: ${DISK}${RESET}"
    [[ -n "$EFI_PART" ]] && echo -e "${YELLOW}EFI: ${EFI_PART}${RESET}"
    [[ -n "$ROOT_PART" ]] && echo -e "${YELLOW}ROOT: ${ROOT_PART}${RESET}"
    echo
    local ans; read -rp "${PURPLE}Elige opción: ${RESET}" ans
    case "$ans" in
      1) select_disk ;;
      2) list_partitions; pause ;;
      3) create_partition ;;
      4) delete_partition ;;
      5) format_partition ;;
      6) set_partition_flag ;;
      7) rename_partition ;;
      8) modify_partition ;;
      9) choose_efi ;;
      10) choose_root ;;
      11) mount_chosen ;;
      12) umount_all ;;
      0) break ;;
      *) ;;
    esac
  done
}

# ------------------------------
# Run
# ------------------------------
require_root
require_cmds
main_menu


