#import "TMHTTP.h"
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <os/log.h>
#include <atomic>
#include <unistd.h>

typedef void (^TMCompletion)(NSData *, NSURLResponse *, NSError *);
typedef NSURLSessionDataTask *(*TMFactory)(id, SEL, id, TMCompletion);
static TMFactory gRequestFactory, gURLFactory;
static __thread unsigned gFactoryDepth;
static NSString *gProcessSession;
static NSString *gBundleIdentifier;
static double gMillisecondsPerTick;
static char gStateKey;

@interface TMHTTPState : NSObject {
@public
    std::atomic<uint64_t> firstResume;
    std::atomic<bool> completed;
    std::atomic<int64_t> responseBytes;
}
@property(nonatomic, weak) NSURLSessionTask *task;
@property(nonatomic, copy) NSString *requestID;
@property(nonatomic, copy) NSString *method;
@property(nonatomic, copy) NSString *url;
@property(nonatomic, strong) NSNumber *bodyBytes;
@property(nonatomic) uint64_t createdTicks;
@property(nonatomic) NSTimeInterval createdWall;
@property(nonatomic) BOOL delegatePath;
@property(nonatomic,copy) NSString *responseSource;
@end

@implementation TMHTTPState
- (instancetype)init {
    if ((self = [super init])) {
        firstResume.store(0);
        completed.store(false);
        responseBytes.store(-1);
    }
    return self;
}
@end

struct TMFactoryGuard {
    TMFactoryGuard() { ++gFactoryDepth; }
    ~TMFactoryGuard() { --gFactoryDepth; }
};

static void TMCompleted(TMHTTPState *state, NSData *data, NSURLResponse *response, NSError *error) {
    if (state->completed.exchange(true) || !TMMonitoringEnabled()) return;
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
        @"source": state.delegatePath?@"nsurlsession_delegate":@"nsurlsession_completion", @"method": state.method,
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
        @"response_body_bytes": data ? @(data.length) : state->responseBytes.load()>=0?@(state->responseBytes.load()):(id)NSNull.null,
        @"response_bytes_source": state.responseSource?:@"completion_nsdata_not_wire",
        @"task_count_bytes_sent": sent >= 0 ? @(sent) : (id)NSNull.null,
        @"task_count_bytes_received": received >= 0 ? @(received) : (id)NSNull.null,
        @"error_domain": errorDomain ?: (id)NSNull.null,
        @"error_code": error ? @(error.code) : (id)NSNull.null
    });
}

