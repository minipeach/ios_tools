//
//  LiteHttpRequest.m
//  testview
//
//  Created by peach on 2016/11/23.
//  Copyright © 2016年 peach. All rights reserved.
//

#import "LiteHttpRequest.h"

static NSString *NetworkRequestErrorDomain = @"LiteHttpRequestErrorDomain";
static CFOptionFlags kNetworkEvents =  kCFStreamEventHasBytesAvailable | kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred;
static NSThread *networkThread = nil;

@interface LiteHttpRequest()

@property (nonatomic, strong) NSMutableData *responseData;
@property (nonatomic, strong) NSURLRequest *urlRequest;
@property (nonatomic, strong) LiteHttpRequestSuccessBlock successBlock;
@property (nonatomic, strong) LiteHttpRequestFailBlock failBlock;
@property (nonatomic, strong) NSInputStream *readStream;
@property (nonatomic, assign) BOOL readStreamIsScheduled;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) NSDate *startTime;
@property (nonatomic, assign) NSTimeInterval timeout;
@property (nonatomic, strong) NSTimer *timer;

@end


@implementation LiteHttpRequest

- (id)initWithURLRequest:(NSURLRequest *)urlRequest{
    if (self = [super init]) {
        self.responseData = [NSMutableData data];
        self.urlRequest = urlRequest;
        self.isRunning = NO;
        if(urlRequest.timeoutInterval > 0){
            self.timeout = urlRequest.timeoutInterval;
        }
        else{
            self.timeout = 30;
        }
    }
    return self;
}

- (void)dealloc {
    NSLog(@"dealloc:%@",self);
    [self destroyReadStream];
    self.successBlock = nil;
    self.failBlock = nil;
    [self stopTimer];
}


- (NSString *)runLoopMode{
    return NSDefaultRunLoopMode;
}

+ (NSThread *)threadForRequest:(LiteHttpRequest *)request{
    if (networkThread == nil) {
        @synchronized(self) {
            if (networkThread == nil) {
                networkThread = [[NSThread alloc] initWithTarget:self selector:@selector(runRequests) object:nil];
                [networkThread start];
            }
        }
    }
    return networkThread;
}

+ (void)runRequests {
    // Should keep the runloop from exiting
    CFRunLoopSourceContext context = {0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL};
    CFRunLoopSourceRef source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    
    BOOL runAlways = YES;
    while (runAlways) {
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0e10, true);
        }
    }
    
    // Should never be called, but anyway
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    CFRelease(source);
}

- (void)sendRequestSuccess:(LiteHttpRequestSuccessBlock)successBlock Fail:(LiteHttpRequestFailBlock)failBlock{
    self.successBlock = successBlock;
    self.failBlock = failBlock;
    
    [self performSelector:@selector(send) onThread:[[self class] threadForRequest:self] withObject:nil waitUntilDone:NO];
    
}

- (void)send{
    
    [self.responseData setLength:0];
    [self cancel];
    
    NSURLRequest *request = self.urlRequest;
    if(!request.URL.absoluteString.length) {
        return;
    }
    
    NSString *urlString = request.URL.absoluteString;
    CFStringRef url = (__bridge CFStringRef)(urlString);
    CFURLRef myURL = CFURLCreateWithString(kCFAllocatorDefault, url, NULL);
    
    NSString *requestMethodString = [request.HTTPMethod isEqualToString:@"POST"] ? @"POST" : @"GET";
    CFStringRef requestMethod = (__bridge CFStringRef)(requestMethodString);
    CFHTTPMessageRef myRequest = CFHTTPMessageCreateRequest(kCFAllocatorDefault, requestMethod, myURL, kCFHTTPVersion1_1);
    
    if ([requestMethodString isEqualToString:@"POST"] && request.HTTPBody.length){
        CFDataRef bodyData = (__bridge CFDataRef)request.HTTPBody;
        CFHTTPMessageSetBody(myRequest, bodyData);
        CFRelease(bodyData);
    }
    
    CFHTTPMessageSetHeaderFieldValue(myRequest, CFSTR("LiteHttpRequest"), CFSTR("1"));
    
    [self setReadStream:(__bridge NSInputStream *)(CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, myRequest))];
    
    CFStreamClientContext ctxt = {0, (__bridge void *)(self), NULL, NULL, NULL};
    CFReadStreamSetClient((CFReadStreamRef)[self readStream], kNetworkEvents, myCFReadStreamClientCallback, &ctxt);
    [[self readStream] scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:[self runLoopMode]];
    [self setReadStreamIsScheduled:YES];
    
    if(!self.timer) {
        [self setTimer:[NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(checkStatus:) userInfo:nil repeats:YES]];
        [[NSRunLoop currentRunLoop] addTimer:self.timer forMode:[self runLoopMode]];
    }
    
    BOOL streamSuccessfullyOpened = NO;
    if (CFReadStreamSetClient((CFReadStreamRef)[self readStream], kNetworkEvents, myCFReadStreamClientCallback, &ctxt)) {
        if (CFReadStreamOpen((CFReadStreamRef)[self readStream])) {
            streamSuccessfullyOpened = YES;
            self.isRunning = YES;
            self.startTime = [NSDate date];
        }
    }
    
    if(!streamSuccessfullyOpened) {
        [self destroyReadStream];
        [self requestFail:[NSError errorWithDomain:NetworkRequestErrorDomain code:LiteHttpRequestErrorStreamOpenFail userInfo:nil]];
    }
    
    CFRelease(url);
    CFRelease(myURL);
    CFRelease(requestMethod);
    CFRelease(myRequest);
    
}

