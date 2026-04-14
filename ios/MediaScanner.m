#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE (MediaScanner, RCTEventEmitter)

RCT_EXTERN_METHOD(getVideos : (RCTPromiseResolveBlock)
                      resolve rejecter : (RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(pickVideoFolder : (RCTPromiseResolveBlock)
                      resolve rejecter : (RCTPromiseRejectBlock)reject)

@end