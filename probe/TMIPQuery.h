#pragma once
#import <Foundation/Foundation.h>

// Uses the current iOS system proxy/PAC and VPN routing. No curl dependency.
NSDictionary *TMQueryPublicIP(NSError **error);
BOOL TMIPQuerySelfTest(void);
