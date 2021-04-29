//
//  ObjectArchiver.h
//  ObjectArchiver
//
//  Created by moxacist on 2021/4/27.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjectArchiver : NSObject

/// 序列化结果
- (NSData *)serializerationResult;

/// 反序列化结果
+ (instancetype)deserializeWithData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
