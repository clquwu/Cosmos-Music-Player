//
//  ObjCExceptionCatcher.m
//  Cosmos Music Player
//
//  Catches Objective-C exceptions that Swift can't handle
//

#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)tryCatch:(void(^)(void))tryBlock error:(NSError **)error {
    @try {
        tryBlock();
        return YES;
    }
    @catch (NSException *exception) {
        NSLog(@"⚠️ Caught Objective-C exception: %@ - %@", exception.name, exception.reason);
        if (error) {
            *error = [NSError errorWithDomain:@"ObjCException"
                                        code:-1
                                    userInfo:@{
                                        NSLocalizedDescriptionKey: exception.reason ?: @"Objective-C exception occurred",
                                        NSLocalizedFailureReasonErrorKey: exception.name,
                                        @"ExceptionName": exception.name,
                                        @"ExceptionReason": exception.reason ?: @"Unknown"
                                    }];
        }
        return NO;
    }
}

@end
