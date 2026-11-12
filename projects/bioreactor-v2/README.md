# Bioreactor v2

Placeholder for the lab-grade bioreactor. It follows from [bioreactor-v1](../bioreactor-v1/): the same stirring, dosing, sampling and heating, with the sensors below added. The vessel and hardware design are in [uwo-fast/lab-grade-bioreactor](https://github.com/uwo-fast/lab-grade-bioreactor).

Nothing here is deployable yet. `machine-profile.yaml` points at bioreactor-v1's configs and has no `components:` block, so `install.sh` has no versions to install from it.

## Sensors

| Measurement | Sensor | Range | Against v1 |
| --- | --- | --- | --- |
| pH | [Atlas Scientific research-grade pH probe](https://atlas-scientific.com/probes/research-grade-ph-probe/) | −1.6 to 15.6 pH | Read in v1 (`ezo0/ph0`) |
| Dissolved oxygen | [Atlas Scientific dissolved oxygen probe](https://atlas-scientific.com/probes/dissolved-oxygen-probe/) | 0 to 100 mg/L | Read in v1 (`ezo0/do0`) |
| CO2, off-gas | [Atlas Scientific CO2 sensor](https://atlas-scientific.com/probes/co2-sensor/) | 0 to 10,000 ppm | New |
| O2, off-gas | [Atlas Scientific oxygen sensor](https://atlas-scientific.com/probes/oxygen-sensor/) | 0 to 42 % | New |
| Temperature | [Omega PR-10 RTD probe](https://www.dwyeromega.com/en-us/rtd-probe-with-insulated-wire-and-shrink-tube-support/PR-10/p/PR-10L-4-100-1-8-12) | −100 to 450 °C | New: v1 reads thermocouples on `bread0/rlht0` |

## Status

As of 2026-11-11:

- **CO2 and O2.** The sensors are on order. Reads for both are merged in [feastorg/ezo-driver](https://github.com/feastorg/ezo-driver) but not released, and have not been run on a circuit: the 0.9.0 release waits on the bench check in [feastorg/ezo-driver#48](https://github.com/feastorg/ezo-driver/issues/48). After that release, [anolis-provider-ezo](https://github.com/anolishq/anolis-provider-ezo) needs the new driver and a `co2` and an `o2` device type, which it does not have.
- **Temperature.** How the RTD is read is not decided. anolis-provider-ezo has an `rtd` device type, for an EZO-RTD circuit.
- **pH and dissolved oxygen.** Unchanged from v1.
