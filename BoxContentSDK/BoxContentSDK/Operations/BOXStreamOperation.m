//
//  BOXStreamOperation.m
//  BoxContentSDK
//
//  Created on 8/5/16.
//  Copyright (c) 2016 Box. All rights reserved.
//

#import "BOXStreamOperation.h"
#import "BOXContentSDKErrors.h"
#import "BOXLog.h"
#import "BOXAPIOperation_Private.h"
#import "BOXAbstractSession.h"

#define MAX_REENQUE_DELAY 60
#define REENQUE_BASE_DELAY 0.2

@interface BOXStreamOperation () <BOXURLSessionDownloadTaskDelegate>

// Buffer data received. Write to the output stream from this data object when space becomes available.
@property (nonatomic, readwrite, strong) NSMutableData *receivedDataBuffer;

@property (nonatomic, readwrite, assign) unsigned long long bytesReceived;

- (void)writeDataToOutputStream;

- (long long)contentLength;

- (void)abortWithError:(NSError *)error;

@end

@implementation BOXStreamOperation

@synthesize successBlock = _successBlock;
@synthesize failureBlock = _failureBlock;
@synthesize progressBlock = _progressBlock;
@synthesize fileID = _fileID;

@synthesize receivedDataBuffer = _receivedDataBuffer;
@synthesize bytesReceived = _bytesReceived;

- (id)initWithURL:(NSURL *)URL HTTPMethod:(NSString *)HTTPMethod body:(NSDictionary *)body queryParams:(NSDictionary *)queryParams session:(BOXAbstractSession *)session
{
    self = [super initWithURL:URL HTTPMethod:HTTPMethod body:body queryParams:queryParams session:session];
    
    if (self != nil)
    {
        _receivedDataBuffer = [NSMutableData dataWithCapacity:0];
        _bytesReceived = 0;

        // Initialize the responseData object to mutable data
        self.responseData = [NSMutableData data];
    }
    
    return self;
}

// BOXAPIDataOperation should only ever be GET requests so there should not be a body
- (NSData *)encodeBody:(NSDictionary *)bodyDictionary
{
    return nil;
}

- (NSURLSessionTask *)createSessionTask
{
    NSURLSessionTask *sessionTask = [self.session.urlSessionManager createNonBackgroundDownloadTaskWithRequest:self.APIRequest
                                                                                                  taskDelegate:self];
    return sessionTask;
}

- (void)processResponseData:(NSData *)data
{
    // Empty data assumes that all data received from the network is buffered. This operation
    // streams all received data to its output stream, so do nothing.
    if (data.length == 0) {
        return;
    }
    
    NSError *JSONError = nil;
    id decodedJSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:&JSONError];
    
    if (JSONError != nil)
    {
        NSDictionary *userInfo = @{
                                   NSUnderlyingErrorKey : JSONError,
                                   };
        self.error = [[NSError alloc] initWithDomain:BOXContentSDKErrorDomain code:BOXContentSDKJSONErrorDecodeFailed userInfo:userInfo];
    }
    else if ([decodedJSON isKindOfClass:[NSDictionary class]] == NO)
    {
        NSDictionary *userInfo = @{
                                   BOXJSONErrorResponseKey : decodedJSON,
                                   };
        self.error = [[NSError alloc] initWithDomain:BOXContentSDKErrorDomain code:BOXContentSDKJSONErrorUnexpectedType userInfo:userInfo];
    }
    else if (self.error != nil)
    {
        // if this operation has already encountered an error, include the decoded JSON in the error info
        NSDictionary *userInfo = @{
                                   BOXJSONErrorResponseKey : decodedJSON,
                                   };
        self.error = [[NSError alloc] initWithDomain:self.error.domain code:self.error.code userInfo:userInfo];
    }
}

#pragma mark - Callback methods

- (void)performCompletionCallback
{
    BOOL shouldClearCompletionBlocks = NO;
    
    if (self.error == nil) {
        if (self.successBlock) {
            self.successBlock(self.fileID, [self contentLength]);
        }
        shouldClearCompletionBlocks = YES;
    } else {
        if ([self.error.domain isEqualToString:BOXContentSDKErrorDomain] &&
            (self.error.code == BOXContentSDKAuthErrorAccessTokenExpiredOperationWillBeClonedAndReenqueued ||
             self.error.code == BOXContentSDKAPIErrorAccepted)) {
                // Do not fire failre block if request is going to be re-enqueued due to an expired token, or a 202 response.
            } else {
                if (self.failureBlock) {
                    self.failureBlock(self.APIRequest, self.HTTPResponse, self.error);
                }
                shouldClearCompletionBlocks = YES;
            }
    }
    
    if (shouldClearCompletionBlocks) {
        self.successBlock = nil;
        self.failureBlock = nil;
        self.progressBlock = nil;
    }
}

