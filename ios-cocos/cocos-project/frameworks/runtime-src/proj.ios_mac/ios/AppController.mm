/****************************************************************************
 Copyright (c) 2010-2013 cocos2d-x.org
 Copyright (c) 2013-2016 Chukong Technologies Inc.
 Copyright (c) 2017-2018 Xiamen Yaji Software Co., Ltd.
 
 http://www.cocos2d-x.org
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 ****************************************************************************/

#import "AppController.h"
#import "cocos2d.h"
#import "AppDelegate.h"
#import "RootViewController.h"
#import "SDKWrapper.h"
#import "IOS2ScriptWebView.h"
#import "IOS2GameWebView.h"
#import "platform/ios/CCEAGLView-ios.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <OpenGLES/ES2/gl.h>
#import <TargetConditionals.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach.h>
#include <string.h>

#include "cocos/scripting/js-bindings/jswrapper/SeApi.h"
#include "platform/CCApplication.h"

static NSObject *s_ios2PickerDelegate = nil;
static BOOL s_ios2LoginBusy = NO;
static BOOL s_ios2AuthReady = NO;
static BOOL s_ios2SDKLoginPending = NO;
static NSString *s_ios2SDKLoginAction = nil;
static NSString *s_ios2SDKLoginInstanceID = nil;
static NSString *s_ios2HSDKImageInstanceID = nil;
// Set while synchronously dispatching a request that originated in a
// particular WKWebView. IOS2CallHSDKMessage uses it to route the response.
static NSString *s_ios2HSDKTargetInstanceID = nil;
static NSString *s_ios2AccountID = nil;
static NSString *s_ios2AuthResponseBase64 = nil;

// These values are the production identity embedded in the reference iOS
// client.  Game scripts use the HSDK init response to decide which in-game
// features are available, so a placeholder "dev" identity hides real UI.
static NSString * const kIOS2GameID = @"xyzw_mix";
static NSString * const kIOS2Channel = @"AppStore";
static NSString * const kIOS2GameVersion = @"0.33.0-ios";
static NSString * const kIOS2HSDKVersion = @"1.4.0";
static NSString * const kIOS2FrameRateDefaultsKey = @"ios2.preferredFrameRate";
static NSString * const kIOS2ShowFPSDefaultsKey = @"ios2.showFPS";
static NSString * const kIOS2HSDKVerboseDebugDefaultsKey = @"ios2.hsdkVerboseDebug";
static NSString * const kIOS2RuntimeBackendDefaultsKey = @"ios2.runtimeBackend";
static NSString * const kIOS2RenderQualitySingleDefaultsKey = @"ios2.renderQuality.single";
static NSString * const kIOS2RenderQualityMultiDefaultsKey = @"ios2.renderQuality.multi";
static uint8_t s_ios2SingleRenderTextureFactor = 1;

static NSInteger IOS2PreferredFrameRate(void)
{
    NSInteger frameRate = [[NSUserDefaults standardUserDefaults] integerForKey:kIOS2FrameRateDefaultsKey];
    switch (frameRate) {
        case 0:
        case 15:
        case 24:
        case 30:
        case 45:
        case 60:
            return frameRate;
        default:
            return 60;
    }
}

static void IOS2ApplyPerformancePreferences(void)
{
    cocos2d::Application *application = cocos2d::Application::getInstance();
    if (!application) return;

    NSInteger frameRate = IOS2PreferredFrameRate();
    NSLog(@"[ios2] restoring performance preferences: %ld FPS", (long)frameRate);
    application->setPreferredFramesPerSecond((int)frameRate);
    application->setDisplayStats([[NSUserDefaults standardUserDefaults] boolForKey:kIOS2ShowFPSDefaultsKey]);
}

static BOOL IOS2HSDKVerboseDebugEnabled(void)
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kIOS2HSDKVerboseDebugDefaultsKey];
}

static NSString *IOS2RenderQualityValue(NSString *key, NSString *fallback)
{
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    return ([value isEqualToString:@"low"] || [value isEqualToString:@"medium"] ||
            [value isEqualToString:@"high"]) ? value : fallback;
}

static double IOS2ResidentMemoryMB(void)
{
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count);
    if (result != KERN_SUCCESS) return -1.0;
    return (double)info.resident_size / 1024.0 / 1024.0;
}

static NSString *IOS2AccountIDForBinData(NSData *binData)
{
    if (!binData.length) return nil;

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(binData.bytes, (CC_LONG)binData.length, digest);
    NSMutableString *identifier = [NSMutableString stringWithString:@"ios2-"];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [identifier appendFormat:@"%02x", digest[index]];
    }
    return identifier;
}

static void IOS2SetAccountIDForBinData(NSData *binData)
{
    NSString *accountID = IOS2AccountIDForBinData(binData);
    [s_ios2AccountID release];
    s_ios2AccountID = [accountID copy];
}

/*
 * NSURLSession may negotiate HTTP/3 in the simulator.  The game endpoint
 * currently leaves that response open behind the simulator proxy, so use the
 * older NSURLConnection stack for the small control-plane requests instead.
 */
typedef void (^IOS2HTTPCompletion)(NSData *data, NSHTTPURLResponse *response, NSError *error);

@interface IOS2HTTPConnection : NSObject <NSURLConnectionDataDelegate>
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSMutableData *bodyData;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@property (nonatomic, strong) IOS2HTTPCompletion completion;
@property (nonatomic, assign) BOOL finished;
- (instancetype)initWithRequest:(NSURLRequest *)request completion:(IOS2HTTPCompletion)completion;
- (void)start;
@end

@implementation IOS2HTTPConnection

- (instancetype)initWithRequest:(NSURLRequest *)request completion:(IOS2HTTPCompletion)completion
{
    self = [super init];
    if (self) {
        _bodyData = [[NSMutableData alloc] initWithLength:0];
        _completion = [completion copy];
        _connection = [[NSURLConnection alloc] initWithRequest:request
                                                       delegate:self
                                               startImmediately:NO];
    }
    return self;
}

- (void)start
{
    [self.connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [self.connection start];
}

- (void)finishWithResponse:(NSHTTPURLResponse *)response error:(NSError *)error
{
    if (self.finished) return;
    self.finished = YES;
    IOS2HTTPCompletion completion = self.completion;
    if (completion) completion([self.bodyData copy], response, error);
    self.completion = nil;
    self.connection = nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    (void)connection;
    self.response = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    [self.bodyData setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    (void)connection;
    [self.bodyData appendData:data];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    (void)connection;
    [self finishWithResponse:nil error:error];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    (void)connection;
    [self finishWithResponse:self.response error:nil];
}

@end

static void IOS2StartPOST(NSURL *url,
                          NSData *body,
                          NSDictionary<NSString *, NSString *> *headers,
                          IOS2HTTPCompletion completion)
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                               cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                           timeoutInterval:30.0];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body ?: [NSData data];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        (void)stop;
        [request setValue:value forHTTPHeaderField:key];
    }];

    IOS2HTTPConnection *connection = [[IOS2HTTPConnection alloc] initWithRequest:request completion:completion];
    [connection start];
}

static UIViewController *IOS2TopViewController(void)
{
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window) break;
    }
    if (!window) window = UIApplication.sharedApplication.keyWindow;

    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

static void IOS2CallJavaScript(NSString *functionName, NSString *argument)
{
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:argument ?: @""
                                                          options:NSJSONWritingFragmentsAllowed
                                                            error:nil];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:
        @"if (typeof window.%@ === 'function') window.%@(%@);", functionName, functionName, json ?: @"null"];
    dispatch_async(dispatch_get_main_queue(), ^{
        se::ScriptEngine *engine = se::ScriptEngine::getInstance();
        if (engine) engine->evalString(script.UTF8String);
    });
}

static void IOS2CallHSDKMessage(NSString *action, NSDictionary *extra, NSInteger errCode)
{
    NSDictionary *message = @{
        @"action": action ?: @"",
        @"meta": @{ @"errCode": @(errCode) },
        @"extra": extra ?: @{}
    };
    NSData *messageData = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    NSString *messageJSON = [[NSString alloc] initWithData:messageData encoding:NSUTF8StringEncoding];
    NSData *argumentData = [NSJSONSerialization dataWithJSONObject:messageJSON ?: @"{}"
                                                              options:NSJSONWritingFragmentsAllowed
                                                                error:nil];
    NSString *argumentJSON = [[NSString alloc] initWithData:argumentData encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:
        @"if (window.HSDK && typeof window.HSDK.onMessage === 'function') window.HSDK.onMessage('sdk', %@);",
        argumentJSON ?: @"null"];
    NSString *targetInstanceID = [s_ios2HSDKTargetInstanceID copy];
    if (targetInstanceID.length) {
        [IOS2GameWebView sendHSDKMessage:action extra:extra errCode:errCode toInstance:targetInstanceID];
        [targetInstanceID release];
        return;
    }
    [targetInstanceID release];
    dispatch_async(dispatch_get_main_queue(), ^{
        se::ScriptEngine *engine = se::ScriptEngine::getInstance();
        if (engine) engine->evalString(script.UTF8String);
    });
}

