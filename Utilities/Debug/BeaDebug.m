#import "BeaDebug.h"
#import <stdlib.h>

BOOL BeaDebugLoggingEnabledFlag = NO;

void BeaDebugRefreshLoggingFlag(void) {
	const char *value = getenv("MINIBEA_DEBUG");
	if (value != NULL && atoi(value) != 0) {
		BeaDebugLoggingEnabledFlag = YES;
		return;
	}
	// Read by string rather than through BeaSettings, so this file stays free
	// of any dependency that could pull it into a +load ordering problem -
	// this one has to be usable from the very first hook that runs.
	BeaDebugLoggingEnabledFlag = [[NSUserDefaults standardUserDefaults] boolForKey:@"BeaDebugLogging"];
}

@interface BeaDebugLoader : NSObject
@end

@implementation BeaDebugLoader
+ (void)load {
	BeaDebugRefreshLoggingFlag();
}
@end
