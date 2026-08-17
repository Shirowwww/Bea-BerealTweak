#import "BeaOwnership.h"
#import <objc/runtime.h>

static const void *BeaOwnedViewKey = &BeaOwnedViewKey;

void BeaMarkViewAsOurs(UIView *view) {
	if (!view) return;
	objc_setAssociatedObject(view, BeaOwnedViewKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL BeaViewIsOurs(UIView *view) {
	if (!view) return NO;
	if (objc_getAssociatedObject(view, BeaOwnedViewKey)) return YES;
	// Every class in this project is named Bea*, which covers the injected
	// buttons and the tap overlays without anything having to mark them.
	return [NSStringFromClass([view class]) hasPrefix:@"Bea"];
}
