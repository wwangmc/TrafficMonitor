# 第二阶段最小版本验证：0.2.0

日期：2026-10-27。目标：`com.korea.mrtgd2.ios`。验证范围仅为 dataTask completion 路径，不包含 delegate 数据采集、upload/download 或 Socket。

## 构建与成品

- [成功 Actions run](https://github.com/wwangmc/TrafficMonitor/actions/runs/40446557111)，源码提交 `5a37696e267c9a9dd02221ed2e7058ef6faf83ce`。
- macOS native probe、Rootless Tweak、arm64 诊断工具、包路径/架构/Filter 检查均成功。
- [Rootless Artifact](https://github.com/wwangmc/TrafficMonitor/actions/runs/40446557111/artifacts/12708921251)，包含 deb、包检查报告和 native probe 日志；有效期 14 天。
- deb：`com.example.trafficmonitor_0.2.0_iphoneos-arm64.deb`，35504 字节。
- deb SHA-256：`ca12657a97b8e93a28a8d51fb0546c8d93bed3328a18e9b494c508318d8243d5`。
- Artifact ZIP SHA-256：`1ea10724d9fddc4a617f7e4a7453dd2e36765043959ec0baafecf9caab127057`，下载后核对一致。
- dylib SHA-256：`9a7a49ffd4a8643161f771b39660174c3c54056b3530f823017a2fdf224442d5`；设备安装后匹配。
- tm-probe SHA-256：`372a1712a58bcb45d86cfde72e3d6d5cc263bb118180f2ca23bdc28303745924`；设备安装后匹配。
- Tweak 包含 arm64/arm64e；CLI 为 arm64。包内是 Rootless dylib、精确 Filter 和 `var/jb/usr/libexec/trafficmonitor/tm-probe`。

## 合成 HTTP 验证

同一套源码分别在 macOS 和 iPhone X / iOS 16.1.1 执行 `--self-test`，均 `PASS`。设备端 exit marker 为 `TM_PROBE_EXIT=0`。

| 检查 | macOS | iOS 真机 |
| --- | --- | --- |
| HTTP 完成事件 / 唯一请求 ID | 40 / 40 | 40 / 40 |
| GET、POST 与 32 个并发任务 | 通过 | 通过 |
| POST 请求/响应 body 各 10 字节 | 通过 | 通过 |
| 404 保留 HTTP 状态且无传输错误 | 通过 | 通过 |
| 重定向原 URL / 最终 URL | 通过 | 通过 |
| 断连 error -1005、取消 error -999 | 通过 | 通过 |
| 无 response 的取消状态码为 NULL | 通过 | 通过 |
| 首次 resume 到完成耗时、去重 | 通过 | 通过 |
| 配置的 callback queue / shared baseline | 通过 | 通过 |
| delegate-only 原路径继续工作且未误计入 | 通过 | 通过 |
| URL 脱敏、无 header/body 内容泄露 | 通过 | 通过 |
| 目录 0700 / 文件 0600 | 通过 | 通过 |

标准 shared/default/ephemeral session 实测均为 `__NSURLSessionLocal`；task 为 `__NSCFLocalDataTask`。没有把这些私有类名写死为跨系统保证。

队列压力阶段故意连续提交 1024 条 `queue_diagnostic`：峰值 256，满队列丢弃 768，随后 40 条 HTTP 全部写入。最终 attempted=1064、queued/written=296、dropped_busy=0、write_errors=0。这里的 768 是合成压力事件，不是 40 个 HTTP 测试中的丢失请求。

完整合成结果：[iOS](validation/stage2-probe-ios.json)、[macOS](validation/stage2-probe-macos.json)。不包含用户真实请求 URL、手机标识或配对材料。

首轮 run `40446315460` 失败于测试对 sharedSession NSOperationQueue 身份的假设；其他 HTTP 检查已通过。修正为与安装 hook 前的真实执行环境对比后，以上成功 run 完整通过；未通过降低事件数或忽略业务回调失败来放行。

## 设备升级与游戏进程

通过现有 MKS USB 调试通道传输精确 deb，设备端 SHA-256 与本地一致后执行 dpkg。首次安装因 roothelp 缺少 PATH 被 dpkg 拒绝，仍保持 0.1.0；仅在安装命令的进程环境补齐 Rootless PATH 后重试，`TM_INSTALL_EXIT=0`，dpkg 状态为 0.2.0 installed。没有改设备全局环境或其他包。

启动游戏前未发现其进程，无需结束正在运行的游戏。启动后捕获：

```text
mrtgd{TrafficMonitor.dylib}[32407]: event=http_hooks_installed session_class=__NSURLSessionLocal task_class=__NSCFLocalDataTask
mrtgd{TrafficMonitor.dylib}[32407]: stage=2 event=loaded version=0.2.0 mode=rootless bundle=com.korea.mrtgd2.ios pid=32407 http_enabled=1 sink=app_tmp/TrafficMonitor/http-events.jsonl
```

一次本地文件快照包含 78 条事件、78 个唯一 request ID，全部为 HTTPS，全部属于 PID 32407 与指定 Bundle；GET 13、POST 65，HTTP 200 为 59、204 为 1，18 条无 HTTP response 且保留 NULL 状态及 error code。78 条都有 resume 耗时；78 条请求 body 快照已知，60 条有 response NSData 长度。不能把无 response 的错误计作 HTTP 0 或下载 0。

本地解析验证：所有 URL query 值均被替换，无 userinfo/fragment。真实事件和截图只保留在本地忽略目录 `packages/`，不上传 GitHub；快照数量不是全生命周期请求总数或覆盖率。

设备目录/文件权限实际为 0700/0600，写入者 mobile。截图显示游戏正常进入主界面，检查时同一 PID 已运行 02:39；这是短时功能观察，不是长期稳定性保证。包中存在 UnityFramework、AFNetworking 等模块，但没有采集调用栈，不能断言每条事件来自哪个模块。

## 尚未验证

Rootful 编译/设备、arm64e 真机、长时间压力、轮转极限与故障注入、流式上传、delegate/upload/download、所有游戏路径、Network.framework/CFNetwork/libcurl、SQLite、WebUI、真实链路流量。同步 flush 仅在诊断工具中使用；游戏采集没有磁盘同步写入或网络线程上的 SQL。