static TMHTTPState *TMNewState(NSURLRequest *request){
    if(!TMMonitoringEnabled() || ![@[@"http",@"https"] containsObject:request.URL.scheme.lowercaseString?:@""])return nil;
    TMHTTPState *s=[TMHTTPState new];s.requestID=NSUUID.UUID.UUIDString;
    s.method=request.HTTPMethod.length<=32?(request.HTTPMethod?:@"GET"):@"OTHER";
    s.url=TMHTTPRedactedURL(request.URL);s.bodyBytes=request.HTTPBody?@(request.HTTPBody.length):(request.HTTPBodyStream?nil:@0);
    s.createdTicks=mach_absolute_time();s.createdWall=NSDate.date.timeIntervalSince1970;return s;
}
static void TMInstallResume(Class cls){
    static NSMutableSet *done; if(!done)done=[NSMutableSet set];
    SEL selector=@selector(resume);Class owner=cls;
    while(owner){unsigned count=0;Method *methods=class_copyMethodList(owner,&count);BOOL found=NO;for(unsigned i=0;i<count;i++)if(method_getName(methods[i])==selector)found=YES;free(methods);if(found)break;owner=class_getSuperclass(owner);}
    if(!owner || [done containsObject:NSStringFromClass(owner)])return;
    [done addObject:NSStringFromClass(owner)];Method m=class_getInstanceMethod(owner,selector);IMP original=method_getImplementation(m);
    IMP hook=imp_implementationWithBlock(^(NSURLSessionTask *task){
        TMHTTPState *s=objc_getAssociatedObject(task,&gStateKey);
        if(!s){s=TMNewState(task.originalRequest);if(s){s.delegatePath=YES;s.task=task;
            if([task isKindOfClass:NSURLSessionDataTask.class]){s->responseBytes.store(0);s.responseSource=@"delegate_data_length_not_wire";}
            else s.responseSource=@"download_delegate_written_not_wire";
            objc_setAssociatedObject(task,&gStateKey,s,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}}
        if(s){uint64_t expected=0;s->firstResume.compare_exchange_strong(expected,mach_absolute_time());}
        ((void(*)(id,SEL))original)(task,selector);
    });class_replaceMethod(owner,selector,hook,method_getTypeEncoding(m));
}
static __thread unsigned gDelegateDepth;
static void TMObserveDelegate(id delegate){
    if(!delegate)return;Class cls=object_getClass(delegate);
    static NSMutableSet *done;if(!done)done=[NSMutableSet set];
    @synchronized(done){
        NSString *name=NSStringFromClass(cls);if([done containsObject:name])return;[done addObject:name];
        SEL complete=@selector(URLSession:task:didCompleteWithError:);Method m=class_getInstanceMethod(cls,complete);IMP old=m?method_getImplementation(m):nullptr;
        IMP hook=imp_implementationWithBlock(^(id object,NSURLSession *session,NSURLSessionTask *task,NSError *error){
            BOOL outer=gDelegateDepth++==0;TMHTTPState *state=objc_getAssociatedObject(task,&gStateKey);
            if(outer&&state.delegatePath){@try{TMCompleted(state,nil,task.response,error);}@catch(NSException *e){}}
            if(old)((void(*)(id,SEL,id,id,id))old)(object,complete,session,task,error);--gDelegateDepth;
        });class_replaceMethod(cls,complete,hook,m?method_getTypeEncoding(m):"v@:@@@");
        SEL receive=@selector(URLSession:dataTask:didReceiveData:);m=class_getInstanceMethod(cls,receive);IMP oldData=m?method_getImplementation(m):nullptr;
        hook=imp_implementationWithBlock(^(id object,NSURLSession *session,NSURLSessionDataTask *task,NSData *data){
            BOOL outer=gDelegateDepth++==0;TMHTTPState *state=objc_getAssociatedObject(task,&gStateKey);if(outer&&state.delegatePath)state->responseBytes.fetch_add(data.length);
            if(oldData)((void(*)(id,SEL,id,id,id))oldData)(object,receive,session,task,data);--gDelegateDepth;
        });class_replaceMethod(cls,receive,hook,m?method_getTypeEncoding(m):"v@:@@@");
        SEL progress=@selector(URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:);m=class_getInstanceMethod(cls,progress);IMP oldProgress=m?method_getImplementation(m):nullptr;
        hook=imp_implementationWithBlock(^(id object,NSURLSession *session,NSURLSessionDownloadTask *task,int64_t delta,int64_t total,int64_t expected){
            TMHTTPState *s=objc_getAssociatedObject(task,&gStateKey);if(s.delegatePath)s->responseBytes.store(total);
            if(oldProgress)((void(*)(id,SEL,id,id,int64_t,int64_t,int64_t))oldProgress)(object,progress,session,task,delta,total,expected);
        });class_replaceMethod(cls,progress,hook,m?method_getTypeEncoding(m):"v@:@@qqq");
    }
}

typedef void(^TMDownloadCompletion)(NSURL *,NSURLResponse *,NSError *);
static IMP gUploadData,gUploadFile,gDownloadURL,gDownloadRequest;
static id TMUpload(id object,SEL selector,NSURLRequest *request,id body,TMCompletion callback,BOOL file){
    IMP original=file?gUploadFile:gUploadData;
    if(gFactoryDepth||!callback)return ((id(*)(id,SEL,id,id,id))original)(object,selector,request,body,callback);
    TMFactoryGuard guard;TMHTTPState *s=TMNewState(request);if(!s)return ((id(*)(id,SEL,id,id,id))original)(object,selector,request,body,callback);
    s.bodyBytes=file?nil:@([body length]);id task=((id(*)(id,SEL,id,id,id))original)(object,selector,request,body,^(NSData *data,NSURLResponse *response,NSError *error){@try{TMCompleted(s,data,response,error);}@catch(NSException *e){}callback(data,response,error);});
    s.task=task;objc_setAssociatedObject(task,&gStateKey,s,OBJC_ASSOCIATION_RETAIN_NONATOMIC);return task;
}
static id TMUploadData(id o,SEL c,NSURLRequest*r,NSData*d,TMCompletion b){return TMUpload(o,c,r,d,b,NO);}
static id TMUploadFile(id o,SEL c,NSURLRequest*r,NSURL*d,TMCompletion b){return TMUpload(o,c,r,d,b,YES);}
static id TMDownload(id object,SEL selector,id input,TMDownloadCompletion callback,BOOL isURL){
    IMP original=isURL?gDownloadURL:gDownloadRequest;
    if(gFactoryDepth||!callback)return ((id(*)(id,SEL,id,id))original)(object,selector,input,callback);
    TMFactoryGuard guard;TMHTTPState *s=TMNewState(isURL?[NSURLRequest requestWithURL:input]:input);
    if(!s)return ((id(*)(id,SEL,id,id))original)(object,selector,input,callback);
    s.responseSource=@"download_file_not_read";id task=((id(*)(id,SEL,id,id))original)(object,selector,input,^(NSURL *url,NSURLResponse *response,NSError *error){@try{TMCompleted(s,nil,response,error);}@catch(NSException*e){}callback(url,response,error);});
    s.task=task;objc_setAssociatedObject(task,&gStateKey,s,OBJC_ASSOCIATION_RETAIN_NONATOMIC);return task;
}
static id TMDownloadURL(id o,SEL c,NSURL*u,TMDownloadCompletion b){return TMDownload(o,c,u,b,YES);}
static id TMDownloadRequest(id o,SEL c,NSURLRequest*u,TMDownloadCompletion b){return TMDownload(o,c,u,b,NO);}
static void TMSwap(Class cls,SEL selector,IMP replacement,IMP *original){Method m=class_getInstanceMethod(cls,selector);if(m){*original=method_getImplementation(m);class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(m));}}