-(void)stopTimer {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)checkStatus:(NSTimer*)timer{
    NSTimeInterval time = [[NSDate date] timeIntervalSinceDate:self.startTime];

    if (self.isRunning && [self readStream] && [self readStreamIsScheduled] && self.timeout > 0 && time > self.timeout) {
        NSLog(@"timeout...");
        [self destroyReadStream];
        [self requestFail:[NSError errorWithDomain:NetworkRequestErrorDomain code:LiteHttpRequestErrorConnectTimeout userInfo:nil]];
    } else if (!self.isRunning) {
        [self stopTimer];
    }
}

- (void)cancel {
    if(self.isRunning){
        [self destroyReadStream];
        self.isRunning = NO;
    }
}

- (void)requestFail:(NSError *)error {
    NSLog(@"requestFail->%@",error);
    self.isRunning = NO;
    if(self.failBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.failBlock(error);
        });
    }
}

- (void)requestSuccess {
    self.isRunning = NO;
    if(self.successBlock){
        dispatch_async(dispatch_get_main_queue(), ^{
            self.successBlock(self.responseData);
        });
    }
}

- (void)unscheduleReadStream {
    if ([self readStream] && [self readStreamIsScheduled]) {
        CFReadStreamSetClient((CFReadStreamRef)[self readStream], kCFStreamEventNone, NULL, NULL);
        [[self readStream] removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:[self runLoopMode]];
        [self setReadStreamIsScheduled:NO];
    }
}

- (void)destroyReadStream {
    if ([self readStream]) {
        [self unscheduleReadStream];
        [[self readStream] removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:[self runLoopMode]];
        [[self readStream] close];
        [self setReadStream:nil];
    }
}

static void myCFReadStreamClientCallback(CFReadStreamRef stream, CFStreamEventType type, void *cientCallbackInfo) {

    LiteHttpRequest *mySelf = (__bridge LiteHttpRequest *)cientCallbackInfo;
    
    if (type == kCFStreamEventEndEncountered) {
        CFHTTPMessageRef response = (CFHTTPMessageRef)CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
        CFIndex statusCode = CFHTTPMessageGetResponseStatusCode(response);
        [mySelf destroyReadStream];
        if(statusCode == 200){
            [mySelf requestSuccess];
        }
        else{
            [mySelf requestFail:[NSError errorWithDomain:NetworkRequestErrorDomain code:LiteHttpRequestErrorHttpStatusInvalid userInfo:nil]];
        }
    } else if (type == kCFStreamEventErrorOccurred) {
        CFStreamError myErr = CFReadStreamGetError(stream);
        NSString *errString = [NSString stringWithFormat:@"CFStreamError,domain:%ld,errorCode:%d", myErr.domain,(int)myErr.error];
        [mySelf destroyReadStream];
        CFReadStreamClose(stream);
        CFRelease(stream);
        stream = NULL;
        [mySelf requestFail:[NSError errorWithDomain:NetworkRequestErrorDomain code:LiteHttpRequestErrorStreamEventErrorOccurred userInfo:@{NSLocalizedDescriptionKey:errString}]];
    } else if (type == kCFStreamEventHasBytesAvailable) {
        UInt8 buffer[1024];
        CFIndex numBytesRead;
        numBytesRead = CFReadStreamRead(stream, buffer, sizeof(buffer));
        [mySelf.responseData appendBytes:buffer length:numBytesRead];
    }
}

@end
