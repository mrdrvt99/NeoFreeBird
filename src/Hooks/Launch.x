//
//  Launch.x
//  NeoFreeBird
//

#import "HookHelpers.h"


// Make a blue color that's 1d9bf0
static UIColor* twitterColor(void) {
    static UIColor* color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithRed:29.0/255.0
                                green:155.0/255.0
                                 blue:240.0/255.0
                                alpha:1.0];
    });
    return color;
}

%hook T1AnimatedLaunchScreenView
-(void)layoutSubviews {
    %orig;
    for (UIView *v in self.subviews) {
        v.backgroundColor = twitterColor();
    }
    self.layer.backgroundColor = twitterColor().CGColor;
    for (CALayer *layer in self.layer.sublayers) {
        layer.backgroundColor = twitterColor().CGColor;
    }
}


%end