/****************************************************************************
 Copyright (c) 2013      cocos2d-x.org
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

#import "RootViewController.h"
#import "cocos2d.h"

#include "platform/CCApplication.h"
#include "platform/ios/CCEAGLView-ios.h"

static NSString * const kIOS2FrameRateDefaultsKey = @"ios2.preferredFrameRate";
static NSString * const kIOS2ShowFPSDefaultsKey = @"ios2.showFPS";

@interface RootViewController ()
@property (nonatomic, strong) UIButton *performanceButton;
@end


@implementation RootViewController

/*
// The designated initializer.  Override if you create the controller programmatically and want to perform customization that is not appropriate for viewDidLoad.
- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
if ((self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil])) {
// Custom initialization
}
return self;
}
*/

// Implement loadView to create a view hierarchy programmatically, without using a nib.
- (void)loadView {
    // Set EAGLView as view of RootViewController
    self.view = (__bridge CCEAGLView *)cocos2d::Application::getInstance()->getView();
}

// Implement viewDidLoad to do additional setup after loading the view, typically from a nib.
- (void)viewDidLoad {
    [super viewDidLoad];
}

- (NSInteger)preferredFrameRate
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

- (void)applyFrameRate:(NSInteger)frameRate
{
    [[NSUserDefaults standardUserDefaults] setInteger:frameRate forKey:kIOS2FrameRateDefaultsKey];
    NSLog(@"[ios2] performance frame rate selected: %ld", (long)frameRate);
    cocos2d::Application *application = cocos2d::Application::getInstance();
    if (application) application->setPreferredFramesPerSecond((int)frameRate);
}

- (void)setFPSVisible:(BOOL)visible
{
    [[NSUserDefaults standardUserDefaults] setBool:visible forKey:kIOS2ShowFPSDefaultsKey];
    NSLog(@"[ios2] performance FPS display: %@", visible ? @"on" : @"off");
    cocos2d::Application *application = cocos2d::Application::getInstance();
    if (application) application->setDisplayStats(visible);
}

- (void)installPerformanceControls
{
    // CCEAGLView owns the game's touch stream. Put this UIKit control on the
    // application window instead, so Cocos cannot intercept its taps.
    UIWindow *window = self.view.window;
    if (!window) return;

    if (self.performanceButton) {
        [window bringSubviewToFront:self.performanceButton];
        return;
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = @"帧率设置";
    button.accessibilityHint = @"打开帧率显示和限帧设置";
    button.accessibilityIdentifier = @"ios2.performance-settings";
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.55];
    button.layer.cornerRadius = 21.0;
    button.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;

    if (@available(iOS 13.0, *)) {
        [button setImage:[UIImage systemImageNamed:@"speedometer"] forState:UIControlStateNormal];
    } else {
        [button setTitle:@"FPS" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    }
    [button addTarget:self action:@selector(showPerformanceMenu:) forControlEvents:UIControlEventTouchUpInside];
    [window addSubview:button];
    self.performanceButton = button;

    UILayoutGuide *safeArea = window.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:42.0],
        [button.heightAnchor constraintEqualToConstant:42.0],
        [button.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:6.0],
        [button.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-6.0],
    ]];
    [window bringSubviewToFront:button];
    NSLog(@"[ios2] performance control installed on application window");
}

- (void)showPerformanceMenu:(UIButton *)sender
{
    NSLog(@"[ios2] performance control tapped");
    NSInteger currentFrameRate = [self preferredFrameRate];
    BOOL showFPS = [[NSUserDefaults standardUserDefaults] boolForKey:kIOS2ShowFPSDefaultsKey];
    NSString *currentText = currentFrameRate == 0 ? @"跟随系统" : [NSString stringWithFormat:@"%ld FPS", (long)currentFrameRate];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"性能设置"
                                                                   message:[NSString stringWithFormat:@"当前帧率：%@", currentText]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    NSString *statsTitle = showFPS ? @"隐藏 FPS" : @"显示 FPS";
    [menu addAction:[UIAlertAction actionWithTitle:statsTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setFPSVisible:!showFPS];
    }]];

    NSArray<NSNumber *> *frameRates = @[ @0, @15, @24, @30, @45, @60 ];
    for (NSNumber *value in frameRates) {
        NSInteger frameRate = value.integerValue;
        NSString *title = frameRate == 0 ? @"跟随系统" : [NSString stringWithFormat:@"%ld FPS", (long)frameRate];
        if (frameRate == currentFrameRate) title = [@"当前：" stringByAppendingString:title];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self applyFrameRate:frameRate];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    (void)sender;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // FPS preferences remain available from the in-game configuration page.
    // Do not install a second UIKit floating button here: it occupies the
    // same top-right touch area as the imported script's floating ball.
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}


// For ios6, use supportedInterfaceOrientations & shouldAutorotate instead
#ifdef __IPHONE_6_0
- (NSUInteger) supportedInterfaceOrientations{
    return UIInterfaceOrientationMaskPortrait;
}
#endif

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationPortrait;
}

- (BOOL) shouldAutorotate {
    return YES;
}

//fix not hide status on ios7
- (BOOL)prefersStatusBarHidden {
    return YES;
}

// Controls the application's preferred home indicator auto-hiding when this view controller is shown.
- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (void)didReceiveMemoryWarning {
    // Releases the view if it doesn't have a superview.
    [super didReceiveMemoryWarning];

    // Release any cached data, images, etc that aren't in use.
}


@end
