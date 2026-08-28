#import <Foundation/Foundation.h>

@interface IOS2GameWebView : NSObject
+ (void)showInstances:(NSArray<NSDictionary *> *)instances scriptsJSON:(NSString *)scriptsJSON manifestJSON:(NSString *)manifestJSON;
+ (void)hide;
+ (void)closeAll;
+ (NSUInteger)instanceCount;
+ (void)sendHSDKMessage:(NSString *)action
                  extra:(NSDictionary *)extra
                errCode:(NSInteger)errCode
             toInstance:(NSString *)instanceID;
@end
