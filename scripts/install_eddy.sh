#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MODULE_NAME="cartographer_eddy.py"
SCAFFOLDING="from cartographer.extra_eddy import *"
DEFAULT_KLIPPER_DIR="$HOME/klipper"
DEFAULT_KLIPPY_ENV="$HOME/klippy-env"
DEFAULT_EDDY_NG_DIR="$HOME/eddy-ng"

# eddy-ng Python file needed in klippy/extras/
EDDY_NG_PYTHON_FILE="ldc1612_ng.py"

# eddy-ng firmware file
EDDY_NG_FIRMWARE_FILE="eddy-ng/sensor_ldc1612_ng.c"

function display_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Installs the Cartographer Eddy integration."
  echo ""
  echo "This script:"
  echo "  1. Installs eddy-ng Python files (without patching Klipper)"
  echo "  2. Copies CartoEddy adapter files into the cartographer package"
  echo "  3. Creates the cartographer_eddy.py scaffolding in klippy/extras/"
  echo "  4. Reverts any old eddy-ng patches (bed_mesh.py, Makefile)"
  echo ""
  echo "Prerequisites:"
  echo "  - eddy-ng repository cloned (default: ~/eddy-ng)"
  echo "  - cartographer3d-plugin must already be installed"
  echo ""
  echo "Options:"
  echo "  -k, --klipper       Klipper directory (default: $DEFAULT_KLIPPER_DIR)"
  echo "  -e, --klippy-env    Klippy virtual environment (default: $DEFAULT_KLIPPY_ENV)"
  echo "  --eddy-ng           eddy-ng directory (default: $DEFAULT_EDDY_NG_DIR)"
  echo "  --uninstall         Remove all CartoEddy files and scaffolding"
  echo "  --help              Show this help message"
  echo ""
  exit 0
}

function parse_args() {
  uninstall=false
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
    -k | --klipper)
      klipper_dir="$2"
      shift 2
      ;;
    -e | --klippy-env)
      klippy_env="$2"
      shift 2
      ;;
    --eddy-ng)
      eddy_ng_dir="$2"
      shift 2
      ;;
    --uninstall)
      uninstall=true
      shift
      ;;
    --help)
      display_help
      ;;
    *)
      echo "Unknown option: $1"
      display_help
      ;;
    esac
  done
}

function check_directory_exists() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "Error: Directory '$dir' does not exist."
    exit 1
  fi
}

