#import "IOS2GameWebView.h"

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <CommonCrypto/CommonDigest.h>

@interface IOS2GameSchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSURLSessionDataTask *> *tasks;
@property (nonatomic, strong) dispatch_queue_t cacheQueue;
@end

@interface IOS2GameWebView () <WKNavigationDelegate, WKScriptMessageHandler>
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *instances;
@property (nonatomic, strong) UIView *toolbar;
@property (nonatomic, strong) UIViewController *presenter;
@end

static IOS2GameWebView *s_ios2GameWebView = nil;
static IOS2GameSchemeHandler *s_ios2GameSchemeHandler = nil;

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

@implementation IOS2GameSchemeHandler

- (NSString *)keyForTask:(id<WKURLSchemeTask>)task
{
    return [NSString stringWithFormat:@"%p", task];
}

- (BOOL)finishDownloadForTask:(id<WKURLSchemeTask>)task
{
    NSString *key = [self keyForTask:task];
    @synchronized (self.tasks) {
        if (!self.tasks[key]) return NO;
        [self.tasks removeObjectForKey:key];
        return YES;
    }
}

+ (instancetype)sharedInstance
{
    if (!s_ios2GameSchemeHandler) {
        s_ios2GameSchemeHandler = [IOS2GameSchemeHandler new];
        s_ios2GameSchemeHandler.tasks = [NSMutableDictionary dictionary];
        s_ios2GameSchemeHandler.cacheQueue = dispatch_queue_create("com.xyzw.ios2.web-cache", DISPATCH_QUEUE_SERIAL);
    }
    return s_ios2GameSchemeHandler;
}

- (void)respondToTask:(id<WKURLSchemeTask>)task data:(NSData *)data url:(NSURL *)url
{
    if (!data) {
        NSLog(@"[ios2] Web resource missing: %@", url.absoluteString);
        [task didFailWithError:[NSError errorWithDomain:@"IOS2GameWebView" code:404
                                               userInfo:@{NSLocalizedDescriptionKey: @"Resource not found"}]];
        return;
    }
    NSURLResponse *response = [[NSURLResponse alloc] initWithURL:url
                                                       MIMEType:IOS2GameMIMEType(url.path)
                                          expectedContentLength:(NSInteger)data.length
                                               textEncodingName:[IOS2GameMIMEType(url.path) hasPrefix:@"text/"] ||
                                                                [url.path.pathExtension.lowercaseString isEqualToString:@"js"] ? @"utf-8" : nil];
    [task didReceiveResponse:response];
    [task didReceiveData:data];
    [task didFinish];
}

