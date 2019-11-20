/* Functions for GUI implemented with Cocoa AppKit on macOS.
   Copyright (C) 2008-2019  YAMAMOTO Mitsuharu

This file is part of GNU Emacs Mac port.

GNU Emacs Mac port is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs Mac port is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs Mac port.  If not, see <https://www.gnu.org/licenses/>.  */

#include <config.h>
#include "lisp.h"
#include "blockinput.h"

#include "macterm.h"

#include <sys/socket.h>

#include "character.h"
#include "frame.h"
#include "dispextern.h"
#include "fontset.h"
#include "termhooks.h"
#include "buffer.h"
#include "window.h"
#include "keyboard.h"
#include "keymap.h"
#include "macfont.h"
#include "menu.h"
#include "atimer.h"
#include "regex.h"

#import "macappkit.h"
#import <objc/runtime.h>

#if USE_ARC
#define MRC_RETAIN(receiver)		((id) (receiver))
#define MRC_RELEASE(receiver)
#define MRC_AUTORELEASE(receiver)	((id) (receiver))
#define CF_BRIDGING_RETAIN		CFBridgingRetain
#define CF_BRIDGING_RELEASE		CFBridgingRelease
#else
#define MRC_RETAIN(receiver)		[(receiver) retain]
#define MRC_RELEASE(receiver)		[(receiver) release]
#define MRC_AUTORELEASE(receiver)	[(receiver) autorelease]
#define __bridge
static inline CFTypeRef
CF_BRIDGING_RETAIN (id X)
{
  return X ? CFRetain ((CFTypeRef) X) : NULL;
}
static inline id
CF_BRIDGING_RELEASE (CFTypeRef X)
{
  return [(id)(X) autorelease];
}
#endif
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1090
#define CF_AUTORELEASE	CFAutorelease
#else
static inline CFTypeRef
CF_AUTORELEASE (CFTypeRef X)
{
  id __autoreleasing result = CF_BRIDGING_RELEASE (X);

  return (__bridge CFTypeRef) result;
}
#endif

/************************************************************************
			       General
 ************************************************************************/

enum {
  ANY_MOUSE_EVENT_MASK = (NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp
			  | NSEventMaskRightMouseDown | NSEventMaskRightMouseUp
			  | NSEventMaskMouseMoved
			  | NSEventMaskLeftMouseDragged
			  | NSEventMaskRightMouseDragged
			  | NSEventMaskMouseEntered | NSEventMaskMouseExited
			  | NSEventMaskScrollWheel
			  | NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp
			  | NSEventMaskOtherMouseDragged),
  ANY_MOUSE_DOWN_EVENT_MASK = (NSEventMaskLeftMouseDown
			       | NSEventMaskRightMouseDown
			       | NSEventMaskOtherMouseDown),
  ANY_MOUSE_UP_EVENT_MASK = (NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp
			     | NSEventMaskOtherMouseUp)
};

enum {
  ANY_KEY_MODIFIER_FLAGS_MASK = (NSEventModifierFlagCapsLock
				 | NSEventModifierFlagShift
				 | NSEventModifierFlagControl
				 | NSEventModifierFlagOption
				 | NSEventModifierFlagCommand
				 | NSEventModifierFlagNumericPad
				 | NSEventModifierFlagHelp
				 | NSEventModifierFlagFunction)
};

#define CFOBJECT_TO_LISP_FLAGS_FOR_EVENT			\
  (CFOBJECT_TO_LISP_WITH_TAG					\
   | CFOBJECT_TO_LISP_DONT_DECODE_STRING			\
   | CFOBJECT_TO_LISP_DONT_DECODE_DICTIONARY_KEY)

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1090
#define NS_STACK_VIEW	NSStackView
#else
#define NS_STACK_VIEW	(NSClassFromString (@"NSStackView"))
#endif

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1090
#define NS_APPEARANCE	NSAppearance
#define NS_APPEARANCE_NAME_AQUA	NSAppearanceNameAqua
#else
#define NS_APPEARANCE	(NSClassFromString (@"NSAppearance"))
#define NS_APPEARANCE_NAME_AQUA	(@"NSAppearanceNameAqua")
#endif

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
#define NS_APPEARANCE_NAME_VIBRANT_LIGHT	NSAppearanceNameVibrantLight
#define NS_APPEARANCE_NAME_VIBRANT_DARK		NSAppearanceNameVibrantDark
#else
#define NS_APPEARANCE_NAME_VIBRANT_LIGHT (@"NSAppearanceNameVibrantLight")
#define NS_APPEARANCE_NAME_VIBRANT_DARK	(@"NSAppearanceNameVibrantDark")
#endif

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101300
#define NS_TOUCH_BAR	NSTouchBar
#define NS_CUSTOM_TOUCH_BAR_ITEM NSCustomTouchBarItem
#define NS_CANDIDATE_LIST_TOUCH_BAR_ITEM	NSCandidateListTouchBarItem
#define NS_TOUCH_BAR_ITEM_IDENTIFIER_CHARACTER_PICKER	\
  NSTouchBarItemIdentifierCharacterPicker
#define NS_TOUCH_BAR_ITEM_IDENTIFIER_CANDIDATE_LIST \
  NSTouchBarItemIdentifierCandidateList
#else
#define NS_TOUCH_BAR	(NSClassFromString (@"NSTouchBar"))
#define NS_CUSTOM_TOUCH_BAR_ITEM (NSClassFromString (@"NSCustomTouchBarItem"))
#define NS_CANDIDATE_LIST_TOUCH_BAR_ITEM \
  (NSClassFromString (@"NSCandidateListTouchBarItem"))
#define NS_TOUCH_BAR_ITEM_IDENTIFIER_CHARACTER_PICKER \
  (@"NSTouchBarItemIdentifierCharacterPicker")
#define NS_TOUCH_BAR_ITEM_IDENTIFIER_CANDIDATE_LIST \
  (@"NSTouchBarItemIdentifierCandidateList")
#endif

static void mac_within_gui_and_here (void (^ CF_NOESCAPE) (void),
				     void (^ CF_NOESCAPE) (void));
static void mac_within_gui_allowing_inner_lisp (void (^ CF_NOESCAPE) (void));
static void mac_within_lisp (void (^ CF_NOESCAPE) (void));
static void mac_within_lisp_deferred_unless_popup (void (^) (void));

@implementation NSData (Emacs)

/* Return a unibyte Lisp string.  */

- (Lisp_Object)lispString
{
  return cfdata_to_lisp ((__bridge CFDataRef) self);
}

@end				// NSData (Emacs)

@implementation NSString (Emacs)

/* Return a string created from the Lisp string.  May cause GC.  */

+ (instancetype)stringWithLispString:(Lisp_Object)lispString
{
  return CF_BRIDGING_RELEASE (cfstring_create_with_string (lispString));
}

/* Return a string created from the unibyte Lisp string in UTF 8.  */

+ (instancetype)stringWithUTF8LispString:(Lisp_Object)lispString
{
  return CF_BRIDGING_RELEASE (cfstring_create_with_string_noencode
			      (lispString));
}

/* Like -[NSString stringWithUTF8String:], but fall back on Mac-Roman
   if BYTES cannot be interpreted as UTF-8 bytes and FLAG is YES. */

+ (instancetype)stringWithUTF8String:(const char *)bytes fallback:(BOOL)flag
{
  id string = [self stringWithUTF8String:bytes];

  if (string == nil && flag)
    string = CF_BRIDGING_RELEASE (CFStringCreateWithCString
				  (NULL, bytes, kCFStringEncodingMacRoman));

  return string;
}

/* Return a multibyte Lisp string.  May cause GC.  */

- (Lisp_Object)lispString
{
  return cfstring_to_lisp ((__bridge CFStringRef) self);
}

/* Return a unibyte Lisp string in UTF 8.  */

- (Lisp_Object)UTF8LispString
{
  return cfstring_to_lisp_nodecode ((__bridge CFStringRef) self);
}

/* Return a unibyte Lisp string in UTF 16 (native byte order, no BOM).  */

- (Lisp_Object)UTF16LispString
{
  return cfstring_to_lisp_utf_16 ((__bridge CFStringRef) self);
}

/* Return an array containing substrings from the receiver that have
   been divided by "camelcasing".  If SEPARATOR is non-nil, it
   specifies separating characters that are used instead of upper case
   letters.  */

- (NSArrayOf (NSString *) *)componentsSeparatedByCamelCasingWithCharactersInSet:(NSCharacterSet *)separator
{
  NSMutableArrayOf (NSString *) *result = [NSMutableArray arrayWithCapacity:0];
  NSUInteger length = [self length];
  NSRange upper = NSMakeRange (0, 0), rest = NSMakeRange (0, length);

  if (separator == nil)
    separator = [NSCharacterSet uppercaseLetterCharacterSet];

  while (rest.length != 0)
    {
      NSRange next = [self rangeOfCharacterFromSet:separator options:0
					     range:rest];

      if (next.location == rest.location)
	upper.length = next.location - upper.location;
      else
	{
	  NSRange capitalized;

	  if (next.location == NSNotFound)
	    next.location = length;
	  if (upper.length)
	    [result addObject:[self substringWithRange:upper]];
	  capitalized.location = NSMaxRange (upper);
	  capitalized.length = next.location - capitalized.location;
	  [result addObject:[self substringWithRange:capitalized]];
	  upper = NSMakeRange (next.location, 0);
	  if (next.location == length)
	    break;
	}
      rest.location = NSMaxRange (next);
      rest.length = length - rest.location;
    }

  if (rest.length == 0 && length != 0)
    {
      upper.length = length - upper.location;
      [result addObject:[self substringWithRange:upper]];
    }

  return result;
}

@end				// NSString (Emacs)

@implementation NSMutableArray (Emacs)

- (void)enqueue:(id)obj
{
  @synchronized (self)
  {
    [self addObject:(obj ? obj : NSNull.null)];
  }
}

- (id)dequeue
{
  id obj;

  @synchronized (self)
  {
    obj = [self objectAtIndex:0];
    obj = (obj == NSNull.null) ? nil : MRC_AUTORELEASE (MRC_RETAIN (obj));
    [self removeObjectAtIndex:0];
  }

  return obj;
}

@end				// NSMutableArray (Emacs)

@implementation NSFont (Emacs)

/* Return an NSFont object for the specified FACE.  */

+ (NSFont *)fontWithFace:(struct face *)face
{
  if (face == NULL || face->font == NULL)
    return nil;

  return (__bridge NSFont *) macfont_get_nsctfont (face->font);
}

@end				// NSFont (Emacs)

@implementation NSEvent (Emacs)

- (NSEvent *)mouseEventByChangingType:(NSEventType)type
			  andLocation:(NSPoint)location
{
  NSInteger clickCount = [self clickCount];

  /* Dragging via Screen Sharing.app sets clickCount to 0, and it
     disables updating screen during resize on macOS 10.12.  */
  return [NSEvent
	   mouseEventWithType:type location:location
		modifierFlags:[self modifierFlags]
		    timestamp:(mac_system_uptime ())
		 windowNumber:[self windowNumber]
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101200
		      context:nil
#else
		      context:[self context]
#endif
		  eventNumber:[self eventNumber]
		   clickCount:(clickCount ? clickCount : 1)
		     pressure:[self pressure]];
}

static void
mac_cgevent_set_unicode_string_from_event_ref (CGEventRef cgevent,
					       EventRef eventRef)
{
  ByteCount size;

  if (GetEventParameter (eventRef, kEventParamKeyUnicodes,
			 typeUnicodeText, NULL, 0, &size, NULL) == noErr)
    {
      UniChar *text = alloca (size);

      if (GetEventParameter (eventRef, kEventParamKeyUnicodes,
			     typeUnicodeText, NULL, size, NULL, text) == noErr)
	CGEventKeyboardSetUnicodeString (cgevent, size / sizeof (UniChar),
					 text);
    }
}

- (CGEventRef)coreGraphicsEvent
{
  CGEventRef event;
  NSEventType type = [self type];

  event = [self CGEvent];
  if (event)
    {
      /* Unicode string is not set if the keyboard event comes from
	 Screen Sharing on Mac OS X 10.6 and later.  */
      if (NSEventMaskFromType (type) & (NSEventMaskKeyDown | NSEventMaskKeyUp))
	{
	  UniCharCount length;

	  CGEventKeyboardGetUnicodeString (event, 0, &length, NULL);
	  if (length == 0)
	    {
	      EventRef eventRef = (EventRef) [self eventRef];

	      mac_cgevent_set_unicode_string_from_event_ref (event, eventRef);
	    }
	}
      return event;
    }

  event = NULL;
  if (NSEventMaskFromType (type) & ANY_MOUSE_EVENT_MASK)
    {
      CGPoint position = CGPointZero;

      GetEventParameter ((EventRef) [self eventRef], kEventParamMouseLocation,
			 typeHIPoint, NULL, sizeof (CGPoint), NULL, &position);
      event = CGEventCreateMouseEvent (NULL, (CGEventType) type, position,
				       [self buttonNumber]);
      /* CGEventCreateMouseEvent on Mac OS X 10.4 does not set
	 type.  */
      CGEventSetType (event, (CGEventType) type);
      if (NSEventMaskFromType (type)
	  & (ANY_MOUSE_DOWN_EVENT_MASK | ANY_MOUSE_UP_EVENT_MASK))
	{
	  CGEventSetIntegerValueField (event, kCGMouseEventClickState,
				       [self clickCount]);
	  CGEventSetDoubleValueField (event, kCGMouseEventPressure,
				      [self pressure]);
	}
    }
  else if (NSEventMaskFromType (type) & (NSEventMaskKeyDown | NSEventMaskKeyUp))
    {
      event = CGEventCreateKeyboardEvent (NULL, [self keyCode],
					  type == NSEventTypeKeyDown);
      CGEventSetIntegerValueField (event, kCGKeyboardEventAutorepeat,
				   [self isARepeat]);
#if __LP64__
      /* This seems to be unnecessary for 32-bit executables.  */
      {
	UInt32 keyboard_type;
	EventRef eventRef = (EventRef) [self eventRef];

	mac_cgevent_set_unicode_string_from_event_ref (event, eventRef);
	if (GetEventParameter (eventRef, kEventParamKeyboardType,
			       typeUInt32, NULL, sizeof (UInt32), NULL,
			       &keyboard_type) == noErr)
	  CGEventSetIntegerValueField (event, kCGKeyboardEventKeyboardType,
				       keyboard_type);
      }
#endif
    }
  if (event == NULL)
    {
      event = CGEventCreate (NULL);
      CGEventSetType (event, (CGEventType) type);
    }
  CGEventSetFlags (event, (CGEventFlags) [self modifierFlags]);
  CGEventSetTimestamp (event, [self timestamp] * kSecondScale);

  return (CGEventRef) CF_AUTORELEASE (event);
}

@end				// NSEvent (Emacs)

@implementation NSAttributedString (Emacs)

/* Return a unibyte Lisp string with text properties, in UTF 16
   (native byte order, no BOM).  */

- (Lisp_Object)UTF16LispString
{
  Lisp_Object result = [[self string] UTF16LispString];
  NSUInteger length = [self length];
  NSRange range = NSMakeRange (0, 0);

  while (NSMaxRange (range) < length)
    {
      Lisp_Object attrs = Qnil;
      NSDictionaryOf (NSString *, id) *attributes =
	[self attributesAtIndex:NSMaxRange (range) effectiveRange:&range];

      if (attributes)
	attrs = cfobject_to_lisp ((__bridge CFTypeRef) attributes,
				  CFOBJECT_TO_LISP_FLAGS_FOR_EVENT, -1);
      if (CONSP (attrs) && EQ (XCAR (attrs), Qdictionary))
	{
	  Lisp_Object props = Qnil, start, end;

	  for (attrs = XCDR (attrs); CONSP (attrs); attrs = XCDR (attrs))
	    props = Fcons (Fintern (XCAR (XCAR (attrs)), Qnil),
			   Fcons (XCDR (XCAR (attrs)), props));

	  XSETINT (start, range.location * sizeof (unichar));
	  XSETINT (end, NSMaxRange (range) * sizeof (unichar));
	  Fadd_text_properties (start, end, props, result);
	}
    }

  return result;
}

@end				// NSAttributedString (Emacs)

@implementation NSColor (Emacs)

+ (NSColor *)colorWithXColorPixel:(unsigned long)pixel
{
  CGFloat components[4];

  components[0] = (CGFloat) RED_FROM_ULONG (pixel) / 255.0f;
  components[1] = (CGFloat) GREEN_FROM_ULONG (pixel) / 255.0f;
  components[2] = (CGFloat) BLUE_FROM_ULONG (pixel) / 255.0f;
  components[3] = 1.0f;

  if ([self respondsToSelector:@selector(colorWithSRGBRed:green:blue:alpha:)])
    return [self colorWithSRGBRed:components[0] green:components[1]
			     blue:components[2] alpha:components[3]];
  else
    return [self colorWithColorSpace:[NSColorSpace sRGBColorSpace]
			  components:components count:4];
}

- (CGColorRef)copyCGColor
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1080
  if ([self respondsToSelector:@selector(CGColor)])
#endif
    return CGColorRetain (self.CGColor);
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1080
  else
    {
      CGColorSpaceRef cgColorSpace;
      CGFloat *components;

      if ([self.colorSpaceName isEqualToString:NSNamedColorSpace])
	cgColorSpace = NULL;
      else
	cgColorSpace = self.colorSpace.CGColorSpace;
      if (cgColorSpace)
	{
	  components = alloca (sizeof (CGFloat) * self.numberOfComponents);
	  [self getComponents:components];
	}
      else
	{
	  NSColor *colorInSRGB =
	    [self colorUsingColorSpace:NSColorSpace.sRGBColorSpace];

	  if (colorInSRGB)
	    {
	      components = alloca (sizeof (CGFloat) * 4);
	      cgColorSpace = mac_cg_color_space_rgb;
	      [colorInSRGB getComponents:components];
	    }
	}
      if (cgColorSpace)
	return CGColorCreate (cgColorSpace, components);
    }

  return NULL;
#endif
}

@end				// NSColor (Emacs)

@implementation NSImage (Emacs)

/* Create an image object from a Quartz 2D image.  */

+ (NSImage *)imageWithCGImage:(CGImageRef)cgImage exclusive:(BOOL)flag
{
  NSImage *image;

  if (flag)
    image = [[self alloc] initWithCGImage:cgImage size:NSZeroSize];
  else
    {
      NSBitmapImageRep *rep =
	[[NSBitmapImageRep alloc] initWithCGImage:cgImage];

      image = [[self alloc] initWithSize:[rep size]];
      [image addRepresentation:rep];
      MRC_RELEASE (rep);
    }

  return MRC_AUTORELEASE (image);
}

@end				// NSImage (Emacs)

@implementation NSApplication (Emacs)

- (void)postDummyEvent
{
  NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
			    location:NSZeroPoint modifierFlags:0
			    timestamp:0 windowNumber:0 context:nil
			    subtype:0 data1:0 data2:0];

  [self postEvent:event atStart:YES];
}

- (void)stopAfterCallingBlock:(void (NS_NOESCAPE ^)(void))block
{
  block ();
  [self stop:nil];
  [self postDummyEvent];
}

/* Temporarily run the main event loop during the call of the given
   block.  */

- (void)runTemporarilyWithBlock:(void (^)(void))block
{
  [[NSRunLoop currentRunLoop]
    performSelector:@selector(stopAfterCallingBlock:) target:self
#if USE_ARC && defined (__clang__) && __clang_major__ < 5
    /* `copy' is unnecessary for ARC on clang Apple LLVM version 5.0.
       Without `copy', earlier versions leak memory.  */
	   argument:[block copy]
#else
	   argument:block
#endif
	      order:0 modes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
  [self run];
}

@end				// NSApplication (Emacs)

static void
mac_within_app (void (^block) (void))
{
  if (!pthread_main_np ())
    mac_within_gui (^{[NSApp runTemporarilyWithBlock:block];});
  else if (![NSApp isRunning])
    [NSApp runTemporarilyWithBlock:block];
  else
    block ();
}

@implementation NSScreen (Emacs)

+ (NSScreen *)screenContainingPoint:(NSPoint)aPoint
{
  for (NSScreen *screen in [NSScreen screens])
    if (NSMouseInRect (aPoint, [screen frame], NO))
      return screen;

  return nil;
}

+ (NSScreen *)closestScreenForRect:(NSRect)aRect
{
  NSPoint centerPoint = NSMakePoint (NSMidX (aRect), NSMidY (aRect));
  CGFloat maxArea = 0, minSquareDistance = CGFLOAT_MAX;
  NSScreen *maxAreaScreen = nil, *minDistanceScreen = nil;

  for (NSScreen *screen in [NSScreen screens])
    {
      NSRect frame = [screen frame];
      NSRect intersectionFrame = NSIntersectionRect (frame, aRect);
      CGFloat area, diffX, diffY, squareDistance;

      area = NSWidth (intersectionFrame) * NSHeight (intersectionFrame);
      if (area > maxArea)
	{
	  maxAreaScreen = screen;
	  maxArea = area;
	}

      diffX = NSMidX (frame) - centerPoint.x;
      diffY = NSMidY (frame) - centerPoint.y;
      squareDistance = diffX * diffX + diffY * diffY;
      if (squareDistance < minSquareDistance)
	{
	  minDistanceScreen = screen;
	  minSquareDistance = squareDistance;
	}
    }

  return maxAreaScreen ? maxAreaScreen : minDistanceScreen;
}

- (BOOL)containsDock
{
  /* On macOS 10.13, screen's visibleFrame occupies full frame when
     the Dock is hidden.  */
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_12))
    return YES;
  else
    {
      NSRect frame = [self frame], visibleFrame = [self visibleFrame];

      return (NSMinY (frame) != NSMinY (visibleFrame)
	      || NSMinX (frame) != NSMinX (visibleFrame)
	      || NSMaxX (frame) != NSMaxX (visibleFrame));
    }
}

- (BOOL)canShowMenuBar
{
  return ([self isEqual:[[NSScreen screens] objectAtIndex:0]]
	  /* OS X 10.9 may have menu bars on non-main screens (in an
	     inactive appearance) if [NSScreen
	     screensHaveSeparateSpaces] returns YES.  */
	  || ([NSScreen respondsToSelector:@selector(screensHaveSeparateSpaces)]
	      && [NSScreen screensHaveSeparateSpaces]));
}

@end				// NSScreen (Emacs)

/* Default implementation.  Will be overridden in EmacsWindow.  */

@implementation NSWindow (Emacs)

- (Lisp_Object)lispFrame
{
  return Qnil;
}

- (NSWindow *)topLevelWindow
{
  NSWindow *current = self, *parent;

  while ((parent = current.parentWindow) != nil)
    current = parent;

  return current;
}

/* Execute the specified block for each of the receiver's child and
   descendant windows.  Set *stop to YES in the block to abort further
   processing of the child windows subtree.  */

- (void)enumerateChildWindowsUsingBlock:(NS_NOESCAPE void
					 (^)(NSWindow *child, BOOL *stop))block
{
  for (NSWindow *childWindow in self.childWindows)
    {
      BOOL stop = NO;

      block (childWindow, &stop);
      if (!stop)
	[childWindow enumerateChildWindowsUsingBlock:block];
    }
}

@end				// NSWindow (Emacs)

@implementation NSCursor (Emacs)

+ (NSCursor *)cursorWithThemeCursor:(ThemeCursor)themeCursor
{
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6
      && themeCursor > kThemePoofCursor)
    return nil;

  /* We don't use a mapping from ThemeCursor to SEL together with
     performSelector: because ARC cannot know whether the return
     value should be retained or not at compile time.  */
  switch (themeCursor)
    {
    case kThemeArrowCursor:
      return [NSCursor arrowCursor];
    case kThemeCopyArrowCursor:
      return [NSCursor dragCopyCursor];
    case kThemeAliasArrowCursor:
      return [NSCursor dragLinkCursor];
    case kThemeContextualMenuArrowCursor:
      return [NSCursor contextualMenuCursor];
    case kThemeIBeamCursor:
      return [NSCursor IBeamCursor];
    case kThemeCrossCursor:
      return [NSCursor crosshairCursor];
    case kThemeClosedHandCursor:
      return [NSCursor closedHandCursor];
    case kThemeOpenHandCursor:
      return [NSCursor openHandCursor];
    case kThemePointingHandCursor:
      return [NSCursor pointingHandCursor];
    case kThemeResizeLeftCursor:
      return [NSCursor resizeLeftCursor];
    case kThemeResizeRightCursor:
      return [NSCursor resizeRightCursor];
    case kThemeResizeLeftRightCursor:
      return [NSCursor resizeLeftRightCursor];
    case kThemeNotAllowedCursor:
      return [NSCursor operationNotAllowedCursor];
    case kThemeResizeUpCursor:
      return [NSCursor resizeUpCursor];
    case kThemeResizeDownCursor:
      return [NSCursor resizeDownCursor];
    case kThemeResizeUpDownCursor:
      return [NSCursor resizeUpDownCursor];
    case kThemePoofCursor:
      return [NSCursor disappearingItemCursor];
    case THEME_RESIZE_NORTHWEST_SOUTHEAST_CURSOR:
      return [NSCursor _windowResizeNorthWestSouthEastCursor];
    case THEME_RESIZE_NORTHEAST_SOUTHWEST_CURSOR:
      return [NSCursor _windowResizeNorthEastSouthWestCursor];
    case THEME_RESIZE_NORTH_SOUTH_CURSOR:
      return [NSCursor _windowResizeNorthSouthCursor];
    case THEME_RESIZE_NORTH_CURSOR:
      return [NSCursor _windowResizeNorthCursor];
    case THEME_RESIZE_SOUTH_CURSOR:
      return [NSCursor _windowResizeSouthCursor];
    case THEME_RESIZE_EAST_WEST_CURSOR:
      return [NSCursor _windowResizeEastWestCursor];
    case THEME_RESIZE_EAST_CURSOR:
      return [NSCursor _windowResizeEastCursor];
    case THEME_RESIZE_WEST_CURSOR:
      return [NSCursor _windowResizeWestCursor];
    case THEME_RESIZE_NORTHWEST_CURSOR:
      return [NSCursor _windowResizeNorthWestCursor];
    case THEME_RESIZE_NORTHEAST_CURSOR:
      return [NSCursor _windowResizeNorthEastCursor];
    case THEME_RESIZE_SOUTHWEST_CURSOR:
      return [NSCursor _windowResizeSouthWestCursor];
    case THEME_RESIZE_SOUTHEAST_CURSOR:
      return [NSCursor _windowResizeSouthEastCursor];
    default:
      return nil;
    }
}

@end				// NSCursor (Emacs)

@implementation EmacsPosingWindow

/* Variables to save implementations of the original -[NSWindow close]
   and -[NSWindow orderOut:].  */
/* ARC requires a precise return type.  */
static void (*impClose) (id, SEL);
static void (*impOrderOut) (id, SEL, id);

+ (void)setup
{
  Method methodCloseNew =
    class_getInstanceMethod ([self class], @selector(close));
  Method methodOrderOutNew =
    class_getInstanceMethod ([self class], @selector(orderOut:));
  IMP impCloseNew = method_getImplementation (methodCloseNew);
  IMP impOrderOutNew = method_getImplementation (methodOrderOutNew);
  const char *typeCloseNew = method_getTypeEncoding (methodCloseNew);
  const char *typeOrderOutNew = method_getTypeEncoding (methodOrderOutNew);

  impClose = ((void (*) (id, SEL))
	      class_replaceMethod ([NSWindow class], @selector(close),
				   impCloseNew, typeCloseNew));
  impOrderOut = ((void (*) (id, SEL, id))
		 class_replaceMethod ([NSWindow class],
				      @selector(orderOut:),
				      impOrderOutNew, typeOrderOutNew));
}

/* Close the receiver with running the main event loop if not.  Just
   closing the window outside the application loop does not activate
   the next window.  */

- (void)close
{
  mac_within_app (^{(*impClose) (self, _cmd);});
}

/* Hide the receiver with running the main event loop if not.  Just
   hiding the window outside the application loop does not activate
   the next window.  */

- (void)orderOut:(id)sender
{
  mac_within_app (^{(*impOrderOut) (self, _cmd, sender);});
}

@end				// EmacsPosingWindow

/* Return a pair of a type tag and a Lisp object converted form the
   NSValue object OBJ.  If the object is not an NSValue object or not
   created from NSRange, NSPoint, NSSize, or NSRect, then return
   nil.  */

static Lisp_Object
mac_nsvalue_to_lisp (CFTypeRef obj)
{
  Lisp_Object result = Qnil;

  if ([(__bridge id)obj isKindOfClass:[NSValue class]])
    {
      NSValue *value = (__bridge NSValue *) obj;
      const char *type = [value objCType];
      Lisp_Object tag = Qnil;

      if (strcmp (type, @encode (NSRange)) == 0)
	{
	  NSRange range = [value rangeValue];

	  tag = Qrange;
	  result = Fcons (make_number (range.location),
			  make_number (range.length));
	}
      else if (strcmp (type, @encode (NSPoint)) == 0)
	{
	  NSPoint point = [value pointValue];

	  tag = Qpoint;
	  result = Fcons (make_float (point.x), make_float (point.y));
	}
      else if (strcmp (type, @encode (NSSize)) == 0)
	{
	  NSSize size = [value sizeValue];

	  tag = Qsize;
	  result = Fcons (make_float (size.width), make_float (size.height));
	}
      else if (strcmp (type, @encode (NSRect)) == 0)
	{
	  NSRect rect = [value rectValue];

	  tag = Qrect;
	  result = list4 (make_float (NSMinX (rect)),
			  make_float (NSMinY (rect)),
			  make_float (NSWidth (rect)),
			  make_float (NSHeight (rect)));
	}

      if (!NILP (tag))
	result = Fcons (tag, result);
    }

  return result;
}

static Lisp_Object
mac_nsfont_to_lisp (CFTypeRef obj)
{
  Lisp_Object result = Qnil;

  if ([(__bridge id)obj isKindOfClass:[NSFont class]])
    {
      result = macfont_nsctfont_to_spec ((void *) obj);
      if (!NILP (result))
	result = Fcons (Qfont, result);
    }

  return result;
}

Lisp_Object
mac_nsobject_to_lisp (CFTypeRef obj)
{
  Lisp_Object result;

  result = mac_nsvalue_to_lisp (obj);
  if (!NILP (result))
    return result;
  result = mac_nsfont_to_lisp (obj);

  return result;
}

static bool
has_resize_indicator_at_bottom_right_p (void)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
  return false;
#else
  return floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6;
#endif
}

static bool
has_full_screen_with_dedicated_desktop_p (void)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
  return true;
#else
  return !(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6);
#endif
}

static bool
has_visual_effect_view_p (void)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
  return true;
#else
  return !(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_9);
#endif
}

static bool
has_system_appearance_p (void)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101400
  return true;
#else
  return !(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_13);
#endif
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
/* Whether window's bottom corners need masking so they look rounded.
   If we use NSVisualEffectView (available on OS X 10.10 and later)
   for the content view, then we don't have to mask the corners
   manually.  Mac OS X 10.6 and earlier don't have the rounded bottom
   corners in the first place.  */

static bool
rounded_bottom_corners_need_masking_p (void)
{
  return (!has_visual_effect_view_p ()
	  && !(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6));
}
#endif

static bool
has_gesture_recognizer_p (void)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
  return true;
#else
  return !(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_9);
#endif
}

static bool
can_auto_hide_menu_bar_without_hiding_dock_p (void)
{
  /* Needs to be linked on OS X 10.11 or later.  */
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101100
  return !(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max);
#else
  return false;
#endif
}

/* Autorelease pool.  */

#if __clang_major__ >= 3
#define BEGIN_AUTORELEASE_POOL	@autoreleasepool {
#define END_AUTORELEASE_POOL	}
#define BEGIN_AUTORELEASE_POOL_BLOCK_INPUT	\
  @autoreleasepool {
#define END_AUTORELEASE_POOL_BLOCK_INPUT	\
  block_input (); } unblock_input ()
#else
#define BEGIN_AUTORELEASE_POOL					\
  { NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init]
#define END_AUTORELEASE_POOL			\
  [pool release]; }
#define BEGIN_AUTORELEASE_POOL_BLOCK_INPUT				\
  block_input ();							\
  { NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];		\
  unblock_input ()
#define END_AUTORELEASE_POOL_BLOCK_INPUT		\
  block_input (); [pool release]; } unblock_input ()
#endif

#if MAC_USE_AUTORELEASE_LOOP
void
mac_autorelease_loop (Lisp_Object (CF_NOESCAPE ^body) (void))
{
  Lisp_Object val;

  do
    {
      BEGIN_AUTORELEASE_POOL_BLOCK_INPUT;
      val = body ();
      END_AUTORELEASE_POOL_BLOCK_INPUT;
    }
  while (!NILP (val));
}

#else

void *
mac_alloc_autorelease_pool (void)
{
  NSAutoreleasePool *pool;

  block_input ();
  pool = [[NSAutoreleasePool alloc] init];
  unblock_input ();

  return pool;
}

void
mac_release_autorelease_pool (void *pool)
{
  block_input ();
  [(NSAutoreleasePool *)pool release];
  unblock_input ();
}
#endif

void
mac_alert_sound_play (void)
{
  NSBeep ();
}

double
mac_appkit_version (void)
{
  return NSAppKitVersionNumber;
}

double
mac_system_uptime (void)
{
  return [[NSProcessInfo processInfo] systemUptime];
}

bool
mac_is_current_process_frontmost (void)
{
  return [[NSRunningApplication currentApplication] isActive];
}

void
mac_bring_current_process_to_front (bool front_window_only_p)
{
  NSApplicationActivationOptions options;

  if (front_window_only_p)
    options = NSApplicationActivateIgnoringOtherApps;
  else
    options = (NSApplicationActivateAllWindows
	       | NSApplicationActivateIgnoringOtherApps);
  [[NSRunningApplication currentApplication] activateWithOptions:options];
}

/* Move FILENAME to the trash without using the Finder and return
   whether it succeeded.  If CFERROR is non-NULL, *CFERROR is set on
   failure.  If trashing functionality is not available, return false
   and set *CFERROR to NULL.  */

bool
mac_trash_file (const char *filename, CFErrorRef *cferror)
{
  bool result;

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1090
  /* -[NSFileManager trashItemAtURL:resultingItemURL:error:] trashes
     the destination of the specified symbolic link instead of the
     symbolic link itself on OS X 10.8 - 10.8.2.  */
  if (NSFoundationVersionNumber >= NSFoundationVersionNumber10_8_3)
#endif
    {
      NSError * __autoreleasing error;
      NSURL *url =
	(CF_BRIDGING_RELEASE
	 (CFURLCreateFromFileSystemRepresentation (NULL,
						   (const UInt8 *) filename,
						   strlen (filename), false)));

      result = [[NSFileManager defaultManager] trashItemAtURL:url
					     resultingItemURL:NULL
							error:&error];
      if (!result && cferror)
	*cferror = (CFErrorRef) CF_BRIDGING_RETAIN (error);
    }
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1090
  else
    {
      OSStatus err;
      FSRef fref;

      err = FSPathMakeRefWithOptions ((const UInt8 *) filename,
				      kFSPathMakeRefDoNotFollowLeafSymlink,
				      &fref, NULL);
      if (err == noErr)
	/* FSPathMoveObjectToTrashSync tries to delete the destination
	   of the specified symbolic link.  So we use
	   FSMoveObjectToTrashSync for an FSRef created with
	   kFSPathMakeRefDoNotFollowLeafSymlink.  */
	err = FSMoveObjectToTrashSync (&fref, NULL,
				       kFSFileOperationDefaultOptions);
      if (err == noErr)
	result = true;
      else
	{
	  result = false;
	  if (cferror)
	    *cferror = CFErrorCreate (NULL, kCFErrorDomainOSStatus, err,
				      NULL);
	}
    }
#endif

  return result;
}


/************************************************************************
			     Application
 ************************************************************************/

#define FRAME_CONTROLLER(f) ((__bridge EmacsFrameController *)	\
			     FRAME_MAC_WINDOW (f))
#define FRAME_MAC_WINDOW_OBJECT(f) ([FRAME_CONTROLLER(f) emacsWindow])

static EmacsController *emacsController;

static void init_menu_bar (void);
static void init_apple_event_handler (void);
static void init_accessibility (void);

static BOOL is_action_selector (SEL);
static BOOL is_services_handler_selector (SEL);
static NSMethodSignature *action_signature (void);
static NSMethodSignature *services_handler_signature (void);
static void handle_action_invocation (NSInvocation *);
static void handle_services_invocation (NSInvocation *);

static void mac_flush_1 (struct frame *);

static void mac_update_accessibility_display_options (void);

static EventRef mac_peek_next_event (void);

/* True if we are executing handleQueuedNSEventsWithHoldingQuitIn:.  */
static bool handling_queued_nsevents_p;

@implementation EmacsApplication

/* Don't use the "applicationShouldTerminate: - NSTerminateLater -
   replyToApplicationShouldTerminate:" mechanism provided by
   -[NSApplication terminate:] for deferring the termination, as it
   does not allow us to go back to the Lisp evaluation loop.  */

- (void)terminate:(id)sender
{
  OSErr err;
  NSAppleEventManager *manager = [NSAppleEventManager sharedAppleEventManager];
  AppleEvent appleEvent, reply;

  err = create_apple_event (kCoreEventClass, kAEQuitApplication, &appleEvent);
  if (err == noErr)
    {
      AEInitializeDesc (&reply);
      [manager dispatchRawAppleEvent:&appleEvent withRawReply:&reply
	       handlerRefCon:0];
      AEDisposeDesc (&reply);
      AEDisposeDesc (&appleEvent);
    }
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
/* Workarounds for memory leaks on OS X 10.9.  */

- (void)_installMemoryPressureDispatchSources
{
  static BOOL doNotInstallDispatchSources;

  if (doNotInstallDispatchSources)
    return;
  [super _installMemoryPressureDispatchSources];
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_9
      && !(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_8))
    doNotInstallDispatchSources = YES;
}

- (void)_installMemoryStatusDispatchSources
{
  static BOOL doNotInstallDispatchSources;

  if (doNotInstallDispatchSources)
    return;
  [super _installMemoryStatusDispatchSources];
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_9
      && !(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_8))
    doNotInstallDispatchSources = YES;
}
#endif

- (void)setMainMenu:(NSMenu *)mainMenu
{
  NSMenu *currentMainMenu = [self mainMenu];

  if (![mainMenu isEqual:currentMainMenu])
    {
      if ([currentMainMenu isKindOfClass:[EmacsMenu class]])
	[[NSNotificationCenter defaultCenter] removeObserver:currentMainMenu];
      if ([mainMenu isKindOfClass:[EmacsMenu class]])
	[[NSNotificationCenter defaultCenter]
	  addObserver:mainMenu
	     selector:@selector(menuDidBeginTracking:)
		 name:NSMenuDidBeginTrackingNotification
	       object:mainMenu];
      [super setMainMenu:mainMenu];
    }
}

@end				// EmacsApplication

@implementation EmacsController

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  for (NSString *keyPath in observedKeyPaths)
    [NSApp removeObserver:self forKeyPath:keyPath];
#if !USE_ARC
  [observedKeyPaths release];
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
  [lastFlushDate release];
  [flushTimer release];
  [deferredFlushWindows release];
#endif
  [super dealloc];
#endif
}

/* Delegate Methods  */

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
  [EmacsPosingWindow setup];
  [NSFontManager setFontPanelFactory:[EmacsFontPanel class]];
  serviceProviderRegistered = mac_service_provider_registered_p ();
  init_menu_bar ();
  init_apple_event_handler ();
  init_accessibility ();
  observedKeyPaths = [[NSSet alloc] init];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  /* Try to suppress the warning "CFMessagePort: bootstrap_register():
     failed" displayed by the second instance of Emacs.  Strictly
     speaking, there's a race condition, but it is not critical
     anyway.  */
  if (!serviceProviderRegistered)
    [NSApp setServicesProvider:self];

  macfont_update_antialias_threshold ();
  [[NSNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(antialiasThresholdDidChange:)
	   name:NSAntialiasThresholdChangedNotification
	 object:nil];

  if ([NSWorkspace instancesRespondToSelector:@selector(accessibilityDisplayShouldIncreaseContrast)])
    {
      mac_update_accessibility_display_options ();
      [[[NSWorkspace sharedWorkspace] notificationCenter]
	addObserver:self
	   selector:@selector(accessibilityDisplayOptionsDidChange:)
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101000
	       name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
#else
	       name:@"NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification"
#endif
	     object:nil];
    }

  [NSApp registerUserInterfaceItemSearchHandler:self];
  Vmac_help_topics = Qnil;

#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101500
  /* Work around animation effect glitches for executables linked on
     macOS 10.15.  */
  setenv ("CAVIEW_USE_GL", "1", 0);
#endif

  /* Exit from the main event loop.  */
  [NSApp stop:nil];
  [NSApp postDummyEvent];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
  if (needsUpdatePresentationOptionsOnBecomingActive)
    {
      [self updatePresentationOptions];
      needsUpdatePresentationOptionsOnBecomingActive = NO;
    }
}

#if HAVE_MAC_METAL
- (void)applicationDidChangeScreenParameters:(NSNotification *)notification
{
  Lisp_Object tail, frame;

  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);

      if (FRAME_MAC_P (f))
	{
	  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

	  [frameController updateEmacsViewMTLObjects];
	}
    }
}
#endif

- (void)antialiasThresholdDidChange:(NSNotification *)notification
{
  macfont_update_antialias_threshold ();
}

- (void)updateObservedKeyPaths
{
  Lisp_Object keymap = get_keymap (Vmac_apple_event_map, 0, 0);

  if (!NILP (keymap))
    keymap = get_keymap (access_keymap (keymap, Qapplication_kvo, 0, 1, 0),
			 0, 0);
  if (!NILP (keymap))
    {
      NSMutableSetOf (NSString *) *work =
	[[NSMutableSet alloc] initWithCapacity:0];

      mac_map_keymap (keymap, false, ^(Lisp_Object key, Lisp_Object binding) {
	  if (!NILP (binding) && !EQ (binding, Qundefined) && SYMBOLP (key))
	    [work addObject:[NSString
			      stringWithUTF8LispString:(SYMBOL_NAME (key))]];
	});

      NSSetOf (NSString *) *oldObservedKeyPaths = observedKeyPaths;
      observedKeyPaths = [[NSSet alloc] initWithSet:work];

      for (NSString *keyPath in oldObservedKeyPaths)
	if ([work member:keyPath])
	  [work removeObject:keyPath];
	else
	  [NSApp removeObserver:self forKeyPath:keyPath];
      MRC_RELEASE (oldObservedKeyPaths);

      for (NSString *keyPath in work)
	[NSApp addObserver:self forKeyPath:keyPath
		   options:(NSKeyValueObservingOptionOld
			    | NSKeyValueObservingOptionNew)
		   context:nil];
      MRC_RELEASE (work);
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionaryOf (NSKeyValueChangeKey, id) *)change
                       context:(void *)context
{
  if ([observedKeyPaths containsObject:keyPath])
    {
      struct input_event inev;
      Lisp_Object tag_Lisp = build_string ("Lisp");
      Lisp_Object change_value =
	cfobject_to_lisp ((__bridge CFTypeRef) change,
			  CFOBJECT_TO_LISP_FLAGS_FOR_EVENT, -1);
      Lisp_Object arg = Qnil;

      arg = Fcons (Fcons (Qchange, Fcons (tag_Lisp, change_value)), arg);
      EVENT_INIT (inev);
      inev.kind = MAC_APPLE_EVENT;
      inev.x = Qapplication_kvo;
      inev.y = Fintern (keyPath.UTF8LispString, Qnil);
      XSETFRAME (inev.frame_or_window, mac_focus_frame (&one_mac_display_info));
      inev.arg = Fcons (build_string ("aevt"), arg);
      [self storeEvent:&inev];
    }
}

- (int)getAndClearMenuItemSelection
{
  int selection = menuItemSelection;

  menuItemSelection = 0;

  return selection;
}

/* Action methods  */

/* Store SENDER's inputEvent to kbd_buffer.  */

- (void)storeInputEvent:(id)sender
{
  [self storeEvent:[sender inputEvent]];
}

/* Set the instance variable menuItemSelection to the value of
   SENDER's tag.  */

- (void)setMenuItemSelectionToTag:(id)sender
{
  menuItemSelection = [sender tag];
}

/* Equivalent of (ns-hide-emacs 'active).  */
- (void)activate:(id)sender
{
  [NSApp activateIgnoringOtherApps:YES];
}

/* Event handling  */

static EventRef peek_if_next_event_activates_menu_bar (void);

/* Store BUFP to kbd_buffer.  */

- (void)storeEvent:(struct input_event *)bufp
{
  if (bufp->kind == HELP_EVENT)
    {
      do_help = 1;
      emacsHelpFrame = XFRAME (bufp->frame_or_window);
    }
  else
    {
      kbd_buffer_store_event_hold (bufp, hold_quit);
      count++;
    }
}

- (void)setTrackingResumeBlock:(void (^)(void))block
{
  MRC_RELEASE (trackingResumeBlock);
  trackingResumeBlock = [block copy];
}

#define MOUSE_TRACKING_SET_RESUMPTION(controller, obj, sel_name)	\
  [(controller) setTrackingResumeBlock:^{[(obj) sel_name];}]

/* These macros can only be used inside EmacsController.  */
#define MOUSE_TRACKING_SUSPENDED_P()	(trackingResumeBlock != nil)
#define MOUSE_TRACKING_RESUME()		trackingResumeBlock ()
#define MOUSE_TRACKING_RESET()		[self setTrackingResumeBlock:nil]

- (BOOL)isMouseTrackingSuspended
{
  return MOUSE_TRACKING_SUSPENDED_P ();
}

/* Minimum time interval between successive mac_read_socket calls.  */

#define READ_SOCKET_MIN_INTERVAL (1/60.0)

static BOOL extendReadSocketIntervalOnce;

- (NSTimeInterval)minimumIntervalForReadSocket
{
  NSTimeInterval interval = READ_SOCKET_MIN_INTERVAL;

  if (MOUSE_TRACKING_SUSPENDED_P () || extendReadSocketIntervalOnce)
    interval *= 6;
  else if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max))
    /* A large interval value affects responsiveness on OS X
       10.11.  */
    interval *= .1;

  return interval;
}

/* Handle the NSEvent EVENT.  */

- (void)handleOneNSEvent:(NSEvent *)event
{
  struct mac_display_info *dpyinfo = &one_mac_display_info;
  struct input_event inev;

  do_help = 0;
  emacsHelpFrame = NULL;

  EVENT_INIT (inev);
  inev.arg = Qnil;
  XSETFRAME (inev.frame_or_window, mac_focus_frame (dpyinfo));

  switch ([event type])
    {
    case NSEventTypeKeyDown:
      {
	CGEventRef cgevent = [event coreGraphicsEvent];
	NSEventModifierFlags flags = [event modifierFlags];
	unsigned short key_code = [event keyCode];

	if (!(mac_cgevent_to_input_event (cgevent, NULL)
	      & ~(mac_pass_command_to_system ? kCGEventFlagMaskCommand : 0)
	      & ~(mac_pass_control_to_system ? kCGEventFlagMaskControl : 0))
	    && ([NSApp keyWindow] || (flags & NSEventModifierFlagCommand))
	    /* Avoid activating context help mode with `help' key.  */
	    && !([[[NSApp keyWindow] firstResponder]
		   isMemberOfClass:[EmacsMainView class]]
		 && key_code == kVK_Help
		 && (flags & (NSEventModifierFlagControl
			      | NSEventModifierFlagOption
			      | NSEventModifierFlagCommand)) == 0))
	  goto OTHER;

	mac_cgevent_to_input_event (cgevent, &inev);
	if (inev.kind != NO_EVENT)
	  [self storeEvent:&inev];
      }
      break;

    default:
    OTHER:
      [NSApp sendEvent:event];
      break;
    }

  if (do_help
      && !(hold_quit && hold_quit->kind != NO_EVENT))
    {
      Lisp_Object frame;

      if (emacsHelpFrame)
	XSETFRAME (frame, emacsHelpFrame);
      else
	frame = Qnil;

      if (do_help > 0)
	{
	  any_help_event_p = true;
	  gen_help_event (help_echo_string, frame, help_echo_window,
			  help_echo_object, help_echo_pos);
	}
      else
	{
	  help_echo_string = Qnil;
	  gen_help_event (Qnil, frame, Qnil, Qnil, 0);
	}
      count++;
    }
}

/* Handle NSEvents in the queue with holding quit event in *BUFP.
   Return the number of stored Emacs events.

   We handle them inside the application loop in order to avoid the
   hang in the following situation:

     1. Save some file in Emacs.
     2. Remove the file in Terminal.
     3. Try to drag the proxy icon in the Emacs title bar.
     4. "Document Drag Error" window will pop up, but can't pop it
        down by clicking the OK button.  */

- (int)handleQueuedNSEventsWithHoldingQuitIn:(struct input_event *)bufp
{
  int __block result;

  mac_within_app (^{
      /* Mac OS X 10.2 doesn't regard untilDate:nil as polling.  */
      NSDate *expiration = [NSDate distantPast];
      struct mac_display_info *dpyinfo = &one_mac_display_info;

      hold_quit = bufp;
      count = 0;

      if (MOUSE_TRACKING_SUSPENDED_P ())
	{
	  NSEvent *leftMouseEvent =
	    [NSApp
	      nextEventMatchingMask:(NSEventMaskLeftMouseDragged
				     | NSEventMaskLeftMouseUp)
			  untilDate:expiration
			     inMode:NSDefaultRunLoopMode dequeue:NO];

	  if (leftMouseEvent)
	    {
	      if ([leftMouseEvent type] == NSEventTypeLeftMouseDragged)
		MOUSE_TRACKING_RESUME ();
	      MOUSE_TRACKING_RESET ();
	    }
	}

      while (1)
	{
	  NSEvent *event;
	  NSUInteger mask;

	  if (dpyinfo->saved_menu_event == NULL)
	    {
	      EventRef menu_event = peek_if_next_event_activates_menu_bar ();

	      if (menu_event)
		{
		  struct input_event inev;

		  dpyinfo->saved_menu_event = RetainEvent (menu_event);
		  RemoveEventFromQueue (GetMainEventQueue (), menu_event);

		  EVENT_INIT (inev);
		  inev.arg = Qnil;
		  XSETFRAME (inev.frame_or_window, mac_focus_frame (dpyinfo));
		  inev.kind = MENU_BAR_ACTIVATE_EVENT;
		  [self storeEvent:&inev];
		}
	    }

	  mask = ((!MOUSE_TRACKING_SUSPENDED_P ()
		   && dpyinfo->saved_menu_event == NULL)
		  ? NSEventMaskAny : (NSEventMaskAny & ~ANY_MOUSE_EVENT_MASK));
	  event = [NSApp nextEventMatchingMask:mask untilDate:expiration
			 inMode:NSDefaultRunLoopMode dequeue:YES];

	  if (event == nil)
	    break;
	  [self handleOneNSEvent:event];
	}

      hold_quit = NULL;

      result = count;
    });

  return result;
}

static BOOL
emacs_windows_need_display_p (void)
{
  Lisp_Object tail, frame;

  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);

      if (FRAME_MAC_P (f))
	{
	  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

	  if ([window isVisible] && [window viewsNeedDisplay])
	    return YES;
	}
    }

  return NO;
}

- (void)processDeferredReadSocket:(NSTimer *)theTimer
{
  if (!handling_queued_nsevents_p)
    {
      if (mac_peek_next_event () || emacs_windows_need_display_p ())
	[NSApp postDummyEvent];
      else
	mac_flush_1 (NULL);
    }
}

- (void)cancelHelpEchoForEmacsFrame:(struct frame *)f
{
  /* Generate a nil HELP_EVENT to cancel a help-echo.
     Do it only if there's something to cancel.
     Otherwise, the startup message is cleared when the
     mouse leaves the frame.  */
  if (any_help_event_p)
    {
      Lisp_Object frame;

      XSETFRAME (frame, f);
      help_echo_string = Qnil;
      gen_help_event (Qnil, frame, Qnil, Qnil, 0);
    }
}

/* Work around conflicting Cocoa's text system key bindings.  */

- (BOOL)conflictingKeyBindingsDisabled
{
  return conflictingKeyBindingsDisabled;
}

- (void)setConflictingKeyBindingsDisabled:(BOOL)flag
{
  id keyBindingManager;

  if (flag == conflictingKeyBindingsDisabled)
    return;

  keyBindingManager = [(NSClassFromString (@"NSKeyBindingManager"))
			performSelector:@selector(sharedKeyBindingManager)];
  if (flag)
    {
      /* Disable the effect of NSQuotedKeystrokeBinding (C-q by
	 default) and NSRepeatCountBinding (none by default but user
	 may set it to C-u).  */
      [keyBindingManager performSelector:@selector(setQuoteBinding:)
			      withObject:nil];
      [keyBindingManager performSelector:@selector(setArgumentBinding:)
			      withObject:nil];
      if (keyBindingsWithConflicts == nil)
	{
	  NSArrayOf (NSString *) *writingDirectionCommands =
	    [NSArray arrayWithObjects:@"insertRightToLeftSlash:",
		     @"makeBaseWritingDirectionNatural:",
		     @"makeBaseWritingDirectionLeftToRight:",
		     @"makeBaseWritingDirectionRightToLeft:",
		     @"makeTextWritingDirectionNatural:",
		     @"makeTextWritingDirectionLeftToRight:",
		     @"makeTextWritingDirectionRightToLeft:", nil];
	  NSMutableDictionaryOf (NSString *, NSString *) *dictionary;

	  /* Replace entries for prefix keys and writing direction
	     commands with dummy ones.  */
	  keyBindingsWithConflicts =
	    MRC_RETAIN ([keyBindingManager dictionary]);
	  dictionary = [keyBindingsWithConflicts mutableCopy];
	  for (NSString *key in keyBindingsWithConflicts)
	    {
	      id object = [keyBindingsWithConflicts objectForKey:key];

	      if (![object isKindOfClass:[NSString class]]
		  || [writingDirectionCommands containsObject:object])
		[dictionary setObject:@"dummy:" forKey:key];
	    }
	  keyBindingsWithoutConflicts = dictionary;
	}
      [keyBindingManager setDictionary:keyBindingsWithoutConflicts];
    }
  else
    {
      NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];

      [keyBindingManager
	performSelector:@selector(setQuoteBinding:)
	     withObject:[userDefaults
			  stringForKey:@"NSQuotedKeystrokeBinding"]];
      [keyBindingManager
	performSelector:@selector(setArgumentBinding:)
	     withObject:[userDefaults
			  stringForKey:@"NSRepeatCountBinding"]];
      if (keyBindingsWithConflicts)
	[keyBindingManager setDictionary:keyBindingsWithConflicts];
    }

  conflictingKeyBindingsDisabled = flag;
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
#define FLUSH_WINDOW_MIN_INTERVAL (1/60.0)

- (void)flushWindow:(NSWindow *)window force:(BOOL)flag
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
  /* Deferring flush seems to be unnecessary and give a reverse effect
     on OS X 10.11.  */
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max))
#endif
    [window flushWindow];
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
  else
    {
      NSTimeInterval timeInterval;

      if (deferredFlushWindows == nil)
	deferredFlushWindows = [[NSMutableSet alloc] initWithCapacity:0];
      if (window)
	[deferredFlushWindows addObject:window];

      if (!flag && lastFlushDate
	  && (timeInterval = - [lastFlushDate timeIntervalSinceNow],
	      timeInterval < FLUSH_WINDOW_MIN_INTERVAL))
	{
	  if (![flushTimer isValid])
	    {
	      MRC_RELEASE (flushTimer);
	      timeInterval = FLUSH_WINDOW_MIN_INTERVAL - timeInterval;
	      flushTimer =
		MRC_RETAIN ([NSTimer scheduledTimerWithTimeInterval:timeInterval
							     target:self
							   selector:@selector(processDeferredFlushWindow:)
							   userInfo:nil
							    repeats:NO]);
	    }
	}
      else
	{
	  MRC_RELEASE (lastFlushDate);
	  lastFlushDate = [[NSDate alloc] init];
	  [flushTimer invalidate];
	  MRC_RELEASE (flushTimer);
	  flushTimer = nil;

	  for (NSWindow *window in deferredFlushWindows)
	    [window flushWindow];
	  [deferredFlushWindows removeAllObjects];
	}
    }
#endif
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
- (void)processDeferredFlushWindow:(NSTimer *)theTimer
{
  if (!handling_queued_nsevents_p)
    [self flushWindow:nil force:YES];
}
#endif
#endif

/* Some key bindings in mac_apple_event_map are regarded as methods in
   the application delegate.  */

- (BOOL)respondsToSelector:(SEL)aSelector
{
  return ([super respondsToSelector:aSelector]
	  || is_action_selector (aSelector)
	  || is_services_handler_selector (aSelector));
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector
{
  NSMethodSignature *signature = [super methodSignatureForSelector:aSelector];

  if (signature)
    return signature;
  else if (is_action_selector (aSelector))
    return action_signature ();
  else if (is_services_handler_selector (aSelector))
    return services_handler_signature ();
  else
    return nil;
}

- (void)forwardInvocation:(NSInvocation *)anInvocation
{
  SEL selector = [anInvocation selector];
  NSMethodSignature *signature = [anInvocation methodSignature];

  if (is_action_selector (selector)
      && [signature isEqual:(action_signature ())])
    handle_action_invocation (anInvocation);
  else if (is_services_handler_selector (selector)
	   && [signature isEqual:(services_handler_signature ())])
    handle_services_invocation (anInvocation);
  else
    [super forwardInvocation:anInvocation];
}

- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)anItem
{
  SEL action = [anItem action];

  return action == @selector(activate:) || is_action_selector (action);
}

- (void)updatePresentationOptions
{
  NSWindow *window = [NSApp keyWindow].topLevelWindow;

  if (![NSApp isActive])
    {
      needsUpdatePresentationOptionsOnBecomingActive = YES;

      return;
    }

  if ([window isKindOfClass:[EmacsWindow class]])
    {
      EmacsFrameController *frameController = ((EmacsFrameController *)
					       [window delegate]);
      WMState windowManagerState = [frameController windowManagerState];
      NSApplicationPresentationOptions options;

      if (has_full_screen_with_dedicated_desktop_p ()
	  && ((options = [NSApp presentationOptions],
	       (options & NSApplicationPresentationFullScreen))
	      || (windowManagerState & WM_STATE_DEDICATED_DESKTOP)))
	{
	  if ((options & (NSApplicationPresentationFullScreen
			  | NSApplicationPresentationAutoHideMenuBar))
	      == NSApplicationPresentationFullScreen
	      /* Application can be in full screen mode without hiding
		 the dock on OS X 10.9.  OS X prior to 10.11 cannot
		 auto-hide the menu bar without hiding the dock.  */
	      && (can_auto_hide_menu_bar_without_hiding_dock_p ()
		  || (options & (NSApplicationPresentationHideDock
				 | NSApplicationPresentationAutoHideDock))))
	    {
	      options |= NSApplicationPresentationAutoHideMenuBar;
	      [NSApp setPresentationOptions:options];
	    }
	}
      else if (windowManagerState & WM_STATE_FULLSCREEN)
	{
	  NSScreen *screen = [window screen];

	  if ([screen canShowMenuBar])
	    {
	      options = NSApplicationPresentationAutoHideMenuBar;
	      if (!can_auto_hide_menu_bar_without_hiding_dock_p ()
		  || [screen containsDock])
		options |= NSApplicationPresentationAutoHideDock;
	    }
	  else if ([screen containsDock])
	    options = NSApplicationPresentationAutoHideDock;
	  else
	    options = NSApplicationPresentationDefault;
	  [NSApp setPresentationOptions:options];
	}
      else if (windowManagerState & WM_STATE_NO_MENUBAR)
	{
	  NSArrayOf (NSNumber *) *windowNumbers =
	    [NSWindow windowNumbersWithOptions:0];

	  options = NSApplicationPresentationDefault;
	  for (NSWindow *window in [NSApp windows])
	    if ([window isKindOfClass:[EmacsWindow class]]
		&& window.isVisible && window.parentWindow == nil)
	      {
		if (windowNumbers)
		  {
		    NSNumber *windowNumber =
		      [NSNumber numberWithInteger:[window windowNumber]];

		    if (![windowNumbers containsObject:windowNumber])
		      continue;
		  }

		frameController = (EmacsFrameController *) [window delegate];
		windowManagerState = [frameController windowManagerState];
		if (has_full_screen_with_dedicated_desktop_p ()
		    && (windowManagerState & WM_STATE_DEDICATED_DESKTOP))
		  ;
		else if (windowManagerState & WM_STATE_FULLSCREEN)
		  {
		    NSScreen *screen = [window screen];

		    if ([screen canShowMenuBar])
		      {
			options |= NSApplicationPresentationAutoHideMenuBar;
			if (!can_auto_hide_menu_bar_without_hiding_dock_p ()
			    || [screen containsDock])
			  options |= NSApplicationPresentationAutoHideDock;
		      }
		    else if ([screen containsDock])
		      options |= NSApplicationPresentationAutoHideDock;
		  }
	      }
	  [NSApp setPresentationOptions:options];
	}
      else
	[NSApp setPresentationOptions:NSApplicationPresentationDefault];
    }
}

- (void)showMenuBar
{
  NSWindow *window = [NSApp keyWindow].topLevelWindow;;

  if ([window isKindOfClass:[EmacsWindow class]])
    {
      EmacsFrameController *frameController = ((EmacsFrameController *)
					       [window delegate]);
      WMState windowManagerState = [frameController windowManagerState];
      NSApplicationPresentationOptions options;

      if (has_full_screen_with_dedicated_desktop_p ()
	  && ((options = [NSApp presentationOptions],
	       (options & NSApplicationPresentationFullScreen))
	      || (windowManagerState & WM_STATE_DEDICATED_DESKTOP)))
	{
	  if ((options & (NSApplicationPresentationFullScreen
			  | NSApplicationPresentationAutoHideMenuBar))
	      == (NSApplicationPresentationFullScreen
		  | NSApplicationPresentationAutoHideMenuBar))
	    {
	      options &= ~NSApplicationPresentationAutoHideMenuBar;
	      [NSApp setPresentationOptions:options];
	    }
	}
      else if (windowManagerState & WM_STATE_FULLSCREEN)
	{
	  NSScreen *screen = [window screen];

	  if ([screen canShowMenuBar])
	    {
	      options = NSApplicationPresentationDisableMenuBarTransparency;
	      if (!can_auto_hide_menu_bar_without_hiding_dock_p ()
		  || [screen containsDock])
		options |= NSApplicationPresentationAutoHideDock;
	      [NSApp setPresentationOptions:options];
	    }
	}
    }
}

@end				// EmacsController

OSStatus
install_application_handler (void)
{
  mac_within_gui (^{
      [EmacsApplication sharedApplication];
      emacsController = [[EmacsController alloc] init];
      [NSApp setDelegate:emacsController];

      /* Will be stopped at applicationDidFinishLaunching: in the
	 delegate.  */
      [NSApp run];
    });

  return noErr;
}

Lisp_Object
mac_application_state (void)
{
  Lisp_Object result = Qnil;

  if (NSApp == nil)
    return result;

  result = Fcons (QChidden_p, Fcons ([NSApp isHidden] ? Qt : Qnil, result));
  result = Fcons (QCactive_p, Fcons ([NSApp isActive] ? Qt : Qnil, result));
  if ([NSApp respondsToSelector:@selector(effectiveAppearance)])
    result = Fcons (QCappearance,
		    Fcons ([NSApp effectiveAppearance].name.lispString,
			   result));

  return result;
}


/************************************************************************
			       Windows
 ************************************************************************/

static void set_global_focus_view_frame (struct frame *);
static CGRect unset_global_focus_view_frame (void);
static void mac_move_frame_window_structure_1 (struct frame *, int, int);

#define DEFAULT_NUM_COLS (80)
#define RESIZE_CONTROL_WIDTH (15)
#define RESIZE_CONTROL_HEIGHT (15)

@implementation EmacsWindow

- (instancetype)initWithContentRect:(NSRect)contentRect
			  styleMask:(NSWindowStyleMask)windowStyle
			    backing:(NSBackingStoreType)bufferingType
			      defer:(BOOL)deferCreation
{
  self = [super initWithContentRect:contentRect styleMask:windowStyle
			    backing:bufferingType defer:deferCreation];
  if (self == nil)
    return nil;

  [[NSNotificationCenter defaultCenter]
    addObserver:self
    selector:@selector(applicationDidUnhide:)
    name:NSApplicationDidUnhideNotification
    object:NSApp];

  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [observedTabGroup removeObserver:self forKeyPath:@"overviewVisible"];
#if !USE_ARC
  [observedTabGroup release];
  [mouseUpEvent release];
  [super dealloc];
#endif
}

- (BOOL)canBecomeKeyWindow
{
  return ((EmacsFrameController *) self.delegate).acceptsFocus;
}

- (BOOL)canBecomeMainWindow
{
  return self.isVisible && self.parentWindow == nil;
}

- (void)setFrame:(NSRect)windowFrame display:(BOOL)displayViews
{
  if (self.hasTitleBar)
    [super setFrame:windowFrame display:displayViews];
  else
    [super setFrame:[self constrainFrameRect:windowFrame toScreen:nil]
	    display:displayViews];
}

- (void)setFrameOrigin:(NSPoint)point
{
  if (self.hasTitleBar)
    [super setFrameOrigin:point];
  else
    {
      NSRect frameRect = [self frame];

      frameRect.origin = point;
      frameRect = [self constrainFrameRect:frameRect toScreen:nil];

      [super setFrameOrigin:frameRect.origin];
    }
}

- (Lisp_Object)lispFrame
{
  Lisp_Object result;

  XSETFRAME (result, [((EmacsFrameController *) [self delegate]) emacsFrame]);

  return result;
}

- (void)setupResizeTracking:(NSEvent *)event
{
  resizeTrackingStartWindowSize = [self frame].size;
  resizeTrackingStartLocation = [event locationInWindow];
}

- (void)suspendResizeTracking:(NSEvent *)event
	   positionAdjustment:(NSPoint)adjustment
{
  NSPoint locationInWindow = [event locationInWindow];

  if (!has_resize_indicator_at_bottom_right_p ()
      /* OS X 10.9 no longer needs position adjustment.  */
      && floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_8)
    {
      if (resizeTrackingStartLocation.x * 2
	  < resizeTrackingStartWindowSize.width)
	locationInWindow.x += adjustment.x;
      if (!(resizeTrackingStartLocation.y * 2
	    <= resizeTrackingStartWindowSize.height))
	locationInWindow.y -= adjustment.y;
    }
  mouseUpEvent = MRC_RETAIN ([event
			       mouseEventByChangingType:NSEventTypeLeftMouseUp
					    andLocation:locationInWindow]);
  [NSApp postEvent:mouseUpEvent atStart:YES];
  MOUSE_TRACKING_SET_RESUMPTION (emacsController, self, resumeResizeTracking);
}

- (void)resumeResizeTracking
{
  NSPoint location;
  NSEvent *mouseDownEvent;
  NSRect frame = [self frame];

  if (has_resize_indicator_at_bottom_right_p ())
    {
      location.x = (NSWidth (frame) + resizeTrackingStartLocation.x
		    - resizeTrackingStartWindowSize.width);
      location.y = resizeTrackingStartLocation.y;
    }
  else
    {
      NSPoint hysteresisCancelLocation;
      NSEvent *hysteresisCancelDragEvent;

      if (resizeTrackingStartLocation.x * 2
	  < resizeTrackingStartWindowSize.width)
	{
	  location.x = resizeTrackingStartLocation.x;
	  if (resizeTrackingStartLocation.x < RESIZE_CONTROL_WIDTH)
	    hysteresisCancelLocation.x = location.x + RESIZE_CONTROL_WIDTH;
	  else
	    hysteresisCancelLocation.x = location.x;
	}
      else
	{
	  location.x = (NSWidth (frame) + resizeTrackingStartLocation.x
			- resizeTrackingStartWindowSize.width);
	  if (resizeTrackingStartLocation.x
	      >= resizeTrackingStartWindowSize.width - RESIZE_CONTROL_WIDTH)
	    hysteresisCancelLocation.x = location.x - RESIZE_CONTROL_WIDTH;
	  else
	    hysteresisCancelLocation.x = location.x;
	}
      if (resizeTrackingStartLocation.y * 2
	  <= resizeTrackingStartWindowSize.height)
	{
	  location.y = resizeTrackingStartLocation.y;
	  if (resizeTrackingStartLocation.y <= RESIZE_CONTROL_HEIGHT)
	    hysteresisCancelLocation.y = location.y + RESIZE_CONTROL_HEIGHT;
	  else
	    hysteresisCancelLocation.y = location.y;
	}
      else
	{
	  location.y = (NSHeight (frame) + resizeTrackingStartLocation.y
			- resizeTrackingStartWindowSize.height);
	  if (resizeTrackingStartLocation.y
	      > resizeTrackingStartWindowSize.height - RESIZE_CONTROL_HEIGHT)
	    hysteresisCancelLocation.y = location.y - RESIZE_CONTROL_HEIGHT;
	  else
	    hysteresisCancelLocation.y = location.y;
	}

      hysteresisCancelDragEvent =
	[mouseUpEvent mouseEventByChangingType:NSEventTypeLeftMouseDragged
				   andLocation:hysteresisCancelLocation];
      [NSApp postEvent:hysteresisCancelDragEvent atStart:YES];
    }

  mouseDownEvent = [mouseUpEvent
		     mouseEventByChangingType:NSEventTypeLeftMouseDown
				  andLocation:location];
  MRC_RELEASE (mouseUpEvent);
  mouseUpEvent = nil;
  [NSApp postEvent:mouseDownEvent atStart:YES];
  setupResizeTrackingSuspended = YES;
}

- (void)sendEvent:(NSEvent *)event
{
  if ([event type] == NSEventTypeLeftMouseDown)
    {
      if (setupResizeTrackingSuspended)
	setupResizeTrackingSuspended = NO;
      else
	[self setupResizeTracking:event];
    }

  [super sendEvent:event];
}

- (BOOL)needsOrderFrontOnUnhide
{
  return needsOrderFrontOnUnhide;
}

- (void)setNeedsOrderFrontOnUnhide:(BOOL)flag
{
  needsOrderFrontOnUnhide = flag;
}

- (void)applicationDidUnhide:(NSNotification *)notification
{
  if (needsOrderFrontOnUnhide)
    {
      [self orderFront:nil];
      needsOrderFrontOnUnhide = NO;
    }

  /* This is a workaround: when the application is unhidden, a
     top-level window may become a (bogus) key window when one of its
     descendants is a (real) key window.  This is problematic because
     a single mouse movement event may be sent to both of the
     top-level and descendant windows.  */
  if (self.isKeyWindow && ![self isEqual:[NSApp keyWindow]])
    [self resignKeyWindow];
}

- (void)suspendConstrainingToScreen:(BOOL)flag
{
  if (flag)
    constrainingToScreenSuspensionCount++;
  else
    {
      if (constrainingToScreenSuspensionCount > 0)
	constrainingToScreenSuspensionCount--;
      else
	eassert (false);
    }
}

- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen
{
  if (constrainingToScreenSuspensionCount == 0)
    {
      id delegate = [self delegate];

      frameRect = [super constrainFrameRect:frameRect toScreen:screen];
      if ([delegate
	    respondsToSelector:@selector(window:willConstrainFrame:toScreen:)])
	frameRect = [delegate window:self willConstrainFrame:frameRect
			    toScreen:screen];
    }

  return frameRect;
}

- (void)zoom:(id)sender
{
  id delegate = [self delegate];
  id target = emacsController;

  if ([delegate respondsToSelector:@selector(window:shouldForwardAction:to:)]
      && [delegate window:self shouldForwardAction:_cmd to:target])
    [NSApp sendAction:_cmd to:target from:sender];
  else
    {
      EmacsFrameController *frameController = (EmacsFrameController *) delegate;
      [frameController setShouldLiveResizeTriggerTransition:YES];
      [super zoom:sender];
      [frameController setShouldLiveResizeTriggerTransition:NO];
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
  SEL action = [menuItem action];

  if (action == @selector(runToolbarCustomizationPalette:))
    return NO;

  return [super validateMenuItem:menuItem];
}

- (void)toggleToolbarShown:(id)sender
{
  Lisp_Object alist =
    list1 (Fcons (Qtool_bar_lines,
		  make_number ([(NSMenuItem *)sender state]
			       != NSControlStateValueOff)));
  EmacsFrameController *frameController = ((EmacsFrameController *)
					   [self delegate]);

  [frameController storeModifyFrameParametersEvent:alist];
}

- (void)changeToolbarDisplayMode:(id)sender
{
  [NSApp sendAction:(NSSelectorFromString (@"change-toolbar-display-mode:"))
		 to:nil from:sender];
}

- (NSWindow *)tabPickerWindow
{
  /* The tab group overview is displayed in NSTabPickerWindow on macOS
     10.15, and -[NSWindowTabGroup isOverviewVisible] returns NO while
     exiting from the overview.  */
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_14))
    {
      NSWindowTabGroup *tabGroup = self.tabGroup;

      if (tabGroup)
	{
	  NSArrayOf (NSWindow *) *windowsInTabGroup = tabGroup.windows;

	  for (NSWindow *window in [NSApp windows])
	    if (window.isVisible
		&& [window.tabGroup isEqual:tabGroup]
		&& ![windowsInTabGroup containsObject:window])
	      return window;
	}
    }

  return nil;
}

- (void)exitTabGroupOverview
{
  if ([self respondsToSelector:@selector(tabGroup)])
    {
      NSWindowTabGroup *tabGroup = self.tabGroup;

      if (tabGroup.isOverviewVisible || self.tabPickerWindow)
	{
	  tabGroup.overviewVisible = NO;
	  while (tabGroup.isOverviewVisible || self.tabPickerWindow)
	    mac_run_loop_run_once (kEventDurationForever);
	}
    }
}

- (void)toggleTabOverview:(id)sender
{
  NSWindowTabGroup *tabGroup = self.tabGroup;

  if (!tabGroup.isOverviewVisible)
    {
      id delegate = self.delegate;

      [tabGroup addObserver:self forKeyPath:@"overviewVisible"
		    options:NSKeyValueObservingOptionNew context:nil];
      observedTabGroup = MRC_RETAIN (tabGroup);

      if ([delegate respondsToSelector:@selector(windowWillEnterTabOverview)])
	[delegate windowWillEnterTabOverview];
    }

  [super toggleTabOverview:sender];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionaryOf (NSKeyValueChangeKey, id) *)change
                       context:(void *)context
{
  if ([keyPath isEqualToString:@"overviewVisible"])
    {
      if (!((NSNumber *)
	    [change objectForKey:NSKeyValueChangeNewKey]).charValue)
	{
	  id delegate = self.delegate;

	  if ([delegate respondsToSelector:@selector(windowDidExitTabOverview)])
	    [delegate windowDidExitTabOverview];
	  [object removeObserver:self forKeyPath:keyPath];
	  MRC_RELEASE (observedTabGroup);
	  observedTabGroup = nil;
	}
    }
  else
    [super observeValueForKeyPath:keyPath ofObject:object change:change
			  context:context];
}

- (id <NSAppearanceCustomization>)appearanceCustomization
{
  if (!has_visual_effect_view_p ())
    return nil;
  else if (has_system_appearance_p ())
    return self.contentView;
  else
    return self;
}

@end				// EmacsWindow

@implementation EmacsFrameController

- (instancetype)initWithEmacsFrame:(struct frame *)f
{
  self = [self init];
  if (self == nil)
    return nil;

  emacsFrame = f;

  [self setupEmacsView];
  [self setupWindow];

  return self;
}

- (void)setupEmacsView
{
  struct frame *f = emacsFrame;

  if (!FRAME_TOOLTIP_P (f))
    {
      NSRect frameRect = NSMakeRect (0, 0, FRAME_PIXEL_WIDTH (f),
				     FRAME_PIXEL_HEIGHT (f));
      EmacsMainView *mainView = [[EmacsMainView alloc] initWithFrame:frameRect];

      [mainView setAction:@selector(storeInputEvent:)];
      emacsView = mainView;
    }
  else
    {
      NSRect frameRect = NSMakeRect (0, 0, 100, 100);

      emacsView = [[EmacsView alloc] initWithFrame:frameRect];
    }
  [emacsView setAutoresizingMask:(NSViewMaxXMargin | NSViewMinYMargin
				  | NSViewWidthSizable | NSViewHeightSizable)];
  emacsView.layerContentsRedrawPolicy =
    NSViewLayerContentsRedrawOnSetNeedsDisplay;
  emacsView.layerContentsPlacement = NSViewLayerContentsPlacementTopLeft;
}

- (void)setupOverlayView
{
  NSRect contentRect = NSMakeRect (0, 0, 64, 64);

  if (overlayView)
    return;

  overlayView = [[EmacsOverlayView alloc] initWithFrame:contentRect];
  [overlayView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
  [overlayView setLayer:[CALayer layer]];
  [overlayView setWantsLayer:YES];
  /* OS X 10.9 needs this.  */
  if ([overlayView respondsToSelector:@selector(setLayerUsesCoreImageFilters:)])
    [overlayView setLayerUsesCoreImageFilters:YES];

  [self setupAnimationLayer];

  /* We add overlayView to the view hierarchy only when it is
     necessary.  Otherwise the CVDisplayLink thread would take much
     CPU time especially with application-side double buffering.  */
  [overlayView.layer addObserver:self forKeyPath:@"sublayers"
			 options:NSKeyValueObservingOptionPrior context:nil];
  [animationLayer addObserver:self forKeyPath:@"sublayers"
		      options:NSKeyValueObservingOptionPrior context:nil];
  [overlayView.layer setValue:((id) kCFBooleanFalse) forKey:@"showingBorder"];
  [overlayView.layer addObserver:self forKeyPath:@"showingBorder"
			 options:0 context:nil];
}

- (void)synchronizeOverlayViewFrame
{
  overlayView.frame = [emacsWindow.contentView bounds];
}

- (void)updateOverlayViewParticipation
{
  BOOL shouldShowOverlayView =
    (has_resize_indicator_at_bottom_right_p ()
     || overlayView.layer.sublayers.count > 1
     || animationLayer.sublayers.count != 0
     || ([overlayView.layer valueForKey:@"showingBorder"]
	 == (id) kCFBooleanTrue));

  if (overlayView.superview && !shouldShowOverlayView)
    [overlayView removeFromSuperview];
  else if (!overlayView.superview && shouldShowOverlayView)
    {
      /* We place overlayView below emacsView so events are not
	 intercepted by the former.  Still the former (layer-hosting)
	 is displayed in front of the latter (neither layer-backed nor
	 layer-hosting).  */
      /* Unfortunately, this trick does not work on macOS 10.14.
	 Placing overlayView above emacsView (with returning nil in
	 hitTest:) works if the executable is linked against the macOS
	 10.14 SDK, but not for the one linked on the older versions
	 then run on macOS 10.14.  Making overlayView a subview of
	 emacsView works for both cases.  Note that we need to
	 temporarily hide overlayView when taking screenshot in
	 -[EmacsFrameController bitmapImageRepInEmacsViewRect:].  */
      /* If emacsView is layer-backed, which is the case when the
	 executable is linked against the macOS 10.14 SDK, then the
	 live resize transition layer used in full screen transition
	 looks translucent if we make overlayView a subview of
	 emacsView.  */
      if (emacsView.layer)
	[emacsWindow.contentView addSubview:overlayView];
      else if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_13))
	[emacsView addSubview:overlayView];
      else
	[emacsWindow.contentView addSubview:overlayView positioned:NSWindowBelow
				 relativeTo:emacsView];
      [self synchronizeOverlayViewFrame];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
			change:(NSDictionaryOf (NSKeyValueChangeKey, id) *)change
		       context:(void *)context
{
  BOOL updateOverlayViewParticipation = NO;

  if ([keyPath isEqualToString:@"sublayers"])
    {
      if ([change objectForKey:NSKeyValueChangeNotificationIsPriorKey])
	[self synchronizeOverlayViewFrame];
      else
	updateOverlayViewParticipation = YES;
    }
  else if ([keyPath isEqualToString:@"showingBorder"])
    updateOverlayViewParticipation = YES;

  if (updateOverlayViewParticipation)
    {
      if (!popup_activated ())
	[self updateOverlayViewParticipation];
      else
	[self performSelector:@selector(updateOverlayViewParticipation)
		   withObject:nil afterDelay:0];
    }
}

- (void)setupWindow
{
  struct frame *f = emacsFrame;
  EmacsWindow *oldWindow = emacsWindow;
  NSRect contentRect;
  NSWindowStyleMask windowStyle;
  EmacsWindow *window;

  if (!FRAME_TOOLTIP_P (f))
    {
      if (!self.shouldBeTitled)
	windowStyle = NSWindowStyleMaskBorderless;
      else
	windowStyle = (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
		       | NSWindowStyleMaskMiniaturizable
		       | NSWindowStyleMaskResizable);
    }
  else
    windowStyle = NSWindowStyleMaskBorderless;

  if (oldWindow == nil)
    {
      NSScreen *screen = nil;

      if (f->size_hint_flags & (USPosition | PPosition))
	screen = [NSScreen screenContainingPoint:(NSMakePoint (f->left_pos,
							       f->top_pos))];
      if (screen == nil)
	screen = [NSScreen mainScreen];
      contentRect.origin = [screen frame].origin;
      contentRect.size = [emacsView frame].size;
    }
  else
    {
      NSView *contentView = [oldWindow contentView];

      contentRect = [contentView frame];
      contentRect.origin = [[contentView superview]
			     convertPoint:contentRect.origin toView:nil];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
      contentRect.origin = [oldWindow convertRectToScreen:contentRect].origin;
#else
      contentRect.origin = [oldWindow convertBaseToScreen:contentRect.origin];
#endif
    }

  window = [[EmacsWindow alloc] initWithContentRect:contentRect
					  styleMask:windowStyle
					    backing:NSBackingStoreBuffered
					      defer:YES];
#if USE_ARC
  /* Increase retain count to accommodate itself to
     released-when-closed on ARC.  Just setting released-when-closed
     to NO leads to crash in some situations.  */
  CF_BRIDGING_RETAIN (window);
#endif
  if (has_visual_effect_view_p ())
    {
      id visualEffectView = [[(NSClassFromString (@"NSVisualEffectView")) alloc]
			      initWithFrame:[window.contentView frame]];

      window.contentView = visualEffectView;
      MRC_RELEASE (visualEffectView);
      FRAME_BACKGROUND_ALPHA_ENABLED_P (f) = true;
    }
  if (FRAME_MAC_DOUBLE_BUFFERED_P (f))
    {
      FRAME_SYNTHETIC_BOLD_WORKAROUND_DISABLED_P (f) = true;
      if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_13)
	[window.contentView setWantsLayer:YES];
    }
  if (oldWindow)
    {
      [window setTitle:[oldWindow title]];
      [window setDocumentEdited:[oldWindow isDocumentEdited]];
      [window setAlphaValue:[oldWindow alphaValue]];
      [window setBackgroundColor:[oldWindow backgroundColor]];
      [window setRepresentedFilename:[oldWindow representedFilename]];
      [window setCollectionBehavior:[oldWindow collectionBehavior]];
      window.level = oldWindow.level;
      [window setExcludedFromWindowsMenu:oldWindow.isExcludedFromWindowsMenu];
      for (NSWindow *childWindow in oldWindow.childWindows)
	if ([childWindow isKindOfClass:[EmacsWindow class]])
	  {
	    [(EmacsWindow *)childWindow suspendConstrainingToScreen:YES];
	    [oldWindow removeChildWindow:childWindow];
	    [(EmacsWindow *)childWindow suspendConstrainingToScreen:NO];
	    [window addChildWindow:childWindow ordered:NSWindowAbove];
	  }
      window.appearanceCustomization.appearance =
	oldWindow.appearanceCustomization.appearance;

      [oldWindow setDelegate:nil];
      [self hideHourglass:nil];
      hourglassWindow = nil;
    }

  emacsWindow = window;
  [window setDelegate:self];
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_9)
    [window useOptimizedDrawing:YES];
#endif
  [[window contentView] addSubview:emacsView];
  [self updateBackingScaleFactor];
  [self updateEmacsViewIsHiddenOrHasHiddenAncestor];
#if HAVE_MAC_METAL
  [self updateEmacsViewMTLObjects];
#endif

  if (oldWindow)
    {
      BOOL isKeyWindow = [oldWindow isKeyWindow];
      NSWindow *parentWindow = oldWindow.parentWindow;

      if (parentWindow == nil)
	[window orderWindow:NSWindowBelow relativeTo:[oldWindow windowNumber]];
      else
	{
	  [parentWindow addChildWindow:window ordered:NSWindowAbove];
	  /* Mac OS X 10.6 needs this.  */
	  [parentWindow removeChildWindow:oldWindow];
	}
      if ([window respondsToSelector:@selector(setAnimationBehavior:)])
	[window setAnimationBehavior:[oldWindow animationBehavior]];
      [oldWindow close];
      /* This is necessary on OS X 10.11.  */
      if (isKeyWindow)
	[window makeKeyWindow];
    }

  if (!FRAME_TOOLTIP_P (f))
    {
      window.hasShadow = self.shouldHaveShadow;
      [window setAcceptsMouseMovedEvents:YES];
      if (window.hasTitleBar)
	[self setupToolBarWithVisibility:(FRAME_EXTERNAL_TOOL_BAR (f))];
      if (has_resize_indicator_at_bottom_right_p ())
	[window setShowsResizeIndicator:NO];
      [self setupOverlayView];
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
      if (has_resize_indicator_at_bottom_right_p ())
	[overlayView setShowsResizeIndicator:self.shouldBeTitled];
#endif
      [self updateOverlayViewParticipation];
      if (has_full_screen_with_dedicated_desktop_p ()
	  && !(windowManagerState & WM_STATE_FULLSCREEN)
	  && !FRAME_PARENT_FRAME (f))
	window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
      if ([window respondsToSelector:@selector(setAnimationBehavior:)])
	[window setAnimationBehavior:NSWindowAnimationBehaviorDocumentWindow];
    }
  else
    {
      [window setHasShadow:YES];
      [window setLevel:NSScreenSaverWindowLevel];
      [window setIgnoresMouseEvents:YES];
      [window setExcludedFromWindowsMenu:YES];
      if ([window respondsToSelector:@selector(setAnimationBehavior:)])
	[window setAnimationBehavior:NSWindowAnimationBehaviorNone];
    }
}

- (void)closeWindow
{
  /* We temporarily run application when closing a window.  That
     causes emacsView to receive drawRect: before closing a tabbed
     window on macOS 10.12.  It is too late to remove the view in the
     windowWillClose: delegate method, so we remove it here.  */
  [emacsView removeFromSuperview];
  [emacsWindow close];
}

- (struct frame *)emacsFrame
{
  return emacsFrame;
}

- (EmacsWindow *)emacsWindow
{
  return emacsWindow;
}

- (void)dealloc
{
  [overlayView.layer removeObserver:self forKeyPath:@"sublayers"];
  [animationLayer removeObserver:self forKeyPath:@"sublayers"];
  [overlayView.layer removeObserver:self forKeyPath:@"showingBorder"];
#if !USE_ARC
  [savedChildWindowAlphaMap release];
  [emacsView release];
  /* emacsWindow and hourglassWindow are released via
     released-when-closed.  */
  [overlayView release];
  [super dealloc];
#endif
}

- (BOOL)acceptsFocus
{
  struct frame *f = emacsFrame;

  return !FRAME_TOOLTIP_P (f) && !FRAME_NO_ACCEPT_FOCUS (f);
}

- (NSSize)hintedWindowFrameSize:(NSSize)frameSize allowsLarger:(BOOL)flag
{
  struct frame *f = emacsFrame;
  XSizeHints *size_hints = FRAME_SIZE_HINTS (f);
  NSRect windowFrame, emacsViewBounds;
  NSSize emacsViewSizeInPixels, emacsViewSize;
  CGFloat dw, dh, min_width, min_height;

  windowFrame = [emacsWindow frame];
  if (size_hints == NULL)
    return windowFrame.size;

  emacsViewBounds = [emacsView bounds];
  emacsViewSizeInPixels = [emacsView convertSize:emacsViewBounds.size
				     toView:nil];
  dw = NSWidth (windowFrame) - emacsViewSizeInPixels.width;
  dh = NSHeight (windowFrame) - emacsViewSizeInPixels.height;
  emacsViewSize = [emacsView convertSize:(NSMakeSize (frameSize.width - dw,
						      frameSize.height - dh))
				fromView:nil];

  min_width = (size_hints->min_width ? size_hints->min_width
	       : size_hints->width_inc);
  if (emacsViewSize.width < min_width)
    emacsViewSize.width = min_width;
  else
    emacsViewSize.width = size_hints->base_width
      + (int) ((emacsViewSize.width - size_hints->base_width)
	       / size_hints->width_inc + (flag ? .5f : 0))
      * size_hints->width_inc;

  min_height = (size_hints->min_height ? size_hints->min_height
	       : size_hints->height_inc);
  if (emacsViewSize.height < min_height)
    emacsViewSize.height = min_height;
  else
    emacsViewSize.height = size_hints->base_height
      + (int) ((emacsViewSize.height - size_hints->base_height)
	       / size_hints->height_inc + (flag ? .5f : 0))
      * size_hints->height_inc;

  emacsViewSizeInPixels = [emacsView convertSize:emacsViewSize toView:nil];

  return NSMakeSize (emacsViewSizeInPixels.width + dw,
		     emacsViewSizeInPixels.height + dh);
}

- (NSRect)window:(NSWindow *)sender willConstrainFrame:(NSRect)frameRect
	toScreen:(NSScreen *)screen
{
  if (windowManagerState & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT
			    | WM_STATE_FULLSCREEN))
    {
      NSWindow *parentWindow = sender.parentWindow;

      if (parentWindow == nil)
	{
	  if (screen == nil)
	    {
	      NSEvent *currentEvent = [NSApp currentEvent];

	      if (currentEvent.type == NSEventTypeLeftMouseUp)
		{
		  /* Probably end of title bar dragging.  */
		  NSWindow *eventWindow = [currentEvent window];
		  NSPoint location = [currentEvent locationInWindow];

		  if (eventWindow)
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
		    location =
		      [eventWindow
			convertRectToScreen:(NSMakeRect (location.x, location.y,
							 0, 0))].origin;
#else
		  location = [eventWindow convertBaseToScreen:location];
#endif

		  screen = [NSScreen screenContainingPoint:location];
		}

	      if (screen == nil)
		screen = [NSScreen closestScreenForRect:frameRect];
	    }

	  if (windowManagerState & WM_STATE_FULLSCREEN)
	    frameRect = screen.frame;
	  else
	    {
	      NSRect screenVisibleFrame = screen.visibleFrame;

	      if (windowManagerState & WM_STATE_MAXIMIZED_HORZ)
		{
		  frameRect.origin.x = screenVisibleFrame.origin.x;
		  frameRect.size.width = screenVisibleFrame.size.width;
		}
	      if (windowManagerState & WM_STATE_MAXIMIZED_VERT)
		{
		  frameRect.origin.y = screenVisibleFrame.origin.y;
		  frameRect.size.height = screenVisibleFrame.size.height;
		}
	    }
	}
      else			/* parentWindow != nil */
	{
	  NSView *parentContentView = parentWindow.contentView;
	  NSRect parentContentRect = parentContentView.bounds;

	  parentContentRect = [parentContentView convertRect:parentContentRect
						      toView:nil];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
	  parentContentRect.origin =
	    [parentWindow convertRectToScreen:parentContentRect].origin;
#else
	  parentContentRect.origin =
	    [parentWindow convertBaseToScreen:parentContentRect.origin];
#endif

	  if (windowManagerState & WM_STATE_FULLSCREEN)
	    frameRect = parentContentRect;
	  else
	    {
	      if (windowManagerState & WM_STATE_MAXIMIZED_HORZ)
		{
		  frameRect.origin.x = parentContentRect.origin.x;
		  frameRect.size.width = parentContentRect.size.width;
		}
	      if (windowManagerState & WM_STATE_MAXIMIZED_VERT)
		{
		  frameRect.origin.y = parentContentRect.origin.y;
		  frameRect.size.height = parentContentRect.size.height;
		}
	    }
	}
    }

  return frameRect;
}

- (WMState)windowManagerState
{
  return windowManagerState;
}

- (void)updateCollectionBehavior
{
  NSWindowCollectionBehavior behavior;

  if ((windowManagerState & WM_STATE_NO_MENUBAR)
      && !(windowManagerState & WM_STATE_FULLSCREEN))
    {
      behavior = ((windowManagerState & WM_STATE_STICKY)
		  ? NSWindowCollectionBehaviorCanJoinAllSpaces
		  : NSWindowCollectionBehaviorMoveToActiveSpace);
      if (has_full_screen_with_dedicated_desktop_p ())
	behavior |= NSWindowCollectionBehaviorFullScreenAuxiliary;
    }
  else
    {
      behavior = ((windowManagerState & WM_STATE_STICKY)
		  ? NSWindowCollectionBehaviorCanJoinAllSpaces
		  : NSWindowCollectionBehaviorDefault);
      if (has_full_screen_with_dedicated_desktop_p ()
	  && (!(windowManagerState & WM_STATE_FULLSCREEN)
	      || (windowManagerState & WM_STATE_DEDICATED_DESKTOP)))
	behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    }
  behavior |= ((windowManagerState & WM_STATE_SKIP_TASKBAR)
	       ? NSWindowCollectionBehaviorIgnoresCycle
	       : NSWindowCollectionBehaviorParticipatesInCycle);
  behavior |= ((windowManagerState & WM_STATE_OVERRIDE_REDIRECT)
	       ? NSWindowCollectionBehaviorTransient
	       : NSWindowCollectionBehaviorManaged);
  [emacsWindow setCollectionBehavior:behavior];

  [emacsWindow setExcludedFromWindowsMenu:((windowManagerState
					    & WM_STATE_SKIP_TASKBAR) != 0)];
}

- (void)updateWindowLevel;
{
  NSWindowLevel level = NSNormalWindowLevel;

  if (windowManagerState & WM_STATE_ABOVE)
    level++;
  else if (windowManagerState & WM_STATE_BELOW)
    level--;
  emacsWindow.level = level;
}

- (NSRect)preprocessWindowManagerStateChange:(WMState)newState
{
  NSRect frameRect = [emacsWindow frame];
  NSRect screenRect = [[emacsWindow screen] frame];
  WMState oldState, diff;

  oldState = windowManagerState;
  diff = (oldState ^ newState);

  if (diff & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_FULLSCREEN))
    {
      if (!(oldState & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_FULLSCREEN)))
	{
	  savedFrame.origin.x = NSMinX (frameRect) - NSMinX (screenRect);
	  savedFrame.size.width = NSWidth (frameRect);
	}
      else
	{
	  frameRect.origin.x = NSMinX (savedFrame) + NSMinX (screenRect);
	  frameRect.size.width = NSWidth (savedFrame);
	}
    }

  if (diff & (WM_STATE_MAXIMIZED_VERT | WM_STATE_FULLSCREEN))
    {
      if (!(oldState & (WM_STATE_MAXIMIZED_VERT | WM_STATE_FULLSCREEN)))
	{
	  savedFrame.origin.y = NSMinY (frameRect) - NSMaxY (screenRect);
	  savedFrame.size.height = NSHeight (frameRect);
	}
      else
	{
	  frameRect.origin.y = NSMinY (savedFrame) + NSMaxY (screenRect);
	  frameRect.size.height = NSHeight (savedFrame);
	}
    }

  windowManagerState ^=
    (diff & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT
	     | WM_STATE_FULLSCREEN | WM_STATE_DEDICATED_DESKTOP));
  [self updateCollectionBehavior];

  return frameRect;
}

- (NSRect)postprocessWindowManagerStateChange:(NSRect)frameRect
{
  frameRect = [emacsWindow constrainFrameRect:frameRect toScreen:nil];
  if (!(windowManagerState & WM_STATE_FULLSCREEN))
    {
      NSSize hintedFrameSize = [self hintedWindowFrameSize:frameRect.size
					      allowsLarger:NO];

      if (!(windowManagerState & WM_STATE_MAXIMIZED_HORZ))
	frameRect.size.width = hintedFrameSize.width;
      if (!(windowManagerState & WM_STATE_MAXIMIZED_VERT))
	frameRect.size.height = hintedFrameSize.height;
    }

  return frameRect;
}

- (void)changeFullScreenState:(WMState)fullScreenState
{
  eassert (emacsWindow.parentWindow == nil
	   && (!(emacsWindow.styleMask & NSWindowStyleMaskFullScreen)
	       != !(fullScreenState & WM_STATE_DEDICATED_DESKTOP)));

  fullScreenTargetState = fullScreenState;
  [emacsWindow toggleFullScreen:nil];
}

- (void)setWindowManagerState:(WMState)newState
{
  struct frame *f = emacsFrame;
  WMState oldState, diff, fullScreenState;
  const WMState collectionBehaviorStates =
    (WM_STATE_STICKY | WM_STATE_NO_MENUBAR
     | WM_STATE_SKIP_TASKBAR | WM_STATE_OVERRIDE_REDIRECT);
  const WMState windowLevelStates = WM_STATE_ABOVE | WM_STATE_BELOW;
  enum {
    SET_FRAME_UNNECESSARY,
    SET_FRAME_NECESSARY,
    SET_FRAME_TOGGLE_FULL_SCREEN_LATER
  } setFrameType = SET_FRAME_UNNECESSARY;

  oldState = windowManagerState;
  diff = (oldState ^ newState);

  if (diff == 0)
    return;

  if (diff & collectionBehaviorStates)
    {
      windowManagerState ^= (diff & collectionBehaviorStates);
      [self updateCollectionBehavior];
    }

  if (diff & windowLevelStates)
    {
      windowManagerState ^= (diff & windowLevelStates);
      [self updateWindowLevel];
    }

  if (has_full_screen_with_dedicated_desktop_p ()
      && (diff & WM_STATE_DEDICATED_DESKTOP)
      && emacsWindow.parentWindow == nil)
    {
      emacsWindow.collectionBehavior |=
	NSWindowCollectionBehaviorFullScreenPrimary;

      if (diff & WM_STATE_FULLSCREEN)
	[self changeFullScreenState:newState];
      else if (newState & WM_STATE_DEDICATED_DESKTOP)
	{
#if 1
	  /* We once used windows with NSWindowStyleMaskFullScreen for
	     fullboth frames instead of window class replacement, but
	     the use of such windows on non-dedicated Space seems to
	     lead to several glitches.  So we have to replace the
	     window class, and then enter full screen mode, i.e.,
	     fullboth -> maximized -> fullscreen.  */
	  fullScreenState = newState;
	  newState = ((newState & ~WM_STATE_FULLSCREEN)
		      | WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT);
	  diff = (oldState ^ newState);
#endif
	  setFrameType = SET_FRAME_TOGGLE_FULL_SCREEN_LATER;
	}
      else
	{
	  /* Direct transition fullscreen -> fullboth is not trivial
	     even if we use -[NSWindow setStyleMask:], which is
	     available from 10.6, instead of window class replacement,
	     because AppKit strips off NSWindowStyleMaskFullScreen
	     after exiting from the full screen mode.  We make such a
	     transition via maximized state, i.e, fullscreen ->
	     maximized -> fullboth.  */
	  mac_within_lisp (^{
	      store_frame_param (f, Qfullscreen, Qmaximized);
	    });
	  [self changeFullScreenState:((newState & ~WM_STATE_FULLSCREEN)
				       | WM_STATE_MAXIMIZED_HORZ
				       | WM_STATE_MAXIMIZED_VERT)];
	  fullscreenFrameParameterAfterTransition = FULLSCREEN_PARAM_FULLBOTH;
	}
    }
  else if (diff & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT
		| WM_STATE_FULLSCREEN))
      setFrameType = SET_FRAME_NECESSARY;

  if (setFrameType != SET_FRAME_UNNECESSARY)
    {
      NSRect frameRect = [self preprocessWindowManagerStateChange:newState];

      if ((diff & WM_STATE_FULLSCREEN)
	  || setFrameType == SET_FRAME_TOGGLE_FULL_SCREEN_LATER)
	[self updateWindowStyle];

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
      BOOL showsResizeIndicator;

      if ((newState & WM_STATE_FULLSCREEN)
	  || ((newState & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT))
	      == (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT)))
	showsResizeIndicator = NO;
      else
	showsResizeIndicator = YES;
      if (has_resize_indicator_at_bottom_right_p ())
	[overlayView setShowsResizeIndicator:showsResizeIndicator];
#endif
      /* This makes it impossible to toggle toolbar visibility for
	 maximized frames on Mac OS X 10.7.  */
#if 0
      else
	{
	  NSWindowStyleMask styleMask = [emacsWindow styleMask];

	  if (showsResizeIndicator)
	    styleMask |= NSWindowStyleMaskResizable;
	  else
	    styleMask &= ~NSWindowStyleMaskResizable;
	  [emacsWindow setStyleMask:styleMask];
	}
#endif

      frameRect = [self postprocessWindowManagerStateChange:frameRect];
      [emacsWindow setFrame:frameRect display:YES];

      if (setFrameType == SET_FRAME_TOGGLE_FULL_SCREEN_LATER)
	[self changeFullScreenState:fullScreenState];
    }

  [emacsController updatePresentationOptions];
}

- (void)updateBackingScaleFactor
{
  struct frame *f = emacsFrame;
  int backingScaleFactor;

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
  backingScaleFactor = [emacsWindow backingScaleFactor];
#else
  if ([emacsWindow respondsToSelector:@selector(backingScaleFactor)])
    backingScaleFactor = [emacsWindow backingScaleFactor];
  else if ([emacsWindow userSpaceScaleFactor] > 1)
    backingScaleFactor = 2;
  else
    backingScaleFactor = 1;
#endif

  FRAME_BACKING_SCALE_FACTOR (f) = backingScaleFactor;
}

- (BOOL)emacsViewIsHiddenOrHasHiddenAncestor
{
  return emacsViewIsHiddenOrHasHiddenAncestor;
}

- (void)updateEmacsViewIsHiddenOrHasHiddenAncestor
{
  emacsViewIsHiddenOrHasHiddenAncestor =
    [emacsView isHiddenOrHasHiddenAncestor];
}

- (void)displayEmacsViewIfNeeded
{
  [emacsView displayIfNeeded];
}

- (void)lockFocusOnEmacsView
{
  eassert (!FRAME_OBSCURED_P (emacsFrame));
  [emacsView lockFocusOnBacking];
}

- (void)unlockFocusOnEmacsView
{
  [emacsView unlockFocusOnBacking];
}

- (void)scrollEmacsViewRect:(NSRect)rect by:(NSSize)delta
{
  [emacsView scrollBackingRect:rect by:delta];
}

#if HAVE_MAC_METAL
- (void)updateEmacsViewMTLObjects
{
  [emacsView updateMTLObjects];
}
#endif

- (NSPoint)convertEmacsViewPointToScreen:(NSPoint)point
{
  point = [emacsView convertPoint:point toView:nil];

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
  return [emacsWindow
	   convertRectToScreen:(NSMakeRect (point.x, point.y, 0, 0))].origin;
#else
  return [emacsWindow convertBaseToScreen:point];
#endif
}

- (NSPoint)convertEmacsViewPointFromScreen:(NSPoint)point
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
  point = [emacsWindow
	    convertRectFromScreen:(NSMakeRect (point.x, point.y, 0, 0))].origin;
#else
  point = [emacsWindow convertScreenToBase:point];
#endif

  return [emacsView convertPoint:point fromView:nil];
}

- (NSRect)convertEmacsViewRectToScreen:(NSRect)rect
{
  rect = [emacsView convertRect:rect toView:nil];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
  rect.origin = [emacsWindow convertRectToScreen:rect].origin;
#else
  rect.origin = [emacsWindow convertBaseToScreen:rect.origin];
#endif

  return rect;
}

- (NSRect)convertEmacsViewRectFromScreen:(NSRect)rect
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
  rect.origin = [emacsWindow convertRectFromScreen:rect].origin;
#else
  rect.origin = [emacsWindow convertScreenToBase:rect.origin];
#endif
  rect = [emacsView convertRect:rect fromView:nil];

  return rect;
}

- (NSRect)centerScanEmacsViewRect:(NSRect)rect
{
  return [emacsView centerScanRect:rect];
}

- (void)invalidateCursorRectsForEmacsView
{
  [emacsWindow invalidateCursorRectsForView:emacsView];
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
- (void)maskRoundedBottomCorners:(NSRect)clipRect directly:(BOOL)flag
{
  NSRect rect = [emacsView convertRect:clipRect toView:nil];

  rect = [emacsWindow _intersectBottomCornersWithRect:rect];
  if (!NSIsEmptyRect (rect))
    {
      if (flag)
	[emacsWindow _maskRoundedBottomCorners:rect];
      else
	{
	  struct frame *f = emacsFrame;

	  if (!FRAME_GARBAGED_P (f))
	    {
	      NSView *frameView = [[emacsWindow contentView] superview];

	      rect = [frameView convertRect:rect fromView:nil];
	      [frameView displayRectIgnoringOpacity:rect];
	    }
	  else
	    {
	      rect = [emacsView convertRect:rect fromView:nil];
	      [emacsView setNeedsDisplayInRect:rect];
	    }
	}
    }
}
#endif

- (void)setEmacsViewNeedsDisplayInRects:(const NSRect *)rects
				  count:(NSUInteger)count
{
  NSUInteger i;

  for (i = 0; i < count; i++)
    [emacsView setNeedsDisplayInRect:rects[i]];
}

- (void)setEmacsViewNeedsDisplay:(BOOL)flag
{
  emacsView.needsDisplay = flag;
}

/* Delegete Methods.  */

- (void)windowDidBecomeKey:(NSNotification *)notification
{
  struct frame *f = emacsFrame;

  mac_within_lisp_deferred_unless_popup (^{
      struct input_event inev;

      EVENT_INIT (inev);
      inev.arg = Qnil;
      mac_focus_changed (activeFlag, FRAME_DISPLAY_INFO (f), f, &inev);
      if (inev.kind != NO_EVENT)
	[emacsController storeEvent:&inev];
    });

  [self noteEnterEmacsView];

  [emacsController setConflictingKeyBindingsDisabled:YES];

  [emacsController updatePresentationOptions];

  [emacsWindow.topLevelWindow makeMainWindow];
}

- (void)windowDidResignKey:(NSNotification *)notification
{
  struct frame *f = emacsFrame;

  mac_within_lisp_deferred_unless_popup (^{
      struct input_event inev;

      EVENT_INIT (inev);
      inev.arg = Qnil;
      mac_focus_changed (0, FRAME_DISPLAY_INFO (f), f, &inev);
      if (inev.kind != NO_EVENT)
	[emacsController storeEvent:&inev];
    });

  [self noteLeaveEmacsView];

  [emacsController setConflictingKeyBindingsDisabled:NO];
}

- (void)windowDidResignMain:(NSNotification *)notification
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
  /* OS X 10.10 seems to do this task for us.  */
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_9)
    {
      eassert ([emacsView isMemberOfClass:[EmacsMainView class]]);

      [(EmacsMainView *)emacsView unmarkText];
      [[NSInputManager currentInputManager] markedTextAbandoned:emacsView];
    }
#endif
}

- (void)windowDidMove:(NSNotification *)notification
{
  struct frame *f = emacsFrame;

  mac_handle_origin_change (f);
}

- (void)windowDidResize:(NSNotification *)notification
{
  struct frame *f = emacsFrame;

  /* `windowDidMove:' above is not called when both size and location
     are changed.  */
  mac_handle_origin_change (f);
  if (hourglassWindow)
    [self updateHourglassWindowOrigin];
}

- (void)windowDidMiniaturize:(NSNotification *)notification
{
  struct frame *f = emacsFrame;

  mac_handle_visibility_change (f);
}

- (void)windowDidDeminiaturize:(NSNotification *)notification
{
  struct frame *f = emacsFrame;

  mac_handle_visibility_change (f);
}

- (void)windowDidChangeScreen:(NSNotification *)notification
{
  /* We used to update the presentation options for the key window
     here.  But it makes application switching impossible in Split
     View on macOS 10.14 and later.  */
#if HAVE_MAC_METAL
  [self updateEmacsViewMTLObjects];
#endif
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification
{
  [self updateBackingScaleFactor];
}

- (BOOL)windowShouldClose:(id)sender
{
  struct frame *f = emacsFrame;
  struct input_event inev;

  EVENT_INIT (inev);
  inev.arg = Qnil;
  inev.kind = DELETE_WINDOW_EVENT;
  XSETFRAME (inev.frame_or_window, f);
  [emacsController storeEvent:&inev];

  return NO;
}

- (BOOL)window:(NSWindow *)sender shouldForwardAction:(SEL)action to:(id)target
{
  if (action == @selector(zoom:))
    if ((windowManagerState
	 & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT))
	&& [target respondsToSelector:action])
      return YES;

  return NO;
}

- (void)windowWillClose:(NSNotification *)notification
{
  [self hideHourglass:nil];
  [emacsWindow setDelegate:nil];
}

- (void)windowWillMove:(NSNotification *)notification
{
  struct frame *f = emacsFrame;

  f->output_data.mac->toolbar_win_gravity = 0;
}

- (NSSize)windowWillResize:(NSWindow *)sender
		    toSize:(NSSize)proposedFrameSize
{
  EmacsWindow *window = (EmacsWindow *) sender;
  NSEvent *currentEvent = [NSApp currentEvent];
  BOOL leftMouseDragged = ([currentEvent type] == NSEventTypeLeftMouseDragged);
  NSSize result;

  if (windowManagerState & WM_STATE_FULLSCREEN)
    {
      NSRect screenFrame = [[window screen] frame];

      result = screenFrame.size;
    }
  else
    {
      if (leftMouseDragged || [emacsController isMouseTrackingSuspended])
	result = [self hintedWindowFrameSize:proposedFrameSize
				allowsLarger:YES];
      else
	result = proposedFrameSize;
      if (windowManagerState
	  & (WM_STATE_MAXIMIZED_HORZ | WM_STATE_MAXIMIZED_VERT))
	{
	  NSRect screenVisibleFrame = [[window screen] visibleFrame];

	  if (windowManagerState & WM_STATE_MAXIMIZED_HORZ)
	    result.width = NSWidth (screenVisibleFrame);
	  if (windowManagerState & WM_STATE_MAXIMIZED_VERT)
	    result.height = NSHeight (screenVisibleFrame);
	}
    }

  if (leftMouseDragged
      /* Updating screen during resize by mouse dragging is
	 implemented by generating fake release and press events.
	 This seems to be too intrusive for "window snapping"
	 introduced in macOS 10.12, so we suppress it when pixelwise
	 frame resizing is in effect.  */
      && (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_11
	  || (FRAME_SIZE_HINTS (emacsFrame)->width_inc != 1
	      && FRAME_SIZE_HINTS (emacsFrame)->height_inc != 1))
      && (has_resize_indicator_at_bottom_right_p ()
	  || !([currentEvent modifierFlags]
	       & (NSEventModifierFlagShift | NSEventModifierFlagOption))))
    {
      NSRect frameRect = [window frame];
      NSPoint adjustment = NSMakePoint (result.width - NSWidth (frameRect),
					result.height - NSHeight (frameRect));

      [window suspendResizeTracking:currentEvent positionAdjustment:adjustment];
    }
  else if ([window inLiveResize]
	   && [currentEvent type] != NSEventTypeLeftMouseUp)
    [self setupLiveResizeTransition];

  return result;
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)sender
			defaultFrame:(NSRect)defaultFrame
{
  struct frame *f = emacsFrame;
  NSRect windowFrame, emacsViewBounds;
  NSSize emacsViewSizeInPixels, emacsViewSize;
  CGFloat dw, dh, dx, dy;
  int columns, rows;

  windowFrame = [sender frame];
  emacsViewBounds = [emacsView bounds];
  emacsViewSizeInPixels = [emacsView convertSize:emacsViewBounds.size
					  toView:nil];
  dw = NSWidth (windowFrame) - emacsViewSizeInPixels.width;
  dh = NSHeight (windowFrame) - emacsViewSizeInPixels.height;
  emacsViewSize =
    [emacsView convertSize:(NSMakeSize (NSWidth (defaultFrame) - dw,
					NSHeight (defaultFrame) - dh))
	       fromView:nil];

  columns = FRAME_PIXEL_WIDTH_TO_TEXT_COLS (f, emacsViewSize.width);
  rows = FRAME_PIXEL_HEIGHT_TO_TEXT_LINES (f, emacsViewSize.height);
  if (columns > DEFAULT_NUM_COLS)
    columns = DEFAULT_NUM_COLS;
  emacsViewSize.width = FRAME_TEXT_COLS_TO_PIXEL_WIDTH (f, columns);
  emacsViewSize.height = FRAME_TEXT_LINES_TO_PIXEL_HEIGHT (f, rows);
  emacsViewSizeInPixels = [emacsView convertSize:emacsViewSize toView:nil];
  windowFrame.size.width = emacsViewSizeInPixels.width + dw;
  windowFrame.size.height = emacsViewSizeInPixels.height + dh;

  dx = NSMaxX (defaultFrame) - NSMaxX (windowFrame);
  if (dx < 0)
    windowFrame.origin.x += dx;
  dx = NSMinX (defaultFrame) - NSMinX (windowFrame);
  if (dx > 0)
    windowFrame.origin.x += dx;
  dy = NSMaxY (defaultFrame) - NSMaxY (windowFrame);
  if (dy > 0)
    windowFrame.origin.y += dy;

  return windowFrame;
}

/* On macOS 10.12 and earlier, cacheDisplayInRect:toBitmapImageRep: is
   buggy for flipped views unless the given rect is of full height.
   Use only for full height rectangles on such versions.  */

- (NSBitmapImageRep *)bitmapImageRepInEmacsViewRect:(NSRect)rect
{
  struct frame *f = emacsFrame;
  NSBitmapImageRep *bitmap =
    [emacsView bitmapImageRepForCachingDisplayInRect:rect];
  bool saved_synthetic_bold_workaround_disabled_p =
    FRAME_SYNTHETIC_BOLD_WORKAROUND_DISABLED_P (f);
  bool saved_background_alpha_enabled_p = FRAME_BACKGROUND_ALPHA_ENABLED_P (f);

  eassert (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_12)
	   || (NSMinY (rect) == NSMinY ([emacsView bounds])
	       && NSHeight (rect) == NSHeight ([emacsView bounds])));

  FRAME_SYNTHETIC_BOLD_WORKAROUND_DISABLED_P (f) = true;
  FRAME_BACKGROUND_ALPHA_ENABLED_P (f) = false;
  if ([overlayView.superview isEqual:emacsView])
    [overlayView setHidden:YES];
  [EmacsView globallyDisableUpdateLayer:YES];
  [emacsView cacheDisplayInRect:rect toBitmapImageRep:bitmap];
  [EmacsView globallyDisableUpdateLayer:NO];
  if (overlayView.isHidden)
    [overlayView setHidden:NO];
  FRAME_BACKGROUND_ALPHA_ENABLED_P (f) = saved_background_alpha_enabled_p;
  FRAME_SYNTHETIC_BOLD_WORKAROUND_DISABLED_P (f) =
    saved_synthetic_bold_workaround_disabled_p;

  return bitmap;
}

- (NSBitmapImageRep *)bitmapImageRep
{
  return [self bitmapImageRepInEmacsViewRect:[emacsView bounds]];
}

- (void)storeModifyFrameParametersEvent:(Lisp_Object)alist
{
  struct frame *f = emacsFrame;
  struct input_event inev;
  Lisp_Object tag_Lisp = build_string ("Lisp");
  Lisp_Object arg;

  EVENT_INIT (inev);
  inev.kind = MAC_APPLE_EVENT;
  inev.x = Qframe;
  inev.y = intern ("modify-frame-parameters");
  XSETFRAME (inev.frame_or_window, f);
  arg = list2 (Fcons (Qframe, Fcons (tag_Lisp, inev.frame_or_window)),
	       Fcons (intern ("alist"), Fcons (tag_Lisp, alist)));
  inev.arg = Fcons (build_string ("aevt"), arg);
  [emacsController storeEvent:&inev];
}

- (CALayer *)liveResizeTransitionLayerWithDefaultBackground:(BOOL)flag
{
  struct frame *f = emacsFrame;
  struct window *root_window;
  CGFloat rootWindowMaxY;
  CALayer *rootLayer, *contentLayer;
  CGSize contentLayerSize;
  NSView *contentView = [emacsWindow contentView];
  NSRect contentViewRect = [contentView visibleRect];
  NSBitmapImageRep *bitmap = [self bitmapImageRep];
  id image = (id) [bitmap CGImage];
  CGFloat internalBorderWidth = FRAME_INTERNAL_BORDER_WIDTH (f);

  rootLayer = [CALayer layer];
  contentViewRect.origin = NSZeroPoint;
  rootLayer.bounds = NSRectToCGRect (contentViewRect);
  rootLayer.anchorPoint = CGPointZero;
  rootLayer.contentsScale = [emacsWindow backingScaleFactor];
  rootLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  rootLayer.geometryFlipped = YES;

  if (FRAME_INTERNAL_BORDER_WIDTH (f) == 0)
    contentLayer = rootLayer;
  else
    {
      GC gc = mac_gc_for_face_id (f, INTERNAL_BORDER_FACE_ID,
				  f->output_data.mac->normal_gc);
      CGColorRef borderColor = CGColorCreateCopyWithAlpha (gc->cg_back_color,
							   1.0f);

      rootLayer.borderColor = borderColor;
      CGColorRelease (borderColor);
      rootLayer.borderWidth = internalBorderWidth;

      contentLayer = [CALayer layer];
      contentLayer.frame = NSRectToCGRect (NSInsetRect (contentViewRect,
							internalBorderWidth,
							internalBorderWidth));
      contentLayer.autoresizingMask = (kCALayerWidthSizable
				       | kCALayerHeightSizable);
      contentLayer.masksToBounds = YES;
      [rootLayer addSublayer:contentLayer];
    }
  contentLayer.layoutManager = [CAConstraintLayoutManager layoutManager];
  if (flag)
    contentLayer.backgroundColor = f->output_data.mac->normal_gc->cg_back_color;
  contentLayerSize = contentLayer.bounds.size;

  root_window = XWINDOW (FRAME_ROOT_WINDOW (f));
  rootWindowMaxY = (WINDOW_TOP_EDGE_Y (root_window)
		    + WINDOW_PIXEL_HEIGHT (root_window));

  mac_foreach_window (f, ^(struct window *w) {
      enum {MIN_X_SCALE = 1 << 0, MAX_X_SCALE = 1 << 1,
	    MIN_Y_SCALE = 1 << 2, MAX_Y_SCALE = 1 << 3, MAX_Y_OFFSET = 1 << 4,
	    MIN_X_NEXT_MIN = 1 << 5};
      NSString *nextLayerName = nil;
      NSRect rects[4];
      int constraints[4];
      int i, nrects = 1;

      rects[0] = NSMakeRect (WINDOW_LEFT_EDGE_X (w), WINDOW_TOP_EDGE_Y (w),
			     WINDOW_PIXEL_WIDTH (w), WINDOW_PIXEL_HEIGHT (w));
      constraints[0] = MIN_X_SCALE | MIN_Y_SCALE;
      if (!w->pseudo_window_p)
	{
	  int x, y, width, height;
	  int bottom_idx = 0, right_idx = 0, constraint_y = MIN_Y_SCALE;
	  int bottom_fill_idx;
	  CGFloat right_width, bottom_height;

	  window_box (w, TEXT_AREA, &x, &y, &width, &height);
	  right_width = NSMaxX (rects[0]) - (x + width);
	  bottom_height = NSMaxY (rects[0]) - (y + height);
	  /* Make right_idx come earlier than bottom_idx for priority,
	     though we divide the right part later than the bottom
	     part.  */
	  if (right_width > 0)
	    right_idx = nrects++;
	  if (bottom_height > 0)
	    {
	      bottom_fill_idx = nrects++;
	      bottom_idx = nrects++;
	    }
	  else
	    {
	      if (NSMinY (rects[0]) >= rootWindowMaxY)
		/* Bottommost (minibuffer) window.  */
		{
		  constraints[0] = MIN_X_SCALE | MAX_Y_OFFSET;
		  constraint_y = MAX_Y_OFFSET;
		}
	    }

	  if (bottom_idx)
	    {
	      NSDivideRect (rects[0], &rects[bottom_idx], &rects[0],
			    bottom_height, NSMaxYEdge);
	      NSDivideRect (rects[bottom_idx], &rects[bottom_fill_idx],
			    &rects[bottom_idx], 1, NSMaxXEdge);
	      if (NSMaxY (rects[bottom_idx]) == rootWindowMaxY)
		/* Bottommost mode-line.  */
		constraints[bottom_idx] = MIN_X_SCALE | MAX_Y_OFFSET;
	      else
		constraints[bottom_idx] = MIN_X_SCALE | MAX_Y_SCALE;
	      constraints[bottom_fill_idx] =
		(constraints[bottom_idx] ^ (MIN_X_SCALE
					    | MAX_X_SCALE | MIN_X_NEXT_MIN));
	    }
	  if (right_idx)
	    {
	      NSDivideRect (rects[0], &rects[right_idx], &rects[0],
			    right_width, NSMaxXEdge);
	      constraints[right_idx] = MAX_X_SCALE | constraint_y;
	    }
	}
      for (i = 0; i < nrects; i++)
	{
	  CALayer *layer = [CALayer layer];
	  NSMutableDictionaryOf (NSString *, id <CAAction>) *actions;
	  CAConstraintAttribute attribute;
	  CGFloat scale;

	  if (nextLayerName)
	    {
	      layer.name = nextLayerName;
	      nextLayerName = nil;
	    }
	  layer.frame = NSRectToCGRect (rects[i]);
	  layer.contents = image;
	  layer.contentsRect =
	    CGRectMake (NSMinX (rects[i]) / NSWidth (contentViewRect),
			NSMinY (rects[i]) / NSHeight (contentViewRect),
			NSWidth (rects[i]) / NSWidth (contentViewRect),
			NSHeight (rects[i]) / NSHeight (contentViewRect));

	  /* Suppress animations triggered by a size change in the
	     superlayer.  Actually not needed on OS X 10.9.  */
	  actions = [NSMutableDictionary
		      dictionaryWithDictionary:layer.actions];
	  [actions setObject:[NSNull null] forKey:@"position"];
	  [actions setObject:[NSNull null] forKey:@"bounds"];
	  layer.actions = actions;

	  if (constraints[i] & (MIN_X_SCALE | MAX_X_SCALE))
	    {
	      if (constraints[i] & MIN_X_SCALE)
		{
		  attribute = kCAConstraintMinX;
		  scale = ((NSMinX (rects[i]) - internalBorderWidth)
			   / contentLayerSize.width);
		}
	      else
		{
		  attribute = kCAConstraintMaxX;
		  scale = ((NSMaxX (rects[i]) - internalBorderWidth)
			   / contentLayerSize.width);
		}
	      [layer addConstraint:[CAConstraint
				     constraintWithAttribute:attribute
						  relativeTo:@"superlayer"
						   attribute:kCAConstraintWidth
						       scale:scale
						      offset:0]];
	    }
	  if (constraints[i] & MIN_X_NEXT_MIN)
	    {
	      CIFilter *filter = [CIFilter filterWithName:@"CIGaussianBlur"];

	      [filter setDefaults];
	      layer.filters = [NSArray arrayWithObject:filter];
	      layer.masksToBounds = YES;
	      attribute = kCAConstraintMinX;
	      nextLayerName = [NSString stringWithFormat:@"layer-%p-%d",
					w, i + 1];
	      [layer addConstraint:[CAConstraint
				     constraintWithAttribute:attribute
						  relativeTo:nextLayerName
						   attribute:attribute]];

	    }
	  if (constraints[i] & (MIN_Y_SCALE | MAX_Y_SCALE | MAX_Y_OFFSET))
	    {
	      CAConstraintAttribute srcAttr;
	      CGFloat offset;

	      if (constraints[i] & MAX_Y_OFFSET)
		{
		  srcAttr = kCAConstraintMaxY;
		  offset = (NSMaxY (rects[i]) - internalBorderWidth
			    - contentLayerSize.height);
		  attribute = kCAConstraintMaxY;
		  scale = 1;
		}
	      else
		{
		  srcAttr = kCAConstraintHeight;
		  offset = 0;
		  if (constraints[i] & MIN_Y_SCALE)
		    {
		      attribute = kCAConstraintMinY;
		      scale = ((NSMinY (rects[i]) - internalBorderWidth)
			       / contentLayerSize.height);
		    }
		  else
		    {
		      attribute = kCAConstraintMaxY;
		      scale = ((NSMaxY (rects[i]) - internalBorderWidth)
			       / contentLayerSize.height);
		    }
		}
	      [layer addConstraint:[CAConstraint
				     constraintWithAttribute:attribute
						  relativeTo:@"superlayer"
						   attribute:srcAttr
						       scale:scale
						      offset:offset]];
	    }
	  [contentLayer addSublayer:layer];
	}

      return (bool) true;
    });

  return rootLayer;
}

- (void)setShouldLiveResizeTriggerTransition:(BOOL)flag
{
  shouldLiveResizeTriggerTransition = flag;
}

- (void)setLiveResizeCompletionHandler:(void (^)(void))block
{
  MRC_RELEASE (liveResizeCompletionHandler);
  liveResizeCompletionHandler = [block copy];
}

- (void)setupLiveResizeTransition
{
  if (liveResizeCompletionHandler == nil
      /* Resizing in Split View on macOS 10.15 no longer
	 scale-and-blurs non-main window.  */
      && (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_14)
	  || emacsWindow.isMainWindow))
    {
      EmacsFrameController * __unsafe_unretained weakSelf = self;
      CALayer *layer =
	[self liveResizeTransitionLayerWithDefaultBackground:YES];

      [CATransaction setDisableActions:YES];
      [[overlayView layer] addSublayer:layer];
      [CATransaction commit];
      [self setVibrantScrollersHidden:YES];
      [self setLiveResizeCompletionHandler:^{
	  [NSAnimationContext
	    runAnimationGroup:^(NSAnimationContext *context) {
	      [context setDuration:(10 / 60.0)];
	      layer.beginTime = [layer convertTime:(CACurrentMediaTime ())
					 fromLayer:nil] + 10 / 60.0;
	      layer.fillMode = kCAFillModeBackwards;
	      layer.opacity = 0;
	    } completionHandler:^{
	      [layer removeFromSuperlayer];
	      [weakSelf setVibrantScrollersHidden:NO];
	    }];
	}];
    }
}

- (void)windowWillStartLiveResize:(NSNotification *)notification
{
  if (shouldLiveResizeTriggerTransition)
    [self setupLiveResizeTransition];
}

- (void)windowDidEndLiveResize:(NSNotification *)notification
{
  if (liveResizeCompletionHandler)
    {
      liveResizeCompletionHandler ();
      [self setLiveResizeCompletionHandler:nil];
    }
}

- (NSSize)window:(NSWindow *)window willUseFullScreenContentSize:(NSSize)proposedSize
{
  return proposedSize;
}

- (NSApplicationPresentationOptions)window:(NSWindow *)window
      willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions
{
  return proposedOptions | NSApplicationPresentationAutoHideToolbar;
}

- (void)storeFullScreenFrameParameter
{
  Lisp_Object value;

  switch (fullscreenFrameParameterAfterTransition)
    {
    case FULLSCREEN_PARAM_NIL:
      value = Qnil;
      break;
    case FULLSCREEN_PARAM_FULLBOTH:
      value = Qfullboth;
      break;
    case FULLSCREEN_PARAM_FULLSCREEN:
      value = Qfullscreen;
      break;
    default:
      return;
    }

  [self storeModifyFrameParametersEvent:(list1 (Fcons (Qfullscreen, value)))];
  fullscreenFrameParameterAfterTransition = FULLSCREEN_PARAM_NONE;
}

- (void)storeParentFrameFrameParameter
{
  struct frame *f = emacsFrame;

  if (!NILP (f->parent_frame))
    {
      [self storeModifyFrameParametersEvent:(list1 (Fcons (Qparent_frame,
							   f->parent_frame)))];
      store_frame_param (f, Qparent_frame, Qnil);
      fset_parent_frame (f, Qnil);
    }
}

- (void)addFullScreenTransitionCompletionHandler:(void (^)(EmacsWindow *,
							   BOOL))block
{
  if (fullScreenTransitionCompletionHandlers == nil)
    fullScreenTransitionCompletionHandlers =
      [[NSMutableArray alloc] initWithCapacity:0];
  [fullScreenTransitionCompletionHandlers
    addObject:(MRC_AUTORELEASE ([block copy]))];
}

- (void)handleFullScreenTransitionCompletionForWindow:(EmacsWindow *)window
					      success:(BOOL)flag
{
  for (void (^handler) (EmacsWindow *, BOOL)
	 in fullScreenTransitionCompletionHandlers)
    handler (window, flag);
  MRC_RELEASE (fullScreenTransitionCompletionHandlers);
  fullScreenTransitionCompletionHandlers = nil;
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification
{
  EmacsFrameController * __unsafe_unretained weakSelf = self;
  BOOL savedToolbarVisibility;

  if (!(fullScreenTargetState & WM_STATE_DEDICATED_DESKTOP))
    {
      /* Entering full screen is triggered by external events rather
	 than explicit frame parameter changes from Lisp.  */
      fullscreenFrameParameterAfterTransition = FULLSCREEN_PARAM_FULLSCREEN;
      fullScreenTargetState = WM_STATE_FULLSCREEN | WM_STATE_DEDICATED_DESKTOP;
    }
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (success)
	[weakSelf storeFullScreenFrameParameter];
    }];
  /* This part is executed in -[EmacsFrameController
     window:startCustomAnimationToEnterFullScreenWithDuration:] on OS
     X 10.10 and earlier.  Unfortunately this is a bit kludgy.  */
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max))
    [self preprocessWindowManagerStateChange:fullScreenTargetState];

  /* This is a workaround for the problem of not preserving toolbar
     visibility value.  */
  savedToolbarVisibility = [[emacsWindow toolbar] isVisible];
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (success)
	[[NSOperationQueue mainQueue] addOperationWithBlock:^{
	    [[window toolbar] setVisible:savedToolbarVisibility];
	  }];
    }];

  /* Child windows seem to be temporarily removed during full screen
     transition.  */
  for (NSWindow *childWindow in self.emacsWindow.childWindows)
    if ([childWindow isKindOfClass:[EmacsWindow class]])
      [(EmacsWindow *)childWindow suspendConstrainingToScreen:YES];
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      for (NSWindow *childWindow in window.childWindows)
	if ([childWindow isKindOfClass:[EmacsWindow class]])
	  [(EmacsWindow *)childWindow suspendConstrainingToScreen:NO];
    }];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
  [self handleFullScreenTransitionCompletionForWindow:emacsWindow success:YES];
  /* For resize in a split-view space on OS X 10.11.  */
  [self setShouldLiveResizeTriggerTransition:YES];
  /* This is necessary for executables compiled on OS X 10.10 or
     earlier and run on OS X 10.11.  Without this, Emacs placed on the
     left side of a split-view space tries to occupy maximum area.  */
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max))
    [emacsWindow suspendConstrainingToScreen:YES];
}

- (void)windowDidFailToEnterFullScreen:(NSWindow *)window
{
  [self handleFullScreenTransitionCompletionForWindow:emacsWindow success:NO];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification
{
  EmacsFrameController * __unsafe_unretained weakSelf = self;
  BOOL savedToolbarVisibility;

  if (fullScreenTargetState & WM_STATE_DEDICATED_DESKTOP)
    {
      /* Exiting full screen is triggered by external events rather
	 than explicit frame parameter changes from Lisp.  */
      fullscreenFrameParameterAfterTransition = FULLSCREEN_PARAM_NIL;
      fullScreenTargetState = 0;
    }
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (success)
	[weakSelf storeFullScreenFrameParameter];
    }];
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max))
    [self preprocessWindowManagerStateChange:fullScreenTargetState];

  /* This is a workaround for the problem of not preserving toolbar
     visibility value.  */
  savedToolbarVisibility = [[emacsWindow toolbar] isVisible];
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (success)
	[[NSOperationQueue mainQueue] addOperationWithBlock:^{
	    [[window toolbar] setVisible:savedToolbarVisibility];
	  }];
    }];

  [self setShouldLiveResizeTriggerTransition:NO];
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (!success)
	[weakSelf setShouldLiveResizeTriggerTransition:YES];
    }];

  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max))
    {
      [emacsWindow suspendConstrainingToScreen:NO];
      [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						       BOOL success) {
	  if (!success)
	    [window suspendConstrainingToScreen:YES];
	}];
    }

  for (NSWindow *childWindow in self.emacsWindow.childWindows)
    if ([childWindow isKindOfClass:[EmacsWindow class]])
      [(EmacsWindow *)childWindow suspendConstrainingToScreen:YES];
  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      for (NSWindow *childWindow in window.childWindows)
	if ([childWindow isKindOfClass:[EmacsWindow class]])
	  [(EmacsWindow *)childWindow suspendConstrainingToScreen:NO];
    }];

  [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						   BOOL success) {
      if (success)
	[weakSelf storeParentFrameFrameParameter];
    }];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
  [self handleFullScreenTransitionCompletionForWindow:emacsWindow success:YES];
  [emacsController updatePresentationOptions];
}

- (void)windowDidFailToExitFullScreen:(NSWindow *)window
{
  [self handleFullScreenTransitionCompletionForWindow:emacsWindow success:NO];
}

- (NSArrayOf (NSWindow *) *)customWindowsToEnterFullScreenForWindow:(NSWindow *)window
{
  /* Custom transition animation is disabled on OS X 10.11 because (1)
     it doesn't look as intended and (2) C-x 5 2 on a full screen
     frame causes crash due to assertion failure in
     -[NSToolbarFullScreenWindowManager getToolbarLayout]:
     getToolbarLayout called with a nil content view.  */
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_10_Max)
    return [NSArray arrayWithObject:window];
  else
    {
      EmacsFrameController * __unsafe_unretained weakSelf = self;
      CALayer *layer =
	[self liveResizeTransitionLayerWithDefaultBackground:YES];

      [CATransaction setDisableActions:YES];
      [[overlayView layer] addSublayer:layer];
      [CATransaction commit];
      [self setVibrantScrollersHidden:YES];
      [self addFullScreenTransitionCompletionHandler:^(EmacsWindow *window,
						       BOOL success) {
	  if (!success)
	    [layer removeFromSuperlayer];
	  else
	    [NSAnimationContext
	      runAnimationGroup:^(NSAnimationContext *context) {
		[context setDuration:(10 / 60.0)];
		layer.opacity = 0;
	      } completionHandler:^{
		[layer removeFromSuperlayer];
		[weakSelf setVibrantScrollersHidden:NO];
	      }];
	}];

      return nil;
    }
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
- (void)window:(NSWindow *)window
  startCustomAnimationToEnterFullScreenWithDuration:(NSTimeInterval)duration
{
  CGFloat previousAlphaValue = [window alphaValue];
  NSAutoresizingMaskOptions previousAutoresizingMask = [emacsView
							 autoresizingMask];
  NSRect srcRect = [window frame], destRect;
  NSView *contentView = [window contentView];
  CALayer *layer;
  CGFloat titleBarHeight;

  layer = [self liveResizeTransitionLayerWithDefaultBackground:NO];

  titleBarHeight = NSHeight (srcRect) - NSMaxY ([contentView frame]);

  destRect = [self preprocessWindowManagerStateChange:fullScreenTargetState];

  NSDisableScreenUpdates ();

  [window setStyleMask:([window styleMask] | NSWindowStyleMaskFullScreen)];

  destRect = [self postprocessWindowManagerStateChange:destRect];
  /* The line below used to be [window setFrame:destRect display:NO],
     but this does not set content view's frame correctly on OS X
     10.10.  */
  [contentView setFrameSize:destRect.size];

  [emacsView setAutoresizingMask:(NSViewMaxXMargin | NSViewMinYMargin)];
  [(EmacsWindow *)window suspendConstrainingToScreen:YES];
  /* We no longer set NSWindowStyleMaskFullScreen until the transition
     animation completes because OS X 10.10 places such a window at
     the center of screen and also makes calls to
     -window:willUseFullScreenContentSize: or
     -windowWillUseStandardFrame:defaultFrame:.  For the same reason,
     we shorten the given animation duration below a bit so as to
     avoid adding NSWindowStyleMaskFullScreen before the completion of
     the transition animation.  */
  [window setStyleMask:([window styleMask] & ~NSWindowStyleMaskFullScreen)];
  [window setFrame:srcRect display:NO];

  [CATransaction setDisableActions:YES];
  [[overlayView layer] addSublayer:layer];
  [CATransaction commit];
  [self setVibrantScrollersHidden:YES];
  [window display];

  [window setAlphaValue:1];

  NSEnableScreenUpdates ();

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
      NSRect destRectWithTitleBar =
	NSMakeRect (NSMinX (destRect), NSMinY (destRect),
		    NSWidth (destRect), NSHeight (destRect) + titleBarHeight);

      [context setDuration:(duration * .9)];
      [context
	setTimingFunction:[CAMediaTimingFunction
			    functionWithName:kCAMediaTimingFunctionDefault]];
      [[window animator] setFrame:destRectWithTitleBar display:YES];
      layer.beginTime = [layer convertTime:(CACurrentMediaTime ())
				 fromLayer:nil] + duration * .9 * (1 - 1.0 / 5);
      layer.speed = 5;
      layer.fillMode = kCAFillModeBackwards;
      layer.opacity = 0;
    } completionHandler:^{
      [layer removeFromSuperlayer];
      [self setVibrantScrollersHidden:NO];
      [window setAlphaValue:previousAlphaValue];
      [(EmacsWindow *)window suspendConstrainingToScreen:NO];
      [window setStyleMask:([window styleMask] | NSWindowStyleMaskFullScreen)];
      [window setFrame:destRect display:NO];
      [emacsView setAutoresizingMask:previousAutoresizingMask];
      /* Mac OS X 10.7 needs this.  */
      [emacsView setFrame:[[emacsView superview] bounds]];
      /* OS X 10.9 - 10.10 need this.  */
      [(EmacsMainView *)emacsView synchronizeChildFrameOrigins];
    }];
}
#endif

- (NSArrayOf (NSWindow *) *)customWindowsToExitFullScreenForWindow:(NSWindow *)window
{
  return [self customWindowsToEnterFullScreenForWindow:window];
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
- (void)window:(NSWindow *)window
  startCustomAnimationToExitFullScreenWithDuration:(NSTimeInterval)duration
{
  CGFloat previousAlphaValue = [window alphaValue];
  NSWindowLevel previousWindowLevel = [window level];
  NSAutoresizingMaskOptions previousAutoresizingMask = [emacsView
							 autoresizingMask];
  NSRect srcRect = [window frame], destRect;
  NSView *contentView = [window contentView];
  CALayer *layer;
  CGFloat titleBarHeight;

  layer = [self liveResizeTransitionLayerWithDefaultBackground:NO];

  destRect = [self preprocessWindowManagerStateChange:fullScreenTargetState];

  NSDisableScreenUpdates ();

  [window setStyleMask:([window styleMask] & ~NSWindowStyleMaskFullScreen)];

  destRect = [self postprocessWindowManagerStateChange:destRect];
  [window setFrame:destRect display:NO];

  titleBarHeight = NSHeight (destRect) - NSMaxY ([contentView frame]);

  [emacsView setAutoresizingMask:(NSViewMaxXMargin | NSViewMinYMargin)];
  srcRect.size.height += titleBarHeight;
  [(EmacsWindow *)window suspendConstrainingToScreen:YES];
  [window setFrame:srcRect display:NO];

  [CATransaction setDisableActions:YES];
  [[overlayView layer] addSublayer:layer];
  [CATransaction commit];
  [self setVibrantScrollersHidden:YES];
  [window display];

  [window setAlphaValue:1];
  [window setLevel:(NSMainMenuWindowLevel + 1)];

  NSEnableScreenUpdates ();

  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
      [context setDuration:duration];
      [context
	setTimingFunction:[CAMediaTimingFunction
			    functionWithName:kCAMediaTimingFunctionDefault]];
      [[window animator] setFrame:destRect display:YES];
      layer.beginTime = [layer convertTime:(CACurrentMediaTime ())
				 fromLayer:nil] + duration * (1 - 1.0 / 5);
      layer.speed = 5;
      layer.fillMode = kCAFillModeBackwards;
      layer.opacity = 0;
    } completionHandler:^{
      [layer removeFromSuperlayer];
      [self setVibrantScrollersHidden:NO];
      [window setAlphaValue:previousAlphaValue];
      [window setLevel:previousWindowLevel];
      [(EmacsWindow *)window suspendConstrainingToScreen:NO];
      [emacsView setAutoresizingMask:previousAutoresizingMask];
      /* Mac OS X 10.7 needs this.  */
      [emacsView setFrame:[[emacsView superview] bounds]];
      /* OS X 10.9 - 10.10 need this.  */
      [(EmacsMainView *)emacsView synchronizeChildFrameOrigins];
    }];
}
#endif

- (BOOL)isWindowFrontmost
{
  NSArrayOf (NSWindow *) *orderedWindows = [NSApp orderedWindows];

  if ([orderedWindows count] > 0)
    {
      NSWindow *frontWindow = [orderedWindows objectAtIndex:0];

      return ([frontWindow isEqual:hourglassWindow]
	      || [frontWindow isEqual:emacsWindow]);
    }

  return NO;
}

- (BOOL)shouldBeTitled
{
  struct frame *f = emacsFrame;

  if (FRAME_PARENT_FRAME (f))
    return NO;
  else if (windowManagerState & WM_STATE_FULLSCREEN)
    return (has_full_screen_with_dedicated_desktop_p ()
	    && (windowManagerState & WM_STATE_DEDICATED_DESKTOP));
  else
    return !FRAME_UNDECORATED (f);
}

- (BOOL)shouldHaveShadow
{
  struct frame *f = emacsFrame;

  if (FRAME_PARENT_FRAME (f))
    return NO;
  else if (windowManagerState & WM_STATE_FULLSCREEN)
    return (has_full_screen_with_dedicated_desktop_p ()
	    && (windowManagerState & WM_STATE_DEDICATED_DESKTOP));
  else
    return YES;
}

- (void)updateWindowStyle
{
  BOOL shouldBeTitled = self.shouldBeTitled;

  if (emacsWindow.hasTitleBar != shouldBeTitled)
    {
      struct frame *f = emacsFrame;
      Lisp_Object tool_bar_lines = get_frame_param (f, Qtool_bar_lines);

      if (INTEGERP (tool_bar_lines) && XINT (tool_bar_lines) > 0)
	mac_within_lisp (^{
	    x_set_frame_parameters (f, list1 (Fcons (Qtool_bar_lines,
						     make_number (0))));
	  });
      FRAME_NATIVE_TOOL_BAR_P (f) = !shouldBeTitled;
      if (INTEGERP (tool_bar_lines) && XINT (tool_bar_lines) > 0)
	mac_within_lisp (^{
	    x_set_frame_parameters (f, list1 (Fcons (Qtool_bar_lines,
						     tool_bar_lines)));
	  });
      [self setupWindow];
    }

  emacsWindow.hasShadow = self.shouldHaveShadow;
}

- (void)windowWillEnterTabOverview
{
  [emacsWindow enumerateChildWindowsUsingBlock:^(NSWindow *child, BOOL *stop) {
      if (savedChildWindowAlphaMap == nil)
	savedChildWindowAlphaMap =
	  [[NSMapTable alloc]
	    initWithKeyOptions:NSMapTableObjectPointerPersonality
		  valueOptions:NSMapTableStrongMemory capacity:0];
      [savedChildWindowAlphaMap
	setObject:[NSNumber numberWithDouble:child.alphaValue] forKey:child];
      child.alphaValue = 0;
    }];
}

- (void)windowDidExitTabOverview
{
  [emacsWindow enumerateChildWindowsUsingBlock:^(NSWindow *child, BOOL *stop) {
      NSNumber *number = [savedChildWindowAlphaMap objectForKey:child];

      child.alphaValue = (number ? number.doubleValue : 1.0);
    }];
  MRC_RELEASE (savedChildWindowAlphaMap);
  savedChildWindowAlphaMap = nil;
}

@end				// EmacsFrameController

/* Window Manager function replacements.  */

void
mac_set_frame_window_title (struct frame *f, CFStringRef string)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{[window setTitle:((__bridge NSString *) string)];});
}

void
mac_set_frame_window_modified (struct frame *f, bool modified)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{[window setDocumentEdited:modified];});
}

void
mac_set_frame_window_proxy (struct frame *f, CFURLRef url)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{[window setRepresentedURL:((__bridge NSURL *) url)];});
}

bool
mac_is_frame_window_visible (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  return [window isVisible] || [window isMiniaturized];
}

bool
mac_is_frame_window_collapsed (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  return [window isMiniaturized];
}

bool
mac_is_frame_window_drawable (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  return ![frameController emacsViewIsHiddenOrHasHiddenAncestor];
}

static void
mac_bring_frame_window_to_front_and_activate (struct frame *f, bool activate_p)
{
  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  if ([NSApp isHidden])
    window.needsOrderFrontOnUnhide = YES;
  else
    mac_within_gui (^{
	struct frame *p = FRAME_PARENT_FRAME (f);

	if (p)
	  {
	    if (!window.isVisible)
	      {
		NSWindow *parentWindow = FRAME_MAC_WINDOW_OBJECT (p);

		[parentWindow addChildWindow:window ordered:NSWindowAbove];
		mac_move_frame_window_structure_1 (f, f->left_pos, f->top_pos);
	      }
	    if (activate_p)
	      [window makeKeyWindow];
	  }
	else
	  {
	    NSWindowTabbingMode tabbingMode = NSWindowTabbingModeAutomatic;
	    NSWindow *mainWindow = [NSApp mainWindow];
	    if ([mainWindow respondsToSelector:@selector(tabGroup)]
		&& mainWindow.tabGroup
		&& ![mainWindow.tabGroup.windows containsObject:mainWindow])
	      mainWindow = mainWindow.tabGroup.selectedWindow;

	    if (!FRAME_TOOLTIP_P (f)
		&& [window respondsToSelector:@selector(setTabbingMode:)]
		&& !window.isVisible)
	      {
		if (!mainWindow.hasTitleBar || NILP (Vmac_frame_tabbing))
		  tabbingMode = NSWindowTabbingModeDisallowed;
		else if (EQ (Vmac_frame_tabbing, Qt))
		  tabbingMode = NSWindowTabbingModePreferred;
		else if (EQ (Vmac_frame_tabbing, Qinverted))
		  switch ([NSWindow userTabbingPreference])
		    {
		    case NSWindowUserTabbingPreferenceManual:
		      tabbingMode = NSWindowTabbingModePreferred;
		      break;
		    case NSWindowUserTabbingPreferenceAlways:
		      tabbingMode = NSWindowTabbingModeDisallowed;
		      break;
		    case NSWindowUserTabbingPreferenceInFullScreen:
		      if (mainWindow.styleMask & NSWindowStyleMaskFullScreen)
			tabbingMode = NSWindowTabbingModeDisallowed;
		      else
			tabbingMode = NSWindowTabbingModePreferred;
		      break;
		    }

		window.tabbingMode = tabbingMode;
		if ([mainWindow isKindOfClass:[EmacsWindow class]])
		  {
		    mainWindow.tabbingMode = tabbingMode;
		    /* If the Tab Overview UI is visible and the window
		       is to join its tab group, then make the Overview
		       UI invisible and wait until it finishes.  */
		    if (tabbingMode == NSWindowTabbingModePreferred)
		      [(EmacsWindow *)mainWindow exitTabGroupOverview];
		  }
	      }

	    if (activate_p)
	      [window makeKeyAndOrderFront:nil];
	    else
	      [window orderFront:nil];

	    if (tabbingMode != NSWindowTabbingModeAutomatic)
	      {
		window.tabbingMode = NSWindowTabbingModeAutomatic;
		if ([mainWindow isKindOfClass:[EmacsWindow class]])
		  mainWindow.tabbingMode = NSWindowTabbingModeAutomatic;
	      }
	  }
      });
}

void
mac_bring_frame_window_to_front (struct frame *f)
{
  mac_bring_frame_window_to_front_and_activate (f, false);
}

void
mac_send_frame_window_behind (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{[window orderWindow:NSWindowBelow relativeTo:0];});
}

void
mac_hide_frame_window (struct frame *f)
{
  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{
      if ([window isMiniaturized])
	[window deminiaturize:nil];

      /* Mac OS X 10.6 needs this.  */
      [window.parentWindow removeChildWindow:window];
      [window orderOut:nil];
      [window setNeedsOrderFrontOnUnhide:NO];
    });
}

void
mac_show_frame_window (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  if (![window isVisible])
    mac_bring_frame_window_to_front_and_activate (f,
						  !FRAME_NO_FOCUS_ON_MAP (f));
}

OSStatus
mac_collapse_frame_window (struct frame *f, bool collapse)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{
      if (collapse && ![window isMiniaturized])
	[window miniaturize:nil];
      else if (!collapse && [window isMiniaturized])
	[window deminiaturize:nil];
    });

  return noErr;
}

bool
mac_is_frame_window_frontmost (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  return [frameController isWindowFrontmost];
}

void
mac_activate_frame_window (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{[window makeKeyWindow];});
}

static NSRect
mac_get_base_screen_frame (void)
{
  NSArrayOf (NSScreen *) *screens = [NSScreen screens];

  if ([screens count] > 0)
    return [[screens objectAtIndex:0] frame];
  else
    return [[NSScreen mainScreen] frame];
}

static void
mac_move_frame_window_structure_1 (struct frame *f, int x, int y)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  struct frame *p = FRAME_PARENT_FRAME (f);
  NSPoint topLeft;

  if (p == NULL)
    {
      NSRect baseScreenFrame = mac_get_base_screen_frame ();

      topLeft = NSMakePoint (x + NSMinX (baseScreenFrame),
			     -y + NSMaxY (baseScreenFrame));
    }
  else
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (p);

      topLeft = [frameController
		  convertEmacsViewPointToScreen:(NSMakePoint (x, y))];
    }

  [window setFrameTopLeftPoint:topLeft];
}

OSStatus
mac_move_frame_window_structure (struct frame *f, int x, int y)
{
  mac_within_gui (^{mac_move_frame_window_structure_1 (f, x, y);});

  return noErr;
}

void
mac_size_frame_window (struct frame *f, int w, int h, bool update)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{
      NSView *contentView;
      NSRect contentViewBounds, windowFrame;
      NSSize oldSizeInPixels, newSizeInPixels;
      CGFloat dw, dh;

      /* W and H are dimensions in user space coordinates; they are
	 not the same as those in device space coordinates if scaling
	 is in effect.  */
      contentView = [window contentView];
      contentViewBounds = [contentView bounds];
      oldSizeInPixels = [contentView convertSize:contentViewBounds.size
					  toView:nil];
      newSizeInPixels = [contentView convertSize:(NSMakeSize (w, h))
					  toView:nil];
      dw = newSizeInPixels.width - oldSizeInPixels.width;
      dh = newSizeInPixels.height - oldSizeInPixels.height;

      windowFrame = [window frame];
      windowFrame.origin.y -= dh;
      windowFrame.size.width += dw;
      windowFrame.size.height += dh;

      [window setFrame:windowFrame display:update];
    });

  if (window.isVisible)
    extendReadSocketIntervalOnce = YES;
}

OSStatus
mac_set_frame_window_alpha (struct frame *f, CGFloat alpha)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{[window setAlphaValue:alpha];});

  return noErr;
}

OSStatus
mac_get_frame_window_alpha (struct frame *f, CGFloat *out_alpha)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  *out_alpha = [window alphaValue];

  return noErr;
}

Lisp_Object
mac_set_tab_group_overview_visible_p (struct frame *f, Lisp_Object value)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  if (![window respondsToSelector:@selector(tabGroup)])
    {
      if (NILP (value))
	return Qnil;
      else
	return build_string ("Tab group overview is not supported on this macOS version");
    }

  Lisp_Object __block result = Qnil;
  mac_within_app (^{
      if (window.tabGroup.isOverviewVisible != !NILP (value))
	{
	  /* Just setting the property window.tabGroup.overviewVisible
	     does not show the search field on macOS 10.13 Beta.  */
	  [NSApp sendAction:@selector(toggleTabOverview:) to:window from:nil];
	  result = Qt;
	}
    });

  return result;
}

Lisp_Object
mac_set_tab_group_tab_bar_visible_p (struct frame *f, Lisp_Object value)
{
  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  Lisp_Object __block result = Qnil;

  mac_within_app (^{
      NSInteger count = window.tabbedWindows.count;

      if ((count != 0) == !NILP (value))
	result = Qnil;
      else if (count > 1)
	result = build_string ("Tab bar cannot be made invisible because of multiple tabs");
      else
	{
	  [window exitTabGroupOverview];
	  [NSApp sendAction:@selector(toggleTabBar:) to:window from:nil];
	  [[NSUserDefaults standardUserDefaults]
	    removeObjectForKey:[@"NSWindowTabbingShoudShowTabBarKey-"
				   stringByAppendingString:window.tabbingIdentifier]];
	  result = Qt;
	}
    });

  return result;
}

Lisp_Object
mac_set_tab_group_selected_frame (struct frame *f, Lisp_Object value)
{
  Lisp_Object selected = mac_get_tab_group_selected_frame (f);
  Lisp_Object frames;
  EmacsWindow *newSelectedWindow;

  if (EQ (selected, value))
    return Qnil;

  frames = mac_get_tab_group_frames (f);
  if (NILP (Fmemq (value, frames)))
    {
      Lisp_Object frame;
      AUTO_STRING (fmt, "Frame %S is not in the tab group for frame %S");

      XSETFRAME (frame, f);

      return CALLN (Fformat, fmt, value, frame);
    }

  newSelectedWindow = FRAME_MAC_WINDOW_OBJECT (XFRAME (value));
  if ([newSelectedWindow respondsToSelector:@selector(tabGroup)])
    mac_within_app (^{
	[newSelectedWindow exitTabGroupOverview];
	newSelectedWindow.tabGroup.selectedWindow = newSelectedWindow;
      });
  else
    mac_within_app (^{
	NSWindow *selectedWindow = FRAME_MAC_WINDOW_OBJECT (XFRAME (selected));
	NSInteger __block aboveWindowNumber = 0;

	[newSelectedWindow exitTabGroupOverview];
	[NSApp enumerateWindowsWithOptions:NSWindowListOrderedFrontToBack
				usingBlock:^(NSWindow *window, BOOL *stop) {
	    if ([window isEqual:selectedWindow])
	      *stop = YES;
	    else if ([window isKindOfClass:EmacsWindow.class])
	      aboveWindowNumber = window.windowNumber;
	  }];
	if (aboveWindowNumber)
	  {
	    [newSelectedWindow orderFront:nil];
	    [newSelectedWindow orderWindow:NSWindowBelow
				relativeTo:aboveWindowNumber];
	  }
	else
	  [newSelectedWindow makeKeyAndOrderFront:nil];
      });

  return Qt;
}

Lisp_Object
mac_set_tab_group_frames (struct frame *f, Lisp_Object value)
{
  Lisp_Object frames = mac_get_tab_group_frames (f), rest, selected;
  NSWindowTabbingIdentifier identifier;

  if (!NILP (Fequal (frames, value)))
    return Qnil;

  if (NILP (frames))
    return build_string ("Frames must be non-nil");

  for (rest = value; CONSP (rest); rest = XCDR (rest))
    {
      Lisp_Object frame = XCAR (rest);

      if (!FRAME_MAC_P (XFRAME (frame)) || !FRAME_LIVE_P (XFRAME (frame)))
	{
	  AUTO_STRING (fmt, "Not a live Mac frame: %S");

	  return CALLN (Fformat, fmt, frame);
	}
    }
  if (!NILP (rest))
    {
      AUTO_STRING (fmt, "Frames do not end with nil: %S");

      return CALLN (Fformat, fmt, rest);
    }

  identifier = FRAME_MAC_WINDOW_OBJECT (f).tabbingIdentifier;
  for (rest = value; !NILP (rest); rest = XCDR (rest))
    if (!NILP (Fmemq (XCAR (rest), XCDR (rest))))
      {
	AUTO_STRING (fmt, "Duplicate frames: %S");

	return CALLN (Fformat, fmt, XCAR (rest));
      }
    else
      {
	NSWindow *window = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (rest)));

	if (!window.hasTitleBar)
	  {
	    AUTO_STRING (fmt, "Not a frame with the title bar: %S");

	    return CALLN (Fformat, fmt, XCAR (rest));
	  }
	if (!window.isVisible)
	  {
	    AUTO_STRING (fmt, "Can't rearrange tabs for invisible/iconified frame: %S");

	    return CALLN (Fformat, fmt, XCAR (rest));
	  }
	if (![identifier isEqualToString:window.tabbingIdentifier])
	  {
	    AUTO_STRING (fmt, "Not a frame with the same identifier: %S");

	    return CALLN (Fformat, fmt, XCAR (rest));
	  }
      }

  selected = mac_get_tab_group_selected_frame (f);
  mac_within_app (^{
      Lisp_Object cur_rest, toinclude, last = Qnil, toexclude = Qnil;
      EmacsWindow *window, *addedWindow;

      window = FRAME_MAC_WINDOW_OBJECT (f);
      [window exitTabGroupOverview];
      for (Lisp_Object rest = value; !NILP (rest); rest = XCDR (rest))
	{
	  window = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (rest)));
	  [window exitTabGroupOverview];
	}

      toinclude = value;
      for (cur_rest = frames; !NILP (cur_rest); cur_rest = XCDR (cur_rest))
	{
	  Lisp_Object frame = XCAR (cur_rest), rest;

	  for (rest = value; !NILP (rest); rest = XCDR (rest))
	    {
	      if (EQ (rest, toinclude))
		last = frame;
	      if (EQ (XCAR (rest), frame))
		break;
	    }

	  if (NILP (rest))
	    {
	      /* `frame' was not found in `value'; to be excluded.  */
	      toexclude = Fcons (frame, toexclude);
	      continue;
	    }
	  else if (!EQ (last, frame))
	    /* `frame' was found between `value' (inclusive) to
	       `toinclude' (not inclusive); already included.  */
	    continue;

	  window = FRAME_MAC_WINDOW_OBJECT (XFRAME (frame));
	  while (!EQ (XCAR (toinclude), frame))
	    {
	      addedWindow = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (toinclude)));
	      [window addTabbedWindow:addedWindow ordered:NSWindowBelow];
	      toinclude = XCDR (toinclude);
	    }
	  toinclude = XCDR (toinclude);
	}
      if (!NILP (toinclude))
	{
	  window = FRAME_MAC_WINDOW_OBJECT (XFRAME (last));
	  do
	    {
	      addedWindow = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (toinclude)));
	      [window addTabbedWindow:addedWindow ordered:NSWindowAbove];
	      window = addedWindow;
	      last = XCAR (toinclude);

	      toinclude = XCDR (toinclude);
	    }
	  while (!NILP (toinclude));
	}

      if (!NILP (toexclude))
	{
	  Lisp_Object last_cell = toexclude;

	  /* `toexclude' is in reverse order.  First we create a new
	     frame for the last element.  */
	  while (!NILP (XCDR (last_cell)))
	    last_cell = XCDR (last_cell);
	  window = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (last_cell)));
	  [NSApp sendAction:@selector(moveTabToNewWindow:) to:window from:nil];
	  for (; !EQ (toexclude, last_cell); toexclude = XCDR (toexclude))
	    {
	      addedWindow = FRAME_MAC_WINDOW_OBJECT (XFRAME (XCAR (toexclude)));
	      [window addTabbedWindow:addedWindow ordered:NSWindowAbove];
	    }
	}
    });
  mac_set_tab_group_selected_frame (XFRAME (selected), selected);

  return Qt;
}

Lisp_Object
mac_get_tab_group_overview_visible_p (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  Lisp_Object __block result = Qnil;

  if ([window respondsToSelector:@selector(tabGroup)])
    mac_within_gui (^{if (window.tabGroup.isOverviewVisible) result = Qt;});

  return result;
}

Lisp_Object
mac_get_tab_group_tab_bar_visible_p (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  Lisp_Object __block result = Qnil;

  if ([window respondsToSelector:@selector(tabGroup)])
    mac_within_gui (^{if (window.tabGroup.isTabBarVisible) result = Qt;});
  else if ([window respondsToSelector:@selector(tabbedWindows)])
    mac_within_gui (^{if (window.tabbedWindows != nil) result = Qt;});

  return result;
}

Lisp_Object
mac_get_tab_group_selected_frame (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  Lisp_Object __block result = Qnil;

  if ([window respondsToSelector:@selector(tabGroup)])
    mac_within_gui (^{result = window.tabGroup.selectedWindow.lispFrame;});
  else if (!window.hasTitleBar)
    ;
#if 1
  else if ([window respondsToSelector:@selector(_windowStackController)])
    mac_within_gui (^{
	NSWindowStackController *stackController =
	  window._windowStackController;

	if (stackController == nil)
	  XSETFRAME (result, f);
	else
	  result = stackController.selectedWindow.lispFrame;
      });
#else  /* This only works for visible frames.  */
  else if ([window respondsToSelector:@selector(tabbedWindows)])
    mac_within_gui (^{
	NSArrayOf (NSWindow *) *tabbedWindows = window.tabbedWindows;

	if (tabbedWindows == nil)
	  XSETFRAME (result, f);
	else
	  {
	    NSWindow * __block selectedWindow = nil;

	    [NSApp enumerateWindowsWithOptions:NSWindowListOrderedFrontToBack
				    usingBlock:^(NSWindow *window, BOOL *stop) {
		if ([tabbedWindows containsObject:window])
		  {
		    selectedWindow = window;
		    *stop = YES;
		  }
	      }];

	    if (selectedWindow)
	      result = selectedWindow.lispFrame;
	  }
      });
#endif

  return result;
}

Lisp_Object
mac_get_tab_group_frames (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  Lisp_Object __block result = Qnil;

  if ([window respondsToSelector:@selector(tabGroup)])
    mac_within_gui (^{
	for (NSWindow *tabbedWindow in window.tabGroup.windows)
	  {
	    Lisp_Object frame = tabbedWindow.lispFrame;

	    if (!NILP (frame))
	      result = Fcons (frame, result);
	  }
	result = Fnreverse (result);
      });
  else if (!window.hasTitleBar)
    ;
  else if ([window respondsToSelector:@selector(tabbedWindows)])
    mac_within_gui (^{
	NSArrayOf (NSWindow *) *tabbedWindows = window.tabbedWindows;
	Lisp_Object frame;

	if (tabbedWindows == nil)
	  {
	    XSETFRAME (frame, f);
	    result = Fcons (frame, result);
	  }
	else
	  {
	    for (NSWindow *tabbedWindow in tabbedWindows)
	      {
		frame = tabbedWindow.lispFrame;
		if (!NILP (frame))
		  result = Fcons (frame, result);
	      }
	    result = Fnreverse (result);
	  }
      });

  return result;
}

void
mac_set_frame_window_structure_bounds (struct frame *f, NativeRectangle bounds)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{
      struct frame *p = FRAME_PARENT_FRAME (f);
      NSRect rect = NSMakeRect (bounds.x, bounds.y,
				bounds.width, bounds.height);

      if (p == NULL)
	{
	  NSRect baseScreenFrame = mac_get_base_screen_frame ();

	  rect.origin =
	    NSMakePoint (NSMinX (rect) + NSMinX (baseScreenFrame),
			 - NSMaxY (rect) + NSMaxY (baseScreenFrame));
	}
      else
	{
	  EmacsFrameController *frameController = FRAME_CONTROLLER (p);

	  rect = [frameController convertEmacsViewRectToScreen:rect];
	}

      [window setFrame:rect display:NO];
    });
}

static void
mac_get_frame_window_structure_bounds_1 (struct frame *f,
					 NativeRectangle *bounds)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  NSRect rect = [window frame];
  struct frame *p = FRAME_PARENT_FRAME (f);

  if (p == NULL)
    {
      NSRect baseScreenFrame = mac_get_base_screen_frame ();

      rect.origin = NSMakePoint (NSMinX (rect) - NSMinX (baseScreenFrame),
				 - NSMaxY (rect) + NSMaxY (baseScreenFrame));
    }
  else
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (p);

      rect = NSIntegralRect ([frameController
			       convertEmacsViewRectFromScreen:rect]);
    }

  STORE_NATIVE_RECT (*bounds, NSMinX (rect), NSMinY (rect),
		     NSWidth (rect), NSHeight (rect));
}

void
mac_get_frame_window_structure_bounds (struct frame *f, NativeRectangle *bounds)
{
  mac_within_gui (^{mac_get_frame_window_structure_bounds_1 (f, bounds);});
}

CGFloat
mac_get_frame_window_title_bar_height (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  CGFloat __block result;

  mac_within_gui (^{
      NSRect windowFrame = [window frame];
      NSRect rect = [NSWindow contentRectForFrameRect:windowFrame
					    styleMask:[window styleMask]];

      rect.origin = NSZeroPoint;
      rect = [[window contentView] convertRect:rect toView:nil];
      result = NSHeight (windowFrame) - NSHeight (rect);
    });

  return result;
}

CGSize
mac_get_frame_window_menu_bar_size (struct frame *f)
{
  NSSize menuBarSize = NSZeroSize;

  if ([NSMenu menuBarVisible])
    {
      NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
      NSScreen *screen = [window screen];

      if (![screen canShowMenuBar])
	screen = [[NSScreen screens] objectAtIndex:0];
      if (screen)
	menuBarSize.width = NSWidth ([screen frame]);
      menuBarSize.height = [[NSApp mainMenu] menuBarHeight];
    }

  return NSSizeToCGSize (menuBarSize);
}

CGRect
mac_get_frame_window_tool_bar_rect (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  CGRect __block result;

  mac_within_gui (^{
      NSView *contentView = [window contentView];
      NSRect rect;
      CGFloat toolBarHeight;

      if (FRAME_NATIVE_TOOL_BAR_P (f))
	{
	  if (FRAME_TOOL_BAR_HEIGHT (f))
	    {
	      rect = [contentView frame];
	      toolBarHeight = FRAME_TOOL_BAR_HEIGHT (f);
	      rect.origin.y += NSHeight (rect) - toolBarHeight;
	      rect.size.height = toolBarHeight;
	    }
	  else
	    rect = NSZeroRect;
	}
      else
	{
	  NSToolbar *toolbar = [window toolbar];

	  if (toolbar && [toolbar isVisible])
	    {
	      rect = [contentView frame];
	      toolBarHeight =
		(NSHeight ([NSWindow contentRectForFrameRect:[window frame]
						   styleMask:[window styleMask]])
		 - NSHeight (rect));
	      rect.origin.y += NSHeight (rect);
	      rect.size.height = toolBarHeight;
	    }
	  else
	    rect = NSZeroRect;
	}
      result = NSRectToCGRect ([contentView convertRect:rect toView:nil]);
    });

  return result;
}

CGRect
mac_get_frame_window_content_rect (struct frame *f, bool inner_p)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
  NSRect __block rect;

  mac_within_gui (^{
      NSView *contentView = [window contentView];

      rect = [contentView bounds];
      if (inner_p)
	{
	  rect = NSInsetRect (rect, FRAME_INTERNAL_BORDER_WIDTH (f),
			      FRAME_INTERNAL_BORDER_WIDTH (f));
	  if (FRAME_NATIVE_TOOL_BAR_P (f))
	    rect.size.height -= FRAME_TOOL_BAR_HEIGHT (f);
	}
      rect = [contentView convertRect:rect toView:nil];
    });

  return NSRectToCGRect (rect);
}

CGPoint
mac_get_frame_mouse (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  NSPoint __block mouseLocation = [NSEvent mouseLocation];

  mac_within_gui (^{
      mouseLocation = [frameController
			convertEmacsViewPointFromScreen:mouseLocation];
    });

  return NSPointToCGPoint (mouseLocation);
}

CGPoint
mac_get_global_mouse ()
{
  NSPoint mouseLocation = [NSEvent mouseLocation];
  NSRect baseScreenFrame = mac_get_base_screen_frame ();

  return CGPointMake (mouseLocation.x - NSMinX (baseScreenFrame),
		      - mouseLocation.y + NSMaxY (baseScreenFrame));
}

void
mac_convert_frame_point_to_global (struct frame *f, int *x, int *y)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  NSPoint __block point = NSMakePoint (*x, *y);
  NSRect baseScreenFrame = mac_get_base_screen_frame ();

  mac_within_gui (^{
      point = [frameController convertEmacsViewPointToScreen:point];
    });

  *x = point.x - NSMinX (baseScreenFrame);
  *y = - point.y + NSMaxY (baseScreenFrame);
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
CGRect
mac_rect_make (struct frame *f, CGFloat x, CGFloat y, CGFloat w, CGFloat h)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  NSRect rect = NSMakeRect (x, y, w, h);

  return NSRectToCGRect ([frameController centerScanEmacsViewRect:rect]);
}
#endif

void
mac_set_frame_window_background (struct frame *f, unsigned long color)
{
  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  mac_within_gui (^{
      [window setBackgroundColor:[NSColor colorWithXColorPixel:color]];
      if (has_visual_effect_view_p ())
	{
	  /* This formula comes from frame-set-background-mode in
	     frame.el.  */
	  NSAppearanceName name =
	    ((RED_FROM_ULONG (color) + GREEN_FROM_ULONG (color)
	      + BLUE_FROM_ULONG (color)) >= (int) (0xff * 3 * .6)
	     ? NS_APPEARANCE_NAME_VIBRANT_LIGHT
	     : NS_APPEARANCE_NAME_VIBRANT_DARK);

	  window.appearanceCustomization.appearance =
	    [NS_APPEARANCE appearanceNamed:name];
	}
    });
}

/* Store the screen positions of frame F into XPTR and YPTR.
   These are the positions of the containing window manager window,
   not Emacs's own window.  */

void
x_real_positions (struct frame *f, int *xptr, int *yptr)
{
  eassert (pthread_main_np ());
  NativeRectangle bounds;

  mac_get_frame_window_structure_bounds_1 (f, &bounds);

  *xptr = bounds.x;
  *yptr = bounds.y;
}

/* Flush display of frame F.  */

void
x_flush (struct frame *f)
{
  eassert (f && FRAME_MAC_P (f));
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!FRAME_MAC_DOUBLE_BUFFERED_P (f))
    {
      EmacsWindow *window;

      block_input ();
      window = FRAME_MAC_WINDOW_OBJECT (f);
      if (window.isVisible)
	mac_within_gui (^{[emacsController flushWindow:window force:YES];});
      unblock_input ();

      return;
    }
#endif
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  block_input ();
  mac_within_gui (^{[frameController displayEmacsViewIfNeeded];});
  unblock_input ();
}

static void
mac_flush_1 (struct frame *f)
{
  if (f == NULL)
    {
      Lisp_Object rest, frame;
      FOR_EACH_FRAME (rest, frame)
	if (FRAME_MAC_P (XFRAME (frame)))
	  mac_flush_1 (XFRAME (frame));
    }
  else
    {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
      if (!FRAME_MAC_DOUBLE_BUFFERED_P (f))
	{
	  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

	  if (window.isVisible)
	    [emacsController flushWindow:window force:NO];

	  return;
	}
#endif
#if 0 /* XXX: is this "flush" necessary for layer-backed views?  */
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      [frameController displayEmacsViewIfNeeded];
#endif
    }
}

void
mac_flush (struct frame *f)
{
  block_input ();
  mac_within_gui (^{mac_flush_1 (NULL);});
  unblock_input ();
}

void
mac_update_begin (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  mac_within_gui (^{
      [frameController lockFocusOnEmacsView];
      set_global_focus_view_frame (f);
    });
}

void
mac_update_end (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  mac_within_gui (^{
      CGRect clip_rect = unset_global_focus_view_frame ();

      [frameController unlockFocusOnEmacsView];
      mac_mask_rounded_bottom_corners (f, clip_rect, false);
    });
}

/* Create a new Mac window for the frame F and store its delegate in
   FRAME_MAC_WINDOW (f).  */

void
mac_create_frame_window (struct frame *f)
{
  EmacsFrameController * __block frameController;
  int left_pos, top_pos;

  /* Save possibly negative position values because they might be
     changed by `setToolbar' -> `windowDidResize:' if the toolbar is
     visible.  */
  if (f->size_hint_flags & (USPosition | PPosition)
      || FRAME_PARENT_FRAME (f))
    {
      left_pos = f->left_pos;
      top_pos = f->top_pos;
    }

  mac_within_gui (^{
      frameController = [[EmacsFrameController alloc] initWithEmacsFrame:f];
    });
  FRAME_MAC_WINDOW (f) =
    (void *) CF_BRIDGING_RETAIN (MRC_AUTORELEASE (frameController));

  if (f->size_hint_flags & (USPosition | PPosition)
      || FRAME_PARENT_FRAME (f))
    {
      f->left_pos = left_pos;
      f->top_pos = top_pos;
      mac_move_frame_window_structure (f, f->left_pos, f->top_pos);
    }
  else if (!FRAME_TOOLTIP_P (f))
    {
      mac_within_gui (^{
	  NSWindow *window = [frameController emacsWindow];
	  NSWindow *mainWindow = [NSApp mainWindow];

	  if (mainWindow == nil)
	    [window center];
	  else
	    {
	      NSRect windowFrame = [mainWindow frame];
	      NSPoint topLeft = NSMakePoint (NSMinX (windowFrame),
					     NSMaxY (windowFrame));

	      topLeft = [window cascadeTopLeftFromPoint:topLeft];
	      [window cascadeTopLeftFromPoint:topLeft];
	    }
	});
    }
}

/* Dispose of the Mac window of the frame F.  */

void
mac_dispose_frame_window (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  mac_within_gui (^{
      EmacsWindow *window = frameController.emacsWindow;

      /* Mac OS X 10.6 needs this.  */
      [window.parentWindow removeChildWindow:window];
      [frameController closeWindow];
      /* [overlayView.layer removeObserver:self forKeyPath:...] in
	 -[EmacsFrameController dealloc] must be called from the GUI
	 thread.  */
      CFRelease (FRAME_MAC_WINDOW (f));
    });
}

void
mac_change_frame_window_wm_state (struct frame *f, WMState flags_to_set,
				  WMState flags_to_clear)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  WMState oldState, newState;

  oldState = [frameController windowManagerState];
  newState = (oldState & ~flags_to_clear) | flags_to_set;
  mac_within_gui_allowing_inner_lisp (^{
      [frameController setWindowManagerState:newState];
    });
}

Cursor
mac_cursor_create (ThemeCursor shape, const XColor *fore_color,
		   const XColor *back_color)
{
  NSCursor *cursor = nil;
  NSImage *image;
  NSSize imageSize;
  NSArrayOf (NSImageRep *) *reps;
  enum {RED, GREEN, BLUE, ALPHA, NCOMPONENTS = ALPHA} c;
  int fg[NCOMPONENTS], delta[NCOMPONENTS];

  /* Fallbacks for Mac OS X 10.6.  */
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6)
    switch (shape)
      {
      case THEME_RESIZE_NORTH_SOUTH_CURSOR:
	shape = kThemeResizeUpDownCursor;
	break;
      case THEME_RESIZE_NORTH_CURSOR:
	shape = kThemeResizeUpCursor;
	break;
      case THEME_RESIZE_SOUTH_CURSOR:
	shape = kThemeResizeDownCursor;
	break;
      case THEME_RESIZE_EAST_WEST_CURSOR:
	shape = kThemeResizeLeftRightCursor;
	break;
      case THEME_RESIZE_EAST_CURSOR:
	shape = kThemeResizeRightCursor;
	break;
      case THEME_RESIZE_WEST_CURSOR:
	shape = kThemeResizeLeftCursor;
	break;
      }

  if ((fore_color && fore_color->pixel != 0)
      || (back_color && back_color->pixel != 0xffffff))
    cursor = [NSCursor cursorWithThemeCursor:shape];
  if (cursor == nil)
    return CFNumberCreate (NULL, kCFNumberSInt32Type, &shape);

  if (fore_color == NULL)
    fg[RED] = fg[GREEN] = fg[BLUE] = 0;
  else
    {
      fg[RED] = fore_color->red;
      fg[GREEN] = fore_color->green;
      fg[BLUE] = fore_color->blue;
    }
  if (back_color == NULL)
    for (c = 0; c < NCOMPONENTS; c++)
      delta[c] = 0xffff - fg[c];
  else
    {
      delta[RED] = back_color->red - fg[RED];
      delta[GREEN] = back_color->green - fg[GREEN];
      delta[BLUE] = back_color->blue - fg[BLUE];
    }

  image = [cursor image];
  reps = [image representations];

  imageSize = [image size];
  image = [[NSImage alloc] initWithSize:imageSize];
  for (NSImageRep * __strong rep in reps)
    {
      NSInteger width = [rep pixelsWide], height = [rep pixelsHigh];
      unsigned char *data = xmalloc (width * height * 4);
      CGContextRef context =
	CGBitmapContextCreate (data, width, height, 8, width * 4,
			       mac_cg_color_space_rgb,
			       (kCGImageAlphaPremultipliedLast
				| kCGBitmapByteOrder32Big));

      if (context)
	{
	  NSGraphicsContext *gcontext;
	  CGImageRef cgImage;
	  NSInteger i;

	  CGContextClearRect (context, CGRectMake (0, 0, width, height));
	  [NSGraphicsContext saveGraphicsState];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
	  gcontext = [NSGraphicsContext graphicsContextWithCGContext:context
							     flipped:NO];
#else
	  gcontext = [NSGraphicsContext graphicsContextWithGraphicsPort:context
								flipped:NO];
#endif
	  NSGraphicsContext.currentContext = gcontext;
	  [rep draw];
	  [NSGraphicsContext restoreGraphicsState];
	  for (i = 0; i < width * height; i++)
	    if (data[i*4+ALPHA] > 0x7f)
	      if ((max (data[i*4+RED], max (data[i*4+GREEN], data[i*4+BLUE]))
		   - min (data[i*4+RED], min (data[i*4+GREEN], data[i*4+BLUE])))
		  <= 5)
		for (c = 0; c < NCOMPONENTS; c++)
		  data[i*4+c] = (fg[c] * data[i*4+ALPHA]
				 + delta[c] * data[i*4+c]) / 0xffff;
	  cgImage = CGBitmapContextCreateImage (context);
	  CGContextRelease (context);
	  if (cgImage)
	    {
	      rep = [[[NSImage imageWithCGImage:cgImage exclusive:NO]
		       representations] objectAtIndex:0];
	      CGImageRelease (cgImage);
	    }
	}
      xfree (data);
      [rep setSize:imageSize];
      [image addRepresentation:rep];
    }
  cursor = [[NSCursor alloc] initWithImage:image hotSpot:[cursor hotSpot]];
  MRC_RELEASE (image);

  return CF_BRIDGING_RETAIN (MRC_AUTORELEASE (cursor));
}

void
mac_cursor_set (Cursor cursor)
{
  if (CFGetTypeID (cursor) == CFNumberGetTypeID ())
    {
#if __LP64__
      extern OSStatus SetThemeCursor (ThemeCursor);
#endif
      ThemeCursor cursor_value;

      if (CFNumberGetValue (cursor, kCFNumberSInt32Type, &cursor_value))
	SetThemeCursor (cursor_value);
    }
  else
    [(__bridge NSCursor *)cursor set];
}

void
mac_cursor_release (Cursor cursor)
{
  if (cursor)
    CFRelease (cursor);
}

void
mac_invalidate_frame_cursor_rects (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  [frameController invalidateCursorRectsForEmacsView];
}

void
mac_mask_rounded_bottom_corners (struct frame *f, CGRect clip_rect,
				 bool direct_p)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
  if (rounded_bottom_corners_need_masking_p ()
      && !FRAME_MAC_DOUBLE_BUFFERED_P (f))
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      [frameController maskRoundedBottomCorners:(NSRectFromCGRect (clip_rect))
				       directly:direct_p];
    }
#endif
}

void
mac_invalidate_rectangles (struct frame *f, NativeRectangle *rectangles, int n)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  NSRect *rects = alloca (sizeof (NSRect) * n);
  int i;

  for (i = 0; i < n; i++)
    rects[i] = NSRectFromCGRect (mac_rect_make (f, rectangles[i].x,
						rectangles[i].y,
						rectangles[i].width,
						rectangles[i].height));
  mac_within_gui (^{
      [frameController setEmacsViewNeedsDisplayInRects:rects count:n];
    });
}

void
mac_update_frame_window_style (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  mac_within_gui_allowing_inner_lisp (^{[frameController updateWindowStyle];});
}

void
mac_update_frame_window_parent (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  WMState windowManagerState = frameController.windowManagerState;
  struct frame *p = FRAME_PARENT_FRAME (f);
  int x = f->left_pos, y = f->top_pos;

  if ((windowManagerState & WM_STATE_DEDICATED_DESKTOP)
      && p)
    {
      /* Exit from full screen and try setting the `parent-frame'
	 frame parameter again via storeParentFrameFrameParameter. */
      mac_within_app (^{
	  [frameController changeFullScreenState:WM_STATE_FULLSCREEN];
	});

      return;
    }

  mac_within_gui (^{
      NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

      if ([window respondsToSelector:@selector(setAnimationBehavior:)])
	window.animationBehavior = (p == NULL
				    ? NSWindowAnimationBehaviorDocumentWindow
				    : NSWindowAnimationBehaviorNone);
      if (window.isVisible)
	{
	  [window.parentWindow removeChildWindow:window];
	  if (p)
	    {
	      NSWindow *newParentWindow = FRAME_MAC_WINDOW_OBJECT (p);

	      if (has_full_screen_with_dedicated_desktop_p ())
		window.collectionBehavior &=
		  ~NSWindowCollectionBehaviorFullScreenPrimary;
	      [newParentWindow addChildWindow:window ordered:NSWindowAbove];
	    }
	  else
	    [frameController updateCollectionBehavior];

	  [emacsController updatePresentationOptions];
	}
      mac_move_frame_window_structure_1 (f, x, y);
    });
  mac_update_frame_window_style (f);
  if (has_full_screen_with_dedicated_desktop_p ()
      && ((windowManagerState & (WM_STATE_FULLSCREEN
				 | WM_STATE_DEDICATED_DESKTOP))
	  == WM_STATE_FULLSCREEN)
      && EQ (get_frame_param (f, Qfullscreen), Qfullscreen)
      && p == NULL)
    mac_within_gui_allowing_inner_lisp (^{
	[frameController setWindowManagerState:(WM_STATE_DEDICATED_DESKTOP
						| windowManagerState)];
      });
}

Lisp_Object
mac_frame_list_z_order (struct frame *f)
{
  Lisp_Object result = Qnil;
  NSWindow *root = nil;

  block_input ();
  if (f)
    root = FRAME_MAC_WINDOW_OBJECT (f);
  for (NSWindow *window in [NSApp orderedWindows])
    if ([window isKindOfClass:EmacsWindow.class])
      {
	Lisp_Object frame = ((EmacsWindow *) window).lispFrame;

	if (EQ (frame, tip_frame))
	  continue;

	if (root)
	  {
	    NSWindow *ancestor = window;

	    do
	      {
		if ([ancestor isEqual:root])
		  break;
		ancestor = ancestor.parentWindow;
	      }
	    while (ancestor);
	    if (ancestor == nil)
	      continue;
	  }

	result = Fcons (frame, result);
      }
  unblock_input ();

  return Fnreverse (result);
}

void
mac_frame_restack (struct frame *f1, struct frame *f2, bool above_flag)
{
  NSWindow *window1, *window2;

  block_input ();
  window1 = FRAME_MAC_WINDOW_OBJECT (f1);
  window2 = FRAME_MAC_WINDOW_OBJECT (f2);
  mac_within_gui (^{
      [window1 orderWindow:(above_flag ? NSWindowAbove : NSWindowBelow)
		relativeTo:window2.windowNumber];
    });
  unblock_input ();
}


/************************************************************************
			   View and Drawing
 ************************************************************************/

/* Array of Carbon key events that are deferred during the execution
   of AppleScript.  NULL if not executing AppleScript.  */
static CFMutableArrayRef deferred_key_events;

static int mac_event_to_emacs_modifiers (NSEvent *);
static bool mac_try_buffer_and_glyph_matrix_access (void);
static void mac_end_buffer_and_glyph_matrix_access (void);

@implementation EmacsBacking

static vImage_Error
mac_vimage_buffer_init_8888 (vImage_Buffer *buf, vImagePixelCount height,
			     vImagePixelCount width)
{
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1090
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1090
  if (vImageBuffer_Init != NULL)
#endif
    return vImageBuffer_Init (buf, height, width, 8 * sizeof (Pixel_8888),
			      kvImageNoFlags);
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1090
  else
#endif
#endif
#if MAC_OS_X_VERSION_MAX_ALLOWED < 1090 || MAC_OS_X_VERSION_MIN_REQUIRED < 1090
    {
      buf->data = malloc (height * width * sizeof (Pixel_8888));
      buf->height = height;
      buf->width = width;
      buf->rowBytes = width * sizeof (Pixel_8888);

      return kvImageNoError;
    }
#endif
}

static vImage_Error
mac_vimage_copy_8888 (const vImage_Buffer *src, const vImage_Buffer *dest,
		      vImage_Flags flags)
{
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101000
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
  if (vImageCopyBuffer != NULL)
#endif
    return vImageCopyBuffer (src, dest, sizeof (Pixel_8888), flags);
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
  else
#endif
#endif
#if MAC_OS_X_VERSION_MAX_ALLOWED < 101000 || MAC_OS_X_VERSION_MIN_REQUIRED < 101000
    {
      const uint8_t identityMap[] = {0, 1, 2, 3};

      return vImagePermuteChannels_ARGB8888 (src, dest, identityMap, flags);
    }
#endif
}

static IOSurfaceRef
mac_iosurface_create (size_t width, size_t height)
{
  NSDictionary *properties =
    [NSDictionary dictionaryWithObjectsAndKeys:
	      [NSNumber numberWithUnsignedLong:width], kIOSurfaceWidth,
	      [NSNumber numberWithUnsignedLong:height], kIOSurfaceHeight,
	      [NSNumber numberWithInt:4], kIOSurfaceBytesPerElement,
	      [NSNumber numberWithUnsignedInt:'BGRA'], kIOSurfacePixelFormat,
		  nil];

  return IOSurfaceCreate ((__bridge CFDictionaryRef) properties);
}

- (instancetype)initWithView:(NSView *)view
{
  self = [super init];
  if (self == nil)
    return nil;

  scaleFactor = view.window.backingScaleFactor;

  NSSize size = view.bounds.size;
  size_t width = size.width * scaleFactor;
  size_t height = size.height * scaleFactor;
  CGContextRef bitmaps[2] = {NULL, NULL};
  IOSurfaceRef surfaces[2] = {NULL, NULL};

  for (int i = 0; i < 2; i++)
    {
      void *data = NULL;
      size_t bytes_per_row = 0;

      surfaces[i] = mac_iosurface_create (width, height);
      if (surfaces[i])
	{
	  IOSurfaceLock (surfaces[i], 0, NULL);
	  data = IOSurfaceGetBaseAddress (surfaces[i]);
	  bytes_per_row = IOSurfaceGetBytesPerRow (surfaces[i]);
	}
      bitmaps[i] = CGBitmapContextCreate (data, width, height, 8, bytes_per_row,
					  view.window.colorSpace.CGColorSpace,
					  /* This combination enables
					     us to use LCD Font
					     smoothing.  */
					  (kCGImageAlphaPremultipliedFirst
					   | kCGBitmapByteOrder32Host));
      CGContextTranslateCTM (bitmaps[i], 0, height);
      CGContextScaleCTM (bitmaps[i], scaleFactor, - scaleFactor);
      if (surfaces[i])
	IOSurfaceUnlock (surfaces[i], 0, NULL);
      else
	break;
    }
  backBitmap = bitmaps[0];
  backSurface = surfaces[0];
  frontBitmap = bitmaps[1];
  frontSurface = surfaces[1];
#if HAVE_MAC_METAL
  [self updateMTLObjectsForView:view];
#endif

  return self;
}

- (void)swapResourcesAndStartCopy
{
  CGContextRef bitmap = backBitmap;
  backBitmap = frontBitmap;
  frontBitmap = bitmap;

  IOSurfaceRef surface = backSurface;
  backSurface = frontSurface;
  frontSurface = surface;

#if HAVE_MAC_METAL
  id <MTLTexture> texture = backTexture;
  backTexture = frontTexture;
  frontTexture = texture;
#endif

  dispatch_queue_t queue =
    dispatch_get_global_queue (DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  copyFromToBackSemaphore = dispatch_semaphore_create (0);

  dispatch_async (queue, ^{
      size_t width = IOSurfaceGetWidth (backSurface);
      size_t height = IOSurfaceGetHeight (backSurface);

#if HAVE_MAC_METAL
      if (backTexture)
	{
	  id <MTLCommandBuffer> commandBuffer = [mtlCommandQueue commandBuffer];
	  id <MTLBlitCommandEncoder> blitCommandEncoder =
	    [commandBuffer blitCommandEncoder];

	  [blitCommandEncoder copyFromTexture:frontTexture
				  sourceSlice:0 sourceLevel:0
				 sourceOrigin:(MTLOriginMake (0, 0, 0))
				   sourceSize:(MTLSizeMake (width, height, 1))
				    toTexture:backTexture
			     destinationSlice:0 destinationLevel:0
			    destinationOrigin:(MTLOriginMake (0, 0, 0))];
	  [blitCommandEncoder endEncoding];
	  [commandBuffer commit];
	  [commandBuffer waitUntilCompleted];
	}
      else
#endif
	{
	  vImage_Buffer src, dest;

	  src.data = IOSurfaceGetBaseAddress (frontSurface);
	  src.rowBytes = IOSurfaceGetBytesPerRow (frontSurface);
	  dest.data = IOSurfaceGetBaseAddress (backSurface);
	  dest.rowBytes = IOSurfaceGetBytesPerRow (backSurface);
	  src.width = dest.width = width;
	  src.height = dest.height = height;

	  IOSurfaceLock (frontSurface, kIOSurfaceLockReadOnly, NULL);
	  IOSurfaceLock (backSurface, 0, NULL);
	  mac_vimage_copy_8888 (&src, &dest, kvImageNoFlags);
	  IOSurfaceUnlock (backSurface, 0, NULL);
	  IOSurfaceUnlock (frontSurface, kIOSurfaceLockReadOnly, NULL);
	}

      dispatch_semaphore_signal (copyFromToBackSemaphore);
    });
}

- (void)waitCopyFromFrontToBack
{
  if (copyFromToBackSemaphore)
    {
      dispatch_semaphore_wait (copyFromToBackSemaphore, DISPATCH_TIME_FOREVER);
#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
      dispatch_release (copyFromToBackSemaphore);
#endif
      copyFromToBackSemaphore = NULL;
    }
}

- (void)dealloc
{
  [self waitCopyFromFrontToBack];
  CGContextRelease (backBitmap);
  CGContextRelease (frontBitmap);
  if (backSurface)
    CFRelease (backSurface);
  if (frontSurface)
    CFRelease (frontSurface);
#if !USE_ARC
#if HAVE_MAC_METAL
  [backTexture release];
  [frontTexture release];
  [mtlCommandQueue release];
#endif
  [super dealloc];
#endif
}

- (char)lockCount
{
  return lockCount;
}

- (NSSize)size
{
  return NSMakeSize (CGBitmapContextGetWidth (backBitmap) / scaleFactor,
		     CGBitmapContextGetHeight (backBitmap) / scaleFactor);
}

#if HAVE_MAC_METAL
static id <MTLTexture>
mac_texture_create_with_surface (id <MTLDevice> device, IOSurfaceRef surface)
{
  if (!device || !surface)
    return nil;

  MTLTextureDescriptor *textureDescriptor =
    [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
				   width:(IOSurfaceGetWidth (surface))
				  height:(IOSurfaceGetHeight (surface))
			       mipmapped:NO];

  return [device newTextureWithDescriptor:textureDescriptor
				iosurface:surface plane:0];
}

- (void)updateMTLObjectsForView:(NSView *)view
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
  if (CGDirectDisplayCopyCurrentMetalDevice == NULL)
    return;
#endif
  CGDirectDisplayID displayID =
    (CGDirectDisplayID) [[view.window.screen.deviceDescription
			     objectForKey:@"NSScreenNumber"] unsignedIntValue];
  id <MTLDevice> newDevice = CGDirectDisplayCopyCurrentMetalDevice (displayID);

  if (newDevice != mtlCommandQueue.device)
    {
      MRC_RELEASE (backTexture);
      backTexture = mac_texture_create_with_surface (newDevice, backSurface);
      MRC_RELEASE (frontTexture);
      if (backTexture == nil)
	frontTexture = nil;
      else
	{
	  frontTexture = mac_texture_create_with_surface (newDevice,
							  frontSurface);
	  if (frontTexture == nil)
	    {
	      MRC_RELEASE (backTexture);
	      backTexture = nil;
	    }
	}
      MRC_RELEASE (mtlCommandQueue);
      mtlCommandQueue = [newDevice newCommandQueue];
    }
  MRC_RELEASE (newDevice);
}
#endif

- (void)setContentsForLayer:(CALayer *)layer
{
  id contents;

  eassert (lockCount == 0);

  [self waitCopyFromFrontToBack];
  if (frontSurface)
    {
      [self swapResourcesAndStartCopy];
      layer.contents = (__bridge id) frontSurface;
    }
  else
    {
      if (backSurface)
	IOSurfaceLock (backSurface, kIOSurfaceLockReadOnly, NULL);
      layer.contents =
	CF_BRIDGING_RELEASE (CGBitmapContextCreateImage (backBitmap));
      if (backSurface)
	IOSurfaceUnlock (backSurface, kIOSurfaceLockReadOnly, NULL);
    }
  layer.contentsScale = scaleFactor;
}

- (void)lockFocus
{
  lockCount++;
  [self waitCopyFromFrontToBack];
  if (backSurface)
    IOSurfaceLock (backSurface, 0, NULL);

  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext =
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
    [NSGraphicsContext graphicsContextWithCGContext:backBitmap flipped:NO];
#else
    [NSGraphicsContext graphicsContextWithGraphicsPort:backBitmap flipped:NO];
#endif
}

- (void)unlockFocus
{
  eassert (lockCount);
  eassert (backBitmap);

  lockCount--;
  if (backSurface)
    IOSurfaceUnlock (backSurface, 0, NULL);
  [NSGraphicsContext restoreGraphicsState];
}

- (void)scrollRect:(NSRect)rect by:(NSSize)delta
{
  eassert (CGBitmapContextGetBitsPerPixel (backBitmap)
	   == 8 * sizeof (Pixel_8888));
  NSInteger bitmapWidth = CGBitmapContextGetWidth (backBitmap);
  NSInteger bitmapHeight = CGBitmapContextGetHeight (backBitmap);
  NSInteger bytesPerRow = CGBitmapContextGetBytesPerRow (backBitmap);
  const NSInteger bytesPerPixel = sizeof (Pixel_8888);
  unsigned char *srcData = CGBitmapContextGetData (backBitmap);
  NSInteger deltaX, deltaY, srcX, srcY, width, height;

  if (scaleFactor != 1.0)
    {
      rect.origin.x *= scaleFactor, rect.origin.y *= scaleFactor;
      rect.size.width *= scaleFactor, rect.size.height *= scaleFactor;
      delta.width *= scaleFactor, delta.height *= scaleFactor;
    }

  deltaX = delta.width, deltaY = delta.height;
  srcX = NSMinX (rect), srcY = NSMinY (rect);
  width = NSWidth (rect), height = NSHeight (rect);

#if HAVE_MAC_METAL
  if (backTexture && width * height >= 0x10000)
    {
      MTLTextureDescriptor *textureDescriptor =
	[MTLTextureDescriptor
	  texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
				       width:width height:height mipmapped:NO];
      id <MTLTexture> texture =
	[mtlCommandQueue.device newTextureWithDescriptor:textureDescriptor];
      id <MTLCommandBuffer> commandBuffer = [mtlCommandQueue commandBuffer];
      id <MTLBlitCommandEncoder> blitCommandEncoder =
	[commandBuffer blitCommandEncoder];

      [blitCommandEncoder copyFromTexture:backTexture
			      sourceSlice:0 sourceLevel:0
			     sourceOrigin:(MTLOriginMake (srcX, srcY, 0))
			       sourceSize:(MTLSizeMake (width, height, 1))
				toTexture:texture
			 destinationSlice:0 destinationLevel:0
			destinationOrigin:(MTLOriginMake (0, 0, 0))];
      [blitCommandEncoder copyFromTexture:texture
			      sourceSlice:0 sourceLevel:0
			     sourceOrigin:(MTLOriginMake (0, 0, 0))
			       sourceSize:(MTLSizeMake (width, height, 1))
				toTexture:backTexture
			 destinationSlice:0 destinationLevel:0
			destinationOrigin:(MTLOriginMake (srcX + deltaX,
							  srcY + deltaY, 0))];
      [blitCommandEncoder endEncoding];
      IOSurfaceUnlock (backSurface, 0, NULL);
      [commandBuffer commit];
      [commandBuffer waitUntilCompleted];
      IOSurfaceLock (backSurface, 0, NULL);
      MRC_RELEASE (texture);
    }
  else
#endif
    {
      vImage_Buffer src, dest;

      src.data = srcData + srcY * bytesPerRow + srcX * bytesPerPixel;
      src.height = height;
      src.width = width;
      src.rowBytes = bytesPerRow;
      if (deltaY != 0)
	{
	  if (deltaY > 0)
	    {
	      src.data += (src.height - 1) * bytesPerRow;
	      src.rowBytes = - bytesPerRow;
	    }
	  dest = src;
	  dest.data += deltaY * bytesPerRow + deltaX * bytesPerPixel;
	  /* As of macOS 10.13, vImageCopyBuffer no longer does
	     multi-threading even if we give it kvImageNoFlags.  We
	     rather pass kvImageDoNotTile so it works with overlapping
	     areas on older versions.  */
	  mac_vimage_copy_8888 (&src, &dest, kvImageDoNotTile);
	}
      else /* deltaY == 0, which does not happen on the current
	  version of Emacs. */
	{
	  dest = src;
	  dest.data += /* deltaY * bytesPerRow + */ deltaX * bytesPerPixel;
	  if (labs (deltaX) >= src.width)
	    mac_vimage_copy_8888 (&src, &dest, kvImageNoFlags);
	  else if (deltaX == 0)
	    return;
	  else
	    {
	      vImage_Buffer buf;

	      mac_vimage_buffer_init_8888 (&buf, src.height, src.width);
	      mac_vimage_copy_8888 (&src, &buf, kvImageNoFlags);
	      mac_vimage_copy_8888 (&buf, &dest, kvImageNoFlags);
	      free (buf.data);
	    }
	}
    }
}

- (NSData *)imageBuffersDataForRectanglesData:(NSData *)rectanglesData
{
  NSInteger i, count = rectanglesData.length / sizeof (NativeRectangle);
  const NativeRectangle *rectangles = rectanglesData.bytes;
  NSMutableData *imageBuffersData =
    [NSMutableData dataWithCapacity:(count * sizeof (vImage_Buffer))];
  vImage_Buffer *imageBuffers = imageBuffersData.mutableBytes;
  [self waitCopyFromFrontToBack];
  if (backSurface)
    IOSurfaceLock (backSurface, kIOSurfaceLockReadOnly, NULL);
  unsigned char *srcData = CGBitmapContextGetData (backBitmap);
  NSInteger scale = scaleFactor;
  vImage_Buffer src;

  src.rowBytes = CGBitmapContextGetBytesPerRow (backBitmap);
  for (i = 0; i < count; i++)
    {
      vImage_Buffer *dest = imageBuffers + i;

      mac_vimage_buffer_init_8888 (dest, rectangles[i].height * scale,
				   rectangles[i].width * scale);
      src.height = dest->height, src.width = dest->width;
      src.data = srcData + (rectangles[i].y * src.rowBytes
			    + rectangles[i].x * sizeof (Pixel_8888)) * scale;
      mac_vimage_copy_8888 (&src, dest, kvImageNoFlags);
    }
  if (backSurface)
    IOSurfaceUnlock (backSurface, kIOSurfaceLockReadOnly, NULL);

  return imageBuffersData;
}

- (void)restoreImageBuffersData:(NSData *)imageBuffersData
	      forRectanglesData:(NSData *)rectanglesData
{
  NSInteger i, count = rectanglesData.length / sizeof (NativeRectangle);
  const NativeRectangle *rectangles = rectanglesData.bytes;
  const vImage_Buffer *imageBuffers = imageBuffersData.bytes;
  [self waitCopyFromFrontToBack];
  if (backSurface)
    IOSurfaceLock (backSurface, 0, NULL);
  unsigned char *destData = CGBitmapContextGetData (backBitmap);
  NSInteger scale = scaleFactor;
  vImage_Buffer dest;

  dest.rowBytes = CGBitmapContextGetBytesPerRow (backBitmap);
  for (i = 0; i < count; i++)
    {
      const vImage_Buffer *src = imageBuffers + i;

      dest.height = src->height, dest.width = src->width;
      dest.data = destData + (rectangles[i].y * dest.rowBytes
			      + rectangles[i].x * sizeof (Pixel_8888)) * scale;
      mac_vimage_copy_8888 (src, &dest, kvImageNoFlags);
      free (src->data);
    }
  if (backSurface)
    IOSurfaceUnlock (backSurface, 0, NULL);
}

@end				// EmacsBacking

/* View for Emacs frame.  */

@implementation EmacsView

static BOOL emacsViewUpdateLayerDisabled;

- (instancetype)initWithFrame:(NSRect)frameRect
{
  self = [super initWithFrame:frameRect];
  if (self == nil)
    return nil;

  [[NSNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(viewFrameDidChange:)
	   name:@"NSViewFrameDidChangeNotification"
	 object:self];

  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
#if !USE_ARC
  [backing release];
  [super dealloc];
#endif
}

+ (void)globallyDisableUpdateLayer:(BOOL)flag
{
  emacsViewUpdateLayerDisabled = flag;
}

- (struct frame *)emacsFrame
{
  EmacsFrameController *frameController =
    (EmacsFrameController *) self.window.delegate;

  return frameController.emacsFrame;
}

- (void)drawRect:(NSRect)aRect
{
  struct frame *f = self.emacsFrame;
  int x = NSMinX (aRect), y = NSMinY (aRect);
  int width = NSWidth (aRect), height = NSHeight (aRect);

  set_global_focus_view_frame (f);
  mac_clear_area (f, x, y, width, height);
  mac_begin_scale_mismatch_detection (f);
  expose_frame (f, x, y, width, height);
  x_clear_under_internal_border (f);
  if (mac_end_scale_mismatch_detection (f)
      && [NSWindow instancesRespondToSelector:@selector(backingScaleFactor)])
    SET_FRAME_GARBAGED (f);
  if (!backing)
    mac_invert_flash_rectangles (f);
  unset_global_focus_view_frame ();
}

- (BOOL)isFlipped
{
  return YES;
}

- (BOOL)isOpaque
{
  return !(has_visual_effect_view_p () && self.layer);
}

#if HAVE_MAC_METAL
- (void)updateMTLObjects
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!self.layer)
    return;
#endif
  [backing updateMTLObjectsForView:self];
}
#endif

- (BOOL)wantsUpdateLayer
{
  return self.layer != nil && !emacsViewUpdateLayerDisabled;
}

- (void)updateLayer
{
  struct frame *f = self.emacsFrame;
  NSData *rectanglesData = ((__bridge NSData *)
			    (FRAME_FLASH_RECTANGLES_DATA (f)));
  NSData *savedImageBuffersData;

  if (backing.lockCount)
    return;

  if (!backing)
    {
      if (mac_try_buffer_and_glyph_matrix_access ())
	{
	  [self lockFocusOnBacking];
	  [self drawRect:self.bounds];
	  [self unlockFocusOnBacking];
	  self.needsDisplay = NO;
	  mac_end_buffer_and_glyph_matrix_access ();
	}
      else
	return;
    }

  if (rectanglesData)
    {
      savedImageBuffersData =
	[backing imageBuffersDataForRectanglesData:rectanglesData];
      [self lockFocusOnBacking];
      set_global_focus_view_frame (f);
      mac_invert_flash_rectangles (f);
      unset_global_focus_view_frame ();
      [self unlockFocusOnBacking];
      self.needsDisplay = NO;
    }

  [backing setContentsForLayer:self.layer];

  if (rectanglesData)
    [backing restoreImageBuffersData:savedImageBuffersData
		   forRectanglesData:rectanglesData];
}

- (void)suspendSynchronizingBackingBitmap:(BOOL)flag
{
  synchronizeBackingSuspended = flag;
}

- (void)synchronizeBacking
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!self.layer)
    return;
#endif
  if (!synchronizeBackingSuspended)
    if (backing && !NSEqualSizes (backing.size, self.bounds.size))
      {
	MRC_RELEASE (backing);
	backing = nil;
      }
}

- (void)lockFocusOnBacking
{
  eassert (pthread_main_np ());

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!self.layer)
    {
      [self lockFocus];

      return;
    }
#endif
  if (!backing)
    backing = [[EmacsBacking alloc] initWithView:self];
  [backing lockFocus];
}

- (void)unlockFocusOnBacking
{
  eassert (pthread_main_np ());

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!self.layer)
    {
      [self unlockFocus];

      return;
    }
#endif
  [backing unlockFocus];
}

- (void)scrollBackingRect:(NSRect)rect by:(NSSize)delta
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!self.layer)
    {
      [self scrollRect:rect by:delta];

      return;
    }
#endif
  [backing scrollRect:rect by:delta];
}

- (void)viewDidChangeBackingProperties
{
  MRC_RELEASE (backing);
  backing = nil;
  self.needsDisplay = YES;
}

- (void)viewFrameDidChange:(NSNotification *)notification
{
  [self synchronizeBacking];
}

@end				// EmacsView

@implementation EmacsMainView

+ (void)initialize
{
  if (self == [EmacsMainView class])
    {
      NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

      if ([defaults objectForKey:@"ApplePressAndHoldEnabled"] == nil)
	{
	  NSDictionaryOf (NSString *, NSString *) *appDefaults =
	    [NSDictionary dictionaryWithObject:@"NO"
					forKey:@"ApplePressAndHoldEnabled"];

	  [defaults registerDefaults:appDefaults];
	}
    }
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
  NSTrackingArea *trackingAreaForCursor;

  self = [super initWithFrame:frameRect];
  if (self == nil)
    return nil;

  trackingAreaForCursor = [[NSTrackingArea alloc]
			    initWithRect:NSZeroRect
				 options:(NSTrackingCursorUpdate
					  | NSTrackingActiveInKeyWindow
					  | NSTrackingInVisibleRect)
				   owner:self userInfo:nil];
  [self addTrackingArea:trackingAreaForCursor];
  MRC_RELEASE (trackingAreaForCursor);

  return self;
}

#if !USE_ARC
- (void)dealloc
{
  [candidateListTouchBarItem release];
  [rawKeyEvent release];
  [markedText release];
  [super dealloc];
}
#endif

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
- (void)drawRect:(NSRect)aRect
{
  [super drawRect:aRect];
  roundedBottomCornersCopied = NO;
}
#endif

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
- (void)scrollRect:(NSRect)aRect by:(NSSize)offset
{
  [super scrollRect:aRect by:offset];
  if (rounded_bottom_corners_need_masking_p ()
      && !self.layer)
    {
      if (roundedBottomCornersCopied)
	[self setNeedsDisplay:YES];
      else
	{
	  NSRect rect = [self convertRect:aRect toView:nil];

	  rect = [[self window] _intersectBottomCornersWithRect:rect];
	  if (!NSIsEmptyRect (rect))
	    {
	      rect = [self convertRect:rect fromView:nil];
	      rect.origin.x += offset.width;
	      rect.origin.y += offset.height;
	      [self setNeedsDisplayInRect:rect];
	      roundedBottomCornersCopied = YES;
	    }
	}
    }
}
#endif

- (void)setMarkedText:(id)aString
{
  if (markedText == aString)
    return;

  (void) MRC_AUTORELEASE (markedText);
  markedText = [aString copy];
}

- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (id)target
{
  return target;
}

- (SEL)action
{
  return action;
}

- (void)setTarget:(id)anObject
{
  target = anObject;		/* Targets should not be retained. */
}

- (void)setAction:(SEL)aSelector
{
  action = aSelector;
}

- (BOOL)sendAction:(SEL)theAction to:(id)theTarget
{
  return [NSApp sendAction:theAction to:theTarget from:self];
}

- (struct input_event *)inputEvent
{
  return &inputEvent;
}

- (void)mouseDown:(NSEvent *)theEvent
{
  struct frame *f = [self emacsFrame];
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  NSPoint point = [self convertPoint:[theEvent locationInWindow] fromView:nil];
  bool tool_bar_p = false;
  NSUInteger down_p;

  down_p = (NSEventMaskFromType ([theEvent type]) & ANY_MOUSE_DOWN_EVENT_MASK);

  if (!down_p && !(dpyinfo->grabbed & (1 << [theEvent buttonNumber])))
    return;

  dpyinfo->last_mouse_glyph_frame = NULL;

  EVENT_INIT (inputEvent);
  inputEvent.arg = Qnil;
  mac_cgevent_to_input_event ([theEvent coreGraphicsEvent], &inputEvent);

  {
    Lisp_Object window;
    EMACS_INT x = point.x;
    EMACS_INT y = point.y;

    XSETINT (inputEvent.x, x);
    XSETINT (inputEvent.y, y);

    window = window_from_coordinates (f, x, y, 0, true);
    if (EQ (window, f->tool_bar_window))
      {
	[self lockFocusOnBacking];
	set_global_focus_view_frame (f);
	if (down_p)
	  handle_tool_bar_click (f, x, y, 1, 0);
	else
	  handle_tool_bar_click (f, x, y, 0, inputEvent.modifiers);
	unset_global_focus_view_frame ();
	[self unlockFocusOnBacking];
	tool_bar_p = true;
      }
    else
      {
	XSETFRAME (inputEvent.frame_or_window, f);
	inputEvent.kind = MOUSE_CLICK_EVENT;
      }
  }

  if (down_p)
    {
      dpyinfo->grabbed |= (1 << [theEvent buttonNumber]);
      dpyinfo->last_mouse_frame = f;

      if (!tool_bar_p)
	f->last_tool_bar_item = -1;
    }
  else
    dpyinfo->grabbed &= ~(1 << [theEvent buttonNumber]);

  /* Ignore any mouse motion that happened before this event; any
     subsequent mouse-movement Emacs events should reflect only motion
     after the ButtonPress.  */
  if (f != 0)
    f->mouse_moved = false;

  inputEvent.modifiers |= (down_p ? down_modifier : up_modifier);
  if (inputEvent.kind == MOUSE_CLICK_EVENT)
    [self sendAction:action to:target];
}

- (void)mouseUp:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)rightMouseDown:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)rightMouseUp:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)otherMouseDown:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)otherMouseUp:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

static Lisp_Object
event_phase_to_symbol (NSEventPhase phase)
{
  switch (phase)
    {
    case NSEventPhaseNone:		return Qnone;
    case NSEventPhaseBegan:		return Qbegan;
    case NSEventPhaseStationary:	return Qstationary;
    case NSEventPhaseChanged:		return Qchanged;
    case NSEventPhaseEnded:		return Qended;
    case NSEventPhaseCancelled:		return Qcancelled;
    case NSEventPhaseMayBegin:		return Qmay_begin;
    default:				return make_number (phase);
    }
}

- (void)scrollWheel:(NSEvent *)theEvent
{
  struct frame *f = [self emacsFrame];
  NSPoint point = [self convertPoint:[theEvent locationInWindow] fromView:nil];
  int modifiers = mac_event_to_emacs_modifiers (theEvent);
  NSEventType type = [theEvent type];
  BOOL isDirectionInvertedFromDevice = NO;
  BOOL isSwipeTrackingFromScrollEventsEnabled = NO;
  CGFloat deltaX = 0, deltaY = 0, deltaZ = 0;
  CGFloat scrollingDeltaX = 0, scrollingDeltaY = 0;
  Lisp_Object phase = Qnil, momentumPhase = Qnil;

  switch (type)
    {
    case NSEventTypeScrollWheel:
      if ([theEvent respondsToSelector:@selector(hasPreciseScrollingDeltas)]
	  && [theEvent hasPreciseScrollingDeltas])
	{
	  scrollingDeltaX = [theEvent scrollingDeltaX];
	  scrollingDeltaY = [theEvent scrollingDeltaY];
	}
      else if ([theEvent respondsToSelector:@selector(_continuousScroll)]
	  && [theEvent _continuousScroll])
	{
	  scrollingDeltaX = [theEvent deviceDeltaX];
	  scrollingDeltaY = [theEvent deviceDeltaY];
	}
      if ([theEvent respondsToSelector:@selector(phase)])
	{
	  phase = event_phase_to_symbol ([theEvent phase]);
	  momentumPhase = event_phase_to_symbol ([theEvent momentumPhase]);
	}
      else if ([theEvent respondsToSelector:@selector(_scrollPhase)])
	{
	  switch ([theEvent _scrollPhase])
	    {
	    case 0:	momentumPhase = Qnone;		break;
	    case 1:	momentumPhase = Qbegan;		break;
	    case 2:	momentumPhase = Qchanged;	break;
	    case 3:	momentumPhase = Qended;		break;
	    }
	}
      if (!NILP (momentumPhase))
	{
	  if (EQ (momentumPhase, Qnone))
	    {
	      savedWheelPoint = point;
	      savedWheelModifiers = modifiers;
	    }
	  else
	    {
	      point = savedWheelPoint;
	      modifiers = savedWheelModifiers;
	    }
	}
      if ([NSEvent respondsToSelector:@selector(isSwipeTrackingFromScrollEventsEnabled)])
	isSwipeTrackingFromScrollEventsEnabled =
	  [NSEvent isSwipeTrackingFromScrollEventsEnabled];
      FALLTHROUGH;

    case NSEventTypeSwipe:
      deltaX = [theEvent deltaX];
      deltaY = [theEvent deltaY];
      deltaZ = [theEvent deltaZ];
      if ([theEvent respondsToSelector:@selector(isDirectionInvertedFromDevice)])
	isDirectionInvertedFromDevice = [theEvent isDirectionInvertedFromDevice];
      break;

    case NSEventTypeMagnify:
      if (has_gesture_recognizer_p ())
	phase = event_phase_to_symbol ([theEvent phase]);
      else
	/* -[NSEvent phase] is not available on Mac OS X 10.6.  For a
	   non-scroll event, it crashes on Mac OS X 10.7, and always
	   returns NSEventPhaseNone on OS X 10.8 - 10.9. */
	phase = Qnone;
      FALLTHROUGH;
    case NSEventTypeGesture:
      deltaY = [theEvent magnification];
      break;

    case NSEventTypeRotate:
      deltaX = [theEvent rotation];
      if (has_gesture_recognizer_p ())
	phase = event_phase_to_symbol ([theEvent phase]);
      else
	phase = Qnone;
      break;

#if __LP64__
    case NSEventTypeSmartMagnify:
      type = NSEventTypeGesture;
      break;
#endif

    default:
      emacs_abort ();
    }

  if (
#if 0 /* We let the framework decide whether events to non-focus frame
	 get accepted.  */
      f != mac_focus_frame (&one_mac_display_info) ||
#endif
      deltaX == 0 && (deltaY == 0 && type != NSEventTypeGesture) && deltaZ == 0
      && scrollingDeltaX == 0 && scrollingDeltaY == 0
      && NILP (phase) && NILP (momentumPhase))
    return;

  /* Two-finger touch (and subsequent release or gesture events other
     than scrolling) on trackpads produces NSEventPhaseMayBegin (and
     NSEventPhaseCancelled, resp.) on OS X 10.8.  We ignore them for
     now because they interfere with `mouse--strip-first-event'.  */
  if (type == NSEventTypeScrollWheel
      && (EQ (phase, Qmay_begin) || EQ (phase, Qcancelled)))
    return;

  if (point.x < 0 || point.y < 0
      || EQ (window_from_coordinates (f, point.x, point.y, 0, true),
	     f->tool_bar_window))
    return;

  EVENT_INIT (inputEvent);
  if (type == NSEventTypeScrollWheel || type == NSEventTypeSwipe)
    {
      if (isDirectionInvertedFromDevice)
	inputEvent.arg = list2 (QCdirection_inverted_from_device_p, Qt);
      if (type == NSEventTypeScrollWheel)
	{
	  inputEvent.arg = nconc2 (inputEvent.arg,
				   listn (CONSTYPE_HEAP, 6,
					  QCdelta_x, make_float (deltaX),
					  QCdelta_y, make_float (deltaY),
					  QCdelta_z, make_float (deltaZ)));
	  if (scrollingDeltaX != 0 || scrollingDeltaY != 0)
	    inputEvent.arg = nconc2 (inputEvent.arg,
				     list4 (QCscrolling_delta_x,
					    make_float (scrollingDeltaX),
					    QCscrolling_delta_y,
					    make_float (scrollingDeltaY)));
	  if (!NILP (phase))
	    inputEvent.arg = nconc2 (inputEvent.arg, list2 (QCphase, phase));
	  if (!NILP (momentumPhase))
	    inputEvent.arg = nconc2 (inputEvent.arg,
				     list2 (QCmomentum_phase, momentumPhase));
	  if (isSwipeTrackingFromScrollEventsEnabled)
	    inputEvent.arg =
	      nconc2 (inputEvent.arg,
		      list2 (QCswipe_tracking_from_scroll_events_enabled_p,
			     Qt));
	}
    }
  else if (type == NSEventTypeMagnify)
    inputEvent.arg = list4 (QCmagnification, make_float (deltaY),
			    QCphase, phase);
  else if (type == NSEventTypeGesture)
    inputEvent.arg = list2 (QCmagnification, make_float (deltaY));
  else if (type == NSEventTypeRotate)
    inputEvent.arg = list4 (QCrotation, make_float (deltaX),
			    QCphase, phase);
  else
    inputEvent.arg = Qnil;
  inputEvent.kind = (deltaY != 0 || scrollingDeltaY != 0
		     || type == NSEventTypeMagnify || type == NSEventTypeGesture
		     ? WHEEL_EVENT : HORIZ_WHEEL_EVENT);
  inputEvent.code = 0;
  inputEvent.modifiers =
    (modifiers
     | (deltaY < 0 || scrollingDeltaY < 0 ? down_modifier
	: (deltaY > 0 || scrollingDeltaY > 0 ? up_modifier
	   : (deltaX < 0 || scrollingDeltaX < 0 ? down_modifier
	      : up_modifier)))
     | (type == NSEventTypeScrollWheel ? 0
	: (type == NSEventTypeSwipe ? drag_modifier : click_modifier)));
  XSETINT (inputEvent.x, point.x);
  XSETINT (inputEvent.y, point.y);
  XSETFRAME (inputEvent.frame_or_window, f);
  inputEvent.timestamp = [theEvent timestamp] * 1000;
  [self sendAction:action to:target];
}

- (void)swipeWithEvent:(NSEvent *)event
{
  [self scrollWheel:event];
}

- (void)magnifyWithEvent:(NSEvent *)event
{
  [self scrollWheel:event];
}

- (void)rotateWithEvent:(NSEvent *)event
{
  [self scrollWheel:event];
}

- (void)smartMagnifyWithEvent:(NSEvent *)event
{
  [self scrollWheel:event];
}

- (void)mouseMoved:(NSEvent *)theEvent
{
  struct frame *f = [self emacsFrame];
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  Mouse_HLInfo *hlinfo = &dpyinfo->mouse_highlight;
  NSPoint point = [self convertPoint:[theEvent locationInWindow] fromView:nil];

  if (![[self window] isKeyWindow])
    return;

  previous_help_echo_string = help_echo_string;
  help_echo_string = Qnil;

  if (hlinfo->mouse_face_hidden)
    {
      hlinfo->mouse_face_hidden = false;
      [frameController clearMouseFace:hlinfo];
    }

  /* Generate SELECT_WINDOW_EVENTs when needed.  */
  if (!NILP (Vmouse_autoselect_window)
      /* Don't switch if we're currently in the minibuffer.  This
	 tries to work around problems where the minibuffer gets
	 unselected unexpectedly, and where you then have to move your
	 mouse all the way down to the minibuffer to select it.  */
      && !MINI_WINDOW_P (XWINDOW (selected_window))
      /* With `focus-follows-mouse' non-nil create an event also when
	 the target window is on another frame.  */
      && (f == XFRAME (selected_frame)
	  || !NILP (focus_follows_mouse)))
    {
      static Lisp_Object last_mouse_window;
      Lisp_Object window = window_from_coordinates (f, point.x, point.y, 0,
						    false);

      /* A window will be autoselected only when it is not selected
	 now and the last mouse movement event was not in it.  The
	 remainder of the code is a bit vague wrt what a "window" is.
	 For immediate autoselection, the window is usually the entire
	 window but for GTK where the scroll bars don't count.  For
	 delayed autoselection the window is usually the window's text
	 area including the margins.  */
      if (WINDOWP (window)
	  && !EQ (window, last_mouse_window)
	  && !EQ (window, selected_window))
	{
	  EVENT_INIT (inputEvent);
	  inputEvent.arg = Qnil;
	  inputEvent.kind = SELECT_WINDOW_EVENT;
	  inputEvent.frame_or_window = window;
	  [self sendAction:action to:target];
	}
      /* Remember the last window where we saw the mouse.  */
      last_mouse_window = window;
    }

  if (![frameController noteMouseMovement:point])
    help_echo_string = previous_help_echo_string;
  else
    [frameController noteToolBarMouseMovement:theEvent];

  /* If the contents of the global variable help_echo_string has
     changed, generate a HELP_EVENT.  */
  if (!NILP (help_echo_string) || !NILP (previous_help_echo_string))
    {
      EVENT_INIT (inputEvent);
      inputEvent.arg = Qnil;
      inputEvent.kind = HELP_EVENT;
      XSETFRAME (inputEvent.frame_or_window, f);
      [self sendAction:action to:target];
    }
}

- (void)mouseDragged:(NSEvent *)theEvent
{
  [self mouseMoved:theEvent];
}

- (void)rightMouseDragged:(NSEvent *)theEvent
{
  [self mouseMoved:theEvent];
}

- (void)otherMouseDragged:(NSEvent *)theEvent
{
  [self mouseMoved:theEvent];
}

- (void)pressureChangeWithEvent:(NSEvent *)event
{
  NSInteger stage = [event stage];

  if (pressureEventStage != stage)
    {
      if (stage == 2
	  && [[NSUserDefaults standardUserDefaults]
	       boolForKey:@"com.apple.trackpad.forceClick"])
	[NSApp sendAction:@selector(quickLookPreviewItems:) to:nil from:nil];
      pressureEventStage = stage;
    }
}

- (void)cursorUpdate:(NSEvent *)event
{
  struct frame *f = [self emacsFrame];

  mac_cursor_set (f->output_data.mac->current_cursor);
}

- (void)keyDown:(NSEvent *)theEvent
{
  struct frame *f = [self emacsFrame];
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  Mouse_HLInfo *hlinfo = &dpyinfo->mouse_highlight;
  CGEventRef cgevent = [theEvent coreGraphicsEvent];
  CGEventFlags mapped_flags;

  [NSCursor setHiddenUntilMouseMoves:YES];

  /* If mouse-highlight is an integer, input clears out mouse
     highlighting.  */
  if (!hlinfo->mouse_face_hidden && INTEGERP (Vmouse_highlight)
      && !EQ (f->tool_bar_window, hlinfo->mouse_face_window))
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      [frameController clearMouseFace:hlinfo];
      hlinfo->mouse_face_hidden = true;
    }

  mapped_flags = mac_cgevent_to_input_event (cgevent, NULL);

  if (!(mapped_flags
	& ~(mac_pass_control_to_system ? kCGEventFlagMaskControl : 0))
      /* This is a workaround: some input methods on macOS 10.13 -
	 10.13.1 do not recognize Control+Space even if it is
	 unchecked in the system-wide short cut settings
	 (rdar://33842041).  */
      && !(1561 <= NSAppKitVersionNumber && NSAppKitVersionNumber < 1561.2
	   && (([theEvent modifierFlags]
		& NSEventModifierFlagDeviceIndependentFlagsMask)
	       == NSEventModifierFlagControl)
	   && [[theEvent charactersIgnoringModifiers] isEqualToString:@" "]))
    {
      keyEventsInterpreted = YES;
      rawKeyEvent = theEvent;
      rawKeyEventHasMappedFlags = (mapped_flags != 0);
      [self interpretKeyEvents:[NSArray arrayWithObject:theEvent]];
      rawKeyEvent = nil;
      rawKeyEventHasMappedFlags = NO;
      if (keyEventsInterpreted)
	return;
    }

  if ([theEvent type] == NSEventTypeKeyUp)
    return;

  EVENT_INIT (inputEvent);
  inputEvent.arg = Qnil;
  XSETFRAME (inputEvent.frame_or_window, f);
  mac_cgevent_to_input_event (cgevent, &inputEvent);
  if (inputEvent.kind != NO_EVENT)
    [self sendAction:action to:target];
}

- (void)insertText:(id)aString replacementRange:(NSRange)replacementRange
{
  struct frame *f = [self emacsFrame];
  NSString *charactersForASCIIKeystroke = nil;
  Lisp_Object arg = Qnil;

  /* While executing AppleScript, key events are directly delivered to
     the first responder's insertText:replacementRange: (not via
     keyDown:).  These are confusing, so we defer them.  */
  if (deferred_key_events)
    {
      EventRef event = GetCurrentEvent ();
      OSType class = GetEventClass (event);
      UInt32 kind = GetEventKind (event);

      if (class == kEventClassKeyboard
	  && (kind == kEventRawKeyDown || kind == kEventRawKeyRepeat))
	CFArrayAppendValue (deferred_key_events, event);

      return;
    }

  if (rawKeyEvent && ![self hasMarkedText])
    {
      unichar character;

      if (rawKeyEventHasMappedFlags
	  || [rawKeyEvent type] == NSEventTypeKeyUp
	  || ([aString isKindOfClass:[NSString class]]
	      && [aString isEqualToString:[rawKeyEvent characters]]
	      && [(NSString *)aString length] == 1
	      && ((character = [aString characterAtIndex:0]) < 0x80
		  /* NSEvent reserves the following Unicode characters
		     for function keys on the keyboard.  */
		  || (character >= 0xf700 && character <= 0xf74f))))
	{
	  /* Process it in keyDown:.  */
	  keyEventsInterpreted = NO;

	  return;
	}
    }

  [self setMarkedText:nil];

  EVENT_INIT (inputEvent);
  inputEvent.arg = Qnil;
  inputEvent.timestamp = [[NSApp currentEvent] timestamp] * 1000;
  XSETFRAME (inputEvent.frame_or_window, f);

  if ([aString isKindOfClass:[NSString class]])
    {
      NSUInteger i, length = [(NSString *)aString length];
      unichar character;

      for (i = 0; i < length; i++)
	{
	  character = [aString characterAtIndex:i];
	  if (!(character >= 0x20 && character <= 0x7f))
	    break;
	}

      if (i == length)
	{
	  /* ASCII only.  Store a text-input/insert-text event to
	     clear the marked text, and store ASCII keystroke events.  */
	  charactersForASCIIKeystroke = aString;
	  aString = @"";
	}
    }

  if (!NSEqualRanges (replacementRange, NSMakeRange (NSNotFound, 0)))
    arg = Fcons (Fcons (build_string ("replacementRange"),
			Fcons (build_string ("Lisp"),
			       Fcons (make_number (replacementRange.location),
				      make_number (replacementRange.length)))),
		 arg);

  inputEvent.kind = MAC_APPLE_EVENT;
  inputEvent.x = Qtext_input;
  inputEvent.y = Qinsert_text;
  inputEvent.arg =
    Fcons (build_string ("aevt"),
	   Fcons (Fcons (build_string ("----"),
			 Fcons (build_string ("Lisp"),
				[aString UTF16LispString])), arg));
  [self sendAction:action to:target];

  if (charactersForASCIIKeystroke)
    {
      NSUInteger i, length = [charactersForASCIIKeystroke length];

      inputEvent.kind = ASCII_KEYSTROKE_EVENT;
      for (i = 0; i < length; i++)
	{
	  inputEvent.code = [charactersForASCIIKeystroke characterAtIndex:i];
	  [self sendAction:action to:target];
	}
    }
  /* This is necessary for insertions by press-and-hold to be
     responsive.  */
  if (rawKeyEvent == nil)
    [NSApp postDummyEvent];
}

- (void)doCommandBySelector:(SEL)aSelector
{
  keyEventsInterpreted = NO;
}

- (void)setMarkedText:(id)aString selectedRange:(NSRange)selectedRange
     replacementRange:(NSRange)replacementRange
{
  struct frame *f = [self emacsFrame];
  Lisp_Object arg = Qnil;

  [self setMarkedText:aString];

  if (!NSEqualRanges (replacementRange, NSMakeRange (NSNotFound, 0)))
    arg = Fcons (Fcons (build_string ("replacementRange"),
			Fcons (build_string ("Lisp"),
			       Fcons (make_number (replacementRange.location),
				      make_number (replacementRange.length)))),
		 arg);

  arg = Fcons (Fcons (build_string ("selectedRange"),
		      Fcons (build_string ("Lisp"),
			     Fcons (make_number (selectedRange.location),
				    make_number (selectedRange.length)))),
	       arg);

  EVENT_INIT (inputEvent);
  inputEvent.kind = MAC_APPLE_EVENT;
  inputEvent.x = Qtext_input;
  inputEvent.y = Qset_marked_text;
  inputEvent.arg = Fcons (build_string ("aevt"),
			  Fcons (Fcons (build_string ("----"),
					Fcons (build_string ("Lisp"),
					       [aString UTF16LispString])),
				 arg));
  inputEvent.timestamp = [[NSApp currentEvent] timestamp] * 1000;
  XSETFRAME (inputEvent.frame_or_window, f);
  [self sendAction:action to:target];
  /* This is necessary for candidate selection from touch bar to be
     responsive.  */
  if (rawKeyEvent == nil)
    [NSApp postDummyEvent];
}

- (void)unmarkText
{
  if ([self hasMarkedText])
    [self insertText:markedText replacementRange:(NSMakeRange (NSNotFound, 0))];
}

- (BOOL)hasMarkedText
{
  /* The cast below is just for determining the return type.  The
     object `markedText' might be of class NSAttributedString.

     Strictly speaking, `markedText != nil &&' is not necessary
     because message to nil is defined to return 0 as NSUInteger, but
     we keep this as markedText is likely to be nil in most cases.  */
  return markedText != nil && [(NSString *)markedText length] != 0;
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)aRange
						actualRange:(NSRangePointer)actualRange
{
  NSRange markedRange = [self markedRange];
  NSAttributedString *result = nil;

  if ([self hasMarkedText]
      && NSEqualRanges (NSUnionRange (markedRange, aRange), markedRange))
    {
      NSRange range = NSMakeRange (aRange.location - markedRange.location,
				   aRange.length);

      if ([markedText isKindOfClass:[NSAttributedString class]])
	result = [markedText attributedSubstringFromRange:range];
      else
	{
	  NSString *string = [markedText substringWithRange:range];

	  result = MRC_AUTORELEASE ([[NSAttributedString alloc]
				      initWithString:string]);
	}

      if (actualRange)
	*actualRange = aRange;
    }
  else if ((poll_suppress_count != 0 || NILP (Vinhibit_quit))
	   /* Might be called during the select emulation.  */
	   && mac_try_buffer_and_glyph_matrix_access ())
    {
      struct frame *f = [self emacsFrame];
      struct window *w = XWINDOW (f->selected_window);
      struct buffer *b = XBUFFER (w->contents);

      /* Are we in a window whose display is up to date?
	 And verify the buffer's text has not changed.  */
      if (w->window_end_valid && !window_outdated (w))
	{
	  NSRange range;
	  CFStringRef string =
	    mac_ax_create_string_for_range (f, (CFRange *) &aRange,
					    (CFRange *) &range);

	  if (string)
	    {
	      NSMutableAttributedString *attributedString =
		MRC_AUTORELEASE ([[NSMutableAttributedString alloc]
				   initWithString:((__bridge NSString *)
						   string)]);
	      int last_face_id = DEFAULT_FACE_ID;
	      NSFont *lastFont =
		[NSFont fontWithFace:(FACE_FROM_ID (f, last_face_id))];
	      EMACS_INT start_charpos, end_charpos;
	      struct glyph_row *r1, *r2;

	      start_charpos = BUF_BEGV (b) + range.location;
	      end_charpos = start_charpos + range.length;
	      [attributedString beginEditing];
	      [attributedString addAttribute:NSFontAttributeName
				       value:lastFont
				       range:(NSMakeRange (0, range.length))];
	      rows_from_pos_range (w, start_charpos, end_charpos, Qnil,
				   &r1, &r2);
	      if (r1 == NULL || r2 == NULL)
		{
		  struct glyph_row *first, *last;

		  first = MATRIX_FIRST_TEXT_ROW (w->current_matrix);
		  last = MATRIX_ROW (w->current_matrix, w->window_end_vpos);
		  if (start_charpos <= MATRIX_ROW_END_CHARPOS (last)
		      && end_charpos > MATRIX_ROW_START_CHARPOS (first))
		    {
		      if (r1 == NULL)
			r1 = first;
		      if (r2 == NULL)
			r2 = last;
		    }
		}
	      if (r1 && r2)
		for (; r1 <= r2; r1++)
		  {
		    struct glyph *glyph;

		    for (glyph = r1->glyphs[TEXT_AREA];
			 glyph < r1->glyphs[TEXT_AREA] + r1->used[TEXT_AREA];
			 glyph++)
		      if (BUFFERP (glyph->object)
			  && glyph->charpos >= start_charpos
			  && glyph->charpos < end_charpos
			  && (glyph->type == CHAR_GLYPH
			      || glyph->type == COMPOSITE_GLYPH)
			  && !glyph->glyph_not_available_p)
			{
			  NSRange attributeRange =
			    (glyph->type == CHAR_GLYPH
			     ? NSMakeRange (glyph->charpos - start_charpos, 1)
			     : [[attributedString string]
				 rangeOfComposedCharacterSequenceAtIndex:(glyph->charpos - start_charpos)]);

			  if (last_face_id != glyph->face_id)
			    {
			      last_face_id = glyph->face_id;
			      lastFont =
				[NSFont fontWithFace:(FACE_FROM_ID
						      (f, last_face_id))];
			    }
			  [attributedString addAttribute:NSFontAttributeName
						   value:lastFont
						   range:attributeRange];
			}
		  }
	      [attributedString endEditing];
	      result = attributedString;

	      if (actualRange)
		*actualRange = range;

	      CFRelease (string);
	    }
	}
      mac_end_buffer_and_glyph_matrix_access ();
    }

  return result;
}

- (NSRange)markedRange
{
  NSUInteger location = NSNotFound;

  if (![self hasMarkedText])
    return NSMakeRange (NSNotFound, 0);

  if (OVERLAYP (Vmac_ts_active_input_overlay)
      && !NILP (Foverlay_get (Vmac_ts_active_input_overlay, Qbefore_string))
      && !NILP (Fmarker_buffer (OVERLAY_START (Vmac_ts_active_input_overlay))))
    location = (marker_position (OVERLAY_START (Vmac_ts_active_input_overlay))
		- BEGV);

  /* The cast below is just for determining the return type.  The
     object `markedText' might be of class NSAttributedString.  */
  return NSMakeRange (location, [(NSString *)markedText length]);
}

- (NSRange)selectedRange
{
  struct frame *f = [self emacsFrame];
  NSRange result;

  /* Might be called when deactivating TSM document inside [emacsView
     removeFromSuperview] in -[EmacsFrameController closeWindow] on
     macOS 10.13.  */
  if (!WINDOWP (f->root_window)
      /* Also might be called during the select emulation.  */
      || !mac_try_buffer_and_glyph_matrix_access ())
    return NSMakeRange (NSNotFound, 0);

  mac_ax_selected_text_range (f, (CFRange *) &result);
  mac_end_buffer_and_glyph_matrix_access ();

  return result;
}

static bool
mac_ts_active_input_string_in_echo_area_p (struct frame *f)
{
  Lisp_Object val = buffer_local_value (intern ("isearch-mode"),
					XWINDOW (f->selected_window)->contents);

  if (!(NILP (val) || EQ (val, Qunbound)))
    return true;

  if (OVERLAYP (Vmac_ts_active_input_overlay)
      && !NILP (Foverlay_get (Vmac_ts_active_input_overlay, Qbefore_string)))
    return false;

  for (Lisp_Object msg = current_message (); STRINGP (msg);
       msg = Fget_text_property (make_number (0), Qdisplay, msg))
    if (!NILP (Fget_text_property (make_number (0), Qmac_ts_active_input_string,
				   msg))
	|| !NILP (Fnext_single_property_change (make_number (0),
						Qmac_ts_active_input_string,
						msg, Qnil)))
      return true;

  return false;
}

- (NSRect)firstRectForCharacterRange:(NSRange)aRange
			 actualRange:(NSRangePointer)actualRange
{
  NSRect rect = NSZeroRect;
  struct frame *f = NULL;

  if (mac_try_buffer_and_glyph_matrix_access ())
    {
      struct window *w;
      NSRange markedRange = self.markedRange;

      if (aRange.location >= NSNotFound
	  || (self.hasMarkedText
	      && NSEqualRanges (NSUnionRange (markedRange, aRange),
				markedRange)))
	{
	  /* Probably asking the location of the marked text.
	     Strictly speaking, it is impossible to get the correct
	     one in general because events pending in the Lisp queue
	     may change some states about display.  In particular,
	     this method might be called before displaying the marked
	     text.

	     We return the current cursor position either in the
	     selected window or in the echo area (during isearch, for
	     example) as an approximate value.  */
	  struct glyph *glyph = NULL;

	  if (WINDOWP (echo_area_window)
	      && mac_ts_active_input_string_in_echo_area_p (self.emacsFrame))
	    {
	      w = XWINDOW (echo_area_window);
	      f = WINDOW_XFRAME (w);
	      glyph = get_phys_cursor_glyph (w);
	    }
	  if (glyph == NULL)
	    {
	      f = self.emacsFrame;
	      w = XWINDOW (f->selected_window);
	      glyph = get_phys_cursor_glyph (w);
	    }
	  if (glyph)
	    {
	      int x, y, h;
	      struct glyph_row *row = MATRIX_ROW (w->current_matrix,
						  w->phys_cursor.vpos);

	      get_phys_cursor_geometry (w, row, glyph, &x, &y, &h);

	      rect = NSMakeRect (x, y, w->phys_cursor_width, h);
	      if (actualRange)
		*actualRange = aRange;
	    }
	}
      else
	{
	  f = self.emacsFrame;
	  w = XWINDOW (f->selected_window);

	  /* Are we in a window whose display is up to date?
	     And verify the buffer's text has not changed.  */
	  if (w->window_end_valid && !window_outdated (w))
	    rect =
	      NSRectFromCGRect (mac_get_first_rect_for_range (w, ((CFRange *)
								  &aRange),
							      ((CFRange *)
							       actualRange)));
	}
      mac_end_buffer_and_glyph_matrix_access ();
    }

  if (actualRange && NSEqualRects (rect, NSZeroRect))
    *actualRange = NSMakeRange (NSNotFound, 0);

  if (f)
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      rect = [frameController convertEmacsViewRectToScreen:rect];
    }

  return rect;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)thePoint
{
  NSUInteger result = NSNotFound;
  NSPoint point;
  Lisp_Object window;
  enum window_part part;
  struct frame *f = [self emacsFrame];
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  struct window *w;
  struct buffer *b;
  int x, y;

  point = [frameController convertEmacsViewPointFromScreen:thePoint];
  x = point.x;
  y = point.y;
  window = window_from_coordinates (f, x, y, &part, true);
  if (!WINDOWP (window) || !EQ (window, f->selected_window))
    return result;

  /* Convert to window-relative pixel coordinates.  */
  w = XWINDOW (window);
  frame_to_window_pixel_xy (w, &x, &y);

  /* Are we in a window whose display is up to date?
     And verify the buffer's text has not changed.  */
  b = XBUFFER (w->contents);
  if (part == ON_TEXT && w->window_end_valid && !window_outdated (w))
    {
      int hpos, vpos, area;
      struct glyph *glyph;

      /* Find the glyph under X/Y.  */
      glyph = x_y_to_hpos_vpos (w, x, y, &hpos, &vpos, 0, 0, &area);

      if (glyph != NULL && area == TEXT_AREA
	  && BUFFERP (glyph->object) && glyph->charpos <= BUF_Z (b))
	result = glyph->charpos - BUF_BEGV (b);
    }

  return result;
}

- (NSArrayOf (NSString *) *)validAttributesForMarkedText
{
  return nil;
}

- (NSString *)string
{
  struct frame *f = [self emacsFrame];
  CFRange range;
  CFStringRef string;

  /* Don't try to get buffer contents as the gap might be being
     altered. */
  if ((poll_suppress_count == 0 && !NILP (Vinhibit_quit))
      /* Might be called during the select emulation.  */
      || !mac_try_buffer_and_glyph_matrix_access ())
    return nil;

  range = CFRangeMake (0, mac_ax_number_of_characters (f));
  string = mac_ax_create_string_for_range (f, &range, NULL);
  mac_end_buffer_and_glyph_matrix_access ();

  return CF_BRIDGING_RELEASE (string);
}

- (void)synchronizeChildFrameOrigins
{
  struct frame *f = self.emacsFrame;
  Lisp_Object frame, tail;

  FOR_EACH_FRAME (tail, frame)
    if (FRAME_PARENT_FRAME (XFRAME (frame)) == f)
      {
	struct frame *c = XFRAME (frame);

	mac_move_frame_window_structure_1 (c, c->left_pos, c->top_pos);
      }
}

- (void)viewDidEndLiveResize
{
  struct frame *f = [self emacsFrame];
  NSRect frameRect = [self frame];

  [super viewDidEndLiveResize];
  [self synchronizeChildFrameOrigins];
  [self synchronizeBacking];
  mac_handle_size_change (f, NSWidth (frameRect), NSHeight (frameRect));
  /* Exit from mac_select so as to react to the frame size change,
     especially in a full screen tile on OS X 10.11.  */
  [NSApp postDummyEvent];
}

- (void)viewFrameDidChange:(NSNotification *)notification
{
  if (![self inLiveResize]
      && ([self autoresizingMask] & (NSViewWidthSizable | NSViewHeightSizable)))
    {
      struct frame *f = [self emacsFrame];
      NSRect frameRect = [self frame];

      [self synchronizeChildFrameOrigins];
      [super viewFrameDidChange:notification];
      mac_handle_size_change (f, NSWidth (frameRect), NSHeight (frameRect));
      /* Exit from mac_select so as to react to the frame size
	 change.  */
      [NSApp postDummyEvent];
    }
}

- (void)viewDidHide
{
  struct frame *f = [self emacsFrame];
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  [frameController updateEmacsViewIsHiddenOrHasHiddenAncestor];

  mac_handle_visibility_change (f);
}

- (void)viewDidUnhide
{
  [self viewDidHide];
}

- (NSTouchBar *)makeTouchBar
{
  NSTouchBar *mainBar = [[NS_TOUCH_BAR alloc] init];

  mainBar.delegate = self;
  mainBar.defaultItemIdentifiers =
    [NSArray arrayWithObjects:NS_TOUCH_BAR_ITEM_IDENTIFIER_CHARACTER_PICKER,
	     NS_TOUCH_BAR_ITEM_IDENTIFIER_CANDIDATE_LIST, nil];

  return MRC_AUTORELEASE (mainBar);
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar
       makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier
{
  NSTouchBarItem *result = nil;

  if ([identifier isEqualToString:NS_TOUCH_BAR_ITEM_IDENTIFIER_CANDIDATE_LIST])
    {
      if (candidateListTouchBarItem == nil)
	candidateListTouchBarItem =
	  [[NS_CANDIDATE_LIST_TOUCH_BAR_ITEM alloc]
	    initWithIdentifier:NS_TOUCH_BAR_ITEM_IDENTIFIER_CANDIDATE_LIST];
      result = candidateListTouchBarItem;
    }

  return result;
}

- (NSCandidateListTouchBarItem *)candidateListTouchBarItem
{
  return candidateListTouchBarItem;
}

@end				// EmacsMainView

#define FRAME_CG_CONTEXT(f)	((f)->output_data.mac->cg_context)

/* Emacs frame containing the globally focused NSView.  */
static struct frame *global_focus_view_frame;
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
static CGRect global_focus_view_accumulated_clip_rect;
#endif
/* Whether view's core animation layer contents are out of sync with
   the backing bitmap and need to be updated.  */
static bool global_focus_view_modified_p;
/* -[EmacsView drawRect:] might be called during update_frame.  */
static struct frame *saved_focus_view_frame;
static CGContextRef saved_focus_view_context;
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
static CGRect saved_focus_view_accumulated_clip_rect;
#endif
static bool saved_focus_view_modified_p;
#if DRAWING_USE_GCD
static dispatch_queue_t global_focus_drawing_queue;
#endif

static void
set_global_focus_view_frame (struct frame *f)
{
  saved_focus_view_frame = global_focus_view_frame;
  if (f != global_focus_view_frame)
    {
      if (saved_focus_view_frame)
	{
	  saved_focus_view_context = FRAME_CG_CONTEXT (saved_focus_view_frame);
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
	  saved_focus_view_accumulated_clip_rect =
	    global_focus_view_accumulated_clip_rect;
#endif
	  saved_focus_view_modified_p = global_focus_view_modified_p;
	}
      global_focus_view_frame = f;
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
      FRAME_CG_CONTEXT (f) = [[NSGraphicsContext currentContext] CGContext];
#else
      FRAME_CG_CONTEXT (f) = [[NSGraphicsContext currentContext] graphicsPort];
      global_focus_view_accumulated_clip_rect = CGRectNull;
#endif
      global_focus_view_modified_p = false;
    }
#if DRAWING_USE_GCD
  if (mac_drawing_use_gcd)
    {
      if (global_focus_drawing_queue == NULL)
	global_focus_drawing_queue =
	  dispatch_queue_create ("org.gnu.Emacs.drawing", NULL);
    }
  else
    {
      if (global_focus_drawing_queue)
	{
#if !OS_OBJECT_USE_OBJC_RETAIN_RELEASE
	  dispatch_release (global_focus_drawing_queue);
#endif
	  global_focus_drawing_queue = NULL;
	}
    }
#endif
}

static void
mac_draw_queue_sync (void)
{
#if DRAWING_USE_GCD
  if (global_focus_drawing_queue)
    dispatch_sync (global_focus_drawing_queue, ^{});
#endif
}

static void
mac_draw_queue_dispatch_async (void (^block) (void))
{
#if DRAWING_USE_GCD
  if (global_focus_drawing_queue)
    dispatch_async (global_focus_drawing_queue, block);
  else
#endif
    block ();
}

static CGRect
unset_global_focus_view_frame (void)
{
  CGRect result = CGRectNull;

  mac_draw_queue_sync ();

  if (global_focus_view_frame != saved_focus_view_frame)
    {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
      result = global_focus_view_accumulated_clip_rect;
#endif
      FRAME_CG_CONTEXT (global_focus_view_frame) = NULL;
      if (FRAME_MAC_DOUBLE_BUFFERED_P (global_focus_view_frame)
	  && global_focus_view_modified_p)
	{
	  EmacsFrameController *frameController =
	    FRAME_CONTROLLER (global_focus_view_frame);

	  [frameController setEmacsViewNeedsDisplay:YES];
	}
      global_focus_view_frame = saved_focus_view_frame;
      if (global_focus_view_frame)
	{
	  FRAME_CG_CONTEXT (global_focus_view_frame) = saved_focus_view_context;
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
	  global_focus_view_accumulated_clip_rect =
	    saved_focus_view_accumulated_clip_rect;
#endif
	  global_focus_view_modified_p = saved_focus_view_modified_p;
	}
    }
  saved_focus_view_frame = NULL;

  return result;
}

static void
mac_accumulate_global_focus_view_clip_rect (const CGRect *clip_rects,
					    CFIndex n_clip_rects)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
  if (n_clip_rects)
    {
      CFIndex i;

      for (i = 0; i < n_clip_rects; i++)
	global_focus_view_accumulated_clip_rect =
	  CGRectUnion (global_focus_view_accumulated_clip_rect,
		       clip_rects[i]);
    }
  else
    global_focus_view_accumulated_clip_rect = CGRectInfinite;
#endif
}

#if DRAWING_USE_GCD
static
#endif
CGContextRef
mac_begin_cg_clip (struct frame *f, GC gc)
{
  CGContextRef context;
  const CGRect *clip_rects;
  CFIndex n_clip_rects;

  if (gc->clip_rects_data)
    {
      clip_rects = (const CGRect *) CFDataGetBytePtr (gc->clip_rects_data);
      n_clip_rects = CFDataGetLength (gc->clip_rects_data) / sizeof (CGRect);
    }
  else
    {
      clip_rects = NULL;       /* Just to avoid uninitialized use.  */
      n_clip_rects = 0;
    }

  if (global_focus_view_frame != f)
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      mac_within_gui (^{
	  [frameController lockFocusOnEmacsView];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
	  FRAME_CG_CONTEXT (f) = [[NSGraphicsContext currentContext] CGContext];
#else
	  FRAME_CG_CONTEXT (f) = [[NSGraphicsContext currentContext]
				   graphicsPort];
#endif
	});
    }
  else
    mac_accumulate_global_focus_view_clip_rect (clip_rects, n_clip_rects);

  context = FRAME_CG_CONTEXT (f);
  CGContextSaveGState (context);
  if (n_clip_rects)
    CGContextClipToRects (context, clip_rects, n_clip_rects);

  return context;
}

#if DRAWING_USE_GCD
static
#endif
void
mac_end_cg_clip (struct frame *f)
{
  CGContextRestoreGState (FRAME_CG_CONTEXT (f));
  if (global_focus_view_frame != f)
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      mac_within_gui (^{
	  [frameController unlockFocusOnEmacsView];
	  FRAME_CG_CONTEXT (f) = NULL;
	  if (FRAME_MAC_DOUBLE_BUFFERED_P (f))
	    [frameController setEmacsViewNeedsDisplay:YES];
	});
    }
  else
    global_focus_view_modified_p = true;
}

#if DRAWING_USE_GCD
void
mac_draw_to_frame (struct frame *f, GC gc, void (^block) (CGContextRef, GC))
{
  CGContextRef context;

  if (global_focus_view_frame != f || global_focus_drawing_queue == NULL)
    {
      context = mac_begin_cg_clip (f, gc);
      block (context, gc);
      mac_end_cg_clip (f);
    }
  else
    {
      const CGRect *clip_rects;
      CFIndex n_clip_rects;

      if (gc->clip_rects_data)
	{
	  clip_rects = (const CGRect *) CFDataGetBytePtr (gc->clip_rects_data);
	  n_clip_rects = (CFDataGetLength (gc->clip_rects_data)
			  / sizeof (CGRect));
	}
      else
	{
	  clip_rects = NULL;   /* Just to avoid uninitialized use.  */
	  n_clip_rects = 0;
	}

      context = FRAME_CG_CONTEXT (f);
      gc = mac_duplicate_gc (gc);

      dispatch_async (global_focus_drawing_queue, ^{
	  CGContextSaveGState (context);
	  if (n_clip_rects)
	    CGContextClipToRects (context, clip_rects, n_clip_rects);
	  block (context, gc);
	  CGContextRestoreGState (context);
	  mac_free_gc (gc);
	});

      mac_accumulate_global_focus_view_clip_rect (clip_rects, n_clip_rects);
      global_focus_view_modified_p = true;
    }
}
#endif

/* Mac replacement for XCopyArea: used only for scrolling.  */

void
mac_scroll_area (struct frame *f, GC gc, int src_x, int src_y,
		 int width, int height, int dest_x, int dest_y)
{
  eassert (global_focus_view_frame);
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  NSRect rect = NSMakeRect (src_x, src_y, width, height);
  NSSize offset = NSMakeSize (dest_x - src_x, dest_y - src_y);

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  if (!FRAME_MAC_DOUBLE_BUFFERED_P (f))
    {
      mac_draw_queue_sync ();
      mac_within_gui (^{[frameController scrollEmacsViewRect:rect by:offset];});

      return;
    }
#endif
  mac_draw_queue_dispatch_async (^{
      [frameController scrollEmacsViewRect:rect by:offset];
    });
  global_focus_view_modified_p = true;
}

@implementation EmacsOverlayView

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
static CGImageRef
create_resize_indicator_image (void)
{
  NSRect contentRect = NSMakeRect (0, 0, 64, 64);
  NSRect resizeIndicatorRect =
    NSMakeRect (NSWidth (contentRect) - RESIZE_CONTROL_WIDTH,
		0, RESIZE_CONTROL_WIDTH, RESIZE_CONTROL_HEIGHT);
  NSWindow *window =
    [[NSWindow alloc] initWithContentRect:contentRect
				styleMask:(NSWindowStyleMaskTitled
					   | NSWindowStyleMaskResizable)
				  backing:NSBackingStoreBuffered
				    defer:NO];
  NSView *frameView = [[window contentView] superview];
  NSBitmapImageRep *bitmap;
  CGImageRef image;

  [window setOpaque:NO];
  [window setBackgroundColor:[NSColor clearColor]];

  [frameView display];
  [frameView lockFocus];
  bitmap =
    [[NSBitmapImageRep alloc] initWithFocusedViewRect:resizeIndicatorRect];
  [frameView unlockFocus];

  image = CGImageRetain ([bitmap CGImage]);
  MRC_RELEASE (bitmap);

  MRC_RELEASE (window);

  return image;
}
#endif

- (void)setHighlighted:(BOOL)flag
{
  CALayer *layer = [self layer];

  if (flag)
    {
      NSAppearance *oldAppearance;
      CGColorRef borderColor;

      if (has_visual_effect_view_p ())
	{
	  oldAppearance = [NS_APPEARANCE currentAppearance];
	  [NS_APPEARANCE setCurrentAppearance:self.effectiveAppearance];
	}
      borderColor = NSColor.selectedControlColor.copyCGColor;
      if (has_visual_effect_view_p ())
	[NS_APPEARANCE setCurrentAppearance:oldAppearance];

      [layer setValue:((id) kCFBooleanTrue) forKey:@"showingBorder"];

      [CATransaction setDisableActions:YES];
      layer.borderColor = borderColor;
      CFRelease (borderColor);
      [CATransaction commit];

      layer.borderWidth = 3.0;
    }
  else
    {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
      if ([NSAnimationContext
	    respondsToSelector:@selector(runAnimationGroup:completionHandler:)])
#endif
	[NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
	    layer.borderWidth = 0;
	  } completionHandler:^{
	    [layer setValue:((id) kCFBooleanFalse) forKey:@"showingBorder"];
	  }];
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
      else
	/* We could use -[CATransaction setCompletionBlock:], but
	   overlayview is always shown on Mac OS X 10.6 for the resize
	   indicator, so we don't have to care about resetting the
	   value for "showingBorder".  */
	layer.borderWidth = 0;
#endif
    }
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
- (void)setShowsResizeIndicator:(BOOL)flag
{
  CALayer *layer = [self layer];

  if (flag)
    {
      static CGImageRef resizeIndicatorImage;

      if (resizeIndicatorImage == NULL)
	resizeIndicatorImage = create_resize_indicator_image ();

      layer.contents = (__bridge id) resizeIndicatorImage;
      layer.contentsGravity = kCAGravityBottomRight;
    }
  else
    layer.contents = nil;
}
#endif

- (NSView *)hitTest:(NSPoint)point
{
  return nil;
}

@end				// EmacsOverlayView


/************************************************************************
				Color
 ************************************************************************/

Lisp_Object
mac_color_lookup (const char *color_name)
{
  Lisp_Object result = Qnil;
  char *colon;
  NSColorListName listName = @"System";
  NSColor *color = nil, *colorInSRGB;
  NSAppearance *oldAppearance, *appearance;

  /* color_name is of the form either "mac:COLOR_LIST_NAME:COLOR_NAME"
     or "mac:COLOR_NAME".  The latter form is for system colors.  */
  if (strncasecmp (color_name, "mac:", 4) != 0)
    return Qnil;

  color_name += sizeof ("mac:") - 1;
  colon = strchr (color_name, ':');
  if (colon)
    {
      listName = MRC_AUTORELEASE ([[NSString alloc]
				    initWithBytes:color_name
					   length:(colon - color_name)
					 encoding:NSUTF8StringEncoding]);
      color_name = colon + 1;
    }
  if (listName)
    {
      NSColorName colorName = [NSString stringWithUTF8String:color_name];
      NSColorList *colorList = [NSColorList colorListNamed:listName];

      if (!colorList)
	for (NSColorList *list in NSColorList.availableColorLists)
	  if ([list.name localizedCaseInsensitiveCompare:listName]
	      == NSOrderedSame)
	    {
	      colorList = list;
	      break;
	    }

      color = [colorList colorWithKey:colorName];
      if (!color && colorList)
	for (NSColorName key in colorList.allKeys)
	  if ([key localizedCaseInsensitiveCompare:colorName] == NSOrderedSame)
	    {
	      color = [colorList colorWithKey:key];
	      break;
	    }
    }

  if (!color)
    return Qnil;

  if (has_visual_effect_view_p ())
    {
      oldAppearance = [NS_APPEARANCE currentAppearance];
      appearance = ([NSApp respondsToSelector:@selector(effectiveAppearance)]
		    ? [NSApp effectiveAppearance]
		    : [NS_APPEARANCE appearanceNamed:NS_APPEARANCE_NAME_AQUA]);
      [NS_APPEARANCE setCurrentAppearance:appearance];
    }
  colorInSRGB = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (colorInSRGB)
    {
      CGFloat components[4];

      [colorInSRGB getComponents:components];
      result = make_number (RGB_TO_ULONG ((int) (components[0] * 255 + .5),
					  (int) (components[1] * 255 + .5),
					  (int) (components[2] * 255 + .5)));
    }
  if (has_visual_effect_view_p ())
    [NS_APPEARANCE setCurrentAppearance:oldAppearance];

  return result;
}

Lisp_Object
mac_color_list_alist (void)
{
  Lisp_Object result = Qnil;

  for (NSColorList *colorList in NSColorList.availableColorLists)
    {
      Lisp_Object color_list = Qnil;

      for (NSColorName key in colorList.allKeys)
	color_list = Fcons (key.lispString, color_list);

      result = Fcons (Fcons (colorList.name.lispString, Fnreverse (color_list)),
		      result);
    }

  return Fnreverse (result);
}


/************************************************************************
			Multi-monitor support
 ************************************************************************/

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1090 && MAC_OS_X_VERSION_MIN_REQUIRED < 101500
static NSArrayOf (NSDictionary *) *
mac_display_get_info_dictionaries (IOOptionBits options)
{
  NSMutableArrayOf (NSDictionary *) *result =
    [NSMutableArray arrayWithCapacity:0];
  CFDictionaryRef matching = IOServiceMatching ("IODisplayConnect");

  if (matching)
    {
      io_iterator_t existing;
      kern_return_t kr = IOServiceGetMatchingServices (kIOMasterPortDefault,
						       matching, &existing);

      if (kr == KERN_SUCCESS)
	{
	  io_object_t service;

	  while ((service = IOIteratorNext (existing)) != 0)
	    {
	      CFDictionaryRef dictionary =
		IODisplayCreateInfoDictionary (service, options);

	      if (dictionary)
		[result addObject:(CF_BRIDGING_RELEASE (dictionary))];
	    }
	  IOObjectRelease (existing);
	}
    }

  return result;
}

static CFDictionaryRef
mac_display_copy_info_dictionary_for_cgdisplay (CGDirectDisplayID displayID,
						NSArrayOf (NSDictionary *)
						*infoDictionaries)
{
  CFDictionaryRef __block result = NULL;
  NSMutableDictionaryOf (NSString *, NSNumber *) *info =
    [NSMutableDictionary dictionaryWithCapacity:3];
  uint32_t val;

  val = CGDisplayVendorNumber (displayID);
  if (val != kDisplayVendorIDUnknown && val != 0xFFFFFFFF)
    /* According to IODisplayLib.c in IOKitUser, a dictionary created
       with IODisplayCreateInfoDictionary maps the kDisplayVendorID
       (or kDisplayProductID, kDisplaySerialNumber) key to a SInt32
       value, whereas the return type of CGDisplayVendorNumber (or
       CGDisplayModelNumber, CGDisplaySerialNumber) is uint32_t.  */
    [info setObject:[NSNumber numberWithInt:val] forKey:@kDisplayVendorID];

  val = CGDisplayModelNumber (displayID);
  if (val != kDisplayProductIDGeneric && val != 0xFFFFFFFF)
    [info setObject:[NSNumber numberWithInt:val] forKey:@kDisplayProductID];

  val = CGDisplaySerialNumber (displayID);
  if (val != 0x00000000 && val != 0xFFFFFFFF)
    [info setObject:[NSNumber numberWithInt:val] forKey:@kDisplaySerialNumber];

  [infoDictionaries enumerateObjectsUsingBlock:
		      ^(NSDictionary *dictionary, NSUInteger idx, BOOL *stop) {
      if (IODisplayMatchDictionaries ((__bridge CFDictionaryRef) dictionary,
				      (__bridge CFDictionaryRef) info,
				      kNilOptions))
	{
	  result = CF_BRIDGING_RETAIN (dictionary);
	  *stop = YES;
	}
    }];

  return result;
}
#endif

Lisp_Object
mac_display_monitor_attributes_list (struct mac_display_info *dpyinfo)
{
  Lisp_Object attributes_list = Qnil, rest, frame;
  NSRect baseScreenFrame = mac_get_base_screen_frame ();
  CGFloat baseScreenFrameMinX = NSMinX (baseScreenFrame);
  CGFloat baseScreenFrameMaxY = NSMaxY (baseScreenFrame);
  NSArrayOf (NSScreen *) *screens = [NSScreen screens];
  NSUInteger i, count = [screens count];
  Lisp_Object monitor_frames = Fmake_vector (make_number (count), Qnil);
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1090 && MAC_OS_X_VERSION_MIN_REQUIRED < 101500
  NSArrayOf (NSDictionary *) *infoDictionaries =
    mac_display_get_info_dictionaries (kIODisplayOnlyPreferredName);
#endif

  FOR_EACH_FRAME (rest, frame)
    {
      struct frame *f = XFRAME (frame);

      if (FRAME_MAC_P (f) && FRAME_DISPLAY_INFO (f) == dpyinfo
	  && !EQ (frame, tip_frame))
	{
	  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
	  NSScreen *screen = [window screen];

	  if (screen == nil)
	    screen = [NSScreen closestScreenForRect:[window frame]];
	  i = [screens indexOfObject:screen];
	  if (i != NSNotFound)
	    ASET (monitor_frames, i, Fcons (frame, AREF (monitor_frames, i)));
	}
    }

  i = count;
  while (i-- > 0)
    {
      Lisp_Object geometry, workarea, attributes = Qnil;
      NSScreen *screen = [screens objectAtIndex:i];
      CGFloat backingScaleFactor;
      CGDirectDisplayID displayID;
      CGSize size;
      NSRect rect;

      if ([screen respondsToSelector:@selector(backingScaleFactor)])
	backingScaleFactor = [screen backingScaleFactor];
      else
	backingScaleFactor = 1.0;
      attributes = Fcons (Fcons (Qbacking_scale_factor,
				 make_number (backingScaleFactor)),
			  attributes);

      displayID = (CGDirectDisplayID) [[[screen deviceDescription]
					 objectForKey:@"NSScreenNumber"]
					unsignedIntValue];
#if HAVE_MAC_METAL
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
      if (CGDirectDisplayCopyCurrentMetalDevice != NULL)
#endif
	{
	  id <MTLDevice> device =
	    CGDirectDisplayCopyCurrentMetalDevice (displayID);

	  attributes = Fcons (Fcons (Qmetal_device_name,
				     device ? device.name.lispString : Qnil),
			      attributes);
	  MRC_RELEASE (device);
	}
#endif

#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101500
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101500
      if ([screen respondsToSelector:@selector(localizedName)])
#endif
	attributes = Fcons (Fcons (Qname, screen.localizedName.lispString),
			    attributes);
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101500
      else
#endif
#endif
#if MAC_OS_X_VERSION_MAX_ALLOWED < 101500 || MAC_OS_X_VERSION_MIN_REQUIRED < 101500
	{
	  CFDictionaryRef displayInfo;
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1090
	  displayInfo =
	    mac_display_copy_info_dictionary_for_cgdisplay (displayID,
							    infoDictionaries);
#else
	  displayInfo =
	    IODisplayCreateInfoDictionary (CGDisplayIOServicePort (displayID),
					   kIODisplayOnlyPreferredName);
#endif
	  if (displayInfo)
	    {
	      CFDictionaryRef localizedNames =
		CFDictionaryGetValue (displayInfo, CFSTR (kDisplayProductName));

	      if (localizedNames)
		{
		  NSDictionary *names =
		    (__bridge NSDictionary *) localizedNames;
		  NSString *name = names.objectEnumerator.nextObject;

		  if (name)
		    attributes = Fcons (Fcons (Qname, name.lispString),
					attributes);
		}
	      CFRelease (displayInfo);
	    }
	}
#endif

      attributes = Fcons (Fcons (Qframes, AREF (monitor_frames, i)),
			  attributes);

      size = CGDisplayScreenSize (displayID);
      attributes = Fcons (Fcons (Qmm_size,
				 list2i (size.width + 0.5f,
					 size.height + 0.5f)),
			  attributes);

      rect = [screen visibleFrame];
      workarea = list4i (NSMinX (rect) - baseScreenFrameMinX,
			 - NSMaxY (rect) + baseScreenFrameMaxY,
			 NSWidth (rect), NSHeight (rect));
      attributes = Fcons (Fcons (Qworkarea, workarea), attributes);

      rect = [screen frame];
      geometry = list4i (NSMinX (rect) - baseScreenFrameMinX,
			 - NSMaxY (rect) + baseScreenFrameMaxY,
			 NSWidth (rect), NSHeight (rect));
      attributes = Fcons (Fcons (Qgeometry, geometry), attributes);

      attributes_list = Fcons (attributes, attributes_list);
    }

  return attributes_list;
}


/************************************************************************
			     Scroll bars
 ************************************************************************/

@implementation NonmodalScroller

static NSTimeInterval NonmodalScrollerButtonDelay = 0.5;
static NSTimeInterval NonmodalScrollerButtonPeriod = 1.0 / 20;
static BOOL NonmodalScrollerPagingBehavior;

+ (void)initialize
{
  if (self == [NonmodalScroller class])
    {
      [self updateBehavioralParameters];
      [[NSDistributedNotificationCenter defaultCenter]
	addObserver:self
	   selector:@selector(pagingBehaviorDidChange:)
	       name:@"AppleNoRedisplayAppearancePreferenceChanged"
	     object:nil
	suspensionBehavior:NSNotificationSuspensionBehaviorCoalesce];
    }
}

+ (void)updateBehavioralParameters
{
  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];

  [userDefaults synchronize];
  NonmodalScrollerButtonDelay =
    [userDefaults doubleForKey:@"NSScrollerButtonDelay"];
  NonmodalScrollerButtonPeriod =
    [userDefaults doubleForKey:@"NSScrollerButtonPeriod"];
  NonmodalScrollerPagingBehavior =
    [userDefaults boolForKey:@"AppleScrollerPagingBehavior"];
}

+ (void)pagingBehaviorDidChange:(NSNotification *)notification
{
  [self updateBehavioralParameters];
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
  self = [super initWithFrame:frameRect];
  if (self == nil)
    return nil;

  isHorizontal = !(NSHeight (frameRect) >= NSWidth (frameRect));

  return self;
}

#if !USE_ARC
- (void)dealloc
{
  [timer release];
  [super dealloc];
}
#endif

/* Whether mouse drag on knob updates the float value.  Subclass may
   override the definition.  */

- (BOOL)dragUpdatesFloatValue
{
  return YES;
}

/* First delay in seconds for mouse tracking.  Subclass may override
   the definition.  */

- (NSTimeInterval)buttonDelay
{
  return NonmodalScrollerButtonDelay;
}

/* Continuous delay in seconds for mouse tracking.  Subclass may
   override the definition.  */

- (NSTimeInterval)buttonPeriod
{
  return NonmodalScrollerButtonPeriod;
}

/* Whether a click in the knob slot above/below the knob jumps to the
   spot that's clicked.  Subclass may override the definition.  */

- (BOOL)pagingBehavior
{
  return NonmodalScrollerPagingBehavior;
}

- (NSScrollerPart)hitPart
{
  return hitPart;
}

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
- (void)highlight:(BOOL)flag
{
  if (hitPart == NSScrollerIncrementLine
      || hitPart == NSScrollerDecrementLine)
    {
      hilightsHitPart = flag;
      [self setNeedsDisplay:YES];
    }
  else
    hilightsHitPart = NO;
}

/* This method is not documented but Cocoa seems to use this for
   drawing highlighted arrow.  */

- (void)drawArrow:(NSUInteger)position highlightPart:(NSInteger)part
{
  if (hilightsHitPart)
    part = (hitPart == NSScrollerIncrementLine ? 0 : 1);
  else
    part = -1;

  [super drawArrow:position highlightPart:part];
}
#endif

/* Post a dummy mouse dragged event to the main event queue to notify
   timer has expired.  */

- (void)postMouseDraggedEvent:(NSTimer *)theTimer
{
  NSEvent *event =
    [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
		       location:[[self window]
				  mouseLocationOutsideOfEventStream]
		  modifierFlags:[NSEvent modifierFlags] timestamp:0
		   windowNumber:[[self window] windowNumber]
			context:[NSGraphicsContext currentContext]
		    eventNumber:0 clickCount:1 pressure:0];

  [NSApp postEvent:event atStart:NO];
  MRC_RELEASE (timer);
  timer = nil;
}

/* Invalidate timer if any, and set new timer's interval to
   SECONDS.  */

- (void)rescheduleTimer:(NSTimeInterval)seconds
{
  [timer invalidate];

  if (seconds >= 0)
    {
      MRC_RELEASE (timer);
      timer = MRC_RETAIN ([NSTimer scheduledTimerWithTimeInterval:seconds
							   target:self
							 selector:@selector(postMouseDraggedEvent:)
							 userInfo:nil
							  repeats:NO]);
    }
}

- (void)mouseDown:(NSEvent *)theEvent
{
  BOOL jumpsToClickedSpot;

  hitPart = [self testPart:[theEvent locationInWindow]];

  if (hitPart == NSScrollerNoPart)
    return;

  if (hitPart != NSScrollerIncrementPage && hitPart != NSScrollerDecrementPage)
    jumpsToClickedSpot = NO;
  else
    {
      jumpsToClickedSpot = [self pagingBehavior];
      if ([theEvent modifierFlags] & NSEventModifierFlagOption)
	jumpsToClickedSpot = !jumpsToClickedSpot;
    }

  if (hitPart != NSScrollerKnob && !jumpsToClickedSpot)
    {
      [self rescheduleTimer:[self buttonDelay]];
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
      [self highlight:YES];
#endif
      [self sendAction:[self action] to:[self target]];
    }
  else
    {
      NSPoint point = [self convertPoint:[theEvent locationInWindow]
			    fromView:nil];
      NSRect bounds, knobRect;

      bounds = [self bounds];
      knobRect = [self rectForPart:NSScrollerKnob];

      if (jumpsToClickedSpot)
	{
	  NSRect knobSlotRect = [self rectForPart:NSScrollerKnobSlot];

	  if (!isHorizontal)
	    {
	      knobRect.origin.y = point.y - round (NSHeight (knobRect) / 2);
	      if (NSMinY (knobRect) < NSMinY (knobSlotRect))
		knobRect.origin.y = knobSlotRect.origin.y;
#if 0		      /* This might be better if no overscrolling.  */
	      else if (NSMaxY (knobRect) > NSMaxY (knobSlotRect))
		knobRect.origin.y = NSMaxY (knobSlotRect) - NSHeight (knobRect);
#endif
	    }
	  else
	    {
	      knobRect.origin.x = point.x - round (NSWidth (knobRect) / 2);
	      if (NSMinX (knobRect) < NSMinX (knobSlotRect))
		knobRect.origin.x = knobSlotRect.origin.x;
#if 0
	      else if (NSMaxX (knobRect) > NSMaxX (knobSlotRect))
		knobRect.origin.x = NSMaxX (knobSlotRect) - NSWidth (knobRect);
#endif
	    }
	  hitPart = NSScrollerKnob;
	}

      if (!isHorizontal)
	knobGrabOffset = - (point.y - NSMinY (knobRect)) - 1;
      else
	knobGrabOffset = - (point.x - NSMinX (knobRect)) - 1;

      if (jumpsToClickedSpot)
	[self mouseDragged:theEvent];
    }
}

- (void)mouseUp:(NSEvent *)theEvent
{
  NSScrollerPart lastPart = hitPart;

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
  [self highlight:NO];
#endif
  [self rescheduleTimer:-1];

  hitPart = NSScrollerNoPart;
  if (lastPart != NSScrollerKnob || knobGrabOffset >= 0)
    [self sendAction:[self action] to:[self target]];
}

- (void)rightMouseDown:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)rightMouseUp:(NSEvent *)theEvent
{
  [self mouseUp:theEvent];
}

- (void)otherMouseDown:(NSEvent *)theEvent
{
  [self mouseDown:theEvent];
}

- (void)otherMouseUp:(NSEvent *)theEvent
{
  [self mouseUp:theEvent];
}

- (void)mouseDragged:(NSEvent *)theEvent
{
  if (hitPart == NSScrollerNoPart)
    return;

  if (hitPart == NSScrollerKnob)
    {
      NSPoint point = [self convertPoint:[theEvent locationInWindow]
			    fromView:nil];
      NSRect bounds, knobSlotRect;

      if (knobGrabOffset <= -1)
	knobGrabOffset = - (knobGrabOffset + 1);

      bounds = [self bounds];
      knobSlotRect = [self rectForPart:NSScrollerKnobSlot];
      if (!isHorizontal)
	knobMinEdgeInSlot = point.y - knobGrabOffset - NSMinY (knobSlotRect);
      else
	knobMinEdgeInSlot = point.x - knobGrabOffset - NSMinX (knobSlotRect);

      if ([self dragUpdatesFloatValue])
	{
	  CGFloat maximum, minEdge;
	  NSRect KnobRect = [self rectForPart:NSScrollerKnob];

	  if (!isHorizontal)
	    maximum = NSHeight (knobSlotRect) - NSHeight (KnobRect);
	  else
	    maximum = NSWidth (knobSlotRect) - NSWidth (KnobRect);

	  minEdge = knobMinEdgeInSlot;
	  if (minEdge < 0)
	    minEdge = 0;
	  if (minEdge > maximum)
	    minEdge = maximum;

	  [self setDoubleValue:minEdge/maximum];
	}

      [self sendAction:[self action] to:[self target]];
    }
  else
    {
      BOOL unhilite = NO;
      NSScrollerPart part = [self testPart:[theEvent locationInWindow]];

      if (part == NSScrollerKnob)
	unhilite = YES;
      else
	{
	  switch (hitPart)
	    {
	    case NSScrollerIncrementPage:
	    case NSScrollerDecrementPage:
	      if (part != NSScrollerIncrementPage
		  && part != NSScrollerDecrementPage)
		unhilite = YES;
	      break;

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
	    case NSScrollerIncrementLine:
	    case NSScrollerDecrementLine:
	      if (part != NSScrollerIncrementLine
		  && part != NSScrollerDecrementLine)
		unhilite = YES;
	      break;
#endif
	    }
	}

      if (unhilite)
	{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
	  [self highlight:NO];
#endif
	}
      else if (part != hitPart || timer == nil)
	{
	  hitPart = part;
	  [self rescheduleTimer:[self buttonPeriod]];
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
	  [self highlight:YES];
#endif
	  [self sendAction:[self action] to:[self target]];
	}
    }
}

@end				// NonmodalScroller

@implementation EmacsScroller

- (void)viewFrameDidChange:(NSNotification *)notification
{
  BOOL enabled = [self isEnabled], tooSmall = NO;
  double floatValue = [self doubleValue];
  CGFloat knobProportion = [self knobProportion];
  const NSControlSize controlSizes[] =
    {NSControlSizeRegular, NSControlSizeSmall}; /* Descending */
  int i, count = ARRAYELTS (controlSizes);
  NSRect knobRect, bounds = [self bounds];
  CGFloat shorterDimension =
    !isHorizontal ? NSWidth (bounds) : NSHeight (bounds);

  for (i = 0; i < count; i++)
    {
      CGFloat width = [[self class]
			scrollerWidthForControlSize:controlSizes[i]
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
				      scrollerStyle:NSScrollerStyleLegacy
#endif
		       ];

      if (shorterDimension >= width)
	{
	  [self setControlSize:controlSizes[i]];
	  break;
	}
    }
  if (i == count)
    tooSmall = YES;

  [self setDoubleValue:0];
  [self setKnobProportion:0];
  [self setEnabled:YES];
  knobRect = [self rectForPart:NSScrollerKnob];
  /* Avoid "Invalid rect passed to CoreUI: {{nan,nan},{nan,nan}}".  */
  if (NSWidth (knobRect) > NSWidth (bounds)
      || NSHeight (knobRect) > NSHeight (bounds)
      || (NSWidth (knobRect) == NSWidth (bounds)
	  && NSHeight (knobRect) == NSHeight (bounds)))
    tooSmall = YES;
  if (!isHorizontal)
    minKnobSpan = NSHeight (knobRect);
  else
    minKnobSpan = NSWidth (knobRect);
  /* The value for knobSlotSpan used to be updated here.  But it seems
     to be too early on Mac OS X 10.7.  We just invalidate it here,
     and update it in the next -[EmacsScroller knobSlotSpan] call.  */
  knobSlotSpan = -1;

  if (!tooSmall)
    {
      [self setEnabled:enabled];
      [self setDoubleValue:floatValue];
      [self setKnobProportion:knobProportion];
    }
  else
    {
      [self setEnabled:NO];
      minKnobSpan = 0;
    }
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
  self = [super initWithFrame:frameRect];
  if (self == nil)
    return nil;

  [[NSNotificationCenter defaultCenter]
    addObserver:self
    selector:@selector(viewFrameDidChange:)
    name:@"NSViewFrameDidChangeNotification"
    object:self];

  [self viewFrameDidChange:nil];

  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
#if !USE_ARC
  [super dealloc];
#endif
}

- (void)drawRect:(NSRect)aRect
{
  [self.window.backgroundColor set];
  NSRectFill (aRect);
  [super drawRect:aRect];
  if (has_visual_effect_view_p ()
      && ![NS_APPEARANCE currentAppearance].allowsVibrancy
      && !mac_accessibility_display_options.reduce_transparency_p)
    {
      [[self.window.backgroundColor colorWithAlphaComponent:0.25] set];
      NSRectFillUsingOperation ([self rectForPart:NSScrollerKnobSlot],
				NSCompositingOperationSourceOver);
    }
}

- (void)setEmacsScrollBar:(struct scroll_bar *)bar
{
  emacsScrollBar = bar;
}

- (struct scroll_bar *)emacsScrollBar
{
  return emacsScrollBar;
}

- (BOOL)dragUpdatesFloatValue
{
  return NO;
}

- (BOOL)isOpaque
{
  return YES;
}

- (NSAppearance *)effectiveAppearance
{
  NSAppearance *effectiveAppearance = super.effectiveAppearance;

  /* If a scroll bar is drawn with the vibrant light appearance, then
     the backgrounds of the scroll bar and containing Emacs window
     become the same color.  This makes it difficult to distinguish
     horizontally adjacent fringe-less Emacs windows with scroll bars.
     So we change EmacsScroller's appearance to NSAppearanceNameAqua
     if otherwise it becomes NSAppearanceNameVibrantLight.  */
  if ([effectiveAppearance.name
	  isEqualToString:NS_APPEARANCE_NAME_VIBRANT_LIGHT])
    return [NS_APPEARANCE appearanceNamed:NS_APPEARANCE_NAME_AQUA];
  else
    return effectiveAppearance;
}

- (CGFloat)knobSlotSpan
{
  if (knobSlotSpan < 0)
    {
      BOOL enabled = [self isEnabled];
      double floatValue = [self doubleValue];
      CGFloat knobProportion = [self knobProportion];
      NSRect bounds, knobSlotRect;

      bounds = [self bounds];
      [self setDoubleValue:0];
      [self setKnobProportion:0];
      [self setEnabled:YES];
      knobSlotRect = [self rectForPart:NSScrollerKnobSlot];
      if (!isHorizontal)
	knobSlotSpan = NSHeight (knobSlotRect);
      else
	knobSlotSpan = NSWidth (knobSlotRect);
      [self setEnabled:enabled];
      [self setDoubleValue:floatValue];
      [self setKnobProportion:knobProportion];
    }

  return knobSlotSpan;
}

- (CGFloat)minKnobSpan
{
  return minKnobSpan;
}

- (CGFloat)knobMinEdgeInSlot
{
  return knobMinEdgeInSlot;
}

- (CGFloat)frameSpan
{
  return frameSpan;
}

- (CGFloat)clickPositionInFrame
{
  return clickPositionInFrame;
}

- (int)inputEventModifiers
{
  return inputEvent.modifiers;
}

- (ptrdiff_t)inputEventCode
{
  return inputEvent.code;
}

- (void)mouseClick:(NSEvent *)theEvent
{
  NSPoint point = [theEvent locationInWindow];
  NSRect bounds = [self bounds];

  hitPart = [self testPart:point];
  point = [self convertPoint:point fromView:nil];
  if (!isHorizontal)
    {
      frameSpan = NSHeight (bounds);
      clickPositionInFrame = point.y;
    }
  else
    {
      frameSpan = NSWidth (bounds);
      clickPositionInFrame = point.x;
    }
  [self sendAction:[self action] to:[self target]];
}

- (void)mouseDown:(NSEvent *)theEvent
{
  struct mac_display_info *dpyinfo = &one_mac_display_info;

  dpyinfo->last_mouse_glyph_frame = NULL;

  mac_cgevent_to_input_event ([theEvent coreGraphicsEvent], &inputEvent);
  /* Make the "Ctrl-Mouse-2 splits window" work for toolkit scroll bars.  */
  if (inputEvent.modifiers & ctrl_modifier)
    {
      inputEvent.modifiers |= down_modifier;
      [self mouseClick:theEvent];
    }
  else
    {
      inputEvent.modifiers = 0;
      [super mouseDown:theEvent];
    }
}

- (void)mouseDragged:(NSEvent *)theEvent
{
  if (inputEvent.modifiers == 0)
    [super mouseDragged:theEvent];
}

- (void)mouseUp:(NSEvent *)theEvent
{
  if (inputEvent.modifiers != 0)
    {
      mac_cgevent_to_input_event ([theEvent coreGraphicsEvent], &inputEvent);
      inputEvent.modifiers |= up_modifier;
      [self mouseClick:theEvent];
    }
  else
    [super mouseUp:theEvent];
}

- (int)whole
{
  return whole;
}

- (void)setWhole:(int)theWhole
{
  whole = theWhole;
}

- (int)portion
{
  return portion;
}

- (void)setPortion:(int)thePortion
{
  portion = thePortion;
}

@end				// EmacsScroller

@implementation EmacsMainView (ScrollBar)

static int
scroller_part_to_scroll_bar_part (NSScrollerPart part,
				  NSEventModifierFlags flags)
{
  switch (part)
    {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
    case NSScrollerDecrementLine:	return ((flags
						 & NSEventModifierFlagOption)
						? scroll_bar_above_handle
						: scroll_bar_up_arrow);
    case NSScrollerIncrementLine:	return ((flags
						 & NSEventModifierFlagOption)
						? scroll_bar_below_handle
						: scroll_bar_down_arrow);
#endif
    case NSScrollerDecrementPage:	return scroll_bar_above_handle;
    case NSScrollerIncrementPage:	return scroll_bar_below_handle;
    case NSScrollerKnob:		return scroll_bar_handle;
    case NSScrollerNoPart:		return scroll_bar_end_scroll;
    }

  return -1;
}

static int
scroller_part_to_horizontal_scroll_bar_part (NSScrollerPart part,
					     NSEventModifierFlags flags)
{
  switch (part)
    {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
    case NSScrollerDecrementLine:	return ((flags
						 & NSEventModifierFlagOption)
						? scroll_bar_before_handle
						: scroll_bar_left_arrow);
    case NSScrollerIncrementLine:	return ((flags
						 & NSEventModifierFlagOption)
						? scroll_bar_after_handle
						: scroll_bar_right_arrow);
#endif
    case NSScrollerDecrementPage:	return scroll_bar_before_handle;
    case NSScrollerIncrementPage:	return scroll_bar_after_handle;
    case NSScrollerKnob:		return scroll_bar_horizontal_handle;
    case NSScrollerNoPart:		return scroll_bar_end_scroll;
    }

  return -1;
}

/* Generate an Emacs input event in response to a scroller action sent
   from SENDER to the receiver Emacs view, and then send the action
   associated to the view to the target of the view.  */

- (void)convertScrollerAction:(id)sender
{
  struct scroll_bar *bar = [sender emacsScrollBar];
  NSScrollerPart hitPart = [sender hitPart];
  int modifiers = [sender inputEventModifiers];
  NSEvent *currentEvent = [NSApp currentEvent];
  NSEventModifierFlags modifierFlags = [currentEvent modifierFlags];

  EVENT_INIT (inputEvent);
  inputEvent.arg = Qnil;
  inputEvent.frame_or_window = bar->window;
  if (bar->horizontal)
    {
      inputEvent.kind = HORIZONTAL_SCROLL_BAR_CLICK_EVENT;
      inputEvent.part =
	scroller_part_to_horizontal_scroll_bar_part (hitPart, modifierFlags);
    }
  else
    {
      inputEvent.kind = SCROLL_BAR_CLICK_EVENT;
      inputEvent.part =
	scroller_part_to_scroll_bar_part (hitPart, modifierFlags);
    }
  inputEvent.timestamp = [currentEvent timestamp] * 1000;
  inputEvent.modifiers = modifiers;

  if (modifiers)
    {
      CGFloat clickPositionInFrame = [sender clickPositionInFrame];
      CGFloat frameSpan = [sender frameSpan];
      ptrdiff_t inputEventCode = [sender inputEventCode];

      if (clickPositionInFrame < 0)
	clickPositionInFrame = 0;
      if (clickPositionInFrame > frameSpan)
	clickPositionInFrame = frameSpan;

      XSETINT (inputEvent.x, clickPositionInFrame);
      XSETINT (inputEvent.y, frameSpan);
      if (inputEvent.part == scroll_bar_end_scroll)
	inputEvent.part = scroll_bar_handle;
      inputEvent.code = inputEventCode;
    }
  else if (hitPart == NSScrollerKnob)
    {
      CGFloat minEdge = [sender knobMinEdgeInSlot];
      CGFloat knobSlotSpan = [sender knobSlotSpan];
      CGFloat minKnobSpan = [sender minKnobSpan];
      CGFloat maximum = knobSlotSpan - minKnobSpan;
      int whole = [sender whole], portion = [sender portion];

      if (minEdge < 0)
	minEdge = 0;
      if (minEdge > maximum)
	minEdge = maximum;

      if (bar->horizontal && whole > 0)
	{
	  /* The default horizontal scroll bar drag handler assumes
	     previously-set `whole' value to be preserved and doesn't
	     want overscrolling.  */
	  int position = lround (whole * minEdge / maximum);

	  if (position > whole - portion)
	    position = whole - portion;
	  XSETINT (inputEvent.x, position);
	  XSETINT (inputEvent.y, whole);
	}
      else
	{
	  XSETINT (inputEvent.x, minEdge);
	  XSETINT (inputEvent.y, maximum);
	}
    }

  [self sendAction:action to:target];
}

@end				// EmacsMainView (ScrollBar)

@implementation EmacsFrameController (ScrollBar)

- (void)addScrollerWithScrollBar:(struct scroll_bar *)bar
{
  struct window *w = XWINDOW (bar->window);
  NSRect frame = NSMakeRect (bar->left, bar->top, bar->width, bar->height);
  BOOL frameAdjusted = NO;
  EmacsScroller *scroller;

  /* Avoid confusion between vertical and horizontal types when
     creating the scroller.  */
  if (!bar->horizontal)
    {
      if (bar->height < bar->width)
	frame.size.height = NSWidth (frame) + 1;
      frameAdjusted = YES;
    }
  else
    {
      if (bar->width < bar->height)
	frame.size.width = NSHeight (frame) + 1;
      frameAdjusted = YES;
    }

  scroller = [[EmacsScroller alloc] initWithFrame:frame];

  if (frameAdjusted)
    {
      if (!bar->horizontal)
	frame.size.height = bar->height;
      else
	frame.size.width = bar->width;
      scroller.frame = frame;
    }

  [scroller setEmacsScrollBar:bar];
  [scroller setAction:@selector(convertScrollerAction:)];
  if (!bar->horizontal
      && WINDOW_RIGHTMOST_P (w) && WINDOW_HAS_VERTICAL_SCROLL_BAR_ON_RIGHT (w))
    [scroller setAutoresizingMask:NSViewMinXMargin];
  else if (bar->horizontal && WINDOW_BOTTOMMOST_P (w))
    [scroller setAutoresizingMask:NSViewMinYMargin];
  [emacsView addSubview:scroller positioned:NSWindowBelow relativeTo:nil];
  MRC_RELEASE (scroller);
  SET_SCROLL_BAR_SCROLLER (bar, scroller);
}

- (void)setVibrantScrollersHidden:(BOOL)flag
{
  if (has_visual_effect_view_p ())
    for (NSView *view in emacsView.subviews)
      if ([view isKindOfClass:[EmacsScroller class]]
	  && view.effectiveAppearance.allowsVibrancy)
	[view setHidden:flag];
}

@end				// EmacsFrameController (ScrollBar)

/* Create a scroll bar control for BAR.  The created control is stored
   in some members of BAR.  */

void
mac_create_scroll_bar (struct scroll_bar *bar)
{
  struct frame *f = XFRAME (WINDOW_FRAME (XWINDOW (bar->window)));
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  mac_within_gui (^{[frameController addScrollerWithScrollBar:bar];});
}

/* Dispose of the scroll bar control stored in some members of
   BAR.  */

void
mac_dispose_scroll_bar (struct scroll_bar *bar)
{
  EmacsScroller *scroller = SCROLL_BAR_SCROLLER (bar);

  mac_within_gui (^{[scroller removeFromSuperview];});
}

/* Update bounds of the scroll bar BAR.  */

void
mac_update_scroll_bar_bounds (struct scroll_bar *bar)
{
  mac_within_gui (^{
      struct window *w = XWINDOW (bar->window);
      EmacsScroller *scroller = SCROLL_BAR_SCROLLER (bar);
      NSRect frame = NSMakeRect (bar->left, bar->top, bar->width, bar->height);

      [scroller setFrame:frame];
      [scroller setNeedsDisplay:YES];
      if (!bar->horizontal && WINDOW_RIGHTMOST_P (w)
	  && WINDOW_HAS_VERTICAL_SCROLL_BAR_ON_RIGHT (w))
	[scroller setAutoresizingMask:NSViewMinXMargin];
      else if (bar->horizontal && WINDOW_BOTTOMMOST_P (w))
	[scroller setAutoresizingMask:NSViewMinYMargin];
      else
	[scroller setAutoresizingMask:NSViewNotSizable];
    });
}

/* Draw the scroll bar BAR.  */

void
mac_redraw_scroll_bar (struct scroll_bar *bar)
{
  EmacsScroller *scroller = SCROLL_BAR_SCROLLER (bar);

  mac_within_gui (^{[scroller setNeedsDisplay:YES];});
}

/* Set the thumb size and position of scroll bar BAR.  We are currently
   displaying PORTION out of a whole WHOLE, and our position POSITION.  */

void
mac_set_scroll_bar_thumb (struct scroll_bar *bar, int portion, int position,
			  int whole)
{
  EmacsScroller *scroller = SCROLL_BAR_SCROLLER (bar);

  block_input ();

  mac_within_gui (^{
      /* Must be inside BLOCK_INPUT as objc_msgSend may call zone_free
	 via _class_lookupMethodAndLoadCache, for example.  */
      CGFloat minKnobSpan = [scroller minKnobSpan];

      if (minKnobSpan == 0)
	;
      else if (whole <= portion)
	[scroller setEnabled:NO];
      else
	{
	  CGFloat knobSlotSpan = [scroller knobSlotSpan];
	  CGFloat maximum, scale, top, size;
	  CGFloat floatValue, knobProportion;

	  maximum = knobSlotSpan - minKnobSpan;
	  scale = maximum / whole;
	  top = position * scale;
	  size = portion * scale + minKnobSpan;

	  floatValue = top / (knobSlotSpan - size);
	  knobProportion = size / knobSlotSpan;

	  [scroller setDoubleValue:floatValue];
	  [scroller setKnobProportion:knobProportion];
	  [scroller setWhole:whole];
	  [scroller setPortion:portion];
	  [scroller setEnabled:YES];
	}
    });

  unblock_input ();
}

int
mac_get_default_scroll_bar_width (struct frame *f)
{
  return [EmacsScroller scrollerWidthForControlSize:NSControlSizeRegular
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
				      scrollerStyle:NSScrollerStyleLegacy
#endif
	  ];
}

int
mac_get_default_scroll_bar_height (struct frame *f)
{
  return mac_get_default_scroll_bar_width (f);
}

/************************************************************************
			       Tool-bars
 ************************************************************************/

#define TOOLBAR_IDENTIFIER_FORMAT (@"org.gnu.Emacs.%p.toolbar")

/* In identifiers such as function/variable names, Emacs tool bar is
   referred to as `tool_bar', and Carbon HIToolbar as `toolbar'.  */

#define TOOLBAR_ICON_ITEM_IDENTIFIER (@"org.gnu.Emacs.toolbar.icon")

@implementation EmacsToolbarItem

- (BOOL)allowsDuplicatesInToolbar
{
  return YES;
}

#if !USE_ARC
- (void)dealloc
{
  [coreGraphicsImages release];
  [super dealloc];
}
#endif

/* Set the toolbar icon image to the CoreGraphics image CGIMAGE.  */

- (void)setCoreGraphicsImage:(CGImageRef)cgImage
{
  [self setCoreGraphicsImages:[NSArray arrayWithObject:((__bridge id)
							cgImage)]];
}

- (void)setCoreGraphicsImages:(NSArrayOf (id) *)cgImages
{
  NSUInteger i, count;
  NSImage *image;

  if ([coreGraphicsImages isEqualToArray:cgImages])
    return;

  count = [cgImages count];
  image = [NSImage imageWithCGImage:((__bridge CGImageRef)
				     [cgImages objectAtIndex:0])
			  exclusive:(count == 1)];
  for (i = 1; i < count; i++)
    {
      NSArrayOf (NSImageRep *) *reps =
	[[NSImage imageWithCGImage:((__bridge CGImageRef)
				    [cgImages objectAtIndex:i])
			 exclusive:NO] representations];

      [image addRepresentation:[reps objectAtIndex:0]];
    }

  [self setImage:image];
  coreGraphicsImages = [cgImages copy];
}

- (void)setImage:(NSImage *)image
{
  [super setImage:image];
  MRC_RELEASE (coreGraphicsImages);
  coreGraphicsImages = nil;
}

@end				// EmacsToolbarItem

@implementation EmacsFrameController (Toolbar)

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)flag
{
  NSToolbarItem *item = nil;

  if ([itemIdentifier isEqualToString:TOOLBAR_ICON_ITEM_IDENTIFIER])
    {
      item = MRC_AUTORELEASE ([[EmacsToolbarItem alloc]
				initWithItemIdentifier:itemIdentifier]);
      [item setTarget:self];
      [item setAction:@selector(storeToolBarEvent:)];
      [item setEnabled:NO];
    }

  return item;
}

- (NSArrayOf (NSToolbarItemIdentifier) *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
  return [NSArray arrayWithObjects:TOOLBAR_ICON_ITEM_IDENTIFIER,
		  NSToolbarSeparatorItemIdentifier, nil];
}

- (NSArrayOf (NSToolbarItemIdentifier) *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
  return [NSArray arrayWithObject:TOOLBAR_ICON_ITEM_IDENTIFIER];
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)theItem
{
  return [theItem isEnabled];
}

/* Create a tool bar for the frame.  */

- (void)setupToolBarWithVisibility:(BOOL)visible
{
  NSToolbarIdentifier identifier =
    [NSString stringWithFormat:TOOLBAR_IDENTIFIER_FORMAT, self];
  NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:identifier];
  NSButton *button;

  if (toolbar == nil)
    return;

  [toolbar setSizeMode:NSToolbarSizeModeSmall];
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6)
    [toolbar setAllowsUserCustomization:NO];
  else
    [toolbar setAllowsUserCustomization:YES];
  [toolbar setAutosavesConfiguration:NO];
  [toolbar setDelegate:self];
  [toolbar setVisible:visible];

  [emacsWindow setToolbar:toolbar];
  MRC_RELEASE (toolbar);

  [self updateToolbarDisplayMode];

  button = [emacsWindow standardWindowButton:NSWindowToolbarButton];
  [button setTarget:emacsController];
  [button setAction:(NSSelectorFromString (@"toolbar-pill-button-clicked:"))];
}

/* Update display mode of the toolbar for the frame according to
   the value of Vtool_bar_style.  */

- (void)updateToolbarDisplayMode
{
  NSToolbar *toolbar = [emacsWindow toolbar];
  NSToolbarDisplayMode displayMode = NSToolbarDisplayModeDefault;

  if (EQ (Vtool_bar_style, Qimage))
    displayMode = NSToolbarDisplayModeIconOnly;
  else if (EQ (Vtool_bar_style, Qtext))
    displayMode = NSToolbarDisplayModeLabelOnly;
  else if (EQ (Vtool_bar_style, Qboth) || EQ (Vtool_bar_style, Qboth_horiz)
	   || EQ (Vtool_bar_style, Qtext_image_horiz))
    displayMode = NSToolbarDisplayModeIconAndLabel;

  /* -[NSToolbar setDisplayMode] posts
      NSViewFrameDidChangeNotification for EmacsView, but with a bogus
      (intermediate?) value for view's frame and bounds.  We suspend
      -[EmacsView synchronizeBacking] while setting toolbar's display
      mode.  */
  [emacsView suspendSynchronizingBackingBitmap:YES];
  [toolbar setDisplayMode:displayMode];
  [emacsView suspendSynchronizingBackingBitmap:NO];
  [emacsView synchronizeBacking];
}

/* Store toolbar item click event from SENDER to kbd_buffer.  */

- (void)storeToolBarEvent:(id)sender
{
  NSInteger i = [sender tag];
  struct frame *f = emacsFrame;

#define PROP(IDX) AREF (f->tool_bar_items, i * TOOL_BAR_ITEM_NSLOTS + (IDX))
  if (i < f->n_tool_bar_items && !NILP (PROP (TOOL_BAR_ITEM_ENABLED_P)))
    {
      Lisp_Object frame;
      struct input_event buf;

      EVENT_INIT (buf);

      XSETFRAME (frame, f);
      buf.kind = TOOL_BAR_EVENT;
      buf.frame_or_window = frame;
      buf.arg = frame;
      kbd_buffer_store_event (&buf);

      buf.kind = TOOL_BAR_EVENT;
      buf.frame_or_window = frame;
      buf.arg = PROP (TOOL_BAR_ITEM_KEY);
      buf.modifiers = mac_event_to_emacs_modifiers ([NSApp currentEvent]);
      kbd_buffer_store_event (&buf);
    }
#undef PROP
}

/* Report a mouse movement over toolbar to the mainstream Emacs
   code.  */

- (void)noteToolBarMouseMovement:(NSEvent *)event
{
  struct frame *f = emacsFrame;
  NSView *hitView;

  /* Return if mouse dragged.  */
  if ([event type] != NSEventTypeMouseMoved)
    return;

  if (!VECTORP (f->tool_bar_items))
    return;

  hitView = [[[emacsWindow contentView] superview]
	      hitTest:[event locationInWindow]];
  if ([hitView respondsToSelector:@selector(item)])
    {
      NSToolbarItem *item = [(id <EmacsToolbarItemViewer>)hitView item];

      if ([item isKindOfClass:[EmacsToolbarItem class]])
	{
#define PROP(IDX) AREF (f->tool_bar_items, i * TOOL_BAR_ITEM_NSLOTS + (IDX))
	  NSInteger i = [item tag];

	  if (i >= 0 && i < f->n_tool_bar_items)
	    {
	      struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
	      NSRect viewFrame;

	      viewFrame = [hitView convertRect:[hitView bounds] toView:nil];
	      viewFrame = [emacsView convertRect:viewFrame fromView:nil];
	      STORE_NATIVE_RECT (dpyinfo->last_mouse_glyph,
				 NSMinX (viewFrame), NSMinY (viewFrame),
				 NSWidth (viewFrame), NSHeight (viewFrame));

	      help_echo_object = help_echo_window = Qnil;
	      help_echo_pos = -1;
	      help_echo_string = PROP (TOOL_BAR_ITEM_HELP);
	      if (NILP (help_echo_string))
		help_echo_string = PROP (TOOL_BAR_ITEM_CAPTION);
	    }
	}
    }
#undef PROP
}

@end				// EmacsFrameController (Toolbar)

/* Whether the toolbar for the frame F is visible.  */

bool
mac_is_frame_window_toolbar_visible (struct frame *f)
{
  NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

  return [[window toolbar] isVisible];
}

/* Update the tool bar for frame F.  Add new buttons and remove old.  */

void
update_frame_tool_bar (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  EmacsWindow *window;
  NativeRectangle r;
  NSToolbar *toolbar;
  int i, win_gravity = f->output_data.mac->toolbar_win_gravity;
  int __block pos;
  bool use_multiimage_icons_p = true;

  block_input ();

  window = [frameController emacsWindow];
  mac_get_frame_window_gravity_reference_bounds (f, win_gravity, &r);
  /* Shrinking the toolbar height with preserving the whole window
     height (e.g., fullheight) seems to be problematic.  */
  [window suspendConstrainingToScreen:YES];

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
  use_multiimage_icons_p =
    ([window respondsToSelector:@selector(backingScaleFactor)]
     || [window userSpaceScaleFactor] > 1);
#endif

  toolbar = [window toolbar];
  pos = 0;
  for (i = 0; i < f->n_tool_bar_items; ++i)
    {
#define PROP(IDX) AREF (f->tool_bar_items, i * TOOL_BAR_ITEM_NSLOTS + (IDX))
      bool enabled_p = !NILP (PROP (TOOL_BAR_ITEM_ENABLED_P));
      bool selected_p = !NILP (PROP (TOOL_BAR_ITEM_SELECTED_P));
      int idx;
      ptrdiff_t img_id;
      struct image *img;
      Lisp_Object image;
      NSString *label;
      NSArrayOf (id) *cgImages;
      NSToolbarItemIdentifier identifier = TOOLBAR_ICON_ITEM_IDENTIFIER;

      if (EQ (PROP (TOOL_BAR_ITEM_TYPE), Qt))
	identifier = NSToolbarSeparatorItemIdentifier;
      else
	{
	  /* If image is a vector, choose the image according to the
	     button state.  */
	  image = PROP (TOOL_BAR_ITEM_IMAGES);
	  if (VECTORP (image))
	    {
	      if (enabled_p)
		idx = (selected_p
		       ? TOOL_BAR_IMAGE_ENABLED_SELECTED
		       : TOOL_BAR_IMAGE_ENABLED_DESELECTED);
	      else
		idx = (selected_p
		       ? TOOL_BAR_IMAGE_DISABLED_SELECTED
		       : TOOL_BAR_IMAGE_DISABLED_DESELECTED);

	      eassert (ASIZE (image) >= idx);
	      image = AREF (image, idx);
	    }
	  else
	    idx = -1;

	  /* Ignore invalid image specifications.  */
	  if (!valid_image_p (image))
	    continue;

	  if (use_multiimage_icons_p)
	    FRAME_BACKING_SCALE_FACTOR (f) = 1;
          img_id = lookup_image (f, image);
	  if (use_multiimage_icons_p)
	    [frameController updateBackingScaleFactor];
          img = IMAGE_FROM_ID (f, img_id);
          prepare_image_for_display (f, img);

          if (img->cg_image == NULL)
	    continue;

	  if (STRINGP (PROP (TOOL_BAR_ITEM_LABEL)))
	    label = [NSString
		      stringWithLispString:(PROP (TOOL_BAR_ITEM_LABEL))];
	  else
	    label = @"";

	  /* As displayed images of toolbar image items are scaled to
	     square shapes, narrow images such as separators look
	     weird.  So we use separator items for too narrow disabled
	     images.  */
	  if (CGImageGetWidth (img->cg_image) <= 2 && !enabled_p)
	    identifier = NSToolbarSeparatorItemIdentifier;
	  else if (!use_multiimage_icons_p || img->target_backing_scale == 0)
	    cgImages = [NSArray arrayWithObject:((__bridge id) img->cg_image)];
	  else
	    {
	      CGImageRef cg_image = img->cg_image;

	      FRAME_BACKING_SCALE_FACTOR (f) = 2;
	      img_id = lookup_image (f, image);
	      [frameController updateBackingScaleFactor];
	      img = IMAGE_FROM_ID (f, img_id);
	      prepare_image_for_display (f, img);

	      /* It's OK for img->cg_image to become NULL here.  */
	      cgImages = [NSArray arrayWithObjects:((__bridge id) cg_image),
				  ((__bridge id) img->cg_image), nil];
	    }
	}

      mac_within_gui (^{
	  NSArrayOf (__kindof NSToolbarItem *) *items = [toolbar items];
	  NSUInteger count = [items count];

	  if (pos >= count
	      || ![identifier isEqualToString:[[items objectAtIndex:pos]
						itemIdentifier]])
	    {
	      [toolbar insertItemWithItemIdentifier:identifier atIndex:pos];
	      items = [toolbar items];
	      count = [items count];
	    }

	  if (identifier == NSToolbarSeparatorItemIdentifier)
	    {
	      /* On Mac OS X 10.7, items with the identifier
		 NSToolbarSeparatorItemIdentifier are not added.  */
	      if (pos < count
		  && [identifier isEqualToString:[[items objectAtIndex:pos]
						   itemIdentifier]])
		pos++;
	    }
	  else
	    {
	      EmacsToolbarItem *item = [items objectAtIndex:pos];

	      [item setCoreGraphicsImages:cgImages];
	      [item setLabel:label];
	      [item setEnabled:(enabled_p || idx >= 0)];
	      [item setTag:i];
	      pos++;
	    }
	});
#undef PROP
    }

  mac_within_gui (^{
      NSUInteger count = [[toolbar items] count];
#if 0
      /* This leads to the problem that the toolbar space right to the
	 icons cannot be dragged if it becomes wider on Mac OS X
	 10.5. */
      while (pos < count)
	[toolbar removeItemAtIndex:--count];
#else
      while (pos < count)
	{
	  [toolbar removeItemAtIndex:pos];
	  count--;
	}
#endif
    });

  unblock_input ();

  /* Check if the window has moved during toolbar item setup.  As
     title bar dragging is processed asynchronously, we don't
     notice it without reading window events.  */
  if (input_polling_used ())
    {
      /* It could be confusing if a real alarm arrives while
	 processing the fake one.  Turn it off and let the handler
	 reset it.  */
      int old_poll_suppress_count = poll_suppress_count;
      poll_suppress_count = 1;
      poll_for_input_1 ();
      poll_suppress_count = old_poll_suppress_count;
    }

  block_input ();

  mac_within_gui (^{
      [frameController updateToolbarDisplayMode];
      /* If we change the visibility of a toolbar while its window is
	 being moved asynchronously, the window moves to the original
	 position.  How can we know we are in asynchronous dragging?
	 Note that sometimes we don't receive windowDidMove: messages
	 for preceding windowWillMove:.  */
      if (![toolbar isVisible])
	[toolbar setVisible:YES];
    });

  [window suspendConstrainingToScreen:NO];
  win_gravity = f->output_data.mac->toolbar_win_gravity;
  if (!(EQ (frame_inhibit_implied_resize, Qt)
	|| (CONSP (frame_inhibit_implied_resize)
	    && !NILP (Fmemq (Qtool_bar_lines, frame_inhibit_implied_resize)))))
    {
      r.width = 0;
      if (!([frameController windowManagerState] & WM_STATE_MAXIMIZED_VERT))
	r.height = 0;
    }
  mac_set_frame_window_gravity_reference_bounds (f, win_gravity, r);
  f->output_data.mac->toolbar_win_gravity = 0;

  unblock_input ();
}

/* Hide the tool bar on frame F.  Unlike the counterpart on GTK+, it
   doesn't deallocate the resources.  */

void
free_frame_tool_bar (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  EmacsWindow *window;
  NSToolbar *toolbar;

  block_input ();

  window = [frameController emacsWindow];
  toolbar = [window toolbar];
  if ([toolbar isVisible])
    {
      int win_gravity = f->output_data.mac->toolbar_win_gravity;
      NativeRectangle r;

      mac_get_frame_window_gravity_reference_bounds (f, win_gravity, &r);
      /* Shrinking the toolbar height with preserving the whole window
	 height (e.g., fullheight) seems to be problematic.  */
      [window suspendConstrainingToScreen:YES];

      mac_within_gui (^{[toolbar setVisible:NO];});

      [window suspendConstrainingToScreen:NO];
      if (!(EQ (frame_inhibit_implied_resize, Qt)
	    || (CONSP (frame_inhibit_implied_resize)
		&& !NILP (Fmemq (Qtool_bar_lines,
				 frame_inhibit_implied_resize)))))
	{
	  r.width = 0;
	  if (!([frameController windowManagerState] & WM_STATE_MAXIMIZED_VERT))
	    r.height = 0;
	}
      mac_set_frame_window_gravity_reference_bounds (f, win_gravity, r);
    }
  f->output_data.mac->toolbar_win_gravity = 0;

  unblock_input ();
}


/************************************************************************
			      Font Panel
 ************************************************************************/

@implementation EmacsFontPanel

#if !USE_ARC
- (void)dealloc
{
  [mouseUpEvent release];
  [super dealloc];
}
#endif

- (void)suspendSliderTracking:(NSEvent *)event
{
  mouseUpEvent =
    MRC_RETAIN ([event mouseEventByChangingType:NSEventTypeLeftMouseUp
				    andLocation:[event locationInWindow]]);
  [NSApp postEvent:mouseUpEvent atStart:YES];
  MOUSE_TRACKING_SET_RESUMPTION (emacsController, self, resumeSliderTracking);
}

- (void)resumeSliderTracking
{
  NSPoint location = [mouseUpEvent locationInWindow];
  NSRect trackRect;
  NSEvent *mouseDownEvent;

  trackRect = [trackedSlider convertRect:[[trackedSlider cell] trackRect]
			     toView:nil];
  if (location.x < NSMinX (trackRect))
    location.x = NSMinX (trackRect);
  else if (location.x >= NSMaxX (trackRect))
    location.x = NSMaxX (trackRect) - 1;
  if (location.y <= NSMinY (trackRect))
    location.y = NSMinY (trackRect) + 1;
  else if (location.y > NSMaxY (trackRect))
    location.y = NSMaxY (trackRect);

  mouseDownEvent = [mouseUpEvent
		     mouseEventByChangingType:NSEventTypeLeftMouseDown
				  andLocation:location];
  MRC_RELEASE (mouseUpEvent);
  mouseUpEvent = nil;
  [NSApp postEvent:mouseDownEvent atStart:YES];
}

- (void)sendEvent:(NSEvent *)event
{
  if ([event type] == NSEventTypeLeftMouseDown)
    {
      NSView *contentView = [self contentView], *hitView;

      hitView = [contentView hitTest:[[contentView superview]
				       convertPoint:[event locationInWindow]
				       fromView:nil]];
      if ([hitView isKindOfClass:[NSSlider class]])
	trackedSlider = (NSSlider *) hitView;
    }

  [super sendEvent:event];
}

@end				// EmacsFontPanel

@implementation EmacsController (FontPanel)

/* Called when the font panel is about to close.  */

- (void)fontPanelWillClose:(NSNotification *)notification
{
  OSStatus err;
  EventRef event;

  err = CreateEvent (NULL, kEventClassFont, kEventFontPanelClosed, 0,
		     kEventAttributeNone, &event);
  if (err == noErr)
    {
      err = mac_store_event_ref_as_apple_event (0, 0, Qfont, Qpanel_closed,
						event, 0, NULL, NULL);
      ReleaseEvent (event);
    }
}

@end				// EmacsController (FontPanel)

@implementation EmacsFrameController (FontPanel)

/* Return the NSFont object for the face FACEID and the character C.  */

- (NSFont *)fontForFace:(int)faceId character:(int)c
	       position:(int)pos object:(Lisp_Object)object
{
  struct frame *f = emacsFrame;

  if (FRAME_FACE_CACHE (f) && CHAR_VALID_P (c))
    {
      struct face *face;

      faceId = FACE_FOR_CHAR (f, FACE_FROM_ID (f, faceId), c, pos, object);
      face = FACE_FROM_ID (f, faceId);

      return [NSFont fontWithFace:face];
    }
  else
    return nil;
}

/* Called when the user has chosen a font from the font panel.  */

- (void)changeFont:(NSFontManager *)sender
{
  EmacsFontPanel *fontPanel = (EmacsFontPanel *) [sender fontPanel:NO];
  NSEvent *currentEvent;
  NSFont *oldFont, *newFont;
  Lisp_Object arg = Qnil;
  struct input_event inev;

  /* This might look strange, but can happen on Mac OS X 10.5 and
     later inside [fontPanel makeFirstResponder:accessoryView] (in
     mac_font_dialog) if the panel is shown for the first time.  */
  if ([[fontPanel delegate] isMemberOfClass:[EmacsFontDialogController class]])
    return;

  currentEvent = [NSApp currentEvent];
  if ([currentEvent type] == NSEventTypeLeftMouseDragged)
    [fontPanel suspendSliderTracking:currentEvent];

  oldFont = [self fontForFace:DEFAULT_FACE_ID character:0 position:-1
		       object:Qnil];
  newFont = [sender convertFont:oldFont];
  if (newFont)
    arg = Fcons (Fcons (Qfont_spec,
			Fcons (build_string ("Lisp"),
			       macfont_nsctfont_to_spec ((__bridge void *)
							 newFont))),
		 arg);

  EVENT_INIT (inev);
  inev.kind = MAC_APPLE_EVENT;
  inev.x = Qfont;
  inev.y = Qselection;
  XSETFRAME (inev.frame_or_window,
	     mac_focus_frame (&one_mac_display_info));
  inev.arg = Fcons (build_string ("aevt"), arg);
  [emacsController storeEvent:&inev];
}

/* Hide unused features in font panels.  */

- (NSFontPanelModeMask)validModesForFontPanel:(NSFontPanel *)fontPanel
{
  /* Underline, Strikethrough, TextColor, DocumentColor, and Shadow
     are not used in font panels.  */
  return (NSFontPanelModeMaskFace
	  | NSFontPanelModeMaskSize
	  | NSFontPanelModeMaskCollection);
}

@end				// EmacsFrameController (FontPanel)

/* Whether the font panel is currently visible.  */

bool
mac_font_panel_visible_p (void)
{
  NSFontPanel *fontPanel = [[NSFontManager sharedFontManager] fontPanel:NO];

  return [fontPanel isVisible];
}

/* Toggle visiblity of the font panel.  */

OSStatus
mac_show_hide_font_panel (void)
{
  static BOOL initialized;
  NSFontManager *fontManager = [NSFontManager sharedFontManager];
  NSFontPanel * __block fontPanel;

  mac_within_gui (^{fontPanel = MRC_RETAIN ([fontManager fontPanel:YES]);});

  if (!initialized)
    {
      [[NSNotificationCenter defaultCenter]
	addObserver:emacsController
	selector:@selector(fontPanelWillClose:)
	name:@"NSWindowWillCloseNotification"
	object:fontPanel];
      initialized = YES;
    }

  mac_within_gui (^{
      if ([fontPanel isVisible])
	[fontPanel orderOut:nil];
      else
	[fontManager orderFrontFontPanel:nil];
    });

  MRC_RELEASE (fontPanel);

  return noErr;
}

/* Set the font selected in the font panel to the one corresponding to
   the face FACE_ID and the charcacter C in the frame F.  */

OSStatus
mac_set_font_info_for_selection (struct frame *f, int face_id, int c, int pos,
				 Lisp_Object object)
{
  if (mac_font_panel_visible_p () && f)
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);
      NSFont *font = [frameController fontForFace:face_id character:c
					 position:pos object:object];

      mac_within_gui (^{
	  [[NSFontManager sharedFontManager] setSelectedFont:font
						  isMultiple:NO];
	});
    }

  return noErr;
}


/************************************************************************
			    Event Handling
 ************************************************************************/

extern Boolean _IsSymbolicHotKeyEvent (EventRef, UInt32 *, Boolean *) AVAILABLE_MAC_OS_X_VERSION_10_3_AND_LATER;

static void update_apple_event_handler (void);
static void update_dragged_types (void);

/* Specify how long dpyinfo->saved_menu_event remains valid in
   seconds.  This is to avoid infinitely ignoring mouse events when
   MENU_BAR_ACTIVATE_EVENT is not processed: e.g., "M-! sleep 30 RET
   -> try to activate menu bar -> C-g".  */
#define SAVE_MENU_EVENT_TIMEOUT	5

@implementation EmacsFrameController (EventHandling)

/* Called when an EnterNotify event would happen for an Emacs window
   if it were on X11.  */

- (void)noteEnterEmacsView
{
  NSPoint mouseLocation = [NSEvent mouseLocation];

  mouseLocation = [self convertEmacsViewPointFromScreen:mouseLocation];
  /* EnterNotify counts as mouse movement,
     so update things that depend on mouse position.  */
  [self noteMouseMovement:mouseLocation];
}

/* Called when a LeaveNotify event would happen for an Emacs window if
   it were on X11.  */

- (void)noteLeaveEmacsView
{
  struct frame *f = emacsFrame;
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  Mouse_HLInfo *hlinfo = &dpyinfo->mouse_highlight;

  if (emacsViewIsHiddenOrHasHiddenAncestor)
    return;

  /* This corresponds to LeaveNotify for an X11 window for an Emacs
     frame.  */
  if (f == hlinfo->mouse_face_mouse_frame)
    {
      /* If we move outside the frame, then we're
	 certainly no longer on any text in the
	 frame.  */
      [self clearMouseFace:hlinfo];
      hlinfo->mouse_face_mouse_frame = 0;
      mac_flush_1 (f);
    }

  [emacsController cancelHelpEchoForEmacsFrame:f];

  /* This corresponds to EnterNotify for an X11 window for some
     popup (from note_mouse_movement in xterm.c).  */
  [self noteMouseHighlightAtX:-1 y:-1];
  dpyinfo->last_mouse_glyph_frame = NULL;
}

/* Function to report a mouse movement to the mainstream Emacs code.
   The input handler calls this.

   We have received a mouse movement event, whose position in the view
   coordinate is given in POINT.  If the mouse is over a different
   glyph than it was last time, tell the mainstream emacs code by
   setting mouse_moved.  If not, ask for another motion event, so we
   can check again the next time it moves.  */

- (BOOL)noteMouseMovement:(NSPoint)point
{
  struct frame *f = emacsFrame;
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  Mouse_HLInfo *hlinfo = &dpyinfo->mouse_highlight;
  NSRect emacsViewBounds = [emacsView bounds];
  int x, y;
  NativeRectangle *r;

  /* While the Tab Overview UI is in action, the views previously
     shown before the invocation of the Overview UI are hidden and not
     drawable.  We avoid lazy creation of emacsWindow.tabGroup because
     it causes side effect of not creating a tabbed window.  */
  if (emacsViewIsHiddenOrHasHiddenAncestor)
    return true;

  dpyinfo->last_mouse_movement_time = mac_system_uptime () * 1000;

  if (f == hlinfo->mouse_face_mouse_frame
      && ! (point.x >= 0 && point.x < NSMaxX (emacsViewBounds)
	    && point.y >= 0 && point.y < NSMaxY (emacsViewBounds)))
    {
      /* This case corresponds to LeaveNotify in X11.  If we move
	 outside the frame, then we're certainly no longer on any text
	 in the frame.  */
      [self clearMouseFace:hlinfo];
      hlinfo->mouse_face_mouse_frame = 0;
    }

  x = point.x;
  y = point.y;
  r = &dpyinfo->last_mouse_glyph;
  /* Has the mouse moved off the glyph it was on at the last sighting?  */
  if (f != dpyinfo->last_mouse_glyph_frame
      || x < r->x || x - r->x >= r->width || y < r->y || y - r->y >= r->height)
    {
      [self noteMouseHighlightAtX:x y:y];
      /* Remember which glyph we're now on.  */
      remember_mouse_glyph (f, x, y, r);
      dpyinfo->last_mouse_glyph_frame = f;
      return true;
    }

  return false;
}

- (BOOL)clearMouseFace:(Mouse_HLInfo *)hlinfo
{
  struct frame *f = emacsFrame;
  BOOL result;

  [emacsView lockFocusOnBacking];
  set_global_focus_view_frame (f);
  result = clear_mouse_face (hlinfo);
  unset_global_focus_view_frame ();
  [emacsView unlockFocusOnBacking];

  return result;
}

- (void)noteMouseHighlightAtX:(int)x y:(int)y
{
  struct frame *f = emacsFrame;

  f->mouse_moved = true;
  [emacsView lockFocusOnBacking];
  set_global_focus_view_frame (f);
  note_mouse_highlight (f, x, y);
  unset_global_focus_view_frame ();
  [emacsView unlockFocusOnBacking];
}

@end				// EmacsFrameController (EventHandling)

/* Obtains the emacs modifiers from the event EVENT.  */

static int
mac_event_to_emacs_modifiers (NSEvent *event)
{
  struct input_event buf;

  mac_cgevent_to_input_event ([event coreGraphicsEvent], &buf);

  return buf.modifiers;
}

void
mac_get_screen_info (struct mac_display_info *dpyinfo)
{
  NSArrayOf (NSScreen *) *screens = [NSScreen screens];
  NSWindowDepth depth = [[screens objectAtIndex:0] depth];
  NSRect frame;

  dpyinfo->n_planes = NSBitsPerPixelFromDepth (depth);
  dpyinfo->color_p = dpyinfo->n_planes > NSBitsPerSampleFromDepth (depth);

  frame = NSZeroRect;
  for (NSScreen *screen in screens)
    frame = NSUnionRect (frame, [screen frame]);
  dpyinfo->width = NSWidth (frame);
  dpyinfo->height = NSHeight (frame);
}

/* Run the current run loop in the default mode until some input
   happens or TIMEOUT seconds passes unless it is negative.  Return 0
   if timeout occurs first.  Return the remaining timeout unless the
   original TIMEOUT value is negative.  */

EventTimeout
mac_run_loop_run_once (EventTimeout timeout)
{
  NSDate *expiration;

  if (timeout < 0)
    expiration = [NSDate distantFuture];
  else
    expiration = [NSDate dateWithTimeIntervalSinceNow:timeout];

  /* On macOS 10.12, the application sometimes becomes unresponsive to
     Dock icon clicks (though it reacts to Command-Tab) if we directly
     run a run loop and the application windows are covered by other
     applications for a while.  */
    mac_within_app (^{
	[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				 beforeDate:expiration];
      });

  if (timeout > 0)
    {
      timeout = [expiration timeIntervalSinceNow];
      if (timeout < 0)
	timeout = 0;
    }

  return timeout;
}

/* Return next event in the main queue if it exists.  Otherwise return
   NULL.  */

static EventRef
mac_peek_next_event (void)
{
  EventRef event;

  event = AcquireFirstMatchingEventInQueue (GetCurrentEventQueue (), 0,
					    NULL, kEventQueueOptionsNone);
  if (event)
    ReleaseEvent (event);

  return event;
}

/* Return next event in the main queue if it exists and is a mouse
   down on the menu bar.  Otherwise return NULL.  */

static EventRef
peek_if_next_event_activates_menu_bar (void)
{
  EventRef event = mac_peek_next_event ();
  OSType event_class;
  UInt32 event_kind;

  if (event == NULL)
    return NULL;

  event_class = GetEventClass (event);
  event_kind = GetEventKind (event);
  if (event_class == kEventClassKeyboard
      && event_kind == kEventRawKeyDown)
    {
      UInt32 code;
      Boolean isEnabled;

      if (_IsSymbolicHotKeyEvent (event, &code, &isEnabled)
	  && isEnabled && code == 7) /* Move focus to the menu bar */
	{
	  OSStatus err;
	  UInt32 modifiers;

	  err = GetEventParameter (event, kEventParamKeyModifiers, typeUInt32,
				   NULL, sizeof (UInt32), NULL, &modifiers);
	  if (err == noErr
	      && !(modifiers
		   & ((mac_pass_command_to_system ? 0 : cmdKey)
		      | (mac_pass_control_to_system ? 0 : controlKey))))
	    return event;
	}
    }
  else if (event_class == kEventClassMouse
	   && event_kind == kEventMouseDown)
    {
      OSStatus err;
      HIPoint point;

      err = GetEventParameter (event, kEventParamMouseLocation,
			       typeHIPoint, NULL, sizeof (HIPoint), NULL,
			       &point);
      if (err == noErr)
	{
	  NSRect baseScreenFrame = mac_get_base_screen_frame ();
	  NSPoint mouseLocation =
	    NSMakePoint (point.x + NSMinX (baseScreenFrame),
			 - point.y + NSMaxY (baseScreenFrame));
	  NSScreen *screen = [NSScreen screenContainingPoint:mouseLocation];

	  if ([screen canShowMenuBar])
	    {
	      NSRect frame = [screen frame];
	      CGFloat menuBarHeight = [[NSApp mainMenu] menuBarHeight];

	      frame.origin.y = NSMaxY (frame) - menuBarHeight;
	      frame.size.height = menuBarHeight;
	      if (NSMouseInRect (mouseLocation, frame, NO))
		return event;
	    }
	}
    }

  return NULL;
}

/* Emacs calls this whenever it wants to read an input event from the
   user. */

int
mac_read_socket (struct terminal *terminal, struct input_event *hold_quit)
{
  int count;
  struct mac_display_info *dpyinfo = &one_mac_display_info;
#if __clang_major__ < 3
  NSAutoreleasePool *pool;
#endif
  static NSDate *lastCallDate;
  static NSTimer *timer;
  NSTimeInterval timeInterval, minimumInterval;

  block_input ();

  BEGIN_AUTORELEASE_POOL;

  minimumInterval = [emacsController minimumIntervalForReadSocket];
  if (lastCallDate
      && (timeInterval = - [lastCallDate timeIntervalSinceNow],
	  timeInterval < minimumInterval))
    {
      if (![timer isValid])
	{
	  MRC_RELEASE (timer);
	  timeInterval = minimumInterval - timeInterval;
	  mac_within_gui (^{
	      timer =
		MRC_RETAIN ([NSTimer
			      scheduledTimerWithTimeInterval:timeInterval
						      target:emacsController
						    selector:@selector(processDeferredReadSocket:)
						    userInfo:nil
						     repeats:NO]);
	    });
	}
      count = 0;
    }
  else
    {
      Lisp_Object tail, frame;

      MRC_RELEASE (lastCallDate);
      lastCallDate = [[NSDate alloc] init];
      [timer invalidate];
      MRC_RELEASE (timer);
      timer = nil;
      extendReadSocketIntervalOnce = NO;

      /* Maybe these should be done at some redisplay timing.  */
      update_apple_event_handler ();
      update_dragged_types ();
      [emacsController updateObservedKeyPaths];

      if (dpyinfo->saved_menu_event
	  && (GetEventTime (dpyinfo->saved_menu_event) + SAVE_MENU_EVENT_TIMEOUT
	      <= GetCurrentEventTime ()))
	{
	  ReleaseEvent (dpyinfo->saved_menu_event);
	  dpyinfo->saved_menu_event = NULL;
	}

      mac_draw_queue_sync ();
      handling_queued_nsevents_p = true;
      count = [emacsController handleQueuedNSEventsWithHoldingQuitIn:hold_quit];
      handling_queued_nsevents_p = false;

      /* If the focus was just given to an autoraising frame,
	 raise it now.  */
      /* ??? This ought to be able to handle more than one such frame.  */
      if (dpyinfo->x_pending_autoraise_frame)
	{
	  x_raise_frame (dpyinfo->x_pending_autoraise_frame);
	  dpyinfo->x_pending_autoraise_frame = NULL;
	}

      if (mac_screen_config_changed)
	{
	  mac_get_screen_info (dpyinfo);
	  mac_screen_config_changed = 0;
	}

      FOR_EACH_FRAME (tail, frame)
	{
	  struct frame *f = XFRAME (frame);

	  if (FRAME_MAC_P (f))
	    {
	      x_flush (f);
	      /* Check which frames are still visible.  We do this
		 here because there doesn't seem to be any direct
		 notification that the visibility of a window has
		 changed (at least, not in all cases.  Or are there
		 any counterparts of kEventWindowShown/Hidden?).  */
	      mac_handle_visibility_change (f);
	    }
	}
    }

  END_AUTORELEASE_POOL;

  unblock_input ();

  return count;
}


/************************************************************************
				Busy cursor
 ************************************************************************/

@implementation EmacsFrameController (Hourglass)

- (void)showHourglass:(id)sender
{
  if (hourglassWindow == nil)
    {
      NSRect rect = NSMakeRect (0, 0, HOURGLASS_WIDTH, HOURGLASS_HEIGHT);
      NSProgressIndicator *indicator =
	[[NSProgressIndicator alloc] initWithFrame:rect];

      [indicator setStyle:NSProgressIndicatorStyleSpinning];
      hourglassWindow =
	[[NSWindow alloc] initWithContentRect:rect
				    styleMask:NSWindowStyleMaskBorderless
				      backing:NSBackingStoreBuffered
					defer:YES];
#if USE_ARC
      /* Increase retain count to accommodate itself to
	 released-when-closed on ARC.  Just setting
	 released-when-closed to NO leads to crash in some
	 situations.  */
      CF_BRIDGING_RETAIN (hourglassWindow);
#endif
      [hourglassWindow setBackgroundColor:[NSColor clearColor]];
      [hourglassWindow setOpaque:NO];
      [hourglassWindow setIgnoresMouseEvents:YES];
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
      if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_9)
	[hourglassWindow useOptimizedDrawing:YES];
#endif
      [hourglassWindow setContentView:indicator];
      [indicator startAnimation:sender];
      MRC_RELEASE (indicator);
      [self updateHourglassWindowOrigin];
      if (has_visual_effect_view_p ())
	hourglassWindow.appearance =
	  ((windowManagerState & WM_STATE_FULLSCREEN)
	   ? emacsWindow.appearanceCustomization.appearance
	   : emacsWindow.appearance);
      [emacsWindow addChildWindow:hourglassWindow ordered:NSWindowAbove];
      [hourglassWindow orderWindow:NSWindowAbove
			relativeTo:[emacsWindow windowNumber]];
    }
}

- (void)hideHourglass:(id)sender
{
  if (hourglassWindow)
    {
      [emacsWindow removeChildWindow:hourglassWindow];
      [hourglassWindow close];
      hourglassWindow = nil;
    }
}

- (void)updateHourglassWindowOrigin
{
  NSRect emacsWindowFrame = [emacsWindow frame];
  NSPoint origin;

  origin.x = (NSMaxX (emacsWindowFrame)
	      - (HOURGLASS_WIDTH
		 + (emacsWindow.hasTitleBar
		    ? HOURGLASS_RIGHT_MARGIN : HOURGLASS_TOP_MARGIN)));
  origin.y = (NSMaxY (emacsWindowFrame)
	      - (HOURGLASS_HEIGHT + HOURGLASS_TOP_MARGIN));
  [hourglassWindow setFrameOrigin:origin];
}

@end				// EmacsFrameController (Hourglass)

/* Show the spinning progress indicator for the frame F.  Create it if
   it doesn't exist yet. */

void
mac_show_hourglass (struct frame *f)
{
  if (!FRAME_TOOLTIP_P (f) && FRAME_PARENT_FRAME (f) == NULL)
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      mac_within_gui (^{[frameController showHourglass:nil];});
    }
}

/* Hide the spinning progress indicator for the frame F.  Do nothing
   it doesn't exist yet. */

void
mac_hide_hourglass (struct frame *f)
{
  if (!FRAME_TOOLTIP_P (f) && FRAME_PARENT_FRAME (f) == NULL)
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);

      mac_within_gui (^{[frameController hideHourglass:nil];});
    }
}


/************************************************************************
			File selection dialog
 ************************************************************************/

@implementation EmacsSavePanel

/* Simulate kNavDontConfirmReplacement.  */

- (BOOL)_overwriteExistingFileCheck:(id)fp8
{
  return YES;
}

@end				// EmacsSavePanel

/* The actual implementation of Fx_file_dialog.  */

Lisp_Object
mac_file_dialog (Lisp_Object prompt, Lisp_Object dir,
		 Lisp_Object default_filename, Lisp_Object mustmatch,
		 Lisp_Object only_dir_p)
{
  struct frame *f = SELECTED_FRAME ();
  NSURL * __block url = nil;
  Lisp_Object file = Qnil;
  ptrdiff_t count = SPECPDL_INDEX ();
  NSString *title, *directory, *nondirectory = nil;

  check_window_system (f);

  CHECK_STRING (prompt);
  CHECK_STRING (dir);

  block_input ();

  title = [NSString stringWithLispString:prompt];
  dir = Fexpand_file_name (dir, Qnil);
  directory = [NSString stringWithLispString:dir];

  if (STRINGP (default_filename))
    {
      Lisp_Object tem = Ffile_name_nondirectory (default_filename);

      nondirectory = [NSString stringWithLispString:tem];
    }

  mac_menu_set_in_use (true);
  mac_within_gui_allowing_inner_lisp (^{
      if (NILP (only_dir_p) && NILP (mustmatch))
	{
	  /* This is a save dialog */
	  NSSavePanel *savePanel = [EmacsSavePanel savePanel];
	  NSModalResponse __block response;

	  [savePanel setTitle:title];
	  [savePanel setPrompt:@"OK"];
	  [savePanel setNameFieldLabel:@"Enter Name:"];
	  if ([savePanel respondsToSelector:@selector(setShowsTagField:)])
	    [savePanel setShowsTagField:NO];

	  [savePanel setDirectoryURL:[NSURL fileURLWithPath:directory
						isDirectory:YES]];
	  if (nondirectory)
	    [savePanel setNameFieldStringValue:nondirectory];
	  mac_within_app (^{response = [savePanel runModal];});
	  if (response == NSModalResponseOK)
	    url = MRC_RETAIN ([savePanel URL]);
	}
      else
	{
	  /* This is an open dialog */
	  NSOpenPanel *openPanel = [NSOpenPanel openPanel];
	  NSModalResponse __block response;

	  [openPanel setTitle:title];
	  [openPanel setPrompt:@"OK"];
	  [openPanel setAllowsMultipleSelection:NO];
	  [openPanel setCanChooseDirectories:YES];
	  [openPanel setCanChooseFiles:(NILP (only_dir_p))];

	  [openPanel setDirectoryURL:[NSURL fileURLWithPath:directory
						isDirectory:YES]];
	  if (nondirectory)
	    [openPanel setNameFieldStringValue:nondirectory];
	  [openPanel setAllowedFileTypes:nil];
	  mac_within_app (^{response = [openPanel runModal];});
	  if (response == NSModalResponseOK)
	    url = MRC_RETAIN ([[openPanel URLs] objectAtIndex:0]);
	}
    });
  mac_menu_set_in_use (false);

  if ([url isFileURL])
    file = [[url path] lispString];
  MRC_RELEASE (url);

  unblock_input ();

  /* Make "Cancel" equivalent to C-g.  */
  if (NILP (file))
    quit ();

  return unbind_to (count, file);
}


/************************************************************************
			Font selection dialog
 ************************************************************************/

@implementation EmacsFontDialogController

- (void)windowWillClose:(NSNotification *)notification
{
  [NSApp abortModal];
}

- (void)cancel:(id)sender
{
  [NSApp abortModal];
}

- (void)ok:(id)sender
{
  [NSApp stopModal];
}

- (void)changeFont:(NSFontManager *)sender
{
}

- (NSFontPanelModeMask)validModesForFontPanel:(NSFontPanel *)fontPanel
{
  /* Underline, Strikethrough, TextColor, DocumentColor, and Shadow
     are not used in font panels.  */
  return (NSFontPanelModeMaskFace
	  | NSFontPanelModeMaskSize
	  | NSFontPanelModeMaskCollection);
}

@end				// EmacsFontDialogController

static NSView *
create_ok_cancel_buttons_view (void)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
  NSView *view;
  NSButton *cancelButton, *okButton;
  NSDictionaryOf (NSString *, id) *viewsDictionary;
  NSArrayOf (NSString *) *formats;

  cancelButton = [[NSButton alloc] init];
  [cancelButton setBezelStyle:NSBezelStyleRounded];
  [cancelButton setTitle:@"Cancel"];
  [cancelButton setAction:@selector(cancel:)];
  [cancelButton setKeyEquivalent:@"\e"];
  [cancelButton setTranslatesAutoresizingMaskIntoConstraints:NO];

  okButton = [[NSButton alloc] init];
  [okButton setBezelStyle:NSBezelStyleRounded];
  [okButton setTitle:@"OK"];
  [okButton setAction:@selector(ok:)];
  [okButton setKeyEquivalent:@"\r"];
  [okButton setTranslatesAutoresizingMaskIntoConstraints:NO];

  view = [[NSView alloc] initWithFrame:NSZeroRect];
  [view addSubview:cancelButton];
  [view addSubview:okButton];

  viewsDictionary = NSDictionaryOfVariableBindings (cancelButton, okButton);
  formats = (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_9)
	     ? [NSArray arrayWithObjects:@"V:|-5-[cancelButton]-5-|",
			@"[cancelButton]-[okButton(==cancelButton)]-|", nil]
	     : [NSArray arrayWithObjects:@"V:|[cancelButton]-5-|",
			@"|-[cancelButton]-[okButton(==cancelButton)]-|", nil]);
  for (NSString *format in formats)
    {
      NSArrayOf (NSLayoutConstraint *) *constraints =
	[NSLayoutConstraint
	  constraintsWithVisualFormat:format
			      options:NSLayoutFormatAlignAllCenterY
			      metrics:nil views:viewsDictionary];

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
      [NSLayoutConstraint activateConstraints:constraints];
#else
      [view addConstraints:constraints];
#endif
    }
  [view setFrameSize:[view fittingSize]];

  MRC_RELEASE (cancelButton);
  MRC_RELEASE (okButton);

  return view;
#else
  NSMatrix *view;
  NSButtonCell *prototype = [[NSButtonCell alloc] init];
  NSSize cellSize;
  NSRect frame;
  NSButtonCell *cancelButton, *okButton;

  [prototype setBezelStyle:NSBezelStyleRounded];
  cellSize = [prototype cellSize];
  frame = NSMakeRect (0, 0, cellSize.width * 2, cellSize.height);
  view = [[NSMatrix alloc] initWithFrame:frame
				    mode:NSTrackModeMatrix
			       prototype:prototype
			    numberOfRows:1 numberOfColumns:2];
  MRC_RELEASE (prototype);
  cancelButton = [view cellAtRow:0 column:0];
  okButton = [view cellAtRow:0 column:1];
  [cancelButton setTitle:@"Cancel"];
  [okButton setTitle:@"OK"];
  [cancelButton setAction:@selector(cancel:)];
  [okButton setAction:@selector(ok:)];
  [cancelButton setKeyEquivalent:@"\e"];
  [okButton setKeyEquivalent:@"\r"];
  [view selectCell:okButton];

  return view;
#endif
}

Lisp_Object
mac_font_dialog (struct frame *f)
{
  Lisp_Object __block result = Qnil;

  mac_menu_set_in_use (true);
  mac_within_gui_allowing_inner_lisp (^{
      NSFontManager *fontManager = [NSFontManager sharedFontManager];
      NSFontPanel *fontPanel = [fontManager fontPanel:YES];
      NSFont *savedSelectedFont, *selectedFont;
      BOOL savedIsMultiple;
      NSView *savedAccessoryView, *accessoryView;
      id savedDelegate, delegate;
      NSModalResponse __block response;

      savedSelectedFont = [fontManager selectedFont];
      savedIsMultiple = [fontManager isMultiple];
      selectedFont = (__bridge NSFont *) macfont_get_nsctfont (FRAME_FONT (f));
      [fontManager setSelectedFont:selectedFont isMultiple:NO];

      savedAccessoryView = [fontPanel accessoryView];
      accessoryView = create_ok_cancel_buttons_view ();
      [fontPanel setAccessoryView:accessoryView];
      MRC_RELEASE (accessoryView);

      savedDelegate = [fontPanel delegate];
      delegate = [[EmacsFontDialogController alloc] init];
      [fontPanel setDelegate:delegate];

      [fontManager orderFrontFontPanel:nil];
      /* This avoids bogus font selection by -[NSTextView
	 resignFirstResponder] inside the modal loop.  */
      [fontPanel makeFirstResponder:accessoryView];

      mac_within_app (^{response = [NSApp runModalForWindow:fontPanel];});
      if (response != NSModalResponseAbort)
	{
	  selectedFont = [fontManager convertFont:[fontManager selectedFont]];
	  result = macfont_nsctfont_to_spec ((__bridge void *) selectedFont);
	}

      [fontPanel setAccessoryView:savedAccessoryView];
      [fontPanel setDelegate:savedDelegate];
      MRC_RELEASE (delegate);
      [fontManager setSelectedFont:savedSelectedFont
			isMultiple:savedIsMultiple];

      [fontPanel close];
    });
  mac_menu_set_in_use (false);

  return result;
}


/************************************************************************
				 Menu
 ************************************************************************/

static void update_services_menu_types (void);
static void mac_fake_menu_bar_click (EventPriority);

static NSString *localizedMenuTitleForEdit, *localizedMenuTitleForHelp;

@implementation NSMenu (Emacs)

/* Create a new menu item using the information in *WV (except
   submenus) and add it to the end of the receiver.  */

- (NSMenuItem *)addItemWithWidgetValue:(widget_value *)wv
{
  NSMenuItem *item;

  if (name_is_separator (wv->name))
    {
      item = (NSMenuItem *) [NSMenuItem separatorItem];
      [self addItem:item];
    }
  else
    {
      NSString *itemName = [NSString stringWithUTF8String:wv->name
				     fallback:YES];
      NSData *data;

      if (wv->key != NULL)
	itemName = [NSString stringWithFormat:@"%@\t%@", itemName,
			     [NSString stringWithUTF8String:wv->key
				       fallback:YES]];

      item = (NSMenuItem *) [self addItemWithTitle:itemName
				  action:@selector(setMenuItemSelectionToTag:)
				  keyEquivalent:@""];

      [item setEnabled:wv->enabled];

      /* We can't use [NSValue valueWithBytes:&wv->help
	 objCType:@encode(Lisp_Object)] when USE_LISP_UNION_TYPE
	 defined, because NSGetSizeAndAlignment does not support bit
	 fields (at least as of Mac OS X 10.5).  */
      data = [NSData dataWithBytes:&wv->help length:(sizeof (Lisp_Object))];
      [item setRepresentedObject:data];

      /* Draw radio buttons and tickboxes. */
      if (wv->selected && (wv->button_type == BUTTON_TYPE_TOGGLE
			   || wv->button_type == BUTTON_TYPE_RADIO))
	[item setState:NSControlStateValueOn];
      else
	[item setState:NSControlStateValueOff];

      [item setTag:((NSInteger) (intptr_t) wv->call_data)];
    }

  return item;
}

/* Create menu trees defined by WV and add them to the end of the
   receiver.  */

- (void)fillWithWidgetValue:(widget_value *)first_wv
{
  widget_value *wv;
  NSFont *menuFont = [NSFont menuFontOfSize:0];
  NSDictionaryOf (NSString *, id) *attributes =
    [NSDictionary dictionaryWithObject:menuFont forKey:NSFontAttributeName];
  NSSize spaceSize = [@" " sizeWithAttributes:attributes];
  CGFloat maxTabStop = 0;

  for (wv = first_wv; wv != NULL; wv = wv->next)
    if (!name_is_separator (wv->name) && wv->key)
      {
	NSString *itemName =
	  [NSString stringWithUTF8String:wv->name fallback:YES];
	NSSize size = [[itemName stringByAppendingString:@"\t"]
			sizeWithAttributes:attributes];

	if (maxTabStop < size.width)
	  maxTabStop = size.width;
      }

  for (wv = first_wv; wv != NULL; wv = wv->next)
    if (!name_is_separator (wv->name) && wv->key)
      {
	NSString *itemName =
	  [NSString stringWithUTF8String:wv->name fallback:YES];
	NSSize nameSize = [itemName sizeWithAttributes:attributes];
	int name_len = strlen (wv->name);
	int pad_len = ceil ((maxTabStop - nameSize.width) / spaceSize.width);
	Lisp_Object name;

	name = make_uninit_string (name_len + pad_len);
	strcpy (SSDATA (name), wv->name);
	memset (SDATA (name) + name_len, ' ', pad_len);
	wv->name = SSDATA (name);
      }

  for (wv = first_wv; wv != NULL; wv = wv->next)
    {
      NSMenuItem *item = [self addItemWithWidgetValue:wv];

      if (wv->contents)
	{
	  NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Submenu"];

	  [submenu setAutoenablesItems:NO];
	  [self setSubmenu:submenu forItem:item];
	  [submenu fillWithWidgetValue:wv->contents];
	  MRC_RELEASE (submenu);
	}
    }

  [self setDelegate:emacsController];
}

@end				// NSMenu (Emacs)

@implementation EmacsMenu

/* Forward unprocessed shortcut key events to the first responder of
   the key window.  */

- (BOOL)performKeyEquivalent:(NSEvent *)theEvent
{
  NSWindow *window;
  NSResponder *firstResponder;

  if ([super performKeyEquivalent:theEvent])
    return YES;

  window = [NSApp keyWindow];
  if (window == nil)
    window = FRAME_MAC_WINDOW_OBJECT (SELECTED_FRAME ());
  firstResponder = [window firstResponder];
  if ([firstResponder isMemberOfClass:[EmacsMainView class]])
    {
      UInt32 code;
      Boolean isEnabled;

      if (_IsSymbolicHotKeyEvent ((EventRef) [theEvent eventRef], &code,
				  &isEnabled)
	  && isEnabled)
	{
	  if (code == 98 /* Show Help menu, Mac OS X 10.5 and later */
	      && floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_7)
	    [emacsController showMenuBar];
	}
      else
	{
	  if ([theEvent type] == NSEventTypeKeyDown
	      && (([theEvent modifierFlags]
		   & NSEventModifierFlagDeviceIndependentFlagsMask)
		  == ((1UL << 31) | NSEventModifierFlagCommand))
	      && [[theEvent charactersIgnoringModifiers] isEqualToString:@"c"])
	    {
	      /* Probably Command-C from "Speak selected text."  */
	      [NSApp sendAction:@selector(copy:) to:nil from:nil];

	      return YES;
	    }

	  /* Note: this is not necessary for binaries built on Mac OS
	     X 10.5 because -[NSWindow sendEvent:] now sends keyDown:
	     to the first responder even if the command-key modifier
	     is set when it is not a key equivalent.  But we keep this
	     for binary compatibility.
	     Update: this is necessary for passing Control-Tab to
	     Emacs on Mac OS X 10.5 and later.  */
	  [firstResponder keyDown:theEvent];

	  return YES;
	}
    }
  else if ([theEvent type] == NSEventTypeKeyDown)
    {
      NSEventModifierFlags flags = [theEvent modifierFlags];

      flags &= ANY_KEY_MODIFIER_FLAGS_MASK;

      if (flags == NSEventModifierFlagCommand)
	{
	  NSString *characters = [theEvent charactersIgnoringModifiers];
	  SEL action = NULL;

	  if ([characters isEqualToString:@"x"])
	    action = @selector(cut:);
	  else if ([characters isEqualToString:@"c"])
	    action = @selector(copy:);
	  else if ([characters isEqualToString:@"v"])
	    action = @selector(paste:);

	  if (action)
	    return [NSApp sendAction:action to:nil from:nil];
	}

      if ([[theEvent charactersIgnoringModifiers] length] == 1
	  && mac_keydown_cgevent_quit_p ([theEvent coreGraphicsEvent]))
	{
	  /* This is necessary for avoiding hang when canceling
	     pop-up dictionary with C-g on OS X 10.11.  */
	  BOOL __block sent;

	  mac_within_app (^{
	      sent = [NSApp sendAction:@selector(cancel:) to:nil from:nil];
	    });

	  return sent;
	}
    }

  return NO;
}

- (void)menuDidBeginTracking:(NSNotification *)notification
{
  if (!popup_activated ())
    {
      NSLog (@"Canceling unexpected menu tracking: %@", [NSApp currentEvent]);
      [self cancelTracking];
    }
}

@end				// EmacsMenu

@implementation EmacsController (Menu)

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item
{
  if (!popup_activated ())
    return;

  NSData *object = [item representedObject];
  Lisp_Object help;

  if (object)
    [object getBytes:&help length:(sizeof (Lisp_Object))];
  else
    help = Qnil;

  mac_within_lisp (^{show_help_echo (help, Qnil, Qnil, Qnil);});
}

/* Start menu bar tracking and return when it is completed.

   The tracking is done inside the application loop because otherwise
   we can't pop down an error dialog caused by a Service invocation,
   for example.  */

- (void)trackMenuBar
{
  mac_within_app (^{
      /* Mac OS X 10.2 doesn't regard untilDate:nil as polling.  */
      NSDate *expiration = [NSDate distantPast];

      while (1)
	{
	  NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
				  untilDate:expiration
				  inMode:NSDefaultRunLoopMode dequeue:YES];
	  NSDate *limitDate;

	  if (event == nil)
	    {
	      /* There can be a pending mouse down event on the menu
		 bar at least on Mac OS X 10.5 with Command-Shift-/ ->
		 search with keyword -> select.  Also, some
		 kEventClassMenu event is still pending on Mac OS X
		 10.6 when selecting menu item via search field on the
		 Help menu.  */
	      if (mac_peek_next_event ())
		continue;
	    }
	  else
	    {
	      [NSApp sendEvent:event];
	      continue;
	    }

	  /* This seems to be necessary for selecting menu item via
	     search field in the Help menu on Mac OS X 10.6.  */
	  limitDate = [[NSRunLoop currentRunLoop]
			limitDateForMode:NSDefaultRunLoopMode];
	  if (limitDate == nil
	      || [limitDate timeIntervalSinceNow] > 0)
	    break;
	}

      [emacsController updatePresentationOptions];
    });
}

- (NSMenu *)applicationDockMenu:(NSApplication *)sender
{
  NSMenu *menu = [[NSMenu alloc] init];

  for (NSWindow *window in [NSApp windows])
    if (!window.hasTitleBar && window.parentWindow == nil
	&& !window.isExcludedFromWindowsMenu
	&& ([window isVisible] || [window isMiniaturized]))
      {
	NSMenuItem *item =
	  [[NSMenuItem alloc] initWithTitle:[window title]
				     action:@selector(makeKeyAndOrderFront:)
			      keyEquivalent:@""];

	[item setTarget:window];
	if ([window isKeyWindow])
	  [item setState:NSControlStateValueOn];
	else if ([window isMiniaturized])
	  {
	    NSImage *image = [NSImage imageNamed:@"NSMenuItemDiamond"];

	    if (image)
	      {
		[item setOnStateImage:image];
		[item setState:NSControlStateValueOn];
	      }
	  }
	[menu addItem:item];
	MRC_RELEASE (item);
      }

  return MRC_AUTORELEASE (menu);
}

/* Methods for the NSUserInterfaceItemSearching protocol.  */

/* This might be called from a non-main thread.  */
- (void)searchForItemsWithSearchString:(NSString *)searchString
			   resultLimit:(NSInteger)resultLimit
		    matchedItemHandler:(void (^)(NSArray *items))handleMatchedItems
{
  NSMutableArrayOf (NSString *) *items =
    [NSMutableArray arrayWithCapacity:resultLimit];
  Lisp_Object rest;

  for (rest = Vmac_help_topics; CONSP (rest); rest = XCDR (rest))
    if (STRINGP (XCAR (rest)))
      {
	NSString *string = [NSString stringWithUTF8LispString:(XCAR (rest))];
	NSRange searchRange = NSMakeRange (0, [string length]);
	NSRange foundRange;

	if ([NSApp searchString:searchString inUserInterfaceItemString:string
		    searchRange:searchRange foundRange:&foundRange])
	  {
	    [items addObject:string];
	    if ([items count] == resultLimit)
	      break;
	  }
      }

  handleMatchedItems (items);
}

- (NSArrayOf (NSString *) *)localizedTitlesForItem:(id)item
{
  return [NSArray arrayWithObject:item];
}

- (void)performActionForItem:(id)item
{
  selectedHelpTopic = item;
  [NSApp sendAction:(NSSelectorFromString (@"select-help-topic:"))
		 to:nil from:self];
  selectedHelpTopic = nil;
}

- (void)showAllHelpTopicsForSearchString:(NSString *)searchString
{
  searchStringForAllHelpTopics = searchString;
  [NSApp sendAction:(NSSelectorFromString (@"show-all-help-topics:"))
		 to:nil from:self];
  searchStringForAllHelpTopics = nil;
}

@end				// EmacsController (Menu)

@implementation EmacsFrameController (Menu)

- (void)popUpMenu:(NSMenu *)menu atLocationInEmacsView:(NSPoint)location
{
  if (!mac_popup_menu_add_contextual_menu)
    [menu popUpMenuPositioningItem:nil atLocation:location inView:emacsView];
  else
    {
      NSEvent *event =
	[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
			   location:[emacsView convertPoint:location toView:nil]
		      modifierFlags:0 timestamp:0
		       windowNumber:[emacsWindow windowNumber]
			    context:[NSGraphicsContext currentContext]
			eventNumber:0 clickCount:1 pressure:0];

      [NSMenu popUpContextMenu:menu withEvent:event forView:emacsView];
    }
}

@end				// EmacsFrameController (Menu)

static void
mac_track_menu_with_block (void (^block) (void))
{
  eassert (!pthread_main_np ());
  Lisp_Object mini_window, old_show_help_function = Vshow_help_function;

  /* Temporarily bind Vshow_help_function to
     tooltip-show-help-non-mode (or nil if the minibuffer frame is not
     visible) because we don't want tooltips during menu tracking.  */
  Vshow_help_function = Qnil;
  mini_window = FRAME_MINIBUF_WINDOW (SELECTED_FRAME ());
  if (WINDOWP (mini_window))
    {
      struct frame *mini_frame = XFRAME (WINDOW_FRAME (XWINDOW (mini_window)));

      if (FRAME_MAC_P (mini_frame)
	  && FRAME_VISIBLE_P (mini_frame) && !FRAME_OBSCURED_P (mini_frame))
	Vshow_help_function = intern ("tooltip-show-help-non-mode");
    }
  mac_within_gui_allowing_inner_lisp (block);
  Vshow_help_function = old_show_help_function;
}

/* Activate the menu bar of frame F.

   To activate the menu bar, we use the button-press event that was
   saved in dpyinfo->saved_menu_event.

   Return the selection.  */

int
mac_activate_menubar (struct frame *f)
{
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  EventRef menu_event;

  update_services_menu_types ();
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6)
    [emacsController showMenuBar];
  menu_event = dpyinfo->saved_menu_event;
  if (menu_event)
    {
      dpyinfo->saved_menu_event = NULL;
      PostEventToQueue (GetMainEventQueue (), menu_event, kEventPriorityHigh);
      ReleaseEvent (menu_event);
    }
  else
    mac_fake_menu_bar_click (kEventPriorityHigh);
  mac_menu_set_in_use (true);
  mac_track_menu_with_block (^{[emacsController trackMenuBar];});
  mac_menu_set_in_use (false);

  return [emacsController getAndClearMenuItemSelection];
}

/* Set up the initial menu bar.  */

static void
init_menu_bar (void)
{
  NSMenu *servicesMenu = [[NSMenu alloc] init];
  NSMenu *windowsMenu = [[NSMenu alloc] init];
  NSMenu *appleMenu = [[NSMenu alloc] init];
  EmacsMenu *mainMenu = [[EmacsMenu alloc] init];
  NSBundle *appKitBundle = [NSBundle bundleWithIdentifier:@"com.apple.AppKit"];
  NSString *localizedTitleForServices = /* Mac OS X 10.6 and later.  */
    NSLocalizedStringFromTableInBundle (@"Services", @"Services",
					appKitBundle, NULL);

  [NSApp setServicesMenu:servicesMenu];

  [NSApp setWindowsMenu:windowsMenu];

  [appleMenu addItemWithTitle:@"About Emacs"
	     action:@selector(about:)
	     keyEquivalent:@""];
  [appleMenu addItem:[NSMenuItem separatorItem]];
  [appleMenu addItemWithTitle:@"Preferences..."
	     action:@selector(preferences:) keyEquivalent:@""];
  [appleMenu addItem:[NSMenuItem separatorItem]];
  [appleMenu setSubmenu:servicesMenu
		forItem:[appleMenu addItemWithTitle:localizedTitleForServices
					     action:nil keyEquivalent:@""]];
  [appleMenu addItem:[NSMenuItem separatorItem]];
  [appleMenu addItemWithTitle:@"Hide Emacs"
	     action:@selector(hide:) keyEquivalent:@"h"];
  [[appleMenu addItemWithTitle:@"Hide Others"
	      action:@selector(hideOtherApplications:) keyEquivalent:@"h"]
    setKeyEquivalentModifierMask:(NSEventModifierFlagOption
				  | NSEventModifierFlagCommand)];
  [appleMenu addItemWithTitle:@"Show All"
	     action:@selector(unhideAllApplications:) keyEquivalent:@""];
  [appleMenu addItem:[NSMenuItem separatorItem]];
  [appleMenu addItemWithTitle:@"Quit Emacs"
	     action:@selector(terminate:) keyEquivalent:@""];
  /* -[NSApplication setAppleMenu:] is hidden on Mac OS X 10.4.  */
  [NSApp performSelector:@selector(setAppleMenu:) withObject:appleMenu];

  [mainMenu setAutoenablesItems:NO];
  [mainMenu setSubmenu:appleMenu
	    forItem:[mainMenu addItemWithTitle:@""
			      action:nil keyEquivalent:@""]];
  [NSApp setMainMenu:mainMenu];

  MRC_RELEASE (mainMenu);
  MRC_RELEASE (appleMenu);
  MRC_RELEASE (windowsMenu);
  MRC_RELEASE (servicesMenu);

  localizedMenuTitleForEdit =
    MRC_RETAIN (NSLocalizedStringFromTableInBundle (@"Edit", @"InputManager",
						    appKitBundle, NULL));
  localizedMenuTitleForHelp =
    MRC_RETAIN (NSLocalizedStringFromTableInBundle (@"Help", @"HelpManager",
						    appKitBundle, NULL));
}

/* Fill menu bar with the items defined by WV.  If DEEP_P, consider
   the entire menu trees we supply, rather than just the menu bar item
   names.  */

void
mac_fill_menubar (widget_value *wv, bool deep_p)
{
  NSMenu *newMenu, *mainMenu = [NSApp mainMenu], *helpMenu = nil;
  NSInteger index, nitems = [mainMenu numberOfItems];
  bool needs_update_p = deep_p;

  newMenu = [[EmacsMenu alloc] init];
  [newMenu setAutoenablesItems:NO];

  for (index = 1; wv != NULL; wv = wv->next, index++)
    {
      NSString *title = CF_BRIDGING_RELEASE (CFStringCreateWithCString
					     (NULL, wv->name,
					      kCFStringEncodingMacRoman));
      NSMenu *submenu;

      /* The title of the Help menu needs to be localized in order for
	 Spotlight for Help to be installed on Mac OS X 10.5.  */
      if ([title isEqualToString:@"Help"])
	title = localizedMenuTitleForHelp;
      if (!needs_update_p)
	{
	  if (index >= nitems)
	    needs_update_p = true;
	  else
	    {
	      submenu = [[mainMenu itemAtIndex:index] submenu];
	      if (!(submenu && [title isEqualToString:[submenu title]]))
		needs_update_p = true;
	    }
	}

      submenu = [[NSMenu alloc] initWithTitle:title];
      [submenu setAutoenablesItems:NO];

      /* To make Input Manager add "Special Characters..." to the
	 "Edit" menu, we have to localize the menu title.  */
      if ([title isEqualToString:@"Edit"])
	title = localizedMenuTitleForEdit;
      else if (title == localizedMenuTitleForHelp)
	helpMenu = submenu;

      [newMenu setSubmenu:submenu
		  forItem:[newMenu addItemWithTitle:title action:nil
				      keyEquivalent:@""]];

      if (wv->contents)
	[submenu fillWithWidgetValue:wv->contents];

      MRC_RELEASE (submenu);
    }

  if (!needs_update_p && index != nitems)
    needs_update_p = true;

  if (needs_update_p)
    {
      NSMenuItem *appleMenuItem = MRC_RETAIN ([mainMenu itemAtIndex:0]);

      [mainMenu removeItem:appleMenuItem];
      [newMenu insertItem:appleMenuItem atIndex:0];
      MRC_RELEASE (appleMenuItem);

      mac_within_gui (^{
	  [NSApp setMainMenu:newMenu];
	  if (helpMenu)
	    [NSApp setHelpMenu:helpMenu];
	});
    }

  MRC_RELEASE (newMenu);
}

static void
mac_fake_menu_bar_click (EventPriority priority)
{
  OSStatus err = noErr;
  const EventKind kinds[] = {kEventMouseDown, kEventMouseUp};
  Point point = {0, 10};	/* vertical, horizontal */
  NSScreen *mainScreen = [NSScreen mainScreen];
  int i;

  if ([mainScreen canShowMenuBar])
    {
      NSRect baseScreenFrame, mainScreenFrame;

      baseScreenFrame = mac_get_base_screen_frame ();
      mainScreenFrame = [mainScreen frame];
      point.h += NSMinX (mainScreenFrame) - NSMinX (baseScreenFrame);
      point.v += - NSMaxY (mainScreenFrame) + NSMaxY (baseScreenFrame);
    }

  [emacsController showMenuBar];

  /* CopyEventAs is not available on Mac OS X 10.2.  */
  for (i = 0; i < 2; i++)
    {
      EventRef event;

      if (err == noErr)
	err = CreateEvent (NULL, kEventClassMouse, kinds[i], 0,
			   kEventAttributeNone, &event);
      if (err == noErr)
	{
	  const UInt32 modifiers = 0, count = 1;
	  const EventMouseButton button = kEventMouseButtonPrimary;
	  const struct {
	    EventParamName name;
	    EventParamType type;
	    ByteCount size;
	    const void *data;
	  } params[] = {
	    {kEventParamMouseLocation, typeQDPoint, sizeof (Point), &point},
	    {kEventParamKeyModifiers, typeUInt32, sizeof (UInt32), &modifiers},
	    {kEventParamMouseButton, typeMouseButton,
	     sizeof (EventMouseButton), &button},
	    {kEventParamClickCount, typeUInt32, sizeof (UInt32), &count}};
	  int j;

	  for (j = 0; j < ARRAYELTS (params); j++)
	    if (err == noErr)
	      err = SetEventParameter (event, params[j].name, params[j].type,
				       params[j].size, params[j].data);
	  if (err == noErr)
	    err = PostEventToQueue (GetMainEventQueue (), event, priority);
	  ReleaseEvent (event);
	}
    }
}

/* Pop up the menu for frame F defined by FIRST_WV at X/Y and loop until the
   menu pops down.  Return the selection.  */

int
create_and_show_popup_menu (struct frame *f, widget_value *first_wv, int x, int y,
			    bool for_click)
{
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Popup"];
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);
  struct mac_display_info *dpyinfo = FRAME_DISPLAY_INFO (f);
  EmacsFrameController *focusFrameController =
    dpyinfo->x_focus_frame ? FRAME_CONTROLLER (dpyinfo->x_focus_frame) : nil;

  [menu setAutoenablesItems:NO];
  [menu fillWithWidgetValue:first_wv->contents];

  mac_menu_set_in_use (true);
  mac_track_menu_with_block (^{
  [focusFrameController noteLeaveEmacsView];
  [frameController popUpMenu:menu atLocationInEmacsView:(NSMakePoint (x, y))];
  [focusFrameController noteEnterEmacsView];
    });
  mac_menu_set_in_use (false);

  /* Must reset this manually because the button release event is not
     passed to Emacs event loop. */
  FRAME_DISPLAY_INFO (f)->grabbed = 0;
  MRC_RELEASE (menu);

  return [emacsController getAndClearMenuItemSelection];
}


/************************************************************************
			     Popup Dialog
 ************************************************************************/

@implementation EmacsDialogView

#define DIALOG_BUTTON_BORDER (6)
#define DIALOG_TEXT_BORDER (1)

#define EMACS_TOUCH_BAR_ITEM_IDENTIFIER_DIALOG \
  (@"EmacsTouchBarItemIdentifierDialog")

- (BOOL)acceptsFirstResponder
{
  return YES;
}

- (BOOL)isFlipped
{
  return YES;
}

- (instancetype)initWithWidgetValue:(widget_value *)wv
{
  const char *dialog_name;
  int nb_buttons, first_group_count, i;
  CGFloat buttons_height, text_height, inner_width, inner_height;
  NSString *message;
  NSRect frameRect;
  NSButton * __unsafe_unretained *buttons;
  NSButton *defaultButton = nil;
  NSTextField *text;
  NSImageView *icon;

  self = [self init];

  if (self == nil)
    return nil;

  dialog_name = wv->name;
  nb_buttons = dialog_name[1] - '0';
  first_group_count = nb_buttons - (dialog_name[4] - '0');

  wv = wv->contents;
  message = [NSString stringWithUTF8String:wv->value fallback:YES];

  wv = wv->next;

  buttons = ((NSButton * __unsafe_unretained *)
	     alloca (sizeof (NSButton *) * nb_buttons));

  for (i = 0; i < nb_buttons; i++)
    {
      NSButton *button = [[NSButton alloc] init];
      NSString *label = [NSString stringWithUTF8String:wv->value fallback:YES];

      [self addSubview:button];
      MRC_RELEASE (button);

      [button setBezelStyle:NSBezelStyleRounded];
      [button setFont:[NSFont systemFontOfSize:0]];
      [button setTitle:label];

      [button setEnabled:wv->enabled];
      if (defaultButton == nil)
	defaultButton = button;

      [button sizeToFit];
      frameRect = [button frame];
      if (frameRect.size.width < (DIALOG_BUTTON_MIN_WIDTH
				  + DIALOG_BUTTON_BORDER * 2))
	frameRect.size.width = (DIALOG_BUTTON_MIN_WIDTH
				+ DIALOG_BUTTON_BORDER * 2);
      else if (frameRect.size.width > (DIALOG_MAX_INNER_WIDTH
				       + DIALOG_BUTTON_BORDER * 2))
	frameRect.size.width = (DIALOG_MAX_INNER_WIDTH
				+ DIALOG_BUTTON_BORDER * 2);
      [button setFrameSize:frameRect.size];

      [button setTag:((NSInteger) (intptr_t) wv->call_data)];
      [button setTarget:self];
      [button setAction:@selector(stopModalWithTagAsCode:)];

      buttons[i] = button;
      wv = wv->next;
    }

  /* Layout buttons.  [buttons[i] frame] is set relative to the
     bottom-right corner of the inner box.  */
  {
    CGFloat bottom, right, max_height, left_align_shift;
    CGFloat button_cell_width, button_cell_height;
    NSButton *button;

    inner_width = DIALOG_MIN_INNER_WIDTH;
    bottom = right = max_height = 0;

    for (i = 0; i < nb_buttons; i++)
      {
	button = buttons[i];
	frameRect = [button frame];
	button_cell_width = NSWidth (frameRect) - DIALOG_BUTTON_BORDER * 2;
	button_cell_height = NSHeight (frameRect) - DIALOG_BUTTON_BORDER * 2;
	if (right - button_cell_width < - inner_width)
	  {
	    if (i != first_group_count
		&& right - button_cell_width >= - DIALOG_MAX_INNER_WIDTH)
	      inner_width = - (right - button_cell_width);
	    else
	      {
		bottom -= max_height + DIALOG_BUTTON_BUTTON_VERTICAL_SPACE;
		right = max_height = 0;
	      }
	  }
	if (max_height < button_cell_height)
	  max_height = button_cell_height;
	frameRect.origin = NSMakePoint ((right - button_cell_width
					 - DIALOG_BUTTON_BORDER),
					(bottom - button_cell_height
					 - DIALOG_BUTTON_BORDER));
	[button setFrameOrigin:frameRect.origin];
	right = (NSMinX (frameRect) + DIALOG_BUTTON_BORDER
		 - DIALOG_BUTTON_BUTTON_HORIZONTAL_SPACE);
	if (i == first_group_count - 1)
	  right -= DIALOG_BUTTON_BUTTON_HORIZONTAL_SPACE;
      }
    buttons_height = - (bottom - max_height);

    left_align_shift = - (inner_width + NSMinX (frameRect)
			  + DIALOG_BUTTON_BORDER);
    for (i = nb_buttons - 1; i >= first_group_count; i--)
      {
	button = buttons[i];
	frameRect = [button frame];

	if (bottom != NSMaxY (frameRect) - DIALOG_BUTTON_BORDER)
	  {
	    left_align_shift = - (inner_width + NSMinX (frameRect)
				  + DIALOG_BUTTON_BORDER);
	    bottom = NSMaxY (frameRect) - DIALOG_BUTTON_BORDER;
	  }
	frameRect.origin.x += left_align_shift;
	[button setFrameOrigin:frameRect.origin];
      }
  }

  /* Create a static text control and measure its bounds.  */
  frameRect = NSMakeRect (0, 0, inner_width + DIALOG_TEXT_BORDER * 2, 0);
  text = [[NSTextField alloc] initWithFrame:frameRect];

  [self addSubview:text];
  MRC_RELEASE (text);

  [text setFont:[NSFont systemFontOfSize:0]];
  [text setStringValue:message];
  [text setDrawsBackground:NO];
  [text setSelectable:NO];
  [text setBezeled:NO];

  [text sizeToFit];
  frameRect = [text frame];
  text_height = NSHeight (frameRect) - DIALOG_TEXT_BORDER * 2;
  if (text_height < DIALOG_TEXT_MIN_HEIGHT)
    text_height = DIALOG_TEXT_MIN_HEIGHT;

  /* Place buttons. */
  inner_height = (text_height + DIALOG_TEXT_BUTTONS_VERTICAL_SPACE
		  + buttons_height);
  for (i = 0; i < nb_buttons; i++)
    {
      NSButton *button = buttons[i];

      frameRect = [button frame];
      frameRect.origin.x += DIALOG_LEFT_MARGIN + inner_width;
      frameRect.origin.y += DIALOG_TOP_MARGIN + inner_height;
      [button setFrameOrigin:frameRect.origin];
    }

  /* Place text.  */
  frameRect = NSMakeRect (DIALOG_LEFT_MARGIN - DIALOG_TEXT_BORDER,
			  DIALOG_TOP_MARGIN - DIALOG_TEXT_BORDER,
			  inner_width + DIALOG_TEXT_BORDER * 2,
			  text_height + DIALOG_TEXT_BORDER * 2);
  [text setFrame:frameRect];

  /* Create the application icon at the upper-left corner.  */
  frameRect = NSMakeRect (DIALOG_ICON_LEFT_MARGIN, DIALOG_ICON_TOP_MARGIN,
			  DIALOG_ICON_WIDTH, DIALOG_ICON_HEIGHT);
  icon = [[NSImageView alloc] initWithFrame:frameRect];
  [self addSubview:icon];
  MRC_RELEASE (icon);
  [icon setImage:[NSImage imageNamed:@"NSApplicationIcon"]];

  [defaultButton setKeyEquivalent:@"\r"];

  frameRect =
    NSMakeRect (0, 0,
		DIALOG_LEFT_MARGIN + inner_width + DIALOG_RIGHT_MARGIN,
		DIALOG_TOP_MARGIN + inner_height + DIALOG_BOTTOM_MARGIN);
  [self setFrame:frameRect];

  return self;
}

- (void)stopModalWithTagAsCode:(id)sender
{
  [NSApp stopModalWithCode:[sender tag]];
}

/* Pop down if escape or quit key is pressed.  */

- (BOOL)performKeyEquivalent:(NSEvent *)theEvent
{
  BOOL quit = NO;

  if ([theEvent type] == NSEventTypeKeyDown)
    {
      NSString *characters = [theEvent characters];

      if ([characters length] == 1
	  && ([characters characterAtIndex:0] == '\033'
	      || mac_keydown_cgevent_quit_p ([theEvent coreGraphicsEvent])))
	quit = YES;
    }

  if (quit)
    {
      [NSApp stopModal];

      return YES;
    }

  return [super performKeyEquivalent:theEvent];
}

- (NSTouchBar *)makeTouchBar
{
  NSTouchBar *touchBar = [[NS_TOUCH_BAR alloc] init];

  touchBar.delegate = self;
  touchBar.defaultItemIdentifiers =
    [NSArray arrayWithObject:EMACS_TOUCH_BAR_ITEM_IDENTIFIER_DIALOG];
  touchBar.principalItemIdentifier = EMACS_TOUCH_BAR_ITEM_IDENTIFIER_DIALOG;

  return MRC_AUTORELEASE (touchBar);
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar
       makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier
{
  NSTouchBarItem *result = nil;

  if ([identifier isEqualToString:EMACS_TOUCH_BAR_ITEM_IDENTIFIER_DIALOG])
    {
      NSMutableArrayOf (NSView *) *touchButtons;
      NSScrollView *scrollView;
      NSStackView *stackView;
      NSView *contentView;
      NSCustomTouchBarItem *item;

      touchButtons = [NSMutableArray arrayWithCapacity:self.subviews.count];
      for (NSButton *button in self.subviews)
	if ([button isKindOfClass:NSButton.class] && button.isEnabled)
	  {
	    NSButton *touchButton = [NSButton buttonWithTitle:button.title
						       target:button.target
						       action:button.action];

	    touchButton.tag = button.tag;
	    touchButton.keyEquivalent = button.keyEquivalent;
	    touchButton.translatesAutoresizingMaskIntoConstraints = NO;
	    [touchButton.widthAnchor
		constraintLessThanOrEqualToConstant:120].active = YES;
	    [touchButtons insertObject:touchButton atIndex:0];
	  }

      scrollView = [[NSScrollView alloc] init];
      stackView = [NS_STACK_VIEW stackViewWithViews:touchButtons];
      scrollView.documentView = stackView;
      contentView = scrollView.contentView;
      [stackView.trailingAnchor
	  constraintEqualToAnchor:contentView.trailingAnchor].active = YES;
      [stackView.widthAnchor
	  constraintGreaterThanOrEqualToAnchor:contentView.widthAnchor].active =
	YES;
      [stackView.topAnchor
	  constraintEqualToAnchor:contentView.topAnchor].active = YES;
      [stackView.bottomAnchor
	  constraintEqualToAnchor:contentView.bottomAnchor].active = YES;

      item = [[NS_CUSTOM_TOUCH_BAR_ITEM alloc] initWithIdentifier:identifier];
      item.view = scrollView;
      MRC_RELEASE (scrollView);
      result = MRC_AUTORELEASE (item);
    }

  return result;
}

@end				// EmacsDialogView

static void
pop_down_dialog (Lisp_Object arg)
{
  NSPanel *panel;
  NSModalSession session;

  memcpy (&session, SDATA (XSAVE_OBJECT (arg, 2)), sizeof (NSModalSession));

  block_input ();

  panel = CF_BRIDGING_RELEASE (XSAVE_POINTER (arg, 1));
  mac_within_gui_allowing_inner_lisp (^{
      [panel close];
      [NSApp endModalSession:session];
    });
  mac_menu_set_in_use (false);

  unblock_input ();
}

/* Pop up the dialog for frame F defined by FIRST_WV and loop until the
   dialog pops down.  Return the selection.  */

int
create_and_show_dialog (struct frame *f, widget_value *first_wv)
{
  int __block result = 0;
  CFTypeRef __block cfpanel;
  NSPanel * __unsafe_unretained __block panel;

  mac_within_gui (^{
      EmacsDialogView *dialogView =
	[[EmacsDialogView alloc] initWithWidgetValue:first_wv];

      cfpanel =
	CF_BRIDGING_RETAIN (MRC_AUTORELEASE
			    ([[NSPanel alloc]
			       initWithContentRect:[dialogView frame]
					 styleMask:NSWindowStyleMaskTitled
					   backing:NSBackingStoreBuffered
					     defer:YES]));
      panel = (__bridge NSPanel *) cfpanel;

      NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
      NSRect panelFrame, windowFrame, visibleFrame;

      panelFrame = [panel frame];
      windowFrame = [window frame];
      panelFrame.origin.x = floor (windowFrame.origin.x
				   + (NSWidth (windowFrame)
				      - NSWidth (panelFrame)) * 0.5f);
      if (NSHeight (panelFrame) < NSHeight (windowFrame))
	panelFrame.origin.y = floor (windowFrame.origin.y
				     + (NSHeight (windowFrame)
					- NSHeight (panelFrame)) * 0.8f);
      else
	panelFrame.origin.y = NSMaxY (windowFrame) - NSHeight (panelFrame);

      visibleFrame = [[window screen] visibleFrame];
      if (NSMaxX (panelFrame) > NSMaxX (visibleFrame))
	panelFrame.origin.x -= NSMaxX (panelFrame) - NSMaxX (visibleFrame);
      if (NSMinX (panelFrame) < NSMinX (visibleFrame))
	panelFrame.origin.x += NSMinX (visibleFrame) - NSMinX (panelFrame);
      if (NSMinY (panelFrame) < NSMinY (visibleFrame))
	panelFrame.origin.y += NSMinY (visibleFrame) - NSMinY (panelFrame);
      if (NSMaxY (panelFrame) > NSMaxY (visibleFrame))
	panelFrame.origin.y -= NSMaxY (panelFrame) - NSMaxY (visibleFrame);

      [panel setFrameOrigin:panelFrame.origin];
      [panel setContentView:dialogView];
      MRC_RELEASE (dialogView);
#if USE_ARC
      dialogView = nil;
      window = nil;
#endif
      [panel setTitle:(first_wv->name[0] == 'Q'
		       ? @"Question" : @"Information")];
      if ([panel respondsToSelector:@selector(setAnimationBehavior:)])
	[panel setAnimationBehavior:NSWindowAnimationBehaviorAlertPanel];
      [panel makeKeyAndOrderFront:nil];
    });

  mac_menu_set_in_use (true);
  {
    NSModalSession __block session;
    mac_within_gui_allowing_inner_lisp (^{
	session = [NSApp beginModalSessionForWindow:panel];
      });
    Lisp_Object session_obj =
      make_unibyte_string ((char *) &session, sizeof (NSModalSession));
    ptrdiff_t specpdl_count = SPECPDL_INDEX ();
    NSModalResponse __block response;

    record_unwind_protect (pop_down_dialog,
			   make_save_funcptr_ptr_obj (NULL, (void *) cfpanel,
						      session_obj));
    do
      {
	struct timespec next_time = timer_check ();

	mac_within_gui_allowing_inner_lisp (^{
	    NSDate *expiration;

	    if (timespec_valid_p (next_time))
	      expiration = [NSDate dateWithTimeIntervalSinceNow:(timespectod
								 (next_time))];
	    else
	      expiration = [NSDate distantFuture];

	    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
				     beforeDate:expiration];

	    /* This is necessary on 10.5 to make the dialog visible
	       when the user tries logout/shutdown.  */
	    [panel makeKeyAndOrderFront:nil];
	    response = [NSApp runModalSession:session];
	    if (response >= 0)
	      result = response;
	  });
      }
    while (response == NSModalResponseContinue);

    unbind_to (specpdl_count, Qnil);
  }

  return result;
}


/************************************************************************
			       Printing
 ************************************************************************/

@implementation EmacsPrintProxyView

- (instancetype)initWithViews:(NSArrayOf (NSView *) *)theViews
{
  CGFloat width = 0, height = 0;

  for (NSView *view in theViews)
    {
      NSRect rect = [view visibleRect];

      if (width < NSWidth (rect))
	width = NSWidth (rect);
      height += NSHeight (rect);
    }

  self = [self initWithFrame:NSMakeRect (0, 0, width, height)];
  if (self == nil)
    return nil;

  views = [theViews copy];

  return self;
}

#if !USE_ARC
- (void)dealloc
{
  MRC_RELEASE (views);
  [super dealloc];
}
#endif

- (void)print:(id)sender
{
  mac_within_app (^{
      [[NSPrintOperation printOperationWithView:self] runOperation];
    });
}

- (BOOL)knowsPageRange:(NSRangePointer)range
{
  range->location = 1;
  range->length = [views count];

  return YES;
}

- (NSRect)rectForPage:(NSInteger)page
{
  NSRect rect = [[views objectAtIndex:(page - 1)] visibleRect];
  NSInteger i;

  rect.origin = NSZeroPoint;
  for (i = 0; i < page - 1; i++)
    rect.origin.y += NSHeight ([[views objectAtIndex:i] visibleRect]);

  return rect;
}

- (void)drawRect:(NSRect)aRect
{
  CGFloat y = 0;
  NSInteger i = 0, pageCount = [views count];

  while (y < NSMinY (aRect) && i < pageCount)
    {
      NSView *view = [views objectAtIndex:i++];

      y += NSHeight ([view visibleRect]);
    }
  while (y < NSMaxY (aRect) && i < pageCount)
    {
      NSView *view = [views objectAtIndex:i++];
      NSRect rect = [view visibleRect];
      NSGraphicsContext *gcontext = NSGraphicsContext.currentContext;
      NSAffineTransform *transform = [NSAffineTransform transform];

      [gcontext saveGraphicsState];
      [transform translateXBy:(- NSMinX (rect)) yBy:(y - NSMinY (rect))];
      [transform concat];
      [EmacsView globallyDisableUpdateLayer:YES];
      [view displayRectIgnoringOpacity:rect inContext:gcontext];
      [EmacsView globallyDisableUpdateLayer:NO];
      [gcontext restoreGraphicsState];
      y += NSHeight ([view visibleRect]);
    }
}

@end				// EmacsPrintProxyView

static void
mac_cgcontext_release (Lisp_Object arg)
{
  CGContextRef context = (CGContextRef) XSAVE_POINTER (arg, 0);

  block_input ();
  CGContextRelease (context);
  unblock_input ();
}

Lisp_Object
mac_export_frames (Lisp_Object frames, Lisp_Object type)
{
  Lisp_Object result = Qnil;
  struct frame *f;
  NSWindow *window;
  NSView *contentView;
  int count = SPECPDL_INDEX ();

  specbind (Qredisplay_dont_pause, Qt);
  redisplay_preserve_echo_area (31);

  f = XFRAME (XCAR (frames));
  frames = XCDR (frames);

  block_input ();
  window = FRAME_MAC_WINDOW_OBJECT (f);
  contentView = [window contentView];
  if (EQ (type, Qpng))
    {
      EmacsFrameController *frameController = FRAME_CONTROLLER (f);
      Lisp_Object __block string = Qnil;

      mac_within_gui (^{
	  NSBitmapImageRep *bitmap = [frameController bitmapImageRep];
	  NSData *data =
	    [bitmap representationUsingType:NSBitmapImageFileTypePNG
				 properties:[NSDictionary dictionary]];

	  if (data)
	    string = [data lispString];
	});
      result = string;
    }
  else if (EQ (type, Qpdf))
    {
      CGContextRef context = NULL;
      NSMutableData *data = [NSMutableData dataWithCapacity:0];
      CGDataConsumerRef consumer =
	CGDataConsumerCreateWithCFData ((__bridge CFMutableDataRef) data);
      CGRect __block mediaBox;

      mac_within_gui (^{
	  mediaBox = NSRectToCGRect ([contentView visibleRect]);
	});
      if (consumer)
	{
	  context = CGPDFContextCreate (consumer, &mediaBox, NULL);
	  CGDataConsumerRelease (consumer);
	}
      if (context)
	{
	  record_unwind_protect (mac_cgcontext_release,
				 make_save_ptr (context));
	  while (1)
	    {
	      mac_within_gui (^{
		  CGRect mediaBox = NSRectToCGRect ([contentView visibleRect]);
		  NSData *mediaBoxData =
		    [NSData dataWithBytes:&mediaBox length:(sizeof (CGRect))];
		  NSDictionary *pageInfo =
		    [NSDictionary dictionaryWithObject:mediaBoxData
						forKey:((__bridge NSString *)
							kCGPDFContextMediaBox)];
		  NSGraphicsContext *gcontext =
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
		    [NSGraphicsContext graphicsContextWithCGContext:context
							    flipped:NO];
#else
		    [NSGraphicsContext graphicsContextWithGraphicsPort:context
							       flipped:NO];
#endif

		  CGPDFContextBeginPage (context,
					 (__bridge CFDictionaryRef) pageInfo);
		  [EmacsView globallyDisableUpdateLayer:YES];
		  [contentView
		    displayRectIgnoringOpacity:(NSRectFromCGRect (mediaBox))
				     inContext:gcontext];
		  [EmacsView globallyDisableUpdateLayer:NO];
		  CGPDFContextEndPage (context);
		});

	      if (NILP (frames))
		break;

	      f = XFRAME (XCAR (frames));
	      frames = XCDR (frames);
	      window = FRAME_MAC_WINDOW_OBJECT (f);
	      contentView = [window contentView];

	      unblock_input ();
	      maybe_quit ();
	      block_input ();
	    }

	  CGPDFContextClose (context);
	  result = [data lispString];
	}
    }
  unblock_input ();

  unbind_to (count, Qnil);

  return result;
}

void
mac_page_setup_dialog (void)
{
  mac_menu_set_in_use (true);
  mac_within_gui_allowing_inner_lisp (^{
      mac_within_app (^{[[NSPageLayout pageLayout] runModal];});
    });
  mac_menu_set_in_use (false);
}

Lisp_Object
mac_get_page_setup (void)
{
  NSPrintInfo *printInfo = [NSPrintInfo sharedPrintInfo];
  NSSize paperSize = [printInfo paperSize];
  NSPaperOrientation orientation = [printInfo orientation];
  CGFloat leftMargin, rightMargin, topMargin, bottomMargin;
  CGFloat pageWidth, pageHeight;
  Lisp_Object orientation_symbol;

  leftMargin = [printInfo leftMargin];
  rightMargin = [printInfo rightMargin];
  topMargin = [printInfo topMargin];
  bottomMargin = [printInfo bottomMargin];

  if (orientation == NSPaperOrientationPortrait)
    {
      orientation_symbol = Qportrait;
      pageWidth = paperSize.width - leftMargin - rightMargin;
      pageHeight = paperSize.height - topMargin - bottomMargin;
    }
  else
    {
      orientation_symbol = Qlandscape;
      pageWidth = paperSize.width - topMargin - bottomMargin;
      pageHeight = paperSize.height - leftMargin - rightMargin;
    }

  return listn (CONSTYPE_HEAP, 7,
		Fcons (Qorientation, orientation_symbol),
		Fcons (Qwidth, make_float (pageWidth)),
		Fcons (Qheight, make_float (pageHeight)),
		Fcons (Qleft_margin, make_float (leftMargin)),
		Fcons (Qright_margin, make_float (rightMargin)),
		Fcons (Qtop_margin, make_float (topMargin)),
		Fcons (Qbottom_margin, make_float (bottomMargin)));
}

void
mac_print_frames_dialog (Lisp_Object frames)
{
  EmacsPrintProxyView * __block printProxyView;
  NSMutableArrayOf (NSView *) *views = [NSMutableArray arrayWithCapacity:0];

  while (!NILP (frames))
    {
      struct frame *f = XFRAME (XCAR (frames));
      NSWindow *window = FRAME_MAC_WINDOW_OBJECT (f);
      NSView *contentView = [window contentView];

      [views addObject:contentView];
      frames = XCDR (frames);
    }

  mac_within_gui (^{
      printProxyView = [[EmacsPrintProxyView alloc] initWithViews:views];
    });
  mac_menu_set_in_use (true);
  mac_within_gui_allowing_inner_lisp (^{[printProxyView print:nil];});
  mac_menu_set_in_use (false);
  MRC_RELEASE (printProxyView);
}


/************************************************************************
			  Selection support
 ************************************************************************/

/* Get a reference to the selection corresponding to the symbol SYM.
   The reference is set to *SEL, and it becomes NULL if there's no
   corresponding selection.  Clear the selection if CLEAR_P is
   true.  */

OSStatus
mac_get_selection_from_symbol (Lisp_Object sym, bool clear_p, Selection *sel)
{
  Lisp_Object str = Fget (sym, Qmac_pasteboard_name);

  if (!STRINGP (str))
    *sel = NULL;
  else
    {
      NSPasteboardName name = [NSString stringWithUTF8LispString:str];

      *sel = (__bridge Selection) [NSPasteboard pasteboardWithName:name];
      if (clear_p)
	[(__bridge NSPasteboard *)*sel declareTypes:[NSArray array] owner:nil];
    }

  return noErr;
}

/* Get a pasteboard data type from the symbol SYM.  Return nil if no
   corresponding data type.  If SEL is non-zero, the return value is
   non-zero only when the SEL has the data type.  */

static NSPasteboardType
get_pasteboard_data_type_from_symbol (Lisp_Object sym, Selection sel)
{
  Lisp_Object str = Fget (sym, Qmac_pasteboard_data_type);
  NSPasteboardType dataType;

  if (STRINGP (str))
    dataType = [NSString stringWithUTF8LispString:str];
  else
    dataType = nil;

  if (dataType && sel)
    {
      NSArrayOf (NSPasteboardType) *array = [NSArray arrayWithObject:dataType];

      dataType = [(__bridge NSPasteboard *)sel availableTypeFromArray:array];
    }

  return dataType;
}

/* Check if the symbol SYM has a corresponding selection target type.  */

bool
mac_valid_selection_target_p (Lisp_Object sym)
{
  return STRINGP (Fget (sym, Qmac_pasteboard_data_type));
}

/* Clear the selection whose reference is *SEL.  */

OSStatus
mac_clear_selection (Selection *sel)
{
  [(__bridge NSPasteboard *)*sel declareTypes:[NSArray array] owner:nil];

  return noErr;
}

/* Get ownership information for SEL.  Emacs can detect a change of
   the ownership by comparing saved and current values of the
   ownership information.  */

Lisp_Object
mac_get_selection_ownership_info (Selection sel)
{
  return INTEGER_TO_CONS ([(__bridge NSPasteboard *)sel changeCount]);
}

/* Return true if VALUE is a valid selection value for TARGET.  */

bool
mac_valid_selection_value_p (Lisp_Object value, Lisp_Object target)
{
  return STRINGP (value);
}

/* Put Lisp object VALUE to the selection SEL.  The target type is
   specified by TARGET. */

OSStatus
mac_put_selection_value (Selection sel, Lisp_Object target, Lisp_Object value)
{
  NSPasteboardType dataType =
    get_pasteboard_data_type_from_symbol (target, nil);
  NSPasteboard *pboard = (__bridge NSPasteboard *)sel;

  if (dataType == nil)
    return noTypeErr;

  [pboard addTypes:[NSArray arrayWithObject:dataType] owner:nil];

  if (dataType == nil)
    return noTypeErr;
  else
    {
      NSData *data = [NSData dataWithBytes:(SDATA (value))
				    length:(SBYTES (value))];

      return [pboard setData:data forType:dataType] ? noErr : noTypeErr;
    }
}

/* Check if data for the target type TARGET is available in SEL.  */

bool
mac_selection_has_target_p (Selection sel, Lisp_Object target)
{
  return get_pasteboard_data_type_from_symbol (target, sel) != nil;
}

/* Get data for the target type TARGET from SEL and create a Lisp
   object.  Return nil if failed to get data.  */

Lisp_Object
mac_get_selection_value (Selection sel, Lisp_Object target)
{
  Lisp_Object result = Qnil;
  NSPasteboardType dataType =
    get_pasteboard_data_type_from_symbol (target, sel);

  if (dataType)
    {
      NSData *data = [(__bridge NSPasteboard *)sel dataForType:dataType];

      if (data)
	result = [data lispString];
    }

  return result;
}

/* Get the list of target types in SEL.  The return value is a list of
   target type symbols possibly followed by pasteboard data type
   strings.  */

Lisp_Object
mac_get_selection_target_list (Selection sel)
{
  Lisp_Object result = Qnil, rest, target, strings = Qnil;
  NSArrayOf (NSPasteboardType) *types = [(__bridge NSPasteboard *)sel types];
  NSMutableSetOf (NSPasteboardType) *typeSet;
  NSPasteboardType dataType;

  typeSet = [NSMutableSet setWithCapacity:[types count]];
  [typeSet addObjectsFromArray:types];

  for (rest = Vselection_converter_alist; CONSP (rest); rest = XCDR (rest))
    if (CONSP (XCAR (rest))
	&& (target = XCAR (XCAR (rest)),
	    SYMBOLP (target))
	&& (dataType = get_pasteboard_data_type_from_symbol (target, sel)))
      {
	result = Fcons (target, result);
	[typeSet removeObject:dataType];
      }

  for (NSPasteboardType dataType in typeSet)
    strings = Fcons ([dataType UTF8LispString], strings);
  result = nconc2 (result, strings);

  return result;
}


/************************************************************************
			 Apple event support
 ************************************************************************/

static NSMutableSetOf (NSNumber *) *registered_apple_event_specs;

@implementation NSAppleEventDescriptor (Emacs)

- (OSErr)copyDescTo:(AEDesc *)desc
{
  return AEDuplicateDesc ([self aeDesc], desc);
}

@end				// NSAppleEventDescriptor (Emacs)

@implementation EmacsController (AppleEvent)

- (void)handleAppleEvent:(NSAppleEventDescriptor *)event
	  withReplyEvent:(NSAppleEventDescriptor *)replyEvent
{
  OSErr err;
  AEDesc reply;

  err = [replyEvent copyDescTo:&reply];
  if (err == noErr)
    {
      const AEDesc *event_ptr = [event aeDesc];

      if (event_ptr)
	err = mac_handle_apple_event (event_ptr, &reply, 0);
      AEDisposeDesc (&reply);
    }
}

@end				// EmacsController (AppleEvent)

/* Register pairs of Apple event class and ID in mac_apple_event_map
   if they have not registered yet.  Each registered pair is stored in
   registered_apple_event_specs as a unsigned long long value whose
   upper and lower half stand for class and ID, respectively.  */

static void
update_apple_event_handler (void)
{
  Lisp_Object keymap = get_keymap (Vmac_apple_event_map, 0, 0);

  if (NILP (keymap))
    return;

  mac_map_keymap (keymap, false, ^(Lisp_Object key, Lisp_Object binding) {
      if (!SYMBOLP (key))
	return;
      AEEventClass eventClass;
      if (!mac_string_to_four_char_code (Fget (key, Qmac_apple_event_class),
					 &eventClass))
	return;
      Lisp_Object keymap = get_keymap (binding, 0, 0);
      if (NILP (keymap))
	return;

      mac_map_keymap (keymap, false, ^(Lisp_Object key, Lisp_Object binding) {
	  if (NILP (binding) || EQ (binding, Qundefined) || !SYMBOLP (key))
	    return;
	  AEEventID eventID;
	  if (!mac_string_to_four_char_code (Fget (key, Qmac_apple_event_id),
					     &eventID))
	    return;

	  unsigned long long code =
	    ((unsigned long long) eventClass << 32) + eventID;
	  NSNumber *value = [NSNumber numberWithUnsignedLongLong:code];

	  if (![registered_apple_event_specs containsObject:value])
	    {
	      [[NSAppleEventManager sharedAppleEventManager]
		setEventHandler:emacsController
		    andSelector:@selector(handleAppleEvent:withReplyEvent:)
		  forEventClass:eventClass andEventID:eventID];
	      [registered_apple_event_specs addObject:value];
	    }
	});
    });
}

static void
init_apple_event_handler (void)
{
  /* Force NSScriptSuiteRegistry to initialize here so our custom
     handlers may not be overwritten by lazy initialization.  */
  [NSScriptSuiteRegistry sharedScriptSuiteRegistry];
  registered_apple_event_specs = [[NSMutableSet alloc] initWithCapacity:0];
  update_apple_event_handler ();
  atexit (cleanup_all_suspended_apple_events);
}


/************************************************************************
                      Drag and drop support
 ************************************************************************/

static NSMutableArrayOf (NSPasteboardType) *registered_dragged_types;

@implementation EmacsMainView (DragAndDrop)

- (void)setDragHighlighted:(BOOL)flag
{
  struct frame *f = [self emacsFrame];
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  [frameController setOverlayViewHighlighted:flag];
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
  [self setDragHighlighted:YES];

  return NSDragOperationGeneric;
}

- (void)draggingExited:(id <NSDraggingInfo>)sender
{
  [self setDragHighlighted:NO];
}

/* Convert the NSDragOperation value OPERATION to a list of symbols for
   the corresponding drag actions.  */

static Lisp_Object
drag_operation_to_actions (NSDragOperation operation)
{
  Lisp_Object result = Qnil;

  if (operation & NSDragOperationCopy)
    result = Fcons (Qcopy, result);
  if (operation & NSDragOperationLink)
    result = Fcons (Qlink, result);
  if (operation & NSDragOperationGeneric)
    result = Fcons (Qgeneric, result);
  if (operation & NSDragOperationPrivate)
    result = Fcons (Qprivate, result);
  if (operation & NSDragOperationMove)
    result = Fcons (Qmove, result);
  if (operation & NSDragOperationDelete)
    result = Fcons (Qdelete, result);

  return result;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
  struct frame *f = [self emacsFrame];
  NSPoint point = [self convertPoint:[sender draggingLocation] fromView:nil];
  NSDragOperation operation = [sender draggingSourceOperationMask];
  Lisp_Object items = Qnil, arg;
  BOOL hasItems = NO;

  [self setDragHighlighted:NO];

  for (NSPasteboardItem *pi in [[sender draggingPasteboard] pasteboardItems])
    {
      Lisp_Object item = Qnil;
      /* The elements in -[NSView registeredDraggedTypes] are in no
	 particular order.  */
      NSPasteboardType type =
	[pi availableTypeFromArray:registered_dragged_types];

      if (type)
	{
	  NSData *data = [pi dataForType:type];

	  if (data)
	    {
	      item = Fcons ([type UTF8LispString], [data lispString]);
	      hasItems = YES;
	    }
	}
      items = Fcons (item, items);
    }

  if (!hasItems)
    return NO;

  arg = list2 (QCitems, Fnreverse (items));
  arg = Fcons (QCactions, Fcons (drag_operation_to_actions (operation), arg));

  EVENT_INIT (inputEvent);
  inputEvent.kind = DRAG_N_DROP_EVENT;
  inputEvent.modifiers = 0;
  inputEvent.timestamp = [[NSApp currentEvent] timestamp] * 1000;
  XSETINT (inputEvent.x, point.x);
  XSETINT (inputEvent.y, point.y);
  XSETFRAME (inputEvent.frame_or_window, f);
  inputEvent.arg = arg;
  [self sendAction:action to:target];

  return YES;
}

@end				// EmacsMainView (DragAndDrop)

@implementation EmacsFrameController (DragAndDrop)

- (void)registerEmacsViewForDraggedTypes:(NSArrayOf (NSPasteboardType) *)pboardTypes
{
  [emacsView registerForDraggedTypes:pboardTypes];
}

- (void)setOverlayViewHighlighted:(BOOL)flag
{
  [overlayView setHighlighted:flag];
}

@end				// EmacsFrameController (DragAndDrop)

/* Update the pasteboard types derived from the value of
   mac-dnd-known-types and register them so every Emacs view can
   accept them.  The registered types are stored in
   registered_dragged_types.  */

static void
update_dragged_types (void)
{
  NSMutableArrayOf (NSPasteboardType) *array =
    [[NSMutableArray alloc] initWithCapacity:0];
  Lisp_Object rest, tail, frame;

  for (rest = Vmac_dnd_known_types; CONSP (rest); rest = XCDR (rest))
    if (STRINGP (XCAR (rest)))
      {
	NSPasteboardType typeString =
	  [NSString stringWithUTF8LispString:(XCAR (rest))];

	if (typeString)
	  [array addObject:typeString];
      }

  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);

      if (EQ (frame, tip_frame))
	continue;

      if (FRAME_MAC_P (f))
	{
	  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

	  mac_within_gui (^{
	      [frameController registerEmacsViewForDraggedTypes:array];
	    });
	}
    }

  (void) MRC_AUTORELEASE (registered_dragged_types);
  registered_dragged_types = array;
}

/* Return default value for mac-dnd-known-types.  */

Lisp_Object
mac_dnd_default_known_types (void)
{
  return list3 ([(__bridge NSPasteboardType)kUTTypeURL UTF8LispString],
		[NSPasteboardTypeString UTF8LispString],
		[NSPasteboardTypeTIFF UTF8LispString]);
}


/************************************************************************
			Services menu support
 ************************************************************************/

@implementation EmacsMainView (Services)

- (id)validRequestorForSendType:(NSPasteboardType)sendType
		     returnType:(NSPasteboardType)returnType
{
  Selection sel;
  NSArrayOf (NSPasteboardType) *array;

  if ([sendType length] == 0
      || (!NILP (Fmac_selection_owner_p (Vmac_service_selection, Qnil))
	  && mac_get_selection_from_symbol (Vmac_service_selection, false,
					    &sel) == noErr
	  && sel
	  && (array = [NSArray arrayWithObject:sendType],
	      [(__bridge NSPasteboard *)sel availableTypeFromArray:array])))
    {
      Lisp_Object rest;
      NSPasteboardType dataType;

      if ([returnType length] == 0)
	return self;

      for (rest = Vselection_converter_alist; CONSP (rest);
	   rest = XCDR (rest))
	if (CONSP (XCAR (rest)) && SYMBOLP (XCAR (XCAR (rest)))
	    && (dataType =
		get_pasteboard_data_type_from_symbol (XCAR (XCAR (rest)), nil))
	    && [dataType isEqualToString:returnType])
	  return self;
    }

  return [super validRequestorForSendType:sendType returnType:returnType];
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pboard
			     types:(NSArrayOf (NSPasteboardType) *)types
{
  OSStatus err;
  Selection sel;
  NSPasteboard *servicePboard;
  BOOL result = NO;

  err = mac_get_selection_from_symbol (Vmac_service_selection, false, &sel);
  if (err != noErr || sel == NULL)
    return NO;

  [pboard declareTypes:[NSArray array] owner:nil];

  servicePboard = (__bridge NSPasteboard *) sel;
  for (NSPasteboardType type in [servicePboard types])
    if ([types containsObject:type])
      {
	NSData *data = [servicePboard dataForType:type];

	if (data)
	  {
	    [pboard addTypes:[NSArray arrayWithObject:type] owner:nil];
	    result = [pboard setData:data forType:type] || result;
	  }
      }

  return result;
}

/* Copy whole data of pasteboard PBOARD to the pasteboard specified by
   mac-service-selection.  */

static BOOL
copy_pasteboard_to_service_selection (NSPasteboard *pboard)
{
  OSStatus err;
  Selection sel;
  NSPasteboard *servicePboard;
  BOOL result = NO;

  err = mac_get_selection_from_symbol (Vmac_service_selection, true, &sel);
  if (err != noErr || sel == NULL)
    return NO;

  servicePboard = (__bridge NSPasteboard *) sel;
  [servicePboard declareTypes:[NSArray array] owner:nil];
  for (NSPasteboardType type in [pboard types])
    {
      NSData *data = [pboard dataForType:type];

      if (data)
	{
	  [servicePboard addTypes:[NSArray arrayWithObject:type] owner:nil];
	  result = [servicePboard setData:data forType:type] || result;
	}
    }

  return result;
}

- (BOOL)readSelectionFromPasteboard:(NSPasteboard *)pboard
{
  BOOL result = copy_pasteboard_to_service_selection (pboard);

  if (result)
    {
      OSStatus err;
      EventRef event;

      err = CreateEvent (NULL, kEventClassService, kEventServicePaste, 0,
			 kEventAttributeNone, &event);
      if (err == noErr)
	{
	  err = mac_store_event_ref_as_apple_event (0, 0, Qservice, Qpaste,
						    event, 0, NULL, NULL);
	  ReleaseEvent (event);
	}

      if (err != noErr)
	result = NO;
    }

  return result;
}

@end				// EmacsMainView (Services)

@implementation NSMethodSignature (Emacs)

/* Dummy method.  Just for getting its method signature.  */

- (void)messageName:(NSPasteboard *)pboard
	   userData:(NSString *)userData
	      error:(NSString **)error
{
}

@end				// NSMethodSignature (Emacs)

static BOOL
is_services_handler_selector (SEL selector)
{
  NSString *name = NSStringFromSelector (selector);

  /* The selector name is of the form `MESSAGENAME:userData:error:' ?  */
  if ([name hasSuffix:@":userData:error:"]
      && (NSMaxRange ([name rangeOfString:@":"])
	  == [name length] - (sizeof ("userData:error:") - 1)))
    {
      /* Lookup the binding `[service perform MESSAGENAME]' in
	 mac-apple-event-map.  */
      Lisp_Object tem = get_keymap (Vmac_apple_event_map, 0, 0);

      if (!NILP (tem))
	tem = get_keymap (access_keymap (tem, Qservice, 0, 1, 0), 0, 0);
      if (!NILP (tem))
	tem = get_keymap (access_keymap (tem, Qperform, 0, 1, 0), 0, 0);
      if (!NILP (tem))
	{
	  NSUInteger index = [name length] - (sizeof (":userData:error:") - 1);

	  name = [name substringToIndex:index];
	  tem = access_keymap (tem, intern (SSDATA ([name UTF8LispString])),
			       0, 1, 0);
	}
      if (!NILP (tem) && !EQ (tem, Qundefined))
	return YES;
    }

  return NO;
}

/* Return the method signature of services handlers.  */

static NSMethodSignature *
services_handler_signature (void)
{
  static NSMethodSignature *signature;

  if (signature == nil)
    signature =
      MRC_RETAIN ([NSMethodSignature
		    instanceMethodSignatureForSelector:@selector(messageName:userData:error:)]);

  return signature;
}

static void
handle_services_invocation (NSInvocation *invocation)
{
  NSPasteboard * __unsafe_unretained pboard;
  NSString * __unsafe_unretained userData;
  /* NSString **error; */
  BOOL result;

  [invocation getArgument:&pboard atIndex:2];
  [invocation getArgument:&userData atIndex:3];
  /* [invocation getArgument:&error atIndex:4]; */

  result = copy_pasteboard_to_service_selection (pboard);
  if (result)
    {
      OSStatus err;
      EventRef event;

      err = CreateEvent (NULL, kEventClassService, kEventServicePerform,
			 0, kEventAttributeNone, &event);
      if (err == noErr)
	{
	  static const EventParamName names[] =
	    {kEventParamServiceMessageName, kEventParamServiceUserData};
	  static const EventParamType types[] =
	    {typeCFStringRef, typeCFStringRef};
	  NSString *name = NSStringFromSelector ([invocation selector]);
	  NSUInteger index;

	  index = [name length] - (sizeof (":userData:error:") - 1);
	  name = [name substringToIndex:index];

	  err = SetEventParameter (event, kEventParamServiceMessageName,
				   typeCFStringRef, sizeof (CFStringRef),
				   &name);
	  if (err == noErr)
	    if (userData)
	      err = SetEventParameter (event, kEventParamServiceUserData,
				       typeCFStringRef, sizeof (CFStringRef),
				       &userData);
	  if (err == noErr)
	    err = mac_store_event_ref_as_apple_event (0, 0, Qservice,
						      Qperform, event,
						      ARRAYELTS (names),
						      names, types);
	  ReleaseEvent (event);
	}
    }
}

static void
update_services_menu_types (void)
{
  NSMutableArrayOf (NSPasteboardType) *array =
    [NSMutableArray arrayWithCapacity:0];
  Lisp_Object rest;

  for (rest = Vselection_converter_alist; CONSP (rest);
       rest = XCDR (rest))
    if (CONSP (XCAR (rest)) && SYMBOLP (XCAR (XCAR (rest))))
      {
	NSPasteboardType dataType =
	  get_pasteboard_data_type_from_symbol (XCAR (XCAR (rest)), nil);

	if (dataType)
	  [array addObject:dataType];
      }

  mac_within_gui (^{
      [NSApp registerServicesMenuSendTypes:array returnTypes:array];
    });
}


/************************************************************************
			    Action support
 ************************************************************************/

static BOOL
is_action_selector (SEL selector)
{
  NSString *name = NSStringFromSelector (selector);

  /* The selector name is of the form `ACTIONNAME:' ?  */
  if (NSMaxRange ([name rangeOfString:@":"]) == [name length])
    {
      /* Lookup the binding `[action ACTIONNAME]' in
	 mac-apple-event-map.  */
      Lisp_Object tem = get_keymap (Vmac_apple_event_map, 0, 0);

      if (!NILP (tem))
	tem = get_keymap (access_keymap (tem, Qaction, 0, 1, 0), 0, 0);
      if (!NILP (tem))
	{
	  name = [name substringToIndex:([name length] - 1)];
	  tem = access_keymap (tem, intern (SSDATA ([name UTF8LispString])),
			       0, 1, 0);
	}
      if (!NILP (tem) && !EQ (tem, Qundefined))
	return YES;
    }

  return NO;
}

/* Return the method signature of actions.  */

static NSMethodSignature *
action_signature (void)
{
  static NSMethodSignature *signature;

  if (signature == nil)
    signature =
      MRC_RETAIN ([NSApplication
		    instanceMethodSignatureForSelector:@selector(terminate:)]);

  return signature;
}

static void
handle_action_invocation (NSInvocation *invocation)
{
  id __unsafe_unretained sender;
  Lisp_Object arg = Qnil;
  struct input_event inev;
  NSString *name = NSStringFromSelector ([invocation selector]);
  Lisp_Object name_symbol =
    intern (SSDATA ([[name substringToIndex:([name length] - 1)]
		      UTF8LispString]));
  CGEventFlags flags = (CGEventFlags) [[NSApp currentEvent] modifierFlags];
  UInt32 modifiers = mac_cgevent_flags_to_modifiers (flags);

  arg = Fcons (Fcons (build_string ("kmod"), /* kEventParamKeyModifiers */
		      Fcons (build_string ("magn"), /* typeUInt32 */
			     mac_four_char_code_to_string (modifiers))),
	       arg);

  [invocation getArgument:&sender atIndex:2];

  if (sender)
    {
      Lisp_Object rest;

      for (rest = Fget (name_symbol, Qmac_action_key_paths);
	   CONSP (rest); rest = XCDR (rest))
	if (STRINGP (XCAR (rest)))
	  {
	    NSString *keyPath;
	    id value;
	    Lisp_Object obj;

	    keyPath = [NSString stringWithUTF8LispString:(XCAR (rest))];

	    @try
	      {
		value = [sender valueForKeyPath:keyPath];
	      }
	    @catch (NSException *exception)
	      {
		value = nil;
	      }

	    if (value == nil)
	      continue;
	    obj = cfobject_to_lisp ((__bridge CFTypeRef) value,
				    CFOBJECT_TO_LISP_FLAGS_FOR_EVENT, -1);
	    arg = Fcons (Fcons (XCAR (rest),
				Fcons (build_string ("Lisp"), obj)),
			 arg);
	  }

      if ([sender isKindOfClass:[NSView class]])
	{
	  Lisp_Object frame = [[sender window] lispFrame];

	  if (!NILP (frame))
	    arg = Fcons (Fcons (Qframe,
				Fcons (build_string ("Lisp"), frame)),
			 arg);
	}
    }

  EVENT_INIT (inev);
  inev.kind = MAC_APPLE_EVENT;
  inev.x = Qaction;
  inev.y = name_symbol;
  XSETFRAME (inev.frame_or_window,
	     mac_focus_frame (&one_mac_display_info));
  inev.arg = Fcons (build_string ("aevt"), arg);
  [emacsController storeEvent:&inev];
}

bool
mac_send_action (Lisp_Object symbol, bool dry_run_p)
{
  bool __block result = false;
  AUTO_STRING (colon, ":");
  Lisp_Object string = concat2 (SYMBOL_NAME (symbol), colon);
  SEL action = NSSelectorFromString ([NSString stringWithLispString:string]);

  if (!action)
    return false;

  mac_within_app (^{
      id target = [NSApp targetForAction:action];
      NSMethodSignature *signature = [target methodSignatureForSelector:action];

      if ([signature isEqual:(action_signature ())]
	  && [target respondsToSelector:@selector(validateUserInterfaceItem:)])
	{
	  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:action
						 keyEquivalent:@""];

	  if ([target validateUserInterfaceItem:item])
	    {
	      if (dry_run_p)
		result = true;
	      else
		result = [NSApp sendAction:action to:target from:nil];
	    }
	  MRC_RELEASE (item);
	}
    });

  return result;
}


/************************************************************************
		 Open Scripting Architecture support
 ************************************************************************/

@implementation EmacsOSAScript

- (NSAppleEventDescriptor *)executeAndReturnError:(NSDictionaryOf (NSString *, id) **)errorInfo
{
  if (inhibit_window_system)
    return [super executeAndReturnError:errorInfo];
  else
    {
      NSAppleEventDescriptor * __block result;
      NSDictionaryOf (NSString *, id) * __block errorInfo1;

      mac_within_gui_allowing_inner_lisp (^{
	  mac_within_app (^{
	      result = [super executeAndReturnError:&errorInfo1];
#if !USE_ARC
	      if (result == nil)
		[errorInfo1 retain];
	      [result retain];
#endif
	    });
	});

      if (result == nil)
	*errorInfo = MRC_AUTORELEASE (errorInfo1);

      return MRC_AUTORELEASE (result);
    }
}

- (NSAppleEventDescriptor *)executeAndReturnDisplayValue:(NSAttributedString **)displayValue error:(NSDictionaryOf (NSString *, id) **)errorInfo
{
  if (inhibit_window_system)
    return [super executeAndReturnDisplayValue:displayValue error:errorInfo];
  else
    {
      NSAppleEventDescriptor * __block result;
      NSAttributedString * __block displayValue1;
      NSDictionaryOf (NSString *, id) * __block errorInfo1;

      mac_within_gui_allowing_inner_lisp (^{
	  mac_within_app (^{
	      result = [super executeAndReturnDisplayValue:&displayValue1
						     error:&errorInfo1];
#if !USE_ARC
	      if (result)
		[displayValue1 retain];
	      else
		[errorInfo1 retain];
	      [result retain];
#endif
	    });
	});

      if (result)
	*displayValue = MRC_AUTORELEASE (displayValue1);
      else
	*errorInfo = MRC_AUTORELEASE (errorInfo1);

      return MRC_AUTORELEASE (result);
    }
}

- (NSAppleEventDescriptor *)executeAppleEvent:(NSAppleEventDescriptor *)event error:(NSDictionaryOf (NSString *, id) **)errorInfo
{
  if (inhibit_window_system)
    return [super executeAppleEvent:event error:errorInfo];
  else
    {
      NSAppleEventDescriptor * __block result;
      NSDictionaryOf (NSString *, id) * __block errorInfo1;

      mac_within_gui_allowing_inner_lisp (^{
	  mac_within_app (^{
	      result = [super executeAppleEvent:event error:&errorInfo1];
#if !USE_ARC
	      if (result == nil)
		[errorInfo1 retain];
	      [result retain];
#endif
	    });
	});

      if (result == nil)
	*errorInfo = MRC_AUTORELEASE (errorInfo1);

      return MRC_AUTORELEASE (result);
    }
}

- (BOOL)compileAndReturnError:(NSDictionaryOf (NSString *, id) **)errorInfo
{
  if (pthread_main_np ())
    return [super compileAndReturnError:errorInfo];
  else
    {
      BOOL __block result;
      NSDictionaryOf (NSString *, id) * __block errorInfo1;

      mac_within_gui (^{
	  result = [super compileAndReturnError:&errorInfo1];
#if !USE_ARC
	  if (!result)
	    [errorInfo1 retain];
#endif
	});

      if (!result)
	*errorInfo = MRC_AUTORELEASE (errorInfo1);

      return result;
    }
}

- (NSData *)compiledDataForType:(NSString *)type
	    usingStorageOptions:(OSAStorageOptions)storageOptions
			  error:(NSDictionaryOf (NSString *, id) **)errorInfo
{
  if (pthread_main_np ())
    return [super compiledDataForType:type
		  usingStorageOptions:storageOptions error:errorInfo];
  else
    {
      NSData * __block result;
      NSDictionaryOf (NSString *, id) * __block errorInfo1;

      mac_within_gui (^{
	  result = [super compiledDataForType:type
			  usingStorageOptions:storageOptions error:&errorInfo1];
#if !USE_ARC
	  if (result == nil)
	    [errorInfo1 retain];
	  [result retain];
#endif
	});

      if (result == nil)
	*errorInfo = MRC_AUTORELEASE (errorInfo1);

      return MRC_AUTORELEASE (result);
    }
}

@end				// EmacsOSAScript

Lisp_Object
mac_osa_language_list (bool long_format_p)
{
  Lisp_Object result = Qnil, default_language_props = Qnil;
  OSALanguage *defaultLanguage = [OSALanguage defaultLanguage];

  for (OSALanguage *language in [OSALanguage availableLanguages])
    {
      Lisp_Object language_props = [[language name] lispString];

      if (long_format_p)
	{
	  Lisp_Object tmp = list2 (QCfeatures,
				   make_number ([language features]));

	  tmp = Fcons (QCmanufacturer,
		       Fcons (mac_four_char_code_to_string ([language
							      manufacturer]),
			      tmp));
	  tmp = Fcons (QCsub_type,
		       Fcons (mac_four_char_code_to_string ([language subType]),
			      tmp));
	  tmp = Fcons (QCtype,
		       Fcons (mac_four_char_code_to_string ([language type]),
			      tmp));
	  tmp = Fcons (QCversion, Fcons ([[language version] lispString], tmp));
	  tmp = Fcons (QCinfo, Fcons ([[language info] lispString], tmp));
	  language_props = Fcons (language_props, tmp);
	}
      if (![language isEqual:defaultLanguage])
	result = Fcons (language_props, result);
      else
	default_language_props = language_props;
    }
  if (!NILP (default_language_props))
    result = Fcons (default_language_props, result);

  return result;
}

static Lisp_Object
mac_osa_error_info_to_lisp (NSDictionaryOf (NSString *, id) *errorInfo)
{
  Lisp_Object result = Qnil;
  NSString *errorMessage = [errorInfo objectForKey:OSAScriptErrorMessage];
  NSNumber *errorNumber = [errorInfo objectForKey:OSAScriptErrorNumber];
  NSString *errorAppName = [errorInfo objectForKey:OSAScriptErrorAppName];
  NSValue *errorRange = [errorInfo objectForKey:OSAScriptErrorRange];

  if (errorRange)
    {
      NSRange range = [errorRange rangeValue];

      result = Fcons (Fcons (Qrange, Fcons (make_number (range.location),
					    make_number (range.length))),
		      result);
    }
  if (errorAppName)
    result = Fcons (Fcons (Qapp_name, [errorAppName lispString]), result);
  if (errorNumber)
    result = Fcons (Fcons (Qnumber, make_number ([errorNumber intValue])),
		    result);
  result = Fcons ((errorMessage ? [errorMessage lispString]
		   : build_string ("OSA script error")), result);

  return result;
}

static OSALanguage *
mac_osa_language_from_lisp (Lisp_Object language)
{
  OSALanguage *result;

  if (NILP (language))
    result = [OSALanguage defaultLanguage];
  else
    {
      NSString *name = [NSString stringWithLispString:language];
      result = [OSALanguage languageForName:name];
    }

  return result;
}

static EmacsOSAScript *
mac_osa_create_script_from_file (Lisp_Object filename,
				 Lisp_Object compiled_p_or_language,
				 Lisp_Object *error_data)
{
  EmacsOSAScript *result;
  Lisp_Object encoded;
  NSURL *url;
  NSAppleEventDescriptor *dataDescriptor;
  NSDictionaryOf (NSString *, id) *errorInfo = nil;
  OSALanguage *language;

  filename = Fexpand_file_name (filename, Qnil);
  encoded = ENCODE_FILE (filename);
  url = [NSURL fileURLWithPath:[NSString stringWithLispString:encoded]];
  dataDescriptor = [OSAScript scriptDataDescriptorWithContentsOfURL:url];

  if (dataDescriptor == nil)
    result = nil;
  else
    {
      NSError *error;

      language = [OSALanguage languageForScriptDataDescriptor:dataDescriptor];
      if (language == nil)
	{
	  if (EQ (compiled_p_or_language, Qt))
	    {
	      *error_data =
		list2 (build_string ("Can't obtain OSA language from file"),
		       filename);

	      return nil;
	    }
	  language = mac_osa_language_from_lisp (compiled_p_or_language);
	  if (language == nil)
	    {
	      *error_data =
		list2 (build_string ("OSA language not available"),
		       compiled_p_or_language);

	      return nil;
	    }
	}
      result = [[EmacsOSAScript alloc]
		 initWithScriptDataDescriptor:dataDescriptor fromURL:url
			     languageInstance:[language sharedLanguageInstance]
			  usingStorageOptions:OSANull error:&error];
      if (result == nil)
	errorInfo = [error userInfo];
  }
  if (result == nil)
    {
      if (errorInfo)
	*error_data = mac_osa_error_info_to_lisp (errorInfo);
      else
	*error_data =
	  list2 (build_string ("Can't create OSA script from file"),
		 filename);
    }

  return result;
}

static EmacsOSAScript *
mac_osa_create_script_from_code (Lisp_Object code,
				 Lisp_Object compiled_p_or_language,
				 Lisp_Object *error_data)
{
  EmacsOSAScript *result;

  if (!EQ (compiled_p_or_language, Qt))
    {
      OSALanguage *language =
	mac_osa_language_from_lisp (compiled_p_or_language);

      if (language == nil)
	{
	  *error_data = list2 (build_string ("OSA language not available"),
			       compiled_p_or_language);

	  return nil;
	}
      result = [[EmacsOSAScript alloc]
		 initWithSource:[NSString stringWithLispString:code]
			fromURL:nil
		 languageInstance:[language sharedLanguageInstance]
		 usingStorageOptions:OSANull];
      if (result == nil)
	*error_data =
	  list2 (build_string ("Can't create OSA script from source"),
		 code);
    }
  else
    {
      NSData *data = [NSData dataWithBytes:(SDATA (code))
				    length:(SBYTES (code))];
      NSDictionaryOf (NSString *, id) *errorInfo = nil;
      NSError *error;

      result = [[EmacsOSAScript alloc] initWithCompiledData:data fromURL:nil
					usingStorageOptions:OSANull
						      error:&error];
      if (result == nil)
	errorInfo = [error userInfo];
      if (result == nil)
	{
	  if (errorInfo)
	    *error_data = mac_osa_error_info_to_lisp (errorInfo);
	  else
	    *error_data =
	      list2 (build_string ("Can't create OSA script from data"),
		     code);
	}
    }

  return result;
}

static EmacsOSAScript *
mac_osa_create_script (Lisp_Object code_or_file,
		       Lisp_Object compiled_p_or_language,
		       bool file_p, Lisp_Object *error_data)
{
  if (file_p)
    return mac_osa_create_script_from_file (code_or_file,
					    compiled_p_or_language, error_data);
  else
    return mac_osa_create_script_from_code (code_or_file,
					    compiled_p_or_language, error_data);
}

Lisp_Object
mac_osa_compile (Lisp_Object code_or_file, Lisp_Object compiled_p_or_language,
		 bool file_p, Lisp_Object *error_data)
{
  Lisp_Object result = Qnil;
  EmacsOSAScript *script;

  *error_data = Qnil;
  script = mac_osa_create_script (code_or_file, compiled_p_or_language, file_p,
				  error_data);
  if (script)
    {
      NSDictionaryOf (NSString *, id) *errorInfo;
      NSData *compiledData = [script compiledDataForType:nil
				     usingStorageOptions:OSANull
						   error:&errorInfo];

      if (compiledData == nil)
	*error_data = mac_osa_error_info_to_lisp (errorInfo);
      else
	result = [compiledData lispString];
      MRC_RELEASE (script);
    }

  return result;
}

static NSAppleEventDescriptor *
mac_apple_event_descriptor_with_handler_call (Lisp_Object handler_call,
					      ptrdiff_t nargs,
					      Lisp_Object *args)
{
  NSAppleEventDescriptor *result = nil;

  if (STRINGP (handler_call))
    {
      AEDescList param_list;

      if (AECreateList (NULL, 0, false, &param_list) == noErr)
	{
	  ptrdiff_t i;
	  NSAppleEventDescriptor *parameters, *target, *handler;
	  NSString *handlerName;

	  for (i = 0; i < nargs; i++)
	    mac_ae_put_lisp (&param_list, 0, args[i]);

	  target = [NSAppleEventDescriptor nullDescriptor];
	  result = [NSAppleEventDescriptor
		     appleEventWithEventClass:kASAppleScriptSuite
				      eventID:kASSubroutineEvent
			     targetDescriptor:target
				     returnID:kAutoGenerateReturnID
				transactionID:kAnyTransactionID];
	  handlerName = [NSString stringWithLispString:handler_call];
	  handler = [NSAppleEventDescriptor descriptorWithString:handlerName];
	  [result setDescriptor:handler forKeyword:keyASSubroutineName];
	  parameters = [[NSAppleEventDescriptor alloc]
			 initWithAEDescNoCopy:&param_list];
	  [result setDescriptor:parameters forKeyword:keyDirectObject];
	  MRC_RELEASE (parameters);
	}
    }
  else
    {
      AppleEvent apple_event;

      if (create_apple_event_from_lisp (handler_call, &apple_event) == noErr)
	result = MRC_AUTORELEASE ([[NSAppleEventDescriptor alloc]
				    initWithAEDescNoCopy:&apple_event]);
    }

  return result;
}

static const void *
cfarray_event_ref_retain (CFAllocatorRef allocator, const void *value)
{
  return RetainEvent ((EventRef) value);
}

static void
cfarray_event_ref_release (CFAllocatorRef allocator, const void *value)
{
  ReleaseEvent ((EventRef) value);
}

static const CFArrayCallBacks
cfarray_event_ref_callbacks = {0, cfarray_event_ref_retain,
			       cfarray_event_ref_release, NULL, NULL};

static void
mac_begin_defer_key_events (void)
{
  deferred_key_events = CFArrayCreateMutable (NULL, 0,
					      &cfarray_event_ref_callbacks);
}

static void
mac_end_defer_key_events (void)
{
  EventQueueRef queue = GetMainEventQueue ();
  CFIndex index, count = CFArrayGetCount (deferred_key_events);

  for (index = 0; index < count; index++)
    {
      EventRef event = (EventRef) CFArrayGetValueAtIndex (deferred_key_events,
							  index);

      PostEventToQueue (queue, event, kEventPriorityHigh);
    }
  CFRelease (deferred_key_events);
  deferred_key_events = NULL;
}

Lisp_Object
mac_osa_script (Lisp_Object code_or_file, Lisp_Object compiled_p_or_language,
		bool file_p, Lisp_Object value_form, Lisp_Object handler_call,
		ptrdiff_t nargs, Lisp_Object *args, Lisp_Object *error_data)
{
  Lisp_Object result = Qnil;
  EmacsOSAScript *script;
  NSAppleEventDescriptor *desc = nil;
  NSAttributedString *displayValue;

  *error_data = Qnil;
  script = mac_osa_create_script (code_or_file, compiled_p_or_language, file_p,
				  error_data);
  if (script)
    {
      NSDictionaryOf (NSString *, id) *errorInfo;
      NSAppleEventDescriptor *event = nil;

      if (![script compileAndReturnError:&errorInfo])
	*error_data = mac_osa_error_info_to_lisp (errorInfo);
      else if (!NILP (handler_call))
	{
	  event = mac_apple_event_descriptor_with_handler_call (handler_call,
								nargs, args);
	  if (event == nil)
	    *error_data = Fcons (build_string ("Can't create Apple event"),
				Fcons (handler_call, Flist (nargs, args)));
	}
      if (NILP (*error_data))
	{
	  mac_menu_set_in_use (true);
	  mac_begin_defer_key_events ();
	  if (event)
	    {
	      desc = [script executeAppleEvent:event error:&errorInfo];
	      if (desc && NILP (value_form))
		displayValue = [script richTextFromDescriptor:desc];
	    }
	  else if (NILP (value_form))
	    desc = [script executeAndReturnDisplayValue:&displayValue
						  error:&errorInfo];
	  else
	    desc = [script executeAndReturnError:&errorInfo];
	  if (desc == nil)
	    *error_data = mac_osa_error_info_to_lisp (errorInfo);
	  mac_end_defer_key_events ();
	  mac_menu_set_in_use (false);
	}
      MRC_RELEASE (script);
    }

  if (desc)
    {
      if (NILP (value_form))
	result = [[displayValue string] lispString];
      else
	result = mac_aedesc_to_lisp ([desc aeDesc]);
    }

  return result;
}


/************************************************************************
			    Image support
 ************************************************************************/

@implementation NSView (Emacs)

- (XImagePtr)createXImageFromRect:(NSRect)rect backgroundColor:(NSColor *)color
		      scaleFactor:(CGFloat)scaleFactor
{
  XImagePtr ximg;
  CGContextRef context;
  NSGraphicsContext *gcontext;
  NSAffineTransform *transform;

  ximg = mac_create_pixmap (NSWidth (rect) * scaleFactor,
			    NSHeight (rect) * scaleFactor, 0);
  context = CGBitmapContextCreate (ximg->data, ximg->width, ximg->height, 8,
				   ximg->bytes_per_line,
				   mac_cg_color_space_rgb,
				   kCGImageAlphaNoneSkipFirst
				   | kCGBitmapByteOrder32Host);
  if (context == NULL)
    {
      XFreePixmap (NULL, ximg);

      return NULL;
    }
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
  gcontext = [NSGraphicsContext graphicsContextWithCGContext:context
						     flipped:NO];
#else
  gcontext = [NSGraphicsContext graphicsContextWithGraphicsPort:context
							flipped:NO];
#endif
  transform = [NSAffineTransform transform];
  [transform scaleBy:scaleFactor];
  [transform translateXBy:(- NSMinX (rect)) yBy:(- NSMinY (rect))];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = gcontext;
  [transform concat];
  if (!(self.isOpaque && NSContainsRect (self.bounds, rect)))
    {
      [gcontext saveGraphicsState];
      [(color ? color : [NSColor clearColor]) set];
      NSRectFill (rect);
      [gcontext restoreGraphicsState];
    }
#ifdef USE_WK_API
  if ([self isKindOfClass:[WKWebView class]])
    {
      WKWebView *webView = (WKWebView *) self;
      WKSnapshotConfiguration *snapshotConfiguration =
	[[WKSnapshotConfiguration alloc] init];
      NSImage * __block image;
      BOOL __block finished = NO;

      [webView _setOverrideDeviceScaleFactor:scaleFactor];
      [webView takeSnapshotWithConfiguration:snapshotConfiguration
			   completionHandler:^(NSImage *snapshotImage,
					       NSError *error) {
	  image = MRC_RETAIN (snapshotImage);
	  finished = YES;
	}];
      MRC_RELEASE (snapshotConfiguration);

      while (!finished)
	mac_run_loop_run_once (0);

      if (image == nil)
	{
	  [NSGraphicsContext restoreGraphicsState];
	  CGContextRelease (context);
	  XFreePixmap (NULL, ximg);

	  return NULL;
	}

      rect = NSIntersectionRect (rect, self.bounds);
      [image drawAtPoint:rect.origin fromRect:rect
	       operation:NSCompositingOperationSourceOver fraction:1];
      MRC_RELEASE (image);
    }
  else
#endif
    [self displayRectIgnoringOpacity:rect inContext:gcontext];
  [NSGraphicsContext restoreGraphicsState];
  CGContextRelease (context);

  return ximg;
}

@end				// NSView (Emacs)

@implementation EmacsSVGLoader

- (instancetype)initWithEmacsFrame:(struct frame *)f emacsImage:(struct image *)img
		checkImageSizeFunc:(bool (*)(struct frame *, int, int))checkImageSize
		    imageErrorFunc:(void (*)(const char *, ...))imageError
{
  self = [super init];

  if (self == nil)
    return nil;

  emacsFrame = f;
  emacsImage = img;
  checkImageSizeFunc = checkImageSize;
  imageErrorFunc = imageError;

  return self;
}

- (NSSize)frameSizeForBoundingBox:(id)boundingBox widthBaseVal:(id)widthBaseVal
		    heightBaseVal:(id)heightBaseVal imageWidth:(int *)imageWidth
		      imageHeight:(int *)imageHeight
{
  NSNumber *unitType, *num;
  NSSize frameSize;
  int width, height;
  enum {
	SVG_LENGTHTYPE_PERCENTAGE = 2
  };

  unitType = [widthBaseVal valueForKey:@"unitType"];
  if (unitType.intValue == SVG_LENGTHTYPE_PERCENTAGE)
    {
      frameSize.width =
	round ([[boundingBox valueForKey:@"x"] doubleValue]
	       + [[boundingBox valueForKey:@"width"] doubleValue]);
      num = [widthBaseVal valueForKey:@"valueInSpecifiedUnits"];
      width = lround (frameSize.width * num.doubleValue / 100);
    }
  else
    {
      num = [widthBaseVal valueForKey:@"value"];
      width = lround (num.doubleValue);
      frameSize.width = width;
    }

  unitType = [heightBaseVal valueForKey:@"unitType"];
  if (unitType.intValue == SVG_LENGTHTYPE_PERCENTAGE)
    {
      frameSize.height =
	round ([[boundingBox valueForKey:@"y"] doubleValue]
	       + [[boundingBox valueForKey:@"height"] doubleValue]);
      num = [heightBaseVal valueForKey:@"valueInSpecifiedUnits"];
      height = lround (frameSize.height * num.doubleValue / 100);
    }
  else
    {
      num = [heightBaseVal valueForKey:@"value"];
      height = lround (num.doubleValue);
      frameSize.height = height;
    }

  *imageWidth = width;
  *imageHeight = height;

  return frameSize;
}

- (bool)loadData:(NSData *)data backgroundColor:(NSColor *)backgroundColor
	 baseURL:(NSURL *)url
{
  bool __block result;

  mac_within_app (^{
      NSRect frameRect = NSMakeRect (0, 0, 100, 100); /* Adjusted later.  */
      int width = -1, height;
      CGFloat scaleFactor;
#ifdef USE_WK_API
      static WKWebView *webView;

      if (!webView)
	{
	  WKWebViewConfiguration *configuration =
	    [[WKWebViewConfiguration alloc] init];

	  configuration.suppressesIncrementalRendering = YES;
	  webView = [[WKWebView alloc] initWithFrame:frameRect
				       configuration:configuration];
	  MRC_RELEASE (configuration);
	}
      else
	webView.frame = frameRect;
#define DELEGATE navigationDelegate
      eassert (!webView.DELEGATE);
      webView.DELEGATE = self;
      [webView loadData:data MIMEType:@"image/svg+xml"
	       characterEncodingName:@"UTF-8" baseURL:url];
#else
      static WebView *webView;

      if (!webView)
	webView = [[WebView alloc] initWithFrame:frameRect frameName:nil
				       groupName:nil];
      else
	webView.frame = frameRect;
#define DELEGATE frameLoadDelegate
      eassert (!webView.DELEGATE);
      webView.DELEGATE = self;
      webView.mainFrame.frameView.allowsScrolling = NO;
      [webView setValue:backgroundColor forKey:@"backgroundColor"];
      [webView.mainFrame loadData:data MIMEType:@"image/svg+xml"
		 textEncodingName:nil baseURL:url];
#endif

      /* webView.isLoading is not sufficient if we have <image
	 xlink:href=... /> */
      while (!isLoaded)
	mac_run_loop_run_once (0);

      @try
	{
	  id boundingBox, widthBaseVal, heightBaseVal;
#ifdef USE_WK_API
	  NSString * __block jsonString;
	  BOOL __block finished = NO;
	  CGFloat components[4];
	  NSColor *colorInSRGB =
	    [backgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
	  NSString *script;

	  [colorInSRGB getComponents:components];
	  script = [NSString stringWithFormat:@"\
const rootElement = document.rootElement;				\
rootElement.style.backgroundColor = '#%02x%02x%02x';			\
function filter (obj, names) {						\
  return names.reduce ((acc, nm) => {acc[nm] = obj[nm]; return acc;}, {}); \
}									\
JSON.stringify (['width', 'height'].reduce				\
  ((obj, dim) => {							\
     obj[dim + 'BaseVal'] =						\
       filter (rootElement[dim].baseVal,				\
	       ['unitType', 'value', 'valueInSpecifiedUnits']);		\
     return obj;							\
   }, {boundingBox: filter (rootElement.getBBox (),			\
			    ['x', 'y', 'width', 'height'])}))",
				       (int) (components[0] * 255 + 0.5),
				       (int) (components[1] * 255 + 0.5),
				       (int) (components[2] * 255 + 0.5)];
	  [webView evaluateJavaScript:script
		    completionHandler:^(id scriptResult, NSError *error) {
	      if ([scriptResult isKindOfClass:NSString.class])
		jsonString = MRC_RETAIN (scriptResult);
	      else
		jsonString = nil;
	      finished = YES;
	    }];

	  while (!finished)
	    mac_run_loop_run_once (0);

	  if (jsonString == nil)
	    boundingBox = nil;
	  else
	    {
	      NSData *data =
		[jsonString dataUsingEncoding:NSUTF8StringEncoding];
	      NSDictionary *jsonObject =
		[NSJSONSerialization JSONObjectWithData:data options:0
						  error:NULL];

	      boundingBox = jsonObject[@"boundingBox"];
	      widthBaseVal = jsonObject[@"widthBaseVal"];
	      heightBaseVal = jsonObject[@"heightBaseVal"];
	      MRC_AUTORELEASE (jsonString);
	    }
#else
	  WebScriptObject *rootElement =
	    [webView.windowScriptObject
		valueForKeyPath:@"document.rootElement"];

	  boundingBox = [rootElement callWebScriptMethod:@"getBBox"
					   withArguments:[NSArray array]];
	  widthBaseVal = [rootElement valueForKeyPath:@"width.baseVal"];
	  heightBaseVal = [rootElement valueForKeyPath:@"height.baseVal"];
#endif
	  if (boundingBox)
	    frameRect.size = [self frameSizeForBoundingBox:boundingBox
					      widthBaseVal:widthBaseVal
					     heightBaseVal:heightBaseVal
						imageWidth:&width
					       imageHeight:&height];
	}
      @catch (NSException *exception)
	{
	}

      if (width < 0)
	{
	  webView.DELEGATE = nil;
	  (*imageErrorFunc) ("Error reading SVG image `%s'", emacsImage->spec);
	  result = 0;

	  return;
	}

      webView.frame = frameRect;
      frameRect.size.width = width;
      frameRect.origin.y = NSHeight (frameRect) - height;
      frameRect.size.height = height;

      scaleFactor = 1;
      if (emacsImage->target_backing_scale == 0)
	{
	  emacsImage->target_backing_scale =
	    FRAME_BACKING_SCALE_FACTOR (emacsFrame);
	  if (emacsImage->target_backing_scale == 2)
	    {
	      width *= 2;
	      height *= 2;
	      scaleFactor = 2;
	    }
	}

      if (!(*checkImageSizeFunc) (emacsFrame, width, height))
	{
	  webView.DELEGATE = nil;
	  (*imageErrorFunc) ("Invalid image size (see `max-image-size')");

	  result = 0;
	  return;
	}

      emacsImage->width = width;
      emacsImage->height = height;
      emacsImage->pixmap = [webView createXImageFromRect:frameRect
					 backgroundColor:backgroundColor
					     scaleFactor:scaleFactor];
      webView.DELEGATE = nil;
#undef DELEGATE

      result = 1;
    });

  return result;
}

#ifdef USE_WK_API
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation;
{
  isLoaded = YES;
}
#else
- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
  isLoaded = YES;
}
#endif

@end				// EmacsSVGLoader

bool
mac_webkit_supports_svg_p (void)
{
#ifdef USE_WK_API
  return true;
#else
  bool __block result;

  block_input ();
  /* Avoid "WebKit Threading Violation - initial use of WebKit from a
     secondary thread."  */
  mac_within_gui (^{result = [WebView canShowMIMEType:@"image/svg+xml"];});
  unblock_input ();

  return result;
#endif
}

bool
mac_svg_load_image (struct frame *f, struct image *img, unsigned char *contents,
		    ptrdiff_t size, XColor *color, Lisp_Object encoded_file,
		    bool (*check_image_size_func) (struct frame *, int, int),
		    void (*image_error_func) (const char *, ...))
{
  EmacsSVGLoader *loader =
    [[EmacsSVGLoader alloc] initWithEmacsFrame:f emacsImage:img
			    checkImageSizeFunc:check_image_size_func
				imageErrorFunc:image_error_func];
  NSData *data =
    [NSData dataWithBytesNoCopy:contents length:size freeWhenDone:NO];
  NSColor *backgroundColor = [NSColor colorWithXColorPixel:color->pixel];
  NSURL *url =
    (STRINGP (encoded_file)
     ? [NSURL fileURLWithPath:[NSString stringWithLispString:encoded_file]]
     : nil);
  /* WebKit may repeatedly call waitpid for a child process
     (WebKitPluginHost) while it returns -1 in its plug-in
     initialization.  So we need to avoid calling wait3 for an
     arbitrary child process in our own SIGCHLD handler.  */
  int mask = sigblock (sigmask (SIGCHLD));
  bool result = [loader loadData:data backgroundColor:backgroundColor
			 baseURL:url];

  sigsetmask (mask);
  MRC_RELEASE (loader);

  return result;
}


/************************************************************************
			Document rasterization
 ************************************************************************/

static NSMutableDictionaryOf (id, NSDictionaryOf (NSString *, id) *)
  *documentRasterizerCache;
static NSDate *documentRasterizerCacheOldestTimestamp;
#define DOCUMENT_RASTERIZER_CACHE_DURATION 60.0

@implementation EmacsPDFDocument

/* Like -[PDFDocument initWithURL:], but suppress warnings if not
   loading a PDF file.  */

- (instancetype)initWithURL:(NSURL *)url
		    options:(NSDictionaryOf (NSString *, id) *)options
{
  NSFileHandle *fileHandle;
  NSData *data;
  NSString *type = [options objectForKey:@"UTI"]; /* NSFileTypeDocumentOption */

  if (type && !UTTypeEqual ((__bridge CFStringRef) type, kUTTypePDF))
    goto error;

  fileHandle = [NSFileHandle fileHandleForReadingFromURL:url error:NULL];
  data = [fileHandle readDataOfLength:5];

  if ([data length] < 5 || memcmp ([data bytes], "%PDF-", 5) != 0)
    goto error;

  self = [self initWithURL:url];

  return self;

 error:
  self = [super init];
  MRC_RELEASE (self);
  self = nil;

  return self;
}

/* Like -[PDFDocument initWithData:], but suppress warnings if not
   loading a PDF data.  */

- (instancetype)initWithData:(NSData *)data
		     options:(NSDictionaryOf (NSString *, id) *)options
{
  NSString *type = [options objectForKey:@"UTI"]; /* NSFileTypeDocumentOption */

  if (type && !UTTypeEqual ((__bridge CFStringRef) type, kUTTypePDF))
    goto error;
  if ([data length] < 5 || memcmp ([data bytes], "%PDF-", 5) != 0)
    goto error;

  self = [self initWithData:data];

  return self;

 error:
  self = [super init];
  MRC_RELEASE (self);
  self = nil;

  return self;
}

+ (BOOL)shouldInitializeInMainThread
{
  return NO;
}

+ (NSArrayOf (NSString *) *)supportedTypes
{
  return [NSArray arrayWithObject:((__bridge NSString *) kUTTypePDF)];
}

- (NSSize)integralSizeOfPageAtIndex:(NSUInteger)index
{
  PDFPage *page = [self pageAtIndex:index];
  NSRect bounds = [page boundsForBox:kPDFDisplayBoxTrimBox];
  int rotation = [page rotation];

  if (rotation == 0 || rotation == 180)
    return NSMakeSize (ceil (NSWidth (bounds)), ceil (NSHeight (bounds)));
  else
    return NSMakeSize (ceil (NSHeight (bounds)), ceil (NSWidth (bounds)));
}

- (CGColorRef)copyBackgroundCGColorOfPageAtIndex:(NSUInteger)index
{
  return NULL;
}

- (NSDictionaryOf (NSString *, id) *)documentAttributesOfPageAtIndex:(NSUInteger)index
{
  return [self documentAttributes];
}

- (void)drawPageAtIndex:(NSUInteger)index inRect:(NSRect)rect
	      inContext:(CGContextRef)ctx
{
  PDFPage *page = [self pageAtIndex:index];
  NSRect bounds = [page boundsForBox:kPDFDisplayBoxTrimBox];
  int rotation = [page rotation];
  CGFloat width, height;

  if (rotation == 0 || rotation == 180)
    width = ceil (NSWidth (bounds)), height = ceil (NSHeight (bounds));
  else
    width = ceil (NSHeight (bounds)), height = ceil (NSWidth (bounds));
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101200
  if ([page respondsToSelector:@selector(drawWithBox:toContext:)])
#endif
    {
      CGContextSaveGState (ctx);
      CGContextTranslateCTM (ctx, NSMinX (rect), NSMinY (rect));
      CGContextScaleCTM (ctx, NSWidth (rect) / width, NSHeight (rect) / height);
      [page drawWithBox:kPDFDisplayBoxTrimBox toContext:ctx];
      CGContextRestoreGState (ctx);
    }
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101200
  else
    {
      NSAffineTransform *transform = [NSAffineTransform transform];
      NSGraphicsContext *gcontext =
	[NSGraphicsContext graphicsContextWithGraphicsPort:ctx flipped:NO];

      [NSGraphicsContext saveGraphicsState];
      NSGraphicsContext.currentContext = gcontext;
      [transform translateXBy:(NSMinX (rect)) yBy:(NSMinY (rect))];
      [transform scaleXBy:(NSWidth (rect) / width)
		      yBy:(NSHeight (rect) / height)];
      [transform concat];
      [page drawWithBox:kPDFDisplayBoxTrimBox];
      [NSGraphicsContext restoreGraphicsState];
    }
#endif
}

@end				// EmacsPDFDocument

@implementation EmacsDocumentRasterizer
- (instancetype)initWithAttributedString:(NSAttributedString *)anAttributedString
		      documentAttributes:(NSDictionaryOf (NSString *, id) *)docAttributes
{
  NSLayoutManager *layoutManager;
  NSTextContainer *textContainer;
  int viewMode;
  NSRange glyphRange;

  self = [super init];

  if (self == nil)
    return nil;

  textStorage = [[NSTextStorage alloc]
		  initWithAttributedString:anAttributedString];
  layoutManager = [[NSLayoutManager alloc] init];
  textContainer = [[NSTextContainer alloc] init];

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
  [layoutManager setUsesScreenFonts:NO];
#endif

  [layoutManager addTextContainer:textContainer];
  MRC_RELEASE (textContainer);
  [textStorage addLayoutManager:layoutManager];
  MRC_RELEASE (layoutManager);

  if (!(textStorage && layoutManager && textContainer))
    {
      MRC_RELEASE (self);
      self = nil;

      return self;
    }

  viewMode = [[docAttributes objectForKey:NSViewModeDocumentAttribute]
	       intValue];
  if (viewMode == 0)
    [textContainer setLineFragmentPadding:0];
  else
    {
      /* page layout */
      NSSize pageSize =
	[[docAttributes objectForKey:NSPaperSizeDocumentAttribute] sizeValue];
      NSAttributedStringDocumentAttributeKey __unsafe_unretained
	marginAttributes[4] = {
	NSLeftMarginDocumentAttribute, NSRightMarginDocumentAttribute,
	NSTopMarginDocumentAttribute, NSBottomMarginDocumentAttribute
      };
      NSNumber * __unsafe_unretained marginValues[4];
      int i;

      for (i = 0; i < 4; i++)
	marginValues[i] = [docAttributes objectForKey:marginAttributes[i]];
      for (i = 0; i < 2; i++)
	if (marginValues[i])
	  pageSize.width -= [marginValues[i] doubleValue];
      for (; i < 4; i++)
	if (marginValues[i])
	  pageSize.height -= [marginValues[i] doubleValue];

      pageSize.width = ceil (pageSize.width);
      pageSize.height = ceil (pageSize.height);
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
      [textContainer setSize:pageSize];
#else
      [textContainer setContainerSize:pageSize];
#endif

      [layoutManager setDelegate:self];
    }

  /* Fully lay out.  */
  glyphRange =
    [layoutManager
      glyphRangeForCharacterRange:(NSMakeRange (0, [textStorage length]))
	     actualCharacterRange:NULL];
  if (NSMaxRange (glyphRange) == 0)
    {
      MRC_RELEASE (self);
      self = nil;

      return self;
    }
  (void) [layoutManager
	   textContainerForGlyphAtIndex:(NSMaxRange (glyphRange) - 1)
			 effectiveRange:NULL];

  if (viewMode == 0)
    {
      NSRect rect = [layoutManager usedRectForTextContainer:textContainer];
      NSSize containerSize = NSMakeSize (ceil (NSMaxX (rect)),
					 ceil (NSMaxY (rect)));

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
      [textContainer setSize:containerSize];
#else
      [textContainer setContainerSize:containerSize];
#endif
    }

  documentAttributes = MRC_RETAIN (docAttributes);

  return self;
}

- (instancetype)initWithURL:(NSURL *)url
		    options:(NSDictionaryOf (NSString *, id) *)options
{
  NSAttributedString *attrString;
  NSDictionaryOf (NSAttributedStringDocumentAttributeKey, id) *docAttributes;

  attrString = [[NSAttributedString alloc]
		 initWithURL:url options:options
		 documentAttributes:&docAttributes error:NULL];
  if (attrString == nil)
    goto error;

  self = [self initWithAttributedString:attrString
		     documentAttributes:docAttributes];
  MRC_RELEASE (attrString);

  return self;

 error:
  self = [self init];
  MRC_RELEASE (self);
  self = nil;

  return self;
}

- (instancetype)initWithData:(NSData *)data
		     options:(NSDictionaryOf (NSString *, id) *)options
{
  NSAttributedString *attrString;
  NSDictionaryOf (NSAttributedStringDocumentAttributeKey, id) *docAttributes;

  attrString = [[NSAttributedString alloc]
		 initWithData:data options:options
		 documentAttributes:&docAttributes error:NULL];
  if (attrString == nil)
    goto error;

  self = [self initWithAttributedString:attrString
		     documentAttributes:docAttributes];
  MRC_RELEASE (attrString);

  return self;

 error:
  self = [self init];
  MRC_RELEASE (self);
  self = nil;

  return self;
}

+ (BOOL)shouldInitializeInMainThread
{
  return YES;
}

#if !USE_ARC
- (void)dealloc
{
  [textStorage release];
  [documentAttributes release];
  [super dealloc];
}
#endif

- (NSLayoutManager *)layoutManager
{
  return [[textStorage layoutManagers] objectAtIndex:0];
}

- (NSUInteger)pageCount
{
  NSLayoutManager *layoutManager = [self layoutManager];

  return [[layoutManager textContainers] count];
}

+ (NSArrayOf (NSString *) *)supportedTypes
{
  return [NSAttributedString textTypes];
}

- (NSSize)integralSizeOfPageAtIndex:(NSUInteger)index
{
  NSLayoutManager *layoutManager = [self layoutManager];
  NSTextContainer *textContainer =
    [[layoutManager textContainers] objectAtIndex:index];

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
  return [textContainer size];
#else
  return [textContainer containerSize];
#endif
}

- (CGColorRef)copyBackgroundCGColorOfPageAtIndex:(NSUInteger)index
{
  NSColor *backgroundColor = [documentAttributes
			       objectForKey:NSBackgroundColorDocumentAttribute];

  /* `backgroundColor' might be nil, but that's OK.  */
  return [backgroundColor copyCGColor];
}

- (NSDictionaryOf (NSString *, id) *)documentAttributesOfPageAtIndex:(NSUInteger)index
{
  return documentAttributes;
}

- (void)drawPageAtIndex:(NSUInteger)index inRect:(NSRect)rect
	      inContext:(CGContextRef)ctx
{
  NSLayoutManager *layoutManager = [self layoutManager];
  NSTextContainer *textContainer =
    [[layoutManager textContainers] objectAtIndex:index];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
  NSSize containerSize = [textContainer size];
#else
  NSSize containerSize = [textContainer containerSize];
#endif
  NSRange glyphRange = [layoutManager glyphRangeForTextContainer:textContainer];
  NSAffineTransform *transform = [NSAffineTransform transform];
  NSGraphicsContext *gcontext =
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
    [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
#else
    [NSGraphicsContext graphicsContextWithGraphicsPort:ctx flipped:YES];
#endif

  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = gcontext;
  [transform translateXBy:(NSMinX (rect)) yBy:(NSMaxY (rect))];
  [transform scaleXBy:(NSWidth (rect) / containerSize.width)
		  yBy:(- NSHeight (rect) / containerSize.height)];
  [transform concat];
  [layoutManager drawBackgroundForGlyphRange:glyphRange atPoint:NSZeroPoint];
  [layoutManager drawGlyphsForGlyphRange:glyphRange atPoint:NSZeroPoint];
  [NSGraphicsContext restoreGraphicsState];
}

- (void)layoutManager:(NSLayoutManager *)aLayoutManager
didCompleteLayoutForTextContainer:(NSTextContainer *)aTextContainer
		atEnd:(BOOL)flag
{
  if (aTextContainer == nil)
    {
      NSLayoutManager *layoutManager = [self layoutManager];
      NSTextContainer *firstContainer =
	[[layoutManager textContainers] objectAtIndex:0];
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
      NSTextContainer *textContainer = [[NSTextContainer alloc]
					 initWithSize:[firstContainer size]];
#else
      NSSize containerSize = [firstContainer containerSize];
      NSTextContainer *textContainer = [[NSTextContainer alloc]
					 initWithContainerSize:containerSize];
#endif

      [aLayoutManager addTextContainer:textContainer];
      MRC_RELEASE (textContainer);
    }
}

@end				// EmacsDocumentRasterizer

static NSArrayOf (Class <EmacsDocumentRasterizer>) *
document_rasterizer_get_classes (void)
{
  return [NSArray arrayWithObjects:[EmacsPDFDocument class],
		  [EmacsDocumentRasterizer class],
		  nil];
}

CFArrayRef
mac_document_copy_type_identifiers (void)
{
  NSMutableArrayOf (NSString *) *identifiers = [NSMutableArray array];

  for (Class <EmacsDocumentRasterizer> class
	 in document_rasterizer_get_classes ())
    [identifiers addObjectsFromArray:[class supportedTypes]];

  return CF_BRIDGING_RETAIN (identifiers);
}

static void
document_cache_evict (void)
{
  NSDate *currentDate, *oldestTimestamp;

  if ([documentRasterizerCacheOldestTimestamp timeIntervalSinceNow]
      > - DOCUMENT_RASTERIZER_CACHE_DURATION)
    return;

  currentDate = [NSDate date];
  oldestTimestamp = nil;
  for (id key in [documentRasterizerCache allKeys])
    {
      NSDictionaryOf (NSString *, id) *value =
	[documentRasterizerCache objectForKey:key];
      NSDate *timestamp = [value objectForKey:@"timestamp"];

      if ([currentDate timeIntervalSinceDate:timestamp]
	  >= DOCUMENT_RASTERIZER_CACHE_DURATION)
	[documentRasterizerCache removeObjectForKey:key];
      else
	{
	  if (oldestTimestamp == nil)
	    oldestTimestamp = timestamp;
	  else
	    oldestTimestamp = [oldestTimestamp earlierDate:timestamp];
	}
    }
  MRC_RELEASE (documentRasterizerCacheOldestTimestamp);
  documentRasterizerCacheOldestTimestamp = MRC_RETAIN (oldestTimestamp);
}

static id <EmacsDocumentRasterizer>
document_cache_lookup (id key, NSDate *modificationDate)
{
  id <EmacsDocumentRasterizer> result = nil;

  if (documentRasterizerCache)
    {
      NSDictionaryOf (NSString *, id) *dictionary =
	[documentRasterizerCache objectForKey:key];

      if (dictionary
	  && (modificationDate == nil
	      || [modificationDate
		   isEqualToDate:[dictionary fileModificationDate]]))
	result = [dictionary objectForKey:@"document"];
    }

  return result;
}

static void
document_cache_set (id <NSCopying> key, id <EmacsDocumentRasterizer> document,
		    NSDate *modificationDate)
{
  NSDate *currentDate;
  NSDictionaryOf (NSString *, id) *value;

  if (documentRasterizerCache == nil)
    documentRasterizerCache = [[NSMutableDictionary alloc] init];

  currentDate = [NSDate date];
  value = [NSDictionary dictionaryWithObjectsAndKeys:document, @"document",
			currentDate, @"timestamp",
			/* The value of modificationDate might be nil,
			   but that's OK.  */
			modificationDate, NSFileModificationDate,
			nil];
  /* This might update an object containing the oldest time stamp.
     Even in such a case, documentRasterizerCacheOldestTimestamp still
     holds an older or equal date than the real oldest time stamp in
     the cache.  */
  [documentRasterizerCache setObject:value forKey:key];
  if (documentRasterizerCacheOldestTimestamp == nil)
    documentRasterizerCacheOldestTimestamp = MRC_RETAIN (currentDate);
}

static id <EmacsDocumentRasterizer>
document_rasterizer_create (id url_or_data,
			    NSDictionaryOf (NSString *, id) *options)
{
  BOOL isURL = [url_or_data isKindOfClass:[NSURL class]];

  for (Class class in document_rasterizer_get_classes ())
    {
      id <EmacsDocumentRasterizer> __block document;
      void (^block) (void);

      if (isURL)
	block = ^{
	  document = [((id <EmacsDocumentRasterizer>) [class alloc])
		       initWithURL:((NSURL *) url_or_data) options:options];
	};
      else
	block = ^{
	  document = [((id <EmacsDocumentRasterizer>) [class alloc])
		       initWithData:((NSData *) url_or_data) options:options];
	};

      if ([(Class <EmacsDocumentRasterizer>)class shouldInitializeInMainThread])
	mac_within_gui (block);
      else
	block ();

      if (document)
	return document;
    }

  return nil;
}

EmacsDocumentRef
mac_document_create_with_url (CFURLRef url, CFDictionaryRef options)
{
  NSURL *nsurl = (__bridge NSURL *) url;
  NSDictionaryOf (NSString *, id) *nsoptions =
    (__bridge NSDictionaryOf (NSString *, id) *) options;
  NSDate *modificationDate = nil;
  id <EmacsDocumentRasterizer> document = nil;

  if ([nsurl isFileURL])
    {
      [[nsurl URLByResolvingSymlinksInPath]
	getResourceValue:&modificationDate
		  forKey:NSURLAttributeModificationDateKey
		   error:NULL];
    }

  if (modificationDate)
    {
      NSDictionaryOf (NSString *, id) *key =
	[NSDictionary dictionaryWithObjectsAndKeys:nsurl, @"URL",
		      /* The value of nsoptions might be nil, but
			 that's OK.  */
		      nsoptions, @"options", nil];

      document = document_cache_lookup (key, modificationDate);
      if (document == nil)
	document = MRC_AUTORELEASE (document_rasterizer_create (nsurl,
								nsoptions));
      if (document)
	document_cache_set (key, document, modificationDate);
    }

  document_cache_evict ();

  return CF_BRIDGING_RETAIN (document);
}

EmacsDocumentRef
mac_document_create_with_data (CFDataRef data, CFDictionaryRef options)
{
  NSData *nsdata = (__bridge NSData *) data;
  NSDictionaryOf (NSString *, id) *nsoptions =
    (__bridge NSDictionaryOf (NSString *, id) *) options;
  NSDictionaryOf (NSString *, id) *key =
    [NSDictionary dictionaryWithObjectsAndKeys:nsdata, @"data",
		  /* The value of nsoptions might be nil, but that's
		     OK.  */
		  nsoptions, @"options", nil];
  id <EmacsDocumentRasterizer> document = document_cache_lookup (key, nil);

  if (document == nil)
    document = MRC_AUTORELEASE (document_rasterizer_create (nsdata, nsoptions));
  if (document)
    document_cache_set (key, document, nil);

  document_cache_evict ();

  return CF_BRIDGING_RETAIN (document);
}

size_t
mac_document_get_page_count (EmacsDocumentRef document)
{
  id <EmacsDocumentRasterizer> documentRasterizer =
    (__bridge id <EmacsDocumentRasterizer>) document;

  return [documentRasterizer pageCount];
}

void
mac_document_copy_page_info (EmacsDocumentRef document, size_t index,
			     CGSize *size, CGColorRef *background,
			     CFDictionaryRef *attributes)
{
  id <EmacsDocumentRasterizer> documentRasterizer =
    (__bridge id <EmacsDocumentRasterizer>) document;

  if (size)
    *size = NSSizeToCGSize ([documentRasterizer
			      integralSizeOfPageAtIndex:index]);
  if (background)
    *background = [documentRasterizer copyBackgroundCGColorOfPageAtIndex:index];
  if (attributes)
    *attributes = CF_BRIDGING_RETAIN ([documentRasterizer
					documentAttributesOfPageAtIndex:index]);
}

void
mac_document_draw_page (CGContextRef c, CGRect rect, EmacsDocumentRef document,
			size_t index)
{
  id <EmacsDocumentRasterizer> documentRasterizer =
    (__bridge id <EmacsDocumentRasterizer>) document;

  [documentRasterizer drawPageAtIndex:index inRect:(NSRectFromCGRect (rect))
			    inContext:c];
}


/************************************************************************
			Accessibility Support
 ************************************************************************/

static id ax_get_value (EmacsMainView *);
static id ax_get_selected_text (EmacsMainView *);
static id ax_get_selected_text_range (EmacsMainView *);
static id ax_get_number_of_characters (EmacsMainView *);
static id ax_get_visible_character_range (EmacsMainView *);
#if 0
static id ax_get_shared_text_ui_elements (EmacsMainView *);
static id ax_get_shared_character_range (EmacsMainView *);
#endif
static id ax_get_insertion_point_line_number (EmacsMainView *);
static id ax_get_selected_text_ranges (EmacsMainView *);

static id ax_get_line_for_index (EmacsMainView *, id);
static id ax_get_range_for_line (EmacsMainView *, id);
static id ax_get_string_for_range (EmacsMainView *, id);
static id ax_get_range_for_position (EmacsMainView *, id);
static id ax_get_range_for_index (EmacsMainView *, id);
static id ax_get_bounds_for_range (EmacsMainView *, id);
static id ax_get_rtf_for_range (EmacsMainView *, id);
#if 0
static id ax_get_style_range_for_index (EmacsMainView *, id);
#endif
static id ax_get_attributed_string_for_range (EmacsMainView *, id);

static const struct {
  NSAccessibilityAttributeName const *ns_name_ptr;
  CFStringRef fallback_name;
  id (*handler) (EmacsMainView *);
} ax_attribute_table[] = {
  {&NSAccessibilityValueAttribute, NULL, ax_get_value},
  {&NSAccessibilitySelectedTextAttribute, NULL, ax_get_selected_text},
  {&NSAccessibilitySelectedTextRangeAttribute,
   NULL, ax_get_selected_text_range},
  {&NSAccessibilityNumberOfCharactersAttribute, NULL,
   ax_get_number_of_characters},
  {&NSAccessibilityVisibleCharacterRangeAttribute, NULL,
   ax_get_visible_character_range},
#if 0
  {&NSAccessibilitySharedTextUIElementsAttribute, NULL,
   ax_get_shared_text_ui_elements},
  {&NSAccessibilitySharedCharacterRangeAttribute, NULL,
   ax_get_shared_character_range},
#endif	/* 0 */
  {&NSAccessibilityInsertionPointLineNumberAttribute, NULL,
   ax_get_insertion_point_line_number},
  {
    &NSAccessibilitySelectedTextRangesAttribute,
    CFSTR ("AXSelectedTextRanges"), ax_get_selected_text_ranges},
};
static const size_t ax_attribute_count = ARRAYELTS (ax_attribute_table);
static NSArrayOf (NSAccessibilityAttributeName) *ax_attribute_names;
static Lisp_Object ax_attribute_event_ids;

static const struct {
  NSAccessibilityParameterizedAttributeName const *ns_name_ptr;
  CFStringRef fallback_name;
  id (*handler) (EmacsMainView *, id);
} ax_parameterized_attribute_table[] = {
  {&NSAccessibilityLineForIndexParameterizedAttribute, NULL,
   ax_get_line_for_index},
  {&NSAccessibilityRangeForLineParameterizedAttribute, NULL,
   ax_get_range_for_line},
  {&NSAccessibilityStringForRangeParameterizedAttribute, NULL,
   ax_get_string_for_range},
  {&NSAccessibilityRangeForPositionParameterizedAttribute, NULL,
   ax_get_range_for_position},
  {&NSAccessibilityRangeForIndexParameterizedAttribute, NULL,
   ax_get_range_for_index},
  {&NSAccessibilityBoundsForRangeParameterizedAttribute, NULL,
   ax_get_bounds_for_range},
  {&NSAccessibilityRTFForRangeParameterizedAttribute, NULL,
   ax_get_rtf_for_range},
#if 0
  {&NSAccessibilityStyleRangeForIndexParameterizedAttribute, NULL,
   ax_get_style_range_for_index},
#endif	/* 0 */
  {&NSAccessibilityAttributedStringForRangeParameterizedAttribute, NULL,
   ax_get_attributed_string_for_range},
};
static const size_t ax_parameterized_attribute_count =
  ARRAYELTS (ax_parameterized_attribute_table);
static NSArrayOf (NSAccessibilityParameterizedAttributeName)
  *ax_parameterized_attribute_names;

static const struct {
  NSAccessibilityActionName const *ns_name_ptr;
  CFStringRef fallback_name;
} ax_action_table[] = {
  {&NSAccessibilityShowMenuAction, NULL},
};
static const size_t ax_action_count = ARRAYELTS (ax_action_table);
static NSArrayOf (NSAccessibilityActionName) *ax_action_names;
static Lisp_Object ax_action_event_ids;

static NSAccessibilityNotificationName ax_selected_text_changed_notification;

static Lisp_Object
ax_name_to_symbol (NSString *name, NSString *prefix)
{
  NSArrayOf (NSString *) *nameComponents =
    [[name substringFromIndex:2] /* strip off leading "AX" */
      componentsSeparatedByCamelCasingWithCharactersInSet:nil];
  NSMutableArrayOf (NSString *) *symbolComponents =
    [NSMutableArray arrayWithCapacity:[nameComponents count]];

  if (prefix)
    [symbolComponents addObject:prefix];
  for (NSString *component in nameComponents)
    [symbolComponents addObject:[component lowercaseString]];

  return Fintern ([[symbolComponents componentsJoinedByString:@"-"]
		    UTF8LispString], Qnil);
}

static void
init_accessibility (void)
{
  int i;
  NSString * __unsafe_unretained *buf;

  buf = ((NSString * __unsafe_unretained *)
	 xmalloc (sizeof (NSString *) * ax_attribute_count));
  ax_attribute_event_ids =
    Fmake_vector (make_number (ax_attribute_count), Qnil);
  staticpro (&ax_attribute_event_ids);
  for (i = 0; i < ax_attribute_count; i++)
    {
      buf[i] = (ax_attribute_table[i].ns_name_ptr
		? *ax_attribute_table[i].ns_name_ptr
		: (__bridge NSString *) ax_attribute_table[i].fallback_name);
      ASET (ax_attribute_event_ids, i, ax_name_to_symbol (buf[i], @"set"));
    }
  ax_attribute_names = [[NSArray alloc] initWithObjects:buf
						  count:ax_attribute_count];

  buf = ((NSString * __unsafe_unretained *)
	 xrealloc (buf,
		   sizeof (NSString *) * ax_parameterized_attribute_count));
  for (i = 0; i < ax_parameterized_attribute_count; i++)
    buf[i] = (ax_parameterized_attribute_table[i].ns_name_ptr
	      ? *ax_parameterized_attribute_table[i].ns_name_ptr
	      : ((__bridge NSString *)
		 ax_parameterized_attribute_table[i].fallback_name));
  ax_parameterized_attribute_names =
    [[NSArray alloc] initWithObjects:buf
			       count:ax_parameterized_attribute_count];

  buf = ((NSString * __unsafe_unretained *)
	 xrealloc (buf, sizeof (NSString *) * ax_action_count));
  ax_action_event_ids = Fmake_vector (make_number (ax_action_count), Qnil);
  staticpro (&ax_action_event_ids);
  for (i = 0; i < ax_action_count; i++)
    {
      buf[i] = (ax_action_table[i].ns_name_ptr
		? *ax_action_table[i].ns_name_ptr
		: (__bridge NSString *) ax_action_table[i].fallback_name);
      ASET (ax_action_event_ids, i, ax_name_to_symbol (buf[i], nil));
    }
  ax_action_names = [[NSArray alloc] initWithObjects:buf count:ax_action_count];

  xfree (buf);

  ax_selected_text_changed_notification =
    NSAccessibilitySelectedTextChangedNotification;
}

@implementation EmacsController (Accessibility)

- (void)accessibilityDisplayOptionsDidChange:(NSNotification *)notification
{
  mac_update_accessibility_display_options ();
}

struct mac_accessibility_display_options mac_accessibility_display_options;

static void
mac_update_accessibility_display_options (void)
{
  NSWorkspace *workspace = [NSWorkspace sharedWorkspace];

  mac_accessibility_display_options.increase_contrast_p =
    [workspace accessibilityDisplayShouldIncreaseContrast];
  mac_accessibility_display_options.differentiate_without_color_p =
    [workspace accessibilityDisplayShouldDifferentiateWithoutColor];
  mac_accessibility_display_options.reduce_transparency_p =
    [workspace accessibilityDisplayShouldReduceTransparency];
}

@end				// EmacsController (Accessibility)

@implementation EmacsMainView (Accessibility)

- (BOOL)accessibilityIsIgnored
{
  return mac_ignore_accessibility;
}

- (NSArrayOf (NSAccessibilityAttributeName) *)accessibilityAttributeNames
{
  static NSArrayOf (NSAccessibilityAttributeName) *names = nil;

  if (names == nil)
    names = MRC_RETAIN ([[super accessibilityAttributeNames]
			  arrayByAddingObjectsFromArray:ax_attribute_names]);

  return names;
}

static id
ax_get_value (EmacsMainView *emacsView)
{
  return [emacsView string];
}

static id
ax_get_selected_text (EmacsMainView *emacsView)
{
  struct frame *f = [emacsView emacsFrame];
  CFRange selectedRange;
  CFStringRef string;

  if (poll_suppress_count == 0 && !NILP (Vinhibit_quit))
    /* Don't try to get buffer contents as the gap might be being
       altered. */
    return nil;

  mac_ax_selected_text_range (f, &selectedRange);
  string = mac_ax_create_string_for_range (f, &selectedRange, NULL);

  return CF_BRIDGING_RELEASE (string);
}

static id
ax_get_insertion_point_line_number (EmacsMainView *emacsView)
{
  struct frame *f = [emacsView emacsFrame];
  EMACS_INT line;

  if (poll_suppress_count == 0 && !NILP (Vinhibit_quit))
    /* Don't try to get buffer contents as the gap might be being
       altered. */
    return nil;

  line = mac_ax_line_for_index (f, -1);

  return line >= 0 ? [NSNumber numberWithLong:line] : nil;
}

static id
ax_get_selected_text_range (EmacsMainView *emacsView)
{
  return [NSValue valueWithRange:[emacsView selectedRange]];
}

static id
ax_get_number_of_characters (EmacsMainView *emacsView)
{
  EMACS_INT length = mac_ax_number_of_characters ([emacsView emacsFrame]);

  return [NSNumber numberWithLong:length];
}

static id
ax_get_visible_character_range (EmacsMainView *emacsView)
{
  NSRange range;

  mac_ax_visible_character_range ([emacsView emacsFrame], (CFRange *) &range);

  return [NSValue valueWithRange:range];
}

static id
ax_get_selected_text_ranges (EmacsMainView *emacsView)
{
  NSValue *rangeValue = [NSValue valueWithRange:[emacsView selectedRange]];

  return [NSArray arrayWithObject:rangeValue];
}

- (id)accessibilityAttributeValue:(NSAccessibilityAttributeName)attribute
{
  NSUInteger index = [ax_attribute_names indexOfObject:attribute];

  if (index != NSNotFound)
    return (*ax_attribute_table[index].handler) (self);
  else if ([attribute isEqualToString:NSAccessibilityRoleAttribute])
    return NSAccessibilityTextAreaRole;
  else
    return [super accessibilityAttributeValue:attribute];
}

- (BOOL)accessibilityIsAttributeSettable:(NSAccessibilityAttributeName)attribute
{
  NSUInteger index = [ax_attribute_names indexOfObject:attribute];

  if (index != NSNotFound)
    {
      Lisp_Object tem = get_keymap (Vmac_apple_event_map, 0, 0);

      if (!NILP (tem))
	tem = get_keymap (access_keymap (tem, Qaccessibility, 0, 1, 0), 0, 0);
      if (!NILP (tem))
	tem = access_keymap (tem, AREF (ax_attribute_event_ids, index),
			     0, 1, 0);

      return !NILP (tem) && !EQ (tem, Qundefined);
    }
  else
    return [super accessibilityIsAttributeSettable:attribute];
}

- (void)accessibilitySetValue:(id)value
		 forAttribute:(NSAccessibilityAttributeName)attribute
{
  NSUInteger index = [ax_attribute_names indexOfObject:attribute];

  if (index != NSNotFound)
    {
      struct frame *f = [self emacsFrame];
      struct input_event inev;
      Lisp_Object arg = Qnil, obj;

      if (NILP (AREF (ax_attribute_event_ids, index)))
	emacs_abort ();

      arg = Fcons (Fcons (Qwindow,
			  Fcons (build_string ("Lisp"),
				 f->selected_window)), arg);
      obj = cfobject_to_lisp ((__bridge CFTypeRef) value,
			      CFOBJECT_TO_LISP_FLAGS_FOR_EVENT, -1);
      arg = Fcons (Fcons (build_string ("----"),
			  Fcons (build_string ("Lisp"), obj)), arg);
      EVENT_INIT (inev);
      inev.kind = MAC_APPLE_EVENT;
      inev.x = Qaccessibility;
      inev.y = AREF (ax_attribute_event_ids, index);
      XSETFRAME (inev.frame_or_window, f);
      inev.arg = Fcons (build_string ("aevt"), arg);
      [emacsController storeEvent:&inev];
    }
  else
    [super accessibilitySetValue:value forAttribute:attribute];
}

- (NSArrayOf (NSAccessibilityParameterizedAttributeName) *)accessibilityParameterizedAttributeNames
{
  static NSArrayOf (NSAccessibilityParameterizedAttributeName) *names = nil;

  if (names == nil)
    names = MRC_RETAIN ([[super accessibilityAttributeNames]
			  arrayByAddingObjectsFromArray:ax_parameterized_attribute_names]);

  return names;
}

static id
ax_get_line_for_index (EmacsMainView *emacsView, id parameter)
{
  struct frame *f = [emacsView emacsFrame];
  EMACS_INT line;

  if (poll_suppress_count == 0 && !NILP (Vinhibit_quit))
    /* Don't try to get buffer contents as the gap might be being
       altered. */
    return nil;

  line = mac_ax_line_for_index (f, [(NSNumber *)parameter longValue]);

  return line >= 0 ? [NSNumber numberWithLong:line] : nil;
}

static id
ax_get_range_for_line (EmacsMainView *emacsView, id parameter)
{
  struct frame *f = [emacsView emacsFrame];
  EMACS_INT line;
  NSRange range;

  if (poll_suppress_count == 0 && !NILP (Vinhibit_quit))
    /* Don't try to get buffer contents as the gap might be being
       altered. */
    return nil;

  line = [(NSNumber *)parameter longValue];
  if (mac_ax_range_for_line (f, line, (CFRange *) &range))
    return [NSValue valueWithRange:range];
  else
    return nil;
}

static id
ax_get_string_for_range (EmacsMainView *emacsView, id parameter)
{
  NSRange range = [(NSValue *)parameter rangeValue];
  struct frame *f = [emacsView emacsFrame];
  CFStringRef string;

  if (poll_suppress_count == 0 && !NILP (Vinhibit_quit))
    /* Don't try to get buffer contents as the gap might be being
       altered. */
    return nil;

  string = mac_ax_create_string_for_range (f, (CFRange *) &range, NULL);

  return CF_BRIDGING_RELEASE (string);
}

static NSRect
ax_get_bounds_for_range_1 (EmacsMainView *emacsView, NSRange range)
{
  NSRange actualRange;
  NSRect rect;

  rect = [emacsView firstRectForCharacterRange:range actualRange:&actualRange];
  while (actualRange.length > 0)
    {
      NSRect rect1;

      if (actualRange.location > range.location)
	{
	  NSRange range1 = NSMakeRange (range.location,
					actualRange.location - range.location);

	  rect1 = ax_get_bounds_for_range_1 (emacsView, range1);
	  rect = NSUnionRect (rect, rect1);
	}
      if (NSMaxRange (actualRange) < NSMaxRange (range))
	{
	  range = NSMakeRange (NSMaxRange (actualRange),
			       NSMaxRange (range) - NSMaxRange (actualRange));
	  rect1 = [emacsView firstRectForCharacterRange:range
					    actualRange:&actualRange];
	  rect = NSUnionRect (rect, rect1);
	}
      else
	break;
    }

  return rect;
}

static id
ax_get_bounds_for_range (EmacsMainView *emacsView, id parameter)
{
  NSRange range = [(NSValue *)parameter rangeValue];
  NSRect rect;

  if (range.location >= NSNotFound)
    rect = [emacsView firstRectForCharacterRange:range actualRange:NULL];
  else
    rect = ax_get_bounds_for_range_1 (emacsView, range);

  return [NSValue valueWithRect:rect];
}

static id
ax_get_range_for_position (EmacsMainView *emacsView, id parameter)
{
  NSPoint position = [(NSValue *)parameter pointValue];
  NSUInteger index = [emacsView characterIndexForPoint:position];

  if (index == NSNotFound)
    return nil;
  else
    return [NSValue valueWithRange:(NSMakeRange (index, 1))];
}

static id
ax_get_range_for_index (EmacsMainView *emacsView, id parameter)
{
  NSRange range = NSMakeRange ([(NSNumber *)parameter unsignedLongValue], 1);

  return [NSValue valueWithRange:range];
}

static id
ax_get_rtf_for_range (EmacsMainView *emacsView, id parameter)
{
  NSRange range = [(NSValue *)parameter rangeValue];
  NSAttributedString *attributedString =
    [emacsView attributedSubstringForProposedRange:range actualRange:NULL];

  return [attributedString
	   RTFFromRange:(NSMakeRange (0, [attributedString length]))
	   documentAttributes:[NSDictionary dictionary]];
}

static id
ax_get_attributed_string_for_range (EmacsMainView *emacsView, id parameter)
{
  NSString *string = ax_get_string_for_range (emacsView, parameter);

  if (string)
    return MRC_AUTORELEASE ([[NSAttributedString alloc] initWithString:string]);
  else
    return nil;
}

- (id)accessibilityAttributeValue:(NSAccessibilityParameterizedAttributeName)attribute
		     forParameter:(id)parameter
{
  NSUInteger index = [ax_parameterized_attribute_names indexOfObject:attribute];

  if (index != NSNotFound)
    return (*ax_parameterized_attribute_table[index].handler) (self, parameter);
  else
    return [super accessibilityAttributeValue:attribute forParameter:parameter];
}

- (NSArrayOf (NSAccessibilityActionName) *)accessibilityActionNames
{
  static NSArrayOf (NSAccessibilityActionName) *names = nil;

  if (names == nil)
    names = MRC_RETAIN ([[super accessibilityActionNames]
			  arrayByAddingObjectsFromArray:ax_action_names]);

  return names;
}

- (void)accessibilityPerformAction:(NSAccessibilityActionName)theAction
{
  NSUInteger index = [ax_action_names indexOfObject:theAction];

  if (index != NSNotFound)
    {
      struct frame *f = [self emacsFrame];
      struct input_event inev;
      Lisp_Object arg = Qnil;

      arg = Fcons (Fcons (Qwindow,
			  Fcons (build_string ("Lisp"),
				 f->selected_window)), arg);
      EVENT_INIT (inev);
      inev.kind = MAC_APPLE_EVENT;
      inev.x = Qaccessibility;
      inev.y = AREF (ax_action_event_ids, index);
      XSETFRAME (inev.frame_or_window, f);
      inev.arg = Fcons (build_string ("aevt"), arg);
      [emacsController storeEvent:&inev];
    }
  else
    [super accessibilityPerformAction:theAction];
}

@end				// EmacsMainView (Accessibility)

@implementation EmacsFrameController (Accessibility)

- (void)postAccessibilityNotificationsToEmacsView
{
  NSAccessibilityPostNotification (emacsView,
				   ax_selected_text_changed_notification);
  NSAccessibilityPostNotification (emacsView,
				   NSAccessibilityValueChangedNotification);
}

@end			       // EmacsFrameController (Accessibility)

void
mac_update_accessibility_status (struct frame *f)
{
  EmacsFrameController *frameController = FRAME_CONTROLLER (f);

  [frameController postAccessibilityNotificationsToEmacsView];
}


/************************************************************************
			      Animation
 ************************************************************************/

@implementation EmacsFrameController (Animation)

- (void)setupAnimationLayer
{
  animationLayer = [CALayer layer];
  animationLayer.anchorPoint = CGPointZero;
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6)
    {
      CGFloat scaleFactor = [emacsWindow userSpaceScaleFactor];

      animationLayer.sublayerTransform =
	CATransform3DMakeScale (scaleFactor, scaleFactor, 1.0);
    }
#endif

  [CATransaction setDisableActions:YES];
  [[overlayView layer] addSublayer:animationLayer];
  [CATransaction commit];
}

- (CALayer *)layerForRect:(NSRect)rect
{
  NSRect rectInLayer = [emacsView convertRect:rect toView:overlayView];
  CALayer *layer, *contentLayer;
  NSBitmapImageRep *bitmap;

  layer = [CALayer layer];
  contentLayer = [CALayer layer];
  layer.frame = NSRectToCGRect (rectInLayer);
  layer.masksToBounds = YES;
  contentLayer.frame = CGRectMake (0, 0, NSWidth (rectInLayer),
				   NSHeight (rectInLayer));
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_12))
    bitmap = [self bitmapImageRepInEmacsViewRect:rect];
  else
    {
      NSRect fullHeightRect = [emacsView bounds];

      fullHeightRect.origin.x = NSMinX (rect);
      fullHeightRect.size.width = NSWidth (rect);
      bitmap = [self bitmapImageRepInEmacsViewRect:fullHeightRect];
      contentLayer.contentsRect =
	CGRectMake (0, NSMinY (rectInLayer) / NSHeight (fullHeightRect),
		    1, NSHeight (rectInLayer) / NSHeight (fullHeightRect));
    }
  contentLayer.contents = (id) [bitmap CGImage];
  [layer addSublayer:contentLayer];

  return layer;
}

- (void)addLayer:(CALayer *)layer
{
  [CATransaction setDisableActions:YES];
  [animationLayer addSublayer:layer];
  [CATransaction commit];
}

static Lisp_Object
get_symbol_from_filter_input_key (NSString *key)
{
  NSArrayOf (NSString *) *components =
    [key componentsSeparatedByCamelCasingWithCharactersInSet:nil];
  NSUInteger count = [components count];

  if (count > 1 && [[components objectAtIndex:0] isEqualToString:@"input"])
    {
      NSMutableArrayOf (NSString *) *symbolComponents =
	[NSMutableArray arrayWithCapacity:(count - 1)];
      NSUInteger index;
      Lisp_Object string;

      for (index = 1; index < count; index++)
	[symbolComponents addObject:[[components objectAtIndex:index]
				      lowercaseString]];
      string = [[symbolComponents componentsJoinedByString:@"-"]
		 UTF8LispString];
      AUTO_STRING (colon, ":");
      return Fintern (concat2 (colon, string), Qnil);
    }
  else
    return Qnil;
}

- (CIFilter *)transitionFilterFromProperties:(Lisp_Object)properties
{
  struct frame *f = emacsFrame;
  NSString *filterName;
  CIFilter *filter;
  NSDictionaryOf (NSString *, id) *attributes;
  Lisp_Object type = Fplist_get (properties, QCtype);

  if (EQ (type, Qbars_swipe))
    filterName = @"CIBarsSwipeTransition";
  else if (EQ (type, Qcopy_machine))
    filterName = @"CICopyMachineTransition";
  else if (EQ (type, Qdissolve))
    filterName = @"CIDissolveTransition";
  else if (EQ (type, Qflash))
    filterName = @"CIFlashTransition";
  else if (EQ (type, Qmod))
    filterName = @"CIModTransition";
  else if (EQ (type, Qpage_curl))
    filterName = @"CIPageCurlTransition";
  else if (EQ (type, Qpage_curl_with_shadow))
    {
      if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6)
	filterName = @"CIPageCurlTransition";
      else
	filterName = @"CIPageCurlWithShadowTransition";
    }
  else if (EQ (type, Qripple))
    filterName = @"CIRippleTransition";
  else if (EQ (type, Qswipe))
    filterName = @"CISwipeTransition";
  else
    return nil;

  filter = [CIFilter filterWithName:filterName];
  [filter setDefaults];
  if (EQ (type, Qbars_swipe)		   /* [0, 2pi], default pi */
      || EQ (type, Qcopy_machine)	   /* [0, 2pi], default 0 */
      || EQ (type, Qpage_curl)		   /* [-pi, pi], default 0 */
      || EQ (type, Qpage_curl_with_shadow) /* [-pi, pi], default 0 */
      || EQ (type, Qswipe))		   /* [-pi, pi], default 0 */
    {
      Lisp_Object direction = Fplist_get (properties, QCdirection);
      double direction_angle;

      if (EQ (direction, Qleft))
	direction_angle = M_PI;
      else if (EQ (direction, Qright))
	direction_angle = 0;
      else if (EQ (direction, Qdown))
	{
	  if (EQ (type, Qbars_swipe) || EQ (type, Qcopy_machine))
	    direction_angle = 3 * M_PI_2;
	  else
	    direction_angle = - M_PI_2;
	}
      else if (EQ (direction, Qup))
	direction_angle = M_PI_2;
      else
	direction = Qnil;

      if (!NILP (direction))
	[filter setValue:[NSNumber numberWithDouble:direction_angle]
		  forKey:kCIInputAngleKey];
    }

  if ([filterName isEqualToString:@"CIPageCurlTransition"]
      || EQ (type, Qripple))
    /* TODO: create a real shading image like
       /Library/Widgets/CI Filter Browser.wdgt/Images/restrictedshine.png */
    [filter setValue:[CIImage emptyImage] forKey:kCIInputShadingImageKey];

  attributes = [filter attributes];
  for (NSString *key in [filter inputKeys])
    {
      NSDictionary *keyAttributes = [attributes objectForKey:key];

      if ([[keyAttributes objectForKey:kCIAttributeClass]
	    isEqualToString:@"NSNumber"]
	  && ![key isEqualToString:kCIInputTimeKey])
	{
	  Lisp_Object symbol = get_symbol_from_filter_input_key (key);

	  if (!NILP (symbol))
	    {
	      Lisp_Object value = Fplist_get (properties, symbol);

	      if (NUMBERP (value))
		[filter setValue:[NSNumber numberWithDouble:(XFLOATINT (value))]
			  forKey:key];
	    }
	}
      else if ([[keyAttributes objectForKey:kCIAttributeType]
		 isEqualToString:kCIAttributeTypeOpaqueColor])
	{
	  Lisp_Object symbol = get_symbol_from_filter_input_key (key);

	  if (!NILP (symbol))
	    {
	      Lisp_Object value = Fplist_get (properties, symbol);
	      CGFloat components[4];
	      int i;

	      if (STRINGP (value))
		{
		  XColor xcolor;

		  if (mac_defined_color (f, SSDATA (value), &xcolor, 0))
		    value = list3 (make_number (xcolor.red),
				   make_number (xcolor.green),
				   make_number (xcolor.blue));
		}
	      for (i = 0; i < 3; i++)
		{
		  if (!CONSP (value))
		    break;
		  if (INTEGERP (XCAR (value)))
		    components[i] =
		      min (max (0, (CGFloat) XINT (XCAR (value)) / 65535), 1);
		  else if (FLOATP (XCAR (value)))
		    components[i] =
		      min (max (0, XFLOAT_DATA (XCAR (value))), 1);
		  else
		    break;
		  value = XCDR (value);
		}
	      if (i == 3 && NILP (value))
		{
		  CGColorRef cg_color;
		  CIColor *color;

		  components[3] = 1.0;
		  cg_color = CGColorCreate (mac_cg_color_space_rgb, components);
		  if (cg_color)
		    {
		      color = [CIColor colorWithCGColor:cg_color];
		      CGColorRelease (cg_color);
		    }
		  else
		    color = [CIColor colorWithRed:components[0]
					    green:components[1]
					     blue:components[2]];
		  [filter setValue:color forKey:key];
		}
	    }
	}
    }

  return filter;
}

- (void)adjustTransitionFilter:(CIFilter *)filter forLayer:(CALayer *)layer
{
  NSDictionaryOf (NSString *, id) *attributes = [filter attributes];
  CGFloat scaleFactor;

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1070
  if (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6)
    scaleFactor = [emacsWindow userSpaceScaleFactor];
  else
#endif
    scaleFactor = 1.0;

  if ([[[attributes objectForKey:kCIInputCenterKey]
	 objectForKey:kCIAttributeType]
	isEqualToString:kCIAttributeTypePosition])
    {
      CGPoint center = [layer position];

      [filter setValue:[CIVector vectorWithX:(center.x * scaleFactor)
					   Y:(center.y * scaleFactor)]
		forKey:kCIInputCenterKey];
    }

  if ([[attributes objectForKey:kCIAttributeFilterName]
	isEqualToString:@"CIPageCurlWithShadowTransition"]
      /* Mac OS X 10.7 automatically sets inputBacksideImage for
	 CIPageCurlTransition.  */
      || (floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_6
	  && [[attributes objectForKey:kCIAttributeFilterName]
	       isEqualToString:@"CIPageCurlTransition"]))
    {
      CGRect frame = layer.frame;
      CGAffineTransform atfm =
	CGAffineTransformMakeTranslation (CGRectGetMinX (frame) * scaleFactor,
					  CGRectGetMinY (frame) * scaleFactor);
      CALayer *contentLayer = [[layer sublayers] objectAtIndex:0];
      CIImage *image;

      if ([emacsWindow respondsToSelector:@selector(backingScaleFactor)])
	{
	  CGFloat scale = 1 / [emacsWindow backingScaleFactor];

	  atfm = CGAffineTransformScale (atfm, scale, scale);
	}

      image = [CIImage imageWithCGImage:((__bridge CGImageRef)
					 contentLayer.contents)];
      [filter setValue:[image imageByApplyingTransform:atfm]
		forKey:@"inputBacksideImage"];
    }
}

/* Delegate Methods  */

@end

void
mac_start_animation (Lisp_Object frame_or_window, Lisp_Object properties)
{
  struct frame *f;
  EmacsFrameController *frameController;
  CGRect rect;

  if (FRAMEP (frame_or_window))
    {
      f = XFRAME (frame_or_window);
      rect = mac_rect_make (f, 0, 0,
			    FRAME_PIXEL_WIDTH (f), FRAME_PIXEL_HEIGHT (f));
    }
  else
    {
      struct window *w = XWINDOW (frame_or_window);

      f = XFRAME (WINDOW_FRAME (w));
      rect = mac_rect_make (f, WINDOW_LEFT_EDGE_X (w), WINDOW_TOP_EDGE_Y (w),
			    WINDOW_PIXEL_WIDTH (w), WINDOW_PIXEL_HEIGHT (w));
    }
  frameController = FRAME_CONTROLLER (f);

  mac_within_gui (^{
      CIFilter *transitionFilter;
      CALayer *layer, *contentLayer;
      Lisp_Object direction, duration;
      CGFloat h_ratio, v_ratio;
      enum {
	ANIM_TYPE_NONE,
	ANIM_TYPE_MOVE_OUT,
	ANIM_TYPE_MOVE_IN,
	ANIM_TYPE_FADE_OUT,
	ANIM_TYPE_FADE_IN,
	ANIM_TYPE_TRANSITION_FILTER
      } anim_type;

      transitionFilter =
	[frameController transitionFilterFromProperties:properties];
      if (transitionFilter)
	anim_type = ANIM_TYPE_TRANSITION_FILTER;
      else
	{
	  Lisp_Object type;

	  direction = Fplist_get (properties, QCdirection);

	  type = Fplist_get (properties, QCtype);
	  if (EQ (type, Qnone))
	    anim_type = ANIM_TYPE_NONE;
	  else if (EQ (type, Qfade_in))
	    anim_type = ANIM_TYPE_FADE_IN;
	  else if (EQ (type, Qmove_in))
	    anim_type = ANIM_TYPE_MOVE_IN;
	  else if (EQ (direction, Qleft) || EQ (direction, Qright)
		   || EQ (direction, Qdown) || EQ (direction, Qup))
	    anim_type = ANIM_TYPE_MOVE_OUT;
	  else
	    anim_type = ANIM_TYPE_FADE_OUT;
	}

      layer = [frameController layerForRect:(NSRectFromCGRect (rect))];
      contentLayer = [[layer sublayers] objectAtIndex:0];

      if (anim_type == ANIM_TYPE_FADE_IN)
	contentLayer.opacity = 0;
      else if (anim_type == ANIM_TYPE_MOVE_OUT
	       || anim_type == ANIM_TYPE_MOVE_IN)
	{
	  h_ratio = v_ratio = 0;
	  if (EQ (direction, Qleft))
	    h_ratio = -1;
	  else if (EQ (direction, Qright))
	    h_ratio = 1;
	  else if (EQ (direction, Qdown))
	    v_ratio = -1;
	  else if (EQ (direction, Qup))
	    v_ratio = 1;

	  if (anim_type == ANIM_TYPE_MOVE_IN)
	    {
	      CGPoint position = contentLayer.position;

	      position.x -= CGRectGetWidth (layer.bounds) * h_ratio;
	      position.y -= CGRectGetHeight (layer.bounds) * v_ratio;
	      contentLayer.position = position;
	    }
	}

      if (anim_type == ANIM_TYPE_MOVE_OUT || anim_type == ANIM_TYPE_MOVE_IN)
	contentLayer.shadowOpacity = 1;

      [frameController addLayer:layer];

      duration = Fplist_get (properties, QCduration);
      if (NUMBERP (duration))
	[CATransaction setValue:[NSNumber
				  numberWithDouble:(XFLOATINT (duration))]
			 forKey:kCATransactionAnimationDuration];

      [CATransaction setCompletionBlock:^{
	  [CATransaction setDisableActions:YES];
	  [layer removeFromSuperlayer];
	}];
      switch (anim_type)
	{
	case ANIM_TYPE_NONE:
	  {
	    CGRect bounds = contentLayer.bounds;

	    /* Dummy change of property that does not affect the
	       appearance.  */
	    bounds.origin.x += 1;
	    contentLayer.bounds = bounds;
	  }
	  break;

	case ANIM_TYPE_FADE_OUT:
	  contentLayer.opacity = 0;
	  break;

	case ANIM_TYPE_FADE_IN:
	  contentLayer.opacity = 1;
	  break;

	case ANIM_TYPE_MOVE_OUT:
	case ANIM_TYPE_MOVE_IN:
	  {
	    CGPoint position = contentLayer.position;

	    position.x += CGRectGetWidth (layer.bounds) * h_ratio;
	    position.y += CGRectGetHeight (layer.bounds) * v_ratio;
	    contentLayer.position = position;
	  }
	  break;

	case ANIM_TYPE_TRANSITION_FILTER:
	  {
	    CATransition *transition = CATransition.animation;
	    NSMutableDictionaryOf (NSString *, id <CAAction>) *actions;
	    CALayer *newContentLayer;

	    [frameController adjustTransitionFilter:transitionFilter
					   forLayer:layer];
	    transition.filter = transitionFilter;

	    actions = [NSMutableDictionary
			dictionaryWithDictionary:[layer actions]];
	    [actions setObject:transition forKey:@"sublayers"];
	    layer.actions = actions;

	    newContentLayer = [CALayer layer];
	    newContentLayer.frame = contentLayer.frame;
	    newContentLayer.opacity = 0;
	    [layer replaceSublayer:contentLayer with:newContentLayer];
	  }
	  break;

	default:
	  emacs_abort ();
	}
    });
}


/************************************************************************
				Fonts
 ************************************************************************/

@implementation NSLayoutManager (Emacs)

/* Return union of enclosing rects for glyphRange in textContainer.  */

- (NSRect)enclosingRectForGlyphRange:(NSRange)glyphRange
		     inTextContainer:(NSTextContainer *)textContainer
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
  NSRect __block result = NSZeroRect;

  [self enumerateEnclosingRectsForGlyphRange:glyphRange
		    withinSelectedGlyphRange:(NSMakeRange (NSNotFound, 0))
			     inTextContainer:textContainer
				  usingBlock:^(NSRect rect, BOOL *stop) {
      result = NSUnionRect (result, rect);
    }];
#else
  NSRect result = NSZeroRect;
  NSUInteger i, nrects;
  NSRect *rects = [self rectArrayForGlyphRange:glyphRange
		      withinSelectedGlyphRange:(NSMakeRange (NSNotFound, 0))
			       inTextContainer:textContainer rectCount:&nrects];

  for (i = 0; i < nrects; i++)
    result = NSUnionRect (result, rects[i]);
#endif

  return result;
}

@end				// NSLayoutManager (Emacs)

#if MAC_OS_X_VERSION_MIN_REQUIRED < 101000
CGGlyph
mac_font_get_glyph_for_cid (CTFontRef font, CTCharacterCollection collection,
			    CGFontIndex cid)
{
  if (!(floor (NSAppKitVersionNumber) <= NSAppKitVersionNumber10_9))
    return mac_ctfont_get_glyph_for_cid (font, collection, cid);

  CGGlyph result = kCGFontIndexInvalid;
  NSFont *nsFont = (__bridge NSFont *) font;
  unichar characters[] = {0xfffd};
  NSString *string =
    [NSString stringWithCharacters:characters
			    length:(ARRAYELTS (characters))];
  NSGlyphInfo *glyphInfo =
    [NSGlyphInfo glyphInfoWithCharacterIdentifier:cid
				       collection:((NSCharacterCollection)
						   collection)
				       baseString:string];
  NSDictionaryOf (NSString *, id) *attributes =
    [NSDictionary dictionaryWithObjectsAndKeys:nsFont,NSFontAttributeName,
		  glyphInfo,NSGlyphInfoAttributeName,nil];
  NSTextStorage *textStorage =
    [[NSTextStorage alloc] initWithString:string
			       attributes:attributes];
  NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
  NSTextContainer *textContainer = [[NSTextContainer alloc] init];
  NSFont *fontInTextStorage;

  [layoutManager addTextContainer:textContainer];
  MRC_RELEASE (textContainer);
  [textStorage addLayoutManager:layoutManager];
  MRC_RELEASE (layoutManager);

  /* Force layout.  */
  (void) [layoutManager glyphRangeForTextContainer:textContainer];

  fontInTextStorage = [textStorage attribute:NSFontAttributeName atIndex:0
			      effectiveRange:NULL];
  if (fontInTextStorage == nsFont
      || [[fontInTextStorage fontName] isEqualToString:[nsFont fontName]])
    {
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
      result = [layoutManager CGGlyphAtIndex:0 isValidIndex:NULL];
#else
      NSGlyph glyph = [layoutManager glyphAtIndex:0];

      if (glyph < [nsFont numberOfGlyphs])
	result = glyph;
#endif
    }

  MRC_RELEASE (textStorage);

  return result;
}
#endif

CFIndex
mac_font_get_weight (CTFontRef font)
{
  NSFont *nsFont = (__bridge NSFont *) font;

  return [[NSFontManager sharedFontManager] weightOfFont:nsFont];
}

ScreenFontRef
mac_screen_font_create_with_name (CFStringRef name, CGFloat size)
{
  NSFont *result, *font;

  font = [NSFont fontWithName:((__bridge NSString *) name) size:size];
  result = [font screenFont];

  return CF_BRIDGING_RETAIN (result);
}

CGFloat
mac_screen_font_get_advance_width_for_glyph (ScreenFontRef font, CGGlyph glyph)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101300
  NSSize advancement = [(__bridge NSFont *)font advancementForCGGlyph:glyph];
#else
  NSSize advancement = [(__bridge NSFont *)font advancementForGlyph:glyph];
#endif

  return advancement.width;
}

Boolean
mac_screen_font_get_metrics (ScreenFontRef font, CGFloat *ascent,
			     CGFloat *descent, CGFloat *leading)
{
  NSFont *nsFont = (__bridge NSFont *) font;
  NSTextStorage *textStorage;
  NSLayoutManager *layoutManager;
  NSTextContainer *textContainer;
  NSRect usedRect;
  NSPoint spaceLocation;
  CGFloat descender;

  textStorage = [[NSTextStorage alloc] initWithString:@" "];
  layoutManager = [[NSLayoutManager alloc] init];
  textContainer = [[NSTextContainer alloc] init];

  [textStorage setFont:nsFont];
  [textContainer setLineFragmentPadding:0];

  [layoutManager addTextContainer:textContainer];
  MRC_RELEASE (textContainer);
  [textStorage addLayoutManager:layoutManager];
  MRC_RELEASE (layoutManager);

  if (!(textStorage && layoutManager && textContainer))
    {
      MRC_RELEASE (textStorage);

      return false;
    }

  usedRect = [layoutManager lineFragmentUsedRectForGlyphAtIndex:0
						 effectiveRange:NULL];
  spaceLocation = [layoutManager locationForGlyphAtIndex:0];
  MRC_RELEASE (textStorage);

  *ascent = spaceLocation.y;
  *descent = NSHeight (usedRect) - spaceLocation.y;
  *leading = 0;
  descender = [nsFont descender];
  if (- descender < *descent)
    {
      *leading = *descent + descender;
      *descent = - descender;
    }

  return true;
}

CFIndex
mac_screen_font_shape (ScreenFontRef screen_font, CFStringRef cf_string,
		       struct mac_glyph_layout *glyph_layouts,
		       CFIndex glyph_len)
{
  NSFont *font = (__bridge NSFont *) screen_font;
  NSString *string = (__bridge NSString *) cf_string;
  NSUInteger i;
  CFIndex result = 0;
  NSTextStorage *textStorage;
  NSLayoutManager *layoutManager;
  NSTextContainer *textContainer;
  NSUInteger stringLength;
  NSPoint spaceLocation;
  NSUInteger used, numberOfGlyphs;

  textStorage = [[NSTextStorage alloc] initWithString:string];
  layoutManager = [[NSLayoutManager alloc] init];
  textContainer = [[NSTextContainer alloc] init];

  /* Append a trailing space to measure baseline position.  */
  [textStorage appendAttributedString:(MRC_AUTORELEASE
				       ([[NSAttributedString alloc]
					  initWithString:@" "]))];
  [textStorage setFont:font];
  [textContainer setLineFragmentPadding:0];

  [layoutManager addTextContainer:textContainer];
  MRC_RELEASE (textContainer);
  [textStorage addLayoutManager:layoutManager];
  MRC_RELEASE (layoutManager);

  if (!(textStorage && layoutManager && textContainer))
    {
      MRC_RELEASE (textStorage);

      return 0;
    }

  stringLength = [string length];

  /* Force layout.  */
  (void) [layoutManager glyphRangeForTextContainer:textContainer];

  spaceLocation = [layoutManager locationForGlyphAtIndex:stringLength];

  /* Remove the appended trailing space because otherwise it may
     generate a wrong result for a right-to-left text.  */
  [textStorage beginEditing];
  [textStorage deleteCharactersInRange:(NSMakeRange (stringLength, 1))];
  [textStorage endEditing];
  (void) [layoutManager glyphRangeForTextContainer:textContainer];

  i = 0;
  while (i < stringLength)
    {
      NSRange range;
      NSFont *fontInTextStorage =
	[textStorage attribute:NSFontAttributeName atIndex:i
		     longestEffectiveRange:&range
		       inRange:(NSMakeRange (0, stringLength))];

      if (!(fontInTextStorage == font
	    || [[fontInTextStorage fontName] isEqualToString:[font fontName]]))
	break;
      i = NSMaxRange (range);
    }
  if (i < stringLength)
    /* Make the test `used <= glyph_len' below fail if textStorage
       contained some fonts other than the specified one.  */
    used = glyph_len + 1;
  else
    {
      NSRange range = NSMakeRange (0, stringLength);

      range = [layoutManager glyphRangeForCharacterRange:range
				    actualCharacterRange:NULL];
      numberOfGlyphs = NSMaxRange (range);
      used = numberOfGlyphs;
      for (i = 0; i < numberOfGlyphs; i++)
	if ([layoutManager notShownAttributeForGlyphAtIndex:i])
	  used--;
    }

  if (0 < used && used <= glyph_len)
    {
      NSUInteger glyphIndex, prevGlyphIndex;
      unsigned char bidiLevel;
      NSUInteger *permutation;
      NSRange compRange, range;
      CGFloat totalAdvance;

      glyphIndex = 0;
      while ([layoutManager notShownAttributeForGlyphAtIndex:glyphIndex])
	glyphIndex++;

      /* For now we assume the direction is not changed within the
	 string.  */
#if MAC_OS_X_VERSION_MAX_ALLOWED >= 101100
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
      if ([layoutManager
	    respondsToSelector:@selector(getGlyphsInRange:glyphs:properties:characterIndexes:bidiLevels:)])
#endif
	{
	  [layoutManager getGlyphsInRange:(NSMakeRange (glyphIndex, 1))
				   glyphs:NULL properties:NULL
			 characterIndexes:NULL bidiLevels:&bidiLevel];
	}
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101100
      else
#endif
#endif
#if MAC_OS_X_VERSION_MAX_ALLOWED < 101100 || MAC_OS_X_VERSION_MIN_REQUIRED < 101100
	{
	  [layoutManager getGlyphsInRange:(NSMakeRange (glyphIndex, 1))
				   glyphs:NULL characterIndexes:NULL
			glyphInscriptions:NULL elasticBits:NULL
			       bidiLevels:&bidiLevel];
	}
#endif
      if (bidiLevel & 1)
	permutation = xmalloc (sizeof (NSUInteger) * used);
      else
	permutation = NULL;

#define RIGHT_TO_LEFT_P permutation

      /* Fill the `comp_range' member of struct mac_glyph_layout, and
	 setup a permutation for right-to-left text.  */
      compRange = NSMakeRange (0, 0);
      for (range = NSMakeRange (0, 0); NSMaxRange (range) < used;
	   range.length++)
	{
	  struct mac_glyph_layout *gl = glyph_layouts + NSMaxRange (range);
	  NSUInteger characterIndex =
	    [layoutManager characterIndexForGlyphAtIndex:glyphIndex];

	  gl->string_index = characterIndex;

	  if (characterIndex >= NSMaxRange (compRange))
	    {
	      compRange.location = NSMaxRange (compRange);
	      do
		{
		  NSRange characterRange =
		    [string
		      rangeOfComposedCharacterSequenceAtIndex:characterIndex];

		  compRange.length =
		    NSMaxRange (characterRange) - compRange.location;
		  [layoutManager glyphRangeForCharacterRange:compRange
					actualCharacterRange:&characterRange];
		  characterIndex = NSMaxRange (characterRange) - 1;
		}
	      while (characterIndex >= NSMaxRange (compRange));

	      if (RIGHT_TO_LEFT_P)
		for (i = 0; i < range.length; i++)
		  permutation[range.location + i] = NSMaxRange (range) - i - 1;

	      range = NSMakeRange (NSMaxRange (range), 0);
	    }

	  gl->comp_range.location = compRange.location;
	  gl->comp_range.length = compRange.length;

	  while (++glyphIndex < numberOfGlyphs)
	    if (![layoutManager notShownAttributeForGlyphAtIndex:glyphIndex])
	      break;
	}
      if (RIGHT_TO_LEFT_P)
	for (i = 0; i < range.length; i++)
	  permutation[range.location + i] = NSMaxRange (range) - i - 1;

      /* Then fill the remaining members.  */
      glyphIndex = prevGlyphIndex = 0;
      while ([layoutManager notShownAttributeForGlyphAtIndex:glyphIndex])
	glyphIndex++;

      if (!RIGHT_TO_LEFT_P)
	totalAdvance = 0;
      else
	{
	  NSRect glyphRect =
	    [layoutManager enclosingRectForGlyphRange:(NSMakeRange
						       (0, numberOfGlyphs))
				      inTextContainer:textContainer];

	  totalAdvance = NSMaxX (glyphRect);
	}

      for (i = 0; i < used; i++)
	{
	  struct mac_glyph_layout *gl;
	  NSPoint location;
	  NSUInteger nextGlyphIndex;
	  NSRange glyphRange;
	  NSRect glyphRect;

	  if (!RIGHT_TO_LEFT_P)
	    gl = glyph_layouts + i;
	  else
	    {
	      NSUInteger dest = permutation[i];

	      gl = glyph_layouts + dest;
	      if (i < dest)
		{
		  CFIndex tmp = gl->string_index;

		  gl->string_index = glyph_layouts[i].string_index;
		  glyph_layouts[i].string_index = tmp;
		}
	    }

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101100
	  gl->glyph_id = [layoutManager CGGlyphAtIndex:glyphIndex];
#else
	  gl->glyph_id = [layoutManager glyphAtIndex:glyphIndex];
#endif
	  location = [layoutManager locationForGlyphAtIndex:glyphIndex];
	  gl->baseline_delta = spaceLocation.y - location.y;

	  for (nextGlyphIndex = glyphIndex + 1; nextGlyphIndex < numberOfGlyphs;
	       nextGlyphIndex++)
	    if (![layoutManager
		   notShownAttributeForGlyphAtIndex:nextGlyphIndex])
	      break;

	  if (!RIGHT_TO_LEFT_P)
	    {
	      CGFloat maxX;

	      if (prevGlyphIndex == 0)
		glyphRange = NSMakeRange (0, nextGlyphIndex);
	      else
		glyphRange = NSMakeRange (glyphIndex,
					  nextGlyphIndex - glyphIndex);
	      glyphRect =
		[layoutManager enclosingRectForGlyphRange:glyphRange
					  inTextContainer:textContainer];
	      maxX = max (NSMaxX (glyphRect), totalAdvance);
	      gl->advance_delta = location.x - totalAdvance;
	      gl->advance = maxX - totalAdvance;
	      totalAdvance = maxX;
	    }
	  else
	    {
	      CGFloat minX;

	      if (nextGlyphIndex == numberOfGlyphs)
		glyphRange = NSMakeRange (prevGlyphIndex,
					  numberOfGlyphs - prevGlyphIndex);
	      else
		glyphRange = NSMakeRange (prevGlyphIndex,
					  glyphIndex + 1 - prevGlyphIndex);
	      glyphRect =
		[layoutManager enclosingRectForGlyphRange:glyphRange
					  inTextContainer:textContainer];
	      minX = min (NSMinX (glyphRect), totalAdvance);
	      gl->advance = totalAdvance - minX;
	      totalAdvance = minX;
	      gl->advance_delta = location.x - totalAdvance;
	    }

	  prevGlyphIndex = glyphIndex + 1;
	  glyphIndex = nextGlyphIndex;
	}

      if (RIGHT_TO_LEFT_P)
	xfree (permutation);

#undef RIGHT_TO_LEFT_P

      result = used;
    }
  MRC_RELEASE (textStorage);

  return result;
}


/************************************************************************
				Sound
 ************************************************************************/

@implementation EmacsController (Sound)

- (void)sound:(NSSound *)sound didFinishPlaying:(BOOL)finishedPlaying
{
  [NSApp postDummyEvent];
}

@end

CFTypeRef
mac_sound_create (Lisp_Object file, Lisp_Object data)
{
  NSSound *sound;

  if (STRINGP (file))
    {
      file = ENCODE_FILE (file);
      sound = [[NSSound alloc]
		initWithContentsOfFile:[NSString stringWithUTF8LispString:file]
			   byReference:YES];
    }
  else if (STRINGP (data))
    sound = [[NSSound alloc]
	      initWithData:[NSData dataWithBytes:(SDATA (data))
					  length:(SBYTES (data))]];
  else
    sound = nil;

  return CF_BRIDGING_RETAIN (MRC_AUTORELEASE (sound));
}

void
mac_sound_play (CFTypeRef mac_sound, Lisp_Object volume, Lisp_Object device)
{
  NSSound *sound = (__bridge NSSound *) mac_sound;

  if ((INTEGERP (volume) || FLOATP (volume)))
    [sound setVolume:(INTEGERP (volume) ? XFASTINT (volume) * 0.01f
		      : (float) XFLOAT_DATA (volume))];
  if (STRINGP (device))
    [sound setPlaybackDeviceIdentifier:[NSString stringWithLispString:device]];

  [sound setDelegate:emacsController];
  [sound play];
  while ([sound isPlaying])
    mac_run_loop_run_once (kEventDurationForever);
}


/***********************************************************************
			Thread Synchronization
***********************************************************************/

/* Binary semaphores for synchronization between GUI and Lisp
   threads.  */
static dispatch_semaphore_t mac_gui_semaphore, mac_lisp_semaphore;

/* Queues of blocks to be executed in GUI or Lisp thread
   respectively.  */
static NSMutableArray *mac_gui_queue, *mac_lisp_queue;

/* Queues of blocks to be executed in Lisp thread at the end of the
   call to mac_within_gui_and_here.  */
static NSMutableArray *mac_deferred_lisp_queue;

/* Dispatch source to break the run loop in the GUI thread for the
   select emulation.  */
static dispatch_source_t mac_select_dispatch_source;

/* Command to execute in the GUI thread after the run loop is
   broken.  */
static enum
{
  MAC_SELECT_COMMAND_TERMINATE	= 1 << 0,
  MAC_SELECT_COMMAND_SUSPEND	= 1 << 1
} mac_select_next_command;

static void
mac_init_thread_synchronization (void)
{
  BEGIN_AUTORELEASE_POOL;

  mac_gui_semaphore = dispatch_semaphore_create (0);
  mac_lisp_semaphore = dispatch_semaphore_create (0);

  mac_gui_queue = [[NSMutableArray alloc] initWithCapacity:2];
  mac_lisp_queue = [[NSMutableArray alloc] initWithCapacity:1];
  mac_deferred_lisp_queue = [[NSMutableArray alloc] initWithCapacity:0];

  mac_select_next_command = MAC_SELECT_COMMAND_TERMINATE;
  mac_select_dispatch_source =
    dispatch_source_create (DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0,
			    dispatch_get_main_queue ());
  if (mac_select_dispatch_source == NULL)
    {
      fprintf (stderr, "Can't create dispatch source\n");
      exit (1);
    }
  dispatch_source_set_event_handler (mac_select_dispatch_source, ^{
      mac_select_next_command |=
	dispatch_source_get_data (mac_select_dispatch_source);
    });
  dispatch_resume (mac_select_dispatch_source);

  END_AUTORELEASE_POOL;
}

/* Keep synchronously executing blocks in `mac_gui_queue', which has
   been set by `mac_within_gui_and_here', in the GUI thread until the
   dequeued block is nil.  */

static void
mac_gui_loop (void)
{
  eassert (pthread_main_np ());
  void (^block) (void);

  do
    {
      BEGIN_AUTORELEASE_POOL;
      dispatch_semaphore_wait (mac_gui_semaphore, DISPATCH_TIME_FOREVER);
      block = [mac_gui_queue dequeue];
      if (block)
	block ();
      dispatch_semaphore_signal (mac_lisp_semaphore);
      END_AUTORELEASE_POOL;
    }
  while (block);
}

static void
mac_gui_loop_once (void)
{
  void (^block) (void);

  BEGIN_AUTORELEASE_POOL;
  dispatch_semaphore_wait (mac_gui_semaphore, DISPATCH_TIME_FOREVER);
  block = [mac_gui_queue dequeue];
  eassert (block);
  block ();
  dispatch_semaphore_signal (mac_lisp_semaphore);
  END_AUTORELEASE_POOL;
}

/* Ask execution of BLOCK to the GUI thread synchronously.  The
   calling thread must not be the GUI thread.  BLOCK will be executed
   in its own autorelease pool.  So if you want to bring back
   NSObjects from BLOCK via __block or global variables, make sure
   they are retained for non-ARC environments.  */

void
mac_within_gui (void (^ CF_NOESCAPE block) (void))
{
  mac_within_gui_and_here (block, NULL);
}

/* Ask execution of BLOCK_GUI to the GUI thread.  The calling thread
   must not be the GUI thread.  If BLOCK_HERE is non-nil, then it is
   also executed in the calling Lisp thread simultaneously.  Control
   returns when the both executions has finished.  */

static void
mac_within_gui_and_here (void (^ CF_NOESCAPE block_gui) (void),
			 void (^ CF_NOESCAPE block_here) (void))
{
  eassert (!pthread_main_np ());
  eassert (mac_gui_queue.count <= 1);

  [mac_gui_queue enqueue:block_gui];
  dispatch_source_merge_data (mac_select_dispatch_source,
			      MAC_SELECT_COMMAND_SUSPEND);
  dispatch_semaphore_signal (mac_gui_semaphore);
  if (block_here)
    block_here ();
  dispatch_semaphore_wait (mac_lisp_semaphore, DISPATCH_TIME_FOREVER);
  if (mac_deferred_lisp_queue.count)
    {
      NSMutableArray *queue = mac_deferred_lisp_queue;

      mac_deferred_lisp_queue = [[NSMutableArray alloc] initWithCapacity:0];
      do
	{
	  void (^block) (void) = [queue dequeue];

	  block ();
	}
      while (queue.count);
      MRC_RELEASE (queue);
      eassert (mac_deferred_lisp_queue.count == 0);
    }
}

/* Ask execution of BLOCK to the GUI thread synchronously with
   allowing block executions in the calling Lisp thread via
   `mac_within_lisp' from the BLOCK_GUI context.  The calling thread
   must not be the GUI thread.  */

static void
mac_within_gui_allowing_inner_lisp (void (^ CF_NOESCAPE block) (void))
{
  eassert (!pthread_main_np ());
  bool __block completed_p = false;

  mac_within_gui (^{
      block ();
      completed_p = true;
    });
  while (!completed_p)
    {
      void (^block_lisp) (void) = [mac_lisp_queue dequeue];

      block_lisp ();
      mac_within_gui (nil);
      dispatch_semaphore_wait (mac_lisp_semaphore, DISPATCH_TIME_FOREVER);
    }
}

/* Ask synchronous execution of BLOCK to the Lisp thread that has
   called `mac_within_gui_allowing_inner_lisp'.  This should be used
   in the context of the block argument of
   `mac_within_gui_allowing_inner_lisp'.  One can use `mac_within_gui'
   etc. in the context of BLOCK.  */

static void
mac_within_lisp (void (^ CF_NOESCAPE block) (void))
{
  eassert (pthread_main_np ());
  eassert (mac_lisp_queue.count == 0);
  eassert (block);

  [mac_lisp_queue enqueue:block];
  dispatch_semaphore_signal (mac_lisp_semaphore);
  mac_gui_loop ();
}

/* Ask deferred execution of BLOCK to the Lisp thread.  This should be
   used in the context of the block argument of `mac_within_gui' etc.
   BLOCK is called at the end of `mac_within_gui' etc. call.  One can
   use `mac_within_gui' etc. in the context of BLOCK.  */

static void
mac_within_lisp_deferred (void (^block) (void))
{
  eassert (pthread_main_np ());
  eassert (block);

  [mac_deferred_lisp_queue enqueue:(MRC_AUTORELEASE ([block copy]))];
}

/* Ask execution of BLOCK to the Lisp thread.  Process BLOCK
   synchronously if some popup menu or dialog is in use, and otherwise
   deferred.  */

static void
mac_within_lisp_deferred_unless_popup (void (^block) (void))
{
  if (popup_activated ())
    mac_within_lisp (block);
  else
    mac_within_lisp_deferred (block);
}


/***********************************************************************
			   Select emulation
***********************************************************************/

/* File descriptors of the socket pair used for breaking pselect calls
   in Lisp threads.  One direction, writing to mac_select_fds[0] and
   reading from mac_select_fds[1], is for notifying termination of the
   run loop in the GUI thread.  The other direction, writing to
   mac_select_fds[1] and reading from mac_select_fds[0] is for
   notifying delivery of SIGALRM.  */
static int mac_select_fds[2];

/* Whether buffer and glyph matrix access from the GUI thread is
   restricted to the case that no Lisp thread is running.  */
static bool mac_buffer_and_glyph_matrix_access_restricted_p;

static int
read_all_from_nonblocking_fd (int fd)
{
  int rtnval;
  char buf[64];

  do
    {
      rtnval = read (fd, buf, sizeof (buf));
    }
  while (rtnval > 0 || (rtnval < 0 && errno == EINTR));

  return rtnval;
}

static int
write_one_byte_to_fd (int fd)
{
  int rtnval;

  do
    {
      rtnval = write (fd, "", 1);
    }
  while (rtnval == 0 || (rtnval < 0 && errno == EINTR));

  return rtnval;
}

static void
mac_init_select_fds (void)
{
  int err, i;

  err = socketpair (AF_UNIX, SOCK_STREAM, 0, mac_select_fds);
  if (err < 0)
    {
      emacs_perror ("Can't create socketpair");
      exit (1);
    }
  for (i = 0; i < 2; i++)
    {
      int flags;

      if ((flags = fcntl (mac_select_fds[i], F_GETFL, 0)) < 0
	  || fcntl (mac_select_fds[i], F_SETFL, flags | O_NONBLOCK) == -1
	  || (flags = fcntl (mac_select_fds[i], F_GETFD, 0)) < 0
	  || fcntl (mac_select_fds[i], F_SETFD, flags | FD_CLOEXEC) == -1)
	{
	  emacs_perror ("Can't make select fds non-blocking");
	  exit (1);
	}
    }
}

int
mac_get_select_fd (void)
{
  return mac_select_fds[1];
}

void
mac_handle_alarm_signal (void)
{
  if (initialized)
    write_one_byte_to_fd (mac_select_fds[1]);
}

/* Restrict/unrestrict buffer and glyph matrix access from the GUI
   thread to the case that no Lisp thread is running.  */

static void
mac_set_buffer_and_glyph_matrix_access_restricted (bool flag)
{
#if MAC_OS_X_VERSION_MIN_REQUIRED < 101400
  /* Temporarily disable autodisplay if the Lisp thread may switch to
     another one and some drawing may happen there.  */
  Lisp_Object tail, frame;

  FOR_EACH_FRAME (tail, frame)
    {
      struct frame *f = XFRAME (frame);

      if (FRAME_MAC_P (f)
	  && !FRAME_MAC_DOUBLE_BUFFERED_P (f))
	{
	  EmacsWindow *window = FRAME_MAC_WINDOW_OBJECT (f);

	  [window setAutodisplay:!flag];
	}
    }
#endif

  mac_buffer_and_glyph_matrix_access_restricted_p = flag;
}

static bool
mac_try_buffer_and_glyph_matrix_access (void)
{
  if (mac_buffer_and_glyph_matrix_access_restricted_p)
    return !thread_try_acquire_global_lock ();

  return true;
}

static void
mac_end_buffer_and_glyph_matrix_access (void)
{
  if (mac_buffer_and_glyph_matrix_access_restricted_p)
    thread_release_global_lock ();
}

int
mac_select (int nfds, fd_set *rfds, fd_set *wfds, fd_set *efds,
	    struct timespec *timeout, sigset_t *sigmask)
{
  bool __block has_event_p, thread_may_switch_p;
  int __block r;

  if (!initialized)
    return thread_select (pselect, nfds, rfds, wfds, efds, timeout, sigmask);

  read_all_from_nonblocking_fd (mac_select_fds[0]);

  if (inhibit_window_system || noninteractive || nfds <= mac_select_fds[1]
      || rfds == NULL || !FD_ISSET (mac_select_fds[1], rfds))
    {
      fd_set rfds_fallback;

      if (rfds == NULL)
	{
	  FD_ZERO (&rfds_fallback);
	  rfds = &rfds_fallback;
	}
      FD_SET (mac_select_fds[0], rfds);
      if (nfds <= mac_select_fds[0])
	nfds = mac_select_fds[0] + 1;

      r = thread_select (pselect, nfds, rfds, wfds, efds, timeout, sigmask);

      if (r > 0 && FD_ISSET (mac_select_fds[0], rfds))
	{
	  /* SIGALRM is delivered.  */
	  FD_CLR (mac_select_fds[0], rfds);
	  errno = EINTR;
	  r = -1;
	}

      return r;
    }

  /* Check if some input is already available.  We need to block input
     because run loop may call back drawRect:.  */
  block_input ();
  mac_within_gui_and_here (^{
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
			       beforeDate:[NSDate date]];
      has_event_p = (mac_peek_next_event () != NULL);
    },
    ^{
      fd_set orfds, owfds, oefds;
      struct timespec select_timeout = make_timespec (0, 0);

      orfds = *rfds;
      if (wfds) owfds = *wfds;
      if (efds) oefds = *efds;

      read_all_from_nonblocking_fd (mac_select_fds[1]);

      FD_CLR (mac_select_fds[1], rfds);
      r = pselect (nfds, rfds, wfds, efds, &select_timeout, sigmask);
      if (r == 0)
	{
	  *rfds = orfds;
	  if (wfds) *wfds = owfds;
	  if (efds) *efds = oefds;
	}
    });
  unblock_input ();

  /* unblock_input above might have read some events.  */
  if (has_event_p || detect_input_pending ())
    {
      /* Pretend that `select' is interrupted by a signal.  */
      errno = EINTR;

      return -1;
    }
  else if (r != 0 || (timeout && timespec_sign (*timeout) == 0))
    return r;

  block_input ();
  turn_on_atimers (false);
  thread_may_switch_p = !NILP (XCDR (Fall_threads ()));
  mac_within_gui_and_here (^{
      if (thread_may_switch_p)
	mac_set_buffer_and_glyph_matrix_access_restricted (true);
      while (true)
	{
	  mac_select_next_command = 0;
	  /* On macOS 10.12, the application sometimes becomes
	     unresponsive to Dock icon clicks (though it reacts to
	     Command-Tab) if we directly run a run loop and the
	     application windows are covered by other applications for
	     a while.  */
	  mac_within_app (^{
	      NSRunLoop *currentRunLoop = [NSRunLoop currentRunLoop];
	      NSDate *limit = [NSDate distantFuture];
	      bool written_p = false;

	      /* On Mac OS X 10.7, delayed visible toolbar item
		 validation (see the documentation of -[NSToolbar
		 validateVisibleItems]) is treated as if it were an
		 input source firing rather than a timer function (as
		 in Mac OS X 10.6).  So it makes -[NSRunLoop
		 runMode:beforeDate:] return despite no available
		 input to process.  In such cases, we want to call
		 -[NSRunLoop runMode:beforeDate:] again so as to avoid
		 wasting CPU time caused by vacuous reactivation of
		 delayed visible toolbar item validation via window
		 update events issued in the application event
		 loop.  */
	      do
		{
		  [currentRunLoop runMode:NSDefaultRunLoopMode
			       beforeDate:limit];
		  if (!written_p && (mac_peek_next_event () != NULL
				     || detect_input_pending ()
				     || emacs_windows_need_display_p ()))
		    {
		      write_one_byte_to_fd (mac_select_fds[0]);
		      written_p = true;
		    }
		  if ((mac_select_next_command & MAC_SELECT_COMMAND_SUSPEND)
		      && mac_gui_queue.count == 0)
		    /* Bogus suspend command: would be a residual from
		       the previous round.  */
		    mac_select_next_command &= ~MAC_SELECT_COMMAND_SUSPEND;
		}
	      while (!mac_select_next_command);
	    });
	  if (mac_select_next_command & MAC_SELECT_COMMAND_TERMINATE)
	    break;
	  else
	    mac_gui_loop_once ();
	}
      if (thread_may_switch_p)
	mac_set_buffer_and_glyph_matrix_access_restricted (false);
    },
    ^{
      r = thread_select (pselect, nfds, rfds, wfds, efds, timeout, sigmask);
      dispatch_source_merge_data (mac_select_dispatch_source,
				  MAC_SELECT_COMMAND_TERMINATE);
      if (r > 0 && FD_ISSET (mac_select_fds[1], rfds))
	/* Pretend that `select' is interrupted by a signal.  */
	r = -1;
    });
  turn_on_atimers (true);
  unblock_input ();

  if (r < 0 || detect_input_pending ())
    {
      /* Pretend that `select' is interrupted by a signal.  */
      errno = EINTR;

      return -1;
    }

  return r;
}


/***********************************************************************
			       Startup
***********************************************************************/

/* Thread ID of the Lisp main thread.  This should be the same as
   `main_thread_id' in sysdep.c.  Note that this is not the thread ID
   of the main/initial thread, which is dedicated to GUI
   processing.  */

static pthread_t mac_lisp_main_thread_id;

/* The entry point of the Lisp main thread.  */

static void *
mac_start_lisp_main (void *arg)
{
  char **argv = (char **) arg;
  int argc = 1;

  pthread_setname_np ("org.gnu.Emacs.lisp-main");

  while (argv[argc])
    argc++;

  emacs_main (argc, argv);

  return 0;
}

/* Return true if the current thread is the GUI thread.  */

bool
mac_gui_thread_p (void)
{
  return initialized && pthread_main_np ();
}

/* The entry point of the main/initial thread.  */

int
main (int argc, char **argv)
{
  int err;
  pthread_attr_t attr;
  struct rlimit rlim;

  if (!initialized)
    return emacs_main (argc, argv);

  if (getenv ("EMACS_REINVOKED_FROM_SHELL"))
    unsetenv ("EMACS_REINVOKED_FROM_SHELL");
  else
    {
      char *shlvl = getenv ("SHLVL");

      if (shlvl == NULL || atoi (shlvl) == 0)
	{
	  CFBundleRef bundle = CFBundleGetMainBundle ();

	  /* Reinvoke the current executable using the helper script
	     in .../Emacs.app/Contents/MacOS/Emacs.sh so the
	     application can get environment variables from the login
	     shell if necessary.  Previously we invoked the helper
	     script directly by specifying it as the value for
	     CFBundleExecutable in Info.plist.  But this makes
	     LookupViewSource invoked by Command-Control-D or
	     three-finger tap crash on OS X 10.10.3.  This is because
	     the ViewBridge framework tries to create a bundle object
	     from the URL obtained by SecCodeCopyPath, which does not
	     store the URL for the application bundle but the one for
	     the executable if CFBundleExecutable does not correspond
	     to the running application process.  */
	  if (bundle && CFBundleGetIdentifier (bundle))
	    {
	      char **new = alloca ((argc + 1) * sizeof *new);
	      size_t len = strlen (argv[0]);

	      new[0] = alloca (len + sizeof (".sh"));
	      strcpy (new[0], argv[0]);
	      strcpy (new[0] + len, ".sh");
	      memcpy (new + 1, argv + 1, argc * sizeof *new);
	      execvp (new[0], new);
	    }
	}
    }

  mac_init_thread_synchronization ();
  mac_init_select_fds ();

  err = pthread_attr_init (&attr);
  if (!err)
    err = pthread_attr_setdetachstate (&attr, PTHREAD_CREATE_DETACHED);
  /* Calculation of the stack size from emacs.c.  */
  if (!err && !getrlimit (RLIMIT_STACK, &rlim)
      && 0 <= rlim.rlim_cur && rlim.rlim_cur <= LONG_MAX)
    {
      rlim_t lim = rlim.rlim_cur;

      /* Approximate the amount regex.c needs per unit of
	 emacs_re_max_failures, then add 33% to cover the size of the
	 smaller stacks that regex.c successively allocates and
	 discards on its way to the maximum.  */
      int min_ratio = 20 * sizeof (char *);
      int ratio = min_ratio + min_ratio / 3;

      /* Extra space to cover what we're likely to use for other
         reasons.  For example, a typical GC might take 30K stack
         frames.  */
      int extra = (30 * 1000) * 50;

      bool try_to_grow_stack = true;
#ifndef CANNOT_DUMP
      try_to_grow_stack = !noninteractive || initialized;
#endif

      if (try_to_grow_stack)
	{
	  rlim_t newlim = emacs_re_max_failures * ratio + extra;

	  /* Round the new limit to a page boundary; this is needed
	     for Darwin kernel 15.4.0 (see Bug#23622) and perhaps
	     other systems.  Do not shrink the stack and do not exceed
	     rlim_max.  Don't worry about exact values of
	     RLIM_INFINITY etc. since in practice when they are
	     nonnegative they are so large that the code does the
	     right thing anyway.  */
	  long pagesize = getpagesize ();
	  newlim += pagesize - 1;
	  if (0 <= rlim.rlim_max && rlim.rlim_max < newlim)
	    newlim = rlim.rlim_max;
	  newlim -= newlim % pagesize;

	  if (newlim > lim	/* in case rlim_t is an unsigned type */
	      && pagesize <= newlim - lim)
	    rlim.rlim_cur = newlim;
	}

      err = pthread_attr_setstacksize (&attr, rlim.rlim_cur);
    }
  if (!err)
    err = pthread_create (&mac_lisp_main_thread_id, &attr, mac_start_lisp_main,
			  argv);
  if (err)
    {
      fprintf (stderr, "Can't create Lisp main thread: %s\n", strerror (err));
      exit (1);
    }
  pthread_attr_destroy (&attr);

  mac_gui_loop ();

  emacs_abort ();
}
