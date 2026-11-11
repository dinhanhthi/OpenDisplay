#import "ODRotation.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

/// The C shape of -[MPDisplay setOrientation:], used only after its argument type was checked.
typedef void (*ODSetOrientation)(id, SEL, int32_t);

/// MonitorPanel's display manager, looked up once; nil when the framework, the class or +sharedMgr is missing.
static NSObject *ODManager(void) {
    static NSObject *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            // Never dlclose: the classes live as long as the process.
            if (dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_NOW) == NULL) {
                return;
            }
            Class type = NSClassFromString(@"MPDisplayMgr");
            SEL shared = NSSelectorFromString(@"sharedMgr");
            Method method = type != Nil ? class_getClassMethod(type, shared) : NULL;
            // Only a method that takes nothing and returns an object is called.
            if (method == NULL || method_getNumberOfArguments(method) != 2) {
                return;
            }
            char returnType[2] = "";
            method_getReturnType(method, returnType, sizeof(returnType));
            if (strcmp(returnType, "@") != 0) {
                return;
            }
            id found = ((id (*)(id, SEL))objc_msgSend)(type, shared);
            if ([found isKindOfClass:[NSObject class]]) {
                manager = found;
            }
        } @catch (NSException *exception) {
            manager = nil;
        }
    });
    return manager;
}

/// The MPDisplay of a display id (MonitorPanel keeps it as a signed int), nil when it lists none.
static NSObject *ODDisplay(CGDirectDisplayID display) {
    NSObject *manager = ODManager();
    if (manager == nil || ![manager respondsToSelector:NSSelectorFromString(@"displays")]) {
        return nil;
    }
    id list = [manager valueForKey:@"displays"];
    if (![list isKindOfClass:[NSArray class]]) {
        return nil;
    }
    for (NSObject *candidate in (NSArray *)list) {
        if (![candidate respondsToSelector:NSSelectorFromString(@"displayID")]) {
            continue;
        }
        id number = [candidate valueForKey:@"displayID"];
        if ([number isKindOfClass:[NSNumber class]] && ((NSNumber *)number).unsignedIntValue == display) {
            return candidate;
        }
    }
    return nil;
}

/// The implementation of the display's setOrientation:, NULL unless it takes self, _cmd and one 32-bit integer.
static ODSetOrientation ODSetter(NSObject *display) {
    SEL selector = NSSelectorFromString(@"setOrientation:");
    Method method = class_getInstanceMethod([display class], selector);
    if (method == NULL || ![display respondsToSelector:selector] || method_getNumberOfArguments(method) != 3) {
        return NULL;
    }
    char *type = method_copyArgumentType(method, 2);
    BOOL isInt32 = type != NULL && (strcmp(type, "i") == 0 || strcmp(type, "I") == 0);
    free(type);
    return isInt32 ? (ODSetOrientation)method_getImplementation(method) : NULL;
}

BOOL ODRotationAvailable(CGDirectDisplayID display) {
    @try {
        NSObject *found = ODDisplay(display);
        return found != nil && ODSetter(found) != NULL;
    } @catch (NSException *exception) {
        return NO;
    }
}

BOOL ODRotationSet(CGDirectDisplayID display, int32_t degrees) {
    @try {
        NSObject *found = ODDisplay(display);
        ODSetOrientation set = found != nil ? ODSetter(found) : NULL;
        if (set == NULL) {
            return NO;
        }
        set(found, NSSelectorFromString(@"setOrientation:"), degrees);
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}