static NSURLSessionDataTask *TMCreate(id object, SEL selector, id input,
                                    TMCompletion completion, BOOL isURL) {
    TMFactory original = isURL ? gURLFactory : gRequestFactory;
    if(!TMMonitoringEnabled())return original(object,selector,input,completion);
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
        TMInstallResume(taskClass);
        NSURLRequest *probeRequest=[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1/"]];
        NSURLSessionTask *uploadSample=[session uploadTaskWithRequest:probeRequest fromData:NSData.data completionHandler:^(NSData*d,NSURLResponse*r,NSError*e){}];
        NSURLSessionTask *downloadSample=[session downloadTaskWithRequest:probeRequest completionHandler:^(NSURL*u,NSURLResponse*r,NSError*e){}];
        TMInstallResume(object_getClass(uploadSample));TMInstallResume(object_getClass(downloadSample));[uploadSample cancel];[downloadSample cancel];
        Class meta=object_getClass(NSURLSession.class);SEL factory=@selector(sessionWithConfiguration:delegate:delegateQueue:);
        Method fm=class_getInstanceMethod(meta,factory);IMP originalFactory=method_getImplementation(fm);
        IMP factoryHook=imp_implementationWithBlock(^id(id self,NSURLSessionConfiguration *config,id delegate,NSOperationQueue *queue){TMObserveDelegate(delegate);return ((id(*)(id,SEL,id,id,id))originalFactory)(self,factory,config,delegate,queue);});
        class_replaceMethod(meta,factory,factoryHook,method_getTypeEncoding(fm));
        TMSwap(sessionClass,@selector(uploadTaskWithRequest:fromData:completionHandler:),(IMP)TMUploadData,&gUploadData);
        TMSwap(sessionClass,@selector(uploadTaskWithRequest:fromFile:completionHandler:),(IMP)TMUploadFile,&gUploadFile);
        TMSwap(sessionClass,@selector(downloadTaskWithURL:completionHandler:),(IMP)TMDownloadURL,&gDownloadURL);
        TMSwap(sessionClass,@selector(downloadTaskWithRequest:completionHandler:),(IMP)TMDownloadRequest,&gDownloadRequest);
        class_replaceMethod(sessionClass, requestSelector, (IMP)TMRequest, method_getTypeEncoding(requestMethod));
        class_replaceMethod(sessionClass, urlSelector, (IMP)TMURL, method_getTypeEncoding(urlMethod));
        installed = YES;
        os_log_t log = os_log_create("com.example.trafficmonitor", "http");
        os_log(log, "event=http_hooks_installed session_class=%{public}s task_class=%{public}s",
               class_getName(sessionClass), class_getName(taskClass));
    });
    return installed;
}
