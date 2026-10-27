# Rootless 构建验证（2026-10-27）

用户明确授权创建 `wwangmc/TrafficMonitor` 私有仓库、上传源码和运行 workflow。仓库已创建，未改变其他仓库。

## 实际构建证据

- [GitHub Actions run #1](https://github.com/wwangmc/TrafficMonitor/actions/runs/40442530548)：`completed / success`。
- 编译源码提交：`be1b37543cba76dd543f728431996aabcdc87e9e`。
- 开始：2026-10-27 11:08:55（Asia/Shanghai）；总耗时 1 分 13 秒。
- runner：macOS 15.7.9；Xcode 16.4（16F6）；TYPE=1；arm64、arm64e。
- RootHide Theos SHA：`cfba89a53a05b4a1b822121158acc3669c20602f`。
- theos/sdks SHA：`0222fd5413cf4b9af096f37b4621afa2688572f7`；SDK 目录为 iPhoneOS16.5.sdk，Mach-O 中 SDK 元数据报告 16.4。
- 编译、链接、签名、打包、deb 检查和上传均成功。

## 成品

- 文件：`com.example.trafficmonitor_0.1.0_iphoneos-arm64.deb`，4186 字节。
- SHA-256：`0bed2a671d46e7307d6e35198ddd95379c8d2c0e8510a64e82995de85fb5c388`。
- 包架构：`iphoneos-arm64`；dylib 切片：`arm64 arm64e`；检查报告包含最低系统 `minos 15.0` 和 Rootless rpath。
- 包内文件仅有 `var/jb/Library/MobileSubstrate/DynamicLibraries/TrafficMonitor.dylib` 与 `TrafficMonitor.plist`。
- Filter 仅包含 `com.korea.mrtgd2.ios`，与源码一致。
- [Rootless Artifact](https://github.com/wwangmc/TrafficMonitor/actions/runs/40442530548/artifacts/12707061218)：含 deb 和完整 `package-inspection.json`。
- Artifact ZIP SHA-256：`6cf58ec6bdf78ebc637a5654fca1a57b1ac417369942c4fe6500f000903dcc61`；本地下载后复核一致。
- 本地 `packages/ci-40442530548/` 已解包；再次执行 `scripts/inspect_deb.py`，包身份、路径与 Filter 检查通过。Windows 不具备 lipo/otool，其检查结果来自 CI。

## 限制

这次 CI 只验证第一阶段 Rootless 构建。后续已在 iPhone X / iOS 16.1.1 验证安装文件与目标 App 注入，见 `DEVICE_RUN_2026-10-27.md`。Rootful 编译、HTTP、Socket、SQLite 和 WebUI 未验证/未实现。

日志存在非致命警告：Theos 链接参数 `-multiply_defined` 已过时；Actions v4 的 Node 20 元数据被 runner 强制转为 Node 24。它们没有阻止此次构建，后续升级工具链时需再验证。

文档结果提交使用 `[skip ci]`，避免仅更新记录触发重复构建。成功 run 对应的是上面的准确源码提交，不能把后续监控功能视为已经通过本次编译。