static void IOS2PublishSDKUser(void)
{
    if (!s_ios2AccountID.length) return;
    // HSDK registers this as a listener rather than a request. The original
    // native SDK publishes it after login; without it, the game reaches the
    // current role through authuser but has no account state for its server
    // selector.
    NSLog(@"[ios2] publishing authenticated SDK user");
    NSString *previousTarget = s_ios2HSDKTargetInstanceID;
    if (!previousTarget.length) s_ios2HSDKTargetInstanceID = s_ios2SDKLoginInstanceID;
    IOS2CallHSDKMessage(@"sdk-get-userId", @{ @"userId": s_ios2AccountID,
                                                @"uniqueId": s_ios2AccountID }, 0);
    s_ios2HSDKTargetInstanceID = previousTarget;
}

static void IOS2PublishSDKUserForAccountID(NSString *accountID, NSString *instanceID)
{
    if (!accountID.length) return;
    NSLog(@"[ios2] publishing authenticated SDK user");
    NSString *previousTarget = s_ios2HSDKTargetInstanceID;
    if (!previousTarget.length) s_ios2HSDKTargetInstanceID = instanceID;
    IOS2CallHSDKMessage(@"sdk-get-userId", @{ @"userId": accountID,
                                                @"uniqueId": accountID }, 0);
    s_ios2HSDKTargetInstanceID = previousTarget;
}

static void IOS2FinishSDKLogin(NSInteger errCode)
{
    if (!s_ios2SDKLoginPending) return;
    s_ios2SDKLoginPending = NO;
    NSString *action = [s_ios2SDKLoginAction copy];
    if (!action) action = [@"user_login_show_dialog" copy];
    [s_ios2SDKLoginAction release];
    s_ios2SDKLoginAction = nil;
    NSString *loginInstanceID = [s_ios2SDKLoginInstanceID copy];
    [s_ios2SDKLoginInstanceID release];
    s_ios2SDKLoginInstanceID = nil;
    NSString *previousTarget = s_ios2HSDKTargetInstanceID;
    s_ios2HSDKTargetInstanceID = loginInstanceID;
    IOS2CallHSDKMessage(action, @{}, errCode);
    s_ios2HSDKTargetInstanceID = previousTarget;
    [loginInstanceID release];
    [action release];
}

static UIImage *IOS2AvatarImage(UIImage *source, CGFloat sideLength)
{
    CGSize sourceSize = source.size;
    if (sourceSize.width <= 0 || sourceSize.height <= 0 || sideLength <= 0) return nil;

    CGFloat scale = MAX(sideLength / sourceSize.width, sideLength / sourceSize.height);
    CGSize drawSize = CGSizeMake(sourceSize.width * scale, sourceSize.height * scale);
    CGRect drawRect = CGRectMake((sideLength - drawSize.width) / 2.0,
                                 (sideLength - drawSize.height) / 2.0,
                                 drawSize.width,
                                 drawSize.height);
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(sideLength, sideLength), YES, 1.0);
    [[UIColor whiteColor] setFill];
    UIRectFill(CGRectMake(0, 0, sideLength, sideLength));
    [source drawInRect:drawRect];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

static NSArray<NSString *> *IOS2SaveAvatarImages(UIImage *source)
{
    UIImage *largeImage = IOS2AvatarImage(source, 512.0);
    UIImage *smallImage = IOS2AvatarImage(source, 98.0);
    NSData *largeData = largeImage ? UIImageJPEGRepresentation(largeImage, 0.9) : nil;
    NSData *smallData = smallImage ? UIImageJPEGRepresentation(smallImage, 0.9) : nil;
    if (!largeData.length || !smallData.length) return nil;

    NSString *token = NSUUID.UUID.UUIDString;
    NSString *directory = NSTemporaryDirectory();
    NSString *largePath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ios2-avatar-%@-512.jpg", token]];
    NSString *smallPath = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ios2-avatar-%@-98.jpg", token]];
    if (![largeData writeToFile:largePath options:NSDataWritingAtomic error:nil] ||
        ![smallData writeToFile:smallPath options:NSDataWritingAtomic error:nil]) return nil;
    return @[largePath, smallPath];
}

@interface IOS2ImagePickerDelegate : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@end

