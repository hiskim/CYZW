#import "IOS2ScriptWebView.h"

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@interface IOS2ScriptWebView () <WKNavigationDelegate, WKScriptMessageHandler>
+ (instancetype)sharedInstance;
- (void)closeButtonTapped:(UIButton *)sender;
- (void)setExpanded:(BOOL)expanded;
@end

static IOS2ScriptWebView *s_ios2ScriptWebView = nil;
static WKWebView *s_ios2ScriptWebViewView = nil;
static UIButton *s_ios2ScriptWebViewClose = nil;
static NSArray *s_ios2ScriptWebViewScripts = nil;
static BOOL s_ios2ScriptWebViewExpanded = NO;

static UIViewController *IOS2ScriptWebViewPresenter(void)
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

static NSString *IOS2ScriptWebViewBootstrap(void)
{
    return @"(function(){\n"
    "'use strict';\n"
    "var nextId=0,pending={};\n"
    "function nativeCall(type,payload){var id=String(++nextId);return new Promise(function(resolve,reject){pending[id]={resolve:resolve,reject:reject};window.webkit.messageHandlers.ios2.postMessage({type:type,id:id,payload:payload||{}});});}\n"
    "window.__ios2ApplyRole=function(role){try{window.ROLE=role||{};window.ROLE.enchantMap=window.ROLE.enchantMap||{};if(typeof window.ROLE.enchantMap.get!=='function')window.ROLE.enchantMap.get=function(key){return this[key];};if(typeof signalEmit==='function')signalEmit('ROLE',window.ROLE);}catch(e){window.ROLE={};}};window.__ios2ApplyStorage=function(storage){try{if(!storage||!window.localStorage)return;for(var key in storage)if(Object.prototype.hasOwnProperty.call(storage,key))window.localStorage.setItem(key,String(storage[key]));}catch(e){}};\n"
    "window.__ios2WebViewResponse=function(message){try{var data=typeof message==='string'?JSON.parse(message):message;var item=pending[String(data.id)];if(!item)return;delete pending[String(data.id)];if(data.ok){if(data.value&&data.value.role)window.__ios2ApplyRole(data.value.role);if(data.value&&data.value.storage)window.__ios2ApplyStorage(data.value.storage);if(data.value&&typeof data.value.connected==='boolean'){socket.readyState=data.value.connected?socket.OPEN:socket.CLOSED;window.__ios2GameBridge.connected=data.value.connected;}item.resolve(data.value);}else item.reject(new Error(data.error||'native request failed'));}catch(e){try{console.error('[ios2] response bridge error',e);}catch(ignored){}}};\n"
    "window.__ios2NativeCall=nativeCall;\n"
    "window.__ios2RunSource=function(source){(0,eval)(String(source||''));};\n"
    "window.unsafeWindow=window;\n"
    "window.cc=window.cc||{};window.cc.log=window.cc.log||console.log.bind(console);window.cc.warn=window.cc.warn||console.warn.bind(console);window.cc.error=window.cc.error||console.error.bind(console);window.cc.Vec2=window.cc.Vec2||function(x,y){this.x=x||0;this.y=y||0;};window.cc.Color=window.cc.Color||function(r,g,b,a){this.r=r||0;this.g=g||0;this.b=b||0;this.a=a===undefined?255:a;};window.cc.Texture2D=window.cc.Texture2D||function(){};window.cc.director=window.cc.director||{getScene:function(){return null;}};window.cc.assetManager=window.cc.assetManager||{bundles:{get:function(){return {load:function(url,type,callback){if(callback)callback(new Error('Cocos asset bridge unavailable'));}};}}};window.cc.sys=window.cc.sys||{localStorage:window.localStorage};\n"
    "var socketListeners={};var socket={readyState:0,OPEN:1,CONNECTING:0,CLOSING:2,CLOSED:3,url:'wss://ios2-bridge.local',onopen:null,onclose:null,onerror:null,onmessage:null,sendAsync:function(request){var copy={};if(request&&typeof request==='object'){for(var key in request)if(Object.prototype.hasOwnProperty.call(request,key))copy[key]=request[key];}else copy=request||{};copy.__ios2WebViewPlainBody=true;return nativeCall('sendAsync',{request:copy});},send:function(data){return nativeCall('send',{data:data});},addEventListener:function(type,listener){if(typeof listener!=='function')return;(socketListeners[type]||(socketListeners[type]=[])).push(listener);},removeEventListener:function(type,listener){var list=socketListeners[type]||[],index=list.indexOf(listener);if(index>=0)list.splice(index,1);},dispatchEvent:function(event){try{event=event||{};var type=String(event.type||'');var list=(socketListeners[type]||[]).slice();for(var i=0;i<list.length;i++){try{list[i].call(socket,event);}catch(error){console.error('[ios2] socket listener error',error);}}var handler=socket['on'+type];if(typeof handler==='function')handler.call(socket,event);return true;}catch(error){console.error('[ios2] socket dispatch error',error);return false;}}};\n"
    "window.ws=socket;window.gameWs=socket;window.gameSocket=socket;window.WebSocketClient=socket;window.h5websocket={ws:socket};\n"
    "window.g_utils={bon:{encode:function(value){return value;},decode:function(value){return value;}}};\n"
    "var signalListeners={};var signalOn=function(name,listener,context){if(typeof listener!=='function')return listener;name=String(name);(signalListeners[name]||(signalListeners[name]=[])).push({fn:listener,ctx:context||null,once:false});return listener;};var signalOff=function(name,listener){var list=signalListeners[String(name)]||[];for(var i=list.length-1;i>=0;i--)if(!listener||list[i].fn===listener)list.splice(i,1);};var signalEmit=function(name){var list=(signalListeners[String(name)]||[]).slice(),args=Array.prototype.slice.call(arguments,1);for(var i=0;i<list.length;i++){try{list[i].fn.apply(list[i].ctx||window,args);}catch(error){console.error('[ios2] signal listener error',error);}if(list[i].once)signalOff(name,list[i].fn);}};var signals={on:signalOn,add:signalOn,addEventListener:signalOn,once:function(name,listener,context){var fn=signalOn(name,listener,context);var list=signalListeners[String(name)]||[];if(list.length)list[list.length-1].once=true;return fn;},off:signalOff,remove:signalOff,removeEventListener:signalOff,emit:signalEmit,dispatch:function(name,payload){return signalEmit(name,payload);},trigger:signalEmit};\n"
    "window.__ios2ApplySignal=function(message){try{var data=typeof message==='string'?JSON.parse(message):message;if(data&&data.name!==undefined){var args=Array.isArray(data.args)?data.args:[];signalEmit.apply(null,[String(data.name)].concat(args));}}catch(error){console.error('[ios2] signal bridge error',error);}};\n"
    "window.__ios2ModuleProxy=function(name){name=String(name||'');var target={__ios2ModuleName:name};if(typeof Proxy!=='function')return target;return new Proxy(target,{get:function(object,key){if(key==='__ios2ModuleName')return name;if(key==='then'||key==='toJSON')return undefined;if(typeof key!=='string')return object[key];return function(){return nativeCall('module',{module:name,method:key,args:Array.prototype.slice.call(arguments)});};}});};\n"
    "window.__require=function(name){if(name==='ServerData')return {ROLE:window.ROLE||{}};if(name==='GlobalSignal')return {GlobalSignal:signals};if(name==='ModuleManager')return {GET_MODULE:function(moduleName){return window.__ios2ModuleProxy(moduleName);},getModule:function(moduleName){return window.__ios2ModuleProxy(moduleName);}};return window.__ios2ModuleProxy(name);};\n"
    "window.__ios2GameBridge={socket:socket,send:function(request){return socket.sendAsync(request);},getRole:function(){return window.ROLE||null;},require:window.__require};\n"
    "window.__ios2WebViewEvent=function(message){try{var data=typeof message==='string'?JSON.parse(message):message;if(!data)return;var type=String(data.type||'message');if(type==='message'){socket.readyState=socket.OPEN;var value=data.data;var event;if(typeof MessageEvent==='function'){try{event=new MessageEvent('message',{data:value});}catch(ignored){}}if(!event)event={type:'message',data:value};socket.dispatchEvent(event);}else if(type==='signal'){if(window.__ios2ApplySignal)window.__ios2ApplySignal(data);}else if(type==='open'){socket.readyState=socket.OPEN;socket.dispatchEvent({type:'open'});}else if(type==='close'){socket.readyState=socket.CLOSED;socket.dispatchEvent({type:'close',code:Number(data.code||1000),reason:String(data.reason||'')});}else if(type==='error'){socket.dispatchEvent({type:'error',message:String(data.message||'socket error')});}}catch(error){try{console.error('[ios2] inbound socket event error',error);}catch(ignored){}}};\n"
    "(function(){var storage=window.localStorage;if(!storage||storage.__ios2PersistentBridge)return;try{var originalSet=storage.setItem.bind(storage),originalRemove=storage.removeItem.bind(storage),originalClear=storage.clear.bind(storage);storage.setItem=function(key,value){originalSet(String(key),String(value));nativeCall('storage',{action:'set',key:String(key),value:String(value)}).catch(function(){});};storage.removeItem=function(key){originalRemove(String(key));nativeCall('storage',{action:'remove',key:String(key)}).catch(function(){});};storage.clear=function(){originalClear();nativeCall('storage',{action:'clear'}).catch(function(){});};Object.defineProperty(storage,'__ios2PersistentBridge',{value:true});}catch(e){}})();\n"
    "window.__ios2BootstrapPromise=nativeCall('bootstrap',{});\n"
    "function syncNativeLayout(){try{var toggle=document.getElementById('arenaToggleBtn'),panel=document.getElementById('arenaMainPanel'),visible=function(el){if(!el)return false;var style=getComputedStyle(el),rect=el.getBoundingClientRect();return style.display!=='none'&&style.visibility!=='hidden'&&Number(style.opacity)!==0&&rect.width>1&&rect.height>1;};window.webkit.messageHandlers.ios2.postMessage({type:'layout',expanded:visible(panel),toggleVisible:visible(toggle)});}catch(e){}}\n"
    "window.__ios2SyncNativeLayout=syncNativeLayout;window.setTimeout(syncNativeLayout,0);window.setInterval(syncNativeLayout,250);if(window.MutationObserver){var root=document.documentElement;if(root)new MutationObserver(syncNativeLayout).observe(root,{subtree:true,childList:true,attributes:true,attributeFilter:['style','class','hidden']});}\n"
    "window.addEventListener('error',function(event){try{window.webkit.messageHandlers.ios2.postMessage({type:'error',message:String(event.message||'script error'),line:event.lineno||0});}catch(e){}});\n"
    "window.addEventListener('unhandledrejection',function(event){try{window.webkit.messageHandlers.ios2.postMessage({type:'error',message:String(event.reason&&event.reason.stack||event.reason||'unhandled rejection')});}catch(e){}});\n"
    "})();";
}

