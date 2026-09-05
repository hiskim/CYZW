#import "IOS2GameWebView.h"

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <CommonCrypto/CommonDigest.h>

// Implemented by AppController.mm. WebKit HSDK calls are fed through the
// same native dispatcher used by the Cocos JSB runtime.
@interface SDKMessager : NSObject
+ (void)callNative:(NSString *)channel withMessage:(NSString *)message;
@end

typedef void (^IOS2WebHTTPCompletion)(NSData *data, NSHTTPURLResponse *response, NSError *error);

extern "C" NSArray<NSDictionary *> *IOS2ManagedBinRecords(void);
extern "C" void IOS2LoginManagedBin(NSString *name, NSString *scriptsJSON, NSString *manifestJSON);

/*
 * Keep CDN downloads on the same connection stack as the working login and
 * manifest requests. NSURLSession can negotiate HTTP/3 in the simulator;
 * this endpoint has been observed to leave that response open there.
 */
@interface IOS2WebHTTPConnection : NSObject <NSURLConnectionDataDelegate>
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSMutableData *bodyData;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@property (nonatomic, copy) IOS2WebHTTPCompletion completion;
@property (nonatomic, copy) NSString *requestID;
@property (nonatomic, assign) BOOL finished;
- (instancetype)initWithRequest:(NSURLRequest *)request completion:(IOS2WebHTTPCompletion)completion;
- (void)start;
- (void)cancel;
@end

@interface IOS2GameSchemeHandler : NSObject <WKURLSchemeHandler>
// `tasks` maps a WKURLSchemeTask to its remote URL.  Several WebKit requests
// may resolve to one CDN URL, so downloads and their waiting tasks are tracked
// independently.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *tasks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, IOS2WebHTTPConnection *> *downloads;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *pendingTasks;
@property (nonatomic, strong) dispatch_queue_t cacheQueue;
- (void)cancelAllRequests;
@end

@interface IOS2GameWebView () <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *instances;
@property (nonatomic, strong) UIView *toolbar;
@property (nonatomic, strong) UIView *groupContainer;
@property (nonatomic, strong) UIView *emptySlot;
@property (nonatomic, strong) UILabel *toolbarTitle;
@property (nonatomic, strong) UILabel *toolbarStatus;
@property (nonatomic, strong) UIButton *switchButton;
@property (nonatomic, strong) UIButton *gearButton;
@property (nonatomic, strong) NSLayoutConstraint *toolbarSingleBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *toolbarMultiBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *toolbarTitleHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *toolbarTitleSingleTrailingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *toolbarTitleMultiTrailingConstraint;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *toolbarControlSizeConstraints;
@property (nonatomic, strong) UIButton *groupControlButton;
@property (nonatomic, strong) NSLayoutConstraint *groupControlCenterXConstraint;
@property (nonatomic, assign) BOOL groupControlCentered;
@property (nonatomic, assign) NSUInteger primaryInstanceIndex;
@property (nonatomic, copy) NSString *scriptsJSON;
@property (nonatomic, copy) NSString *manifestJSON;
@property (nonatomic, strong) UIViewController *presenter;
@property (nonatomic, assign) NSUInteger shutdownGeneration;
@property (nonatomic, assign) NSUInteger startupGeneration;
@property (nonatomic, assign) NSUInteger startupIndex;
@property (nonatomic, copy) NSString *startupWaitingInstanceID;
- (void)shutdownAndCloseInstances;
- (void)finishShutdownGeneration:(NSNumber *)generation;
- (void)startNextInstanceForGeneration:(NSNumber *)generation;
- (void)startupTimeout:(NSDictionary *)token;
- (void)installBootstrapForRecord:(NSDictionary *)record;
- (void)releaseStartupPayloadForInstanceID:(NSString *)instanceID;
- (void)groupControlTapped;
- (void)tuckGroupControlButton;
- (void)showGroupControlButton;
- (void)ensureGroupContainer;
- (void)addBinToGroupTapped;
- (void)presentGroupBinPicker;
- (void)instanceThumbnailTapped:(UITapGestureRecognizer *)gesture;
- (void)showInstanceCloseMenu;
- (void)closeInstanceAtIndex:(NSUInteger)index;
- (void)updateAccountBadgeForRecord:(NSMutableDictionary *)record frame:(CGRect)frame;
- (void)appendInstanceWithAccount:(NSString *)account accountID:(NSString *)accountID authResponse:(NSString *)authResponse;
+ (NSString *)layoutMode;
+ (void)setLayoutMode:(NSString *)mode;
@end

static IOS2GameWebView *s_ios2GameWebView = nil;
static IOS2GameSchemeHandler *s_ios2GameSchemeHandler = nil;
static WKProcessPool *s_ios2WebProcessPool = nil;
static NSString * const kIOS2WebRuntimeRevision = @"20260829-webkit-quality-2";
static NSString * const kIOS2WebFrameRateDefaultsKey = @"ios2.preferredFrameRate";
static NSString * const kIOS2WebVerboseLoggingDefaultsKey = @"ios2.hsdkVerboseDebug";
static NSString * const kIOS2WebStartupModeDefaultsKey = @"ios2.webStartupMode";
static NSString * const kIOS2WebRenderQualitySingleDefaultsKey = @"ios2.renderQuality.single";
static NSString * const kIOS2WebRenderQualityMultiDefaultsKey = @"ios2.renderQuality.multi";
static NSString * const kIOS2WebLayoutModeDefaultsKey = @"ios2.webLayoutMode";
static NSTimeInterval const kIOS2WebParallelStartupDelay = 0.75;
static NSTimeInterval const kIOS2WebStartupPayloadCleanupDelay = 0.75;
static NSTimeInterval const kIOS2WebStartupTimeout = 60.0;
static NSTimeInterval const kIOS2WebGroupControlIdleDelay = 3.5;

static UIColor *IOS2TokenCardColor(void)
{
    return [UIColor colorWithRed:28.0 / 255.0 green:28.0 / 255.0 blue:31.0 / 255.0 alpha:0.96];
}

static UIColor *IOS2TokenCardRaisedColor(void)
{
    return [UIColor colorWithRed:41.0 / 255.0 green:41.0 / 255.0 blue:43.0 / 255.0 alpha:0.98];
}

static UIColor *IOS2TokenBorderColor(void)
{
    return [UIColor colorWithRed:59.0 / 255.0 green:59.0 / 255.0 blue:61.0 / 255.0 alpha:0.92];
}

static UIColor *IOS2TokenAccentColor(void)
{
    return [UIColor colorWithRed:41.0 / 255.0 green:150.0 / 255.0 blue:255.0 / 255.0 alpha:1.0];
}

static WKProcessPool *IOS2SharedWebProcessPool(void)
{
    if (!s_ios2WebProcessPool) s_ios2WebProcessPool = [WKProcessPool new];
    return s_ios2WebProcessPool;
}

static BOOL IOS2WebVerboseLoggingEnabled(void)
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kIOS2WebVerboseLoggingDefaultsKey];
}

static NSString *IOS2WebStartupMode(void)
{
    NSString *mode = [[NSUserDefaults standardUserDefaults] stringForKey:kIOS2WebStartupModeDefaultsKey];
    return [mode isEqualToString:@"parallel"] ? @"parallel" : @"serial";
}

static NSString *IOS2WebRenderQuality(NSString *key, NSString *fallback)
{
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    return ([value isEqualToString:@"low"] || [value isEqualToString:@"medium"] ||
            [value isEqualToString:@"high"]) ? value : fallback;
}

static NSInteger IOS2WebPreferredFrameRate(void)
{
    NSInteger frameRate = [[NSUserDefaults standardUserDefaults] integerForKey:kIOS2WebFrameRateDefaultsKey];
    switch (frameRate) {
        case 15:
        case 24:
        case 30:
        case 45:
        case 60:
            return frameRate;
        case 0:
        default:
            return 60;
    }
}

static NSString *IOS2GameMIMEType(NSString *path)
{
    NSString *extension = path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"html"]) return @"text/html";
    if ([extension isEqualToString:@"js"]) return @"application/javascript";
    if ([extension isEqualToString:@"json"]) return @"application/json";
    if ([extension isEqualToString:@"css"]) return @"text/css";
    if ([extension isEqualToString:@"pvr"]) return @"application/octet-stream";
    if ([extension isEqualToString:@"png"]) return @"image/png";
    if ([extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"]) return @"image/jpeg";
    if ([extension isEqualToString:@"mp3"]) return @"audio/mpeg";
    if ([extension isEqualToString:@"m4a"]) return @"audio/mp4";
    return @"application/octet-stream";
}

static NSURL *IOS2GameCacheDirectory(void)
{
    NSURL *documents = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                               inDomains:NSUserDomainMask] firstObject];
    return [documents URLByAppendingPathComponent:@"gamecaches" isDirectory:YES];
}

static NSString *IOS2GameSHA256(NSString *value)
{
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) [result appendFormat:@"%02x", digest[index]];
    return result;
}

@implementation IOS2WebHTTPConnection

