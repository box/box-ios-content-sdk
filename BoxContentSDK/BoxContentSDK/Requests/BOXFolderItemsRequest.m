//
//  BOXFolderItemsRequest.m
//  BoxContentSDK
//

#import "BOXFolderItemsRequest.h"

#import "BOXRequest_Private.h"
#import "BOXFolderPaginatedItemsRequest.h"

#import "BOXAPIJSONOperation.h"
#import "BOXBookmark.h"
#import "BOXFile.h"
#import "BOXFolder.h"
#import "BOXItem.h"
#import "BOXSharedLinkHeadersHelper.h"
#import "BOXFolderPaginatedItemsRequest_Private.h"

@interface BOXFolderItemsRequest ()
@property (nonatomic) BOOL isCancelled;

- (NSArray *)itemsFromJSONDictionary:(NSDictionary *)JSONDictionary;

@end

@implementation BOXFolderItemsRequest

- (instancetype)initWithFolderID:(NSString *)folderID
{
    if (self = [super init]) {
        self.folderID = folderID;
        self.limit = self.rangeStep;        
        self.offset = 0;
    }
    
    return self;
}

- (void)cancel
{
    @synchronized(self) {
        [super cancel];
        self.isCancelled = YES;
    }
}

- (NSUInteger)rangeStep
{
    return 1000;
}

+ (NSString *)uniqueHashForItem:(BOXItem *)item
{
    NSString *uniqueItemHash = item.modelID;
    
    if ([item isKindOfClass:[BOXFile class]]) {
        uniqueItemHash = [uniqueItemHash stringByAppendingString:@"_file"];
    } else if ([item isKindOfClass:[BOXFolder class]]) {
        uniqueItemHash = [uniqueItemHash stringByAppendingString:@"_folder"];
    } else if ([item isKindOfClass:[BOXBookmark class]]) {
        uniqueItemHash = [uniqueItemHash stringByAppendingString:@"_bookmark"];
    }
    
    return uniqueItemHash;
}

+ (NSArray *)dedupeItemsByBoxID:(NSArray *)items
{
    NSMutableArray *results = [[NSMutableArray alloc] init];
    NSMutableSet *uniqueItemSet = [[NSMutableSet alloc] init];
    for (BOXItem *item in items) {
        NSString *uniqueItemHash = [self uniqueHashForItem:item];
        
        if ([uniqueItemSet containsObject:uniqueItemHash] == NO) {
            [uniqueItemSet addObject:uniqueItemHash];
            [results addObject:item];
        }
    }
 
    return [results copy];
}


- (void)performRequestWithCompletion:(BOXItemsBlock)completionBlock
{
    [self performRequestWithCached:nil refreshed:completionBlock];
}

- (void)performRequestWithCached:(BOXItemsBlock)cacheBlock refreshed:(BOXItemsBlock)refreshBlock
{
    __weak BOXFolderItemsRequest *weakSelf = self;
    
    if (cacheBlock) {
        if (self.requestCache) {
            void (^localCacheBlock)(NSDictionary *JSONDictionary) = ^void(NSDictionary *JSONDictionary) {
                NSArray *items = [weakSelf itemsFromJSONDictionary:JSONDictionary];
                cacheBlock(items, nil);
            };
            [weakSelf.requestCache fetchCacheResponseForRequest:weakSelf cacheBlock:localCacheBlock];
        }
    }
    
    if (refreshBlock) {
        BOOL isMainThread = [NSThread isMainThread];
        
        NSMutableArray *results = [[NSMutableArray alloc] init];
        
        // used to work around warning on retain loop on paginatedItemFetch
        __block BOXItemArrayCompletionBlock recursiveFetch = nil;
        
        BOXItemsBlock localRefreshBlock = ^(NSArray *items, NSError *error){
            [BOXDispatchHelper callCompletionBlock:^{
                refreshBlock(items, error);
            } onMainThread:isMainThread];
        };
        
        BOXItemArrayCompletionBlock paginatedRefreshItemFetch = ^(NSArray *items, NSUInteger totalCount, NSRange range, NSError *error) {
            @synchronized(weakSelf) {
                if (error) {
                    localRefreshBlock(nil, error);
                    //TODO: only if not network error
                    [weakSelf.requestCache removeCacheResponseForRequest:weakSelf];
                } else {
                    [results addObjectsFromArray:items];
                    
                    NSUInteger rangeEnd = NSMaxRange(range);
                    if (rangeEnd < totalCount) {
                        // if total count is 1200, kMaxRangeStep is 1000, we've covered first 1000 items.
                        // now, (1200-1000) == 200, so we shuold cover next 200 items instead of 1000.
                        // There is also different situation
                        // total count is 2222, kMaxRangeStep is 1000, we've covered first 1000 items.
                        // now (2222-1000) == 1222, so we shuold cover next 1000 items
                        NSUInteger length = (totalCount - rangeEnd) > weakSelf.rangeStep ? weakSelf.rangeStep : (totalCount - rangeEnd);
                        weakSelf.offset = rangeEnd;
                        weakSelf.limit = length;
                        
                        // reset operation, so that boxrequest recreates new operation for next batch
                        weakSelf.operation = nil;
                        
                        // if operation got cancelled while preparing for the next request, call cancellation block
                        if (weakSelf.isCancelled) {
                            error = [NSError errorWithDomain:BOXContentSDKErrorDomain code:BOXContentSDKAPIUserCancelledError userInfo:nil];
                            localRefreshBlock(nil, error);
                        } else {
                            [weakSelf performPaginatedRequestWithCached:nil refreshed:recursiveFetch];
                        }
                    } else {
                        NSArray *dedupedResults = [BOXFolderItemsRequest dedupeItemsByBoxID:results];
                        localRefreshBlock(dedupedResults, nil);
                        [weakSelf.requestCache updateCacheForRequest:weakSelf withResponse:[weakSelf JSONDictionaryFromItems:dedupedResults]];
                    }
                }
            }
        };
        
        recursiveFetch = [paginatedRefreshItemFetch copy];
        [self performPaginatedRequestWithCached:nil refreshed:paginatedRefreshItemFetch];
    }
}

- (void)performPaginatedRequestWithCompletion:(BOXItemArrayCompletionBlock)completionBlock
{
    // just call paginated request
    [super performRequestWithCached:nil refreshed:completionBlock];
}

- (void)performPaginatedRequestWithCached:(BOXItemArrayCompletionBlock)cacheBlock refreshed:(BOXItemArrayCompletionBlock)refreshBlock
{
    // just call paginated request
    [super performRequestWithCached:cacheBlock refreshed:refreshBlock];
}


#pragma mark - Private Helpers
- (NSArray *)itemsFromJSONDictionary:(NSDictionary *)JSONDictionary
{
    NSArray *itemsDicts = [JSONDictionary objectForKey:@"entries"];
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:itemsDicts.count];
    
    for (NSDictionary *dict in itemsDicts) {
        [items addObject:[self itemWithJSON:dict]];
    }
    
    return items;
}

- (NSDictionary *)JSONDictionaryFromItems:(NSArray *)items
{
    NSMutableArray *itemsDicts = [NSMutableArray arrayWithCapacity:items.count];
    
    for (BOXItem *item in items) {
        [itemsDicts addObject:item.JSONData];
    }
    
    NSDictionary *JSONDictionary = @{@"entries" : [itemsDicts copy]};
    
    return JSONDictionary;
}


@end