@implementation IOS2ScriptWebView

+ (instancetype)sharedInstance
{
    if (!s_ios2ScriptWebView) s_ios2ScriptWebView = [IOS2ScriptWebView new];
    return s_ios2ScriptWebView;
}

+ (void)showScriptsJSON:(NSString *)json
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *scripts = nil;
        NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([object isKindOfClass:[NSArray class]]) scripts = object;
        if (!scripts.count) return;
        s_ios2ScriptWebViewScripts = [scripts copy];

        UIViewController *presenter = IOS2ScriptWebViewPresenter();
        if (!presenter || !presenter.view) {
            NSLog(@"[ios2] script WebView presenter unavailable");
            return;
        }
        IOS2ScriptWebView *delegate = [self sharedInstance];
        if (!s_ios2ScriptWebViewView) {
            WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
            WKUserContentController *controller = configuration.userContentController;
            WKUserScript *bootstrap = [[WKUserScript alloc] initWithSource:IOS2ScriptWebViewBootstrap()
                                                               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                            forMainFrameOnly:YES];
            [controller addUserScript:bootstrap];
            [controller addScriptMessageHandler:delegate name:@"ios2"];
            configuration.allowsInlineMediaPlayback = YES;
            s_ios2ScriptWebViewView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
            s_ios2ScriptWebViewView.navigationDelegate = delegate;
            s_ios2ScriptWebViewView.opaque = NO;
            s_ios2ScriptWebViewView.backgroundColor = UIColor.clearColor;
            s_ios2ScriptWebViewView.scrollView.backgroundColor = UIColor.clearColor;
            s_ios2ScriptWebViewView.scrollView.alwaysBounceVertical = NO;
            s_ios2ScriptWebViewView.translatesAutoresizingMaskIntoConstraints = YES;
            s_ios2ScriptWebViewView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
        if (!s_ios2ScriptWebViewView.superview) {
            [presenter.view addSubview:s_ios2ScriptWebViewView];
        }
        if (!s_ios2ScriptWebViewClose) {
            s_ios2ScriptWebViewClose = [UIButton buttonWithType:UIButtonTypeSystem];
            s_ios2ScriptWebViewClose.translatesAutoresizingMaskIntoConstraints = NO;
            s_ios2ScriptWebViewClose.accessibilityLabel = @"关闭脚本面板";
            s_ios2ScriptWebViewClose.accessibilityIdentifier = @"ios2.script-webview-close";
            s_ios2ScriptWebViewClose.tintColor = UIColor.whiteColor;
            s_ios2ScriptWebViewClose.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.82];
            s_ios2ScriptWebViewClose.layer.cornerRadius = 19.0;
            s_ios2ScriptWebViewClose.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
            s_ios2ScriptWebViewClose.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
            if (@available(iOS 13.0, *)) {
                [s_ios2ScriptWebViewClose setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
            } else {
                [s_ios2ScriptWebViewClose setTitle:@"×" forState:UIControlStateNormal];
                s_ios2ScriptWebViewClose.titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightMedium];
            }
            [s_ios2ScriptWebViewClose addTarget:delegate action:@selector(closeButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
            [presenter.view addSubview:s_ios2ScriptWebViewClose];
            UILayoutGuide *safeArea = presenter.view.safeAreaLayoutGuide;
            [NSLayoutConstraint activateConstraints:@[
                [s_ios2ScriptWebViewClose.widthAnchor constraintEqualToConstant:38.0],
                [s_ios2ScriptWebViewClose.heightAnchor constraintEqualToConstant:38.0],
                [s_ios2ScriptWebViewClose.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8.0],
                [s_ios2ScriptWebViewClose.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-8.0]
            ]];
        }
        [delegate setExpanded:NO];
        s_ios2ScriptWebViewClose.hidden = YES;
        [presenter.view bringSubviewToFront:s_ios2ScriptWebViewView];
        [presenter.view bringSubviewToFront:s_ios2ScriptWebViewClose];
        NSString *html = @"<!doctype html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no\"><style>html,body{margin:0;padding:0;background:transparent;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,sans-serif;}*{box-sizing:border-box;}</style></head><body></body></html>";
        [s_ios2ScriptWebViewView loadHTMLString:html baseURL:[NSURL URLWithString:@"https://ios2.local/"]];
    });
}

