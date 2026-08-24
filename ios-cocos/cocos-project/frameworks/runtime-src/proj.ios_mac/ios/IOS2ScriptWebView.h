#import <Foundation/Foundation.h>

@interface IOS2ScriptWebView : NSObject
+ (void)showScriptsJSON:(NSString *)json;
+ (void)hide;
+ (void)sendResponseJSON:(NSString *)json;
+ (void)sendEventJSON:(NSString *)json;
+ (void)syncRoleJSON:(NSString *)json;
@end
