# TrafficMonitor

面向已越狱 iPhone 的网络观测工具：Theos Objective-C++ Tweak 采集，电脑通过 USB 增量同步，SQLite 保存历史，本地 WebUI 实时展示。默认目标 **com.korea.mrtgd2.ios**，可在界面中选择一个普通 App 或游戏。

## 使用

1. 手机安装 Actions 生成的 Rootless `.deb`，完全结束并重新打开目标应用。
2. 电脑连接并信任 iPhone；安装 Python 3.9+、Apple USB 驱动。当前桌面采集器使用这台手机已安装的 **MKS 管理插件（8081 / roothelp）**，通过 USB 访问；无需手工创建端口转发。新设备若没有 MKS，Tweak 仍能生成诊断文件，但桌面实时同步和应用配置不可用。
3. Windows 双击项目根目录 **start.cmd**，首次自动安装 `tidevice==0.12.10`，直接打开本地观测台。保持启动窗口运行，退出用 Ctrl+C。
4. 在「监控应用」下拉框中选择目标，自动保存；完全退出并重新打开新选应用后，请求会自动显示。

服务只绑定 **127.0.0.1:27681**。直接打开 http://127.0.0.1:27681/ 即可使用，无需访问令牌或登录。USB 断开仍可查看电脑已经保存的历史。

手动运行：`python desktop/trafficmonitor.py`。多设备用 `--udid`，仅查看历史用 `--offline`，换端口用 `--port`。数据默认保存在 `desktop/data/trafficmonitor.sqlite3`，不随源码上传。

## 可视化界面

一个应用下拉框，「按请求 / 按域名」切换，以及「删除记录」按钮。请求视图显示最近200条请求的URL和大小；域名视图汇总当前应用全部已保存请求，按URL主机名合并。两个视图均按大小从大到小排列，未知放在最后，不展示速度曲线等额外面板。

大小为请求body与响应应用数据长度之和；请求任一项未知时显示「未知」。域名中含有未知请求时，以「≥ 已知合计」表示下限，全未知时显示「未知」，不混入Socket字节或报头。URL参数值继续脱敏。

「删除记录」需确认，只清理当前应用的电脑历史与其手机采集日志，不影响其他应用。旧日志重新读入会按应用删除时间过滤；新的请求仍会继续显示。详见 [使用说明](docs/USAGE.md)。

底层采集与历史存储保留；计量和覆盖边界见 [架构](docs/ARCHITECTURE.md) 与 [兼容性](docs/COMPATIBILITY.md)。

## 构建与安装

[GitHub Actions](https://github.com/wwangmc/TrafficMonitor/actions/workflows/build.yml) 自动执行静态检查、SQLite/API 集成测试、原生 HTTP/Socket 诊断，独立编译 Rootful、Rootless、RootHide，检查包内路径与 Mach-O，上传三个环境的 deb 与桌面版。0.4.0 三种包已在 [run 40459242763](https://github.com/wwangmc/TrafficMonitor/actions/runs/40459242763) 全部编译成功。

Rootless：`make TYPE=1 clean package`，iOS 15+、arm64/arm64e，安装到 `/var/jb`，优先适配 Dopamine/ElleKit。部署下限不代表所有设备与所有游戏均已测试。

Rootful 独立方案：`make TYPE=0 ARCHS=arm64 clean package`，iOS 14+、传统安装前缀。**Dopamine 不是 iOS 14 越狱工具**。Rootful 已完成 CI 编译和安装包检查，未做 iOS 14 真机运行验收。

RootHide：`make TYPE=2 clean package`，iOS 15+、arm64/arm64e、`iphoneos-arm64e` 包架构。已完成 CI 编译和包检查，未做 RootHide 真机运行验收；目标应用还需在 Bootstrap App List 启用注入。三个模式分别 clean，避免混用产物。

GoScrcpy 定制版已通过原生 Go 采集器集成此功能：右键 iOS 设备选择「网络监控」，自动检测并通过 MKS 安装缺失插件，三种 deb 均嵌入 EXE。它使用独立的按手机 SQLite 历史，删除提供撤销且不清空手机日志；不依赖 Python。原独立 Python 版数据库保持原样，勿同时运行两个采集器修改目标配置。

本机 Windows 无 Theos/Xcode，不声称本地完成 iOS 编译。实际包由 GitHub macOS runner 构建。Rootless 安装示例：`dpkg -i com.example.trafficmonitor_<version>_iphoneos-arm64.deb`；不需要自动重启 SpringBoard，只需冷启动监控应用。

## 查询手机出口 IP

0.4.1 增加 `tm-probe --query-ip`。请求在手机上使用原生 NSURLSession GET `http://ip-api.com/json`，每次创建无缓存会话，沿用当时的 iOS 系统代理 / PAC 与 VPN 路由；代理失败直接报错，不切换直连。输出包含 IP、地区、运营商和组织的 JSON。不需要 curl 或 Procursus 源，也不需要启动监控应用或重新注销。

`tm-probe --self-test-ip` 使用本机临时 HTTP 代理与 `.invalid` 域名验证代理请求，并测试 HTTP 错误和无效 JSON；不会请求外网。GoScrcpy 的代理面板和网络监控窗口共用此查询，缺少查询能力时使用 EXE 内置插件包升级。

## 工程

`Tweak.xm`、`Sources/` 为采集代码；`probe/` 为独立诊断工具；`desktop/` 为 SQLite/USB 服务与 WebUI；`scripts/` 为静态/安装包检查；`.github/workflows/build.yml` 为 CI。fishhook 授权和修改说明见 `THIRD_PARTY_LICENSES/`。

URL 的 query 值全部脱敏，移除 user/password/fragment，不采集 header、cookie、请求或响应正文。URL path 仍可能包含业务标识。手机日志每类最多 2×1 MiB，电脑每类最多 100,000 条并按保留期清理。WebUI 无需访问令牌，保留 Host/Origin 校验、CSP、参数化 SQL 与纯文本 DOM。

尚未宣称覆盖 CFNetwork HTTPStream、Network.framework/QUIC、所有 libcurl/Unity/Unreal 后端、后台系统进程或直接 syscall。已测结果与实际问题修复记录见 [进展](docs/PROGRESS.md) 及 [交付验收](docs/RELEASE_VERIFICATION.md)。