- (instancetype)initWithRequest:(NSURLRequest *)request completion:(IOS2WebHTTPCompletion)completion
{
    self = [super init];
    if (self) {
        _bodyData = [[NSMutableData alloc] init];
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

- (void)cancel
{
    [self.connection cancel];
    self.completion = nil;
    self.connection = nil;
}

- (void)dealloc
{
    [self cancel];
    self.bodyData = nil;
    self.response = nil;
    self.requestID = nil;
    [super dealloc];
}

- (void)finishWithResponse:(NSHTTPURLResponse *)response error:(NSError *)error
{
    if (self.finished) return;
    self.finished = YES;
    IOS2WebHTTPCompletion completion = self.completion;
    // The completion is invoked synchronously and does not retain the body.
    // Avoid an extra full-size copy for every CDN response.
    NSData *body = self.bodyData;
    if (completion) completion(body, response, error);
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
    [self finishWithResponse:self.response error:error];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    (void)connection;
    [self finishWithResponse:self.response error:nil];
}

@end

@implementation IOS2GameSchemeHandler

- (NSString *)keyForTask:(id<WKURLSchemeTask>)task
{
    return [NSString stringWithFormat:@"%p", task];
}

- (BOOL)isTaskActive:(id<WKURLSchemeTask>)task
{
    @synchronized (self.tasks) {
        return self.tasks[[self keyForTask:task]] != nil;
    }
}

- (void)registerTask:(id<WKURLSchemeTask>)task url:(NSURL *)url
{
    @synchronized (self.tasks) {
        self.tasks[[self keyForTask:task]] = url.absoluteString ?: @"<unknown>";
    }
}

- (void)updateTask:(id<WKURLSchemeTask>)task remoteURL:(NSString *)remoteURL
{
    @synchronized (self.tasks) {
        NSString *key = [self keyForTask:task];
        if (self.tasks[key]) self.tasks[key] = remoteURL;
    }
}

- (void)finishTask:(id<WKURLSchemeTask>)task
{
    @synchronized (self.tasks) {
        [self.tasks removeObjectForKey:[self keyForTask:task]];
    }
}

+ (instancetype)sharedInstance
{
    if (!s_ios2GameSchemeHandler) {
        s_ios2GameSchemeHandler = [IOS2GameSchemeHandler new];
        s_ios2GameSchemeHandler.tasks = [NSMutableDictionary dictionary];
        s_ios2GameSchemeHandler.downloads = [NSMutableDictionary dictionary];
        s_ios2GameSchemeHandler.pendingTasks = [NSMutableDictionary dictionary];
        s_ios2GameSchemeHandler.cacheQueue = dispatch_queue_create("com.xyzw.ios2.web-cache", DISPATCH_QUEUE_SERIAL);
    }
    return s_ios2GameSchemeHandler;
}

- (void)cancelAllRequests
{
    NSArray<IOS2WebHTTPConnection *> *downloads = nil;
    @synchronized (self.tasks) {
        downloads = [[self.downloads allValues] copy];
        [self.downloads removeAllObjects];
        [self.pendingTasks removeAllObjects];
        [self.tasks removeAllObjects];
    }
    for (IOS2WebHTTPConnection *download in downloads) [download cancel];
    [downloads release];
}

- (void)respondToTask:(id<WKURLSchemeTask>)task data:(NSData *)data url:(NSURL *)url
{
    // WKWebView can stop a task while a cache/CDN callback is queued on the
    // main queue. Never send a second response to a stopped task.
    if (![self isTaskActive:task]) return;
    if (!data) {
        NSLog(@"[ios2] Web resource missing: %@", url.absoluteString);
        [task didFailWithError:[NSError errorWithDomain:@"IOS2GameWebView" code:404
                                               userInfo:@{NSLocalizedDescriptionKey: @"Resource not found"}]];
        [self finishTask:task];
        return;
    }
    NSString *mimeType = IOS2GameMIMEType(url.path);
    NSDictionary *headers = @{
        @"Content-Type": mimeType,
        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
        // Native cacheList.json owns CDN caching; avoid retaining a stale
        // WebKit runtime after an Xcode rebuild.
        @"Cache-Control": @"no-store"
    };
    /* WKURLSchemeTask needs an HTTP response to expose fetch().ok/status. */
    NSURLResponse *response = [[[NSHTTPURLResponse alloc] initWithURL:url
                                                            statusCode:200
                                                           HTTPVersion:@"HTTP/1.1"
                                                          headerFields:headers] autorelease];
    [task didReceiveResponse:response];
    [task didReceiveData:data];
    [task didFinish];
    [self finishTask:task];
}

- (NSURL *)cachedFileForURL:(NSString *)remoteURL index:(NSDictionary *)index
{
    NSDictionary *files = [index[@"files"] isKindOfClass:[NSDictionary class]] ? index[@"files"] : nil;
    NSDictionary *record = [files[remoteURL] isKindOfClass:[NSDictionary class]] ? files[remoteURL] : nil;
    NSString *relativePath = [record[@"url"] isKindOfClass:[NSString class]] ? record[@"url"] : nil;
    if (!relativePath.length || [relativePath hasPrefix:@"/"] || [relativePath containsString:@".."]) return nil;
    NSURL *cacheDirectory = IOS2GameCacheDirectory().standardizedURL;
    NSURL *fileURL = [[cacheDirectory URLByAppendingPathComponent:relativePath] standardizedURL];
    NSString *cachePrefix = [cacheDirectory.path stringByAppendingString:@"/"];
    if (![fileURL.path hasPrefix:cachePrefix]) return nil;
    return [[NSFileManager defaultManager] fileExistsAtPath:fileURL.path] ? fileURL : nil;
}

- (NSArray<NSDictionary *> *)takePendingTasksForURL:(NSString *)remoteURL requestID:(NSString *)requestID
{
    @synchronized (self.tasks) {
        if (![self.downloads[remoteURL].requestID isEqualToString:requestID]) return @[];
        NSArray<NSDictionary *> *pending = [[self.pendingTasks[remoteURL] copy] autorelease] ?: @[];
        [self.downloads removeObjectForKey:remoteURL];
        [self.pendingTasks removeObjectForKey:remoteURL];
        return pending;
    }
}

- (void)respondToPendingTasks:(NSArray<NSDictionary *> *)pending data:(NSData *)data error:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSDictionary *entry in pending) {
            id<WKURLSchemeTask> task = entry[@"task"];
            NSURL *url = entry[@"url"];
            if (![self isTaskActive:task]) continue;
            if (error) {
                [task didFailWithError:error];
                [self finishTask:task];
            } else {
                [self respondToTask:task data:data url:url];
            }
        }
    });
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    (void)webView;
    NSURL *url = task.request.URL;
    [self registerTask:task url:url];
    if ([url.host isEqualToString:@"app"] && ![url.path hasPrefix:@"/cdn/"]) {
        NSString *name = url.lastPathComponent;
        NSDictionary *files = @{
            @"index.html": @"ios2-web-index.html",
            @"settings.js": @"settings.b2e22.js",
            @"cocos2d.js": @"ios2-web-cocos2d.js",
            @"physics.js": @"ios2-web-physics.js",
            @"boot.js": @"ios2-web-boot.js"
        };
        NSString *resource = files[name];
        NSString *path = nil;
        if ([name isEqualToString:@"game-defines.js"]) {
            path = [[NSBundle mainBundle] pathForResource:@"game-defines.js"
                                                    ofType:nil
                                               inDirectory:@"jsb-adapter"];
        } else if (resource.length) {
            path = [[NSBundle mainBundle] pathForResource:resource ofType:nil inDirectory:@"src"];
        } else if ([url.path hasPrefix:@"/src/"]) {
            path = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:[url.path substringFromIndex:1]];
        } else if ([url.path hasPrefix:@"/assets/"]) {
            path = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:[url.path substringFromIndex:1]];
        }
        NSData *localData = path.length ? [NSData dataWithContentsOfFile:path] : nil;
        if (localData.length || [url.path hasPrefix:@"/src/"]) {
            [self respondToTask:task data:localData url:url];
            return;
        }

        /*
         * Cocos' remote bundle loader keeps the bundle URL it was given. In
         * WebKit that URL is ios2-game://app/game/... (or
         * ios2-game://app/TEST_REMOTE_MODULE/...), while the CDN stores the
         * same files below /remote/<bundle>/. Fall through to the CDN path
         * for these non-packaged app resources instead of reporting them as
         * missing local files.
         */
    }
    if (![url.host isEqualToString:@"cdn"] && ![url.host isEqualToString:@"app"]) {
        [self respondToTask:task data:nil url:url];
        return;
    }
    NSString *remoteURL = nil;
    if ([url.host isEqualToString:@"app"]) {
        NSString *cdnPath = [url.path substringFromIndex:[@"/cdn" length]];
        if (![url.path hasPrefix:@"/cdn/"]) {
            cdnPath = [@"/remote" stringByAppendingString:url.path];
            if (IOS2WebVerboseLoggingEnabled()) {
                NSLog(@"[ios2] Web bundle resource mapped: %@ -> %@", url.absoluteString, cdnPath);
            }
        }
        remoteURL = [@"https://xxz-xyzw-res.hortorgames.com" stringByAppendingString:cdnPath ?: @""];
        if (url.query.length) remoteURL = [remoteURL stringByAppendingFormat:@"?%@", url.query];
    } else {
        NSString *encoded = [url.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        remoteURL = [@"https://xxz-xyzw-res.hortorgames.com/" stringByAppendingString:encoded.stringByRemovingPercentEncoding ?: @""];
        if (url.query.length) remoteURL = [remoteURL stringByAppendingFormat:@"?%@", url.query];
    }
    NSURL *remote = [NSURL URLWithString:remoteURL ?: @""];
    if (!remote || ![@[@"http", @"https"] containsObject:remote.scheme.lowercaseString]) {
        [self respondToTask:task data:nil url:url];
        return;
    }
    [self updateTask:task remoteURL:remoteURL];
    dispatch_async(self.cacheQueue, ^{
        if (![self isTaskActive:task]) return;
        NSURL *cacheDirectory = IOS2GameCacheDirectory();
        NSURL *indexURL = [cacheDirectory URLByAppendingPathComponent:@"cacheList.json"];
        NSData *indexData = [NSData dataWithContentsOfURL:indexURL];
        NSDictionary *index = indexData ? [NSJSONSerialization JSONObjectWithData:indexData options:0 error:nil] : nil;
        NSURL *cachedURL = [self cachedFileForURL:remoteURL index:index];
        NSData *cachedData = cachedURL ? [NSData dataWithContentsOfURL:cachedURL] : nil;
        if (cachedData.length) {
            if (IOS2WebVerboseLoggingEnabled()) {
                NSLog(@"[ios2] Web CDN cache hit: %@ bytes=%lu", remoteURL, (unsigned long)cachedData.length);
            }
            dispatch_async(dispatch_get_main_queue(), ^{ [self respondToTask:task data:cachedData url:url]; });
            return;
        }
        BOOL shouldStartDownload = NO;
        @synchronized (self.tasks) {
            if (!self.tasks[[self keyForTask:task]]) return;
            NSMutableArray<NSDictionary *> *pending = self.pendingTasks[remoteURL];
            if (!pending) {
                pending = [NSMutableArray array];
                self.pendingTasks[remoteURL] = pending;
                shouldStartDownload = YES;
            }
            [pending addObject:@{ @"task": (id)task, @"url": url }];
            self.tasks[[self keyForTask:task]] = remoteURL;
        }
        if (!shouldStartDownload) {
            if (IOS2WebVerboseLoggingEnabled()) NSLog(@"[ios2] Web CDN request coalesced: %@", remoteURL);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (self.tasks) {
                if (!self.pendingTasks[remoteURL].count || self.downloads[remoteURL]) return;
            }
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:remote
                                                                      cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                                  timeoutInterval:60.0];
            request.HTTPMethod = @"GET";
            [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
            [request setValue:@"close" forHTTPHeaderField:@"Connection"];
            NSString *downloadID = NSUUID.UUID.UUIDString;
            IOS2WebHTTPConnection *download = [[IOS2WebHTTPConnection alloc] initWithRequest:request
                                                                                       completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
                NSInteger status = response ? response.statusCode : 0;
                if (error || !data.length || status < 200 || status >= 300) {
                    NSLog(@"[ios2] Web CDN request failed: %@ status=%ld error=%@",
                          remoteURL, (long)status, error.localizedDescription ?: @"<none>");
                    NSError *failure = error;
                    if (!failure) {
                        NSString *message = status ? [NSString stringWithFormat:@"CDN request failed (HTTP %ld)", (long)status]
                                                   : @"CDN request failed";
                        failure = [NSError errorWithDomain:@"IOS2GameWebView"
                                                       code:(status ?: -1)
                                                   userInfo:@{NSLocalizedDescriptionKey: message}];
                    }
                    dispatch_async(self.cacheQueue, ^{
                        NSArray<NSDictionary *> *pending = [self takePendingTasksForURL:remoteURL requestID:downloadID];
                        [self respondToPendingTasks:pending data:nil error:failure];
                    });
                    return;
                }
                if (IOS2WebVerboseLoggingEnabled()) {
                    NSLog(@"[ios2] Web CDN request finished: %@ status=%ld bytes=%lu",
                          remoteURL, (long)status, (unsigned long)data.length);
                }
                dispatch_async(self.cacheQueue, ^{
                    NSFileManager *manager = [NSFileManager defaultManager];
                    NSURL *webDirectory = [IOS2GameCacheDirectory() URLByAppendingPathComponent:@"webkit" isDirectory:YES];
                    NSError *directoryError = nil;
                    if (![manager createDirectoryAtURL:webDirectory withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
                        NSLog(@"[ios2] Web CDN cache directory create failed: %@ error=%@", remoteURL,
                              directoryError.localizedDescription ?: @"<none>");
                        NSArray<NSDictionary *> *pending = [self takePendingTasksForURL:remoteURL requestID:downloadID];
                        [self respondToPendingTasks:pending data:data error:nil];
                        return;
                    }
                    NSString *extension = remote.pathExtension.length ? [@"." stringByAppendingString:remote.pathExtension] : @"";
                    NSString *relativePath = [@"webkit/" stringByAppendingString:[IOS2GameSHA256(remoteURL) stringByAppendingString:extension]];
                    NSURL *fileURL = [IOS2GameCacheDirectory() URLByAppendingPathComponent:relativePath];
                    NSError *fileWriteError = nil;
                    if (![data writeToURL:fileURL options:NSDataWritingAtomic error:&fileWriteError]) {
                        NSLog(@"[ios2] Web CDN cache file write failed: %@ error=%@", remoteURL,
                              fileWriteError.localizedDescription ?: @"<none>");
                        NSArray<NSDictionary *> *pending = [self takePendingTasksForURL:remoteURL requestID:downloadID];
                        [self respondToPendingTasks:pending data:data error:nil];
                        return;
                    }
                    NSData *latestData = [NSData dataWithContentsOfURL:indexURL];
                    NSMutableDictionary *latest = latestData ? [[[NSJSONSerialization JSONObjectWithData:latestData options:NSJSONReadingMutableContainers error:nil] mutableCopy] autorelease] : [NSMutableDictionary dictionary];
                    NSMutableDictionary *cacheFiles = [latest[@"files"] isKindOfClass:[NSDictionary class]] ? [[latest[@"files"] mutableCopy] autorelease] : [NSMutableDictionary dictionary];
                    cacheFiles[remoteURL] = @{ @"url": relativePath, @"bundle": @"webkit" };
                    latest[@"files"] = cacheFiles;
                    NSData *updated = [NSJSONSerialization dataWithJSONObject:latest options:0 error:nil];
                    NSError *indexWriteError = nil;
                    if (![updated writeToURL:indexURL options:NSDataWritingAtomic error:&indexWriteError]) {
                        NSLog(@"[ios2] Web CDN cache index write failed: %@ error=%@", remoteURL,
                              indexWriteError.localizedDescription ?: @"<none>");
                    } else if (IOS2WebVerboseLoggingEnabled()) {
                        NSLog(@"[ios2] Web CDN cache saved: %@ -> %@", remoteURL, relativePath);
                    }
                    NSArray<NSDictionary *> *pending = [self takePendingTasksForURL:remoteURL requestID:downloadID];
                    [self respondToPendingTasks:pending data:data error:nil];
                });
            }];
            @synchronized (self.tasks) {
                if (!self.pendingTasks[remoteURL].count || self.downloads[remoteURL]) {
                    [download release];
                    return;
                }
                download.requestID = downloadID;
                self.downloads[remoteURL] = download;
            }
            [download start];
            [download release];
        });
    });
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task
{
    (void)webView;
    IOS2WebHTTPConnection *download = nil;
    @synchronized (self.tasks) {
        NSString *key = [self keyForTask:task];
        NSString *remoteURL = self.tasks[key];
        if (!remoteURL.length) return;
        [self.tasks removeObjectForKey:key];
        NSMutableArray<NSDictionary *> *pending = self.pendingTasks[remoteURL];
        NSIndexSet *indices = [pending indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger index, BOOL *stop) {
            (void)index;
            if (entry[@"task"] != (id)task) return NO;
            *stop = YES;
            return YES;
        }];
        [pending removeObjectsAtIndexes:indices];
        if (!pending.count) {
            [self.pendingTasks removeObjectForKey:remoteURL];
            download = self.downloads[remoteURL];
            [self.downloads removeObjectForKey:remoteURL];
        }
    }
    [download cancel];
}