function get_cartographer_package_dir() {
  cartographer_pkg_dir=$("$klippy_env/bin/python" -c "
import cartographer
import os
print(os.path.dirname(cartographer.__file__))
" 2>/dev/null)
  if [ -z "$cartographer_pkg_dir" ] || [ ! -d "$cartographer_pkg_dir" ]; then
    echo "Error: Could not locate cartographer package in '$klippy_env'."
    echo "Make sure cartographer3d-plugin is installed."
    exit 1
  fi
  echo "Found cartographer package at: $cartographer_pkg_dir"
}

function get_extras_dir() {
  if [ -d "$klipper_dir/klippy/plugins" ]; then
    extras_dir="$klipper_dir/klippy/plugins"
    use_git_exclude=false
  else
    extras_dir="$klipper_dir/klippy/extras"
    use_git_exclude=true
  fi
}

function add_to_git_exclude() {
  local rel_path="$1"
  if [ "$use_git_exclude" = true ]; then
    local exclude_file="$klipper_dir/.git/info/exclude"
    if [ -d "$klipper_dir/.git" ] && ! grep -qF "$rel_path" "$exclude_file" 2>/dev/null; then
      echo "$rel_path" >>"$exclude_file"
    fi
  fi
}

# ──────────────────────────────────────────────────────────────
# Clean up old eddy-ng patches (bed_mesh.py + Makefile)
# CartoEddy does NOT need these patches.
# ──────────────────────────────────────────────────────────────

function clean_old_patches() {
  echo "Checking for old eddy-ng patches..."
  cd "$klipper_dir"

  local old_patched_files=("klippy/extras/bed_mesh.py" "src/Makefile")
  local cleaned=false

  for f in "${old_patched_files[@]}"; do
    # Lift assume-unchanged if set
    git update-index --no-assume-unchanged "$f" 2>/dev/null || true

    # Revert if modified
    if ! git diff --quiet "$f" 2>/dev/null; then
      git checkout -- "$f"
      echo "  Reverted old patch: $f"
      cleaned=true
    fi
  done

  if [ "$cleaned" = true ]; then
    echo "  Old eddy-ng patches removed (CartoEddy doesn't need them)."
  else
    echo "  No old patches found."
  fi
}

# ──────────────────────────────────────────────────────────────
# Install eddy-ng Python files (without Klipper patches)
# ──────────────────────────────────────────────────────────────

function install_eddy_ng_files() {
  echo "Installing eddy-ng files (patch-free)..."

  # Copy Python driver
  local src="$eddy_ng_dir/$EDDY_NG_PYTHON_FILE"
  local dest="$extras_dir/$EDDY_NG_PYTHON_FILE"
  if [ ! -f "$src" ]; then
    echo "Error: eddy-ng not found at $eddy_ng_dir"
    echo "Clone it first: git clone https://github.com/daTobi1/eddy-ng.git $eddy_ng_dir"
    exit 1
  fi
  cp "$src" "$dest"
  add_to_git_exclude "${extras_dir#"$klipper_dir"/}/$EDDY_NG_PYTHON_FILE"
  echo "  Copied $EDDY_NG_PYTHON_FILE → $extras_dir/"

  # Copy firmware C file
  local fw_src="$eddy_ng_dir/$EDDY_NG_FIRMWARE_FILE"
  local fw_dest="$klipper_dir/src/$(basename "$EDDY_NG_FIRMWARE_FILE")"
  if [ -f "$fw_src" ]; then
    cp "$fw_src" "$fw_dest"
    add_to_git_exclude "src/$(basename "$EDDY_NG_FIRMWARE_FILE")"
    echo "  Copied $(basename "$EDDY_NG_FIRMWARE_FILE") → src/"
  fi

  echo "  eddy-ng installed (no Klipper patches applied)."
}

# ──────────────────────────────────────────────────────────────
# Install CartoEddy adapter files
# ──────────────────────────────────────────────────────────────

function install_eddy_adapter_files() {
  echo "Installing CartoEddy adapter files into cartographer package..."

  local eddy_dir="$cartographer_pkg_dir/adapters/eddy"
  mkdir -p "$eddy_dir"

  cp "$REPO_DIR/src/cartographer/adapters/eddy/__init__.py" "$eddy_dir/"
  cp "$REPO_DIR/src/cartographer/adapters/eddy/mcu.py" "$eddy_dir/"
  cp "$REPO_DIR/src/cartographer/adapters/eddy/configuration.py" "$eddy_dir/"
  cp "$REPO_DIR/src/cartographer/adapters/eddy/integrator.py" "$eddy_dir/"
  cp "$REPO_DIR/src/cartographer/adapters/eddy/toolhead.py" "$eddy_dir/"
  cp "$REPO_DIR/src/cartographer/adapters/eddy/adapters.py" "$eddy_dir/"
  echo "  Copied adapters/eddy/ (6 files)"

  cp "$REPO_DIR/src/cartographer/extra_eddy.py" "$cartographer_pkg_dir/"
  echo "  Copied extra_eddy.py"

  cp "$REPO_DIR/src/cartographer/runtime/loader.py" "$cartographer_pkg_dir/runtime/"
  cp "$REPO_DIR/src/cartographer/runtime/environment.py" "$cartographer_pkg_dir/runtime/"
  echo "  Updated runtime/loader.py and runtime/environment.py"
}

# ──────────────────────────────────────────────────────────────
# Create scaffolding file
# ──────────────────────────────────────────────────────────────

function create_scaffolding() {
  local scaffolding_path="$extras_dir/$MODULE_NAME"
  local scaffolding_rel_path="${extras_dir#"$klipper_dir"/}/$MODULE_NAME"

  if [ -L "$scaffolding_path" ]; then
    rm "$scaffolding_path"
  fi

  echo "$SCAFFOLDING" >"$scaffolding_path"
  add_to_git_exclude "$scaffolding_rel_path"
  echo "  Created scaffolding: $scaffolding_path"
}

# ──────────────────────────────────────────────────────────────
# Uninstall
# ──────────────────────────────────────────────────────────────

function uninstall_eddy() {
  echo "Uninstalling CartoEddy..."

  get_extras_dir

  # Remove scaffolding
  local scaffolding="$extras_dir/$MODULE_NAME"
  if [ -f "$scaffolding" ] || [ -L "$scaffolding" ]; then
    echo "  Removing scaffolding: $scaffolding"
    rm "$scaffolding"
  fi

  # Remove eddy files from cartographer package
  get_cartographer_package_dir 2>/dev/null || true
  if [ -n "${cartographer_pkg_dir:-}" ] && [ -d "$cartographer_pkg_dir" ]; then
    if [ -d "$cartographer_pkg_dir/adapters/eddy" ]; then
      echo "  Removing adapters/eddy/"
      rm -rf "$cartographer_pkg_dir/adapters/eddy"
    fi
    if [ -f "$cartographer_pkg_dir/extra_eddy.py" ]; then
      echo "  Removing extra_eddy.py"
      rm "$cartographer_pkg_dir/extra_eddy.py"
    fi
  fi

  # Clean up any remaining patches
  clean_old_patches

  echo ""
  echo "CartoEddy uninstalled."
  echo "Note: eddy-ng files (ldc1612_ng.py, sensor_ldc1612_ng.c) were not removed."
  echo "Note: runtime/loader.py was modified — re-install cartographer to restore."
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

function main() {
  klipper_dir="$DEFAULT_KLIPPER_DIR"
  klippy_env="$DEFAULT_KLIPPY_ENV"
  eddy_ng_dir="$DEFAULT_EDDY_NG_DIR"

  parse_args "$@"

  check_directory_exists "$klipper_dir"
  get_extras_dir

  if [ "$uninstall" = true ]; then
    uninstall_eddy
  else
    # Verify cartographer is installed
    get_cartographer_package_dir

    # Clean old patches, install fresh
    clean_old_patches
    install_eddy_ng_files
    install_eddy_adapter_files
    create_scaffolding

    echo ""
    echo "========================================="
    echo " CartoEddy installed successfully!"
    echo "========================================="
    echo ""
    echo "Klipper repo is CLEAN — no dirty-repo warnings."
    echo ""
    echo "Next steps:"
    echo "  1. Add [cartographer_eddy] section to your printer.cfg"
    echo "  2. Remove any existing [probe_eddy_ng] section"
    echo "  3. Restart Klipper"
    echo "  4. Run: CARTOGRAPHER_SCAN_CALIBRATE METHOD=TOUCH"
    echo ""
    echo "First-time firmware build:"
    echo "  cd $klipper_dir"
    echo "  # The update script handles the Makefile patch temporarily:"
    echo "  cd $(dirname "$SCRIPT_DIR") && ./scripts/update.sh --flash --skip-klipper --skip-cartographer --skip-cartoeddy"
    echo ""
  fi
}

main "$@"