- (NSURL *)cachedFileForURL:(NSString *)remoteURL index:(NSDictionary *)index
{
    NSDictionary *files = [index[@"files"] isKindOfClass:[NSDictionary class]] ? index[@"files"] : nil;
    NSDictionary *record = [files[remoteURL] isKindOfClass:[NSDictionary class]] ? files[remoteURL] : nil;
    NSString *relativePath = [record[@"url"] isKindOfClass:[NSString class]] ? record[@"url"] : nil;
    if (!relativePath.length) return nil;
    NSURL *fileURL = [IOS2GameCacheDirectory() URLByAppendingPathComponent:relativePath];
    return [[NSFileManager defaultManager] fileExistsAtPath:fileURL.path] ? fileURL : nil;
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    (void)webView;
    NSURL *url = task.request.URL;
    if ([url.host isEqualToString:@"app"] && ![url.path hasPrefix:@"/cdn/"]) {
        NSString *name = url.lastPathComponent;
        NSDictionary *files = @{
            @"index.html": @"ios2-web-index.html",
            @"settings.js": @"settings.b2e22.js",
            @"cocos2d.js": @"ios2-web-cocos2d.js",
            @"boot.js": @"ios2-web-boot.js"
        };
        NSString *resource = files[name];
        NSString *path = nil;
        if (resource.length) {
            path = [[NSBundle mainBundle] pathForResource:resource ofType:nil inDirectory:@"src"];
        } else if ([url.path hasPrefix:@"/src/"]) {
            path = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:[url.path substringFromIndex:1]];
        } else if ([url.path hasPrefix:@"/assets/"]) {
            path = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:[url.path substringFromIndex:1]];
        }
        [self respondToTask:task data:path.length ? [NSData dataWithContentsOfFile:path] : nil url:url];
        return;
    }
    if (![url.host isEqualToString:@"cdn"] &&
        !([url.host isEqualToString:@"app"] && [url.path hasPrefix:@"/cdn/"])) {
        [self respondToTask:task data:nil url:url];
        return;
    }
    NSString *remoteURL = nil;
    if ([url.host isEqualToString:@"app"]) {
        NSString *cdnPath = [url.path substringFromIndex:[@"/cdn" length]];
        remoteURL = [@"https://xxz-xyzw-res.hortorgames.com" stringByAppendingString:cdnPath ?: @""];
        if (url.query.length) remoteURL = [remoteURL stringByAppendingFormat:@"?%@", url.query];
    } else {
        NSString *encoded = [url.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
        remoteURL = encoded.stringByRemovingPercentEncoding;
    }
    NSURL *remote = [NSURL URLWithString:remoteURL ?: @""];
    if (!remote || ![@[@"http", @"https"] containsObject:remote.scheme.lowercaseString]) {
        [self respondToTask:task data:nil url:url];
        return;
    }
    dispatch_async(self.cacheQueue, ^{
        NSURL *cacheDirectory = IOS2GameCacheDirectory();
        NSURL *indexURL = [cacheDirectory URLByAppendingPathComponent:@"cacheList.json"];
        NSData *indexData = [NSData dataWithContentsOfURL:indexURL];
        NSDictionary *index = indexData ? [NSJSONSerialization JSONObjectWithData:indexData options:0 error:nil] : nil;
        NSURL *cachedURL = [self cachedFileForURL:remoteURL index:index];
        NSData *cachedData = cachedURL ? [NSData dataWithContentsOfURL:cachedURL] : nil;
        if (cachedData.length) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self respondToTask:task data:cachedData url:url]; });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURLSessionDataTask *download = [[NSURLSession sharedSession] dataTaskWithURL:remote
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (![self finishDownloadForTask:task]) return;
                NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
                if (error || !data.length || http.statusCode < 200 || http.statusCode >= 300) {
                    NSLog(@"[ios2] Web CDN request failed: %@ status=%ld error=%@",
                          remoteURL, (long)http.statusCode, error.localizedDescription ?: @"<none>");
                    [task didFailWithError:error ?: [NSError errorWithDomain:@"IOS2GameWebView" code:http.statusCode
                                                                    userInfo:@{NSLocalizedDescriptionKey: @"CDN request failed"}]];
                    return;
                }
                dispatch_async(self.cacheQueue, ^{
                    NSFileManager *manager = [NSFileManager defaultManager];
                    NSURL *webDirectory = [IOS2GameCacheDirectory() URLByAppendingPathComponent:@"webkit" isDirectory:YES];
                    [manager createDirectoryAtURL:webDirectory withIntermediateDirectories:YES attributes:nil error:nil];
                    NSString *extension = remote.pathExtension.length ? [@"." stringByAppendingString:remote.pathExtension] : @"";
                    NSString *relativePath = [@"webkit/" stringByAppendingString:[IOS2GameSHA256(remoteURL) stringByAppendingString:extension]];
                    NSURL *fileURL = [IOS2GameCacheDirectory() URLByAppendingPathComponent:relativePath];
                    [data writeToURL:fileURL options:NSDataWritingAtomic error:nil];
                    NSData *latestData = [NSData dataWithContentsOfURL:indexURL];
                    NSMutableDictionary *latest = latestData ? [[NSJSONSerialization JSONObjectWithData:latestData options:NSJSONReadingMutableContainers error:nil] mutableCopy] : [NSMutableDictionary dictionary];
                    NSMutableDictionary *cacheFiles = [latest[@"files"] isKindOfClass:[NSDictionary class]] ? [latest[@"files"] mutableCopy] : [NSMutableDictionary dictionary];
                    cacheFiles[remoteURL] = @{ @"url": relativePath, @"bundle": @"webkit" };
                    latest[@"files"] = cacheFiles;
                    NSData *updated = [NSJSONSerialization dataWithJSONObject:latest options:0 error:nil];
                    [updated writeToURL:indexURL options:NSDataWritingAtomic error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{ [self respondToTask:task data:data url:url]; });
                });
            }];
            @synchronized (self.tasks) { self.tasks[[self keyForTask:task]] = download; }
            [download resume];
        });
    });
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task
{
    (void)webView;
    NSURLSessionDataTask *download = nil;
    @synchronized (self.tasks) {
        NSString *key = [self keyForTask:task];
        download = self.tasks[key];
        [self.tasks removeObjectForKey:key];
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

static NSString *IOS2PVRBootstrap(NSString *instanceID, NSString *accountName, NSString *authResponse, NSString *scriptsJSON, NSString *manifestJSON)
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
        @"scripts": scripts ?: @[],
        @"manifest": manifest ?: @{}
    };
    NSData *identityData = [NSJSONSerialization dataWithJSONObject:identity options:0 error:nil];
    NSString *identityJSON = [[NSString alloc] initWithData:identityData encoding:NSUTF8StringEncoding] ?: @"{}";
    return [NSString stringWithFormat:
        @"(function(){'use strict';"
         "window.__IOS2_GAME_INSTANCE__=%@;"
         "function authBytes(){var value=window.__IOS2_GAME_INSTANCE__.authResponse||'',binary=atob(value),bytes=new Uint8Array(binary.length);for(var i=0;i<binary.length;i++)bytes[i]=binary.charCodeAt(i);return bytes.buffer;}"
         "var NativeXHR=window.XMLHttpRequest;function IOS2XHR(){this._native=new NativeXHR();this._fake=false;this._listeners={};this._readyState=0;this._status=0;this._response=null;this._responseType='';var self=this;['readystatechange','load','error','timeout','abort','loadend','progress'].forEach(function(type){self._native['on'+type]=function(event){var handler=self['on'+type];if(typeof handler==='function')handler.call(self,event);var list=self._listeners[type]||[];for(var i=0;i<list.length;i++)list[i].call(self,event);};});}"
         "IOS2XHR.prototype.open=function(method,url){this._fake=/\\/login\\/authuser(?:\\?|$)/.test(String(url||''));if(this._fake){this._readyState=1;this._emit('readystatechange');}else this._native.open.apply(this._native,arguments);};"
         "IOS2XHR.prototype.send=function(body){if(!this._fake){this._native.send(body);return;}var self=this;setTimeout(function(){self._status=200;self._response=authBytes();self._readyState=4;self._emit('readystatechange');self._emit('load');self._emit('loadend');},0);};"
         "IOS2XHR.prototype.abort=function(){if(this._fake){this._readyState=0;this._emit('abort');this._emit('loadend');}else this._native.abort();};IOS2XHR.prototype.setRequestHeader=function(name,value){if(!this._fake)this._native.setRequestHeader(name,value);};IOS2XHR.prototype.getAllResponseHeaders=function(){return this._fake?'Content-Type: application/octet-stream\\r\\n':this._native.getAllResponseHeaders();};IOS2XHR.prototype.getResponseHeader=function(name){return this._fake?(String(name).toLowerCase()==='content-type'?'application/octet-stream':null):this._native.getResponseHeader(name);};IOS2XHR.prototype.overrideMimeType=function(value){if(!this._fake&&this._native.overrideMimeType)this._native.overrideMimeType(value);};IOS2XHR.prototype.addEventListener=function(type,listener){if(typeof listener==='function')(this._listeners[type]||(this._listeners[type]=[])).push(listener);};IOS2XHR.prototype.removeEventListener=function(type,listener){var list=this._listeners[type]||[],index=list.indexOf(listener);if(index>=0)list.splice(index,1);};IOS2XHR.prototype._emit=function(type){var event={type:type,target:this},handler=this['on'+type];if(typeof handler==='function')handler.call(this,event);var list=(this._listeners[type]||[]).slice();for(var i=0;i<list.length;i++)list[i].call(this,event);};"
         "Object.defineProperties(IOS2XHR.prototype,{readyState:{get:function(){return this._fake?this._readyState:this._native.readyState;}},status:{get:function(){return this._fake?this._status:this._native.status;}},statusText:{get:function(){return this._fake?'OK':this._native.statusText;}},response:{get:function(){return this._fake?this._response:this._native.response;}},responseText:{get:function(){return this._fake?'':this._native.responseText;}},responseType:{get:function(){return this._fake?this._responseType:this._native.responseType;},set:function(value){this._responseType=value||'';if(!this._fake)this._native.responseType=value;}},timeout:{get:function(){return this._native.timeout;},set:function(value){this._native.timeout=value;}},withCredentials:{get:function(){return this._fake?false:this._native.withCredentials;},set:function(value){if(!this._fake)this._native.withCredentials=value;}}});IOS2XHR.UNSENT=0;IOS2XHR.OPENED=1;IOS2XHR.HEADERS_RECEIVED=2;IOS2XHR.LOADING=3;IOS2XHR.DONE=4;window.XMLHttpRequest=IOS2XHR;"
         "function extensions(gl){return {pvrtc:gl.getExtension('WEBGL_compressed_texture_pvrtc')||gl.getExtension('WEBKIT_WEBGL_compressed_texture_pvrtc'),astc:gl.getExtension('WEBGL_compressed_texture_astc')};}"
         "function parse(buffer){var view=new DataView(buffer),magic=view.getUint32(0,true);if(magic!==0x03525650)throw new Error('Only PVR v3 textures are supported');var low=view.getUint32(8,true),high=view.getUint32(12,true);if(high!==0||low>3)throw new Error('Unsupported PVR pixel format '+high+':'+low);var height=view.getUint32(24,true),width=view.getUint32(28,true),mips=Math.max(1,view.getUint32(44,true)),offset=52+view.getUint32(48,true),levels=[],w=width,h=height,bpp=(low===0||low===1)?2:4;for(var level=0;level<mips;level++){var size=bpp===2?Math.max(w,16)*Math.max(h,8)*2/8:Math.max(w,8)*Math.max(h,8)*4/8;size=Math.floor(size);if(offset+size>buffer.byteLength)throw new Error('Truncated PVR mip level '+level);levels.push({width:w,height:h,data:new Uint8Array(buffer,offset,size)});offset+=size;w=Math.max(1,w>>1);h=Math.max(1,h>>1);}return {width:width,height:height,format:low,levels:levels};}"
         "function upload(gl,buffer){var pvr=parse(buffer),ext=extensions(gl).pvrtc;if(!ext)throw new Error('PVRTC WebGL extension is unavailable');var formats=[ext.COMPRESSED_RGB_PVRTC_2BPPV1_IMG,ext.COMPRESSED_RGBA_PVRTC_2BPPV1_IMG,ext.COMPRESSED_RGB_PVRTC_4BPPV1_IMG,ext.COMPRESSED_RGBA_PVRTC_4BPPV1_IMG],texture=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,texture);for(var i=0;i<pvr.levels.length;i++){var item=pvr.levels[i];gl.compressedTexImage2D(gl.TEXTURE_2D,i,formats[pvr.format],item.width,item.height,0,item.data);}gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,pvr.levels.length>1?gl.LINEAR_MIPMAP_LINEAR:gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);return {texture:texture,width:pvr.width,height:pvr.height,format:pvr.format};}"
         "window.IOS2PVR={extensions:extensions,parse:parse,upload:upload,load:function(gl,url,options){return fetch(url,options||{}).then(function(response){if(!response.ok)throw new Error('PVR request failed: '+response.status);return response.arrayBuffer();}).then(function(buffer){return upload(gl,buffer);});}};"
         "window.addEventListener('load',function(){setTimeout(function(){var scripts=window.__IOS2_GAME_INSTANCE__.scripts||[];for(var i=0;i<scripts.length;i++){try{(0,eval)(String(scripts[i].source||'')+'\\n//# sourceURL=ios2-game/'+String(scripts[i].name||'script.js'));}catch(error){window.webkit.messageHandlers.ios2Game.postMessage({type:'error',instance:window.__IOS2_GAME_INSTANCE__.id,message:String(error&&error.stack||error)});}}},0);});"
         "window.addEventListener('DOMContentLoaded',function(){var canvas=document.querySelector('canvas'),gl=canvas&&(canvas.getContext('webgl2')||canvas.getContext('webgl')||canvas.getContext('experimental-webgl')),support=gl?extensions(gl):{};window.webkit.messageHandlers.ios2Game.postMessage({type:'capabilities',instance:window.__IOS2_GAME_INSTANCE__.id,pvrtc:!!support.pvrtc,astc:!!support.astc});});"
         "window.addEventListener('error',function(event){window.webkit.messageHandlers.ios2Game.postMessage({type:'error',instance:window.__IOS2_GAME_INSTANCE__.id,message:String(event.message||'Web game error')});});"
         "window.addEventListener('unhandledrejection',function(event){window.webkit.messageHandlers.ios2Game.postMessage({type:'error',instance:window.__IOS2_GAME_INSTANCE__.id,message:String(event.reason&&event.reason.stack||event.reason||'Unhandled rejection')});});"
         "['log','warn','error'].forEach(function(level){var original=console[level];console[level]=function(){var args=Array.prototype.slice.call(arguments);try{window.webkit.messageHandlers.ios2Game.postMessage({type:'console',level:level,instance:window.__IOS2_GAME_INSTANCE__.id,message:args.map(function(value){return String(value&&value.stack||value);}).join(' ')});}catch(ignored){}return original.apply(console,args);};});"
         "})();", identityJSON];
}

