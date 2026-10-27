# 真机验收记录：2026-10-27

## 设备与已安装内容

- USB 连接的 iPhone X，iOS 16.1.1，Rootless 路径 `/var/jb`；具体越狱版本未查询。
- `dpkg-query` 确认 `com.example.trafficmonitor 0.1.0 iphoneos-arm64`、`ellekit 1.2 iphoneos-arm64` 已安装。
- 目标 App：`com.korea.mrtgd2.ios`，可执行文件 `mrtgd`，App 版本 1.1.0、build 20261015.1。
- 安装位置：`/var/jb/Library/MobileSubstrate/DynamicLibraries/TrafficMonitor.dylib` 与同名 plist。
- 实际读取已安装的二进制 Filter plist，内容为 `{"Filter":{"Bundles":["com.korea.mrtgd2.ios"]}}`。
- 设备 dylib 的 SHA-256 与本地 CI deb 内 dylib 一致：`88be5bdb36d46146b146a201ca67d09e80cceac3a6f589fa4c83bf0bc5692896`。

## 真实加载日志

通过 USB 读取统一日志，并用 MKS USB 通道核对前台应用与目标进程。观察到的三次冷启动记录（Asia/Shanghai）：

```text
2026-10-27 11:18:26.291139 mrtgd{TrafficMonitor.dylib}[31600] <NOTICE>: stage=1 event=loaded version=0.1.0 mode=rootless bundle=com.korea.mrtgd2.ios pid=31600 capture=disabled [com.example.trafficmonitor][bootstrap]
2026-10-27 11:20:48.385944 mrtgd{TrafficMonitor.dylib}[31669] <NOTICE>: stage=1 event=loaded version=0.1.0 mode=rootless bundle=com.korea.mrtgd2.ios pid=31669 capture=disabled [com.example.trafficmonitor][bootstrap]
2026-10-27 11:21:49.826635 mrtgd{TrafficMonitor.dylib}[31709] <NOTICE>: stage=1 event=loaded version=0.1.0 mode=rootless bundle=com.korea.mrtgd2.ios pid=31709 capture=disabled [com.example.trafficmonitor][bootstrap]
```

每个 PID 在本次连续日志观察中各出现一次初始化日志。第一次启动前未发现 `mrtgd` 进程；后两次仅向已核对路径的目标 PID 发送 SIGTERM，再重新打开相同 Bundle ID。未结束其他 App 或重启 SpringBoard。

## 界面、前后台与负例

- 实际查看了截图：游戏先显示资源下载界面，之后进入游戏公告界面，最终观察截图显示战斗界面；没有由验收脚本执行战斗操作。
- `/currApp` 先后确认游戏、`com.apple.Preferences`、返回游戏；设置 PID 为 31728。
- 负例窗口内没有观察到设置进程的 TrafficMonitor 初始化日志。精确 Filter 已核对；没有读取其他进程的内存映射，不能将“无日志”单独视为未映射该库的证明。
- 对第三个目标 PID 31709 完成 301.5 秒的存活采样（约每 30 秒一次，共 11 次），所有采样均为同一目标进程且存活；末次 `ps` 显示进程已运行 05:43。观察结束后 `/currApp` 仍为目标游戏，截图保存于本地 `packages/device-verified.png` 并实际查看。
- 观察期间未收到额外的 TrafficMonitor 初始化日志；之后已停止电脑端日志流与采样任务。本次采样只能说明观察窗口内进程存活，不代表完整游玩或所有交互稳定性测试。

## 验证边界与工具说明

确认的能力仅为：此设备上的已安装包与 CI 成品一致，Tweak 在指定游戏进程成功初始化，可重复冷启动。尚未验证 HTTP/Socket 监控、SQLite、WebUI、长时间游玩、其他机型、Rootful、卸载或反作弊兼容性。

设备没有 `log`、`pgrep` 或 `plutil` 命令；使用电脑端 pymobiledevice3 统一日志、设备 `ps` 和 MKS `readPlist` 完成对应检查。USB 工具使用现有信任配对，不在电脑创建额外监听端口。

已安装 MKS 的 `/screenshot_original` 声明 `image/jpeg`，实际字节为 PNG；任务临时适配器校验 PNG 魔数后保存原始数据并实际查看，不以 HTTP 成功代替画面验证。适配器、截图和观察数据位于本地忽略目录 `packages/`，不上传设备标识、配对证书或截图。
