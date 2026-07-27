// Bridging header for the Macterm app target (wired via
// SWIFT_OBJC_BRIDGING_HEADER in project.yml). Swift has no @try/@catch, so
// the ObjC exception trampoline below can't be pure Swift.
#import "System/ObjCExceptionCatcher.h"
