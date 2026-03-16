from typing import TYPE_CHECKING, cast

from cartographer.adapters.kalico.adapters import KalicoAdapters
from cartographer.adapters.kalico.integrator import KalicoIntegrator
from cartographer.adapters.klipper.adapters import KlipperAdapters
from cartographer.adapters.klipper.integrator import KlipperIntegrator
from cartographer.runtime.adapters import Adapters
from cartographer.runtime.environment import Environment, detect_environment
from cartographer.runtime.integrator import Integrator

if TYPE_CHECKING:
    from configfile import ConfigWrapper as KlipperConfigWrapper


def init_adapter(config: object) -> Adapters:
    env = detect_environment(config)
    if env == Environment.Klipper:
        from cartographer.adapters.klipper.adapters import KlipperAdapters

        return KlipperAdapters(cast("KlipperConfigWrapper", config))
    if env == Environment.Kalico:
        from cartographer.adapters.kalico.adapters import KalicoAdapters

        return KalicoAdapters(cast("KlipperConfigWrapper", config))

    msg = f"Unsupported environment: {env}"
    raise RuntimeError(msg)


def init_eddy_adapter(config: object, sensor: object) -> Adapters:
    from cartographer.adapters.eddy.adapters import EddyAdapters

    return EddyAdapters(cast("KlipperConfigWrapper", config), sensor)


def init_integrator(adapters: Adapters) -> Integrator:
    from cartographer.adapters.eddy.adapters import EddyAdapters

    if isinstance(adapters, KlipperAdapters):
        return KlipperIntegrator(adapters)
    if isinstance(adapters, KalicoAdapters):
        return KalicoIntegrator(adapters)
    if isinstance(adapters, EddyAdapters):
        from cartographer.adapters.eddy.integrator import EddyIntegrator

        return EddyIntegrator(adapters)

    msg = "Unsupported adapters"
    raise RuntimeError(msg)
