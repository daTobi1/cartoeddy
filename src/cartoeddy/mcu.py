from __future__ import annotations

import logging
from functools import cached_property
from typing import TYPE_CHECKING, Callable, final

import mcu
from mcu import MCU_trsync
from mcu import TriggerDispatch as KlipperTriggerDispatch
from typing_extensions import override

from cartographer.adapters.klipper.mcu.stream import KlipperStream, KlipperStreamMcu
from cartographer.interfaces.printer import CoilCalibrationReference, Mcu, Position, Sample

if TYPE_CHECKING:
    from configfile import ConfigWrapper
    from reactor import Reactor, ReactorCompletion

    from cartographer.interfaces.multiprocessing import Scheduler
    from cartographer.stream import Session

logger = logging.getLogger(__name__)

# Eddy sensor data arrives via BatchBulkHelper as (time, raw_freqval) tuples.
# We bridge these into the Cartographer Stream[Sample] pattern.

SENSOR_READY_TIMEOUT = 5.0

# Supported tap detection modes for eddy-ng
TAP_MODE_WMA = "wma"
TAP_MODE_SOS = "sos"
VALID_TAP_MODES = {TAP_MODE_WMA, TAP_MODE_SOS}


@final
class EddyMcu(Mcu, KlipperStreamMcu):
    """Adapter that wraps an eddy-ng LDC1612_ng sensor to implement
    the Cartographer Mcu protocol.

    Provides `klipper_mcu` and `dispatch` attributes so it can be used
    with the existing KlipperEndstop, KlipperLikeToolhead, and
    KlipperLikeIntegrator infrastructure.
    """

    def __init__(
        self,
        config: ConfigWrapper,
        scheduler: Scheduler,
        sensor: object,
        tap_mode: str = TAP_MODE_WMA,
    ):
        if tap_mode not in VALID_TAP_MODES:
            msg = f"Invalid tap_mode '{tap_mode}'. Must be one of: {', '.join(sorted(VALID_TAP_MODES))}"
            raise ValueError(msg)

        self.printer = config.get_printer()
        self._sensor = sensor
        self._scheduler = scheduler
        self._tap_mode = tap_mode

        # The underlying Klipper MCU object — needed by KlipperEndstop.get_mcu()
        self.klipper_mcu = sensor.get_mcu()
        self._reactor: Reactor = self.klipper_mcu.get_printer().get_reactor()

        # Stream infrastructure (same pattern as KlipperCartographerMcu)
        self._stream = KlipperStream[Sample](self, self._reactor)

        # TriggerDispatch for homing — needed by KlipperEndstop
        self.dispatch = KlipperTriggerDispatch(self.klipper_mcu)

        self.motion_report = self.printer.load_object(config, "motion_report")

        self._sensor_ready = False
        self._streaming = False

        self.printer.register_event_handler("klippy:mcu_identify", self._handle_mcu_identify)
        self.printer.register_event_handler("klippy:connect", self._handle_connect)

    @property
    def tap_mode(self) -> str:
        """The active tap detection mode ('wma' or 'sos')."""
        return self._tap_mode

    @cached_property
    def kinematics(self):
        return self.printer.lookup_object("toolhead").get_kinematics()

    # ──────────────────────────────────────────────────────────────
    # Mcu protocol implementation
    # ──────────────────────────────────────────────────────────────

    @override
    def start_homing_scan(self, print_time: float, frequency: float) -> ReactorCompletion:
        self._ensure_sensor_ready()

        trigger_freq = frequency
        # Safe-start frequency: 6% above trigger (same hysteresis concept)
        safe_freq = frequency * 1.06

        completion = self.dispatch.start(print_time)

        self._sensor.setup_home(
            trsync_oid=self.dispatch.get_oid(),
            hit_reason=MCU_trsync.REASON_ENDSTOP_HIT,
            other_reason_base=MCU_trsync.REASON_COMMS_TIMEOUT + 1,
            trigger_freq=trigger_freq,
            start_freq=safe_freq,
            start_time=0,
            mode="home",
        )
        return completion

    @override
    def start_homing_touch(self, print_time: float, threshold: int) -> ReactorCompletion:
        self._ensure_sensor_ready()

        completion = self.dispatch.start(print_time)

        # eddy-ng supports two tap detection modes:
        #   "wma" — Weighted Moving Average of frequency derivative (fast, integer math)
        #   "sos" — Butterworth bandpass filter via cascaded second-order sections (cleaner signal)
        #
        # Both modes share the same setup_home() interface. The threshold is passed
        # as a float — eddy-ng internally converts via int(tap_threshold * 65536.0).
        # The MCU side then interprets it mode-specifically:
        #   WMA: tap_threshold >> 16 (cumulative derivative change)
        #   SOS: tap_threshold / 65536.0f (filtered signal magnitude)
        #
        # The trigger/start freqs are not used in tap modes,
        # but eddy-ng still expects them. We use 0 as placeholders.
        self._sensor.setup_home(
            trsync_oid=self.dispatch.get_oid(),
            hit_reason=MCU_trsync.REASON_ENDSTOP_HIT,
            other_reason_base=MCU_trsync.REASON_COMMS_TIMEOUT + 1,
            trigger_freq=0.0,
            start_freq=0.0,
            start_time=0,
            mode=self._tap_mode,
            tap_threshold=float(threshold),
        )
        return completion

    @override
    def stop_homing(self, home_end_time: float) -> float:
        self.dispatch.wait_end(home_end_time)

        home_result = self._sensor.finish_home()

        result = self.dispatch.stop()
        if result >= MCU_trsync.REASON_COMMS_TIMEOUT:
            msg = "Communication timeout during homing"
            raise RuntimeError(msg)
        if result != MCU_trsync.REASON_ENDSTOP_HIT:
            return 0.0

        return home_result.trigger_time if home_result.trigger_time > 0 else home_end_time

    @override
    def start_session(self, start_condition: Callable[[Sample], bool] | None = None) -> Session[Sample]:
        return self._stream.start_session(start_condition)

    @override
    def register_callback(self, callback: Callable[[Sample], None]) -> None:
        return self._stream.register_callback(callback)

    @override
    def unregister_callback(self, callback: Callable[[Sample], None]) -> None:
        return self._stream.unregister_callback(callback)

    @override
    def get_current_time(self) -> float:
        return self.printer.get_reactor().monotonic()

    @override
    def get_coil_reference(self) -> CoilCalibrationReference:
        # Eddy probes have no on-board temperature sensor.
        # Return a neutral reference that disables temperature compensation.
        return CoilCalibrationReference(
            min_frequency=0.0,
            min_frequency_temperature=25.0,
        )

    @override
    def get_status(self, eventtime: float) -> dict[str, object]:
        last = self._stream.last_item
        return {
            "last_sample": {
                "frequency": last.frequency,
                "time": last.time,
                "temperature": last.temperature,
                "raw_count": last.raw_count,
            }
            if last
            else None,
            "sensor_type": "eddy",
            "tap_mode": self._tap_mode,
        }

    @override
    def get_mcu_version(self) -> str:
        return self.klipper_mcu.get_status()["mcu_version"]

    @override
    def get_last_sample(self) -> Sample | None:
        return self._stream.last_item

    # ──────────────────────────────────────────────────────────────
    # KlipperStreamMcu protocol implementation
    # ──────────────────────────────────────────────────────────────

    @override
    def start_streaming(self) -> None:
        if self._streaming:
            return
        self._streaming = True
        self._sensor.add_bulk_sensor_data_client(self._handle_bulk_data)

    @override
    def stop_streaming(self) -> None:
        # BatchBulkHelper manages start/stop via client refcount.
        # We just mark ourselves as not interested; the callback will
        # return False which removes us from the client list.
        self._streaming = False

    # ──────────────────────────────────────────────────────────────
    # Bulk data bridge: eddy-ng BatchBulkHelper → Cartographer Stream
    # ──────────────────────────────────────────────────────────────

    def _handle_bulk_data(self, msg: dict) -> bool:
        """Callback registered with LDC1612_ng.add_bulk_sensor_data_client().

        Called periodically with a batch of (time, raw_freqval) samples.
        Returns True to keep receiving, False to unregister.
        """
        if not self._streaming:
            return False

        samples = msg.get("data", [])
        for ptime, raw_freqval in samples:
            frequency = self._sensor.from_ldc_freqval(raw_freqval, ignore_err=True)
            position = self._get_requested_position(ptime)
            sample = Sample(
                raw_count=raw_freqval,
                time=ptime,
                frequency=frequency,
                temperature=0.0,
                position=position,
            )
            self._stream.add_item(sample)

        return True

    def _get_requested_position(self, time: float) -> Position | None:
        try:
            kinematics = self.kinematics
            stepper_pos = {
                stepper.get_name(): stepper.mcu_to_commanded_position(stepper.get_past_mcu_position(time))
                for stepper in kinematics.get_steppers()
            }
            position = kinematics.calc_position(stepper_pos)
            return Position(x=position[0], y=position[1], z=position[2])
        except Exception:
            return None

    # ──────────────────────────────────────────────────────────────
    # Event handlers
    # ──────────────────────────────────────────────────────────────

    def _handle_mcu_identify(self) -> None:
        for stepper in self.kinematics.get_steppers():
            if stepper.is_active_axis("z"):
                self.dispatch.add_stepper(stepper)

    def _handle_connect(self) -> None:
        pass

    # ──────────────────────────────────────────────────────────────
    # Sensor readiness
    # ──────────────────────────────────────────────────────────────

    def _ensure_sensor_ready(self, timeout: float = SENSOR_READY_TIMEOUT) -> None:
        if self._sensor_ready:
            return

        if self._is_sensor_ready():
            self._sensor_ready = True
            return

        logger.debug("Eddy sensor not ready, waiting for %.1f", timeout)
        if not self._scheduler.wait_until(
            self._is_sensor_ready,
            timeout=timeout,
            poll_interval=0.1,
        ):
            msg = f"Eddy sensor not ready after {timeout:.1f}s. Check coil connection and power."
            raise RuntimeError(msg)

        self._sensor_ready = True
        logger.debug("Eddy sensor ready")

    def _is_sensor_ready(self) -> bool:
        try:
            result = self._sensor.read_one_value()
            return result.freqval <= 0x0FFFFFFF and result.freq > 0
        except Exception:
            return False
