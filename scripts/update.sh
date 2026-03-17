#!/bin/bash

set -euo pipefail

# =========================================================================
# CartoEddy Full Update Script
#
# Automates the complete update of Klipper + eddy-ng + Cartographer +
# CartoEddy WITHOUT leaving a dirty Klipper repo.
#
# Key insight: CartoEddy does NOT need eddy-ng's bed_mesh.py patch
# (Cartographer has its own BED_MESH_CALIBRATE implementation).
# The Makefile patch is only needed during firmware compilation.
#
# Strategy:
#   - Install eddy-ng Python files directly (no patches)
#   - Keep Klipper repo 100% clean
#   - Provide --flash option for firmware rebuilds (temp-patches Makefile)
# =========================================================================

DEFAULT_KLIPPER_DIR="$HOME/klipper"
DEFAULT_KLIPPY_ENV="$HOME/klippy-env"
DEFAULT_EDDY_NG_DIR="$HOME/eddy-ng"
DEFAULT_CARTOGRAPHER_DIR="$HOME/cartographer3d-plugin"
DEFAULT_CARTOEDDY_DIR="$HOME/cartoeddy"

# eddy-ng Python files to copy into klippy/extras/
EDDY_NG_PYTHON_FILES=(
  "ldc1612_ng.py"
)

# eddy-ng firmware file
EDDY_NG_FIRMWARE_FILE="eddy-ng/sensor_ldc1612_ng.c"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function display_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Fully automated update of Klipper + eddy-ng + Cartographer + CartoEddy."
  echo "Keeps the Klipper repo clean — no dirty-repo warnings in Moonraker."
  echo ""
  echo "Options:"
  echo "  -k, --klipper           Klipper directory (default: $DEFAULT_KLIPPER_DIR)"
  echo "  -e, --klippy-env        Klippy virtual environment (default: $DEFAULT_KLIPPY_ENV)"
  echo "  --eddy-ng               eddy-ng directory (default: $DEFAULT_EDDY_NG_DIR)"
  echo "  --cartographer          cartographer3d-plugin directory (default: $DEFAULT_CARTOGRAPHER_DIR)"
  echo "  --cartoeddy             cartoeddy directory (default: $DEFAULT_CARTOEDDY_DIR)"
  echo "  --flash                 Also rebuild & flash MCU firmware (applies Makefile patch temporarily)"
  echo "  --skip-klipper          Skip Klipper git pull"
  echo "  --skip-eddy-ng          Skip eddy-ng update"
  echo "  --skip-cartographer     Skip Cartographer update"
  echo "  --skip-cartoeddy        Skip CartoEddy update"
  echo "  --skip-restart          Skip Klipper service restart"
  echo "  --help                  Show this help message"
  echo ""
  echo "Firmware note:"
  echo "  The Makefile patch for sensor_ldc1612_ng.c is only applied during --flash"
  echo "  and reverted immediately after. The Klipper repo stays clean at all times."
  echo ""
  exit 0
}

function log_step() {
  echo -e "${BLUE}━━━ $1${NC}"
}

function log_ok() {
  echo -e "  ${GREEN}✓${NC} $1"
}

function log_warn() {
  echo -e "  ${YELLOW}⚠${NC} $1"
}

function log_error() {
  echo -e "  ${RED}✗${NC} $1"
}

function parse_args() {
  skip_klipper=false
  skip_eddy_ng=false
  skip_cartographer=false
  skip_cartoeddy=false
  skip_restart=false
  do_flash=false

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
    -k | --klipper)         klipper_dir="$2";       shift 2 ;;
    -e | --klippy-env)      klippy_env="$2";        shift 2 ;;
    --eddy-ng)              eddy_ng_dir="$2";       shift 2 ;;
    --cartographer)         cartographer_dir="$2";  shift 2 ;;
    --cartoeddy)            cartoeddy_dir="$2";     shift 2 ;;
    --flash)                do_flash=true;           shift ;;
    --skip-klipper)         skip_klipper=true;      shift ;;
    --skip-eddy-ng)         skip_eddy_ng=true;      shift ;;
    --skip-cartographer)    skip_cartographer=true;  shift ;;
    --skip-cartoeddy)       skip_cartoeddy=true;    shift ;;
    --skip-restart)         skip_restart=true;       shift ;;
    --help) display_help ;;
    *)
      echo "Unknown option: $1"
      display_help
      ;;
    esac
  done
}