+ (void)hide
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [s_ios2ScriptWebViewView stopLoading];
        [s_ios2ScriptWebViewView loadHTMLString:@"<!doctype html><html><body></body></html>" baseURL:nil];
        [s_ios2ScriptWebViewView removeFromSuperview];
        s_ios2ScriptWebViewExpanded = NO;
        s_ios2ScriptWebViewView.frame = CGRectZero;
        // Keep the close control attached so a later script launch can reuse
        // the same WKWebView and constraints without losing the button.
        s_ios2ScriptWebViewClose.hidden = YES;
        s_ios2ScriptWebViewScripts = nil;
    });
}

+ (void)sendResponseJSON:(NSString *)json
{
    if (!json.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!s_ios2ScriptWebViewView) return;
        NSString *script = [NSString stringWithFormat:@"if(window.__ios2WebViewResponse){window.__ios2WebViewResponse(%@);}", json];
        [s_ios2ScriptWebViewView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) NSLog(@"[ios2] script WebView response error: %@", error.localizedDescription);
        }];
    });
}

+ (void)sendEventJSON:(NSString *)json
{
    if (!json.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!s_ios2ScriptWebViewView) return;
        NSString *script = [NSString stringWithFormat:@"if(window.__ios2WebViewEvent){window.__ios2WebViewEvent(%@);}", json];
        [s_ios2ScriptWebViewView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) NSLog(@"[ios2] script WebView event error: %@", error.localizedDescription);
        }];
    });
}

