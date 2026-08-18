#import <Foundation/Foundation.h>
#import <os/log.h>

// Nikolozi's verbose network/runtime diagnostics ([BeaNet] request/response
// logging, [BeaDiag] view-hierarchy dumps, [BeaClassDump] full class/method
// surveys, and the per-layout-pass gating-overlay scan log) are OFF by
// default. This tweak ships to end users, not just active development - it
// must not spend cycles hooking every loaded class's URLSession delegate
// callbacks, dumping method lists, or logging request/response bodies (which
// can include auth tokens and other PII) unless someone explicitly opts in.
//
// Two ways in, because the original one is unreachable for the people who
// actually hit these bugs. MINIBEA_DEBUG=1 in the process environment needs
// an Xcode scheme or `launchctl setenv` on a jailbroken device - neither of
// which a sideloaded install has. The MiniBea settings screen (long-press the
// "+") writes the same switch into NSUserDefaults, which is why this is a
// cached variable rather than a getenv() behind dispatch_once: it has to be
// able to change without relaunching.
FOUNDATION_EXPORT BOOL BeaDebugLoggingEnabledFlag;

// Re-reads both sources. Called from +load and whenever the switch is flipped.
FOUNDATION_EXPORT void BeaDebugRefreshLoggingFlag(void);

static inline BOOL BeaDebugLoggingEnabled(void) {
	return BeaDebugLoggingEnabledFlag;
}

#define BeaLog(fmt, ...) do { if (BeaDebugLoggingEnabled()) os_log(OS_LOG_DEFAULT, fmt, ##__VA_ARGS__); } while (0)
