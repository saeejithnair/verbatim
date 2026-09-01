#import "ObjCTry.h"

NSException * _Nullable VBTryCatch(void (NS_NOESCAPE ^ _Nonnull block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}
