//
//  BOXRepresentationDownloadRequest.m
//  BoxContentSDK
//
//  Created by Clement Rousselle on 3/2/17.
//  Copyright © 2017 Box. All rights reserved.
//

#import "BOXRequest_Private.h"
#import "BOXFileRepresentationDownloadRequest.h"
#import "BOXRepresentation.h"
#import "BOXAPIDataOperation.h"
#import "BOXLog.h"
#import "BOXDispatchHelper.h"
#import "BOXHashHelper.h"
#import "BOXContentSDKErrors.h"

@interface BOXFileRepresentationDownloadRequest ()

@property (nonatomic, readonly, strong) NSString *destinationPath;
@property (nonatomic, readonly, strong) NSOutputStream *outputStream;
@property (nonatomic, readonly, strong) NSString *fileID;
@property (nonatomic, readwrite, strong) BOXRepresentation *representation;
@property (nonatomic, readwrite, copy) NSString *associateId;

@end

@implementation BOXFileRepresentationDownloadRequest

- (instancetype)initWithLocalDestination:(NSString *)destinationPath
                                  fileID:(NSString *)fileID
                          representation:(BOXRepresentation *)representation
{
    if (self = [super init]) {
        _destinationPath = destinationPath;
        _fileID = fileID;
        _representation = representation;
        _ignoreLocalURLRequestCache = NO;
        _sha1Hash = nil;
    }
    return self;
}

- (instancetype)initWithLocalDestination:(NSString *)destinationPath
                                  fileID:(NSString *)fileID
                          representation:(BOXRepresentation *)representation
                             associateId:(NSString *)associateId
{
    self = [self initWithLocalDestination:destinationPath fileID:fileID representation:representation];
    self.associateId = associateId;
    return self;
}

- (instancetype)initWithOutputStream:(NSOutputStream *)outputStream
                              fileID:(NSString *)fileID
                      representation:(BOXRepresentation *)representation
{
    if (self = [super init]) {
        _outputStream = outputStream;
        _fileID = fileID;
        _representation = representation;
    }
    return self;
}

- (void) setIgnoreLocalURLRequestCache:(BOOL)ignoreLocalURLRequestCache
{
    if(ignoreLocalURLRequestCache) {
        [self.operation.APIRequest setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
    } else {
        [self.operation.APIRequest setCachePolicy:NSURLRequestUseProtocolCachePolicy];
    }
}

- (BOXAPIOperation *)createOperation
{
    NSURL *URL = self.representation.contentURL;
    
    BOXAPIDataOperation *dataOperation = [self dataOperationWithURL:URL
                                                         HTTPMethod:BOXAPIHTTPMethodGET
                                              queryStringParameters:nil
                                                     bodyDictionary:nil
                                                       successBlock:nil
                                                       failureBlock:nil
                                                        associateId:self.associateId];
    
    BOXAssert(self.representation != nil, @"A representation must be specified.");
    BOXAssert(self.outputStream != nil || self.destinationPath != nil, @"An output stream or destination file path must be specified.");
    BOXAssert(!(self.outputStream != nil && self.destinationPath != nil), @"You cannot specify both an outputStream and a destination file path.");
    
    if (self.destinationPath != nil && self.associateId != nil) {
        dataOperation.destinationPath = self.destinationPath;
    } else if (self.outputStream != nil) {
        dataOperation.outputStream = self.outputStream;
    } else {
        dataOperation.outputStream = [[NSOutputStream alloc] initToFileAtPath:self.destinationPath append:NO];
    }
    
    [self addSharedLinkHeaderToRequest:dataOperation.APIRequest];
    
    return dataOperation;
}

- (void)performRequestWithProgress:(BOXProgressBlock)progressBlock completion:(BOXErrorBlock)completionBlock
{
    if (completionBlock) {
        BOOL isMainThread = [NSThread isMainThread];
        
        BOXAPIDataOperation *fileOperation = (BOXAPIDataOperation *)self.operation;
        if (progressBlock) {
            fileOperation.progressBlock = ^(long long expectedTotalBytes, unsigned long long bytesReceived) {
                [BOXDispatchHelper callCompletionBlock:^{
                    progressBlock(bytesReceived, expectedTotalBytes);
                } onMainThread:isMainThread];
            };
        }
        
        fileOperation.successBlock = ^(NSString *modelID, long long expectedTotalBytes) {
            [BOXDispatchHelper callCompletionBlock:^{
                completionBlock(nil);
            } onMainThread:isMainThread];

            
            if([self.sha1Hash length]) {
                NSString *calculatedSha1 = [BOXHashHelper sha1HashOfFileAtPath:self.destinationPath];
                if(![calculatedSha1 isEqualToString:self.sha1Hash]) {
                    NSDictionary *userInfo = @{@"local_sha1" : self.sha1Hash,
                                               @"download_sha1" : calculatedSha1,
                                               @"file_id" : self.fileID};
                    // Data integrity check fails - Notify the cache and/or application that cache needs to be invalidated
                    // This is asynchronous notification because of performance implications when dealing with large files or large download sets
                    [[NSNotificationCenter defaultCenter] postNotificationName:BOXFileDownloadCorruptedNotification object:self userInfo:userInfo];
                }
            }
        };
        fileOperation.failureBlock = ^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error) {
            [BOXDispatchHelper callCompletionBlock:^{
                completionBlock(error);
            } onMainThread:isMainThread];
        };
        [self performRequest];
    }
}

#pragma mark - Superclass overidden methods

- (NSString *)itemIDForSharedLink
{
    return self.fileID;
}

- (BOXAPIItemType *)itemTypeForSharedLink
{
    return BOXAPIItemTypeFile;
}

- (void)cancelWithIntentionToResume
{
    BOXAPIDataOperation *dataOperation = (BOXAPIDataOperation *)self.operation;
    dataOperation.allowResume = YES;
    [self cancel];
}
@end