@end

static UIViewController *IOS2GamePresenter(void)
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

static NSString *IOS2DisplayAccountName(NSString *name)
{
    NSString *value = [name isKindOfClass:[NSString class]] ? name : @"";
    if ([value.lowercaseString hasSuffix:@".bin"]) value = [value substringToIndex:value.length - 4];
    return value.length ? value : @"账号";
}

static NSString *IOS2PVRBootstrap(NSString *instanceID, NSString *accountName, NSString *authResponse, NSString *scriptsJSON, NSString *manifestJSON, BOOL verboseLogging, BOOL multiOpen, NSString *startupMode)
{
    NSArray *scripts = nil;
    NSData *scriptsData = [scriptsJSON dataUsingEncoding:NSUTF8StringEncoding];
    id scriptsObject = scriptsData ? [NSJSONSerialization JSONObjectWithData:scriptsData options:0 error:nil] : nil;
    if ([scriptsObject isKindOfClass:[NSArray class]]) scripts = scriptsObject;
    NSDictionary *manifest = nil;
    NSData *manifestData = [manifestJSON dataUsingEncoding:NSUTF8StringEncoding];
    id manifestObject = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil] : nil;
    if ([manifestObject isKindOfClass:[NSDictionary class]]) manifest = manifestObject;
    NSDictionary *identity = @{
        @"id": instanceID ?: @"",
        @"account": accountName ?: @"",
        @"authResponse": authResponse ?: @"",
        @"frameRate": @(IOS2WebPreferredFrameRate()),
        @"qualitySingle": IOS2WebRenderQuality(kIOS2WebRenderQualitySingleDefaultsKey, @"high"),
        @"qualityMulti": IOS2WebRenderQuality(kIOS2WebRenderQualityMultiDefaultsKey, @"medium"),
        @"verboseLogging": @(verboseLogging),
        @"multiOpen": @(multiOpen),
        @"startupMode": startupMode ?: @"serial",
        @"scripts": scripts ?: @[],
        @"manifest": manifest ?: @{}
    };
    NSData *identityData = [NSJSONSerialization dataWithJSONObject:identity options:0 error:nil];
    NSString *identityJSON = [[[NSString alloc] initWithData:identityData encoding:NSUTF8StringEncoding] autorelease] ?: @"{}";
    return [NSString stringWithFormat:
        @"(function(){'use strict';"
         "window.__IOS2_GAME_INSTANCE__=%@;var __ios2VerboseLogging=!!window.__IOS2_GAME_INSTANCE__.verboseLogging;"
         "window.jsb=window.jsb||{};window.jsb.reflection=window.jsb.reflection||{};"
         "window.jsb.reflection.callStaticMethod=function(){var args=Array.prototype.slice.call(arguments),klass=args.shift(),method=args.shift();if(klass==='SDKMessager'&&method==='callNative:withMessage:'){var channel=args[0]||'sdk',message=args[1]||'{}';try{window.webkit.messageHandlers.ios2Game.postMessage({type:'hsdk',instance:window.__IOS2_GAME_INSTANCE__.id,channel:channel,message:String(message)});}catch(error){console.error('[ios2-web] HSDK bridge failed',error);}}return null;};"
         "var __ios2AuthBuffer=null;function authBytes(){if(__ios2AuthBuffer)return __ios2AuthBuffer.slice(0);var value=window.__IOS2_GAME_INSTANCE__.authResponse||'',binary=atob(value),bytes=new Uint8Array(binary.length);for(var i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);__ios2AuthBuffer=bytes.buffer;window.__IOS2_GAME_INSTANCE__.authResponse='';return __ios2AuthBuffer.slice(0);}"
         "var NativeXHR=window.XMLHttpRequest;function IOS2XHR(){this._native=new NativeXHR();this._fake=false;this._listeners={};this._readyState=0;this._status=0;this._response=null;this._responseType='';var self=this;['readystatechange','load','error','timeout','abort','loadend','progress'].forEach(function(type){self._native['on'+type]=function(event){var handler=self['on'+type];if(typeof handler==='function')handler.call(self,event);var list=self._listeners[type]||[];for(var i=0;i<list.length;i++)list[i].call(self,event);};});}"
         "IOS2XHR.prototype.open=function(method,url){this._fake=/\\/login\\/authuser(?:\\?|$)/.test(String(url||''));if(this._fake){this._readyState=1;this._emit('readystatechange');}else this._native.open.apply(this._native,arguments);};"
         "IOS2XHR.prototype.send=function(body){if(!this._fake){this._native.send(body);return;}var self=this;setTimeout(function(){self._status=200;self._response=authBytes();self._readyState=4;self._emit('readystatechange');self._emit('load');self._emit('loadend');},0);};"
         "IOS2XHR.prototype.abort=function(){if(this._fake){this._readyState=0;this._emit('abort');this._emit('loadend');}else this._native.abort();};IOS2XHR.prototype.setRequestHeader=function(name,value){if(!this._fake)this._native.setRequestHeader(name,value);};IOS2XHR.prototype.getAllResponseHeaders=function(){return this._fake?'Content-Type: application/octet-stream\\r\\n':this._native.getAllResponseHeaders();};IOS2XHR.prototype.getResponseHeader=function(name){return this._fake?(String(name).toLowerCase()==='content-type'?'application/octet-stream':null):this._native.getResponseHeader(name);};IOS2XHR.prototype.overrideMimeType=function(value){if(!this._fake&&this._native.overrideMimeType)this._native.overrideMimeType(value);};IOS2XHR.prototype.addEventListener=function(type,listener){if(typeof listener==='function')(this._listeners[type]||(this._listeners[type]=[])).push(listener);};IOS2XHR.prototype.removeEventListener=function(type,listener){var list=this._listeners[type]||[],index=list.indexOf(listener);if(index>=0)list.splice(index,1);};IOS2XHR.prototype._emit=function(type){var event={type:type,target:this},handler=this['on'+type];if(typeof handler==='function')handler.call(this,event);var list=(this._listeners[type]||[]).slice();for(var i=0;i<list.length;i++)list[i].call(this,event);};"
         "Object.defineProperties(IOS2XHR.prototype,{readyState:{get:function(){return this._fake?this._readyState:this._native.readyState;}},status:{get:function(){return this._fake?this._status:this._native.status;}},statusText:{get:function(){return this._fake?'OK':this._native.statusText;}},response:{get:function(){return this._fake?this._response:this._native.response;}},responseText:{get:function(){return this._fake?'':this._native.responseText;}},responseType:{get:function(){return this._fake?this._responseType:this._native.responseType;},set:function(value){this._responseType=value||'';if(!this._fake)this._native.responseType=value;}},timeout:{get:function(){return this._native.timeout;},set:function(value){this._native.timeout=value;}},withCredentials:{get:function(){return this._fake?false:this._native.withCredentials;},set:function(value){if(!this._fake)this._native.withCredentials=value;}}});IOS2XHR.UNSENT=0;IOS2XHR.OPENED=1;IOS2XHR.HEADERS_RECEIVED=2;IOS2XHR.LOADING=3;IOS2XHR.DONE=4;window.XMLHttpRequest=IOS2XHR;"
         "function extensions(gl){return {pvrtc:gl.getExtension('WEBGL_compressed_texture_pvrtc')||gl.getExtension('WEBKIT_WEBGL_compressed_texture_pvrtc'),astc:gl.getExtension('WEBGL_compressed_texture_astc')};}"
         "function parse(buffer){var view=new DataView(buffer),magic=view.getUint32(0,true);if(magic!==0x03525650)throw new Error('Only PVR v3 textures are supported');var low=view.getUint32(8,true),high=view.getUint32(12,true);if(high!==0||low>3)throw new Error('Unsupported PVR pixel format '+high+':'+low);var height=view.getUint32(24,true),width=view.getUint32(28,true),mips=Math.max(1,view.getUint32(44,true)),offset=52+view.getUint32(48,true),levels=[],w=width,h=height,bpp=(low===0||low===1)?2:4;for(var level=0;level<mips;level++){var size=bpp===2?Math.max(w,16)*Math.max(h,8)*2/8:Math.max(w,8)*Math.max(h,8)*4/8;size=Math.floor(size);if(offset+size>buffer.byteLength)throw new Error('Truncated PVR mip level '+level);levels.push({width:w,height:h,data:new Uint8Array(buffer,offset,size)});offset+=size;w=Math.max(1,w>>1);h=Math.max(1,h>>1);}return {width:width,height:height,format:low,levels:levels};}"
         "function upload(gl,buffer){var pvr=parse(buffer),ext=extensions(gl).pvrtc;if(!ext)throw new Error('PVRTC WebGL extension is unavailable');var formats=[ext.COMPRESSED_RGB_PVRTC_2BPPV1_IMG,ext.COMPRESSED_RGBA_PVRTC_2BPPV1_IMG,ext.COMPRESSED_RGB_PVRTC_4BPPV1_IMG,ext.COMPRESSED_RGBA_PVRTC_4BPPV1_IMG],texture=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,texture);for(var i=0;i<pvr.levels.length;i++){var item=pvr.levels[i];gl.compressedTexImage2D(gl.TEXTURE_2D,i,formats[pvr.format],item.width,item.height,0,item.data);}gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,pvr.levels.length>1?gl.LINEAR_MIPMAP_LINEAR:gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);return {texture:texture,width:pvr.width,height:pvr.height,format:pvr.format};}"
         "window.IOS2PVR={extensions:extensions,parse:parse,upload:upload,load:function(gl,url,options){return fetch(url,options||{}).then(function(response){if(!response.ok)throw new Error('PVR request failed: '+response.status);return response.arrayBuffer();}).then(function(buffer){return upload(gl,buffer);});}};"
         "window.addEventListener('load',function(){setTimeout(function(){var scripts=window.__IOS2_GAME_INSTANCE__.scripts||[];for(var i=0;i<scripts.length;i++){try{(0,eval)(String(scripts[i].source||'')+'\\n//# sourceURL=ios2-game/'+String(scripts[i].name||'script.js'));if(window.HSDK&&HSDK.config)HSDK.config.isOpenDebug=__ios2VerboseLogging;}catch(error){window.webkit.messageHandlers.ios2Game.postMessage({type:'error',instance:window.__IOS2_GAME_INSTANCE__.id,message:String(error&&error.stack||error)});}}window.__IOS2_GAME_INSTANCE__.scripts=null;scripts=null;},0);});"
         "window.addEventListener('error',function(event){window.webkit.messageHandlers.ios2Game.postMessage({type:'error',instance:window.__IOS2_GAME_INSTANCE__.id,message:String(event.message||'Web game error')});});"
         "window.addEventListener('unhandledrejection',function(event){window.webkit.messageHandlers.ios2Game.postMessage({type:'error',instance:window.__IOS2_GAME_INSTANCE__.id,message:String(event.reason&&event.reason.stack||event.reason||'Unhandled rejection')});});"
         "['log','warn','error'].forEach(function(level){var original=console[level];console[level]=function(){var args=Array.prototype.slice.call(arguments);if(level==='error'||__ios2VerboseLogging)try{window.webkit.messageHandlers.ios2Game.postMessage({type:'console',level:level,instance:window.__IOS2_GAME_INSTANCE__.id,message:args.map(function(value){return String(value&&value.stack||value);}).join(' ')});}catch(ignored){}return original.apply(console,args);};});"
         "})();", identityJSON];
}

