# xgc2-zenoh

This repository pins the Zenoh ecosystem sources used by XGC2 as Git
submodules.

Repository: <https://github.com/XGC-Team/xgc2-zenoh>

## Usage

```bash
git clone --recurse-submodules https://github.com/XGC-Team/xgc2-zenoh.git
```

Initialize submodules in an existing checkout:

```bash
git submodule update --init --recursive
```

Show the pinned revisions:

```bash
git submodule status
```

## Submodules

Each submodule tracks its official upstream repository. Personal forks are
not used.

| Path | Upstream | Purpose |
| --- | --- | --- |
| `rmw_zenoh` | [ros2/rmw_zenoh](https://github.com/ros2/rmw_zenoh) | ROS 2 RMW implementation over Zenoh |
| `zenoh` | [eclipse-zenoh/zenoh](https://github.com/eclipse-zenoh/zenoh) | Zenoh core: pub/sub, query, and storage |
| `zenoh-backend-influxdb` | [eclipse-zenoh/zenoh-backend-influxdb](https://github.com/eclipse-zenoh/zenoh-backend-influxdb) | InfluxDB backend for time-series storage |
| `zenoh-cpp` | [eclipse-zenoh/zenoh-cpp](https://github.com/eclipse-zenoh/zenoh-cpp) | Zenoh C++ API |
| `zenoh-pico` | [eclipse-zenoh/zenoh-pico](https://github.com/eclipse-zenoh/zenoh-pico) | Lightweight client for embedded devices |
| `zenoh-plugin-dds` | [eclipse-zenoh/zenoh-plugin-dds](https://github.com/eclipse-zenoh/zenoh-plugin-dds) | DDS bridge |
| `zenoh-plugin-mqtt` | [eclipse-zenoh/zenoh-plugin-mqtt](https://github.com/eclipse-zenoh/zenoh-plugin-mqtt) | MQTT bridge |
| `zenoh-plugin-ros2dds` | [eclipse-zenoh/zenoh-plugin-ros2dds](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds) | ROS 2 / DDS forwarder |
| `zenoh-plugin-webserver` | [eclipse-zenoh/zenoh-plugin-webserver](https://github.com/eclipse-zenoh/zenoh-plugin-webserver) | HTTP / Web access plugin |
| `zenoh-python` | [eclipse-zenoh/zenoh-python](https://github.com/eclipse-zenoh/zenoh-python) | Zenoh Python API |
