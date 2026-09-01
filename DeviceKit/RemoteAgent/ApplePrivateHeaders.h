#ifndef ApplePrivateHeaders_h
#define ApplePrivateHeaders_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>
#import <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// IOKit & IOHIDEvent Types & Constants
// ============================================================================

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef uint32_t IOHIDEventField;
typedef uint32_t IOOptionBits;
typedef double IOHIDFloat;

#define IOHIDEventFieldBase(type) ((type) << 16)

enum {
    kIOHIDEventTypeNULL               = 0,
    kIOHIDEventTypeVendorDefined      = 1,
    kIOHIDEventTypeButton             = 2,
    kIOHIDEventTypeKeyboard           = 3,
    kIOHIDEventTypeTranslation        = 4,
    kIOHIDEventTypeRotation           = 5,
    kIOHIDEventTypeScroll             = 6,
    kIOHIDEventTypeScale              = 7,
    kIOHIDEventTypeZoom               = 8,
    kIOHIDEventTypeVelocity           = 9,
    kIOHIDEventTypeOrientation        = 10,
    kIOHIDEventTypeDigitizer          = 11,
    kIOHIDEventTypeAmbientLightSensor = 12,
    kIOHIDEventTypeAccelerometer      = 13,
    kIOHIDEventTypeProximity          = 14,
    kIOHIDEventTypeTemperature        = 15,
    kIOHIDEventTypeNavigationSwipe    = 16,
    kIOHIDEventTypePointer            = 17,
    kIOHIDEventTypeProgress           = 18,
    kIOHIDEventTypeForce              = 32
};

enum {
    kIOHIDDigitizerTransducerTypeStylus = 0,
    kIOHIDDigitizerTransducerTypePuck   = 1,
    kIOHIDDigitizerTransducerTypeFinger = 2,
    kIOHIDDigitizerTransducerTypeHand   = 3
};

enum {
    kIOHIDDigitizerEventRange       = 1 << 0,
    kIOHIDDigitizerEventTouch       = 1 << 1,
    kIOHIDDigitizerEventPosition    = 1 << 2,
    kIOHIDDigitizerEventStop        = 1 << 3,
    kIOHIDDigitizerEventPeak        = 1 << 4,
    kIOHIDDigitizerEventIdentity    = 1 << 5,
    kIOHIDDigitizerEventAttribute   = 1 << 6,
    kIOHIDDigitizerEventCancel      = 1 << 7,
    kIOHIDDigitizerEventUpdate      = 1 << 8
};

enum {
    kIOHIDDigitizerEventFieldRange             = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | 0x01,
    kIOHIDDigitizerEventFieldTouch             = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | 0x02,
    kIOHIDDigitizerEventFieldPositionX         = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | 0x03,
    kIOHIDDigitizerEventFieldPositionY         = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | 0x04,
    kIOHIDDigitizerEventFieldPositionZ         = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | 0x05,
    kIOHIDDigitizerEventFieldPressure          = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | 0x06,
    kIOHIDDigitizerEventFieldEventMask         = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | 0x0B,
    kIOHIDDigitizerEventFieldChildEventMask    = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | 0x0C,
    kIOHIDDigitizerEventFieldTransducerIndex   = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | 0x0E,
    kIOHIDDigitizerEventFieldTransducerType    = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | 0x0F,
    kIOHIDDigitizerEventFieldIdentity          = IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) | 0x10
};

// Function prototypes for dynamic loading via dlsym
typedef IOHIDEventRef (*IOHIDEventCreateDigitizerFingerEventWithUserDataFunc)(
    CFAllocatorRef allocator,
    uint64_t timeStamp,
    uint32_t index,
    uint32_t identity,
    uint32_t eventMask,
    IOHIDFloat x,
    IOHIDFloat y,
    IOHIDFloat z,
    IOHIDFloat tipPressure,
    IOHIDFloat twist,
    Boolean range,
    Boolean touch,
    IOOptionBits options,
    void *userData
);

typedef IOHIDEventRef (*IOHIDEventCreateDigitizerEventFunc)(
    CFAllocatorRef allocator,
    uint64_t timeStamp,
    uint32_t transducerType,
    uint32_t index,
    uint32_t identity,
    uint32_t eventMask,
    uint32_t buttonMask,
    IOHIDFloat x,
    IOHIDFloat y,
    IOHIDFloat z,
    IOHIDFloat tipPressure,
    IOHIDFloat barrelPressure,
    Boolean range,
    Boolean touch,
    IOOptionBits options
);

typedef IOHIDEventRef (*IOHIDEventCreateKeyboardEventFunc)(
    CFAllocatorRef allocator,
    uint64_t timeStamp,
    uint32_t usagePage,
    uint32_t usage,
    Boolean down,
    IOOptionBits options
);

typedef void (*IOHIDEventAppendEventFunc)(IOHIDEventRef parent, IOHIDEventRef child);
typedef void (*IOHIDEventSetIntegerValueFunc)(IOHIDEventRef event, IOHIDEventField field, int value);
typedef void (*BKSHIDServicesPostEventFunc)(IOHIDEventRef event);

// ============================================================================
// IOKit Power & Thermal Source API Prototypes
// ============================================================================

typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_connect_t;
typedef io_object_t io_registry_entry_t;
typedef io_object_t io_iterator_t;

#define kIOMasterPortDefault 0
io_service_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching);
CFMutableDictionaryRef IOServiceMatching(const char *name);
CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options);
kern_return_t IOObjectRelease(io_object_t object);

// ============================================================================
// Private Application Services Prototypes
// ============================================================================

typedef void (*BKSTerminateApplicationForReasonAndReportWithDescriptionFunc)(
    NSString *bundleIdentifier,
    int reason,
    bool report,
    NSString *description
);

#ifdef __cplusplus
}
#endif

// ============================================================================
// LSApplicationWorkspace Objective-C Interface
// ============================================================================

@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
- (BOOL)openURL:(NSURL *)url;
- (NSArray *)allInstalledApplications;
@end

#endif /* ApplePrivateHeaders_h */