function check_dir() {
  local name="$1"
  local dir="$2"
  if [ ! -d "$dir" ]; then
    log_error "$name directory not found: $dir"
    return 1
  fi
  return 0
}

# ──────────────────────────────────────────────────────────────
# Clean up: Undo any leftover eddy-ng patches from old installs
# ──────────────────────────────────────────────────────────────

function clean_old_patches() {
  log_step "Cleaning old eddy-ng patches (if any)"
  cd "$klipper_dir"

  local old_patched_files=("klippy/extras/bed_mesh.py" "src/Makefile")

  for f in "${old_patched_files[@]}"; do
    # Lift assume-unchanged if set
    git update-index --no-assume-unchanged "$f" 2>/dev/null || true

    # Revert if modified
    if ! git diff --quiet "$f" 2>/dev/null; then
      git checkout -- "$f"
      log_ok "Reverted old patch: $f"
    fi
  done

  log_ok "Klipper repo is clean"
}

# ──────────────────────────────────────────────────────────────
# Update Klipper
# ──────────────────────────────────────────────────────────────

function update_klipper() {
  if [ "$skip_klipper" = true ]; then
    log_step "Skipping Klipper update (--skip-klipper)"
    return
  fi

  log_step "Updating Klipper"
  cd "$klipper_dir"

  local before
  before=$(git rev-parse --short HEAD)

  git pull --ff-only 2>&1 | while IFS= read -r line; do echo "  $line"; done

  local after
  after=$(git rev-parse --short HEAD)

  if [ "$before" = "$after" ]; then
    log_ok "Already up to date ($after)"
  else
    log_ok "Updated $before → $after"
  fi
}

# ──────────────────────────────────────────────────────────────
# Update & install eddy-ng (Python files only — no Klipper patches)
# ──────────────────────────────────────────────────────────────

function update_eddy_ng() {
  if [ "$skip_eddy_ng" = true ]; then
    log_step "Skipping eddy-ng update (--skip-eddy-ng)"
    return
  fi

  if ! check_dir "eddy-ng" "$eddy_ng_dir"; then
    log_warn "Skipping eddy-ng update"
    return
  fi

  log_step "Updating eddy-ng"
  cd "$eddy_ng_dir"

  local before
  before=$(git rev-parse --short HEAD)

  git pull 2>&1 | while IFS= read -r line; do echo "  $line"; done

  local after
  after=$(git rev-parse --short HEAD)

  if [ "$before" = "$after" ]; then
    log_ok "Already up to date ($after)"
  else
    log_ok "Updated $before → $after"
  fi

  log_step "Installing eddy-ng Python files (no Klipper patches)"

  # Determine target directory
  local extras_dir
  if [ -d "$klipper_dir/klippy/plugins" ]; then
    extras_dir="$klipper_dir/klippy/plugins"
  else
    extras_dir="$klipper_dir/klippy/extras"
  fi

  # Copy Python driver files
  for f in "${EDDY_NG_PYTHON_FILES[@]}"; do
    local src="$eddy_ng_dir/$f"
    local dest="$extras_dir/$(basename "$f")"
    if [ -f "$src" ]; then
      cp "$src" "$dest"
      log_ok "Copied $f → $extras_dir/"
    else
      log_error "Source file not found: $src"
    fi
  done

  # Copy firmware C file (needed for --flash, doesn't dirty the repo)
  local fw_src="$eddy_ng_dir/$EDDY_NG_FIRMWARE_FILE"
  local fw_dest="$klipper_dir/src/$(basename "$EDDY_NG_FIRMWARE_FILE")"
  if [ -f "$fw_src" ]; then
    cp "$fw_src" "$fw_dest"
    log_ok "Copied $(basename "$EDDY_NG_FIRMWARE_FILE") → src/"

    # Add to git exclude so it doesn't show as untracked
    local exclude_file="$klipper_dir/.git/info/exclude"
    local fw_rel="src/$(basename "$EDDY_NG_FIRMWARE_FILE")"
    if [ -d "$klipper_dir/.git" ] && ! grep -qF "$fw_rel" "$exclude_file" 2>/dev/null; then
      echo "$fw_rel" >>"$exclude_file"
      log_ok "Added $fw_rel to git exclude"
    fi
  fi

  # Add Python files to git exclude
  for f in "${EDDY_NG_PYTHON_FILES[@]}"; do
    local rel_path="${extras_dir#"$klipper_dir"/}/$(basename "$f")"
    local exclude_file="$klipper_dir/.git/info/exclude"
    if [ -d "$klipper_dir/.git" ] && ! grep -qF "$rel_path" "$exclude_file" 2>/dev/null; then
      echo "$rel_path" >>"$exclude_file"
    fi
  done

  log_ok "eddy-ng installed (Python files only, no Klipper patches)"
}

