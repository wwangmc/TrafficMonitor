# 第一阶段设备验收

以下是待执行步骤，不是测试通过报告。当前没有 iOS 编译、安装或注入证据。

## 构建与包内容

执行 README 的静态检查与 macOS 构建命令，保留构建日志、Xcode 版本、Theos/SDK SHA、TYPE、ARCHS、deb 文件名和 SHA-256。在具备 dpkg 工具的主机或设备检查实际包：

```sh
package_path=/path/to/actual.deb
dpkg-deb -f "$package_path" Package Architecture Depends
dpkg-deb -c "$package_path"
```

Rootless 预期架构 `iphoneos-arm64`，dylib/Filter 位于 `./var/jb/Library/MobileSubstrate/DynamicLibraries/TrafficMonitor.*`；Rootful 预期 `iphoneos-arm` 和 `./Library/MobileSubstrate/DynamicLibraries/TrafficMonitor.*`。不能仅凭 control 源文件判断成品。解包后用 `plutil -lint` 检查 plist、`lipo -info` 检查切片、`otool -l`/`otool -L` 检查最低系统、依赖与 rpath；Rootless 不应依赖错误的 Rootful 注入库绝对路径。

## 注入、稳定性与负例

1. 记录设备型号、iOS、越狱/注入器版本；确认目标 App 开启 tweak 注入。
2. 安装匹配的包。工程不自动结束 App 或重启 SpringBoard。
3. 先观察 subsystem `com.example.trafficmonitor` 日志，再完全结束并打开 `com.korea.mrtgd2.ios`。
4. 预期该 PID 出现一次 `stage=1 event=loaded ... mode=rootless bundle=com.korea.mrtgd2.ios ... capture=disabled`；Rootful 包的 mode 为 rootful。
5. 再冷启动两次，确认新 PID 各有一次日志；运行至少 5 分钟，测试基础操作和前后台切换，记录崩溃或异常。
6. 打开其他 App，确认其 PID 没有该日志；确认已安装 Filter 只有目标 Bundle，无全进程或 Executables 过滤。

没有日志时检查真实 Bundle ID、安装包内容、注入开关、缓存/冷启动、签名/依赖/架构和统一日志读取权限。游戏反注入/反作弊可能阻止加载，应保留失败与崩溃记录，不能承诺绕过。Rootful arm64e 必须独立构建/验证。

本阶段没有 hooks、业务数据库或 listener，不能以无 HTTP 数据或无 WebUI 判断注入失败；加载成功也不能证明后续网络兼容性。

## 卸载

用包管理器卸载，或 `dpkg -r com.example.trafficmonitor`；冷启动目标 App，新 PID 应不再出现加载日志。不要删除其他 tweak 或注入器。本阶段无业务数据库需清理。

## 验收记录

| 项目 | 结果 |
| --- | --- |
| 设备 / iOS / 越狱 / 注入器 | 未执行 |
| 构建日志 / CI run URL | 未执行 |
| 包文件 / SHA-256 / 架构 / 路径 | 未执行 |
| 目标日志 / PID / 非目标负例 | 未执行 |
| 稳定性 / 卸载 | 未执行 |
