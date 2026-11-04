# zenohd 1.8.0 supply — delivery receipt

状态：候选已封 SHA，等待 integration / 正式 CI；未 push、未发布、未操作现场。

## 1. 源码身份

| 项 | 值 |
| --- | --- |
| base | `cb8735562e5e52163179fc2872169fd31401c2bc` |
| candidate (HEAD) | `9934fcd02b81c006364d765984abb90fd33eb736` |
| 前序提交（Root 已源审） | `8a958f7` feat(zenoh): ship the official zenohd 1.8.0 router |
| 测试修正提交 | `9934fcd` fix(zenoh): prove zenohd readiness with an SDK client link |
| 隔离工作树 | `/tmp/opencode/zenohd-package`（detached） |
| 差异 | 6 files, +109 / -17 |
| patch 目录 | `/tmp/opencode/zenohd-evidence/patches/` |

改动文件：

- `.xgc2/scripts/build_zenoh.sh`
- `.xgc2/scripts/check_prefix.sh`
- `.xgc2/scripts/check_package_compliance.sh`
- `.xgc2/scripts/smoke_pubsub.sh`
- `.xgc2/product.yml`
- `zenoh.lock`

patch 文件：

- `0001-feat-zenoh-ship-the-official-zenohd-1.8.0-router-in-.patch`
  sha256 `1c4a96d9343186ba166ea7eb4fef79f96cc6fa655dcacf09a318bbe24c1ed55a`
- `0002-fix-zenoh-prove-zenohd-readiness-with-an-SDK-client-.patch`
  sha256 `a8d19b9b30d9da1de8dc6392c5bce6c52e86c7213cb8fe68c60d0b86511a6b2d`

Root 源审的 `8a958f7` 只差第二个测试提交；生产输入（`build_zenoh.sh`、lock、打包）未再变化。
`git range-diff cb87355..8a958f7 cb87355..HEAD` 显示 0001 完全相同，仅多出 0002。

两个 patch 依次 `git am` 到 base 后，树与 `9934fcd` 完全一致（`git diff` 为空）。

## 2. 上游固定点

`zenoh.lock` 新增：

```
ZENOH_RUST_ARCHIVE_SHA256=96c0dc13cb836bd9574a2dd357fe82591c72d50dbe850f5d561cfc2a1a0d5278
```

沿用：

```
ZENOH_RUST_REPOSITORY=https://github.com/eclipse-zenoh/zenoh.git
ZENOH_RUST_VERSION=1.8.0
ZENOH_RUST_SHA=29b3e63a311ab55f438280f3e71c6268b6f115cc
RUST_TOOLCHAIN=1.93.0
```

`build_zenoh.sh` 下载 `codeload.github.com/eclipse-zenoh/zenoh/tar.gz/${ZENOH_RUST_SHA}`，
先按上面的 archive SHA 校验，再在目标发行版容器内 `cargo fetch --locked` / 离线
`cargo build --release --locked --offline --package zenohd`，安装到唯一路径
`/opt/xgc2/zenoh/bin/zenohd`。不新增包、不新增第二份 binary、无 fallback 搜索。

## 3. Focal amd64 真实包

| 项 | 值 |
| --- | --- |
| 路径 | `/tmp/opencode/zenohd-package/.ci/debs/xgc2-zenoh_1.8.0-2~focal_amd64.deb` |
| SHA256 | `0ded418ecdb5a1d29aea54b07d6ecc49000df85c36e1190eeff5b7a2422995e8` |
| 大小 | 21,203,996 bytes |
| 版本 | `1.8.0-2~focal` (amd64) |
| Depends | `libc6, libgcc-s1, libstdc++6, python3` |

包内 `zenohd`：

| 项 | 值 |
| --- | --- |
| 唯一路径 | `./opt/xgc2/zenoh/bin/zenohd` |
| 权限/属主 | `-rwxr-xr-x root/root`, 15,708,944 bytes |
| SHA256 | `b9660ad8e9a949af87a459c58498f51ca01638e5cb20e73694e8ea3cc9622981` |
| 归属 | `dpkg -S /opt/xgc2/zenoh/bin/zenohd` → `xgc2-zenoh` |
| 包内匹配数 | `dpkg-deb -c ... | grep -c zenohd` = 1（无重复 binary） |

`zenohd --version` → `zenohd v1.8.0 built with rustc 1.93.0 (254b59607 2026-01-19)`。

## 4. 目标基线

| 项 | 值 |
| --- | --- |
| 构建/安装容器 | Ubuntu 20.04.6 LTS (Focal) |
| glibc | 2.31-0ubuntu9.17 |
| 编译器 | GNU 9.4.0 |
| Rust | 1.93.0（镜像内固定） |
| 构建镜像 | `ghcr.io/xgc-team/xgc2-images/xgc2-build-focal-dev:1.0.0` amd64 digest `sha256:91c2b3d2dd2d4e7aee3199219e82301dbb0343dd550b2a45eaaab21c944ac822` |
| 产物 GLIBC 上限 | `GLIBC_2.30`（≤ 2.31，本地与重建两次一致） |
| 动态依赖 | `libdl.so.2, libgcc_s.so.1, libpthread.so.0, libm.so.6, libc.so.6`（未引入 openssl 等新运行时依赖） |

