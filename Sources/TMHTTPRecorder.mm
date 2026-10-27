#import "TMHTTP.h"
#import "TMSocket.h"
#import <os/lock.h>
#import <os/log.h>
#include <atomic>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
NSString *TMCurrentFileName=@"http-events.jsonl";

static constexpr unsigned kCapacity = 256;
static constexpr off_t kMaxFileBytes = 1024 * 1024;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary *gEvents[kCapacity];
static unsigned gHead, gCount;
static std::atomic<uint64_t> gAttempts{0}, gQueued{0}, gFull{0}, gBusy{0};
static std::atomic<uint64_t> gWritten{0}, gWriteErrors{0}, gPeak{0};
static dispatch_queue_t gWriter;
static dispatch_source_t gTimer;
static NSString *gDirectory;
static os_log_t gLog;
// Only the serial writer owns the following file state.
static int gFD = -1;
static off_t gFileBytes;
static int gSocketFD=-1;
static off_t gSocketBytes;
static std::atomic<bool> gEnabled{true};
static long long gGeneration=-1;
BOOL TMMonitoringEnabled(void){return gEnabled.load(std::memory_order_relaxed);}

NSString *TMHTTPRedactedURL(NSURL *url) {
    if (!url) return @"<unknown-url>";
    NSString *raw = url.absoluteString;
    if (!raw || raw.length > 4096) return @"<oversize-or-invalid-url>";
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!parts || ![@[@"http", @"https"] containsObject:parts.scheme.lowercaseString]) {
        return @"<non-http-url>";
    }
    parts.user = nil;
    parts.password = nil;
    parts.fragment = nil;
    if (parts.percentEncodedQuery != nil) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSURLQueryItem *item in parts.queryItems) {
            [items addObject:[NSURLQueryItem queryItemWithName:item.name value:@"<redacted>"]];
        }
        // If malformed query parsing fails, discard the entire query.
        parts.queryItems = items.count ? items : nil;
    }
    NSString *result = parts.string;
    return result && result.length <= 4096 ? result : @"<oversize-or-invalid-url>";
}

static BOOL TMOpenFile(void) {
    if (gFD >= 0) return YES;
    const char *directory = gDirectory.fileSystemRepresentation;
    struct stat directoryStat;
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) return NO;
    if (lstat(directory, &directoryStat) != 0 || !S_ISDIR(directoryStat.st_mode) ||
        directoryStat.st_uid != getuid()) return NO;
    if (chmod(directory, 0700) != 0) return NO;
    NSString *path = [gDirectory stringByAppendingPathComponent:TMCurrentFileName];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return NO;
    struct stat fileStat;
    if (fstat(fd, &fileStat) != 0 || !S_ISREG(fileStat.st_mode) ||
        fileStat.st_uid != getuid() || fchmod(fd, 0600) != 0) {
        close(fd);
        return NO;
    }
    gFD = fd;
    gFileBytes = fileStat.st_size;
    return YES;
}

static void TMWriteEvent(NSDictionary *event) {
    BOOL isSocket=[event[@"kind"] isEqual:@"socket_sample"];
    // Reuse the same bounded writer with distinct HTTP and Socket file state.
    if(isSocket){std::swap(gFD,gSocketFD);std::swap(gFileBytes,gSocketBytes);}
    NSString *fileName=isSocket?@"socket-events.jsonl":@"http-events.jsonl";
    // TMOpenFile takes its filename from this writer-only setting.
    extern NSString *TMCurrentFileName;
    TMCurrentFileName=fileName;
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:&error];
    if (!json || json.length > 16 * 1024 || !TMOpenFile()) {
        gWriteErrors.fetch_add(1, std::memory_order_relaxed);
        if(isSocket){std::swap(gFD,gSocketFD);std::swap(gFileBytes,gSocketBytes);}return;
    }
    if (gFileBytes + (off_t)json.length + 1 > kMaxFileBytes) {
        close(gFD);
        gFD = -1;
        NSString *current = [gDirectory stringByAppendingPathComponent:fileName];
        NSString *previous = [current stringByAppendingString:@".1"];
        // Rename atomically replaces only the single bounded previous segment.
        if (rename(current.fileSystemRepresentation, previous.fileSystemRepresentation) != 0 || !TMOpenFile()) {
            gWriteErrors.fetch_add(1, std::memory_order_relaxed);
            if(isSocket){std::swap(gFD,gSocketFD);std::swap(gFileBytes,gSocketBytes);}return;
        }
    }
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *bytes = (const uint8_t *)line.bytes;
    size_t remaining = line.length;
    while (remaining) {
        ssize_t written = write(gFD, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            gWriteErrors.fetch_add(1, std::memory_order_relaxed);
            close(gFD);
            gFD = -1;
            if(isSocket){std::swap(gFD,gSocketFD);std::swap(gFileBytes,gSocketBytes);}return;
        }
        remaining -= (size_t)written;
        bytes += written;
        gFileBytes += written;
    }
    gWritten.fetch_add(1, std::memory_order_relaxed);
    if(isSocket){std::swap(gFD,gSocketFD);std::swap(gFileBytes,gSocketBytes);}
}

