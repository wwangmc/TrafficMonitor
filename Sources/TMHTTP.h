#pragma once
#import <Foundation/Foundation.h>

// Stage 2: process-local HTTP diagnostics, not Socket or wire-level counters.
void TMHTTPRecorderStart(NSString *directory);
void TMHTTPEnqueue(NSDictionary *event);
NSDictionary *TMHTTPHealth(void);
// Explicitly for the command-line probe. Never called from a network callback.
void TMHTTPFlushForTesting(void);
NSString *TMHTTPRedactedURL(NSURL *url);
BOOL TMHTTPInstallHooks(void);
BOOL TMMonitoringEnabled(void);