@implementation IOS2GameWebView

+ (instancetype)sharedInstance
{
    if (!s_ios2GameWebView) {
        s_ios2GameWebView = [IOS2GameWebView new];
        s_ios2GameWebView.instances = [NSMutableArray array];
    }
    return s_ios2GameWebView;
}

+ (void)showInstances:(NSArray<NSDictionary *> *)instances scriptsJSON:(NSString *)scriptsJSON manifestJSON:(NSString *)manifestJSON
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[self sharedInstance] showInstances:instances scriptsJSON:scriptsJSON manifestJSON:manifestJSON];
    });
}

- (void)showInstances:(NSArray<NSDictionary *> *)instanceConfigs scriptsJSON:(NSString *)scriptsJSON manifestJSON:(NSString *)manifestJSON
{
    if (instanceConfigs.count < 1 || instanceConfigs.count > 4) return;
    [self closeAllInstances];
    self.presenter = IOS2GamePresenter();
    if (!self.presenter.view) return;
    [self ensureToolbar];
    self.toolbar.hidden = NO;

    for (NSDictionary *item in instanceConfigs) {
        NSString *accountName = [item[@"account"] isKindOfClass:[NSString class]] ? item[@"account"] : @"账号";
        NSString *authResponse = [item[@"authResponse"] isKindOfClass:[NSString class]] ? item[@"authResponse"] : @"";
        NSString *instanceID = NSUUID.UUID.UUIDString;
        WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
        [configuration setURLSchemeHandler:[IOS2GameSchemeHandler sharedInstance] forURLScheme:@"ios2-game"];
        configuration.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
        configuration.allowsInlineMediaPlayback = YES;
        WKUserContentController *controller = configuration.userContentController;
        [controller addScriptMessageHandler:self name:@"ios2Game"];
        [controller addUserScript:[[WKUserScript alloc]
            initWithSource:IOS2PVRBootstrap(instanceID, accountName, authResponse, scriptsJSON, manifestJSON)
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
            forMainFrameOnly:YES]];

        WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    #if IOS2_WEBKIT_DEBUG
        if (@available(iOS 16.4, *)) webView.inspectable = YES;
    #endif
        webView.navigationDelegate = self;
        webView.translatesAutoresizingMaskIntoConstraints = NO;
        webView.scrollView.bounces = NO;
        [self.presenter.view addSubview:webView];
        [self.instances addObject:@{ @"id": instanceID, @"account": accountName, @"view": webView }];
        [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"ios2-game://app/index.html"]]];
    }
    [self layoutInstances];
    [self.presenter.view bringSubviewToFront:self.toolbar];
    NSLog(@"[ios2] started %lu Web game instances", (unsigned long)self.instances.count);
}

