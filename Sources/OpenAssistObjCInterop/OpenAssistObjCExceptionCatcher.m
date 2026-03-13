#import "OpenAssistObjCExceptionCatcher.h"

@implementation OpenAssistObjCExceptionCatcher

+ (BOOL)performBlock:(NS_NOESCAPE dispatch_block_t)block
               error:(NSError * _Nullable __autoreleasing * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: @"Unknown Objective-C exception.";
            *error = [NSError errorWithDomain:@"OpenAssist.ObjCException"
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: reason,
                                         @"exceptionName": exception.name
                                     }];
        }
        return NO;
    }
}

@end
