# 架构与数据口径

## 路径

精确 Bundle Filter → 进程内 Tweak → HTTP 元数据队列 / Socket C 环形队列 → utility 串行写入两个 JSONL 流 → USB 增量读取 → 电脑 SQLite WAL → 127.0.0.1 本地 API → 本地 WebUI。

选择 USB 桥接是为了在目标 App 沙盒内只写自己的临时目录，不要求任意应用访问全局 SQLite 或跨应用监听端口。当前桥接依赖这台设备已有的 MKS/roothelp；未实现独立安装的 iOS collector daemon 或手机端网页服务。用户直接操作的是电脑浏览器观测台。

## 网络热路径

NSURLSession 任务附加状态、首次 resume 时刻、完成事件。completion 包装保留原始回调与队列，delegate 使用原类方法实现观察，不替换 delegate 身份。仅读取已有 NSData.length / task 计数，不预读 stream，不读取应用下载文件。HTTP 元数据封装仍有 Objective-C 分配开销；无 SQLite、文件 I/O、同步 IPC 或等待队列空位。

Socket 使用动态导入符号重绑定，避免在短 libc 函数上创建指令跳板/异常端口。固定 4096 项 fd 表和 2048 项事件环，trylock，TLS 避免重入；保存 errno 并调用原 API，只计成功返回字节，忽略 MSG_PEEK，截断 UDP 按实际复制长度计数。首次元数据探测会调用 getsockopt/getpeername，无 DNS 查询。hash 冲突、锁竞争及队列满会丢弃并计数。

后台每 250ms 从元数据队列取最多 64 条；每秒汇总 Socket C 环增量和健康数据。写入两个独立 JSONL，每流 1MiB + 一个旧文件，目录0700、文件0600，拒绝符号链接和非自身所有者。写入失败计数。暂停/清理配置在后台读取，不在网络线程读取配置。

电脑 USB 读写与 SQLite 脱离目标进程。增量游标以 inode/offset 存储，先读轮转文件再读当前文件，只提交完整行；HTTP request_id / Socket event_id 唯一去重。读取重试、重复输入不会重复累加。采集线程后台写事务，查询短锁，USB 操作不持数据库锁。断线可查看历史，不保证填补超过手机轮转容量的缺口。

## SQLite

| 表 | 内容 | 统计方式 |
| --- | --- | --- |
| http | method/脱敏URL/status/耗时/body/完整元数据 | 请求数、域名分组，字节不并入 Socket |
| samples | Socket 每秒增量、event_id、connection_id | 时间窗口字节、速率、曲线 |
| connections | fd generation + remote endpoint 会话 | 会话累计字节、协议/IP/端口/状态 |
| health | 每应用最新队列/丢弃/错误 | 判断样本是否可能不完整 |
| settings/cursors | 应用选择、保留期、读取游标 | 断线续读及配置持久化 |

默认 WAL/synchronous=NORMAL；每分钟执行保留期与行数清理；清理操作同时截断 WAL 并 VACUUM。SQLite 保存位置在电脑，不在 iPhone 网络线程写数据库。时钟通过 USB 获取设备 Unix 时间后校准，曲线来自 worker 时间戳及批次而非每个包的精确时刻。

## HTTP 与 Socket

HTTP body 是应用提供/接收的已解码数据，任务自报计数另列，未知用 null。URL 最长4096字符，保留scheme/host/path/query名称并替换所有query值，清除userinfo/fragment。HTTP duration 是首次 resume 到完成，包括重定向、等待和应用调度，不代表纯网络 RTT。

Socket 字节是调用成功处理的用户缓冲区长度，TLS 路径可能表现为 TLS 记录字节；不含 TCP/IP/链路报头、TCP重传、内核及其他进程流量。HTTP 与 Socket可能描述同一业务，禁止求和。并非抓包，不解密 TLS，不改证书信任，不提供真实网卡计费总量。

当前 fd 表固定容量，有别名/复用生命周期边界；dup/dup2 区分新描述符，但 fcntl(F_DUPFD)、跨进程 fd 传递、close取消窗口、直接syscall、绕过动态符号及系统后台进程未完整覆盖。recvmsg 未提供远端地址的未连接 UDP 可能无法归属；缺失端点不猜 IP。

## 安全边界

按用户要求移除访问令牌和登录；本地接口保留精确 Host/Origin、无 CORS、CSP、纯文本 DOM、参数化 SQLite，不提供网页任意 Shell API。USB 管理器只执行固定功能与经白名单验证的 Bundle/容器路径，选择上限8。共享电脑账户及既有 MKS/roothelp 通道属于受信任边界。不会安装 TLS 证书或关闭系统安全策略。
