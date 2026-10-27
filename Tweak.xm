#import <Foundation/Foundation.h>
#import <os/log.h>
#import <unistd.h>
#import "Sources/TMTarget.h"
#import "Sources/TMHTTP.h"

#ifndef TM_ROOTLESS
#error TM_ROOTLESS must be set by the project Makefile
#endif

// Only the exact configured application starts process-local HTTP diagnostics.
static void TMStart(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        // Defense in depth if an injector disregards or caches the Filter plist.
        if (![bundleID isEqualToString:TM_TARGET_BUNDLE_ID]) {
            return;
        }

        os_log_t log = os_log_create("com.example.trafficmonitor", "bootstrap");
        NSOperatingSystemVersion minimum = {TM_ROOTLESS ? 15 : 14, 0, 0};
        if (![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:minimum]) {
            os_log_error(log, "stage=1 event=unsupported_os minimum=%ld",
                         (long)minimum.majorVersion);
            return;
        }

        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"TrafficMonitor"];
        TMHTTPRecorderStart(directory);
        BOOL enabled = TMHTTPInstallHooks();
        const char *mode = TM_ROOTLESS ? "rootless" : "rootful";
        os_log_with_type(log, OS_LOG_TYPE_DEFAULT,
                         "stage=2 event=loaded version=0.2.0 mode=%{public}s "
                         "bundle=%{public}@ pid=%d http_enabled=%d sink=app_tmp/TrafficMonitor/http-events.jsonl",
                         mode, bundleID, (int)getpid(), (int)enabled);
    }
}

%ctor {
    TMStart();
}