@implementation IOS2GameWebView

+ (instancetype)sharedInstance
{
    if (!s_ios2GameWebView) {
        s_ios2GameWebView = [IOS2GameWebView new];
        s_ios2GameWebView.instances = [NSMutableArray array];
        s_ios2GameWebView.primaryInstanceIndex = 0;
    }
    return s_ios2GameWebView;
}

+ (void)showInstances:(NSArray<NSDictionary *> *)instances scriptsJSON:(NSString *)scriptsJSON manifestJSON:(NSString *)manifestJSON
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[self sharedInstance] showInstances:instances scriptsJSON:scriptsJSON manifestJSON:manifestJSON];
    });
}

+ (void)appendInstanceWithAccount:(NSString *)account
                         accountID:(NSString *)accountID
                      authResponse:(NSString *)authResponse
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[self sharedInstance] appendInstanceWithAccount:account
                                                 accountID:accountID
                                              authResponse:authResponse];
    });
}

+ (void)showGroupBinPicker
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[self sharedInstance] presentGroupBinPicker];
    });
}

- (void)appendInstanceWithAccount:(NSString *)account accountID:(NSString *)accountID authResponse:(NSString *)authResponse
{
    if (self.instances.count < 1 || self.instances.count >= 4 || !self.groupContainer || !self.presenter.view) return;
    self.groupContainer.hidden = NO;
    self.toolbar.hidden = NO;
    for (NSDictionary *record in self.instances) ((WKWebView *)record[@"view"]).hidden = NO;
    NSString *instanceID = NSUUID.UUID.UUIDString;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.processPool = IOS2SharedWebProcessPool();
    [configuration setURLSchemeHandler:[IOS2GameSchemeHandler sharedInstance] forURLScheme:@"ios2-game"];
    configuration.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    configuration.allowsInlineMediaPlayback = YES;
    WKUserContentController *controller = configuration.userContentController;
    [controller addScriptMessageHandler:self name:@"ios2Game"];
    WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    [configuration release];
    webView.navigationDelegate = self;
    webView.translatesAutoresizingMaskIntoConstraints = YES;
    webView.scrollView.bounces = NO;
    webView.layer.cornerRadius = 12.0;
    webView.layer.masksToBounds = YES;
    [self.groupContainer addSubview:webView];
    NSMutableDictionary *record = [@{ @"id": instanceID,
                                      @"account": account ?: @"账号",
                                      @"accountID": accountID ?: @"",
                                      @"authResponse": authResponse ?: @"",
                                      @"view": webView } mutableCopy];
    [self.instances addObject:record];
    [record release];
    [webView release];
    NSDictionary *added = self.instances.lastObject;
    [self installBootstrapForRecord:added];
    NSString *entry = [NSString stringWithFormat:@"ios2-game://app/index.html?revision=%@", kIOS2WebRuntimeRevision];
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:entry]]];
    [self layoutInstances];
    [self configureToolbar];
}

- (void)showInstances:(NSArray<NSDictionary *> *)instanceConfigs scriptsJSON:(NSString *)scriptsJSON manifestJSON:(NSString *)manifestJSON
{
    if (instanceConfigs.count < 1 || instanceConfigs.count > 4) return;
    [self closeAllInstances];
    self.scriptsJSON = scriptsJSON ?: @"[]";
    self.manifestJSON = manifestJSON ?: @"{}";
    self.presenter = IOS2GamePresenter();
    if (!self.presenter.view) return;
    [self ensureGroupContainer];
    [self ensureToolbar];
    self.toolbar.hidden = NO;
    // Four independent Cocos pages can briefly hold the encrypted bundle,
    // decoded source and GPU upload buffers at the same time. Keep the
    // detailed HSDK console bridge useful for one-page debugging, but make
    // multi-open resilient even if the launcher setting was left enabled.
    NSString *startupMode = IOS2WebStartupMode();
    self.startupGeneration = self.shutdownGeneration;
    self.startupIndex = 0;
    self.startupWaitingInstanceID = nil;

    for (NSDictionary *item in instanceConfigs) {
        NSString *accountName = [item[@"account"] isKindOfClass:[NSString class]] ? item[@"account"] : @"账号";
        NSString *authResponse = [item[@"authResponse"] isKindOfClass:[NSString class]] ? item[@"authResponse"] : @"";
        NSString *instanceID = NSUUID.UUID.UUIDString;
        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        configuration.processPool = IOS2SharedWebProcessPool();
        [configuration setURLSchemeHandler:[IOS2GameSchemeHandler sharedInstance] forURLScheme:@"ios2-game"];
        // Game settings are commonly stored through localStorage. A
        // non-persistent store discarded those values whenever the game view
        // was closed, so use the app's persistent WebKit store instead.
        configuration.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
        configuration.allowsInlineMediaPlayback = YES;
        WKUserContentController *controller = configuration.userContentController;
        [controller addScriptMessageHandler:self name:@"ios2Game"];

        WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
        [configuration release];
    #if IOS2_WEBKIT_DEBUG
        if (@available(iOS 16.4, *)) webView.inspectable = YES;
    #endif
        webView.navigationDelegate = self;
        webView.translatesAutoresizingMaskIntoConstraints = NO;
        webView.scrollView.bounces = NO;
        webView.layer.cornerRadius = 12.0;
        webView.layer.masksToBounds = YES;
        [self.groupContainer addSubview:webView];
        NSString *accountID = [item[@"accountID"] isKindOfClass:[NSString class]] ? item[@"accountID"] : @"";
        NSMutableDictionary *record = [@{ @"id": instanceID,
                                          @"account": accountName,
                                          @"accountID": accountID,
                                          @"authResponse": authResponse,
                                          @"view": webView } mutableCopy];
        [self.instances addObject:record];
        [record release];
        [webView release];
    }
    [self configureToolbar];
    [self layoutInstances];
    [self.groupContainer bringSubviewToFront:self.toolbar];
    NSLog(@"[ios2] queued %lu Web game instances at %ld FPS (startup mode=%@)",
          (unsigned long)self.instances.count, (long)IOS2WebPreferredFrameRate(), startupMode);
    if ([startupMode isEqualToString:@"serial"]) {
        [self startNextInstanceForGeneration:@(self.startupGeneration)];
    } else {
        NSUInteger generation = self.startupGeneration;
        NSUInteger index = 0;
        for (NSDictionary *record in self.instances) {
            NSTimeInterval delay = kIOS2WebParallelStartupDelay * index++;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (generation != self.shutdownGeneration || generation != self.startupGeneration) return;
                WKWebView *webView = record[@"view"];
                [self installBootstrapForRecord:record];
                NSString *entry = [NSString stringWithFormat:@"ios2-game://app/index.html?revision=%@", kIOS2WebRuntimeRevision];
                NSLog(@"[ios2] loading Web runtime revision=%@ account=%@ (parallel)",
                      kIOS2WebRuntimeRevision, record[@"account"] ?: @"账号");
                [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:entry]]];
            });
        }
    }
}

