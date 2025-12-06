#!/bin/bash

MKI="/etc/mkinitcpio.conf"

info "Modifying mkinitcpio.conf..."
sudo sed -i \
  -e 's|MODULES=(btrfs)|MODULES=(btrfs nvidia nvidia_modeset nvidia_uvm nvidia_drm)|' \
  -e 's|HOOKS=(base|HOOKS=(base plymouth|' \
  "$MKI"

# Optional: enable DRM modeset (uncomment if needed)
# echo 'options nvidia_drm modeset=1' > /etc/modprobe.d/nvidia.conf

### Regenerate initramfs
info "Regenerating initramfs..."
sudo mkinitcpio -P