+ (void)syncRoleJSON:(NSString *)json
{
    if (!json.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!s_ios2ScriptWebViewView) return;
        NSString *script = [NSString stringWithFormat:
            @"if(window.__ios2ApplyRole){window.__ios2ApplyRole(%@);}", json];
        [s_ios2ScriptWebViewView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) NSLog(@"[ios2] ROLE sync error: %@", error.localizedDescription);
        }];
    });
}

- (void)setExpanded:(BOOL)expanded
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = IOS2ScriptWebViewPresenter();
        if (!presenter || !s_ios2ScriptWebViewView) return;

        CGRect bounds = presenter.view.bounds;
        if (expanded) {
            // Keep the WKWebView bounded instead of using a full-screen
            // transparent surface. The imported panel uses vw/vh sizing, so
            // this still gives it a stable, usable viewport while leaving a
            // touchable margin around the game.
            CGFloat width = MIN(MAX(0.0, CGRectGetWidth(bounds) - 16.0), 460.0);
            CGFloat height = MAX(0.0, CGRectGetHeight(bounds) - 16.0);
            s_ios2ScriptWebViewView.frame = CGRectMake(
                (CGRectGetWidth(bounds) - width) * 0.5,
                8.0,
                width,
                height);
        } else {
            CGFloat size = 76.0;
            CGFloat top = MAX(0.0, presenter.view.safeAreaInsets.top + 6.0);
            s_ios2ScriptWebViewView.frame = CGRectMake(
                CGRectGetWidth(bounds) - size - 8.0, top, size, size);
        }

        s_ios2ScriptWebViewExpanded = expanded;
        s_ios2ScriptWebViewClose.hidden = !expanded;
        [presenter.view bringSubviewToFront:s_ios2ScriptWebViewView];
        if (expanded && s_ios2ScriptWebViewClose) {
            [presenter.view bringSubviewToFront:s_ios2ScriptWebViewClose];
        }
    });
}

