#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MODULE_NAME="cartographer_eddy.py"
SCAFFOLDING="from cartographer.extra_eddy import *"
CARTOGRAPHER_MODULE_NAME="cartographer.py"
CARTOGRAPHER_PACKAGE_NAME="cartographer3d-plugin"
CARTOGRAPHER_SCAFFOLDING="from cartographer.extra import *"

DEFAULT_KLIPPER_DIR="$HOME/klipper"
DEFAULT_KLIPPY_ENV="$HOME/klippy-env"
DEFAULT_EDDY_NG_DIR="$HOME/eddy-ng"

EDDY_NG_REPO="https://github.com/daTobi1/eddy-ng.git"

# eddy-ng files
EDDY_NG_PYTHON_FILE="ldc1612_ng.py"
EDDY_NG_FIRMWARE_FILE="eddy-ng/sensor_ldc1612_ng.c"

function display_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "One-step installer for CartoEddy (Cartographer + eddy-ng integration)."
  echo ""
  echo "This script automatically:"
  echo "  1. Installs cartographer3d-plugin (if not already installed)"
  echo "  2. Clones eddy-ng (if not already cloned)"
  echo "  3. Installs eddy-ng Python files (without patching Klipper)"
  echo "  4. Copies CartoEddy adapter files into the cartographer package"
  echo "  5. Creates the cartographer_eddy.py scaffolding"
  echo "  6. Reverts any old eddy-ng patches (bed_mesh.py, Makefile)"
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
  local name="${2:-$dir}"
  if [ ! -d "$dir" ]; then
    echo "Error: $name directory '$dir' does not exist."
    exit 1
  fi
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