static BOOL TMDrainBatch(void) {
    NSMutableArray *batch = [NSMutableArray arrayWithCapacity:64];
    os_unfair_lock_lock(&gLock); // Consumer only; producers always use trylock.
    for (unsigned n = 0; gCount && n < 64; ++n) {
        [batch addObject:gEvents[gHead]];
        gEvents[gHead] = nil;
        gHead = (gHead + 1) % kCapacity;
        --gCount;
    }
    BOOL remaining = gCount > 0;
    os_unfair_lock_unlock(&gLock);
    for (NSDictionary *event in batch) {
        @autoreleasepool { TMWriteEvent(event); }
    }
    return remaining;
}

void TMHTTPEnqueue(NSDictionary *event) {
    if (!gWriter || !event) return;
    gAttempts.fetch_add(1, std::memory_order_relaxed);
    if (!os_unfair_lock_trylock(&gLock)) {
        gBusy.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    if (gCount == kCapacity) {
        os_unfair_lock_unlock(&gLock);
        gFull.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    gEvents[(gHead + gCount) % kCapacity] = event;
    ++gCount;
    if (gCount > gPeak.load(std::memory_order_relaxed)) gPeak.store(gCount, std::memory_order_relaxed);
    os_unfair_lock_unlock(&gLock);
    gQueued.fetch_add(1, std::memory_order_relaxed);
}

NSDictionary *TMHTTPHealth(void) {
    return @{@"capacity": @(kCapacity), @"attempted": @(gAttempts.load()),
             @"queued": @(gQueued.load()), @"dropped_full": @(gFull.load()),
             @"dropped_busy": @(gBusy.load()), @"written": @(gWritten.load()),
             @"write_errors": @(gWriteErrors.load()), @"peak_depth": @(gPeak.load())};
}

void TMHTTPRecorderStart(NSString *directory) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gDirectory = [directory copy];
        NSDictionary *initial=[NSDictionary dictionaryWithContentsOfFile:[gDirectory stringByAppendingPathComponent:@"config.plist"]];
        if(initial){gEnabled.store([initial[@"enabled"] boolValue]);gGeneration=[initial[@"generation"] longLongValue];}
        gLog = os_log_create("com.example.trafficmonitor", "http");
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        gWriter = dispatch_queue_create("com.example.trafficmonitor.http-writer", attr);
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gWriter);
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                                 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gTimer, ^{
            @autoreleasepool {
                TMDrainBatch();
                static unsigned ticks;
                if(ticks%4==0){
                    NSDictionary *config=[NSDictionary dictionaryWithContentsOfFile:[gDirectory stringByAppendingPathComponent:@"config.plist"]];
                    if(config){
                        gEnabled.store([config[@"enabled"] boolValue]);
                        long long generation=[config[@"generation"] longLongValue];
                        if(gGeneration>=0 && generation!=gGeneration){
                            if(gFD>=0)close(gFD);if(gSocketFD>=0)close(gSocketFD);gFD=gSocketFD=-1;gFileBytes=gSocketBytes=0;
                            for(NSString *name in @[@"http-events.jsonl",@"http-events.jsonl.1",@"socket-events.jsonl",@"socket-events.jsonl.1"])
                                unlink([gDirectory stringByAppendingPathComponent:name].fileSystemRepresentation);
                        }
                        gGeneration=generation;
                    }
                    TMSocketDrain();
                    TMHTTPEnqueue(@{@"kind":@"collector_health",@"bundle_id":NSBundle.mainBundle.bundleIdentifier?:@"<probe>",
                        @"time":@(NSDate.date.timeIntervalSince1970),@"enabled":@(gEnabled.load()),@"http":TMHTTPHealth(),@"socket":TMSocketHealth()});
                }
                if (++ticks % 40 == 0 && (gFull.load() || gBusy.load() || gWriteErrors.load())) {
                    os_log_error(gLog, "event=http_health dropped_full=%llu dropped_busy=%llu write_errors=%llu",
                                 (unsigned long long)gFull.load(), (unsigned long long)gBusy.load(),
                                 (unsigned long long)gWriteErrors.load());
                }
            }
        });
        dispatch_resume(gTimer);
    });
}

void TMHTTPFlushForTesting(void) {
    if (!gWriter) return;
    dispatch_sync(gWriter, ^{
        @autoreleasepool { while (TMDrainBatch()) {} }
    });
}
