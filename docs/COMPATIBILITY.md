# 兼容性与实测边界

0.4.0 沿用 0.3.1 的 NSURLSession 与 BSD Socket 导入符号采集，增加独立 Rootful/Rootless/RootHide 编译和环境标识。覆盖率未知，不提供全游戏、全 API 或真实网卡流量承诺。

| 路径 | 当前实现 / 实测 | 限制 |
| --- | --- | --- |
| NSURLSession dataTask completion URL/Request | macOS/iOS 合成测试、目标游戏实际 HTTPS | redirect/error/cancel/并发/共享与普通 session 已测；自定义子类、缓存等未穷尽 |
| delegate dataTask | 原 delegate 身份与回调保持，合成测试有正例 | 应用在装钩前创建的 session、动态替换 delegate 方法、后台系统进程不保证 |
| upload data/file completion | data 有合成正例；不读取 file | file/stream body 未知；文件 upload 尚无独立真机用例 |
| download completion | 合成正例，不读取下载文件 | body 字节未知，task 计数另列；resume-data/background 未覆盖 |
| TCP/UDP IPv4/IPv6 | connect/send/recv/sendto/recvfrom/sendmsg/recvmsg，加 read/write/readv/writev/close/dup/dup2/accept；合成 TCP/UDP/IPv6 正例，游戏实际 TCP 正例 | 指动态导入符号，直接 syscall、私有变体、无法修改的导入段、未观察到的 API 会漏记；arm64e 仅编译未真机测 |
| CFNetwork / CFHTTPStream | 暂无专用 HTTP hook | 底层若经过已挂钩导入可能产生 Socket 样本，不还原其 HTTP |
| Network.framework / QUIC | 暂无专用 nw_connection 适配 | 不能假设全部经过公共 BSD 导入；本机游戏 HTTP 大文件与 Socket 样本字节明显不等，不能把 Socket 当完整总量 |
| libcurl | 无 curl 专用 HTTP hook；普通动态 BSD 导入可能可观测 | 静态实现、自定义 transport/socket/TLS backend 未做 curl 实例验证，不宣称完整支持 |
| Unity | 目标游戏存在 UnityFramework，0.3.1 可启动并出现实际 HTTP 与 TCP 样本 | 无调用栈归因，不把 SDK 请求归因为 UnityWebRequest，不推断全部游戏流量 |
| Unreal | 只完成官方接口研究 | 具体构建后端未有真机样本，不承诺支持全部 Unreal 游戏 |
| WKWebView/扩展/nsurlsessiond | 不注入其他进程 | 宿主 Bundle 过滤不覆盖独立执行进程 |

## 真机发现与实现选择

0.3.0 以 MSHookFunction 修改短 libc 函数，目标 Unity 游戏约 3 秒后 EXC_GUARD 退出；崩溃包含 ElleKit 异常端口循环和 Unity Breakpad ForwardException。不能仅凭合成 probe 通过交付此版本。

0.3.1 改用带许可证的 fishhook 导入符号重绑定，避免指令跳板/异常端口。对应用和后续 image 的可处理导入段重绑定，保留原函数和 errno，自身 worker 导入排除。目标游戏重新启动进入主界面并产出 TCP 样本。符号重绑定也有覆盖边界，尤其 arm64e authenticated/chained fixup 并未在真机确认。

## 官方资料与推论（2026-10-27 复核）

- [Apple Network.framework](https://developer.apple.com/documentation/network)：独立网络 API。没有 nw_connection 专用探针，不能从其存在推断 BSD 覆盖。
- [libcurl CURLOPT_OPENSOCKETFUNCTION](https://curl.se/libcurl/c/CURLOPT_OPENSOCKETFUNCTION.html)：明确允许自定义创建 socket、返回已经连接的 socket；据此推论不能只监控 connect 来证明全部 curl 流量覆盖。
- [Unity Web 请求手册](https://docs.unity3d.com/Manual/web-request.html)：介绍 UnityWebRequest 的传输能力；不能据此确定某游戏的具体 iOS transport。目标样本可能来自内嵌 SDK。
- [Unreal FGenericPlatformHttp](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/HTTP/FGenericPlatformHttp)：平台相关请求构造与管理；具体游戏需要对实际构建验证。
- [fishhook](https://github.com/facebook/fishhook)：动态导入重绑定机制，和内核抓包有不同覆盖范围。
- [Theos Rootless](https://theos.dev/docs/rootless)、[ElleKit](https://github.com/tealbathingsuit/ellekit)：安装前缀与注入环境依据，不代表任意游戏的兼容性保证。

没有 TLS 解密、证书绕过、反作弊绕过、系统全局抓包或真实接口流量统计。0.4.0 的 Rootful iOS 14、Rootless、RootHide 三种包已通过 GitHub Actions 编译与包检查，Rootful/RootHide 尚无真机运行验收；Dopamine 目标为 iOS 15+ Rootless。RootHide 还需在 Bootstrap 中开启目标应用注入，不能把编译成功等同于全场景可运行。
