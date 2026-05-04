# xgc2-zenoh

本仓库用 Git submodule 固定 XGC2 相关的 Zenoh 生态源码版本。

## 使用

```bash
git clone --recurse-submodules <repo-url>
```

已有仓库初始化 submodule：

```bash
git submodule update --init --recursive
```

查看当前固定版本：

```bash
git submodule status
```

## Submodules

- `rmw_zenoh`: ROS 2 的 Zenoh RMW 实现，用于让 ROS 2 通过 Zenoh 进行通信。
- `zenoh`: Zenoh 核心实现，提供数据分发、查询和存储抽象。
- `zenoh-backend-influxdb`: Zenoh 的 InfluxDB 后端，用于把 Zenoh 数据写入或查询时间序列数据库。
- `zenoh-cpp`: Zenoh C++ API，用于在 C++ 程序中接入 Zenoh。
- `zenoh-pico`: 轻量级 Zenoh 客户端实现，面向嵌入式和资源受限设备。
- `zenoh-plugin-dds`: Zenoh DDS 插件，用于桥接 DDS 数据空间。
- `zenoh-plugin-mqtt`: Zenoh MQTT 插件，用于桥接 MQTT 客户端和 Zenoh 网络。
- `zenoh-plugin-ros2dds`: Zenoh ROS 2/DDS 插件，用于在 Zenoh 和 ROS 2/DDS 之间转发数据。
- `zenoh-plugin-webserver`: Zenoh WebServer 插件，用于通过 HTTP/Web 接口访问 Zenoh 能力。
- `zenoh-python`: Zenoh Python API，用于在 Python 程序中接入 Zenoh。