- (void)startNextInstanceForGeneration:(NSNumber *)generationNumber
{
    NSUInteger generation = generationNumber.unsignedIntegerValue;
    if (generation != self.shutdownGeneration || generation != self.startupGeneration ||
        self.startupWaitingInstanceID.length) return;
    if (self.startupIndex >= self.instances.count) return;

    NSDictionary *record = self.instances[self.startupIndex++];
    NSString *instanceID = record[@"id"];
    WKWebView *webView = record[@"view"];
    if (!instanceID.length || !webView) {
        [self startNextInstanceForGeneration:generationNumber];
        return;
    }
    self.startupWaitingInstanceID = instanceID;
    NSString *accountName = record[@"account"] ?: @"账号";
    [self installBootstrapForRecord:record];
    NSString *entry = [NSString stringWithFormat:@"ios2-game://app/index.html?revision=%@", kIOS2WebRuntimeRevision];
    NSLog(@"[ios2] loading Web runtime revision=%@ account=%@ (%lu/%lu)",
          kIOS2WebRuntimeRevision, accountName, (unsigned long)self.startupIndex,
          (unsigned long)self.instances.count);
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:entry]]];
    [self performSelector:@selector(startupTimeout:)
               withObject:@{ @"generation": @(generation), @"instance": instanceID }
               afterDelay:kIOS2WebStartupTimeout];
}

- (void)installBootstrapForRecord:(NSDictionary *)record
{
    WKWebView *webView = record[@"view"];
    if (!webView || !record[@"id"]) return;
    WKUserContentController *controller = webView.configuration.userContentController;
    NSString *source = IOS2PVRBootstrap(record[@"id"], record[@"account"] ?: @"账号",
                                        record[@"authResponse"] ?: @"", self.scriptsJSON ?: @"[]",
                                        self.manifestJSON ?: @"{}",
                                        IOS2WebVerboseLoggingEnabled() && self.instances.count == 1,
                                        self.instances.count > 1, IOS2WebStartupMode());
    WKUserScript *bootstrapScript = [[WKUserScript alloc]
        initWithSource:source
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES];
    [controller addUserScript:bootstrapScript];
    [bootstrapScript release];
}

- (void)releaseStartupPayloadForInstanceID:(NSString *)instanceID
{
    if (!instanceID.length) return;
    for (NSMutableDictionary *record in self.instances) {
        if (![record[@"id"] isEqualToString:instanceID]) continue;
        WKWebView *webView = record[@"view"];
        // The bootstrap WKUserScript contains the complete script manifest and
        // auth response. It is only needed for the first document load; keeping
        // it registered makes WebKit retain a large source string per page.
        [record removeObjectForKey:@"authResponse"];
        // Removing user scripts can synchronously touch WebKit's main-thread
        // state. Defer it so the next serial navigation can be queued without
        // making the launcher appear to stall after it reports ready.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kIOS2WebStartupPayloadCleanupDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (webView) [webView.configuration.userContentController removeAllUserScripts];
        });
        return;
    }
}

- (void)startupTimeout:(NSDictionary *)token
{
    NSUInteger generation = [token[@"generation"] unsignedIntegerValue];
    NSString *instanceID = token[@"instance"];
    if (generation != self.shutdownGeneration || generation != self.startupGeneration ||
        ![self.startupWaitingInstanceID isEqualToString:instanceID]) return;
    NSLog(@"[ios2] Web game startup timeout; continuing with next instance %@", instanceID);
    [self releaseStartupPayloadForInstanceID:instanceID];
    self.startupWaitingInstanceID = nil;
    [self startNextInstanceForGeneration:@(generation)];
}

- (NSString *)currentSingleAccountName
{
    if (self.instances.count != 1) return @"";
    NSDictionary *record = self.instances.firstObject;
    NSString *account = [record[@"account"] isKindOfClass:[NSString class]] ? record[@"account"] : @"";
    return account ?: @"";
}

- (UIButton *)toolbarButtonWithSystemName:(NSString *)systemName fallback:(NSString *)fallback action:(SEL)action
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = IOS2TokenCardRaisedColor();
    button.layer.cornerRadius = 14.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = IOS2TokenBorderColor().CGColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.20;
    button.layer.shadowRadius = 7.0;
    button.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    button.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    BOOL didSetImage = NO;
    if (@available(iOS 13.0, *)) {
        UIImage *image = [UIImage systemImageNamed:systemName];
        if (image) {
            [button setImage:image forState:UIControlStateNormal];
            button.imageView.contentMode = UIViewContentModeScaleAspectFit;
            [button setPreferredSymbolConfiguration:
                [UIImageSymbolConfiguration configurationWithPointSize:17.0
                                                                  weight:UIImageSymbolWeightSemibold]
                                             forImageInState:UIControlStateNormal];
            didSetImage = YES;
        }
    }
    if (!didSetImage) [button setTitle:fallback forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)configureToolbar
{
    BOOL single = self.instances.count == 1;
    NSString *title = single ? IOS2DisplayAccountName([self currentSingleAccountName]) :
        [NSString stringWithFormat:@"群控 %lu开", (unsigned long)self.instances.count];
    self.toolbarTitle.text = title;
    self.toolbarStatus.text = single ? @"运行中  ·  WebKit" :
        [NSString stringWithFormat:@"运行中  ·  %lu 个实例", (unsigned long)self.instances.count];
    self.toolbarSingleBottomConstraint.active = single;
    self.toolbarMultiBottomConstraint.active = !single;
    self.toolbarTitleHeightConstraint.constant = 40.0;
    self.toolbarTitleSingleTrailingConstraint.active = single;
    self.toolbarTitleMultiTrailingConstraint.active = !single;
    CGFloat controlSize = 44.0;
    for (NSLayoutConstraint *constraint in self.toolbarControlSizeConstraints) {
        constraint.constant = controlSize;
    }
    self.gearButton.hidden = !single;
    self.switchButton.hidden = NO;
    self.switchButton.enabled = YES;
    self.switchButton.alpha = 1.0;
    [self showGroupControlButton];
}

- (void)showGroupControlButton
{
    if (!self.groupControlButton) return;
    BOOL visible = self.instances.count > 1 && !self.toolbar.hidden;
    self.groupControlButton.hidden = !visible;
    if (!visible) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(tuckGroupControlButton)
                                               object:nil];
    self.groupControlCentered = NO;
    // Move the center to the right edge, leaving half the control exposed as
    // a discoverable edge affordance.
    self.groupControlCenterXConstraint.constant = self.groupContainer.bounds.size.width * 0.5;
    [self.groupContainer layoutIfNeeded];
}

- (void)tuckGroupControlButton
{
    if (!self.groupControlButton || self.groupControlButton.hidden) return;
    self.groupControlCentered = NO;
    self.groupControlCenterXConstraint.constant = self.groupContainer.bounds.size.width * 0.5;
    [UIView animateWithDuration:0.24 animations:^{ [self.groupContainer layoutIfNeeded]; }];
}

- (void)groupControlTapped
{
    if (self.instances.count < 2) return;
    self.groupControlCentered = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(tuckGroupControlButton)
                                               object:nil];
    self.groupControlCenterXConstraint.constant = 0.0;
    [UIView animateWithDuration:0.24 animations:^{ [self.groupContainer layoutIfNeeded]; }
                     completion:^(BOOL finished) {
        (void)finished;
        [self showGameMenu];
    }];
    [self performSelector:@selector(tuckGroupControlButton)
               withObject:nil
               afterDelay:kIOS2WebGroupControlIdleDelay];
}

- (void)ensureGroupContainer
{
    if (self.groupContainer.superview) {
        self.groupContainer.hidden = NO;
        return;
    }
    UIView *container = [UIView new];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.backgroundColor = UIColor.blackColor;
    container.clipsToBounds = YES;
    self.groupContainer = container;
    [self.presenter.view addSubview:container];
    [NSLayoutConstraint activateConstraints:@[
        [container.leadingAnchor constraintEqualToAnchor:self.presenter.view.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:self.presenter.view.trailingAnchor],
        [container.topAnchor constraintEqualToAnchor:self.presenter.view.topAnchor],
        [container.bottomAnchor constraintEqualToAnchor:self.presenter.view.bottomAnchor]
    ]];
    [self.presenter.view layoutIfNeeded];
    [container release];
}

