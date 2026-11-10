# I2C Sensor Bench

A bus of vendor I2C sensor breakouts on their own host, for trying boards against their providers. It has no actuators and no behaviour tree, so a software e-stop has nothing to drive.

## On the bus

Bus 1 at the default 100 kHz, 3.3 V, on the Raspberry Pi header: pin 1 3.3 V, pin 3 SDA, pin 5 SCL, pin 6 GND.

| Device | Board | Type | Address |
| --- | --- | --- | --- |
| `adafruit0/rh0` | Adafruit SHT31-D | `sht3x` | `0x44` |
| `adafruit0/baro0` | Adafruit LPS22 | `lps22` | `0x5D` |
| `adafruit0/baro1` | Adafruit BMP390 | `bmp3xx` | `0x77` |
| `adafruit0/imu0` | Adafruit MPU-6050 | `mpu6050` | `0x68` |

## Set up the host

The host needs I2C on: `dtparam=i2c_arm=on` in `/boot/firmware/config.txt`, then a reboot. Check the wiring before installing:

```bash
i2cdetect -y 1
```

Every address in the table should appear.

The provider runs as the `anolis` service user, which needs the bus. `install.sh` stops if it does not have it:

```bash
id anolis || sudo useradd --system --shell /usr/sbin/nologin --home-dir /opt/anolis anolis
sudo usermod -aG i2c anolis
```

## Install

`install.sh` comes from the anolis release that `machine-profile.yaml` pins. From a clone of this repository:

```bash
PROJ=$PWD/projects/i2c-sensor-bench
RT=0.12.0
curl -fsSLO "https://github.com/anolishq/anolis/releases/download/v${RT}/install.sh"
curl -fsSLO "https://github.com/anolishq/anolis/releases/download/v${RT}/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS
sudo bash install.sh --project "$PROJ" --variant manual --keep-hostname
```

Without `--keep-hostname`, an arm64 host is renamed `anolis-<serial>`.

## Add a board

1. Connect it with the host powered off, and confirm it appears in `i2cdetect -y 1`.
2. Add it under `devices` in `config/provider-adafruit.sensor-bench.yaml`, at an address nothing else on the bus uses, and add a row to the table above.
3. For another vendor's provider, add it under `providers` in the runtime config, and under `providers` and `components.providers` in `machine-profile.yaml`.
4. Re-run the install with `--replace-config`, because an upgrade otherwise keeps the existing `runtime.yaml`.