对照：官方 `zenohd_1.8.0_amd64.deb` 控制字段为 `libc6 (>= 2.34)`，其
`usr/bin/zenohd` 最高需求 `GLIBC_2.34`；未放入本包，也没有向目标拷 host libc。
deployment-test 中挂 host glibc 运行该文件的结果不作为 Focal/2.31 证据。

## 5. 验证证据

日志目录 `/tmp/opencode/zenohd-evidence/`：

| 文件 | 内容 |
| --- | --- |
| `focal-rebuild.log` | Focal 容器内完整源码构建日志（1416 行，含 tarball 校验、cargo、`check_prefix`） |
| `focal-verify.log` | 安装前 `check_prefix`、包合规、`dpkg -i`、ownership、安装后 smoke（旧日志轮询版） |
| `focal-smoke-9934fcd.log` | 最终提交 `9934fcd` 的安装后 smoke |
| `patches/` | 两个 format-patch 文件 |

实际结果：

- `check_prefix.sh /w/.ci/prefix/zenoh-amd64 --arch amd64`
  → `glibc highest required: GLIBC_2.30 (baseline <= GLIBC_2.31)`
  → `zenoh prefix OK`
- `check_package_compliance.sh .ci/debs`
  → `compliance OK: xgc2-zenoh 1.8.0-2~focal amd64 (focal, python=yes)`
- `dpkg -i` 1.8.0-2~focal → `Setting up xgc2-zenoh (1.8.0-2~focal)`
- `smoke_pubsub.sh /opt/xgc2/zenoh`
  → C 动态/静态 pub/sub payload verified
  → `zenoh cxx include/link/session OK`
  → `zenohd UDP router start/stop OK (exit 143)`（SIGTERM 正常退出）

zenohd 就绪判定（按 Root 源审意见修正，`9934fcd`）：

- 复用同一 `smoke.cxx` 程序，带 endpoint 参数时以 `mode=client`、
  `connect/endpoints=["udp/127.0.0.1:<port>"]`、`connect/timeout_ms=5000`、
  `connect/exit_on_failure=true`、关闭 multicast scouting 打开 session；
  能退出 0 即证明链路建立。
- 已删除 100 轮日志轮询与 `"Zenoh can be reached at"` 字符串断言。
- 负向控制：对无监听端口运行同一 client，5 s 连接超时后 exit 1；
  readiness 不可能由日志文本或空跑通过。

## 6. 可重复构建事实

同一 candidate、同一 lock、同一 Focal 镜像、独立输出目录重建成功：

- 重建 `zenohd` 大小同为 15,708,944 bytes，版本/GLIBC 上限相同；
- 但 SHA256 为 `4c85f4fe7d35b77f1dcc4ba882fe3fe6f56880ddf777d664e440716b56eefcda`，
  与交付件 `b9660ad8...` 不同（Build ID 不同，两者都嵌入了各自的临时构建路径）。
- 结论：源码/工具链/体积/ABI 一致，但当前**不是逐字节可重复**；交付以
  `0ded418e...` 这个真实 Focal 包为准，不宣称 bit-reproducible。

## 7. 矩阵与未完成项

候选 SHA 尚未 push，因此没有 candidate 的 CI 结果；不改动现有矩阵角色：

| distro | amd64 | arm64 |
| --- | --- | --- |
| bionic | 未跑（base 绿） | 未跑（base 绿） |
| focal | **本地真实包已验证** | 未跑 |
| jammy | 未跑（base 绿） | 未跑（base 绿） |
| noble | 未跑（base 绿） | 未跑（base 绿） |

- base `cb87355` 的 CI run `41113597481`：8 个 `deb-build-and-smoke` 行全部 success。
- 四个构建镜像 manifest 均含 `amd64` + `arm64`；arm64 行使用 native
  `ubuntu-24.04-arm` runner，脚本用容器内 `dpkg --print-architecture` 取架构，无
  amd64 硬编码。未在本地用 qemu/host libc 冒充 arm64 结果。
- Focal arm64 还需要它自己的 native 行（含 Python 3.8 wheel 构建与 interop gate）。
- 本地 Focal 打包复用主仓既有
  `.ci/py/eclipse_zenoh-1.8.0-cp38-abi3-linux_x86_64.whl`（工作树 `.ci/py` 为空，
  该目录被 gitignore）；CI 内由 `build_python_binding.sh` 现场构建。

剩余：

1. 对 `9934fcd` 跑完整 native CI（8 行，重点 focal/arm64），绿后再进 release-orchestrator。
2. 正式发车由中央 APT 流程执行，本回执不发布。
3. （可选）如需 bit-reproducible，后续给 cargo 加 path remap；不影响本次交付。
