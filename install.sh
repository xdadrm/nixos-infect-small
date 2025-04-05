#!/usr/bin/env bash

# Minimal NixOS installation script

set -e -o pipefail

makeConf() {
  # Skip if configuration already exists
  [[ -e /etc/nixos/configuration.nix ]] && return 0

  mkdir -p /etc/nixos
  
  # Get SSH keys
  local IFS=$'\n'
  for trypath in /root/.ssh/authorized_keys /home/$SUDO_USER/.ssh/authorized_keys $HOME/.ssh/authorized_keys; do
    [[ -r "$trypath" ]] \
    && keys=$(sed -E 's/^[^#].*[[:space:]]((sk-ssh|sk-ecdsa|ssh|ecdsa)-[^[:space:]]+)[[:space:]]+([^[:space:]]+)([[:space:]]*.*)$/\1 \3\4/' "$trypath") \
    && [[ ! -z "$keys" ]] \
    && break
  done

  # Use NIX_CHANNEL environment variable or default to nixos-24.05
  NIX_CHANNEL="${NIX_CHANNEL:-nixos-24.05}"
  STATE_VERSION=$(echo "$NIX_CHANNEL" | sed -E 's/nixos-([0-9]+\.[0-9]+).*/\1/')

  # Create main configuration file
  cat > /etc/nixos/configuration.nix << EOF
{ ... }: {
  imports = [
    ./hardware-configuration.nix
  ];

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
  networking.hostName = "$(hostname -s)";
  networking.domain = "$(hostname -d)";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [$(while read -r line; do
    line=$(echo -n "$line" | sed 's/\r//g')
    trimmed_line=$(echo -n "$line" | xargs)
    echo -n "''$trimmed_line'' "
  done <<< "$keys")];
  system.stateVersion = "$STATE_VERSION";
}
EOF

  # Configure boot loader
  if [ -d /sys/firmware/efi ]; then
    bootcfg=$(cat << EOF
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  fileSystems."/boot" = { device = "$esp"; fsType = "vfat"; };
EOF
)
  else
    bootcfg=$(cat << EOF
  boot.loader.grub.device = "$grubdev";
EOF
)
  fi

  # Create hardware configuration
  availableKernelModules=('"ata_piix"' '"uhci_hcd"' '"xen_blkfront"')
  if [[ "$(uname -m)" == "x86_64" ]]; then
    availableKernelModules+=('"vmw_pvscsi"')
  fi

  cat > /etc/nixos/hardware-configuration.nix << EOF
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
$bootcfg
  boot.initrd.availableKernelModules = [ ${availableKernelModules[@]} ];
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = { device = "$rootfsdev"; fsType = "$rootfstype"; };
}
EOF
}

setupSwap() {
  swapFile=$(mktemp /tmp/nixos-install.XXXXX.swp)
  dd if=/dev/zero "of=$swapFile" bs=1M count=$((1*1024))
  chmod 0600 "$swapFile"
  mkswap "$swapFile"
  swapon -v "$swapFile"
}

cleanupSwap() {
  swapoff -a
  rm -f /tmp/nixos-install.*.swp
}

