#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../Sources/TMHTTP.h"
#include "TMFixture.h"
#include <atomic>
#include <cstdio>
#include <sys/stat.h>
#include <unistd.h>

static void PrintJSON(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

@interface TMProbeDelegate : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) dispatch_semaphore_t finished;
@property(nonatomic, strong) NSMutableData *received;
@property(nonatomic, strong) NSError *error;
@property(nonatomic) unsigned calls;
@end
@implementation TMProbeDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    [self.received appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    self.error = error;
    ++self.calls;
    dispatch_semaphore_signal(self.finished);
}
@end

static NSURLSessionDataTask *RunCase(NSURLSession *session, dispatch_group_t group,
                                   NSMutableArray *results, NSString *label, NSURLRequest *request,
                                   BOOL urlAPI, NSInteger status, NSData *expected, NSInteger failure) {
    dispatch_group_enter(group);
    void (^completion)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger actual = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        BOOL ok = failure ? (error != nil && (failure != 2 || error.code == NSURLErrorCancelled)) :
                            (!error && actual == status && [data isEqualToData:expected]);
        BOOL callbackQueue = NSOperationQueue.currentQueue == session.delegateQueue;
        // All probe sessions use a serial delegate queue; protect cross-session callbacks too.
        @synchronized (results) {
            [results addObject:@{@"case": label, @"ok": @(ok && callbackQueue),
                                 @"status": @(actual), @"error": error ? @(error.code) : @0,
                                 @"callback_queue_preserved": @(callbackQueue)}];
        }
        dispatch_group_leave(group);
    };
    NSURLSessionDataTask *task = urlAPI ? [session dataTaskWithURL:request.URL completionHandler:completion] :
                                        [session dataTaskWithRequest:request completionHandler:completion];
    [task resume];
    return task;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc != 2 || strcmp(argv[1], "--self-test") != 0) {
            fprintf(stderr, "Usage: tm-probe --self-test\nRuns synthetic HTTP requests against 127.0.0.1 only.\n");
            return 2;
        }
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
                               [@"TrafficMonitorProbe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        TMHTTPRecorderStart(directory);
        // Exercise the real bounded producer/consumer path without inventing HTTP requests.
        for (unsigned i = 0; i < 1024; ++i) TMHTTPEnqueue(@{@"kind": @"queue_diagnostic", @"index": @(i)});
        TMHTTPFlushForTesting();
        NSDictionary *health = TMHTTPHealth();
        uint64_t attempted = [health[@"attempted"] unsignedLongLongValue];
        uint64_t accounted = [health[@"queued"] unsignedLongLongValue] +
                             [health[@"dropped_full"] unsignedLongLongValue] + [health[@"dropped_busy"] unsignedLongLongValue];
        BOOL queueOK = attempted == 1024 && attempted == accounted &&
                       [health[@"peak_depth"] unsignedIntValue] <= 256 &&
                       [health[@"written"] unsignedLongLongValue] == [health[@"queued"] unsignedLongLongValue] &&
                       [health[@"write_errors"] unsignedLongLongValue] == 0;
        NSString *redacted = TMHTTPRedactedURL([NSURL URLWithString:@"https://alice:tm_probe_password@example.com/a?token=tm_probe_query_secret&x=abc#tm_probe_fragment"]);
        BOOL redactionOK = [redacted containsString:@"example.com/a?"] &&
                           ![redacted containsString:@"alice"] && ![redacted containsString:@"tm_probe_"] &&
                           ![redacted containsString:@"abc"] && ![redacted containsString:@"#"];
        if (!queueOK || !redactionOK || !TMHTTPInstallHooks()) {
            PrintJSON(@{@"result": @"FAIL", @"queue_ok": @(queueOK), @"redaction_ok": @(redactionOK), @"health": health});
            return 1;
        }
        TMFixture fixture;
        if (!fixture.start()) { fprintf(stderr, "Fixture could not bind loopback\n"); return 1; }
        NSString *base = [NSString stringWithFormat:@"http://127.0.0.1:%u", fixture.port()];
        NSOperationQueue *callbackQueue = [NSOperationQueue new];
        callbackQueue.maxConcurrentOperationCount = 1;
        callbackQueue.name = @"TrafficMonitor.probe.callbacks";
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 6;
        config.timeoutIntervalForResource = 12;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:callbackQueue];
        NSURLSession *defaultSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                                  delegate:nil delegateQueue:callbackQueue];
        NSMutableArray *results = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();
        NSData *getBody = [@"get-ok" dataUsingEncoding:NSUTF8StringEncoding];
        auto request = ^NSURLRequest *(NSString *path) { return [NSURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:path]]]; };
        RunCase(session, group, results, @"get_url", request(@"/get?token=tm_probe_query_secret"), YES, 200, getBody, 0);
        NSMutableURLRequest *post = [request(@"/post?password=tm_probe_post_secret") mutableCopy];
        post.HTTPMethod = @"POST";
        post.HTTPBody = [@"payload-42" dataUsingEncoding:NSUTF8StringEncoding];
        [post setValue:@"Bearer tm_probe_header_secret" forHTTPHeaderField:@"Authorization"];
        RunCase(session, group, results, @"post_request", post, NO, 200, post.HTTPBody, 0);
        RunCase(session, group, results, @"http_404", request(@"/missing"), NO, 404, [@"not-found" dataUsingEncoding:NSUTF8StringEncoding], 0);
        RunCase(session, group, results, @"redirect", request(@"/redirect"), YES, 200, [@"final-ok" dataUsingEncoding:NSUTF8StringEncoding], 0);
        RunCase(session, group, results, @"transport_error", request(@"/disconnect"), NO, 0, nil, 1);
        NSURLSessionDataTask *cancel = RunCase(session, group, results, @"cancel", request(@"/delay"), NO, 0, nil, 2);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [cancel cancel]; });
        for (unsigned n = 0; n < 32; ++n) {
            NSString *label = [NSString stringWithFormat:@"concurrent_%u", n];
            RunCase(session, group, results, label, request([@"/get/" stringByAppendingString:label]), n % 2, 200, getBody, 0);
        }
        RunCase(NSURLSession.sharedSession, group, results, @"shared_session", request(@"/get/shared"), YES, 200, getBody, 0);
        RunCase(defaultSession, group, results, @"default_session", request(@"/get/default"), NO, 200, getBody, 0);
        BOOL timedOut = dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC)) != 0;
        if (timedOut) { PrintJSON(@{@"result": @"FAIL", @"reason": @"callback_timeout"}); return 1; }

        // Nil-completion tasks must retain their original delegate behavior and stay uncaptured.
        TMProbeDelegate *delegate = [TMProbeDelegate new];
        delegate.finished = dispatch_semaphore_create(0);
        delegate.received = [NSMutableData data];
        NSURLSession *delegated = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:callbackQueue];
        [[delegated dataTaskWithRequest:request(@"/get/delegate") completionHandler:nil] resume];
        BOOL delegateOK = dispatch_semaphore_wait(delegate.finished, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0 &&
                          delegate.calls == 1 && !delegate.error && [delegate.received isEqualToData:getBody];
        [session finishTasksAndInvalidate];
        [defaultSession finishTasksAndInvalidate];
        [delegated finishTasksAndInvalidate];
        fixture.stop();
        TMHTTPFlushForTesting();

        NSString *path = [directory stringByAppendingPathComponent:@"http-events.jsonl"];
        NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSMutableArray *http = [NSMutableArray array];
        NSMutableSet *identifiers = [NSMutableSet set];
        BOOL fieldsOK = raw != nil, bytesOK = NO, redirectOK = NO, cancellationOK = NO;
        for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
            if (!line.length) continue;
            NSDictionary *event = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if (![event[@"kind"] isEqual:@"http_request"]) continue;
            [http addObject:event];
            [identifiers addObject:event[@"request_id"] ?: @""];
            fieldsOK &= [event[@"duration_ms"] isKindOfClass:NSNumber.class] && [event[@"duration_ms"] doubleValue] >= 0;
            fieldsOK &= [event[@"pid"] intValue] == getpid() && [event[@"source"] isEqual:@"nsurlsession_data_completion"];
            if ([event[@"method"] isEqual:@"POST"]) bytesOK = [event[@"request_body_bytes"] intValue] == 10 && [event[@"response_body_bytes"] intValue] == 10;
            if ([event[@"url"] containsString:@"/redirect"]) redirectOK = [event[@"final_url"] isKindOfClass:NSString.class] && [event[@"final_url"] containsString:@"/final?"];
            if ([event[@"url"] containsString:@"/delay"]) cancellationOK = [event[@"error_code"] integerValue] == NSURLErrorCancelled && event[@"status_code"] == NSNull.null;
        }
        BOOL callbacksOK = results.count == 40;
        for (NSDictionary *result in results) callbacksOK &= [result[@"ok"] boolValue];
        struct stat fileStat{}, directoryStat{};
        BOOL permissionsOK = stat(path.fileSystemRepresentation, &fileStat) == 0 && (fileStat.st_mode & 0777) == 0600 &&
                             stat(directory.fileSystemRepresentation, &directoryStat) == 0 && (directoryStat.st_mode & 0777) == 0700;
        BOOL secretsOK = raw && ![raw containsString:@"tm_probe_"] && ![raw containsString:@"payload-42"] && ![raw containsString:@"Authorization"];
        BOOL ok = callbacksOK && delegateOK && http.count == 40 && identifiers.count == 40 &&
                  fieldsOK && bytesOK && redirectOK && cancellationOK && secretsOK && permissionsOK;
        PrintJSON(@{@"result": ok ? @"PASS" : @"FAIL", @"callbacks": results, @"http_events": @(http.count),
                    @"unique_requests": @(identifiers.count), @"fields_ok": @(fieldsOK), @"body_bytes_ok": @(bytesOK),
                    @"redirect_ok": @(redirectOK), @"cancellation_ok": @(cancellationOK), @"redaction_ok": @(secretsOK),
                    @"permissions_ok": @(permissionsOK), @"nil_completion_delegate_ok": @(delegateOK),
                    @"session_class": NSStringFromClass(object_getClass(session)),
                    @"default_class": NSStringFromClass(object_getClass(defaultSession)),
                    @"shared_class": NSStringFromClass(object_getClass(NSURLSession.sharedSession)),
                    @"health": TMHTTPHealth(), @"output_directory": directory});
        return ok ? 0 : 1;
    }
}
