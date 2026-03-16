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

## Prerequisites

1. **Klipper** (or Kalico) installed and running
2. **eddy-ng** installed — `ldc1612_ng.py` must be in `klippy/extras/`
   ```bash
   cd ~/eddy-ng
   python install.py
   ```
3. **cartographer3d-plugin** installed
   ```bash
   cd ~/cartographer3d-plugin
   ./scripts/install.sh
   ```

## Installation

### Automatic (recommended)

```bash
git clone https://github.com/daTobi1/cartoeddy.git ~/cartoeddy
```

Then apply the code changes and create the scaffolding file:

```bash
cd ~/cartoeddy
./scripts/install_eddy.sh
```

The install script:
- Verifies that eddy-ng and cartographer3d-plugin are already installed
- Creates `cartographer_eddy.py` in `klippy/extras/` (or `klippy/plugins/` for Kalico)
- Adds the file to git exclude so it doesn't show up in Klipper's git status

### Manual

1. Copy the eddy adapter files into the installed cartographer package:
   ```bash
   SITE_PACKAGES=$(~/klippy-env/bin/python -c "import cartographer; import os; print(os.path.dirname(cartographer.__file__))")

   # Copy adapter files
   cp -r src/cartographer/adapters/eddy "$SITE_PACKAGES/adapters/eddy"

   # Copy entry point
   cp src/cartographer/extra_eddy.py "$SITE_PACKAGES/extra_eddy.py"

   # Copy modified runtime files
   cp src/cartographer/runtime/loader.py "$SITE_PACKAGES/runtime/loader.py"
   cp src/cartographer/runtime/environment.py "$SITE_PACKAGES/runtime/environment.py"
   ```

2. Create the Klipper scaffolding file:
   ```bash
   echo 'from cartographer.extra_eddy import *' > ~/klipper/klippy/extras/cartographer_eddy.py
   ```

3. Restart Klipper.

## Configuration

Add a `[cartographer_eddy]` section to your `printer.cfg`. This replaces both `[probe_eddy_ng]` and `[cartographer]` — do **not** use those sections alongside `[cartographer_eddy]`.

### Minimal Configuration

```ini
[cartographer_eddy]
# Sensor pin configuration (same as you'd use for eddy-ng)
cs_pin: EBBCan:gpio9
spi_bus: spi1a
# Or for I2C:
# i2c_bus: i2c3a_PB3_PB4
# i2c_address: 43

# Probe offset from nozzle
x_offset: -36.0
y_offset: 0.0

# Required for virtual endstop homing
[stepper_z]
endstop_pin: probe:z_virtual_endstop
homing_retract_dist: 0  # REQUIRED: must be 0

[safe_z_home]
home_xy_position: 150, 150
z_hop: 10
```

### Full Configuration Reference

```ini
[cartographer_eddy]
# === Sensor Hardware ===
# SPI connection (BTT Eddy typical)
cs_pin: EBBCan:gpio9
spi_bus: spi1a

# Or I2C connection
# i2c_bus: i2c3a_PB3_PB4
# i2c_address: 43

# === Probe Position ===
x_offset: -36.0              # Distance from nozzle to probe (X)
y_offset: 0.0                # Distance from nozzle to probe (Y)

# === Movement ===
travel_speed: 50              # Speed (mm/s) for XY travel moves
lift_speed: 5                 # Speed (mm/s) for Z lift moves

# === General ===
z_backlash: 0.05              # Z backlash compensation (mm)
verbose: False                # Enable debug logging
# macro_prefix: EDDY          # Optional: creates aliased macro set (e.g., EDDY_SCAN_CALIBRATE)

# === Tap Detection Mode ===
# tap_mode: wma               # Options: wma (default), sos/butterworth
                              # wma = Weighted Moving Average (fast, lightweight)
                              # sos = Butterworth bandpass filter (cleaner signal, more filtering)

# === Scan Mode ===
[cartographer_eddy scan]
samples: 20                   # Number of samples per probe point
probe_speed: 5                # Z speed (mm/s) during probing
mesh_runs: 1                  # Number of mesh passes
mesh_height: 3                # Head height (mm) during mesh scan
# mesh_direction: x           # Primary mesh axis (x or y)
# mesh_path: snake             # Mesh path pattern (snake or zigzag)

# === Touch Mode ===
[cartographer_eddy touch]
samples: 3                    # Successful samples needed
max_samples: 10               # Maximum attempts before giving up
retract_distance: 2.0         # Retract (mm) between touch samples
sample_range: 0.010           # Acceptable range (mm) between samples

# === Bed Mesh ===
[bed_mesh]
speed: 200
horizontal_move_z: 3
mesh_min: 10, 10
mesh_max: 290, 290
probe_count: 30, 30
algorithm: bicubic
```

### Sensor Type Detection

The LDC1612_ng driver automatically detects your sensor type (BTT Eddy, Cartographer Eddy, Mellow Fly, etc.) based on the resonant frequency. No `sensor_type` configuration is needed.

