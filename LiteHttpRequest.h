//
//  LiteHttpRequest.h
//  testview
//
//  Created by peach on 2016/11/23.
//  Copyright © 2016年 peach. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void (^LiteHttpRequestSuccessBlock)(NSData *data);
typedef void (^LiteHttpRequestFailBlock)(NSError *error);

typedef NS_ENUM (NSUInteger, LiteHttpRequestErrorType) {
    LiteHttpRequestErrorStreamOpenFail,
    LiteHttpRequestErrorStreamEventErrorOccurred,
    LiteHttpRequestErrorHttpStatusInvalid,
    LiteHttpRequestErrorConnectTimeout,
    LiteHttpRequestErrorUnknown
};

@interface LiteHttpRequest : NSObject

- (id)initWithURLRequest:(NSURLRequest *)urlRequest;

- (void)sendRequestSuccess:(LiteHttpRequestSuccessBlock)successBlock Fail:(LiteHttpRequestFailBlock)failBlock;

- (void)cancel;

@end
