#!/bin/bash

set -euo pipefail

# =========================================================================
# CartoEddy Full Update Script
#
# Automates the complete update of Klipper + eddy-ng + Cartographer +
# CartoEddy without leaving dirty-repo warnings.
#
# What it does:
#   1. Removes eddy-ng patches from Klipper (bed_mesh.py, Makefile)
#   2. Lifts any assume-unchanged flags
#   3. Updates Klipper via git pull
#   4. Updates eddy-ng via git pull + re-installs (re-patches Klipper)
#   5. Updates Cartographer via git pull + re-installs (pip upgrade)
#   6. Updates CartoEddy via git pull + re-installs (copies adapter files)
#   7. Marks patched files as assume-unchanged (hides from git status)
#   8. Restarts Klipper
# =========================================================================

DEFAULT_KLIPPER_DIR="$HOME/klipper"
DEFAULT_KLIPPY_ENV="$HOME/klippy-env"
DEFAULT_EDDY_NG_DIR="$HOME/eddy-ng"
DEFAULT_CARTOGRAPHER_DIR="$HOME/cartographer3d-plugin"
DEFAULT_CARTOEDDY_DIR="$HOME/cartoeddy"

# Files that eddy-ng patches in the Klipper repo
PATCHED_FILES=(
  "klippy/extras/bed_mesh.py"
  "src/Makefile"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function display_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Fully automated update of Klipper + eddy-ng + Cartographer + CartoEddy."
  echo "Handles patched files cleanly so Klipper/Moonraker won't report a dirty repo."
  echo ""
  echo "Options:"
  echo "  -k, --klipper           Klipper directory (default: $DEFAULT_KLIPPER_DIR)"
  echo "  -e, --klippy-env        Klippy virtual environment (default: $DEFAULT_KLIPPY_ENV)"
  echo "  --eddy-ng               eddy-ng directory (default: $DEFAULT_EDDY_NG_DIR)"
  echo "  --cartographer          cartographer3d-plugin directory (default: $DEFAULT_CARTOGRAPHER_DIR)"
  echo "  --cartoeddy             cartoeddy directory (default: $DEFAULT_CARTOEDDY_DIR)"
  echo "  --skip-klipper          Skip Klipper git pull"
  echo "  --skip-eddy-ng          Skip eddy-ng update"
  echo "  --skip-cartographer     Skip Cartographer update"
  echo "  --skip-cartoeddy        Skip CartoEddy update"
  echo "  --skip-restart          Skip Klipper service restart"
  echo "  --no-assume-unchanged   Don't set assume-unchanged on patched files"
  echo "  --help                  Show this help message"
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
  do_assume_unchanged=true

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
    -k | --klipper)         klipper_dir="$2";       shift 2 ;;
    -e | --klippy-env)      klippy_env="$2";        shift 2 ;;
    --eddy-ng)              eddy_ng_dir="$2";       shift 2 ;;
    --cartographer)         cartographer_dir="$2";  shift 2 ;;
    --cartoeddy)            cartoeddy_dir="$2";     shift 2 ;;
    --skip-klipper)         skip_klipper=true;      shift ;;
    --skip-eddy-ng)         skip_eddy_ng=true;      shift ;;
    --skip-cartographer)    skip_cartographer=true;  shift ;;
    --skip-cartoeddy)       skip_cartoeddy=true;    shift ;;
    --skip-restart)         skip_restart=true;       shift ;;
    --no-assume-unchanged)  do_assume_unchanged=false; shift ;;
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
# Step 1: Lift assume-unchanged and unpatch Klipper
# ──────────────────────────────────────────────────────────────

function lift_assume_unchanged() {
  log_step "Lifting assume-unchanged flags on patched files"
  cd "$klipper_dir"

  for f in "${PATCHED_FILES[@]}"; do
    if [ -f "$f" ]; then
      git update-index --no-assume-unchanged "$f" 2>/dev/null || true
      log_ok "$f"
    fi
  done
}

function unpatch_klipper() {
  log_step "Reverting eddy-ng patches in Klipper"
  cd "$klipper_dir"

  # Check if files are actually modified before trying to restore
  local dirty_files
  dirty_files=$(git diff --name-only "${PATCHED_FILES[@]}" 2>/dev/null || true)

  if [ -z "$dirty_files" ]; then
    log_ok "No patches to revert (files are clean)"
    return
  fi

  for f in "${PATCHED_FILES[@]}"; do
    if git diff --quiet "$f" 2>/dev/null; then
      log_ok "$f (already clean)"
    else
      git checkout -- "$f"
      log_ok "Restored $f to upstream version"
    fi
  done
}

# ──────────────────────────────────────────────────────────────
# Step 2: Update Klipper
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
# Step 3: Update & re-install eddy-ng
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

  log_step "Re-installing eddy-ng into Klipper"
  python3 install.py "$klipper_dir" --copy 2>&1 | while IFS= read -r line; do echo "  $line"; done
  log_ok "eddy-ng installed (files copied + Klipper patched)"
}

# ──────────────────────────────────────────────────────────────
# Step 4: Update & re-install Cartographer
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
# Step 5: Update & re-install CartoEddy
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
# Step 6: Hide patched files from git status
# ──────────────────────────────────────────────────────────────

function set_assume_unchanged() {
  if [ "$do_assume_unchanged" = false ]; then
    log_step "Skipping assume-unchanged (--no-assume-unchanged)"
    return
  fi

  log_step "Hiding patched files from git status (assume-unchanged)"
  cd "$klipper_dir"

  for f in "${PATCHED_FILES[@]}"; do
    if [ -f "$f" ]; then
      git update-index --assume-unchanged "$f"
      log_ok "$f"
    fi
  done

  log_ok "Moonraker will no longer report a dirty Klipper repo"
}

# ──────────────────────────────────────────────────────────────
# Step 7: Restart Klipper
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
  echo ""

  # Validate that at least Klipper exists
  if ! check_dir "Klipper" "$klipper_dir"; then
    exit 1
  fi

  # Phase 1: Clean up patched state
  lift_assume_unchanged
  unpatch_klipper

  # Phase 2: Pull updates
  update_klipper
  update_eddy_ng
  update_cartographer
  update_cartoeddy

  # Phase 3: Hide patches from git
  set_assume_unchanged

  # Phase 4: Restart
  restart_klipper

  echo ""
  echo -e "${GREEN}━━━ Update complete!${NC}"
  echo ""
  echo "  Note: If eddy-ng MCU firmware was updated, you may also need to"
  echo "  rebuild and flash the firmware:"
  echo "    cd $klipper_dir"
  echo "    make menuconfig   # Ensure WANT_EDDY_NG is selected"
  echo "    make flash"
  echo ""
}

main "$@"