- (void)ensureToolbar
{
    if (self.toolbar.superview) return;
    UIView *toolbar = [UIView new];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.96];
    self.toolbar = toolbar;
    [self.presenter.view addSubview:toolbar];

    UIButton *manager = [UIButton buttonWithType:UIButtonTypeSystem];
    manager.translatesAutoresizingMaskIntoConstraints = NO;
    [manager setTitle:@"账号" forState:UIControlStateNormal];
    [manager addTarget:self action:@selector(showManager) forControlEvents:UIControlEventTouchUpInside];
    [toolbar addSubview:manager];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeCurrent) forControlEvents:UIControlEventTouchUpInside];
    [toolbar addSubview:close];

    UILayoutGuide *safeArea = self.presenter.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [toolbar.leadingAnchor constraintEqualToAnchor:self.presenter.view.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.presenter.view.trailingAnchor],
        [toolbar.topAnchor constraintEqualToAnchor:self.presenter.view.topAnchor],
        [toolbar.bottomAnchor constraintEqualToAnchor:safeArea.topAnchor constant:42.0],
        [manager.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:8.0],
        [manager.bottomAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:-4.0],
        [manager.widthAnchor constraintEqualToConstant:52.0],
        [manager.heightAnchor constraintEqualToConstant:34.0],
        [close.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-8.0],
        [close.bottomAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:-4.0],
        [close.widthAnchor constraintEqualToConstant:52.0],
        [close.heightAnchor constraintEqualToConstant:34.0]
    ]];
}

