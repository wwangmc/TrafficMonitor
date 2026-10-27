> 新增功能：域名汇总当前应用全部保存请求（已知大小合计，未知用≥标示）；确认后按应用删除，保留其他应用并过滤旧日志重读。新增集成测试覆盖跨200条域名汇总、应用隔离、删除确认、旧数据防回流、新记录继续采集和手机日志清理范围；真实用户历史不用于删除测试。

> 界面后续精简：仅保留单应用选择和请求URL/大小列表；自动更新最近200条。大小为请求与响应应用数据合计，未知保留未知。下文多面板描述对应历史版本。

> 后续调整：按用户要求已移除访问令牌、Bearer校验、登录框和浏览器令牌存储。GET/POST集成测试改为直接访问，并继续校验异常Host/Origin为403。以下401/token描述为原验收版本的历史记录。

# 0.3.1 交付验收（2026-10-27）

## 编译与安装

- 实际编译提交：20f21bfb95dc1603d3ca99bd8b3feb7b9c97d2bb。
- [GitHub Actions 成功运行 40451971297](https://github.com/wwangmc/TrafficMonitor/actions/runs/40451971297)，macos-15 / Xcode 16.4 / iOS16.5 SDK / Rootless arm64+arm64e。
- 静态配置、4项 SQLite/认证 API 集成测试、原生 HTTP/Socket probe、交叉编译、Mach-O/前缀/Filter 检查及两个产物上传均成功。
- deb SHA256：65421f9e17a3f1af696f5aadf9a878ec530196d55b6adbd5736758a680819580。
- 真机 dpkg 安装退出0；安装后的 dylib 与 probe 分别匹配包内 SHA256。详见 validation/0.3.1/package.json。

## 真机与探针

设备 iPhone X / iOS16.1.1 / Rootless / ElleKit1.2，目标 com.korea.mrtgd2.ios。探针输出 PASS：43 条唯一 HTTP 请求、42条 completion 回调加1条 delegate记录，TCP/UDP/IPv6 Socket wrapper 自测通过，脱敏/权限/取消/重定向/回调队列保持检查通过。

队列压力测试主动输入1024条事件，预期丢弃768，峰值256，无写入错误；这是合成压力值，不代表真实游戏丢弃数。probe 以 TM_SOCKET_TEST 直接调用包装器，不在 probe 内给 libc 打补丁；实际符号重绑定通过目标游戏验证。

0.3.0 曾在游戏启动时 EXC_GUARD 退出，涉及短函数补丁与 ElleKit/Unity Breakpad 异常端口链；0.3.1 改为导入符号重绑定。第一次冷启动12:53:43，运行至12:59:09由本次验证主动结束；第二次12:59:09正常启动并持续运行，主界面截图已实际观察。没有把首次失败隐藏或当作通过。

一个观察点已入库该新进程 HTTP223条（delegate116、completion107），Socket90个增量样本，上行6926B、下行92995B；仅为当次观察值，不是覆盖率。实际 TCP游戏连接及HTTPS连接均有正例，UDP目前仅合成测试有正例。原始游戏日志、数据库、设备识别信息和截图不上传仓库，只保留去标识汇总。

## 可视化与交互

在真实桌面 Chrome 和窄幅内置浏览器中检查布局，修复窄幅导航换行、应用选择入口和筛选宽度。实际验证应用搜索与保存（目标配置及Filter在手机读取确认）、暂停/恢复（运行中enabled配置变化）、HTTP搜索/详情及脱敏URL、Socket会话、历史1小时窗口、JSON导出落盘并解析。SQLite保留/清理在临时数据库集成测试中执行，没有为测试清空用户采集历史。

导出窗口3600秒、最近200条请求上限已检查。浏览器下载事件等待器曾超时，但文件已经实际落盘，后续解析确认成功；不是服务端导出失败。

本地监听127.0.0.1:27681，接口未认证401、异常Host/Origin403、CSP/静态页面不泄露token、SQL参数绑定及重复事件去重均通过集成测试。桌面实时传输依赖既有MKS/roothelp，不是独立手机端守护进程。

## 验收边界

不宣称CFNetwork HTTPStream、Network.framework/QUIC、所有curl或Unity/Unreal后端完整覆盖；不把Socket字节和HTTP body相加。实际存在HTTP大文件与Socket采集字节差异，说明存在未观测路径。Rootful iOS14与arm64e运行未真机验证；当前只确认arm64设备。详见COMPATIBILITY.md。

验收合成记录：validation/0.3.1/probe-host.json、probe-device.json、package.json、game-observation.json。源码与说明后续提交不改变以上已安装Tweak的功能代码。