# ──────────────────────────────────────────────────────────────
# Update & re-install Cartographer
# ──────────────────────────────────────────────────────────────

function update_cartographer() {
  if [ "$skip_cartographer" = true ]; then
    log_step "Skipping Cartographer update (--skip-cartographer)"
    return
  fi

  if ! check_dir "Cartographer" "$cartographer_dir"; then
    log_warn "Skipping Cartographer update"
    return
  fi

  log_step "Updating Cartographer"
  cd "$cartographer_dir"

  local before
  before=$(git rev-parse --short HEAD)

  git pull 2>&1 | while IFS= read -r line; do echo "  $line"; done

  local after
  after=$(git rev-parse --short HEAD)

  if [ "$before" = "$after" ]; then
    log_ok "Already up to date ($after)"
  else
    log_ok "Updated $before → $after"
  fi

  log_step "Re-installing Cartographer into klippy-env"
  ./scripts/install.sh -k "$klipper_dir" -e "$klippy_env" 2>&1 | while IFS= read -r line; do echo "  $line"; done
  log_ok "Cartographer installed"
}

# ──────────────────────────────────────────────────────────────
# Update & re-install CartoEddy
# ──────────────────────────────────────────────────────────────

function update_cartoeddy() {
  if [ "$skip_cartoeddy" = true ]; then
    log_step "Skipping CartoEddy update (--skip-cartoeddy)"
    return
  fi

  if ! check_dir "CartoEddy" "$cartoeddy_dir"; then
    log_warn "Skipping CartoEddy update"
    return
  fi

  log_step "Updating CartoEddy"
  cd "$cartoeddy_dir"

  local before
  before=$(git rev-parse --short HEAD)

  git pull 2>&1 | while IFS= read -r line; do echo "  $line"; done

  local after
  after=$(git rev-parse --short HEAD)

  if [ "$before" = "$after" ]; then
    log_ok "Already up to date ($after)"
  else
    log_ok "Updated $before → $after"
  fi

  log_step "Re-installing CartoEddy adapter files"
  ./scripts/install_eddy.sh -k "$klipper_dir" -e "$klippy_env" 2>&1 | while IFS= read -r line; do echo "  $line"; done
  log_ok "CartoEddy installed"
}

# ──────────────────────────────────────────────────────────────
# Flash firmware (optional, temp-patches Makefile)
# ──────────────────────────────────────────────────────────────

