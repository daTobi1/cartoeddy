from __future__ import annotations

import logging
from typing import TYPE_CHECKING, final

from cartographer.adapters.eddy.configuration import EddyConfiguration
from cartographer.adapters.eddy.mcu import TAP_MODE_SOS, TAP_MODE_WMA, EddyMcu
from cartographer.adapters.eddy.toolhead import EddyToolhead
from cartographer.adapters.klipper.bed_mesh import KlipperBedMesh
from cartographer.adapters.klipper.gcode import KlipperGCodeDispatch
from cartographer.adapters.klipper.scheduler import KlipperScheduler
from cartographer.interfaces.configuration import GeneralConfig
from cartographer.runtime.adapters import Adapters

if TYPE_CHECKING:
    from configfile import ConfigWrapper as KlipperConfigWrapper

logger = logging.getLogger(__name__)


TAP_MODE_CHOICES = {"wma": TAP_MODE_WMA, "sos": TAP_MODE_SOS, "butterworth": TAP_MODE_SOS}


def _parse_eddy_general_config(config: object) -> GeneralConfig:
    """Parse GeneralConfig for an Eddy sensor.

    The `mcu` field is not meaningful for Eddy (the MCU comes from the I2C bus),
    so we provide a default value instead of requiring it in config.
    """
    return GeneralConfig(
        mcu=config.get("mcu", default="mcu"),
        x_offset=config.getfloat("x_offset"),
        y_offset=config.getfloat("y_offset"),
        z_backlash=config.getfloat("z_backlash", default=0.05, minval=0),
        travel_speed=config.getfloat("travel_speed", default=50, minval=1),
        lift_speed=config.getfloat("lift_speed", default=5, minval=1),
        verbose=config.getboolean("verbose", default=False),
        macro_prefix=config.get("macro_prefix", default=None),
    )


@final
class EddyAdapters(Adapters):
    """Wires together all adapters for an Eddy sensor integration."""

    def __init__(self, config: KlipperConfigWrapper, sensor: object) -> None:
        self.printer = config.get_printer()
        self.scheduler = KlipperScheduler(self.printer.get_reactor())

        general = _parse_eddy_general_config(config)
        tap_mode = config.getchoice("tap_mode", TAP_MODE_CHOICES, TAP_MODE_WMA)
        self.mcu = EddyMcu(config, self.scheduler, sensor, tap_mode=tap_mode)
        self.config = EddyConfiguration(config, self.mcu, general)

        self.toolhead = EddyToolhead(config, self.mcu)
        self.bed_mesh = KlipperBedMesh(config)
        self.gcode = KlipperGCodeDispatch(self.printer)

        self.axis_twist_compensation = None
        if config.has_section("axis_twist_compensation"):
            from cartographer.adapters.klipper.axis_twist_compensation import KlipperAxisTwistCompensationAdapter

            self.axis_twist_compensation = KlipperAxisTwistCompensationAdapter(config)
