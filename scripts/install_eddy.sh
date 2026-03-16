#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MODULE_NAME="cartographer_eddy.py"
SCAFFOLDING="from cartographer.extra_eddy import *"
DEFAULT_KLIPPER_DIR="$HOME/klipper"
DEFAULT_KLIPPY_ENV="$HOME/klippy-env"

function display_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Installs the Cartographer Eddy integration."
  echo ""
  echo "This script:"
  echo "  1. Copies Eddy adapter files into the installed cartographer package"
  echo "  2. Creates the cartographer_eddy.py scaffolding in klippy/extras/"
  echo ""
  echo "Prerequisites:"
  echo "  - eddy-ng must already be installed (ldc1612_ng.py in klippy/extras/)"
  echo "  - cartographer3d-plugin must already be installed (run its install.sh first)"
  echo ""
  echo "Options:"
  echo "  -k, --klipper       Set the Klipper directory (default: $DEFAULT_KLIPPER_DIR)"
  echo "  -e, --klippy-env    Set the Klippy virtual environment directory (default: $DEFAULT_KLIPPY_ENV)"
  echo "  --uninstall         Remove all CartoEddy files and scaffolding"
  echo "  --help              Show this help message and exit"
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

function check_prerequisites() {
  # Check that eddy-ng is installed
  local eddy_found=false
  for dir in "$klipper_dir/klippy/extras" "$klipper_dir/klippy/plugins"; do
    if [ -f "$dir/ldc1612_ng.py" ]; then
      eddy_found=true
      echo "Found eddy-ng at: $dir/ldc1612_ng.py"
      break
    fi
  done
  if [ "$eddy_found" = false ]; then
    echo "Error: eddy-ng not found. ldc1612_ng.py must be in klippy/extras/ or klippy/plugins/."
    echo "Install eddy-ng first: https://github.com/daTobi1/eddy-ng"
    exit 1
  fi

  # Check that cartographer3d-plugin is installed
  get_cartographer_package_dir
}

function install_eddy_files() {
  echo "Installing Eddy adapter files into cartographer package..."

  # Create eddy adapter directory
  local eddy_dir="$cartographer_pkg_dir/adapters/eddy"
  mkdir -p "$eddy_dir"

  # Copy adapter files
  cp "$REPO_DIR/src/cartographer/adapters/eddy/__init__.py" "$eddy_dir/"
  cp "$REPO_DIR/src/cartographer/adapters/eddy/mcu.py" "$eddy_dir/"
  cp "$REPO_DIR/src/cartographer/adapters/eddy/configuration.py" "$eddy_dir/"
  cp "$REPO_DIR/src/cartographer/adapters/eddy/integrator.py" "$eddy_dir/"
  cp "$REPO_DIR/src/cartographer/adapters/eddy/toolhead.py" "$eddy_dir/"
  cp "$REPO_DIR/src/cartographer/adapters/eddy/adapters.py" "$eddy_dir/"
  echo "  Copied adapters/eddy/ (6 files)"

  # Copy entry point
  cp "$REPO_DIR/src/cartographer/extra_eddy.py" "$cartographer_pkg_dir/"
  echo "  Copied extra_eddy.py"

  # Copy modified runtime files
  cp "$REPO_DIR/src/cartographer/runtime/loader.py" "$cartographer_pkg_dir/runtime/"
  cp "$REPO_DIR/src/cartographer/runtime/environment.py" "$cartographer_pkg_dir/runtime/"
  echo "  Updated runtime/loader.py and runtime/environment.py"

  echo "Eddy adapter files installed."
}

function create_scaffolding() {
  if [ -d "$klipper_dir/klippy/plugins" ]; then
    scaffolding_dir="$klipper_dir/klippy/plugins"
    use_git_exclude=false
  else
    scaffolding_dir="$klipper_dir/klippy/extras"
    use_git_exclude=true
  fi

  scaffolding_path="$scaffolding_dir/$MODULE_NAME"
  scaffolding_rel_path="${scaffolding_dir#"$klipper_dir"/}/$MODULE_NAME"

  check_directory_exists "$scaffolding_dir"

  if [ -L "$scaffolding_path" ]; then
    local original_target
    original_target=$(readlink "$scaffolding_path")
    echo "Warning: '$scaffolding_path' is a symlink and will be removed."
    rm "$scaffolding_path"
  fi

  echo "$SCAFFOLDING" >"$scaffolding_path"
  echo "Created scaffolding: $scaffolding_path"

  if [ "$use_git_exclude" = true ]; then
    local exclude_file="$klipper_dir/.git/info/exclude"
    if [ -d "$klipper_dir/.git" ] && ! grep -qF "$scaffolding_rel_path" "$exclude_file" >/dev/null 2>&1; then
      echo "$scaffolding_rel_path" >>"$exclude_file"
      echo "Added '$scaffolding_rel_path' to git exclude."
    fi
  fi
}

function uninstall_eddy() {
  echo "Uninstalling CartoEddy..."

  # Remove scaffolding
  local paths=(
    "$klipper_dir/klippy/extras"
    "$klipper_dir/klippy/plugins"
  )

  for dir in "${paths[@]}"; do
    if [ ! -d "$dir" ]; then
      continue
    fi

    local full_path="$dir/$MODULE_NAME"
    local rel_path="${dir#"$klipper_dir"/}/$MODULE_NAME"

    if [ -f "$full_path" ] || [ -L "$full_path" ]; then
      echo "Removing scaffolding: $full_path"
      rm "$full_path"

      local exclude_file="$klipper_dir/.git/info/exclude"
      if [ -f "$exclude_file" ]; then
        sed -i "\|^$rel_path\$|d" "$exclude_file" 2>/dev/null || true
      fi
    fi
  done

  # Remove eddy files from cartographer package (if it exists)
  get_cartographer_package_dir 2>/dev/null || true
  if [ -n "${cartographer_pkg_dir:-}" ] && [ -d "$cartographer_pkg_dir" ]; then
    if [ -d "$cartographer_pkg_dir/adapters/eddy" ]; then
      echo "Removing adapters/eddy/ from cartographer package"
      rm -rf "$cartographer_pkg_dir/adapters/eddy"
    fi
    if [ -f "$cartographer_pkg_dir/extra_eddy.py" ]; then
      echo "Removing extra_eddy.py from cartographer package"
      rm "$cartographer_pkg_dir/extra_eddy.py"
    fi
  fi

  echo "CartoEddy uninstalled."
  echo "Note: runtime/loader.py and runtime/environment.py were modified but not reverted."
  echo "Re-install cartographer3d-plugin to restore originals if needed."
}

function main() {
  klipper_dir="$DEFAULT_KLIPPER_DIR"
  klippy_env="$DEFAULT_KLIPPY_ENV"

  parse_args "$@"

  check_directory_exists "$klipper_dir"

  if [ "$uninstall" = true ]; then
    uninstall_eddy
  else
    check_prerequisites
    install_eddy_files
    create_scaffolding
    echo ""
    echo "========================================="
    echo " CartoEddy installed successfully!"
    echo "========================================="
    echo ""
    echo "Next steps:"
    echo "  1. Add [cartographer_eddy] section to your printer.cfg"
    echo "  2. Remove any existing [probe_eddy_ng] section"
    echo "  3. Restart Klipper"
    echo "  4. Run: CARTOGRAPHER_SCAN_CALIBRATE METHOD=TOUCH"
    echo ""
    echo "See README.md for full configuration reference."
  fi
}

main "$@"
