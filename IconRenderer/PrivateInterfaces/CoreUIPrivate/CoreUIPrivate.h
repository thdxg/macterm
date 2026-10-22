// The three CoreUI (private framework) classes `macterm-icon-renderer` uses to
// read the app icon's layer stack out of a compiled asset catalog. Declared by
// hand: CoreUI ships no headers. The selectors are the ones the macOS 27 cache
// exports (checked with the ObjC runtime); a change makes the helper fail, and
// the app keeps the bundled icon. See IconRenderer/main.swift.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CUINamedLookup : NSObject
@end

/// One appearance of a layered (`.icon`) app icon. IconRendering's
/// `makeIcon()` turns it into the `Icon` model.
@interface CUINamedIconLayerStack : CUINamedLookup
@property (readonly) CGSize size;
@end

@interface CUICatalog : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
/// scale 1, idiom 0, subtype 0, gamut 0 and an appearance name of
/// `NSAppearanceNameAqua` or `NSAppearanceNameDarkAqua` find a macOS app icon;
/// scale 2 or a nil appearance find nothing.
- (nullable CUINamedIconLayerStack *)iconLayerStackWithName:(NSString *)name
                                                scaleFactor:(double)scale
                                                deviceIdiom:(long long)idiom
                                              deviceSubtype:(unsigned long long)subtype
                                               displayGamut:(unsigned long long)gamut
                                             appearanceName:(nullable NSString *)appearanceName
                                                     locale:(nullable NSString *)locale;
@end

NS_ASSUME_NONNULL_END