#pragma mark - Output Stream methods

- (long long)contentLength
{
    NSHTTPURLResponse *response = self.HTTPResponse;
    NSString *contentRange = [response.allHeaderFields objectForKey:@"Content-Range"];
    NSString *contentLength = [[contentRange componentsSeparatedByString:@"/"] objectAtIndex:1];
    return [contentLength longLongValue];
//    return [self.HTTPResponse expectedContentLength];
}

- (void)abortWithError:(NSError *)error
{
    [self.sessionTask cancel];
    [self sessionTask:self.sessionTask didFinishWithResponse:self.sessionTask.response error:error];
}

#pragma mark - BOXURLSessionTaskDelegate
//NOTE: Currently not implementing BOXURLSessionDownloadTaskDelegate methods on purpose.
// For the stream, only the direct data and response handling is required.

- (void)processIntermediateResponse:(NSURLResponse *)response
{
    [super processIntermediateResponse:response];
    
    if (self.error != nil &&
        self.error.code == BOXContentSDKAPIErrorAccepted) {
        // If we get a 202, it means the content is not yet ready on Box's servers.
        // Re-enqueue after a certain amount of time.
        double delay = [self reenqueDelay];
        [self performSelector:@selector(reenqueOperationDueTo202Response) withObject:self afterDelay:delay];
    }
}

// Override this delegate method from the default BOXAPIOperation implementation
// (may not even be implemented in the first place as it is optional).
// By default, BOXAPIOperation buffers all received data from the connection in
// self.responseData. This operation differs in that it should write its received
// data immediately to its output stream. Failure to do so will cause downloads to
// be buffered entirely in memory.
- (void)processIntermediateData:(NSData *)data
{
    if (self.HTTPResponse.statusCode < 200 || self.HTTPResponse.statusCode >= 300) {
        // If we received an error, don't write the response data to the output stream
        [super processIntermediateData:data];
    } else {
        // Buffer received data in an NSMutableData ivar because the output stream
        // may not have space available for writing
        [self.receivedDataBuffer appendData:data];
        self.bytesReceived += data.length;
        BOXLog(@"Bytes received: %lu", (unsigned long)data.length);
        if (self.progressBlock && data.length > 0) {
            self.progressBlock(data, self.contentLength);
        }
    }
}

#pragma mark - Reenque helpers

- (void)reenqueOperationDueTo202Response
{
    BOXStreamOperation *operationCopy = [self copy];
    operationCopy.timesReenqueued++;
    [self.session.queueManager enqueueOperation:operationCopy];
    [self finish];
}

- (double)reenqueDelay
{
    // Delay grows each time the request is re-enqueued.
    double delay = MIN(pow((1 + REENQUE_BASE_DELAY), self.timesReenqueued) - 1, MAX_REENQUE_DELAY);
    return delay;
}

- (id)copyWithZone:(NSZone *)zone
{
    NSURL *URLCopy = [self.baseRequestURL copy];
    NSDictionary *bodyCopy = [self.body copy];
    NSDictionary *queryStringParametersCopy = [self.queryStringParameters copy];
    
    BOXStreamOperation *operationCopy = [[BOXStreamOperation allocWithZone:zone] initWithURL:URLCopy
                                                                                    HTTPMethod:self.HTTPMethod
                                                                                          body:bodyCopy
                                                                                   queryParams:queryStringParametersCopy
                                                                                       session:self.session];
    operationCopy.timesReenqueued = self.timesReenqueued;
    operationCopy.successBlock = [self.successBlock copy];
    operationCopy.failureBlock = [self.failureBlock copy];
    operationCopy.progressBlock = [self.progressBlock copy];
    operationCopy.sessionTaskReplacedBlock = self.sessionTaskReplacedBlock;
    
    return operationCopy;
}

- (BOOL)canBeReenqueued
{
    return YES;
}

- (BOOL)shouldUseSessionTask
{
    return YES;
}

@end