- (void)closeButtonTapped:(UIButton *)sender
{
    (void)sender;
    [IOS2ScriptWebView hide];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    (void)webView; (void)navigation;
    NSArray *scripts = s_ios2ScriptWebViewScripts;
    for (NSDictionary *record in scripts) {
        NSString *name = [record[@"name"] isKindOfClass:[NSString class]] ? record[@"name"] : @"script";
        NSString *source = [record[@"source"] isKindOfClass:[NSString class]] ? record[@"source"] : @"";
        if (!source.length) continue;
        NSString *programSource = [source stringByAppendingFormat:@"\n//# sourceURL=ios2-webview/%@", name];
        NSData *sourceData = [NSJSONSerialization dataWithJSONObject:programSource options:NSJSONWritingFragmentsAllowed error:nil];
        NSString *sourceJSON = sourceData ? [[NSString alloc] initWithData:sourceData encoding:NSUTF8StringEncoding] : @"\"\"";
        NSString *program = [NSString stringWithFormat:@"(window.__ios2BootstrapPromise||Promise.resolve()).then(function(){window.__ios2RunSource(%@);});", sourceJSON];
        [s_ios2ScriptWebViewView evaluateJavaScript:program completionHandler:^(id result, NSError *error) {
            if (error) NSLog(@"[ios2] WebView script %@ failed: %@", name, error.localizedDescription);
            else NSLog(@"[ios2] WebView script %@ started", name);
        }];
    }
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
    (void)userContentController;
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *body = (NSDictionary *)message.body;
    NSString *type = [body[@"type"] isKindOfClass:[NSString class]] ? body[@"type"] : @"";
    if ([type isEqualToString:@"layout"]) {
        [self setExpanded:[body[@"expanded"] boolValue]];
        return;
    }
    if ([type isEqualToString:@"error"]) {
        NSLog(@"[ios2] WebView script error: %@", body[@"message"] ?: @"unknown error");
        return;
    }
    if ([type isEqualToString:@"bootstrap"] || [type isEqualToString:@"sendAsync"] || [type isEqualToString:@"send"] || [type isEqualToString:@"module"]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (json.length) {
            Class nativeClass = NSClassFromString(@"IOS2Native");
            SEL selector = NSSelectorFromString(@"webViewRequest:");
            if ([nativeClass respondsToSelector:selector]) {
                NSMethodSignature *signature = [nativeClass methodSignatureForSelector:selector];
                NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
                invocation.selector = selector;
                invocation.target = nativeClass;
                NSString *argument = json;
                [invocation setArgument:&argument atIndex:2];
                [invocation invoke];
            }
        }
    }
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    (void)webView; (void)navigation;
    NSLog(@"[ios2] script WebView navigation failed: %@", error.localizedDescription);
}

@end
