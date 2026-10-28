#import "include/CBXExceptionTrap.h"

NSErrorDomain const CBXExceptionTrapErrorDomain = @"com.iliasaz.chatterbox.ExceptionTrap";
NSErrorUserInfoKey const CBXExceptionNameKey = @"CBXExceptionName";
NSErrorUserInfoKey const CBXExceptionCallStackKey = @"CBXExceptionCallStack";

BOOL CBXPerformTrappingExceptions(NS_NOESCAPE void (^block)(void),
                                  NSError *__autoreleasing _Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: @"Objective-C exception with no reason";
            if (exception.name) { info[CBXExceptionNameKey] = exception.name; }
            if (exception.callStackSymbols) { info[CBXExceptionCallStackKey] = exception.callStackSymbols; }
            *error = [NSError errorWithDomain:CBXExceptionTrapErrorDomain code:1 userInfo:info];
        }
        return NO;
    }
}
