#import "TMHTTP.h"
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <atomic>
#include <unistd.h>

typedef void (^TMCompletion)(NSData *, NSURLResponse *, NSError *);
typedef NSURLSessionDataTask *(*TMFactory)(id, SEL, id, TMCompletion);
static TMFactory gRequestFactory, gURLFactory;
static void (*gResume)(id, SEL);
static __thread unsigned gFactoryDepth;
static NSString *gProcessSession;
static NSString *gBundleIdentifier;
static double gMillisecondsPerTick;
static char gStateKey;

@interface TMHTTPState : NSObject {
@public
    std::atomic<uint64_t> firstResume;
    std::atomic<bool> completed;
}
@property(nonatomic, weak) NSURLSessionTask *task;
@property(nonatomic, copy) NSString *requestID;
@property(nonatomic, copy) NSString *method;
@property(nonatomic, copy) NSString *url;
@property(nonatomic, strong) NSNumber *bodyBytes;
@property(nonatomic) uint64_t createdTicks;
@property(nonatomic) NSTimeInterval createdWall;
@end

@implementation TMHTTPState
- (instancetype)init {
    if ((self = [super init])) {
        firstResume.store(0);
        completed.store(false);
    }
    return self;
}
@end

struct TMFactoryGuard {
    TMFactoryGuard() { ++gFactoryDepth; }
    ~TMFactoryGuard() { --gFactoryDepth; }
};

static void TMResume(id object, SEL selector) {
    TMHTTPState *state = objc_getAssociatedObject(object, &gStateKey);
    if (state) {
        uint64_t expected = 0;
        state->firstResume.compare_exchange_strong(expected, mach_absolute_time());
    }
    gResume(object, selector);
}

static void TMCompleted(TMHTTPState *state, NSData *data, NSURLResponse *response, NSError *error) {
    if (state->completed.exchange(true)) return;
    const uint64_t completedTicks = mach_absolute_time();
    const uint64_t resumedTicks = state->firstResume.load();
    NSURLSessionTask *task = state.task;
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
    const int64_t sent = task ? task.countOfBytesSent : -1;
    const int64_t received = task ? task.countOfBytesReceived : -1;
    NSString *errorDomain = nil;
    if (error) {
        // Never persist localizedDescription or userInfo: they can contain raw URLs.
        errorDomain = [@[@"NSURLErrorDomain", @"NSCocoaErrorDomain", @"kCFErrorDomainCFNetwork"]
                       containsObject:error.domain] ? error.domain : @"other";
    }
    TMHTTPEnqueue(@{
        @"schema_version": @1, @"kind": @"http_request", @"request_id": state.requestID,
        @"process_session": gProcessSession, @"pid": @((int)getpid()),
        @"bundle_id": gBundleIdentifier,
        @"source": @"nsurlsession_data_completion", @"method": state.method,
        @"url": state.url, @"final_url": response.URL ? TMHTTPRedactedURL(response.URL) : (id)NSNull.null,
        @"created_at_unix": @(state.createdWall),
        @"first_resume_at_unix": resumedTicks ? @(state.createdWall +
            (resumedTicks - state.createdTicks) * gMillisecondsPerTick / 1000.0) : (id)NSNull.null,
        @"completed_at_unix": @(NSDate.date.timeIntervalSince1970),
        @"duration_ms": resumedTicks ? @((completedTicks - resumedTicks) * gMillisecondsPerTick) : (id)NSNull.null,
        @"duration_source": @"first_resume_to_completion_callback_including_suspension",
        @"task_identifier": task ? @(task.taskIdentifier) : (id)NSNull.null,
        @"status_code": http ? @(http.statusCode) : (id)NSNull.null,
        @"request_body_bytes": state.bodyBytes ?: (id)NSNull.null,
        @"request_bytes_source": state.bodyBytes ? @"httpbody_snapshot_not_wire" : @"unknown_stream",
        @"response_body_bytes": data ? @(data.length) : (id)NSNull.null,
        @"response_bytes_source": @"completion_nsdata_not_wire",
        @"task_count_bytes_sent": sent >= 0 ? @(sent) : (id)NSNull.null,
        @"task_count_bytes_received": received >= 0 ? @(received) : (id)NSNull.null,
        @"error_domain": errorDomain ?: (id)NSNull.null,
        @"error_code": error ? @(error.code) : (id)NSNull.null
    });
}