@implementation IOS2ImagePickerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
 didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info
{
    UIImage *image = [info[UIImagePickerControllerOriginalImage] isKindOfClass:[UIImage class]]
        ? info[UIImagePickerControllerOriginalImage] : nil;
    NSArray<NSString *> *images = image ? IOS2SaveAvatarImages(image) : nil;
    [picker dismissViewControllerAnimated:YES completion:^{
        s_ios2PickerDelegate = nil;
        if (images.count == 2) {
            NSLog(@"[ios2] avatar image selected");
            NSString *previousTarget = s_ios2HSDKTargetInstanceID;
            s_ios2HSDKTargetInstanceID = s_ios2HSDKImageInstanceID;
            IOS2CallHSDKMessage(@"sdk-read-image", @{ @"images": images }, 0);
            s_ios2HSDKTargetInstanceID = previousTarget;
        } else {
            NSLog(@"[ios2] avatar image processing failed");
            NSString *previousTarget = s_ios2HSDKTargetInstanceID;
            s_ios2HSDKTargetInstanceID = s_ios2HSDKImageInstanceID;
            IOS2CallHSDKMessage(@"sdk-read-image", @{}, 1);
            s_ios2HSDKTargetInstanceID = previousTarget;
        }
        [s_ios2HSDKImageInstanceID release];
        s_ios2HSDKImageInstanceID = nil;
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
    [picker dismissViewControllerAnimated:YES completion:^{
        s_ios2PickerDelegate = nil;
        NSString *previousTarget = s_ios2HSDKTargetInstanceID;
        s_ios2HSDKTargetInstanceID = s_ios2HSDKImageInstanceID;
        IOS2CallHSDKMessage(@"sdk-read-image", @{}, 1);
        s_ios2HSDKTargetInstanceID = previousTarget;
        [s_ios2HSDKImageInstanceID release];
        s_ios2HSDKImageInstanceID = nil;
    }];
}

@end

static NSURL *IOS2DocumentsDirectory(void)
{
    return [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                   inDomains:NSUserDomainMask].firstObject;
}

static NSURL *IOS2BinDirectory(void)
{
    NSURL *directory = [IOS2DocumentsDirectory() URLByAppendingPathComponent:@"ios2/bins" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return directory;
}

static NSURL *IOS2ScriptDirectory(void)
{
    NSURL *directory = [IOS2DocumentsDirectory() URLByAppendingPathComponent:@"ios2/scripts" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return directory;
}

static NSString *IOS2SafeManagedFileName(NSString *name, NSString *extension, NSString *fallbackName)
{
    // Keep Unicode file names intact. The previous ASCII allowlist turned every
    // Chinese character into an underscore before the file was stored.
    NSString *candidate = name.lastPathComponent ?: fallbackName;
    if (![[candidate.pathExtension lowercaseString] isEqualToString:extension]) {
        candidate = [candidate stringByAppendingPathExtension:extension];
    }

    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"/\\\\"];
    NSMutableString *safe = [NSMutableString stringWithCapacity:candidate.length];
    for (NSUInteger index = 0; index < candidate.length; index++) {
        unichar character = [candidate characterAtIndex:index];
        if ([unsafe characterIsMember:character] || [[NSCharacterSet controlCharacterSet] characterIsMember:character]) {
            [safe appendString:@"_"];
        } else {
            [safe appendString:[NSString stringWithCharacters:&character length:1]];
        }
    }

    NSString *result = [safe precomposedStringWithCanonicalMapping];
    return (result.length && ![result isEqualToString:@"."] && ![result isEqualToString:@".."]) ? result : fallbackName;
}

static NSString *IOS2SafeBinName(NSString *name)
{
    return IOS2SafeManagedFileName(name, @"bin", @"account.bin");
}

static NSString *IOS2StoreBin(NSData *data, NSString *preferredName)
{
    if (!data.length) return nil;
    NSURL *directory = IOS2BinDirectory();
    NSString *name = IOS2SafeBinName(preferredName);
    NSURL *url = [directory URLByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        NSString *base = [name stringByDeletingPathExtension];
        NSString *extension = name.pathExtension.length ? name.pathExtension : @"bin";
        name = [NSString stringWithFormat:@"%@-%@.%@", base,
                [[NSUUID UUID].UUIDString substringToIndex:8], extension];
        url = [directory URLByAppendingPathComponent:name];
    }
    return [data writeToURL:url atomically:YES] ? name : nil;
}

static NSString *IOS2SafeScriptName(NSString *name)
{
    return IOS2SafeManagedFileName(name, @"js", @"script.js");
}

static NSString *IOS2StoreScript(NSData *data, NSString *preferredName)
{
    if (!data.length) return nil;
    NSURL *directory = IOS2ScriptDirectory();
    NSString *name = IOS2SafeScriptName(preferredName);
    NSURL *url = [directory URLByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        NSString *base = [name stringByDeletingPathExtension];
        name = [NSString stringWithFormat:@"%@-%@.js", base,
                [[NSUUID UUID].UUIDString substringToIndex:8]];
        url = [directory URLByAppendingPathComponent:name];
    }
    return [data writeToURL:url atomically:YES] ? name : nil;
}

static BOOL IOS2DeleteBin(NSString *name, NSError **error)
{
    NSString *safeName = IOS2SafeBinName(name);
    NSURL *root = [IOS2DocumentsDirectory() URLByAppendingPathComponent:@"ios2" isDirectory:YES];
    NSURL *url = [safeName isEqualToString:@"last.bin"] ?
        [root URLByAppendingPathComponent:@"last.bin"] :
        [IOS2BinDirectory() URLByAppendingPathComponent:safeName];
    return [[NSFileManager defaultManager] removeItemAtURL:url error:error];
}

static BOOL IOS2DeleteScript(NSString *name, NSError **error)
{
    NSString *safeName = IOS2SafeScriptName(name);
    NSURL *url = [IOS2ScriptDirectory() URLByAppendingPathComponent:safeName];
    return [[NSFileManager defaultManager] removeItemAtURL:url error:error];
}

static NSArray<NSDictionary *> *IOS2BinFileRecords(BOOL includeLast)
{
    NSURL *documents = IOS2DocumentsDirectory();
    NSURL *root = [documents URLByAppendingPathComponent:@"ios2" isDirectory:YES];
    NSURL *directory = IOS2BinDirectory();
    NSMutableArray *records = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *locations = includeLast ? @[[root URLByAppendingPathComponent:@"last.bin"], directory] : @[directory];
    for (NSURL *location in locations) {
        BOOL isDirectory = NO;
        BOOL exists = [fileManager fileExistsAtPath:location.path isDirectory:&isDirectory];
        NSArray *urls = isDirectory ?
            [fileManager contentsOfDirectoryAtURL:location includingPropertiesForKeys:
                @[NSURLFileSizeKey, NSURLContentModificationDateKey]
                options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] :
            (exists ? @[location] : @[]);
        for (NSURL *url in urls) {
            if (![[url.pathExtension lowercaseString] isEqualToString:@"bin"]) continue;
            NSNumber *size = nil;
            NSDate *modified = nil;
            [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
            [records addObject:@{ @"name": url.lastPathComponent ?: @"account.bin",
                                  @"size": size ?: @0,
                                  @"modified": @((long long)[modified timeIntervalSince1970]),
                                  @"last": @([url.lastPathComponent isEqualToString:@"last.bin"]) }];
        }
    }
    [records sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        BOOL leftLast = [left[@"last"] boolValue];
        BOOL rightLast = [right[@"last"] boolValue];
        if (leftLast != rightLast) return leftLast ? NSOrderedAscending : NSOrderedDescending;
        long long leftTime = [left[@"modified"] longLongValue];
        long long rightTime = [right[@"modified"] longLongValue];
        if (leftTime != rightTime) return leftTime > rightTime ? NSOrderedAscending : NSOrderedDescending;
        NSString *leftName = [left[@"name"] isKindOfClass:[NSString class]] ? left[@"name"] : @"";
        NSString *rightName = [right[@"name"] isKindOfClass:[NSString class]] ? right[@"name"] : @"";
        return [leftName localizedCaseInsensitiveCompare:rightName];
    }];
    return records;
}

static void IOS2ListBinFiles(void)
{
    NSArray *records = IOS2BinFileRecords(YES);
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:records options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    IOS2CallJavaScript(@"__ios2BinFilesReady", json ?: @"[]");
}

static void IOS2ListScriptFiles(void)
{
    NSURL *directory = IOS2ScriptDirectory();
    NSMutableArray *records = [NSMutableArray array];
    NSArray *urls = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory
                                  includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLContentModificationDateKey]
                                                                     options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    for (NSURL *url in urls) {
        if (![[url.pathExtension lowercaseString] isEqualToString:@"js"]) continue;
        NSNumber *size = nil;
        NSDate *modified = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        [records addObject:@{ @"name": url.lastPathComponent ?: @"script.js",
                              @"size": size ?: @0,
                              @"modified": @((long long)[modified timeIntervalSince1970]) }];
    }
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:records options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    IOS2CallJavaScript(@"__ios2ScriptFilesReady", json ?: @"[]");
}

static void IOS2Authenticate(NSData *binData)
{
    [s_ios2AuthResponseBase64 release];
    s_ios2AuthResponseBase64 = nil;
    NSURL *url = [NSURL URLWithString:@"https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1"];
    if (!url) {
        s_ios2LoginBusy = NO;
        s_ios2AuthReady = NO;
        IOS2FinishSDKLogin(1);
        IOS2CallJavaScript(@"__ios2BinLoginFailed", @"invalid auth URL");
        return;
    }

    IOS2StartPOST(url, binData,
                  @{ @"Content-Type": @"application/octet-stream",
                     @"O4e-Encoding": @"lx",
                     @"Connection": @"close" },
                  ^(NSData *data, NSHTTPURLResponse *http, NSError *error) {
        s_ios2LoginBusy = NO;
        NSLog(@"[ios2] authuser finished status=%ld bytes=%lu error=%@",
              (long)http.statusCode, (unsigned long)data.length, error.localizedDescription ?: @"<none>");
        if (error || !http || http.statusCode < 200 || http.statusCode >= 300 || data.length <= 4) {
            s_ios2AuthReady = NO;
            IOS2FinishSDKLogin(1);
            NSString *message = error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
            IOS2CallJavaScript(@"__ios2BinLoginFailed", message);
            return;
        }
        s_ios2AuthReady = YES;
        NSString *base64 = [data base64EncodedStringWithOptions:0];
        s_ios2AuthResponseBase64 = [base64 copy];
        IOS2CallJavaScript(@"__ios2BinLoginReady", base64);
        IOS2PublishSDKUser();
        IOS2FinishSDKLogin(0);
    });
}

static void IOS2AuthenticateAdditionalBin(NSData *binData, NSString *name)
{
    NSURL *url = [NSURL URLWithString:@"https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1"];
    IOS2StartPOST(url, binData,
                  @{ @"Content-Type": @"application/octet-stream",
                     @"O4e-Encoding": @"lx",
                     @"Connection": @"close" },
                  ^(NSData *data, NSHTTPURLResponse *http, NSError *error) {
        s_ios2LoginBusy = NO;
        if (error || !http || http.statusCode < 200 || http.statusCode >= 300 || data.length <= 4) {
            NSString *message = error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
            IOS2CallJavaScript(@"__ios2GroupBinPickerFailed", message);
            return;
        }
        NSString *authResponse = [data base64EncodedStringWithOptions:0];
        NSString *accountID = IOS2AccountIDForBinData(binData) ?: @"";
        [IOS2GameWebView appendInstanceWithAccount:name accountID:accountID authResponse:authResponse];
        IOS2ListBinFiles();
    });
}

@interface IOS2BinPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, assign) BOOL importOnly;
@property (nonatomic, assign) BOOL scriptImport;
@property (nonatomic, assign) BOOL settingsImport;
@property (nonatomic, assign) BOOL groupAdd;
@end

@implementation IOS2BinPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    (void)controller;
    NSURL *url = urls.firstObject;
    if (!url) {
        s_ios2LoginBusy = NO;
        IOS2CallJavaScript(self.settingsImport ? @"__ios2SettingsImportFailed" :
                           (self.scriptImport ? @"__ios2ScriptImportFailed" : @"__ios2BinLoginFailed"),
                           self.settingsImport ? @"no settings.js file selected" :
                           (self.scriptImport ? @"no .js file selected" : @"no .bin file selected"));
        return;
    }

    if (self.importOnly && !self.scriptImport && urls.count > 1) {
        NSMutableArray<NSString *> *storedNames = [NSMutableArray arrayWithCapacity:urls.count];
        NSError *firstReadError = nil;
        for (NSURL *candidateURL in urls) {
            BOOL candidateAccessed = [candidateURL startAccessingSecurityScopedResource];
            NSError *candidateError = nil;
            NSData *candidateData = [NSData dataWithContentsOfURL:candidateURL
                                                           options:NSDataReadingMappedIfSafe
                                                             error:&candidateError];
            if (candidateAccessed) [candidateURL stopAccessingSecurityScopedResource];
            if (!candidateData.length) {
                if (!firstReadError) firstReadError = candidateError;
                continue;
            }
            NSString *storedName = IOS2StoreBin(candidateData, candidateURL.lastPathComponent);
            if (storedName.length) [storedNames addObject:storedName];
        }
        s_ios2LoginBusy = NO;
        if (!storedNames.count) {
            IOS2CallJavaScript(@"__ios2BinLoginFailed",
                               firstReadError.localizedDescription ?: @"unable to store .bin files");
            return;
        }
        IOS2ListBinFiles();
        for (NSString *storedName in storedNames) {
            IOS2CallJavaScript(@"__ios2BinImported", storedName);
        }
        return;
    }

    BOOL accessed = [url startAccessingSecurityScopedResource];
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
    if (accessed) [url stopAccessingSecurityScopedResource];
    if (!data.length) {
        s_ios2LoginBusy = NO;
        if (!self.importOnly && !self.scriptImport) {
            s_ios2AuthReady = NO;
            IOS2FinishSDKLogin(1);
            IOS2CallJavaScript(@"__ios2BinLoginFailed", readError.localizedDescription ?: @"unable to read .bin file");
        } else if (self.settingsImport) {
            IOS2CallJavaScript(@"__ios2SettingsImportFailed", readError.localizedDescription ?: @"unable to read settings.js file");
        } else if (self.scriptImport) {
            IOS2CallJavaScript(@"__ios2ScriptImportFailed", readError.localizedDescription ?: @"unable to read .js file");
        } else {
            IOS2CallJavaScript(@"__ios2BinLoginFailed", readError.localizedDescription ?: @"unable to read .bin file");
        }
        return;
    }

    if (self.settingsImport) {
        NSURL *directory = [IOS2DocumentsDirectory() URLByAppendingPathComponent:@"ios2" isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:directory
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *settingsURL = [directory URLByAppendingPathComponent:@"settings.js"];
        NSError *writeError = nil;
        BOOL written = [data writeToURL:settingsURL options:NSDataWritingAtomic error:&writeError];
        s_ios2LoginBusy = NO;
        if (!written) {
            IOS2CallJavaScript(@"__ios2SettingsImportFailed", writeError.localizedDescription ?: @"unable to store settings.js file");
            return;
        }
        IOS2CallJavaScript(@"__ios2SettingsImported", @"settings.js");
        return;
    }

    if (self.scriptImport) {
        NSString *storedName = IOS2StoreScript(data, url.lastPathComponent);
        s_ios2LoginBusy = NO;
        if (!storedName.length) {
            IOS2CallJavaScript(@"__ios2ScriptImportFailed", @"unable to store .js file");
            return;
        }
        IOS2ListScriptFiles();
        IOS2CallJavaScript(@"__ios2ScriptImported", storedName);
        return;
    }

    if (self.importOnly) {
        NSString *storedName = IOS2StoreBin(data, url.lastPathComponent);
        s_ios2LoginBusy = NO;
        if (!storedName.length) {
            IOS2CallJavaScript(@"__ios2BinLoginFailed", @"unable to store .bin file");
            return;
        }
        IOS2ListBinFiles();
        IOS2CallJavaScript(@"__ios2BinImported", storedName);
        return;
    }

    NSString *storedName = IOS2StoreBin(data, url.lastPathComponent);
    if (self.groupAdd && [IOS2GameWebView instanceCount] > 1) {
        IOS2AuthenticateAdditionalBin(data, storedName ?: url.lastPathComponent);
    } else {
        IOS2SetAccountIDForBinData(data);
        // Keep the selected account available for later switching without
        // creating the unused ios2/last.bin marker file.
        IOS2Authenticate(data);
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    (void)controller;
    s_ios2LoginBusy = NO;
    if (!self.importOnly && !self.scriptImport) {
        s_ios2AuthReady = NO;
        IOS2FinishSDKLogin(1);
        IOS2CallJavaScript(@"__ios2BinLoginFailed", @"file selection cancelled");
    } else if (self.settingsImport) {
        IOS2CallJavaScript(@"__ios2SettingsImportFailed", @"file selection cancelled");
    } else if (self.scriptImport) {
        IOS2CallJavaScript(@"__ios2ScriptImportFailed", @"file selection cancelled");
    } else {
        IOS2CallJavaScript(@"__ios2BinLoginFailed", @"file selection cancelled");
    }
}

@end

@interface IOS2Native : NSObject
+ (void)selectLoginBin;
+ (void)showGroupBinPicker;
+ (void)appendBinToWebGroup:(NSString *)name;
+ (void)selectBinFile;
+ (void)selectScriptFile;
+ (void)selectSettingsFile;
+ (void)loginBinFile:(NSString *)name;
+ (void)deleteBinFile:(NSString *)name;
+ (void)deleteScriptFile:(NSString *)name;
+ (void)deleteSettingsFile;
+ (NSString *)settingsFileName;
+ (void)listBinFiles;
+ (void)listScriptFiles;
+ (NSString *)scriptFileContent:(NSString *)name;
+ (void)resumeLastBin;
+ (void)loginForSDK;
+ (void)logout;
+ (void)fetchManifest:(NSString *)version;
+ (void)applyPerformancePreferences;
+ (NSInteger)preferredFrameRate;
+ (NSString *)residentMemoryMB;
+ (void)setPreferredFrameRate:(NSInteger)frameRate;
+ (BOOL)showFPS;
+ (void)setShowFPS:(BOOL)showFPS;
+ (BOOL)hsdkVerboseDebug;
+ (void)setHSDKVerboseDebug:(BOOL)enabled;
+ (NSString *)renderQualitySingle;
+ (void)setRenderQualitySingle:(NSString *)quality;
+ (void)applyRenderQualitySingle;
+ (void)resetRenderQualitySingle;
+ (NSString *)renderQualityMulti;
+ (void)setRenderQualityMulti:(NSString *)quality;
+ (BOOL)isSimulator;
+ (void)trace:(NSString *)message;
+ (void)showScripts:(NSString *)json;
+ (void)hideScriptWebView;
+ (void)webViewRequest:(NSString *)message;
+ (void)webViewResponse:(NSString *)message;
+ (void)webViewEvent:(NSString *)message;
+ (void)syncRole:(NSString *)json;
+ (NSString *)runtimeBackend;
+ (void)setRuntimeBackend:(NSString *)backend;
+ (void)loginBinFiles:(NSString *)namesJSON scriptsJSON:(NSString *)scriptsJSON manifestJSON:(NSString *)manifestJSON;
+ (void)hideWebGames;
+ (NSInteger)webGameInstanceCount;
+ (NSString *)webGameStartupMode;
+ (void)setWebGameStartupMode:(NSString *)mode;
+ (NSString *)webGameLayoutMode;
+ (void)setWebGameLayoutMode:(NSString *)mode;
+ (void)webGameManagerRequested;
@end

@implementation IOS2Native

+ (BOOL)isSimulator
{
#if TARGET_OS_SIMULATOR
    return YES;
#else
    return NO;
#endif
}

+ (void)trace:(NSString *)message
{
    NSLog(@"[ios2][js] %@", message ?: @"<empty>");
}

+ (NSString *)residentMemoryMB
{
    double memoryMB = IOS2ResidentMemoryMB();
    if (memoryMB < 0) return @"-1";
    return [NSString stringWithFormat:@"%.1f", memoryMB];
}

+ (void)showScripts:(NSString *)json
{
    if (![[self runtimeBackend] isEqualToString:@"webkit"]) {
        NSLog(@"[ios2] ignored script WebView request outside WebKit mode");
        [IOS2ScriptWebView hide];
        return;
    }
    NSLog(@"[ios2] showing %lu enabled script(s) in WKWebView", (unsigned long)[[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] count]);
    [IOS2ScriptWebView showScriptsJSON:json];
}

+ (void)hideScriptWebView
{
    [IOS2ScriptWebView hide];
}

+ (void)webViewRequest:(NSString *)message
{
    if (!message.length) return;
    // The WebView cannot hold Cocos' JS objects directly. Forward its JSON
    // request into the Cocos JS realm, where the real game socket lives.
    IOS2CallJavaScript(@"__ios2WebViewRequest", message);
}

+ (void)webViewResponse:(NSString *)message
{
    [IOS2ScriptWebView sendResponseJSON:message];
}

+ (void)webViewEvent:(NSString *)message
{
    [IOS2ScriptWebView sendEventJSON:message];
}

+ (void)syncRole:(NSString *)json
{
    [IOS2ScriptWebView syncRoleJSON:json];
}

+ (NSString *)runtimeBackend
{
    NSString *backend = [[NSUserDefaults standardUserDefaults] stringForKey:kIOS2RuntimeBackendDefaultsKey];
    return [backend isEqualToString:@"webkit"] ? @"webkit" : @"native";
}

+ (void)setRuntimeBackend:(NSString *)backend
{
    NSString *value = [backend isEqualToString:@"webkit"] ? @"webkit" : @"native";
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:kIOS2RuntimeBackendDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[ios2] runtime backend selected: %@", value);
}

+ (void)loginBinFiles:(NSString *)namesJSON scriptsJSON:(NSString *)scriptsJSON manifestJSON:(NSString *)manifestJSON
{
    if (![[self runtimeBackend] isEqualToString:@"webkit"]) {
        IOS2CallJavaScript(@"__ios2MultiLoginFailed", @"多开仅支持 WebKit 模式");
        return;
    }
    NSData *jsonData = [namesJSON dataUsingEncoding:NSUTF8StringEncoding];
    id object = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
    if (![object isKindOfClass:[NSArray class]] || [(NSArray *)object count] < 1 || [(NSArray *)object count] > 4) {
        IOS2CallJavaScript(@"__ios2MultiLoginFailed", @"请选择 1 到 4 个账号");
        return;
    }
    NSArray *names = [(NSArray *)object copy];
    // WebKit games issue an HSDK login request after their web view starts.
    // Reset the previous native login result here so that request can only
    // reuse the account authenticated by this launch.
    s_ios2AuthReady = NO;
    [s_ios2AuthResponseBase64 release];
    s_ios2AuthResponseBase64 = nil;
    NSMutableArray<NSDictionary *> *instances = [NSMutableArray arrayWithCapacity:names.count];
    dispatch_group_t group = dispatch_group_create();
    NSObject *resultLock = [NSObject new];
    __block NSString *failure = nil;
    for (id value in names) {
        if (![value isKindOfClass:[NSString class]]) {
            failure = @"账号名称无效";
            break;
        }
        NSString *name = (NSString *)value;
        NSString *safeName = IOS2SafeBinName(name);
        NSURL *url = [IOS2BinDirectory() URLByAppendingPathComponent:safeName];
        NSData *binData = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        if (!binData.length) {
            failure = [NSString stringWithFormat:@"无法读取 %@", name];
            break;
        }
        // Keep the first account as the SDK identity. Single-account WebKit
        // login is the normal path; multi-open continues to use per-instance
        // auth responses supplied to each WKWebView.
        if (names.count == 1) IOS2SetAccountIDForBinData(binData);
        dispatch_group_enter(group);
        NSURL *authURL = [NSURL URLWithString:@"https://xxz-xyzw.hortorgames.com/login/authuser?_seq=1"];
        IOS2StartPOST(authURL, binData,
                      @{ @"Content-Type": @"application/octet-stream",
                         @"O4e-Encoding": @"lx",
                         @"Connection": @"close" },
                      ^(NSData *data, NSHTTPURLResponse *http, NSError *error) {
            @synchronized (resultLock) {
                if (error || !http || http.statusCode < 200 || http.statusCode >= 300 || data.length <= 4) {
                    if (!failure) failure = [NSString stringWithFormat:@"%@ 认证失败：%@", name,
                        error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]];
                } else {
                    [instances addObject:@{
                        @"account": name,
                        @"accountID": IOS2AccountIDForBinData(binData) ?: @"",
                        @"authResponse": [data base64EncodedStringWithOptions:0]
                    }];
                }
            }
            dispatch_group_leave(group);
        });
    }
    if (failure) {
        IOS2CallJavaScript(@"__ios2MultiLoginFailed", failure);
        return;
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (failure || instances.count != names.count) {
            IOS2CallJavaScript(@"__ios2MultiLoginFailed", failure ?: @"部分账号认证失败");
            return;
        }
        NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:names.count];
        for (NSString *name in names) {
            for (NSDictionary *instance in instances) {
                if ([instance[@"account"] isEqualToString:name]) {
                    [ordered addObject:instance];
                    break;
                }
            }
        }
        if (names.count == 1) {
            NSDictionary *instance = ordered.firstObject;
            NSString *authResponse = [instance[@"authResponse"] isKindOfClass:[NSString class]] ? instance[@"authResponse"] : @"";
            if (authResponse.length) {
                s_ios2AuthResponseBase64 = [authResponse copy];
                s_ios2AuthReady = YES;
            }
        }
        [IOS2GameWebView showInstances:ordered
                   scriptsJSON:scriptsJSON ?: @"[]"
                  manifestJSON:manifestJSON ?: @"{}"];
        IOS2CallJavaScript(@"__ios2MultiLoginReady", @"");
    });
}