## Calibration Workflow

### 1. Scan Calibration (required first)

This creates a polynomial model mapping sensor frequency to Z distance:

```
CARTOGRAPHER_SCAN_CALIBRATE METHOD=TOUCH
```

Or with manual paper test:
```
CARTOGRAPHER_SCAN_CALIBRATE METHOD=MANUAL
```

After calibration, a model is saved automatically. You can verify it:
```
CARTOGRAPHER_SCAN_MODEL LIST=1
```

### 2. Touch Calibration (optional, for touch homing)

If you want to use touch-based Z homing (more accurate than scan):

```
CARTOGRAPHER_TOUCH_CALIBRATE
```

This automatically finds the optimal touch threshold for your setup by iterating from a start value upwards until it finds a threshold that produces consistent, repeatable results.

**How auto-calibration works:**
1. **Screening phase** — collects a few samples at the current threshold, checks if a consistent subset exists
2. **Verification phase** — runs multiple full touch probe sequences to confirm reliability
3. **Increment** — if the threshold fails, it's increased (10-20% steps) and retried
4. Stops at the **minimum threshold that passes both phases**

**Tap mode selection** (`tap_mode` in config):

| Mode | Config Value | Default Threshold Range | Characteristics |
|------|-------------|------------------------|-----------------|
| **WMA** | `wma` (default) | 500 - 2000 | Fast, lightweight integer math. Tracks weighted average of frequency derivative. Good general-purpose choice. |
| **Butterworth** | `sos` or `butterworth` | 100 - 500 | IIR bandpass filter (5-25 Hz). Cleaner signal, better noise rejection. Slightly more MCU load and phase lag. |

**Calibration parameters:**
```
# Use defaults (START=500, MAX=5000):
CARTOGRAPHER_TOUCH_CALIBRATE

# For Butterworth mode, start lower:
CARTOGRAPHER_TOUCH_CALIBRATE START=100 MAX=2000

# Customize verification:
CARTOGRAPHER_TOUCH_CALIBRATE SPEED=2 VERIFICATION_SAMPLES=10
```

**Threshold guidance:**
- The auto-calibration finds the optimal value — use it as-is
- Lower = more sensitive (may false trigger), Higher = less sensitive (may miss contact)
- WMA thresholds are typically higher than Butterworth thresholds
- If calibration fails, try the other `tap_mode` or check mechanical setup

### 3. Verify Accuracy

```
# Scan mode accuracy
CARTOGRAPHER_SCAN_ACCURACY

# Touch mode accuracy (after touch calibration)
CARTOGRAPHER_TOUCH_ACCURACY
```

### 4. Bed Mesh

```
BED_MESH_CALIBRATE
```

Uses Cartographer's rapid scan mesh — much faster than point-by-point probing.

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

> `CARTOGRAPHER_TEMPERATURE_CALIBRATE` is registered but will not produce useful results (Eddy has no coil temperature sensor — temperature is always reported as 0).

## Architecture

```
[cartographer_eddy] config section
        │
        ▼
  extra_eddy.py          ← Entry point (load_config)
        │
        ├── LDC1612_ng   ← eddy-ng sensor driver (I2C/SPI communication)
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
| Touch detection | Custom firmware | eddy-ng WMA or Butterworth mode |
| Scan mode | Native | Via eddy-ng frequency conversion |
| All macros | Yes | Yes (except temp calibrate) |

## Troubleshooting

### "Eddy sensor not ready after 5.0s"
The sensor couldn't get a valid reading within 5 seconds of a homing attempt. Check:
- Coil connection and power
- I2C/SPI bus configuration
- That the sensor is close enough to a metallic surface

### "Could not import ldc1612_ng"
eddy-ng is not installed. Install it first:
```bash
cd ~/eddy-ng && python install.py
```

### "Communication timeout during homing"
The MCU lost synchronization during a homing move. This can happen if:
- The homing speed is too fast
- The sensor is too far from the bed when starting
- There's electrical noise on the I2C/SPI bus

### Touch mode gives inconsistent results
- Try switching `tap_mode` between `wma` and `sos` (Butterworth may work better for noisy setups)
- Try adjusting `sample_range` (default 0.010mm)
- Increase `retract_distance` if samples are too close
- Re-run `CARTOGRAPHER_TOUCH_CALIBRATE` to find optimal threshold
- For Butterworth mode, use lower START value: `CARTOGRAPHER_TOUCH_CALIBRATE START=100`

## Uninstall

```bash
cd ~/cartoeddy
./scripts/install_eddy.sh --uninstall
```

Then remove the `[cartographer_eddy]` section from your `printer.cfg`.

## License

This project builds on [cartographer3d-plugin](https://github.com/Cartographer3D/cartographer3d-plugin) (GPLv3) and [eddy-ng](https://github.com/daTobi1/eddy-ng).
