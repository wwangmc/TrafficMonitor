# 0.4.3 大文件大小漏计修复

问题来源：用户报告 com.boge.lgmahjongios 在另一台手机显示下载约 300 MB，监控仅约 30 MB。当前手机是新安装，未保留该次下载证据，不能断言这两个缺陷解释了全部差额。

确认的代码缺陷：

- downloadTask completion 以前未提取临时文件大小，response_body_bytes 为 NULL；现在在应用回调移动/删除文件前只 stat 元数据，不读取文件正文。
- file/stream upload 的未知请求大小与 SQL 的 up+down 组合，曾使已知下载量也变成 NULL，被域名 sum 排除。现在保留已知方向，并以 ≥ 标记不完整大小；两方向全未知仍为未知。
- 缺失应用数据大小时可使用 task_count_bytes_sent/received 兜底；不同计数不相加，避免重复。桌面端可补录仍保留日志中的旧计数，已丢弃的日志无法恢复。

新增回归：真实 URLSession URL/Request completion 下载 180+120 MiB，delegate 下载 4 MiB，文件上传；每个请求只记录一次，应用可在原回调内删除临时文件。fixture 以 64 KiB 块发送，不把大文件读进内存。另有 SQLite 部分未知、历史计数去重补录、删除后不复活测试。

统计边界：HTTP 表显示已完成、已捕获请求的应用数据大小。下载中、未钩住的网络库、独立进程不保证出现；Socket 导入符号采集也不完整，不与 HTTP 相加。下载临时文件可能包含续传已有数据，文件大小不等于本次实际网络下载量；压缩/解压、缓存、重试也会造成差别。未知路径不能用 Content-Length/预计大小假装已下载。

Windows 本机没有 iOS SDK/Theos。Objective-C++ 编译、大文件 probe 和三个 deb 以 GitHub Actions 实际结果为准；应用内 300 MB 资源包需真机再次触发才能确认覆盖。
