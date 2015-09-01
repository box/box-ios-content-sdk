//
//  BOXRequestCache.h
//  BoxContentSDK
//
//  Created on 8/25/15.
//  Copyright (c) 2015 Box. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "BOXAPIJSONOperation.h"
#import "BOXRequest.h"

@interface BOXRequestCache : NSObject

@property (nonatomic, readonly, copy) NSString *userID;

- (instancetype)initWithUserID:(NSString *)userID;

- (void)fetchCacheForKey:(NSString *)key cacheBlock:(void(^)(NSDictionary *dictionary))cacheBlock;
- (void)removeCacheForKey:(NSString *)key;
- (void)updateCacheForKey:(NSString *)key withResponse:(NSDictionary *)JSONDictionary;
- (void)removeAllCachedResponses;
- (void)clearForLogout;
@end
