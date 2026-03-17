# CartoEddy

Cartographer3D Eddy Probe Integration — Use BTT Eddy (and compatible LDC1612-based probes) with Cartographer's full feature set: scan mode, touch mode, bed mesh, and all macros.

## How It Works

CartoEddy bridges the [eddy-ng](https://github.com/daTobi1/eddy-ng) sensor driver (`LDC1612_ng`) into Cartographer's adapter architecture. Instead of replacing Cartographer's core logic, it implements Cartographer's `Mcu` protocol for the Eddy sensor. This means all of Cartographer's features work out of the box:

- **Scan mode homing** (frequency-threshold based Z homing)
- **Touch mode homing** (WMA or Butterworth tap detection)
- **Scan calibration** (`CARTOGRAPHER_SCAN_CALIBRATE`)
- **Touch calibration** (`CARTOGRAPHER_TOUCH_CALIBRATE`)
- **Bed mesh** (`BED_MESH_CALIBRATE` — rapid scan mesh)
- **All Cartographer macros** (probe accuracy, model management, streaming, etc.)

> **Note:** Temperature calibration (`CARTOGRAPHER_TEMPERATURE_CALIBRATE`) is not applicable — Eddy probes have no on-board coil temperature sensor. Temperature compensation is automatically disabled.

## Installation

One command — everything is handled automatically:

```bash
git clone https://github.com/daTobi1/cartoeddy.git ~/cartoeddy
cd ~/cartoeddy
./scripts/install_eddy.sh
```

The install script:
1. Installs **cartographer3d-plugin** from PyPI (with numpy dependency)
2. Clones **eddy-ng** to `~/eddy-ng` (if not already present)
3. Copies eddy-ng Python files **without patching Klipper** (no dirty repo)
4. Copies CartoEddy adapter files into the cartographer package
5. Creates `cartographer_eddy.py` scaffolding in `klippy/extras/`
6. Reverts any old eddy-ng patches if present

**Options:**
```bash
./scripts/install_eddy.sh --help             # Show all options
./scripts/install_eddy.sh -k ~/klipper       # Custom Klipper path
./scripts/install_eddy.sh --eddy-ng ~/eddy   # Custom eddy-ng path
./scripts/install_eddy.sh --uninstall        # Remove CartoEddy
```

**First-time firmware build** (needed once for the eddy-ng MCU driver):
```bash
cd ~/cartoeddy
./scripts/update.sh --flash --skip-klipper --skip-cartographer --skip-cartoeddy
```
This temporarily patches `src/Makefile`, builds & flashes firmware, then reverts the patch.

## Configuration

Replace your `[probe_eddy_ng]` section with `[cartographer_eddy]`. Do **not** keep both.

A complete reference config is included in the repo: [`config/cartographer_eddy.cfg`](config/cartographer_eddy.cfg)

### Minimal Configuration

```ini
[mcu eddy]
canbus_uuid: YOUR_UUID_HERE

[cartographer_eddy]
sensor_type: btt_eddy
i2c_mcu: eddy
i2c_bus: i2c0f
x_offset: 0.0
y_offset: 16.0

[cartographer_eddy scan]

[cartographer_eddy touch]

# REQUIRED in your stepper_z section:
[stepper_z]
endstop_pin: probe:z_virtual_endstop
homing_retract_dist: 0
```

### Full Configuration Reference

```ini
[cartographer_eddy]
# === Sensor Hardware (passed to LDC1612_ng) ===
sensor_type: btt_eddy           # btt_eddy, cartographer, mellow_fly, ldc1612, ldc1612_internal_clk
i2c_mcu: eddy                   # MCU the sensor is connected to
i2c_bus: i2c0f                   # I2C bus
# reg_drive_current: 15         # LDC1612 drive current (0-31, 0=auto)
# samples_per_second: 250       # Sensor sample rate (min 50)

# === Probe Position ===
x_offset: 0.0                   # Distance from nozzle to probe (X mm)
y_offset: 16.0                  # Distance from nozzle to probe (Y mm)

# === Movement ===
travel_speed: 50                 # XY travel speed (mm/s)
lift_speed: 10                   # Z lift speed (mm/s)

# === General ===
z_backlash: 0.05                 # Z backlash compensation (mm)
tap_mode: wma                    # wma (default) or sos/butterworth
# verbose: false                 # Enable debug logging
# macro_prefix: EDDY             # Extra macro aliases (e.g. EDDY_TOUCH_HOME)

# === Scan Mode ===
[cartographer_eddy scan]
# samples: 20                    # Samples per probe point
# probe_speed: 5                 # Z probe speed (mm/s)
# mesh_runs: 1                   # Mesh passes
# mesh_height: 3                 # Head height during mesh scan (mm)

# === Touch Mode ===
[cartographer_eddy touch]
samples: 5                       # Successful samples needed
max_samples: 20                  # Maximum attempts
sample_range: 0.0050             # Acceptable range between samples (mm)
# retract_distance: 2.0          # Retract between touch samples (mm)
```

### Migration from eddy-ng

| Alt (`[probe_eddy_ng]`) | Neu (`[cartographer_eddy]`) |
|---|---|
| `move_speed` | `travel_speed` |
| `tap_threshold` | Wird automatisch kalibriert |
| `tap_speed` | Wird automatisch kalibriert |
| `tap_adjust_z` | Wird automatisch kalibriert |
| `tap_samples` | `[cartographer_eddy touch]` → `samples` |
| `tap_max_samples` | `[cartographer_eddy touch]` → `max_samples` |
| `tap_samples_stddev` | `[cartographer_eddy touch]` → `sample_range` |
| `home_trigger_height` | Wird durch Scan-Modell ersetzt |
| `calibration_z_max` | Nicht noetig |
| `tap_start_z`, `tap_target_z` | Nicht noetig (Cartographer managt das) |
| `write_tap_plot` | Nicht verfuegbar |
| `PROBE_EDDY_NG_TAP` | `CARTOGRAPHER_TOUCH_HOME` |
| `BED_MESH_CALIBRATE METHOD=rapid_scan` | `BED_MESH_CALIBRATE` |

## Calibration

After installation and config, restart Klipper and follow this workflow.

### Step 1: Scan Calibration (required)

Creates a polynomial model mapping sensor frequency to Z distance. This is the foundation for all probing.

```
CARTOGRAPHER_SCAN_CALIBRATE METHOD=TOUCH
```

This uses touch to find Z=0, then scans across a range of heights to build the model. Alternatively, use `METHOD=MANUAL` for a paper-test based zero.

After calibration, verify:
```
CARTOGRAPHER_SCAN_MODEL LIST=1
```

Save immediately:
```
SAVE_CONFIG
```

### Step 2: Touch Calibration (recommended)

Touch mode provides more accurate Z homing than scan mode. The calibration automatically finds the optimal threshold for your setup.

```
CARTOGRAPHER_TOUCH_CALIBRATE
```

**How auto-calibration works:**
1. **Screening** — collects samples at the current threshold, checks for consistent subset
2. **Verification** — runs multiple full touch sequences to confirm reliability
3. **Increment** — if threshold fails, increases by 10-20% and retries
4. Stops at the **minimum threshold that passes both phases**

**Tap mode selection** (`tap_mode` in config):

| Mode | Config | Typical Threshold | Best for |
|------|--------|-------------------|----------|
| **WMA** | `wma` (default) | 500 - 2000 | General purpose, fast integer math |
| **Butterworth** | `sos` | 100 - 500 | Noisy setups, better signal filtering |

**Custom parameters:**
```
# For WMA (default):
CARTOGRAPHER_TOUCH_CALIBRATE

# For Butterworth mode, start lower:
CARTOGRAPHER_TOUCH_CALIBRATE START=100 MAX=2000

# Custom verification:
CARTOGRAPHER_TOUCH_CALIBRATE SPEED=2 VERIFICATION_SAMPLES=10
```

Save immediately:
```
SAVE_CONFIG
```

### Step 3: Verify Accuracy

```
# Scan mode accuracy (should be < 0.01mm range):
CARTOGRAPHER_SCAN_ACCURACY

# Touch mode accuracy (should be < 0.005mm range):
CARTOGRAPHER_TOUCH_ACCURACY
```

### Step 4: Bed Mesh

```
BED_MESH_CALIBRATE
```

Uses Cartographer's rapid scan mesh — much faster than point-by-point probing.

### Recalibration

Recalibrate when:
- You change the nozzle
- You change the build plate
- Touch results become inconsistent
- After significant hardware changes

```
# Full recalibration:
CARTOGRAPHER_SCAN_CALIBRATE METHOD=TOUCH
SAVE_CONFIG
# After restart:
CARTOGRAPHER_TOUCH_CALIBRATE
SAVE_CONFIG
```

## Available GCode Commands

All standard Cartographer commands work:

| Command | Description |
|---------|-------------|
| `PROBE` | Probe bed at current position |
| `PROBE_ACCURACY` | Measure probe repeatability |
| `QUERY_PROBE` | Query probe state |
| `CARTOGRAPHER_QUERY` | Show MCU, scan, and touch status |
| `CARTOGRAPHER_SCAN_CALIBRATE` | Run scan model calibration |
| `CARTOGRAPHER_SCAN_ACCURACY` | Measure scan mode accuracy |
| `CARTOGRAPHER_SCAN_MODEL` | Manage scan models (load/remove/list) |
| `CARTOGRAPHER_TOUCH_PROBE` | Touch bed at current position |
| `CARTOGRAPHER_TOUCH_CALIBRATE` | Calibrate touch threshold |
| `CARTOGRAPHER_TOUCH_ACCURACY` | Measure touch mode accuracy |
| `CARTOGRAPHER_TOUCH_HOME` | Home Z via touch |
| `CARTOGRAPHER_TOUCH_MODEL` | Manage touch models |
| `BED_MESH_CALIBRATE` | Rapid scan bed mesh |
| `CARTOGRAPHER_STREAM` | Stream sensor data to CSV |
| `CARTOGRAPHER_ESTIMATE_BACKLASH` | Estimate Z backlash |
| `Z_OFFSET_APPLY_PROBE` | Apply Z offset from probe |

> `CARTOGRAPHER_TEMPERATURE_CALIBRATE` is registered but will not produce useful results (Eddy has no coil temperature sensor).

## Updating

Full-stack update that keeps the Klipper repo **100% clean**:

```bash
cd ~/cartoeddy
./scripts/update.sh
```

This pulls and re-installs all components (Klipper, eddy-ng, Cartographer, CartoEddy) then restarts Klipper.

```bash
# Also rebuild & flash firmware:
./scripts/update.sh --flash

# Skip components:
./scripts/update.sh --skip-klipper --skip-eddy-ng

# Custom paths:
./scripts/update.sh -k ~/klipper -e ~/klippy-env --eddy-ng ~/eddy-ng
```

**Why the Klipper repo stays clean:**
- eddy-ng's `bed_mesh.py` patch is **not needed** (Cartographer has its own)
- `Makefile` patch is **only applied temporarily** during `--flash` builds
- All added files are hidden via `.git/info/exclude`

## Architecture

```
[cartographer_eddy] config section
        │
        ▼
  extra_eddy.py          ← Entry point (load_config)
        │
        ├── LDC1612_ng   ← eddy-ng sensor driver (I2C/SPI)
        │
        ├── EddyMcu      ← Implements Cartographer Mcu protocol
        │   ├── Bridges BatchBulkHelper → Stream[Sample]
        │   ├── Homing: setup_home() for scan/touch modes
        │   └── Duck-types as KlipperCartographerMcu
        │
        ├── EddyConfiguration  ← Config adapter (no coil temp)
        ├── EddyToolhead       ← Reuses KlipperLikeToolhead
        ├── EddyIntegrator     ← Reuses KlipperLikeIntegrator
        └── EddyAdapters       ← Wires everything together
                │
                ▼
        PrinterCartographer    ← Core logic (unchanged)
```

## Differences from Native Cartographer

| Feature | Native Cartographer | CartoEddy |
|---------|-------------------|-----------|
| Sensor | Cartographer PCB (24MHz) | BTT Eddy / compatible (12-40MHz) |
| Connection | USB/CAN (dedicated MCU) | I2C/SPI via printer MCU |
| Temperature sensor | On-board coil temp | None (disabled) |
| Temperature compensation | Yes | No (not needed for most setups) |
| Touch detection | Custom firmware | eddy-ng WMA or Butterworth |
| Scan mode | Native | Via eddy-ng frequency conversion |
| All macros | Yes | Yes (except temp calibrate) |

## Troubleshooting

### "Eddy sensor not ready after 5.0s"
The sensor couldn't get a valid reading within 5 seconds. Check:
- Coil connection and power
- I2C bus configuration (`i2c_mcu`, `i2c_bus`)
- That the sensor is close enough to a metallic surface

### "Could not import ldc1612_ng"
eddy-ng Python files are not installed. Re-run:
```bash
cd ~/cartoeddy && ./scripts/install_eddy.sh
```

### "Communication timeout during homing"
The MCU lost synchronization. Check:
- Homing speed (try slower)
- Sensor distance from bed when starting
- Electrical noise on I2C bus

### Touch mode gives inconsistent results
- Switch `tap_mode` between `wma` and `sos`
- Increase `sample_range` slightly (e.g. 0.008)
- Re-run `CARTOGRAPHER_TOUCH_CALIBRATE`
- For Butterworth: `CARTOGRAPHER_TOUCH_CALIBRATE START=100`

### "homing_retract_dist must be set to 0"
Add to your `[stepper_z]` section:
```ini
homing_retract_dist: 0
```

## Uninstall

```bash
cd ~/cartoeddy
./scripts/install_eddy.sh --uninstall
```

Then remove the `[cartographer_eddy]` sections from your `printer.cfg`.

## License

This project builds on [cartographer3d-plugin](https://github.com/Cartographer3D/cartographer3d-plugin) (GPLv3) and [eddy-ng](https://github.com/daTobi1/eddy-ng).
