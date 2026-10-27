#import "TMIPQuery.h"
#include "TMFixture.h"
#include <arpa/inet.h>

static NSError *IPError(NSString *message) {
    return [NSError errorWithDomain:@"TrafficMonitor.IP" code:1
                          userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSURLSessionConfiguration *SystemConfiguration(void) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 12;
    configuration.timeoutIntervalForResource = 18;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    // Leave connectionProxyDictionary nil: NSURLSession consults current system
    // settings, including PAC. Never replace it with an empty dictionary, disable
    // proxies, bind an interface, or fall back to a direct socket on failure.
    return configuration;
}

static NSDictionary *Query(NSURL *url, NSURLSessionConfiguration *configuration, NSError **error) {
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block NSData *body = nil;
    __block NSError *failure = nil;
    __block NSInteger status = 0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        body = data;
        failure = err;
        status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_semaphore_signal(finished);
    }];
    [task resume];
    if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC))) {
        [session invalidateAndCancel];
        if (error) *error = IPError(@"查询超时，请检查手机网络和系统代理");
        return nil;
    }
    [session finishTasksAndInvalidate];
    if (failure || status != 200 || !body.length || body.length > 65536) {
        if (error) *error = failure ?: IPError([NSString stringWithFormat:@"查询失败（HTTP %ld）",(long)status]);
        return nil;
    }
    id value = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"status"] isEqual:@"success"] || ![value[@"query"] isKindOfClass:NSString.class]) {
        if (error) *error = IPError(@"IP 服务返回无效数据或请求过于频繁");
        return nil;
    }
    unsigned char address[16];
    const char *ip = [value[@"query"] UTF8String];
    if (inet_pton(AF_INET, ip, address) != 1 && inet_pton(AF_INET6, ip, address) != 1) {
        if (error) *error = IPError(@"IP 服务返回无效地址");
        return nil;
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:@{@"status":@"success"}];
    for (NSString *key in @[@"query",@"country",@"regionName",@"city",@"isp",@"org",@"timezone"]) {
        if ([value[key] isKindOfClass:NSString.class]) result[key] = [value[key] substringToIndex:MIN([value[key] length],512U)];
    }
    return result;
}

NSDictionary *TMQueryPublicIP(NSError **error) {
    return Query([NSURL URLWithString:@"http://ip-api.com/json"], SystemConfiguration(), error);
}

BOOL TMIPQuerySelfTest(void) {
    TMFixture proxy;
    if (!proxy.start()) return NO;
    NSURLSessionConfiguration *configuration = SystemConfiguration();
    if (configuration.connectionProxyDictionary != nil) return NO;
    // .invalid can never resolve directly. Success requires sending the GET
    // through this local HTTP proxy; no external service is used by CI.
    configuration.connectionProxyDictionary = @{@"HTTPEnable":@YES,@"HTTPProxy":@"127.0.0.1",@"HTTPPort":@(proxy.port())};
    NSError *error = nil;
    NSDictionary *result = Query([NSURL URLWithString:@"http://ip-api.invalid/json"], configuration, &error);
    if (error || ![result[@"query"] isEqual:@"203.0.113.42"]) return NO;
    NSURLSessionConfiguration *direct = SystemConfiguration();
    direct.connectionProxyDictionary = @{}; // Test fixture only, never production.
    NSString *base = [NSString stringWithFormat:@"http://127.0.0.1:%u",proxy.port()];
    if (Query([NSURL URLWithString:[base stringByAppendingString:@"/get"]],direct,&error) || !error) return NO;
    error = nil;
    if (Query([NSURL URLWithString:[base stringByAppendingString:@"/missing"]],direct,&error) || !error) return NO;
    return YES;
}