function get_cartographer_package_dir() {
  cartographer_pkg_dir=$("$klippy_env/bin/python" -c "
import cartographer
import os
print(os.path.dirname(cartographer.__file__))
" 2>/dev/null) || true
  if [ -z "$cartographer_pkg_dir" ] || [ ! -d "$cartographer_pkg_dir" ]; then
    echo "Error: Could not locate cartographer package in '$klippy_env'."
    exit 1
  fi
}

# ──────────────────────────────────────────────────────────────
# Phase 1: Install cartographer3d-plugin from PyPI
# ──────────────────────────────────────────────────────────────

function ensure_numpy() {
  "$klippy_env/bin/python" -c "
import sys
try:
    import numpy
    version = tuple(map(int, numpy.__version__.split('.')[:2]))
    if version >= (1, 16):
        print(f'  numpy {numpy.__version__} OK')
        sys.exit(0)
    else:
        print(f'  numpy {numpy.__version__} too old, upgrading...')
        sys.exit(1)
except ImportError:
    print('  numpy not found, installing...')
    sys.exit(1)
" || "$klippy_env/bin/pip" install "numpy~=1.16"
}

function remove_legacy_cartographer_files() {
  local files=("idm.py" "scanner.py" "cartographer.py")
  local paths=("$klipper_dir/klippy/extras" "$klipper_dir/klippy/plugins")

  for dir in "${paths[@]}"; do
    [ ! -d "$dir" ] && continue
    for file in "${files[@]}"; do
      local full_path="$dir/$file"
      local rel_path="${dir#"$klipper_dir"/}/$file"
      if [ -f "$full_path" ] || [ -L "$full_path" ]; then
        rm "$full_path"
        echo "  Removed legacy: $rel_path"
        local exclude_file="$klipper_dir/.git/info/exclude"
        if [ -f "$exclude_file" ]; then
          sed -i "\|^$rel_path\$|d" "$exclude_file" 2>/dev/null || true
        fi
      fi
    done
  done
}

function install_cartographer() {
  # Check if already installed
  local installed_version
  installed_version=$("$klippy_env/bin/python" -c "
import cartographer
print(cartographer.__version__)
" 2>/dev/null) || true

  if [ -n "$installed_version" ]; then
    echo "  Cartographer $installed_version already installed, upgrading..."
  else
    echo "  Cartographer not found, installing..."
  fi

  remove_legacy_cartographer_files

  ensure_numpy
  "$klippy_env/bin/pip" install --upgrade "$CARTOGRAPHER_PACKAGE_NAME" 2>&1 | tail -1
  echo "  $CARTOGRAPHER_PACKAGE_NAME installed."

  # Create cartographer scaffolding
  local scaffolding_path="$extras_dir/$CARTOGRAPHER_MODULE_NAME"
  local scaffolding_rel_path="${extras_dir#"$klipper_dir"/}/$CARTOGRAPHER_MODULE_NAME"

  if [ -L "$scaffolding_path" ]; then
    rm "$scaffolding_path"
  fi
  echo "$CARTOGRAPHER_SCAFFOLDING" >"$scaffolding_path"
  add_to_git_exclude "$scaffolding_rel_path"
  echo "  Created scaffolding: $CARTOGRAPHER_MODULE_NAME"
}

# ──────────────────────────────────────────────────────────────
# Phase 2: Clone & install eddy-ng
# ──────────────────────────────────────────────────────────────

function ensure_eddy_ng_repo() {
  if [ -d "$eddy_ng_dir" ]; then
    echo "  eddy-ng repo found at $eddy_ng_dir"
    return
  fi

  echo "  Cloning eddy-ng..."
  git clone "$EDDY_NG_REPO" "$eddy_ng_dir" 2>&1 | while IFS= read -r line; do echo "    $line"; done
  echo "  eddy-ng cloned to $eddy_ng_dir"
}

function install_eddy_ng_files() {
  # Copy Python driver
  local src="$eddy_ng_dir/$EDDY_NG_PYTHON_FILE"
  if [ ! -f "$src" ]; then
    echo "Error: $EDDY_NG_PYTHON_FILE not found in $eddy_ng_dir"
    exit 1
  fi
  cp "$src" "$extras_dir/$EDDY_NG_PYTHON_FILE"
  add_to_git_exclude "${extras_dir#"$klipper_dir"/}/$EDDY_NG_PYTHON_FILE"
  echo "  Copied $EDDY_NG_PYTHON_FILE"

  # Copy firmware C file
  local fw_src="$eddy_ng_dir/$EDDY_NG_FIRMWARE_FILE"
  if [ -f "$fw_src" ]; then
    cp "$fw_src" "$klipper_dir/src/$(basename "$EDDY_NG_FIRMWARE_FILE")"
    add_to_git_exclude "src/$(basename "$EDDY_NG_FIRMWARE_FILE")"
    echo "  Copied $(basename "$EDDY_NG_FIRMWARE_FILE")"
  fi
}

# ──────────────────────────────────────────────────────────────
# Phase 3: Install CartoEddy adapter files
# ──────────────────────────────────────────────────────────────

function install_eddy_adapter_files() {
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

function create_scaffolding() {
  local scaffolding_path="$extras_dir/$MODULE_NAME"
  local scaffolding_rel_path="${extras_dir#"$klipper_dir"/}/$MODULE_NAME"

  if [ -L "$scaffolding_path" ]; then
    rm "$scaffolding_path"
  fi

  echo "$SCAFFOLDING" >"$scaffolding_path"
  add_to_git_exclude "$scaffolding_rel_path"
  echo "  Created scaffolding: $MODULE_NAME"
}

# ──────────────────────────────────────────────────────────────
# Clean up old eddy-ng patches
# ──────────────────────────────────────────────────────────────

function clean_old_patches() {
  cd "$klipper_dir"

  local old_patched_files=("klippy/extras/bed_mesh.py" "src/Makefile")

  for f in "${old_patched_files[@]}"; do
    git update-index --no-assume-unchanged "$f" 2>/dev/null || true
    if ! git diff --quiet "$f" 2>/dev/null; then
      git checkout -- "$f"
      echo "  Reverted old patch: $f"
    fi
  done
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

  check_directory_exists "$klipper_dir" "Klipper"
  check_directory_exists "$klippy_env" "klippy-env"
  get_extras_dir

  if [ "$uninstall" = true ]; then
    uninstall_eddy
    return
  fi

  echo ""
  echo "Installing CartoEddy..."
  echo ""

  # Phase 1: Cartographer
  echo "--- Cartographer ---"
  install_cartographer

  # Phase 2: eddy-ng
  echo ""
  echo "--- eddy-ng ---"
  ensure_eddy_ng_repo
  clean_old_patches
  install_eddy_ng_files

  # Phase 3: CartoEddy adapter
  echo ""
  echo "--- CartoEddy ---"
  get_cartographer_package_dir
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
}

main "$@"
