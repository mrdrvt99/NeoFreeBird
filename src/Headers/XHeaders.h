#import <SafariServices/SafariServices.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@interface XDSButtonContentElement : NSObject
+ (id)labelWithText:(id)text font:(id)font color:(id)color;
@end

// Builds and caches the design system's fonts.
@interface XFontCatalog : NSObject
+ (UIFont*)tabularDigitsFontOfSize:(CGFloat)size weight:(UIFontWeight)weight;
+ (void)resetCachedFonts;
@end
