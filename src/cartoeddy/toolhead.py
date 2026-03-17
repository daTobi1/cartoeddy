from __future__ import annotations

from typing import TYPE_CHECKING

from typing_extensions import override

from cartographer.adapters.klipper_like.toolhead import KlipperLikeToolhead

if TYPE_CHECKING:
    from configfile import ConfigWrapper
    from gcode import GCodeDispatch

    from cartoeddy.mcu import EddyMcu


class EddyToolhead(KlipperLikeToolhead):
    """Toolhead adapter for Eddy sensor.

    Reuses the full KlipperLikeToolhead implementation since EddyMcu
    provides the required `klipper_mcu` and `dispatch` attributes.
    """

    def __init__(self, config: ConfigWrapper, mcu: EddyMcu) -> None:
        # KlipperLikeToolhead expects KlipperCartographerMcu in its type hint,
        # but only uses .klipper_mcu, .dispatch, and .get_current_time() —
        # all of which EddyMcu provides.
        super().__init__(config, mcu)  # type: ignore[arg-type]
        self._gcode: GCodeDispatch = config.printer.lookup_object("gcode")

    @override
    def get_max_accel(self) -> float:
        return self.toolhead.get_max_velocity()[1]

    @override
    def set_max_accel(self, accel: float) -> None:
        self._gcode.run_script_from_command(f"SET_VELOCITY_LIMIT ACCEL={accel:.3f}")