- (void)layoutInstances
{
    NSUInteger count = self.instances.count;
    UIView *content = self.presenter.view;
    WKWebView *first = self.instances[0][@"view"];
    if (count == 1) {
        [NSLayoutConstraint activateConstraints:@[
            [first.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [first.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [first.topAnchor constraintEqualToAnchor:self.toolbar.bottomAnchor],
            [first.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
        ]];
        return;
    }
    WKWebView *second = self.instances[1][@"view"];
    if (count == 2) {
        [NSLayoutConstraint activateConstraints:@[
            [first.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [first.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [first.topAnchor constraintEqualToAnchor:self.toolbar.bottomAnchor],
            [first.bottomAnchor constraintEqualToAnchor:content.centerYAnchor],
            [second.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [second.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [second.topAnchor constraintEqualToAnchor:first.bottomAnchor],
            [second.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
        ]];
        return;
    }
    WKWebView *third = self.instances[2][@"view"];
    [NSLayoutConstraint activateConstraints:@[
        [first.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [first.topAnchor constraintEqualToAnchor:self.toolbar.bottomAnchor],
        [first.bottomAnchor constraintEqualToAnchor:content.centerYAnchor],
        [second.topAnchor constraintEqualToAnchor:self.toolbar.bottomAnchor],
        [second.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [second.bottomAnchor constraintEqualToAnchor:content.centerYAnchor],
        [first.trailingAnchor constraintEqualToAnchor:second.leadingAnchor],
        [first.widthAnchor constraintEqualToAnchor:second.widthAnchor],
        [third.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [third.topAnchor constraintEqualToAnchor:first.bottomAnchor],
        [third.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
    ]];
    if (count == 3) {
        [third.trailingAnchor constraintEqualToAnchor:content.trailingAnchor].active = YES;
        return;
    }
    WKWebView *fourth = self.instances[3][@"view"];
    [NSLayoutConstraint activateConstraints:@[
        [fourth.topAnchor constraintEqualToAnchor:second.bottomAnchor],
        [fourth.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [fourth.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [third.trailingAnchor constraintEqualToAnchor:fourth.leadingAnchor],
        [third.widthAnchor constraintEqualToAnchor:fourth.widthAnchor]
    ]];
}

- (void)showManager
{
    [IOS2GameWebView hide];
    Class nativeClass = NSClassFromString(@"IOS2Native");
    SEL selector = NSSelectorFromString(@"webGameManagerRequested");
    if ([nativeClass respondsToSelector:selector]) [nativeClass performSelector:selector];
}

- (void)closeCurrent
{
    [IOS2GameWebView closeAll];
    [self showManager];
}

+ (void)hide
{
    dispatch_async(dispatch_get_main_queue(), ^{
        IOS2GameWebView *manager = [self sharedInstance];
        manager.toolbar.hidden = YES;
        for (NSDictionary *record in manager.instances) ((WKWebView *)record[@"view"]).hidden = YES;
    });
}

+ (void)closeAll
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[self sharedInstance] closeAllInstances];
    });
}

- (void)closeAllInstances
{
    for (NSDictionary *record in self.instances) {
        WKWebView *view = record[@"view"];
        [view stopLoading];
        [view.configuration.userContentController removeScriptMessageHandlerForName:@"ios2Game"];
        [view removeFromSuperview];
    }
    [self.instances removeAllObjects];
    [self.toolbar removeFromSuperview];
    self.toolbar = nil;
}

+ (NSUInteger)instanceCount
{
    return [self sharedInstance].instances.count;
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
    if ([body[@"type"] isEqualToString:@"capabilities"]) {
        NSLog(@"[ios2] Web game %@ compressed textures: PVRTC=%@ ASTC=%@", body[@"instance"], body[@"pvrtc"], body[@"astc"]);
    } else if ([body[@"type"] isEqualToString:@"error"]) {
        NSLog(@"[ios2] Web game %@ error: %@", body[@"instance"], body[@"message"]);
    } else if ([body[@"type"] isEqualToString:@"console"]) {
        NSLog(@"[ios2][web][%@][%@] %@", body[@"instance"], body[@"level"], body[@"message"]);
    }
}

@end