+ (void)hideWebGames
{
    [IOS2GameWebView hide];
}

+ (NSInteger)webGameInstanceCount
{
    return (NSInteger)[IOS2GameWebView instanceCount];
}

+ (NSString *)webGameStartupMode
{
    return [IOS2GameWebView startupMode];
}

+ (void)setWebGameStartupMode:(NSString *)mode
{
    [IOS2GameWebView setStartupMode:mode];
}

+ (NSString *)webGameLayoutMode
{
    return [IOS2GameWebView layoutMode];
}

+ (void)setWebGameLayoutMode:(NSString *)mode
{
    [IOS2GameWebView setLayoutMode:mode];
}

+ (void)webGameManagerRequested
{
    IOS2CallJavaScript(@"__ios2WebGameManagerRequested", @"");
}

+ (void)applyPerformancePreferences
{
    IOS2ApplyPerformancePreferences();
}

+ (NSInteger)preferredFrameRate
{
    return IOS2PreferredFrameRate();
}

+ (void)setPreferredFrameRate:(NSInteger)frameRate
{
    NSArray *supported = @[@0, @15, @24, @30, @45, @60];
    if (![supported containsObject:@(frameRate)]) return;
    [[NSUserDefaults standardUserDefaults] setInteger:frameRate forKey:kIOS2FrameRateDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    IOS2ApplyPerformancePreferences();
}

+ (BOOL)showFPS
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kIOS2ShowFPSDefaultsKey];
}

