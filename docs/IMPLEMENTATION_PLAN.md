> 界面后续精简：仅保留单应用选择和请求URL/大小列表；自动更新最近200条。大小为请求与响应应用数据合计，未知保留未知。下文多面板描述对应历史版本。

> 后续调整：按用户要求已移除本地 WebUI 访问令牌与登录，保留127.0.0.1和Host/Origin限制。下文认证设计仅为历史方案。

> 当前交付：0.3.1 已完成 HTTP、Socket、电脑 SQLite、USB WebUI 和 GitHub Actions。以下保留最初实施设计；最终桥接采用已有 MKS/roothelp，SQLite 与 Web 服务运行在电脑。兼容性与验收以 COMPATIBILITY.md / RELEASE_VERIFICATION.md 为准。

# TrafficMonitor 实施计划

日期：2026-10-27（Asia/Shanghai）。本轮范围：初始化与第一阶段。

## 分阶段交付与验收

| 阶段 | 实际交付 | 验收条件 | 当前状态 |
| --- | --- | --- | --- |
| 1 最小 Tweak | Makefile、control、Bundle Filter、Objective-C++/Logos 加载入口、目标配置脚本、构建骨架 | 两种 scheme 可独立构建；Rootless deb 可安装；指定 App 冷启动出现一次加载日志；其他 App 不注入 | 源码、静态检查、Rootless CI/包检查及三次真机冷启动注入通过；Rootful 编译待执行 |
| 2 NSURLSession | 先 dataTask completion-handler 路径，再 delegate、upload、download；请求事件模型与最小验证客户端 | 自建服务验证 GET/POST、错误、取消、重定向、并发；逐项标明支持范围 | completion 最小版通过 CI、macOS/iOS probe 和游戏实际 HTTPS 验证；delegate/upload/download 待扩展 |
| 3 Socket | connect/send/recv/sendto/recvfrom/sendmsg/recvmsg；连接与字节模型 | TCP/UDP、IPv4/IPv6、部分收发、失败、非阻塞、fd 复用等有实测记录 | 待实现 |
| 4 SQLite | 独立 collector、受限 IPC、有界采集队列、异步批量写入、保留与删除策略 | 真机验证 App 沙盒能访问 collector；积压有界；网络线程不等待磁盘/IPC；重启恢复、清理和丢弃计数可验证 | 待实现 |
| 5 本地 WebUI | 受认证 API、应用选择、请求与连接、速度、域名/IP 汇总、历史与清理 | 仅 127.0.0.1 监听；认证/Origin/Host/CSRF 校验；新选择应用重启后生效；UI 可观察丢弃数与数据范围 | 待实现 |
| 6 CI 与集成 | 验证 Rootless Actions、deb 内容检查、安装说明、端到端验证记录 | 成功 CI run 和对应包；在支持的越狱设备验证完整链路 | 第一阶段 Rootless CI 与包检查已通过；完整监控链路待后续实现 |

每阶段都提交实际源码和本地/CI/设备检查结果到 `PROGRESS.md`，不可把生成 workflow、静态检查或部署 target 当成编译/兼容性验证。

## 构建边界

- 默认 `TYPE=1`：Rootless、iOS 15.0+、arm64/arm64e，优先 Dopamine + ElleKit。
- 独立 `TYPE=0`：Rootful、iOS 14.0+、默认 arm64。arm64e 必须在相应 iOS 14 注入环境另行构建验证。Dopamine 不属于 iOS 14 Rootful 方案。
- 不加入 RootHide 模式；资源安装前缀由 Theos scheme 决定，不在源码中硬编码 `/var/jb`。
- 当前唯一目标：`com.korea.mrtgd2.ios`。Filter 与编译时 Bundle 校验保持一致。不配置 SpringBoard 或全进程注入。

## 数据与采集架构（设计约束，尚未实现）

