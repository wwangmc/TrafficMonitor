# TrafficMonitor

Theos + Objective-C++/Logos 的 iOS 越狱网络监控工程。**目前交付第一阶段：指定进程注入基线，已通过 GitHub Actions Rootless 编译、包内容检查，以及 iPhone X / iOS 16.1.1 上三次冷启动的真实注入验证。HTTP、Socket、SQLite 和 WebUI 尚未实现。**

私有仓库：[wwangmc/TrafficMonitor](https://github.com/wwangmc/TrafficMonitor)。[成功构建 #1](https://github.com/wwangmc/TrafficMonitor/actions/runs/40442530548) · [Rootless 产物](https://github.com/wwangmc/TrafficMonitor/actions/runs/40442530548/artifacts/12707061218) · [验证记录](docs/BUILD_VERIFICATION.md)。

目标为 `com.korea.mrtgd2.ios`。加载入口只校验 Bundle ID、系统版本并输出一次日志：`stage=1 event=loaded ... capture=disabled`。不会主动发请求、监听端口或记录业务数据；不猜测目标可执行文件名，不自动杀进程。

## 构建配置

| 方案 | make 参数 | 默认架构 | 最低部署目标 |
| --- | --- | --- | --- |
| Rootless（默认） | `TYPE=1` | arm64、arm64e | iOS 15.0 |
| Rootful（独立） | `TYPE=0` | arm64 | iOS 14.0 |

优先 Dopamine + ElleKit Rootless。**Dopamine 不是 iOS 14 越狱方案**；iOS 14 Rootful 需要自己的越狱和兼容注入器，必须独立验证。部署下限不代表设备、系统或游戏均兼容。Rootful arm64e 可另传 `ARCHS="arm64 arm64e"`，但尚未验证。

Theos scheme 负责安装前缀与成品架构：control 保留基础 `iphoneos-arm`，Rootless 成品应为 `iphoneos-arm64`。源码不硬编码资源安装根目录，不提供 RootHide 构建模式。依据：[Theos Rootless](https://theos.dev/docs/rootless)、[Dopamine](https://github.com/opa334/Dopamine)、[ElleKit](https://github.com/tealbathingsuit/ellekit)。

## Windows 静态检查与目标配置

在本目录运行（Python 3.9+）：

```powershell
python scripts/check_project.py --environment --require-yaml
python scripts/set_target.py com.korea.mrtgd2.ios
```

静态检查覆盖 plist、Filter/运行时目标一致性、control、Makefile、UTF-8/LF 与 workflow YAML；不代替编译。`--require-yaml` 需要 PyYAML（`python -m pip install PyYAML`）。不带该参数时，若没有依赖会明确跳过 YAML 解析。

目标脚本同步更新 `TrafficMonitor.plist` 与 `Sources/TMTarget.h`，只接受精确 Bundle ID。修改后重编译、重装并冷启动目标 App。普通 App 与游戏使用相同过滤方式，是否允许注入必须逐个验证。

## macOS 本地构建

需完整 Xcode、Theos、GNU make、ldid、xz、iPhoneOS16.5.sdk。CI 沿用技能的 RootHide Theos fork 和补丁 SDK；本工程只使用普通 Rootless/Rootful scheme。环境安装见 [Theos macOS 指南](https://theos.dev/docs/installation-macos)。

```sh
export THEOS=/path/to/theos
python3 scripts/check_project.py
gmake TYPE=1 clean
gmake -j2 TYPE=1 FINALPACKAGE=1 package
```

产物输出到 `packages/`。独立构建 iOS 14 Rootful：

```sh
gmake TYPE=0 clean
gmake -j2 TYPE=0 FINALPACKAGE=1 package
```

GNU make 若命名为 `make` 可替换 `gmake`。更换 SDK 可传 `TM_SDK=<已安装版本>`，需要重新验证。切换 TYPE、SDK、架构时先 clean。

## GitHub Actions 构建

`.github/workflows/build.yml` **已运行成功并生成 Rootless deb**。默认只构建 Rootless，使用 `macos-15`、Xcode 16.4、RootHide Theos 和 iPhoneOS16.5.sdk，自动检查 deb 路径、包架构、dylib 切片和 Filter。Theos/SDK 跟踪远程分支并打印 SHA，暂非完全可重现构建。阶段 6 的完整监控链路验收仍待后续实现。

1. 将本目录内容作为 GitHub 仓库根目录，包含隐藏的 `.github/`。若位于其他仓库子目录，应先调整 workflow 位置及工作目录。
2. 推送 main/master，或从 **Actions → Build Theos packages → Run workflow** 手动运行。
3. 成功 run 的 **Artifacts → TrafficMonitor-rootless** 包含 `packages/*.deb` 与 `package-inspection.json`；日志为 `build-log-rootless`。Artifacts 保留 14 天，私有仓库下载需要登录有权限的 GitHub 账号。

## 安装与使用

只安装匹配当前越狱的构建产物。用 Sileo/Zebra 打开 deb，或在设备有权限的 shell 执行 `dpkg -i <实际包路径>`。`mobilesubstrate` 是兼容注入接口依赖；Dopamine 使用其正常安装的 ElleKit，不要为此混装注入器。

安装后完全结束目标 App 再打开，观察 subsystem `com.example.trafficmonitor`、category `bootstrap` 的统一日志。若环境提供 `log`，在打开 App 前运行：

```sh
log stream --level info --predicate 'subsystem == "com.example.trafficmonitor"'
```

没有设备端 `log` 时使用 macOS Console 连接设备观察。预期有 `event=loaded`、`bundle=com.korea.mrtgd2.ios`、实际 PID、对应 mode 和 `capture=disabled`。该日志仅证明本次初始化，不能证明网络监控能力。详细包内容、负例与卸载验证见 [设备验收步骤](docs/DEVICE_VALIDATION.md)。用包管理器移除，或 `dpkg -r com.example.trafficmonitor` 后重启目标 App；本阶段无数据库。

## 后续路线与数据边界

- [实施计划](docs/IMPLEMENTATION_PLAN.md)：NSURLSession → Socket → SQLite → WebUI → CI 集成；含异步采集、沙盒 IPC 与隐私约束。
- [阶段进展](docs/PROGRESS.md)：实际检查与尚未验证的内容。
- [真机验收记录](docs/DEVICE_RUN_2026-10-27.md)：安装文件一致性、实际加载日志和设备测试边界。
- [兼容性矩阵](docs/COMPATIBILITY.md)：Network.framework、CFNetwork、libcurl、Unity/Unreal 的待测路径。

HTTP 请求/应用数据与 Socket 字节将分开存储。Socket 用户态调用返回字节不能标为真实网络层流量，也不能与 HTTP 字节相加。后续 Web/collector 只监听 `127.0.0.1`，要求认证、URL 脱敏和记录清理；这些功能尚未实现。
