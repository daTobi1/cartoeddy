from __future__ import annotations

import logging
from typing import TYPE_CHECKING, final

from typing_extensions import override

from cartographer.adapters.klipper.probe import KlipperCartographerProbe
from cartographer.adapters.klipper_like.integrator import KlipperLikeIntegrator

if TYPE_CHECKING:
    from cartoeddy.adapters import EddyAdapters
    from cartographer.core import PrinterCartographer

logger = logging.getLogger(__name__)


@final
class EddyIntegrator(KlipperLikeIntegrator):
    """Integrator for the Eddy sensor.

    Reuses KlipperLikeIntegrator which provides macro registration,
    endstop pin registration, and homing event handling. The only
    Eddy-specific part is register_cartographer and skipping the
    coil temperature sensor (Eddy has no temp sensor).
    """

    def __init__(self, adapters: EddyAdapters) -> None:
        # KlipperLikeIntegrator expects KlipperLikeAdapters protocol:
        #   mcu: KlipperCartographerMcu, printer: Printer, config: KlipperConfiguration
        # EddyMcu is duck-type compatible (provides klipper_mcu, dispatch).
        super().__init__(adapters)  # type: ignore[arg-type]
        self._toolhead = adapters.toolhead

    @override
    def register_cartographer(self, cartographer: PrinterCartographer) -> None:
        self._printer.add_object(
            "probe",
            KlipperCartographerProbe(
                self._toolhead,
                cartographer.scan_mode,
                cartographer.probe_macro,
                cartographer.query_probe_macro,
                cartographer.config.general,
            ),
        )

    @override
    def register_coil_temperature_sensor(self) -> None:
        # Eddy probes have no on-board coil temperature sensor — skip registration.
        logger.debug("Eddy sensor has no coil temperature sensor, skipping registration")
