#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching any Objective-C exception it raises. Returns the
/// caught exception, or nil when the block completes normally. Swift-side
/// callers use the `catchingObjCException` wrapper (ObjCExceptionCatcher.swift);
/// this lives in Objective-C only because Swift has no @try/@catch.
NSException *_Nullable MactermCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
