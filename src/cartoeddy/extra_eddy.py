"""Entry point for the Eddy sensor integration with Cartographer.

This module is loaded by Klipper when it encounters a [cartographer_eddy] config section.
It creates an LDC1612_ng sensor instance and wraps it in Cartographer's adapter layer,
giving Eddy probe users access to Cartographer's scan mode, touch mode, bed mesh, and macros.

Example config:
    [cartographer_eddy]
    sensor_type: btt_eddy
    cs_pin: ...
    x_offset: -36.0
    y_offset: 0.0
    mcu: mcu  # the MCU that the Eddy sensor is connected to
"""
from __future__ import annotations

import logging

from cartographer import __version__
from cartographer.core import PrinterCartographer

logger = logging.getLogger(__name__)


def load_config(config: object) -> object:
    from cartoeddy.adapters import EddyAdapters
    from cartoeddy.integrator import EddyIntegrator

    # Create the LDC1612_ng sensor from eddy-ng
    sensor = _create_sensor(config)

    adapters = EddyAdapters(config, sensor)
    integrator = EddyIntegrator(adapters)

    integrator.setup()

    cartographer = PrinterCartographer(adapters)

    integrator.register_cartographer(cartographer)

    for macro in cartographer.macros:
        integrator.register_macro(macro)

    # Skip coil temperature sensor (Eddy has none)
    integrator.register_coil_temperature_sensor()

    integrator.register_endstop_pin("probe", "z_virtual_endstop", cartographer.scan_mode)

    integrator.register_ready_callback(cartographer.ready_callback)

    logger.info(
        "Loaded Cartographer3D Eddy Plugin version %s using %s",
        __version__,
        integrator.__class__.__name__,
    )

    return cartographer


def _create_sensor(config: object):
    """Create an LDC1612_ng sensor instance.

    Supports both Klipper and Kalico import paths.
    """
    try:
        from klippy.extras.ldc1612_ng import LDC1612_ng

        return LDC1612_ng(config)
    except ImportError:
        pass

    try:
        from extras.ldc1612_ng import LDC1612_ng

        return LDC1612_ng(config)
    except ImportError:
        pass

    msg = (
        "Could not import ldc1612_ng. "
        "Make sure eddy-ng is installed (ldc1612_ng.py must be in klippy/extras/)."
    )
    raise ImportError(msg)
