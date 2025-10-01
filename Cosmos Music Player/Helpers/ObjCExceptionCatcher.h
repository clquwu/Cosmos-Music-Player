//
//  ObjCExceptionCatcher.h
//  Cosmos Music Player
//
//  Catches Objective-C exceptions that Swift can't handle
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

/// Executes a block and catches any Objective-C exceptions
/// Returns YES if successful, NO if an exception was caught
+ (BOOL)tryCatch:(void(^)(void))tryBlock error:(NSError *_Nullable __autoreleasing *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