+ (void)setShowFPS:(BOOL)showFPS
{
    [[NSUserDefaults standardUserDefaults] setBool:showFPS forKey:kIOS2ShowFPSDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    IOS2ApplyPerformancePreferences();
}

+ (BOOL)hsdkVerboseDebug
{
    return IOS2HSDKVerboseDebugEnabled();
}

+ (void)setHSDKVerboseDebug:(BOOL)enabled
{
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kIOS2HSDKVerboseDebugDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[ios2] HSDK verbose debug %@", enabled ? @"enabled" : @"disabled");
}

+ (NSString *)renderQualitySingle
{
    return IOS2RenderQualityValue(kIOS2RenderQualitySingleDefaultsKey, @"high");
}

+ (void)setRenderQualitySingle:(NSString *)quality
{
    NSString *value = ([quality isEqualToString:@"low"] || [quality isEqualToString:@"medium"] ||
                       [quality isEqualToString:@"high"]) ? quality : @"high";
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:kIOS2RenderQualitySingleDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[ios2] single render quality selected: %@", value);
}

+ (void)applyRenderQualitySingle
{
    cocos2d::Application *application = cocos2d::Application::getInstance();
    if (!application) return;
    NSString *quality = [self renderQualitySingle];
    // Cocos' native render texture uses a downsample factor: 1 is the full
    // device framebuffer, while 2 and 3 provide medium and low quality.
    uint8_t factor = [quality isEqualToString:@"low"] ? 3 :
                     ([quality isEqualToString:@"medium"] ? 2 : 1);
    if (factor == s_ios2SingleRenderTextureFactor) {
        NSLog(@"[ios2] single render quality applied: %@ (downsample=%u)", quality, factor);
        return;
    }
    if (factor > 1) {
        if (!application->isDownsampleEnabled()) application->setDevicePixelRatio(factor);
        else application->getRenderTexture()->init(factor);
    } else if (application->isDownsampleEnabled()) {
        // The bundled Cocos engine exposes a one-way downsample flag. Rebuild
        // its texture at the native resolution when returning to the launcher.
        application->getRenderTexture()->init(1);
    }
    s_ios2SingleRenderTextureFactor = factor;
    NSLog(@"[ios2] single render quality applied: %@ (downsample=%u)", quality, factor);
}

+ (void)resetRenderQualitySingle
{
    cocos2d::Application *application = cocos2d::Application::getInstance();
    if (!application || !application->isDownsampleEnabled()) return;
    application->getRenderTexture()->init(1);
    s_ios2SingleRenderTextureFactor = 1;
    NSLog(@"[ios2] single render quality reset for launcher (downsample=1)");
}

+ (NSString *)renderQualityMulti
{
    return IOS2RenderQualityValue(kIOS2RenderQualityMultiDefaultsKey, @"medium");
}

+ (void)setRenderQualityMulti:(NSString *)quality
{
    NSString *value = ([quality isEqualToString:@"low"] || [quality isEqualToString:@"medium"] ||
                       [quality isEqualToString:@"high"]) ? quality : @"medium";
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:kIOS2RenderQualityMultiDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[ios2] multi render quality selected: %@", value);
}

+ (void)showGroupBinPicker
{
    [IOS2GameWebView hide];
    IOS2CallJavaScript(@"__ios2ShowGroupBinPicker", @"");
}

+ (void)appendBinToWebGroup:(NSString *)name
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_ios2LoginBusy || [IOS2GameWebView instanceCount] < 2 || [IOS2GameWebView instanceCount] >= 4) return;
        NSString *safeName = IOS2SafeBinName(name);
        NSURL *url = [IOS2BinDirectory() URLByAppendingPathComponent:safeName];
        NSData *binData = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        if (!binData.length) {
            IOS2CallJavaScript(@"__ios2GroupBinPickerFailed", @"无法读取所选 Bin 文件");
            return;
        }
        s_ios2LoginBusy = YES;
        IOS2AuthenticateAdditionalBin(binData, name ?: safeName);
    });
}

