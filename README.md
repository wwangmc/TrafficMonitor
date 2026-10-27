# TrafficMonitor

面向已越狱 iPhone 的网络观测工具：Theos Objective-C++ Tweak 采集，电脑通过 USB 增量同步，SQLite 保存历史，本地 WebUI 实时展示。默认目标 **com.korea.mrtgd2.ios**，可在界面中选择最多 8 个普通 App 或游戏。

## 使用

1. 手机安装 Actions 生成的 Rootless `.deb`，完全结束并重新打开目标应用。
2. 电脑连接并信任 iPhone；安装 Python 3.9+、Apple USB 驱动。当前桌面采集器使用这台手机已安装的 **MKS 管理插件（8081 / roothelp）**，通过 USB 访问；无需手工创建端口转发。新设备若没有 MKS，Tweak 仍能生成诊断文件，但桌面实时同步和应用配置不可用。
3. Windows 双击项目根目录 **start.cmd**，首次自动安装 `tidevice==0.12.10`，直接打开本地观测台。保持启动窗口运行，退出用 Ctrl+C。
4. 点击「监控应用」选择目标，保存后完全退出并重新打开新选应用。「暂停/恢复」通过 USB 同步，约 1 秒后影响运行中的采集器。

服务只绑定 **127.0.0.1:27681**。直接打开 http://127.0.0.1:27681/ 即可使用，无需访问令牌或登录。USB 断开仍可查看电脑已经保存的历史。

手动运行：`python desktop/trafficmonitor.py`。多设备用 `--udid`，仅查看历史用 `--offline`，换端口用 `--port`。数据默认保存在 `desktop/data/trafficmonitor.sqlite3`，不随源码上传。

## 可视化界面

- 总览：上传/下载速度、时间曲线、HTTP 请求数量/错误/耗时、活跃 Socket 会话。
- HTTP：方法、完整结构的脱敏 URL、状态码、耗时、请求/响应应用数据字节；支持搜索、状态筛选、详情。
- Socket：TCP/UDP、IPv4/IPv6、远程 IP/端口、描述符会话累计上传/下载字节与状态。
- 汇总与历史：按域名计算请求数，按 IP/协议计算窗口内字节，5 分钟/1 小时/24 小时/7 天，自动保留 1/3/7 天，导出当前窗口与清理。

HTTP 和 Socket 分表保存、分别展示，**不能相加当作总流量**。Socket 指用户态 API 成功返回的数据长度，不包含 TCP/IP 头、链路头、重传或其他进程流量。详见 [架构与计量边界](docs/ARCHITECTURE.md)、[兼容性](docs/COMPATIBILITY.md) 和 [使用说明](docs/USAGE.md)。

## 构建与安装

[GitHub Actions](https://github.com/wwangmc/TrafficMonitor/actions/workflows/build.yml) 自动执行静态检查、SQLite/API 集成测试、原生 HTTP/Socket 诊断、Rootless 编译、包内路径及 Mach-O 检查，上传 `TrafficMonitor-rootless` 与 `TrafficMonitor-Desktop`。

Rootless：`make TYPE=1 clean package`，iOS 15+、arm64/arm64e，安装到 `/var/jb`，优先适配 Dopamine/ElleKit。部署下限不代表所有设备与所有游戏均已测试。

Rootful 独立方案：`make TYPE=0 ARCHS=arm64 clean package`，iOS 14+、传统安装前缀。**Dopamine 不是 iOS 14 越狱工具**。Rootful 目前预留并静态检查，未做 iOS 14 真机构建/运行验收。两个模式分别 clean，避免混用产物。

本机 Windows 无 Theos/Xcode，不声称本地完成 iOS 编译。实际包由 GitHub macOS runner 构建。Rootless 安装示例：`dpkg -i com.example.trafficmonitor_<version>_iphoneos-arm64.deb`；不需要自动重启 SpringBoard，只需冷启动监控应用。

## 工程

`Tweak.xm`、`Sources/` 为采集代码；`probe/` 为独立诊断工具；`desktop/` 为 SQLite/USB 服务与 WebUI；`scripts/` 为静态/安装包检查；`.github/workflows/build.yml` 为 CI。fishhook 授权和修改说明见 `THIRD_PARTY_LICENSES/`。

URL 的 query 值全部脱敏，移除 user/password/fragment，不采集 header、cookie、请求或响应正文。URL path 仍可能包含业务标识。手机日志每类最多 2×1 MiB，电脑每类最多 100,000 条并按保留期清理。WebUI 无需访问令牌，保留 Host/Origin 校验、CSP、参数化 SQL 与纯文本 DOM。

尚未宣称覆盖 CFNetwork HTTPStream、Network.framework/QUIC、所有 libcurl/Unity/Unreal 后端、后台系统进程或直接 syscall。已测结果与实际问题修复记录见 [进展](docs/PROGRESS.md) 及 [交付验收](docs/RELEASE_VERIFICATION.md)。
