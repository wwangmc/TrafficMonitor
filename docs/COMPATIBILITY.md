# 覆盖与限制

0.2.0 已实现并验证 NSURLSession dataTask completion 路径，覆盖率仍未知。`com.korea.mrtgd2.ios` 包内发现 UnityFramework 与多个 SDK，实际捕获了该进程的 completion HTTPS 事件；没有调用栈证据，不能归因或推断全部网络栈。

| 路径 | 计划 | 必须验证的边界 |
| --- | --- | --- |
| NSURLSession dataTask + completion | 已实现 URL/Request 入口；macOS/iOS 各 40 请求通过，游戏实际事件有正例 | 去重、回调队列、redirect/error/cancel 已测；缓存、stream 与自定义子类等未完整覆盖 |
| delegate/upload/download/background | 第一条路径通过后单独扩展 | 不预读 stream；系统后台进程、下载文件与 metrics 时序另测 |
| CFNetwork/CFHTTPStream | 后续独立适配 | NSURLSession 验证不代表全部 CFNetwork 覆盖 |
| BSD TCP/UDP | connect/send/recv/sendto/recvfrom/sendmsg/recvmsg | 处理 fd 生命周期；read/write/readv/writev 等实际路径也可能需要覆盖；直接 syscall/其他进程可能遗漏 |
| Network.framework / QUIC | 用样例验证进程及调用路径后再适配 | 不假设会经过上述 BSD hooks；UDP 或多路复用字节不能直接还原 HTTP 请求 |
| libcurl | 检查动态/静态链接、transport，必要时独立适配 | 不假设进入 NSURLSession；自定义 socket、SSL backend、静态符号另测 |
| Unity | 目标包中发现 UnityFramework，捕获同进程部分 NSURLSession HTTPS 事件 | 未确认事件来自 UnityWebRequest 还是 SDK；不承诺完整 Unity 覆盖，自有 UDP 另测 |
| Unreal | 检查实际构建的 HTTP、Socket 与插件后端 | 不假设所有 iOS 构建都使用 NSURLSession 或同一种 curl 配置 |
| WKWebView/扩展/系统进程 | 识别真实执行进程再评估 | 宿主注入不代表其他进程覆盖；不注入全系统以扩大数字 |

## 初步资料与推论

2026-10-27 核对的官方入口：

- [Theos Rootless](https://theos.dev/docs/rootless)：scheme、前缀与包架构依据。
- [ElleKit](https://github.com/tealbathingsuit/ellekit)：提供 Substrate/libhooker API 实现，不证明某个游戏可注入。
- [Apple NSURLSession](https://developer.apple.com/documentation/foundation/urlsession) 与 [Network.framework](https://developer.apple.com/documentation/network)：后续按 API/任务模型拆分验证，尚未完成底层路径研究。
- [libcurl CURLOPT_OPENSOCKETFUNCTION](https://curl.se/libcurl/c/CURLOPT_OPENSOCKETFUNCTION.html)：允许自定义 socket 创建及提供已连接 socket。因此不能只凭 connect 推断 curl 连接完整性；这是设计推论，无本项目实测。
- [Unity 请求手册](https://docs.unity3d.com/Manual/web-request.html)：不据此推断 iOS 底层 transport。
- [Unreal FGenericPlatformHttp](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/HTTP/FGenericPlatformHttp)：存在平台相关 HTTP 实现；具体 iOS 游戏后端仍需代码/二进制与真机验证。

具体第二阶段证据见 STAGE2_VERIFICATION.md。后续继续研究 Network.framework、CFNetwork 和引擎具体实现。当前没有协议解密、反作弊绕过、内核抓包或真实接口流量统计。