+ (void)selectLoginBin
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_ios2LoginBusy) return;
        UIViewController *presenter = IOS2TopViewController();
        if (!presenter) {
            IOS2CallJavaScript(@"__ios2BinLoginFailed", @"native view controller is unavailable");
            return;
        }

        UTType *binType = [UTType typeWithFilenameExtension:@"bin" conformingToType:UTTypeData];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[binType ?: UTTypeData] asCopy:YES];
        IOS2BinPickerDelegate *delegate = [IOS2BinPickerDelegate new];
        delegate.importOnly = NO;
        delegate.scriptImport = NO;
        delegate.groupAdd = [IOS2GameWebView instanceCount] > 1;
        s_ios2PickerDelegate = delegate;
        picker.delegate = (id<UIDocumentPickerDelegate>)s_ios2PickerDelegate;
        picker.allowsMultipleSelection = NO;
        s_ios2LoginBusy = YES;
        [presenter presentViewController:picker animated:YES completion:nil];
    });
}

+ (void)selectBinFile
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_ios2LoginBusy) return;
        UIViewController *presenter = IOS2TopViewController();
        if (!presenter) {
            IOS2CallJavaScript(@"__ios2BinLoginFailed", @"native view controller is unavailable");
            return;
        }
        UTType *binType = [UTType typeWithFilenameExtension:@"bin" conformingToType:UTTypeData];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[binType ?: UTTypeData] asCopy:YES];
        IOS2BinPickerDelegate *delegate = [IOS2BinPickerDelegate new];
        delegate.importOnly = YES;
        delegate.scriptImport = NO;
        s_ios2PickerDelegate = delegate;
        picker.delegate = (id<UIDocumentPickerDelegate>)delegate;
        picker.allowsMultipleSelection = YES;
        s_ios2LoginBusy = YES;
        [presenter presentViewController:picker animated:YES completion:nil];
    });
}

+ (void)selectScriptFile
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![[self runtimeBackend] isEqualToString:@"webkit"]) {
            IOS2CallJavaScript(@"__ios2ScriptImportFailed", @"JS 脚本仅支持 WebKit 模式");
            return;
        }
        if (s_ios2LoginBusy) return;
        UIViewController *presenter = IOS2TopViewController();
        if (!presenter) {
            IOS2CallJavaScript(@"__ios2ScriptImportFailed", @"native view controller is unavailable");
            return;
        }
        UTType *scriptType = [UTType typeWithFilenameExtension:@"js" conformingToType:UTTypePlainText];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[scriptType ?: UTTypePlainText] asCopy:YES];
        IOS2BinPickerDelegate *delegate = [IOS2BinPickerDelegate new];
        delegate.importOnly = YES;
        delegate.scriptImport = YES;
        s_ios2PickerDelegate = delegate;
        picker.delegate = (id<UIDocumentPickerDelegate>)delegate;
        picker.allowsMultipleSelection = NO;
        s_ios2LoginBusy = YES;
        [presenter presentViewController:picker animated:YES completion:nil];
    });
}

+ (void)selectSettingsFile
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (s_ios2LoginBusy) return;
        UIViewController *presenter = IOS2TopViewController();
        if (!presenter) {
            IOS2CallJavaScript(@"__ios2SettingsImportFailed", @"native view controller is unavailable");
            return;
        }
        UTType *scriptType = [UTType typeWithFilenameExtension:@"js" conformingToType:UTTypePlainText];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForOpeningContentTypes:@[scriptType ?: UTTypePlainText] asCopy:YES];
        IOS2BinPickerDelegate *delegate = [IOS2BinPickerDelegate new];
        delegate.importOnly = YES;
        delegate.scriptImport = NO;
        delegate.settingsImport = YES;
        s_ios2PickerDelegate = delegate;
        picker.delegate = (id<UIDocumentPickerDelegate>)delegate;
        picker.allowsMultipleSelection = NO;
        s_ios2LoginBusy = YES;
        [presenter presentViewController:picker animated:YES completion:nil];
    });
}

+ (void)listBinFiles
{
    dispatch_async(dispatch_get_main_queue(), ^{
        IOS2ListBinFiles();
    });
}

+ (void)listScriptFiles
{
    dispatch_async(dispatch_get_main_queue(), ^{
        IOS2ListScriptFiles();
    });
}

+ (void)deleteBinFile:(NSString *)name
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        NSString *safeName = IOS2SafeBinName(name);
        if (!IOS2DeleteBin(safeName, &error)) {
            IOS2CallJavaScript(@"__ios2BinDeleteFailed", error.localizedDescription ?: @"unable to delete .bin file");
            return;
        }
        IOS2ListBinFiles();
        IOS2CallJavaScript(@"__ios2BinDeleted", safeName);
    });
}

+ (void)deleteScriptFile:(NSString *)name
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        NSString *safeName = IOS2SafeScriptName(name);
        if (!IOS2DeleteScript(safeName, &error)) {
            IOS2CallJavaScript(@"__ios2ScriptDeleteFailed", error.localizedDescription ?: @"unable to delete .js file");
            return;
        }
        IOS2ListScriptFiles();
        IOS2CallJavaScript(@"__ios2ScriptDeleted", safeName);
    });
}

+ (NSString *)scriptFileContent:(NSString *)name
{
    NSString *safeName = IOS2SafeScriptName(name);
    NSURL *url = [IOS2ScriptDirectory() URLByAppendingPathComponent:safeName];
    NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfURL:url
                                                 encoding:NSUTF8StringEncoding
                                                    error:&error];
    if (error) NSLog(@"[ios2] unable to read script %@: %@", safeName, error.localizedDescription);
    return source ?: @"";
}

+ (NSString *)settingsFileName
{
    NSURL *url = [IOS2DocumentsDirectory() URLByAppendingPathComponent:@"ios2/settings.js"];
    return [[NSFileManager defaultManager] fileExistsAtPath:url.path] ? @"settings.js" : @"";
}

+ (void)deleteSettingsFile
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *url = [IOS2DocumentsDirectory() URLByAppendingPathComponent:@"ios2/settings.js"];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] removeItemAtURL:url error:&error] &&
            [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            IOS2CallJavaScript(@"__ios2SettingsDeleteFailed", error.localizedDescription ?: @"unable to remove settings.js");
            return;
        }
        IOS2CallJavaScript(@"__ios2SettingsDeleted", @"settings.js");
    });
}

+ (void)loginBinFile:(NSString *)name
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *safeName = IOS2SafeBinName(name);
        NSURL *root = [IOS2DocumentsDirectory() URLByAppendingPathComponent:@"ios2" isDirectory:YES];
        NSURL *url = [safeName isEqualToString:@"last.bin"] ?
            [root URLByAppendingPathComponent:@"last.bin"] :
            [IOS2BinDirectory() URLByAppendingPathComponent:safeName];
        NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        if (!data.length) {
            IOS2CallJavaScript(@"__ios2BinLoginFailed", @"unable to read selected .bin file");
            return;
        }
        if (s_ios2LoginBusy) return;
        s_ios2AuthReady = NO;
        s_ios2LoginBusy = YES;
        IOS2SetAccountIDForBinData(data);
        IOS2Authenticate(data);
    });
}

+ (void)resumeLastBin
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *documents = IOS2DocumentsDirectory();
        NSURL *lastBin = [documents URLByAppendingPathComponent:@"ios2/last.bin"];
        NSData *data = [NSData dataWithContentsOfURL:lastBin options:NSDataReadingMappedIfSafe error:nil];
        if (data.length > 0) {
            IOS2SetAccountIDForBinData(data);
            s_ios2LoginBusy = YES;
            IOS2Authenticate(data);
        }
    });
}

+ (void)loginForSDK
{
    // A WebKit multi-open instance is authenticated before its page is
    // created. HSDK still asks the native bridge to log in during bootstrap;
    // answer for that originating instance instead of opening another
    // document picker. This path is synchronous so concurrent instances do
    // not overwrite the shared pending-login state.
    NSString *instanceID = [s_ios2HSDKTargetInstanceID copy];
    if ([[self runtimeBackend] isEqualToString:@"webkit"] && instanceID.length &&
        [IOS2GameWebView instanceCount] > 1) {
        NSString *accountID = [IOS2GameWebView accountIDForInstance:instanceID];
        IOS2PublishSDKUserForAccountID(accountID, instanceID);
        IOS2FinishSDKLogin(0);
        [instanceID release];
        return;
    }
    [instanceID release];
    dispatch_async(dispatch_get_main_queue(), ^{
        // The manager authenticates the selected bin before starting the
        // remote launcher. Reuse that authenticated response when HSDK asks
        // for its normal login callback, instead of opening another picker.
        if (s_ios2AuthReady) {
            IOS2PublishSDKUser();
            IOS2FinishSDKLogin(0);
            return;
        }
        s_ios2AuthReady = NO;
        if (!s_ios2LoginBusy) [IOS2Native selectLoginBin];
    });
}

