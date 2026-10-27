# 阶段进展

## 2026-10-27 第一阶段

范围：初始化、实施计划与最小注入 Tweak。目标 Bundle ID：`com.korea.mrtgd2.ios`。

已实现：

- 从 create-theos-project 技能生成工程并修改源码；当前目录无同名项目或额外 AGENTS.md。
- Objective-C++/Logos 加载入口、精确 Bundle 二次校验、按构建方案检查系统下限、一次统一日志。
- Rootless iOS 15+ / Rootful iOS 14+ 独立 TYPE 配置，默认 Rootless，不猜测进程名或自动杀进程。
- 目标配置脚本、静态检查脚本、README、设备验收和兼容性边界、分阶段数据/隐私架构计划。
- 未运行的 Rootless GitHub Actions 骨架；正式 CI/包体验收保留到阶段 6。

环境：Windows PowerShell；Python 3.9.10、Git、PyYAML 可用。PATH 未发现 make/gmake、clang、perl、dpkg-deb、xcodebuild；THEOS 未设置。`wsl --list --quiet` 和 `wsl --status` 返回退出码 1，未获取到可用发行版信息。没有可用于本项目验证的 iOS 设备会话。

实际验证结果：

- `python scripts/set_target.py com.korea.mrtgd2.ios`：退出码 0；实际更新 Filter 与头文件。
- `python scripts/check_project.py --require-yaml --environment`：退出码 0；plist/YAML 解析、control 字段、目标一致性、构建设置、UTF-8/LF 与模板残留检查通过。
- Python AST 解析两个脚本：通过。
- 临时目录执行目标切换：plist 与运行时头文件同步为 `com.example.validation`；六种非法输入（通配符、缺少分段、换行、引号、路径分隔符等）均拒绝且文件未变化；通过。正式工程目标保持 `com.korea.mrtgd2.ios`。
- 未执行 iOS 编译、deb 检查、CI、安装、加载日志或稳定性测试，不能标记“编译成功”或“可安装性已验证”。

阶段 1 状态：源码基线与静态检查完成；构建/设备验收待执行。当前没有编译产物。

下一步：有工具链时构建本基线并按 `DEVICE_VALIDATION.md` 验收，随后实现 NSURLSession dataTask completion 路径。阶段 2–6 业务源码尚未开始。

## 2026-10-27 GitHub Actions 编译

用户明确授权新建私有仓库、上传源码并运行编译。已创建 [wwangmc/TrafficMonitor](https://github.com/wwangmc/TrafficMonitor)，提交第一阶段源码并由 push 自动触发 workflow。

- [Run #1](https://github.com/wwangmc/TrafficMonitor/actions/runs/40442530548) 成功完成，源码提交 `be1b37543cba76dd543f728431996aabcdc87e9e`。
- 新增 `scripts/inspect_deb.py`：实际检查 deb 身份、包架构、Rootless 文件路径、Filter、Mach-O 切片与依赖，并生成报告；CI 步骤通过。
- Rootless deb 已下载到本地，ZIP SHA-256 与 GitHub Artifact digest 一致；本地再次检查包内容通过。
- 编译产物：`com.example.trafficmonitor_0.1.0_iphoneos-arm64.deb`，arm64/arm64e、iOS 15.0+。详细哈希、工具链与限制见 `BUILD_VERIFICATION.md`。
- Rootful 构建、真机安装/注入和阶段 2–6 的完整业务能力仍待验证。第一阶段的“尚未编译”记录是首次初始化时状态，以本节为当前状态。

当前状态：第一阶段源码、静态检查、Rootless CI 编译和包内容检查完成；真机验收待执行。

## 2026-10-27 真机验证

用户已安装编译产物并连接电脑。当前设备为 iPhone X / iOS 16.1.1，Rootless + ElleKit 1.2。

- 已核对安装包版本、设备 Filter 和 dylib SHA-256；安装的 dylib 与 CI 包内文件一致。
- USB 统一日志捕获三次目标冷启动的 `stage=1 event=loaded`，PID 为 31600、31669、31709，每个 PID 各一次。
- 实际查看游戏资源下载与公告界面；切到设置再返回游戏，设置进程未观察到本插件日志。
- 第三个 PID 完成 301.5 秒、11 次存活采样，始终为同一目标进程；末次进程运行时长 05:43，前台仍为游戏。观察后已结束电脑端日志监听与采样。详细证据与限制见 `DEVICE_RUN_2026-10-27.md`。
- 本次未改插件源码、未安装/卸载软件、未重启设备；只结束并重新打开目标游戏两次，验证重复冷启动。

当前状态：第一阶段 Rootless 构建、包检查与此设备上的基础注入验收通过。后续可进入 NSURLSession 监控实现；当前没有 HTTP/Socket 数据采集能力。

## 2026-10-27 第二阶段开发（0.2.0）

已实现 URL/Request dataTask completion、嵌套工厂去重、首次 resume 计时、事件/脱敏、256 槽位 trylock 队列、异步 JSONL 和两段轮转。附带同源 tm-probe，显式执行才使用 loopback fixture 验证 40 个合成 HTTP 任务和 queue 压力。CI 新增 macOS native probe，再编译 iOS 包。

静态检查通过，实际 CI/真机结果待执行。delegate、upload/download、CFNetwork 和 Socket 未覆盖，详见 `STAGE2_NSURLSESSION.md`。