1. 注入端分别产生 HTTP 事件和 Socket 事件。HTTP 记录 request ID、进程会话、方法、脱敏后的完整 URL 结构、起止时间/单调时钟耗时、状态码/错误、字节口径及计数来源。重定向需要记录各跳或明确最终 URL；取消与失败不可伪造状态码。
2. HTTP body 实际可见大小与 NSURLSessionTaskMetrics 的计数分别标记；未知字节为 NULL，不能记作 0。禁止为了统计主动读取 HTTPBodyStream 或改变任务、缓存、delegate 和 completion 行为。系统后台会话和 WebKit 独立进程需单独测试。
3. Socket 仅按成功返回的字节数累计。`sendmsg/recvmsg` 的 iovec 总长度是上限，实际计数以返回值为准；UDP MSG_TRUNC/MSG_PEEK 等特殊 flag 需要单独定义和验证，不能盲加。保存 errno，防止采集递归；处理 close/dup/dup2/accept、未经过 connect 的 UDP、fd 复用和非阻塞连接完成；查 peer 的成本不能放在每次收发的热路径。
4. 热路径使用有界、尽力入队的固定尺寸事件缓冲；不执行 SQL、文件 I/O、同步 IPC、DNS 反查或逐次日志。溢出立即丢弃并计数；不能简单对每次收发无限 `dispatch_async`。消费者线程聚合后异步发送给 collector，超时/断连/背压不可卡住原网络调用。
5. collector 单写者管理 SQLite，WAL、批量事务、索引和定期保留期清理。规划独立表：`process_sessions`、`http_requests`、`socket_connections`、`socket_samples`、`collector_health`。所有事件带 bundle ID、PID、进程会话 ID 和单调时钟，避免 PID/fd 复用污染历史。
6. HTTP 请求次数/应用数据与 Socket 字节分表、分接口、分 UI 卡片。Socket 字节是被拦截的用户态 API 返回字节，不包含完整 IP/TCP/UDP 头、重传等链路成本，不能标成真实网卡流量；TLS 所处层次会改变计数。真正网络层流量需要另行引入并验证有权限的内核/接口观测。
7. 数据库由 collector 持有，不能假设沙盒 App 可直接写公共 SQLite 路径。受认证的 loopback IPC 是待验证候选；需要先验证游戏沙盒、端点发现、token 安全分发和排除监控自身 IPC，再确定实现。未验证前不承诺全 App 可达。

## 隐私、Web 与配置边界（后续验收要求）

- HTTP URL 保留 scheme/host/port/path 结构；默认脱敏全部 query 值、userinfo 和 fragment；路径中的秘密也可能泄露，应支持路径脱敏/白名单。不会默认存正文、Cookie 或 Authorization。脱敏在跨进程传输/写盘之前完成。
- collector/Web 只绑定 `127.0.0.1`，不绑定 `0.0.0.0` 或 `::`。本地地址不能代替认证：使用随机 token、受限文件权限、严格 Host/Origin、禁止宽松 CORS、写操作防 CSRF；UI 禁止渲染未转义 URL。
- 默认保留期与容量上限、按应用/时间删除、全部清理（包括 WAL/checkpoint）作为阶段 4/5 必做项；第一阶段无数据库、无请求日志、无监听端口。
- 已注入进程中的启停可以运行时控制；增加新的注入目标通常需要更新已安装 Filter 并重启目标 App。WebUI 不应宣称点击即可向任意已运行进程注入。阶段 1 使用构建前脚本配置。

## 兼容性研究计划

阶段 2/3 检查 Network.framework、CFNetwork、libcurl、Unity 和 Unreal 的官方文档及实际链接/调用路径；覆盖矩阵见 `COMPATIBILITY.md`。覆盖以特定调用路径和真机证据为单位，不按游戏引擎名称推算。自研网络栈、静态链接、内联 syscall、QUIC、反注入/反作弊和加密自有协议都必须保留未知项。