+ (void)logout
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [IOS2ScriptWebView hide];
        s_ios2LoginBusy = NO;
        s_ios2AuthReady = NO;
        s_ios2SDKLoginPending = NO;
        [s_ios2SDKLoginAction release];
        s_ios2SDKLoginAction = nil;
        [s_ios2SDKLoginInstanceID release];
        s_ios2SDKLoginInstanceID = nil;
        [s_ios2HSDKImageInstanceID release];
        s_ios2HSDKImageInstanceID = nil;
        [s_ios2AuthResponseBase64 release];
        s_ios2AuthResponseBase64 = nil;
        [s_ios2AccountID release];
        s_ios2AccountID = nil;
        IOS2CallHSDKMessage(@"user-logout-from-sdk", @{}, 0);
        [IOS2GameWebView shutdownAndCloseAll];
    });
}

+ (void)fetchManifest:(NSString *)version
{
    NSString *manifestVersion = version.length ? version : @"0.33.0-ios";
    NSString *urlString = [NSString stringWithFormat:
        @"https://xxz-xyzw.hortorgames.com/login/manifest?platform=hortor&version=%@",
        manifestVersion];
    NSURL *url = [NSURL URLWithString:urlString];
    NSLog(@"[ios2] manifest request version=%@", manifestVersion);
    IOS2StartPOST(url, [NSData data],
                  @{ @"Content-Type": @"application/json;charset=UTF-8",
                     @"Accept": @"application/json, text/plain, */*",
                     @"Connection": @"close" },
                  ^(NSData *data, NSHTTPURLResponse *http, NSError *error) {
        NSLog(@"[ios2] manifest finished status=%ld bytes=%lu error=%@",
              (long)http.statusCode, (unsigned long)data.length, error.localizedDescription ?: @"<none>");
        if (error || !http || http.statusCode < 200 || http.statusCode >= 300 || data.length == 0) {
            NSString *message = error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
            IOS2CallJavaScript(@"__ios2ManifestFailed", message);
            return;
        }
        NSError *parseError = nil;
        NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        NSDictionary *body = [envelope isKindOfClass:[NSDictionary class]] ? envelope[@"body"] : nil;
        NSString *bundleVers = [body isKindOfClass:[NSDictionary class]] ? body[@"bundleVers"] : nil;
        if (![bundleVers isKindOfClass:[NSString class]] || !bundleVers.length) {
            NSString *message = parseError.localizedDescription ?: @"manifest has no bundleVers";
            IOS2CallJavaScript(@"__ios2ManifestFailed", message);
            return;
        }
        NSDictionary *versions = [NSJSONSerialization JSONObjectWithData:
            [bundleVers dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSLog(@"[ios2] manifest codeVersion=%@ battleVersion=%@ game=%@ launcher=%@",
              [versions isKindOfClass:[NSDictionary class]] ? versions[@"codeVersion"] : @"<unknown>",
              [body isKindOfClass:[NSDictionary class]] ? body[@"battleVersion"] : @"<unknown>",
              [versions isKindOfClass:[NSDictionary class]] ? versions[@"game"] : @"<unknown>",
              [versions isKindOfClass:[NSDictionary class]] ? versions[@"launcher"] : @"<unknown>");
        // `battleVersion` and other manifest metadata are consumed by game
        // scripts through cc.sys.manifestResult.rawData.  Do not reduce the
        // response to bundleVers when crossing the native bridge.
        NSString *manifest = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        IOS2CallJavaScript(@"__ios2ManifestReady", manifest ?: @"");
    });
}

@end

extern "C" NSArray<NSDictionary *> *IOS2ManagedBinRecords(void)
{
    return IOS2BinFileRecords(NO);
}

extern "C" void IOS2LoginManagedBin(NSString *name, NSString *scriptsJSON, NSString *manifestJSON)
{
    if (![name isKindOfClass:[NSString class]] || !name.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([[IOS2Native runtimeBackend] isEqualToString:@"webkit"]) {
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[name] options:0 error:nil];
            NSString *namesJSON = [[[NSString alloc] initWithData:jsonData
                                                         encoding:NSUTF8StringEncoding] autorelease] ?: @"[]";
            [IOS2Native loginBinFiles:namesJSON
                          scriptsJSON:scriptsJSON ?: @"[]"
                         manifestJSON:manifestJSON ?: @"{}"];
            return;
        }
        [IOS2Native loginBinFile:name];
    });
}

/*
 * HSDK's native iOS adapter calls this class through Cocos' ObjC bridge.
 * The original client supplies it from its SDK framework; ios2 keeps the
 * bridge local so the runtime remains self-contained and WebView-free.
 */
@interface SDKMessager : NSObject
+ (void)callNative:(NSString *)channel withMessage:(NSString *)message;
@end

@implementation SDKMessager