- (void)ensureToolbar
{
    if (self.toolbar.superview) return;
    UIView *toolbar = [UIView new];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.backgroundColor = UIColor.clearColor;
    toolbar.userInteractionEnabled = YES;
    self.toolbar = toolbar;
    [self.groupContainer addSubview:toolbar];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    title.textColor = UIColor.whiteColor;
    title.backgroundColor = IOS2TokenCardColor();
    title.layer.cornerRadius = 18.0;
    title.layer.borderWidth = 1.0;
    title.layer.borderColor = IOS2TokenBorderColor().CGColor;
    title.layer.masksToBounds = YES;
    title.textAlignment = NSTextAlignmentLeft;
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    self.toolbarTitle = title;
    [toolbar addSubview:title];

    UILabel *status = [UILabel new];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
    status.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    status.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.86];
    status.layer.cornerRadius = 12.0;
    status.layer.borderWidth = 1.0;
    status.layer.borderColor = IOS2TokenBorderColor().CGColor;
    status.layer.masksToBounds = YES;
    status.textAlignment = NSTextAlignmentCenter;
    self.toolbarStatus = status;
    [self.groupContainer addSubview:status];

    UIButton *close = [self toolbarButtonWithSystemName:@"arrow.right" fallback:@"↪" action:@selector(showManager)];
    [toolbar addSubview:close];

    UIButton *info = [self toolbarButtonWithSystemName:@"info.circle" fallback:@"i" action:@selector(showCurrentInfo)];
    [toolbar addSubview:info];

    UIButton *account = [self toolbarButtonWithSystemName:@"person.2.fill" fallback:@"人" action:@selector(showAccountSwitch)];
    self.switchButton = account;
    [toolbar addSubview:account];

    UIButton *gear = [self toolbarButtonWithSystemName:@"gearshape.fill" fallback:@"⚙" action:@selector(showGameMenu)];
    self.gearButton = gear;
    [toolbar addSubview:gear];

    UILayoutGuide *safeArea = self.groupContainer.safeAreaLayoutGuide;
    NSLayoutConstraint *singleBottom = [toolbar.bottomAnchor constraintEqualToAnchor:safeArea.topAnchor constant:68.0];
    NSLayoutConstraint *multiBottom = [toolbar.bottomAnchor constraintEqualToAnchor:safeArea.topAnchor constant:68.0];
    self.toolbarSingleBottomConstraint = singleBottom;
    self.toolbarMultiBottomConstraint = multiBottom;
    self.toolbarTitleHeightConstraint = [title.heightAnchor constraintEqualToConstant:40.0];
    self.toolbarTitleSingleTrailingConstraint = [title.trailingAnchor constraintLessThanOrEqualToAnchor:gear.leadingAnchor constant:-12.0];
    self.toolbarTitleMultiTrailingConstraint = [title.trailingAnchor constraintLessThanOrEqualToAnchor:account.leadingAnchor constant:-10.0];
    self.toolbarTitleMultiTrailingConstraint.active = NO;
    NSLayoutConstraint *closeWidth = [close.widthAnchor constraintEqualToConstant:44.0];
    NSLayoutConstraint *closeHeight = [close.heightAnchor constraintEqualToConstant:44.0];
    NSLayoutConstraint *infoWidth = [info.widthAnchor constraintEqualToConstant:44.0];
    NSLayoutConstraint *infoHeight = [info.heightAnchor constraintEqualToConstant:44.0];
    NSLayoutConstraint *accountWidth = [account.widthAnchor constraintEqualToConstant:44.0];
    NSLayoutConstraint *accountHeight = [account.heightAnchor constraintEqualToConstant:44.0];
    NSLayoutConstraint *gearWidth = [gear.widthAnchor constraintEqualToConstant:44.0];
    NSLayoutConstraint *gearHeight = [gear.heightAnchor constraintEqualToConstant:44.0];
    self.toolbarControlSizeConstraints = @[closeWidth, closeHeight, infoWidth, infoHeight,
                                           accountWidth, accountHeight, gearWidth, gearHeight];
    [NSLayoutConstraint activateConstraints:@[
        [toolbar.leadingAnchor constraintEqualToAnchor:self.groupContainer.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.groupContainer.trailingAnchor],
        [toolbar.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8.0],
        singleBottom,
        [title.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12.0],
        [title.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        self.toolbarTitleHeightConstraint,
        self.toolbarTitleSingleTrailingConstraint,
        self.toolbarTitleMultiTrailingConstraint,
        [close.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12.0],
        [close.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        closeWidth,
        closeHeight,
        [info.trailingAnchor constraintEqualToAnchor:close.leadingAnchor constant:-6.0],
        [info.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        infoWidth,
        infoHeight,
        [account.trailingAnchor constraintEqualToAnchor:info.leadingAnchor constant:-6.0],
        [account.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        accountWidth,
        accountHeight,
        [gear.trailingAnchor constraintEqualToAnchor:account.leadingAnchor constant:-6.0],
        [gear.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        gearWidth,
        gearHeight,
        [status.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:16.0],
        [status.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-12.0],
        [status.widthAnchor constraintGreaterThanOrEqualToConstant:118.0],
        [status.heightAnchor constraintEqualToConstant:24.0]
    ]];
    [title release];
    [status release];
    [toolbar release];

    UIButton *groupButton = [self toolbarButtonWithSystemName:@"square.grid.2x2.fill"
                                                       fallback:@"▦"
                                                         action:@selector(groupControlTapped)];
    groupButton.translatesAutoresizingMaskIntoConstraints = NO;
    groupButton.tintColor = UIColor.whiteColor;
    if (@available(iOS 13.0, *)) {
        [groupButton setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightMedium]
                                             forImageInState:UIControlStateNormal];
    }
    groupButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    groupButton.backgroundColor = IOS2TokenAccentColor();
    groupButton.layer.cornerRadius = 24.0;
    groupButton.layer.shadowColor = UIColor.blackColor.CGColor;
    groupButton.layer.shadowOpacity = 0.22;
    groupButton.layer.shadowRadius = 8.0;
    groupButton.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    groupButton.accessibilityLabel = @"群控面板";
    groupButton.accessibilityIdentifier = @"ios2.group-control";
    self.groupControlButton = groupButton;
    [self.groupContainer addSubview:groupButton];
    NSLayoutConstraint *centerX = [groupButton.centerXAnchor constraintEqualToAnchor:self.groupContainer.centerXAnchor];
    self.groupControlCenterXConstraint = centerX;
    UILayoutGuide *groupSafeArea = self.groupContainer.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [groupButton.widthAnchor constraintEqualToConstant:48.0],
        [groupButton.heightAnchor constraintEqualToConstant:48.0],
        centerX,
        [groupButton.bottomAnchor constraintEqualToAnchor:groupSafeArea.bottomAnchor constant:-96.0]
    ]];
    groupButton.hidden = YES;
}

- (void)presentToolbarAlert:(UIAlertController *)alert source:(UIView *)source
{
    UIViewController *presenter = IOS2GamePresenter();
    if (!presenter) return;
    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.sourceView = source ?: self.toolbar;
        popover.sourceRect = source ? source.bounds : self.toolbar.bounds;
        popover.permittedArrowDirections = UIPopoverArrowDirectionUp;
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)loginAccount:(NSString *)account
{
    if (!account.length) return;
    IOS2LoginManagedBin(account, self.scriptsJSON ?: @"[]", self.manifestJSON ?: @"{}");
}

- (void)showGameMenu
{
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            // The floating group-control menu must remain modal on iPad. An
                                                            // action sheet is dismissed by tapping the dimmed area, and that
                                                            // same touch can then reach the account-manager view underneath.
                                                            preferredStyle:UIAlertControllerStyleAlert];
    NSString *account = [self currentSingleAccountName];
    if (self.instances.count > 1) {
        NSString *layoutTitle = [NSString stringWithFormat:@"布局切换（当前：%@）",
                                  [[[self class] layoutMode] isEqualToString:@"stacked"] ? @"堆叠布局" : @"均分布局"];
        // Keep the menu as a small control surface. The WebKit views own
        // their layout; this action only changes the persisted layout state.
        [menu addAction:[UIAlertAction actionWithTitle:layoutTitle
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            [[self class] setLayoutMode:[[[self class] layoutMode] isEqualToString:@"stacked"] ? @"split" : @"stacked"];
            [self layoutInstances];
            [self configureToolbar];
            self.groupControlCentered = YES;
            self.groupControlCenterXConstraint.constant = 0.0;
            [UIView animateWithDuration:0.2 animations:^{ [self.groupContainer layoutIfNeeded]; }];
            [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                     selector:@selector(tuckGroupControlButton)
                                                       object:nil];
            [self performSelector:@selector(tuckGroupControlButton)
                       withObject:nil
                       afterDelay:kIOS2WebGroupControlIdleDelay];
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"退出指定窗口"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self showInstanceCloseMenu]; });
        }]];
    }
    UIAlertAction *relogin = [UIAlertAction actionWithTitle:@"重新登录"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *action) {
        (void)action;
        [self loginAccount:account];
    }];
    relogin.enabled = account.length > 0;
    [menu addAction:relogin];
    [menu addAction:[UIAlertAction actionWithTitle:@"关闭"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *action) {
        (void)action;
        [self closeCurrent];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentToolbarAlert:menu source:self.instances.count > 1 ? self.groupControlButton : self.toolbar];
}

- (void)showCurrentInfo
{
    NSString *message = self.instances.count == 1 ?
        [NSString stringWithFormat:@"当前账号：%@", IOS2DisplayAccountName([self currentSingleAccountName])] :
        [NSString stringWithFormat:@"当前群控实例：%lu 个", (unsigned long)self.instances.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"账号信息"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentToolbarAlert:alert source:self.toolbar];
}

- (void)showAccountSwitch
{
    NSString *current = [self currentSingleAccountName];
    NSArray<NSDictionary *> *records = IOS2ManagedBinRecords() ?: @[];
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray arrayWithCapacity:records.count];
    for (NSDictionary *record in records) {
        NSString *name = [record[@"name"] isKindOfClass:[NSString class]] ? record[@"name"] : @"";
        if (!name.length || [name isEqualToString:current]) continue;
        [candidates addObject:record];
    }
    if (!candidates.count) {
        UIAlertController *empty = [UIAlertController alertControllerWithTitle:@"切换 bin"
                                                                       message:@"没有其他可切换的 bin 文件"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentToolbarAlert:empty source:self.switchButton];
        return;
    }

    UIAlertController *list = [UIAlertController alertControllerWithTitle:@"切换 bin"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *record in candidates) {
        NSString *name = [record[@"name"] isKindOfClass:[NSString class]] ? record[@"name"] : @"";
        NSString *title = IOS2DisplayAccountName(name);
        [list addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            (void)action;
            [self loginAccount:name];
        }]];
    }
    [list addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentToolbarAlert:list source:self.switchButton];
}

- (void)addBinToGroupTapped
{
    [self presentGroupBinPicker];
}

- (void)presentGroupBinPicker
{
    NSArray<NSDictionary *> *records = IOS2ManagedBinRecords() ?: @[];
    if (!records.count) {
        UIAlertController *empty = [UIAlertController alertControllerWithTitle:@"增加多开"
                                                                       message:@"暂无可用的 Bin 文件"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentToolbarAlert:empty source:self.emptySlot];
        return;
    }
    UIAlertController *list = [UIAlertController alertControllerWithTitle:@"选择 Bin 增加多开"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSMutableSet<NSString *> *activeNames = [NSMutableSet setWithCapacity:self.instances.count];
    for (NSDictionary *instance in self.instances) {
        NSString *active = [instance[@"account"] isKindOfClass:[NSString class]] ? instance[@"account"] : @"";
        if (active.length) [activeNames addObject:active];
    }
    for (NSDictionary *record in records) {
        NSString *name = [record[@"name"] isKindOfClass:[NSString class]] ? record[@"name"] : @"";
        if (!name.length || [activeNames containsObject:name]) continue;
        [list addAction:[UIAlertAction actionWithTitle:IOS2DisplayAccountName(name)
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            (void)action;
            Class nativeClass = NSClassFromString(@"IOS2Native");
            SEL selector = NSSelectorFromString(@"appendBinToWebGroup:");
            if ([nativeClass respondsToSelector:selector]) [nativeClass performSelector:selector withObject:name];
        }]];
    }
    [list addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentToolbarAlert:list source:self.emptySlot];
}

- (void)showInstanceCloseMenu
{
    if (self.instances.count < 2) return;
    UIAlertController *list = [UIAlertController alertControllerWithTitle:@"退出指定窗口"
                                                                  message:@"选择要退出的窗口和账号"
                                                           // Keep the nested group-control menu modal as well. This prevents a
                                                           // dismissal touch from being delivered to the manager behind it.
                                                           preferredStyle:UIAlertControllerStyleAlert];
    for (NSUInteger index = 0; index < self.instances.count; index++) {
        NSDictionary *record = self.instances[index];
        NSString *name = [record[@"account"] isKindOfClass:[NSString class]] ? record[@"account"] : @"账号";
        NSString *title = [NSString stringWithFormat:@"窗口 %lu：%@", (unsigned long)(index + 1),
                            IOS2DisplayAccountName(name)];
        [list addAction:[UIAlertAction actionWithTitle:title
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(UIAlertAction *action) {
            (void)action;
            [self closeInstanceAtIndex:index];
        }]];
    }
    [list addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentToolbarAlert:list source:self.groupControlButton];
}

