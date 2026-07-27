import Foundation

/// Runs `body`, catching any Objective-C exception raised inside it. Returns
/// the caught exception, or nil when `body` completes normally.
///
/// Swift can't catch ObjC exceptions, and one escaping to the top of the run
/// loop kills the process *without a crash report*: HIToolbox's top-level
/// handler logs a reason-redacted FAULT and exits (see ExceptionReporting).
/// AppKit does throw from otherwise-innocuous calls — observed 2026-07-28 on
/// macOS beta: ViewBridge's NSRemoteView (the text-input cursor UI hosted
/// inside our windows) raised NSInternalInconsistencyException out of
/// `makeKeyAndOrderFront` while the quick terminal opened, taking the whole
/// app down. This trampolines through an ObjC shim (ObjCExceptionCatcher.m)
/// so known-flaky AppKit calls can fail soft instead.
func catchingObjCException(_ body: () -> Void) -> NSException? {
    MactermCatchObjCException(body)
}