+ (void)callNative:(NSString *)channel withMessage:(NSString *)message
{
    (void)channel;
    NSDictionary *request = nil;
    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
    if (data) {
        id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([object isKindOfClass:[NSDictionary class]]) request = object;
    }

    NSString *action = [request[@"action"] isKindOfClass:[NSString class]] ? request[@"action"] : @"";
    NSDictionary *extra = [request[@"extra"] isKindOfClass:[NSDictionary class]] ? request[@"extra"] : @{};
    NSString *instanceID = [request[@"__ios2Instance"] isKindOfClass:[NSString class]] ? request[@"__ios2Instance"] : @"";
    NSString *previousTarget = s_ios2HSDKTargetInstanceID;
    s_ios2HSDKTargetInstanceID = instanceID.length ? instanceID : nil;
    BOOL isReportLogPost = [action isEqualToString:@"report_log_post"];
    BOOL verboseHSDK = IOS2HSDKVerboseDebugEnabled();
    if (isReportLogPost && verboseHSDK) {
        NSString *eventName = [extra[@"eventName"] isKindOfClass:[NSString class]] ? extra[@"eventName"] : @"";
        NSString *eventType = [extra[@"eventType"] isKindOfClass:[NSString class]] ? extra[@"eventType"] : @"";
        NSLog(@"[ios2] HSDK analytics action=report_log_post event=%@ type=%@", eventName, eventType);
    } else if (!isReportLogPost && verboseHSDK) {
        NSLog(@"[ios2] HSDK request action=%@ extra=%@", action, extra);
    }

    if ([action isEqualToString:@"game-init"]) {
        UIDevice *device = UIDevice.currentDevice;
        NSDictionary *deviceInfo = @{
            @"deviceSystem": @"iOS",
            @"deviceModel": device.model ?: @"iPhone",
            @"deviceBrand": @"Apple",
            @"deviceVersion": device.systemVersion ?: @"",
            @"hortorSDKVersion": kIOS2HSDKVersion,
            @"deviceName": device.name ?: @"iPhone"
        };
        NSString *distinctId = [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"ios2";
        NSLog(@"[ios2] HSDK game-init identity gameID=%@ env=production channel=%@ version=%@",
              kIOS2GameID, kIOS2Channel, kIOS2GameVersion);
        IOS2CallHSDKMessage(@"game-init", @{
            @"gameID": kIOS2GameID,
            // HSDK maps 0 to HSDK.ENV.Production and 1 to HSDK.ENV.Test.
            @"env": @0,
            @"gameVersion": kIOS2GameVersion,
            @"channel": kIOS2Channel,
            @"distinctId": distinctId,
            @"deviceInfo": deviceInfo
        }, 0);
    } else if ([action isEqualToString:@"user_login_show_dialog"] ||
               [action isEqualToString:@"user-tokenlogin"] ||
               [action isEqualToString:@"user-multi-platform-login"]) {
        s_ios2SDKLoginPending = YES;
        [s_ios2SDKLoginAction release];
        s_ios2SDKLoginAction = [action copy];
        [s_ios2SDKLoginInstanceID release];
        s_ios2SDKLoginInstanceID = [instanceID copy];
        [IOS2Native loginForSDK];
    } else if ([action isEqualToString:@"user-logout"]) {
        [IOS2Native logout];
        IOS2CallHSDKMessage(action, @{}, 0);
    } else if ([action isEqualToString:@"sdk-get-device-info"]) {
        UIDevice *device = UIDevice.currentDevice;
        IOS2CallHSDKMessage(action, @{
            @"deviceUniqueId": [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"ios2",
            @"gameId": kIOS2GameID,
            @"gameTp": @"ios",
            @"uniqueId": [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"ios2",
            @"sysInfo": @{
                @"deviceSystem": @"iOS",
                @"deviceModel": device.model ?: @"iPhone",
                @"deviceBrand": @"Apple",
                @"deviceVersion": device.systemVersion ?: @"",
                @"hortorSDKVersion": kIOS2HSDKVersion,
                @"deviceName": device.name ?: @"iPhone"
            }
        }, 0);
    } else if ([action isEqualToString:@"sdk-get-userId"] ||
               [action isEqualToString:@"user-getuserinfo"]) {
        NSString *accountID = [IOS2GameWebView accountIDForInstance:instanceID];
        if (!accountID.length) accountID = s_ios2AccountID;
        NSDictionary *account = accountID.length ?
            @{ @"userId": accountID, @"uniqueId": accountID } : @{};
        IOS2CallHSDKMessage(action, account, 0);
    } else if ([action isEqualToString:@"sdk-read-image"]) {
        [s_ios2HSDKImageInstanceID release];
        s_ios2HSDKImageInstanceID = [instanceID copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = IOS2TopViewController();
            if (!presenter || ![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
                NSString *previousTarget = s_ios2HSDKTargetInstanceID;
                s_ios2HSDKTargetInstanceID = s_ios2HSDKImageInstanceID;
                IOS2CallHSDKMessage(action, @{}, 1);
                s_ios2HSDKTargetInstanceID = previousTarget;
                [s_ios2HSDKImageInstanceID release];
                s_ios2HSDKImageInstanceID = nil;
                return;
            }

            UIImagePickerController *picker = [UIImagePickerController new];
            picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
            picker.allowsEditing = NO;
            s_ios2PickerDelegate = [IOS2ImagePickerDelegate new];
            picker.delegate = (id<UIImagePickerControllerDelegate, UINavigationControllerDelegate>)s_ios2PickerDelegate;
            [presenter presentViewController:picker animated:YES completion:nil];
        });
    } else if ([action isEqualToString:@"sdk-sync-passbord"]) {
        // HSDK keeps this action name for compatibility (the production SDK
        // spells "passbord" without the second 'a'). Its payload is the
        // clipboard object, normally { text: "..." }.
        NSString *text = [extra[@"text"] isKindOfClass:[NSString class]] ? extra[@"text"] : nil;
        if (!text && [extra[@"data"] isKindOfClass:[NSString class]]) text = extra[@"data"];
        if (!text) text = @"";
        NSString *clipboardText = [text copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIPasteboard generalPasteboard].string = clipboardText;
            NSLog(@"[ios2] clipboard updated length=%lu", (unsigned long)clipboardText.length);
        });
        IOS2CallHSDKMessage(action, @{}, 0);
    } else if ([action isEqualToString:@"sdk-get-passbord"]) {
        NSString *text = [UIPasteboard generalPasteboard].string ?: @"";
        IOS2CallHSDKMessage(action, @{ @"text": text }, 0);
    } else if ([action isEqualToString:@"get-check-switchs"]) {
        // HSDK resolves this call from a positional `data` array. Returning
        // an empty object makes its listener dereference data and abort the
        // loading chain, so provide a deterministic disabled-by-default set
        // of switches with the same order as switchIdList.
        NSNumber *sequence = [extra[@"sequence"] isKindOfClass:[NSNumber class]] ? extra[@"sequence"] : @0;
        NSArray *switchIds = [extra[@"switchIdList"] isKindOfClass:[NSArray class]] ? extra[@"switchIdList"] : @[];
        NSMutableArray *switchValues = [NSMutableArray arrayWithCapacity:switchIds.count];
        for (id switchId in switchIds) {
            // These are the client-side switches required by the bundled pet
            // page implementation. FasterSubPage makes UISubPages attach the
            // SubPageComp used by the refinement drawer's checkPageVisible();
            // ControllerSubPage covers the older UIController path.
            BOOL enabled = [switchId isKindOfClass:[NSString class]] &&
                           ([switchId isEqualToString:@"ChatWorldSwitch"] ||
                            [switchId isEqualToString:@"PaySwitch"] ||
                            [switchId isEqualToString:@"FasterSubPage"] ||
                            [switchId isEqualToString:@"ControllerSubPage"]);
            // HSDK's production config uses numeric flags, not JSON booleans.
            [switchValues addObject:(enabled ? @1 : @0)];
        }
        NSLog(@"[ios2] HSDK switches sequence=%@ ids=%@ values=%@", sequence, switchIds, switchValues);
        IOS2CallHSDKMessage(action, @{
            @"sequence": sequence,
            @"data": switchValues
        }, 0);
    } else if ([action isEqualToString:@"game_addiction_quit"] ||
               [action isEqualToString:@"send-url-param"] ||
               [action isEqualToString:@"app-activity-resume"] ||
               [action isEqualToString:@"app-activity-pause"]) {
        // These HSDK calls register listeners for a later native event.  They
        // are not request/response APIs; replying immediately would invoke
        // the game's listener as if the event had happened. In particular,
        // game_addiction_quit would make the game close during scene loading.
        NSLog(@"[ios2] HSDK listener registered action=%@", action);
    } else if (isReportLogPost) {
        // HSDK sends analytics through a fire-and-forget path. It does not
        // create a matching promise for this action, so a native reply only
        // allocates response JSON/script strings and makes HSDK log
        // "promiseList is empty" on every page transition.
    } else {
        // Resolve optional HSDK calls so a missing store/share/analytics
        // service cannot leave a game's promise chain pending.
        IOS2CallHSDKMessage(action, @{}, 0);
    }
    s_ios2HSDKTargetInstanceID = previousTarget;
}

@end



using namespace cocos2d;

// The startup script calls this method for compatibility with the original
// app. UIKit owns the launch storyboard in ios2, so there is no extra splash
// view to dismiss.
@interface AppController (IOS2Splash)
+ (void)hideSplash;
@end

@implementation AppController (IOS2Splash)
+ (void)hideSplash
{
}
@end

@implementation AppController

Application* app = nullptr;
@synthesize window;

#pragma mark -
#pragma mark Application lifecycle

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[SDKWrapper getInstance] application:application didFinishLaunchingWithOptions:launchOptions];
    // Add the view controller's view to the window and display.
    float scale = [[UIScreen mainScreen] scale];
    CGRect bounds = [[UIScreen mainScreen] bounds];
    window = [[UIWindow alloc] initWithFrame: bounds];
    
    // cocos2d application instance
    app = new AppDelegate(bounds.size.width * scale, bounds.size.height * scale);
    app->setMultitouch(true);
    
    // Use RootViewController to manage CCEAGLView
    _viewController = [[RootViewController alloc]init];
#ifdef NSFoundationVersionNumber_iOS_7_0
    _viewController.automaticallyAdjustsScrollViewInsets = NO;
    _viewController.extendedLayoutIncludesOpaqueBars = NO;
    _viewController.edgesForExtendedLayout = UIRectEdgeAll;
#else
    _viewController.wantsFullScreenLayout = YES;
#endif
    // Set RootViewController to window
    if ( [[UIDevice currentDevice].systemVersion floatValue] < 6.0)
    {
        // warning: addSubView doesn't work on iOS6
        [window addSubview: _viewController.view];
    }
    else
    {
        // use this method on ios6
        [window setRootViewController:_viewController];
    }
    
    [window makeKeyAndVisible];

    // Request portrait geometry explicitly so Cocos receives a portrait-sized
    // framebuffer from the first frame on modern simulator runtimes.
    if (@available(iOS 16.0, *)) {
        UIWindowScene *scene = window.windowScene;
        if (scene) {
            UIWindowSceneGeometryPreferencesIOS *preferences =
                [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskPortrait];
            [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
                NSLog(@"[ios2] portrait geometry request failed: %@", error.localizedDescription);
            }];
        }
    }
    
    [[UIApplication sharedApplication] setStatusBarHidden:YES];

    //run the cocos2d-x game scene
    app->start();

    const GLubyte *glVersion = glGetString(GL_VERSION);
    const GLubyte *glExtensions = glGetString(GL_EXTENSIONS);
    NSLog(@"[ios2] GL version: %s", glVersion ? (const char *)glVersion : "<none>");
    NSLog(@"[ios2] ASTC extension: %s", (glExtensions && strstr((const char *)glExtensions, "texture_compression_astc_ldr")) ? "yes" : "no");

    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    /*
     Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
     Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
     */
    app->onPause();
    [[SDKWrapper getInstance] applicationWillResignActive:application];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    /*
     Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
     */
    app->onResume();
    [[SDKWrapper getInstance] applicationDidBecomeActive:application];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    /*
     Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
     If your application supports background execution, called instead of applicationWillTerminate: when the user quits.
     */
    [IOS2GameWebView releaseUnusedAssetsForAllInstances];
    [[SDKWrapper getInstance] applicationDidEnterBackground:application];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    /*
     Called as part of  transition from the background to the inactive state: here you can undo many of the changes made on entering the background.
     */
    [[SDKWrapper getInstance] applicationWillEnterForeground:application];    
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    [[SDKWrapper getInstance] applicationWillTerminate:application];
    delete app;
    app = nil;
}


#pragma mark -
#pragma mark Memory management

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    /*
     Free up as much memory as possible by purging cached data objects that can be recreated (or reloaded from disk) later.
     */
    [IOS2GameWebView releaseUnusedAssetsForAllInstances];
}

@end
