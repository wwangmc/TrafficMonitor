# 第二阶段：NSURLSession dataTask completion

开发版本 0.2.0。源码已实现，CI/设备结果待执行后补充。0.1.0 的编译与注入结果不代表本版通过。

## 覆盖

仅监控指定 Bundle 中本地 session 的 `dataTaskWithURL:completionHandler:` 和 `dataTaskWithRequest:completionHandler:`。运行时读取共享 session 与样例 data task 的具体类，在这些类上替换方法并保留原实现链；样例 task 不 resume，不发请求。线程局部深度避免 URL/Request 相互调用重复计数，不改变 completion 队列、原参数、业务任务状态、请求、缓存或 delegate。

nil completion 原样调用。delegate-only、upload/download、background sessions、CFNetwork、Network.framework、libcurl、WebKit 和自有游戏栈未覆盖。自定义子类覆盖方法、后装插件重新替换方法都可能绕过本实现。probe 分别检查标准 shared/default/ephemeral sessions。

## 事件口径与隐私

- 独立请求 UUID、进程会话 UUID、PID/Bundle、task identifier、方法、脱敏 URL、最终 URL、状态码或 error domain/code。
- duration 为首次 resume 到 completion callback 的单调时钟耗时，包含暂停；没观察到 resume 则 NULL，不冒充服务器耗时。
- `request_body_bytes` 是创建时 HTTPBody 快照长度。无 body 为 0，有 stream 且无 NSData body 为 NULL，不读取 stream，不推断重试/重定向后的实际上行量。
- `response_body_bytes` 是 completion NSData 长度，nil 为 NULL、空 NSData 为 0；受缓存/解压缩影响，不是 wire bytes。
- `task_count_bytes_sent/received` 独立保存 NSURLSession 自报计数，不与 body 字节相加，也不声称为网卡流量。
- 只记录重定向的原始与最终 URL/状态，不虚构每跳请求。404 是 HTTP response；没有 response 的失败/取消状态码为 NULL。
- URL 移除 userinfo 和 fragment，替换所有 query 值；超长或不可解析 URL 只存占位符。不存 headers、正文、NSError 描述/userInfo。路径和 query 名仍可能敏感，路径脱敏配置待扩展。

设计参考 [Apple dataTask API](https://developer.apple.com/documentation/foundation/urlsession/datatask(with:completionhandler:)-52wk8) 和 [task 字节计数 API](https://developer.apple.com/documentation/foundation/urlsessiontask/countofbytessent)；覆盖仍以项目测试为准。

## 异步队列和清理

元数据进入容量 256 的 trylock 队列，锁忙/满立即丢弃并分别计数；无网络回调中的 SQL、磁盘写入、同步 IPC 或逐次 dispatch_async。不承诺 Foundation 和内存分配器是无锁实时系统。

utility 串行 worker 每 250ms 最多消费 64 条，写 App 自身 `tmp/TrafficMonitor/http-events.jsonl`。目录 0700、文件 0600，拒绝符号链接/不匹配所有者；当前和 `.1` 两段，每段约 1 MiB。health 暴露队列丢弃和写入错误，记录不完整时不能宣称完整统计。当前只有临时诊断文件，SQLite/collector 仍在后续阶段。

先结束目标 App 后，才可仅删除其这两个诊断文件；不要清空 App 容器。同步 flush 只给独立 probe 在网络回调全部完成后使用，业务 Tweak 不调用。

## 独立测试

同一 deb 包含 arm64 的 `usr/libexec/trafficmonitor/tm-probe`，Rootless 自动加安装前缀。工具直接调用同一套 monitor/recorder，不扩大 Tweak Filter。

```sh
/var/jb/usr/libexec/trafficmonitor/tm-probe --self-test
```

显式运行时才创建 127.0.0.1 随机端口的合成 HTTP fixture，结束关闭。检查 GET/POST、404、重定向、断连、取消、32 个并发、shared/default/ephemeral session、callback queue、delegate 原路径不变、去重、body 字节、URL/headers/body 不泄露、目录权限和有界队列。sharedSession 的回调执行环境与安装拦截前的真实 baseline 对比，显式配置的 session 则严格检查指定 NSOperationQueue。预期 40 条 HTTP 事件与 40 个唯一请求，JSON `result=PASS`、退出码 0。queue 压力事件单独标成 queue_diagnostic。

CI 先编译/运行 macOS native probe，再交叉编译 iOS 包与检查内容；macOS 通过不能替代真机或游戏网络路径验证。

## 当前结果

待执行本版 CI 和真机验证。
