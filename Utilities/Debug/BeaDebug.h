#import <Foundation/Foundation.h>
#import <os/log.h>
#import <stdlib.h>

// Nikolozi's verbose network/runtime diagnostics ([BeaNet] request/response
// logging, [BeaDiag] view-hierarchy dumps, [BeaClassDump] full class/method
// surveys, and the per-layout-pass gating-overlay scan log) are OFF by
// default. This tweak ships to end users, not just active development - it
// must not spend cycles hooking every loaded class's URLSession delegate
// callbacks, dumping method lists, or logging request/response bodies (which
// can include auth tokens and other PII) unless a developer explicitly opts
// in. Set MINIBEA_DEBUG=1 in the process environment before BeReal launches
// (e.g. an Xcode scheme's environment variables, or `launchctl setenv
// MINIBEA_DEBUG 1` on a jailbroken device) to re-enable it.
static inline BOOL BeaDebugLoggingEnabled(void) {
	static BOOL enabled = NO;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		const char *value = getenv("MINIBEA_DEBUG");
		enabled = value != NULL && atoi(value) != 0;
	});
	return enabled;
}

#define BeaLog(fmt, ...) do { if (BeaDebugLoggingEnabled()) os_log(OS_LOG_DEFAULT, fmt, ##__VA_ARGS__); } while (0)