static NSURLSessionDataTask *TMCreate(id object, SEL selector, id input,
                                    TMCompletion completion, BOOL isURL) {
    TMFactory original = isURL ? gURLFactory : gRequestFactory;
    if (gFactoryDepth) return original(object, selector, input, completion);
    TMFactoryGuard guard;
    if (!completion || !input) return original(object, selector, input, completion);
    NSURLRequest *request = isURL ? [NSURLRequest requestWithURL:input] : input;
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (![@[@"http", @"https"] containsObject:scheme ?: @""]) {
        return original(object, selector, input, completion);
    }
    TMHTTPState *state = [TMHTTPState new];
    state.requestID = NSUUID.UUID.UUIDString;
    state.method = request.HTTPMethod.length <= 32 ? (request.HTTPMethod ?: @"GET") : @"OTHER";
    state.url = TMHTTPRedactedURL(request.URL);
    NSData *body = request.HTTPBody;
    state.bodyBytes = body ? @(body.length) : (request.HTTPBodyStream ? nil : @0);
    state.createdTicks = mach_absolute_time();
    state.createdWall = NSDate.date.timeIntervalSince1970;
    NSURLSessionDataTask *task = original(object, selector, input,
        ^(NSData *data, NSURLResponse *response, NSError *error) {
            @try { TMCompleted(state, data, response, error); }
            @catch (NSException *exception) {
                // Monitoring must never suppress or duplicate the application's callback.
                TMHTTPEnqueue(@{@"kind": @"capture_error", @"reason": @"metadata_exception"});
            }
            completion(data, response, error); // Same system-provided callback queue and arguments.
        });
    state.task = task;
    if (task) objc_setAssociatedObject(task, &gStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return task;
}

static NSURLSessionDataTask *TMRequest(id object, SEL selector, NSURLRequest *request, TMCompletion completion) {
    return TMCreate(object, selector, request, completion, NO);
}
static NSURLSessionDataTask *TMURL(id object, SEL selector, NSURL *url, TMCompletion completion) {
    return TMCreate(object, selector, url, completion, YES);
}

BOOL TMHTTPInstallHooks(void) {
    static dispatch_once_t once;
    static BOOL installed;
    dispatch_once(&once, ^{
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        gMillisecondsPerTick = (double)timebase.numer / timebase.denom / 1e6;
        gProcessSession = NSUUID.UUID.UUIDString;
        gBundleIdentifier = [NSBundle.mainBundle.bundleIdentifier copy] ?: @"<command-line-probe>";
        NSURLSession *session = NSURLSession.sharedSession;
        Class sessionClass = object_getClass(session);
        SEL requestSelector = @selector(dataTaskWithRequest:completionHandler:);
        SEL urlSelector = @selector(dataTaskWithURL:completionHandler:);
        Method requestMethod = class_getInstanceMethod(sessionClass, requestSelector);
        Method urlMethod = class_getInstanceMethod(sessionClass, urlSelector);
        // This task is never resumed and generates no network activity or monitor event.
        NSURLSessionDataTask *sample = [session dataTaskWithURL:[NSURL URLWithString:@"http://127.0.0.1/"]
                                           completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}];
        Class taskClass = object_getClass(sample);
        SEL resumeSelector = @selector(resume);
        Method resumeMethod = class_getInstanceMethod(taskClass, resumeSelector);
        [sample cancel];
        if (!requestMethod || !urlMethod || !resumeMethod) return;
        // Capture the current chain, then add concrete overrides for inherited methods.
        gRequestFactory = (TMFactory)method_getImplementation(requestMethod);
        gURLFactory = (TMFactory)method_getImplementation(urlMethod);
        gResume = (void (*)(id, SEL))method_getImplementation(resumeMethod);
        class_replaceMethod(taskClass, resumeSelector, (IMP)TMResume, method_getTypeEncoding(resumeMethod));
        class_replaceMethod(sessionClass, requestSelector, (IMP)TMRequest, method_getTypeEncoding(requestMethod));
        class_replaceMethod(sessionClass, urlSelector, (IMP)TMURL, method_getTypeEncoding(urlMethod));
        installed = YES;
        os_log_t log = os_log_create("com.example.trafficmonitor", "http");
        os_log(log, "event=http_hooks_installed session_class=%{public}s task_class=%{public}s",
               class_getName(sessionClass), class_getName(taskClass));
    });
    return installed;
}