- (void)closeInstanceAtIndex:(NSUInteger)index
{
    if (index >= self.instances.count) return;
    NSMutableDictionary *record = self.instances[index];
    WKWebView *view = record[@"view"];
    [view evaluateJavaScript:@"if (typeof window.__ios2ShutdownGame === 'function') window.__ios2ShutdownGame();void 0;"
             completionHandler:nil];
    [view stopLoading];
    view.navigationDelegate = nil;
    view.UIDelegate = nil;
    [view.configuration.userContentController removeScriptMessageHandlerForName:@"ios2Game"];
    [view.configuration.userContentController removeAllUserScripts];
    [view loadHTMLString:@"" baseURL:nil];
    [view removeFromSuperview];
    [record[@"accountBadge"] removeFromSuperview];
    [record[@"thumbnailOverlay"] removeFromSuperview];
    [self.instances removeObjectAtIndex:index];
    if (!self.instances.count) {
        [self closeAllInstances];
        return;
    }
    if (self.primaryInstanceIndex > index) self.primaryInstanceIndex--;
    else if (self.primaryInstanceIndex == index) self.primaryInstanceIndex = MIN(index, self.instances.count - 1);
    [self configureToolbar];
    [self layoutInstances];
}

- (void)updateAccountBadgeForRecord:(NSMutableDictionary *)record frame:(CGRect)frame
{
    // Single-account WebKit games already show the account in the toolbar;
    // reserve the in-game badge for group-control windows only.
    if (!record || !self.groupContainer || self.instances.count <= 1) return;
    UILabel *badge = record[@"accountBadge"];
    if (!badge) {
        badge = [UILabel new];
        badge.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.36];
        badge.textColor = UIColor.whiteColor;
        badge.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.lineBreakMode = NSLineBreakByTruncatingTail;
        badge.layer.cornerRadius = 8.0;
        badge.layer.masksToBounds = YES;
        badge.userInteractionEnabled = NO;
        record[@"accountBadge"] = badge;
        [badge release];
        badge = record[@"accountBadge"];
    }
    NSString *account = [record[@"account"] isKindOfClass:[NSString class]] ? record[@"account"] : @"账号";
    badge.text = IOS2DisplayAccountName(account);
    CGFloat maxWidth = MAX(24.0, frame.size.width - 12.0);
    CGFloat measured = [badge sizeThatFits:CGSizeMake(maxWidth, 24.0)].width + 18.0;
    CGFloat badgeWidth = MIN(maxWidth, MAX(70.0, measured));
    badge.frame = CGRectMake(CGRectGetMidX(frame) - badgeWidth * 0.5, frame.origin.y + 8.0,
                             badgeWidth, 24.0);
    badge.hidden = NO;
    [self.groupContainer addSubview:badge];
}

- (void)instanceThumbnailTapped:(UITapGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateEnded || self.instances.count < 2) return;
    NSUInteger index = (NSUInteger)gesture.view.tag;
    if (index >= self.instances.count || index == self.primaryInstanceIndex) return;
    self.primaryInstanceIndex = index;
    [self layoutInstances];
}

- (void)layoutInstances
{
    NSUInteger count = self.instances.count;
    if (!count || !self.groupContainer) return;
    UIView *content = self.groupContainer;
    [content layoutIfNeeded];
    CGRect bounds = content.bounds;
    // The WebKit scene is full-bleed. The native controls are an overlay and
    // must not reserve a white/header band above the game surface.
    CGFloat top = 0.0;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = MAX(1.0, CGRectGetHeight(bounds) - top);
    BOOL stacked = [[[self class] layoutMode] isEqualToString:@"stacked"] && count > 1;
    CGFloat gutter = stacked ? 12.0 : 2.0;
    [self.emptySlot removeFromSuperview];
    self.emptySlot = nil;

    // Frames keep both modes deterministic and avoid retaining an old
    // constraint graph when the user switches layouts from the floating menu.
    for (NSDictionary *record in self.instances) {
        WKWebView *view = record[@"view"];
        if (!view) continue;
        UIView *thumbnailOverlay = record[@"thumbnailOverlay"];
        thumbnailOverlay.hidden = YES;
        [thumbnailOverlay removeFromSuperview];
        UIView *accountBadge = record[@"accountBadge"];
        accountBadge.hidden = YES;
        [accountBadge removeFromSuperview];
        NSMutableArray *owned = [NSMutableArray array];
        for (NSLayoutConstraint *constraint in content.constraints) {
            if (constraint.firstItem == view || constraint.secondItem == view) [owned addObject:constraint];
        }
        if (owned.count) [content removeConstraints:owned];
        view.translatesAutoresizingMaskIntoConstraints = YES;
    }
    if (!stacked) {
        NSUInteger columns = count == 1 ? 1 : 2;
        // Keep two instances in the same 2x2 geometry as four instances.
        // The third cell is a real, interactive empty slot.
        NSUInteger slotCount = (count > 1 && count < 4) ? 4 : count;
        NSUInteger rows = (slotCount + columns - 1) / columns;
        CGFloat cellWidth = (width - gutter * (columns - 1)) / columns;
        CGFloat cellHeight = (height - gutter * (rows - 1)) / rows;
        for (NSUInteger index = 0; index < count; index++) {
            WKWebView *view = self.instances[index][@"view"];
            NSUInteger column = index % columns;
            NSUInteger row = index / columns;
            CGRect frame = CGRectMake(column * (cellWidth + gutter), top + row * (cellHeight + gutter),
                                      cellWidth, cellHeight);
            view.frame = frame;
            [self updateAccountBadgeForRecord:self.instances[index] frame:frame];
        }
        if (count > 1 && count < 4) {
            UIView *slot = [UIView new];
            slot.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
            slot.layer.cornerRadius = 12.0;
            slot.layer.borderWidth = 1.0;
            slot.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
            slot.clipsToBounds = YES;
            UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
            add.frame = CGRectMake(0.0, 0.0, cellWidth, cellHeight);
            add.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            add.tintColor = [UIColor colorWithRed:0.36 green:0.68 blue:1.0 alpha:1.0];
            [add setTitle:@"+  增加多开" forState:UIControlStateNormal];
            add.titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightMedium];
            add.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
            add.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
            add.titleLabel.textAlignment = NSTextAlignmentCenter;
            add.titleLabel.adjustsFontSizeToFitWidth = YES;
            add.titleLabel.minimumScaleFactor = 0.70;
            [add addTarget:self action:@selector(addBinToGroupTapped) forControlEvents:UIControlEventTouchUpInside];
            add.accessibilityLabel = @"从 Bin 列表增加多开";
            [slot addSubview:add];
            NSUInteger slotIndex = count;
            NSUInteger slotColumn = slotIndex % columns;
            NSUInteger slotRow = slotIndex / columns;
            slot.frame = CGRectMake(slotColumn * (cellWidth + gutter),
                                    top + slotRow * (cellHeight + gutter),
                                    cellWidth, cellHeight);
            [content addSubview:slot];
            self.emptySlot = slot;
            [slot release];
        }
    } else {
        if (self.primaryInstanceIndex >= count) self.primaryInstanceIndex = 0;
        CGFloat stackGutter = 8.0;
        NSUInteger thumbnailCount = count - 1;
        CGFloat gameAspect = width / MAX(1.0, height);
        CGFloat thumbnailWidth = (width - stackGutter * (thumbnailCount + 1)) / thumbnailCount;
        CGFloat thumbnailHeight = thumbnailWidth / MAX(0.1, gameAspect);
        CGFloat maxThumbnailHeight = height * 0.30;
        if (thumbnailHeight > maxThumbnailHeight) {
            thumbnailHeight = maxThumbnailHeight;
            thumbnailWidth = thumbnailHeight * gameAspect;
        }
        CGFloat mainY = top + thumbnailHeight + stackGutter;
        CGFloat mainAvailableHeight = MAX(1.0, CGRectGetMaxY(bounds) - mainY - stackGutter);
        CGFloat mainHeight = mainAvailableHeight;
        CGFloat mainWidth = MIN(width - stackGutter * 2.0, mainHeight * gameAspect);
        mainHeight = mainWidth / MAX(0.1, gameAspect);
        CGFloat mainX = (width - mainWidth) * 0.5;
        for (NSUInteger index = 0; index < count; index++) {
            WKWebView *view = self.instances[index][@"view"];
            if (index == self.primaryInstanceIndex) {
                CGRect frame = CGRectMake(mainX, mainY, mainWidth, mainHeight);
                view.frame = frame;
                [self updateAccountBadgeForRecord:self.instances[index] frame:frame];
            } else {
                NSUInteger thumbIndex = index < self.primaryInstanceIndex ? index : index - 1;
                CGFloat x = (width - (thumbnailWidth * thumbnailCount + stackGutter * (thumbnailCount - 1))) * 0.5 +
                            thumbIndex * (thumbnailWidth + stackGutter);
                CGRect frame = CGRectMake(x, top, thumbnailWidth, thumbnailHeight);
                view.frame = frame;
                [self updateAccountBadgeForRecord:self.instances[index] frame:frame];
                UIView *overlay = self.instances[index][@"thumbnailOverlay"];
                if (!overlay) {
                    overlay = [UIView new];
                    overlay.backgroundColor = UIColor.clearColor;
                    overlay.userInteractionEnabled = YES;
                    UITapGestureRecognizer *tap = [[[UITapGestureRecognizer alloc]
                        initWithTarget:self action:@selector(instanceThumbnailTapped:)] autorelease];
                    [overlay addGestureRecognizer:tap];
                    self.instances[index][@"thumbnailOverlay"] = overlay;
                    [overlay release];
                    overlay = self.instances[index][@"thumbnailOverlay"];
                }
                overlay.tag = (NSInteger)index;
                overlay.hidden = NO;
                overlay.frame = view.frame;
                [content addSubview:overlay];
            }
        }
        for (NSUInteger index = 0; index < count; index++) {
            if (index != self.primaryInstanceIndex) {
                [content bringSubviewToFront:self.instances[index][@"view"]];
                [content bringSubviewToFront:self.instances[index][@"thumbnailOverlay"]];
            }
        }
        [content bringSubviewToFront:self.instances[self.primaryInstanceIndex][@"view"]];
        for (NSDictionary *record in self.instances) [content bringSubviewToFront:record[@"accountBadge"]];
    }
    if (self.toolbar) [content bringSubviewToFront:self.toolbar];
    if (self.toolbarStatus) [content bringSubviewToFront:self.toolbarStatus];
    if (self.groupControlButton) [content bringSubviewToFront:self.groupControlButton];
}

- (void)showManager
{
    [IOS2GameWebView hide];
    [IOS2GameWebView closeAll];
    Class nativeClass = NSClassFromString(@"IOS2Native");
    SEL selector = NSSelectorFromString(@"webGameManagerRequested");
    if ([nativeClass respondsToSelector:selector]) [nativeClass performSelector:selector];
}