prepareEnv() {
  # Identify boot device
  if [ -d /sys/firmware/efi ]; then
    for d in /boot/EFI /boot/efi /boot; do
      [[ ! -d "$d" ]] && continue
      [[ "$d" == "$(df "$d" --output=target | sed 1d)" ]] \
        && esp="$(df "$d" --output=source | sed 1d)" \
        && break
    done
    for uuid in /dev/disk/by-uuid/*; do
      [[ $(readlink -f "$uuid") == "$esp" ]] && esp=$uuid && break
    done
  else
    for grubdev in /dev/vda /dev/sda /dev/xvda /dev/nvme0n1; do 
      [[ -e $grubdev ]] && break
    done
  fi

  # Get root filesystem device and type
  rootfsdev=$(mount | grep "on / type" | awk '{print $1;}')
  rootfstype=$(df $rootfsdev --output=fstype | sed 1d)

  # Set environment variables
  export USER="root"
  export HOME="/root"

  # Use NIX_CHANNEL environment variable or default to nixos-24.05
  export NIX_CHANNEL="${NIX_CHANNEL:-nixos-24.05}"

  # Create nix directory
  mkdir -p -m 0755 /nix
}

setupNixUsers() {
  # Add nix build users
  groupadd nixbld -g 30000 || true
  for i in {1..10}; do
    useradd -c "Nix build user $i" -d /var/empty -g nixbld -G nixbld -M -N -r -s "$(which nologin)" "nixbld$i" || true
  done
}

installNix() {
  # Install Nix package manager
  curl -L "https://nixos.org/nix/install" | sh -s -- --no-channel-add

  # Source nix environment
  # shellcheck disable=SC1090
  source ~/.nix-profile/etc/profile.d/nix.sh

  # Set up NixOS channel
  nix-channel --remove nixpkgs || true
  nix-channel --add "https://nixos.org/channels/$NIX_CHANNEL" nixos
  nix-channel --update

  # Set NIXOS_CONFIG environment variable
  export NIXOS_CONFIG="/etc/nixos/configuration.nix"

  # Install NixOS - with proper paths to prevent "file 'nixos-config' was not found" error
  nix-env --set \
    -I nixpkgs="$HOME/.nix-defexpr/channels/nixos" \
    -I nixos-config="$NIXOS_CONFIG" \
    -f '<nixpkgs/nixos>' \
    -p /nix/var/nix/profiles/system \
    -A system

  # Clean up nix installer
  rm -f /nix/var/nix/profiles/default*
  /nix/var/nix/profiles/system/sw/bin/nix-collect-garbage
}

lustrateSystem() {
  # Handle resolv.conf
  [[ -L /etc/resolv.conf ]] && mv /etc/resolv.conf /etc/resolv.conf.lnk && cat /etc/resolv.conf.lnk > /etc/resolv.conf

  # Mark the system as NixOS
  touch /etc/NIXOS
  echo etc/nixos                  >> /etc/NIXOS_LUSTRATE
  echo etc/resolv.conf            >> /etc/NIXOS_LUSTRATE
  echo root/.nix-defexpr/channels >> /etc/NIXOS_LUSTRATE
  (cd / && ls etc/ssh/ssh_host_*_key* || true) >> /etc/NIXOS_LUSTRATE

  # Handle boot directory
  rm -rf /boot.bak
  if [ -d /sys/firmware/efi ]; then
    umount "$esp" || true
  fi

  mv /boot /boot.bak || { cp -a /boot /boot.bak; rm -rf /boot/*; umount /boot || true; }
  if [ -d /sys/firmware/efi ]; then
    mkdir -p /boot
    mount "$esp" /boot
    find /boot -depth ! -path /boot -exec rm -rf {} +
  fi
  
  # Activate the system
  /nix/var/nix/profiles/system/bin/switch-to-configuration boot

  # Create a cleanup script to remove /old-root after reboot
  mkdir -p /root/bin
  cat > /root/bin/cleanup_old_root << EOF
#! /usr/bin/env bash
# Script to remove /old-root directory after NixOS installation
echo "Cleaning up /old-root..."
chattr -i /old-root/etc/udev/rules.d/99-vultr-fix-virtio.rules /old-root/usr/lib/sysctl.d/90-vultr.conf 2>/dev/null || true
rm -rf /old-root
echo "Cleanup complete!"
EOF
  chmod +x /root/bin/cleanup_old_root
  
  # Remove /old-root now if possible
  echo "Attempting to clean up /old-root before reboot..."
  chattr -i /old-root/etc/udev/rules.d/99-vultr-fix-virtio.rules /old-root/usr/lib/sysctl.d/90-vultr.conf 2>/dev/null || true
  rm -rf /old-root || echo "Could not remove /old-root now. Please run /root/bin/cleanup_old_root after reboot."
}

main() {
  # Check if running as root
  [[ "$(whoami)" == "root" ]] || { echo "Error: Must run as root"; exit 1; }
  
  # Main installation process
  prepareEnv
  setupSwap
  setupNixUsers
  makeConf
  installNix
  lustrateSystem
  cleanupSwap
  
  echo "NixOS installation complete. Rebooting system..."
  reboot
}

main
