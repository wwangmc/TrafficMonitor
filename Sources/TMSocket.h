#pragma once
#import <Foundation/Foundation.h>
BOOL TMSocketInstall(void);
void TMSocketDrain(void);
void TMSocketDiscard(void);
NSDictionary *TMSocketHealth(void);
BOOL TMSocketSelfTest(void);
