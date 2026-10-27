#import <Foundation/Foundation.h>
#import <os/log.h>
#import <unistd.h>
#import "Sources/TMTarget.h"

#ifndef TM_ROOTLESS
#error TM_ROOTLESS must be set by the project Makefile
#endif

// Stage 1 deliberately only confirms injection. No network hooks or service.
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

        const char *mode = TM_ROOTLESS ? "rootless" : "rootful";
        os_log_with_type(log, OS_LOG_TYPE_DEFAULT,
                         "stage=1 event=loaded version=0.1.0 mode=%{public}s "
                         "bundle=%{public}@ pid=%d capture=disabled",
                         mode, bundleID, (int)getpid());
    }
}

%ctor {
    TMStart();
}