function flash_firmware() {
  if [ "$do_flash" = false ]; then
    return
  fi

  log_step "Building & flashing firmware with eddy-ng support"
  cd "$klipper_dir"

  local makefile="src/Makefile"

  # Check if Makefile already has sensor_ldc1612_ng.c (from a previous partial run)
  if grep -q "sensor_ldc1612_ng.c" "$makefile"; then
    log_ok "Makefile already has sensor_ldc1612_ng.c"
  else
    # Temporarily patch Makefile to include eddy-ng firmware
    sed -i 's,sensor_ldc1612.c$,sensor_ldc1612.c sensor_ldc1612_ng.c,' "$makefile"
    log_ok "Temporarily patched Makefile for firmware build"
  fi

  # Build firmware
  echo ""
  echo -e "  ${YELLOW}Running make — this may take a moment...${NC}"
  make 2>&1 | while IFS= read -r line; do echo "  $line"; done

  # Flash firmware
  echo ""
  echo -e "  ${YELLOW}Flashing firmware...${NC}"
  make flash 2>&1 | while IFS= read -r line; do echo "  $line"; done
  log_ok "Firmware built and flashed"

  # Revert Makefile patch
  git checkout -- "$makefile"
  log_ok "Reverted temporary Makefile patch (repo stays clean)"
}

# ──────────────────────────────────────────────────────────────
# Restart Klipper
# ──────────────────────────────────────────────────────────────

function restart_klipper() {
  if [ "$skip_restart" = true ]; then
    log_step "Skipping Klipper restart (--skip-restart)"
    return
  fi

  log_step "Restarting Klipper service"

  if command -v systemctl &>/dev/null; then
    sudo systemctl restart klipper 2>&1 | while IFS= read -r line; do echo "  $line"; done
    log_ok "Klipper restarted via systemctl"
  elif command -v service &>/dev/null; then
    sudo service klipper restart 2>&1 | while IFS= read -r line; do echo "  $line"; done
    log_ok "Klipper restarted via service"
  else
    log_warn "Could not find systemctl or service. Please restart Klipper manually."
  fi
}

# ──────────────────────────────────────────────────────────────
# Verify clean repo
# ──────────────────────────────────────────────────────────────

function verify_clean_repo() {
  log_step "Verifying Klipper repo status"
  cd "$klipper_dir"

  local dirty
  dirty=$(git status --porcelain 2>/dev/null || true)

  if [ -z "$dirty" ]; then
    log_ok "Klipper repo is clean — no dirty-repo warnings"
  else
    log_warn "Klipper repo still has changes:"
    echo "$dirty" | while IFS= read -r line; do echo "    $line"; done
    echo ""
    log_warn "These may be untracked files not in .git/info/exclude"
  fi
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

function main() {
  klipper_dir="$DEFAULT_KLIPPER_DIR"
  klippy_env="$DEFAULT_KLIPPY_ENV"
  eddy_ng_dir="$DEFAULT_EDDY_NG_DIR"
  cartographer_dir="$DEFAULT_CARTOGRAPHER_DIR"
  cartoeddy_dir="$DEFAULT_CARTOEDDY_DIR"

  parse_args "$@"

  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║     CartoEddy Full Stack Update           ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
  echo ""
  echo "  Klipper:      $klipper_dir"
  echo "  klippy-env:   $klippy_env"
  echo "  eddy-ng:      $eddy_ng_dir"
  echo "  Cartographer: $cartographer_dir"
  echo "  CartoEddy:    $cartoeddy_dir"
  if [ "$do_flash" = true ]; then
    echo "  Firmware:     will rebuild & flash"
  fi
  echo ""

  if ! check_dir "Klipper" "$klipper_dir"; then
    exit 1
  fi

  # Phase 1: Clean up any old eddy-ng patches
  clean_old_patches

  # Phase 2: Pull updates
  update_klipper
  update_eddy_ng
  update_cartographer
  update_cartoeddy

  # Phase 3: Firmware (optional)
  flash_firmware

  # Phase 4: Verify & restart
  verify_clean_repo
  restart_klipper

  echo ""
  echo -e "${GREEN}━━━ Update complete!${NC}"
  echo ""
  if [ "$do_flash" = false ]; then
    echo "  Tip: If eddy-ng firmware was updated, re-run with --flash:"
    echo "    $0 --flash --skip-klipper --skip-cartographer --skip-cartoeddy"
    echo ""
  fi
}

main "$@"
