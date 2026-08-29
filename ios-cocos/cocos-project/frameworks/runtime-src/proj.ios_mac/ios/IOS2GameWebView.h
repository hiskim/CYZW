#import <Foundation/Foundation.h>

@interface IOS2GameWebView : NSObject
+ (void)showInstances:(NSArray<NSDictionary *> *)instances scriptsJSON:(NSString *)scriptsJSON manifestJSON:(NSString *)manifestJSON;
+ (void)appendInstanceWithAccount:(NSString *)account
                         accountID:(NSString *)accountID
                      authResponse:(NSString *)authResponse;
+ (void)showGroupBinPicker;
+ (void)hide;
+ (void)closeAll;
+ (void)shutdownAndCloseAll;
+ (void)releaseUnusedAssetsForAllInstances;
+ (NSUInteger)instanceCount;
+ (NSString *)startupMode;
+ (void)setStartupMode:(NSString *)mode;
+ (NSString *)layoutMode;
+ (void)setLayoutMode:(NSString *)mode;
+ (void)sendHSDKMessage:(NSString *)action
                  extra:(NSDictionary *)extra
                errCode:(NSInteger)errCode
             toInstance:(NSString *)instanceID;
+ (NSString *)accountIDForInstance:(NSString *)instanceID;
@end