- (void)closeCurrent
{
    [self showManager];
}

+ (void)hide
{
    dispatch_async(dispatch_get_main_queue(), ^{
        IOS2GameWebView *manager = [self sharedInstance];
        manager.groupContainer.hidden = YES;
        manager.toolbar.hidden = YES;
        manager.groupControlButton.hidden = YES;
        for (NSDictionary *record in manager.instances) ((WKWebView *)record[@"view"]).hidden = YES;
        [self releaseUnusedAssetsForAllInstances];
    });
}

+ (void)closeAll
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[self sharedInstance] shutdownAndCloseInstances];
    });
}

+ (void)shutdownAndCloseAll
{
    dispatch_async(dispatch_get_main_queue(), ^{
        IOS2GameWebView *manager = [self sharedInstance];
        [manager shutdownAndCloseInstances];
    });
}

+ (void)releaseUnusedAssetsForAllInstances
{
    dispatch_async(dispatch_get_main_queue(), ^{
        IOS2GameWebView *manager = s_ios2GameWebView;
        if (!manager) return;
        NSString *script = @"if (typeof window.__ios2ReleaseUnusedAssets === 'function') "
                            "window.__ios2ReleaseUnusedAssets('native-lifecycle');void 0;";
        for (NSDictionary *record in manager.instances) {
            WKWebView *webView = record[@"view"];
            [webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
                if (error) NSLog(@"[ios2] Cocos asset cleanup request failed: %@", error.localizedDescription);
            }];
        }
    });
}

- (void)shutdownAndCloseInstances
{
    NSUInteger generation = ++self.shutdownGeneration;
    NSUInteger instanceCount = self.instances.count;
    if (!instanceCount) {
        [self closeAllInstances];
        return;
    }

    __block NSUInteger remaining = instanceCount;
    NSString *script = @"if (typeof window.__ios2ShutdownGame === 'function') "
                        "window.__ios2ShutdownGame();void 0;";
        for (NSDictionary *record in self.instances) {
        WKWebView *webView = record[@"view"];
        [webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) NSLog(@"[ios2] Cocos game shutdown request failed: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.shutdownGeneration || remaining == 0) return;
                remaining--;
                if (remaining == 0) [self finishShutdownGeneration:@(generation)];
            });
        }];
    }
    // A stalled WebContent process must not prevent logout from completing.
    [self performSelector:@selector(finishShutdownGeneration:)
               withObject:@(generation)
               afterDelay:0.5];
}

- (void)finishShutdownGeneration:(NSNumber *)generation
{
    if (generation.unsignedIntegerValue != self.shutdownGeneration) return;
    [self closeAllInstances];
}

- (void)closeAllInstances
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    self.shutdownGeneration++;
    self.startupGeneration = self.shutdownGeneration;
    self.startupIndex = 0;
    self.startupWaitingInstanceID = nil;
    [[IOS2GameSchemeHandler sharedInstance] cancelAllRequests];
    for (NSDictionary *record in self.instances) {
        WKWebView *view = record[@"view"];
        [view stopLoading];
        view.navigationDelegate = nil;
        view.UIDelegate = nil;
        view.scrollView.delegate = nil;
        [view.configuration.userContentController removeScriptMessageHandlerForName:@"ios2Game"];
        [view.configuration.userContentController removeAllUserScripts];
        [view loadHTMLString:@"" baseURL:nil];
        [view removeFromSuperview];
    }
    [self.instances removeAllObjects];
    self.primaryInstanceIndex = 0;
    [self.toolbar removeFromSuperview];
    self.toolbar = nil;
    [self.groupControlButton removeFromSuperview];
    self.groupControlButton = nil;
    self.groupControlCenterXConstraint = nil;
    [self.groupContainer removeFromSuperview];
    self.groupContainer = nil;
    self.emptySlot = nil;
    self.toolbarTitle = nil;
    [self.toolbarStatus removeFromSuperview];
    self.toolbarStatus = nil;
    self.switchButton = nil;
    self.gearButton = nil;
    self.toolbarSingleBottomConstraint = nil;
    self.toolbarMultiBottomConstraint = nil;
    self.toolbarTitleHeightConstraint = nil;
    self.toolbarTitleSingleTrailingConstraint = nil;
    self.toolbarTitleMultiTrailingConstraint = nil;
    self.toolbarControlSizeConstraints = nil;
    self.presenter = nil;
    self.scriptsJSON = nil;
    self.manifestJSON = nil;
    NSLog(@"[ios2] Web game instances closed and released");
}

+ (NSUInteger)instanceCount
{
    return [self sharedInstance].instances.count;
}

+ (NSString *)startupMode
{
    return IOS2WebStartupMode();
}

+ (void)setStartupMode:(NSString *)mode
{
    NSString *value = [mode isEqualToString:@"parallel"] ? @"parallel" : @"serial";
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:kIOS2WebStartupModeDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[ios2] WebKit startup mode selected: %@", value);
}

+ (NSString *)layoutMode
{
    NSString *mode = [[NSUserDefaults standardUserDefaults] stringForKey:kIOS2WebLayoutModeDefaultsKey];
    return [mode isEqualToString:@"stacked"] ? @"stacked" : @"split";
}

+ (void)setLayoutMode:(NSString *)mode
{
    NSString *value = [mode isEqualToString:@"stacked"] ? @"stacked" : @"split";
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:kIOS2WebLayoutModeDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[ios2] WebKit layout mode selected: %@", value);
}

+ (NSString *)accountIDForInstance:(NSString *)instanceID
{
    if (!instanceID.length) return nil;
    for (NSDictionary *record in [self sharedInstance].instances) {
        if ([record[@"id"] isEqualToString:instanceID]) {
            NSString *accountID = [record[@"accountID"] isKindOfClass:[NSString class]] ? record[@"accountID"] : nil;
            return accountID.length ? accountID : nil;
        }
    }
    return nil;
}

+ (void)sendHSDKMessage:(NSString *)action
                  extra:(NSDictionary *)extra
                errCode:(NSInteger)errCode
             toInstance:(NSString *)instanceID
{
    if (!instanceID.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        IOS2GameWebView *manager = [self sharedInstance];
        WKWebView *webView = nil;
        for (NSDictionary *record in manager.instances) {
            if ([record[@"id"] isEqualToString:instanceID]) {
                webView = record[@"view"];
                break;
            }
        }
        if (!webView) {
            NSLog(@"[ios2] HSDK response dropped; WebKit instance %@ is gone", instanceID);
            return;
        }
        NSDictionary *message = @{
            @"action": action ?: @"",
            @"meta": @{ @"errCode": @(errCode) },
            @"extra": extra ?: @{}
        };
        NSData *messageData = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
        NSString *messageJSON = [[[NSString alloc] initWithData:messageData encoding:NSUTF8StringEncoding] autorelease] ?: @"{}";
        NSData *argumentData = [NSJSONSerialization dataWithJSONObject:messageJSON options:NSJSONWritingFragmentsAllowed error:nil];
        NSString *argumentJSON = [[[NSString alloc] initWithData:argumentData encoding:NSUTF8StringEncoding] autorelease] ?: @"\"{}\"";
        NSString *script = [NSString stringWithFormat:
            @"if (window.HSDK && typeof window.HSDK.onMessage === 'function') window.HSDK.onMessage('sdk', %@);",
            argumentJSON];
        [webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) NSLog(@"[ios2] HSDK WebKit response failed action=%@ error=%@", action, error.localizedDescription);
        }];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    (void)webView; (void)navigation;
    NSLog(@"[ios2] Web game navigation finished");
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    (void)webView; (void)navigation;
    NSLog(@"[ios2] Web game navigation failed: %@", error.localizedDescription);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    (void)webView; (void)navigation;
    NSLog(@"[ios2] Web game provisional navigation failed: %@", error.localizedDescription);
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    NSLog(@"[ios2] Web game content process terminated for %@", webView.URL.absoluteString ?: @"<unknown>");
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
    (void)userContentController;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *body = message.body;
    if ([body[@"type"] isEqualToString:@"ready"]) {
        NSString *instanceID = [body[@"instance"] isKindOfClass:[NSString class]] ? body[@"instance"] : @"";
        [self releaseStartupPayloadForInstanceID:instanceID];
        if (instanceID.length && [instanceID isEqualToString:self.startupWaitingInstanceID]) {
            NSUInteger generation = self.startupGeneration;
            [NSObject cancelPreviousPerformRequestsWithTarget:self
                                                       selector:@selector(startupTimeout:)
                                                         object:nil];
            self.startupWaitingInstanceID = nil;
            NSLog(@"[ios2] Web game %@ startup settled (stable=%@ assets=%@ pending=%@ elapsed=%@ms); starting next instance",
                  instanceID, body[@"stable"] ?: @NO, body[@"assets"] ?: @"?",
                  body[@"pendingDownloads"] ?: @"?", body[@"elapsedMs"] ?: @"?");
            // Queue the next navigation immediately. The previous page's
            // bootstrap script is released asynchronously above, after this
            // load request has been handed to WebKit.
            [self startNextInstanceForGeneration:@(generation)];
        }
    } else if ([body[@"type"] isEqualToString:@"capabilities"]) {
        NSLog(@"[ios2] Web game %@ compressed textures: PVRTC=%@ ASTC=%@", body[@"instance"], body[@"pvrtc"], body[@"astc"]);
    } else if ([body[@"type"] isEqualToString:@"error"]) {
        NSLog(@"[ios2] Web game %@ error: %@", body[@"instance"], body[@"message"]);
    } else if ([body[@"type"] isEqualToString:@"console"]) {
        NSString *level = [body[@"level"] isKindOfClass:[NSString class]] ? body[@"level"] : @"log";
        if ([level isEqualToString:@"error"] || IOS2WebVerboseLoggingEnabled()) {
            NSLog(@"[ios2][web][%@][%@] %@", body[@"instance"], level, body[@"message"]);
        }
    } else if ([body[@"type"] isEqualToString:@"hsdk"]) {
        NSString *channel = [body[@"channel"] isKindOfClass:[NSString class]] ? body[@"channel"] : @"sdk";
        NSString *message = [body[@"message"] isKindOfClass:[NSString class]] ? body[@"message"] : @"{}";
        NSData *messageData = [message dataUsingEncoding:NSUTF8StringEncoding];
        id object = messageData ? [NSJSONSerialization JSONObjectWithData:messageData options:NSJSONReadingMutableContainers error:nil] : nil;
        if (![object isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[ios2] invalid WebKit HSDK request: %@", message);
            return;
        }
        NSMutableDictionary *request = [[(NSDictionary *)object mutableCopy] autorelease];
        NSString *instanceID = [body[@"instance"] isKindOfClass:[NSString class]] ? body[@"instance"] : @"";
        if (instanceID.length) request[@"__ios2Instance"] = instanceID;
        NSData *requestData = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
        NSString *requestJSON = [[[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding] autorelease] ?: @"{}";
        [SDKMessager callNative:channel withMessage:requestJSON];
    }
}

@end
