#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpenAssistObjCExceptionCatcher : NSObject

+ (BOOL)performBlock:(NS_NOESCAPE dispatch_block_t)block
               error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
