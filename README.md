# xgc2-zenoh

本仓库用 Git submodule 固定 XGC2 相关的 Zenoh 生态源码版本。

仓库地址：<https://github.com/XGC-Team/xgc2-zenoh>

## 使用

```bash
git clone --recurse-submodules https://github.com/XGC-Team/xgc2-zenoh.git
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

子模块一律跟踪上游公开仓库，不经过个人 fork。

| 路径 | 上游仓库 | 说明 |
| --- | --- | --- |
| `rmw_zenoh` | [ros2/rmw_zenoh](https://github.com/ros2/rmw_zenoh) | ROS 2 的 Zenoh RMW，让 ROS 2 走 Zenoh 通信 |
| `zenoh` | [eclipse-zenoh/zenoh](https://github.com/eclipse-zenoh/zenoh) | Zenoh 核心：数据分发、查询和存储 |
| `zenoh-backend-influxdb` | [eclipse-zenoh/zenoh-backend-influxdb](https://github.com/eclipse-zenoh/zenoh-backend-influxdb) | InfluxDB 后端，读写时间序列 |
| `zenoh-cpp` | [eclipse-zenoh/zenoh-cpp](https://github.com/eclipse-zenoh/zenoh-cpp) | Zenoh C++ API |
| `zenoh-pico` | [eclipse-zenoh/zenoh-pico](https://github.com/eclipse-zenoh/zenoh-pico) | 面向嵌入式的轻量客户端 |
| `zenoh-plugin-dds` | [eclipse-zenoh/zenoh-plugin-dds](https://github.com/eclipse-zenoh/zenoh-plugin-dds) | DDS 桥 |
| `zenoh-plugin-mqtt` | [eclipse-zenoh/zenoh-plugin-mqtt](https://github.com/eclipse-zenoh/zenoh-plugin-mqtt) | MQTT 桥 |
| `zenoh-plugin-ros2dds` | [eclipse-zenoh/zenoh-plugin-ros2dds](https://github.com/eclipse-zenoh/zenoh-plugin-ros2dds) | ROS 2 / DDS 转发 |
| `zenoh-plugin-webserver` | [eclipse-zenoh/zenoh-plugin-webserver](https://github.com/eclipse-zenoh/zenoh-plugin-webserver) | HTTP / Web 访问入口 |
| `zenoh-python` | [eclipse-zenoh/zenoh-python](https://github.com/eclipse-zenoh/zenoh-python) | Zenoh Python API |
