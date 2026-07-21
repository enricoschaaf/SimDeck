#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <VideoToolbox/VideoToolbox.h>

#import "SimDeckCameraShared.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

static SimDeckCameraHeader *gHeader;
static size_t gFrameMapSize;
static uint64_t gLastDeliveredSequence;
static CVPixelBufferPoolRef gBGRAPool;
static size_t gBGRAPoolWidth;
static size_t gBGRAPoolHeight;
static CVPixelBufferPoolRef gMirrorPool;
static size_t gMirrorPoolWidth;
static size_t gMirrorPoolHeight;
static OSType gMirrorPoolPixelFormat;
static CIContext *gImageContext;
static dispatch_source_t gFrameTimer;
static dispatch_queue_t gFrameQueue;
static NSMutableArray<NSValue *> *gSessions;
static NSMutableArray<NSValue *> *gVideoOutputs;
static NSHashTable<AVSampleBufferDisplayLayer *> *gPreviewLayers;
static NSMutableSet<NSString *> *gHookedVideoOutputClasses;
static uint32_t gLastAppliedMirrorMode = UINT32_MAX;

static char kSessionInputsKey;
static char kSessionOutputsKey;
static char kSessionRunningKey;
static char kInputFakeKey;
static char kInputDeviceKey;
static char kOutputDelegateKey;
static char kOutputQueueKey;
static char kOutputVideoSettingsKey;
static char kOutputDiscardsLateFramesKey;
static char kOutputDeliveryPendingKey;
static char kOutputConnectionKey;
static char kPreviewOverlayKey;
static char kPreviewHostKey;
static char kPreviewSessionKey;
static char kPickerOverlayViewKey;
static char kPickerCaptureControlKey;
static char kPickerCameraOverlayKey;
static char kPickerCaptureWindowKey;
static char kBrowserActiveFormatKey;

static void StartFrameTimer(void);
static void InstallVideoOutputDelegateHook(Class cls);
static void Log(NSString *format, ...);
static void DebugLog(NSString *format, ...);
static BOOL OpenSharedCamera(void);
static void TrackPointer(NSMutableArray<NSValue *> *pointers, id object);
static void RegisterOutputLayer(CALayer *layer);
static void RegisterPreviewLayer(CALayer *layer);
static void SendPickerCapture(UIImagePickerController *picker);
static AVCaptureConnection *CameraConnectionForOutput(AVCaptureOutput *output);

static CFStringRef ColorPrimariesAttachment(uint32_t value) {
    switch (value) {
        case SIMDECK_CAMERA_COLOR_PRIMARIES_ITU_R_709_2:
            return kCVImageBufferColorPrimaries_ITU_R_709_2;
        case SIMDECK_CAMERA_COLOR_PRIMARIES_P3_D65:
            return kCVImageBufferColorPrimaries_P3_D65;
        case SIMDECK_CAMERA_COLOR_PRIMARIES_ITU_R_2020:
            return kCVImageBufferColorPrimaries_ITU_R_2020;
        default:
            return NULL;
    }
}

static CFStringRef TransferFunctionAttachment(uint32_t value) {
    switch (value) {
        case SIMDECK_CAMERA_TRANSFER_FUNCTION_ITU_R_709_2:
            return kCVImageBufferTransferFunction_ITU_R_709_2;
        case SIMDECK_CAMERA_TRANSFER_FUNCTION_SRGB:
            return kCVImageBufferTransferFunction_sRGB;
        case SIMDECK_CAMERA_TRANSFER_FUNCTION_ITU_R_2020:
            return kCVImageBufferTransferFunction_ITU_R_2020;
        default:
            return NULL;
    }
}

static CFStringRef YCbCrMatrixAttachment(uint32_t value) {
    switch (value) {
        case SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_601_4:
            return kCVImageBufferYCbCrMatrix_ITU_R_601_4;
        case SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_709_2:
            return kCVImageBufferYCbCrMatrix_ITU_R_709_2;
        case SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_2020:
            return kCVImageBufferYCbCrMatrix_ITU_R_2020;
        default:
            return NULL;
    }
}

static void ApplyColorAttachments(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer || !gHeader) return;
    CFStringRef primaries = ColorPrimariesAttachment(gHeader->colorPrimaries);
    CFStringRef transfer = TransferFunctionAttachment(gHeader->transferFunction);
    CFStringRef matrix = YCbCrMatrixAttachment(gHeader->yCbCrMatrix);
    if (primaries) {
        CVBufferSetAttachment(pixelBuffer,
                              kCVImageBufferColorPrimariesKey,
                              primaries,
                              kCVAttachmentMode_ShouldPropagate);
    }
    if (transfer) {
        CVBufferSetAttachment(pixelBuffer,
                              kCVImageBufferTransferFunctionKey,
                              transfer,
                              kCVAttachmentMode_ShouldPropagate);
    }
    if (matrix) {
        CVBufferSetAttachment(pixelBuffer,
                              kCVImageBufferYCbCrMatrixKey,
                              matrix,
                              kCVAttachmentMode_ShouldPropagate);
    }
}

static BOOL IsVideoMediaType(AVMediaType mediaType) {
    return mediaType == nil || [mediaType isEqualToString:AVMediaTypeVideo];
}

static void SimDeckSetSampleBufferDelegate(AVCaptureVideoDataOutput *output,
                                           SEL selector,
                                           id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate,
                                           dispatch_queue_t sampleBufferCallbackQueue) {
    (void)selector;
    objc_setAssociatedObject(output, &kOutputDelegateKey, delegate, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(output, &kOutputQueueKey, sampleBufferCallbackQueue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized(gVideoOutputs) {
        TrackPointer(gVideoOutputs, output);
    }
}

static void TrackPointer(NSMutableArray<NSValue *> *pointers, id object) {
    if (!pointers || !object) return;
    void *pointer = (__bridge void *)object;
    for (NSValue *value in pointers) {
        if (value.pointerValue == pointer) return;
    }
    [pointers addObject:[NSValue valueWithPointer:pointer]];
}

static void RegisterOutputLayer(CALayer *host) {
    if (!host) return;
    AVSampleBufferDisplayLayer *layer = objc_getAssociatedObject(host, &kPreviewOverlayKey);
    if (!layer) {
        layer = [AVSampleBufferDisplayLayer layer];
        layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        layer.masksToBounds = YES;
        layer.frame = host.bounds;
        objc_setAssociatedObject(layer, &kPreviewHostKey, host, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(host, &kPreviewOverlayKey, layer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSublayer:layer];
    }
    @synchronized(gPreviewLayers) {
        [gPreviewLayers addObject:layer];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer setAffineTransform:gHeader &&
                                        SimDeckCameraLoadMirrorMode(gHeader) == SIMDECK_CAMERA_MIRROR_ON
        ? CGAffineTransformMakeScale(-1, 1)
        : CGAffineTransformIdentity];
    [CATransaction commit];
}

static void RegisterPreviewLayer(CALayer *layer) {
    if (!layer) return;
    RegisterOutputLayer(layer);
    DebugLog(@"installed sample-buffer preview layer on %@", NSStringFromClass(object_getClass(layer)));
}

static void SimDeckSetVideoSettings(AVCaptureVideoDataOutput *output,
                                    SEL selector,
                                    NSDictionary *videoSettings) {
    (void)selector;
    objc_setAssociatedObject(output, &kOutputVideoSettingsKey, videoSettings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    InstallVideoOutputDelegateHook(object_getClass(output));
    DebugLog(@"captured video settings on %@", NSStringFromClass(object_getClass(output)));
}

static id SimDeckVideoDataOutputAllocWithZone(Class cls, SEL selector, struct _NSZone *zone) {
    (void)selector;
    (void)zone;
    if (cls == AVCaptureVideoDataOutput.class && OpenSharedCamera()) {
        Class fakeClass = objc_getClass("SimDeckCameraVideoDataOutput");
        if (fakeClass) return class_createInstance(fakeClass, 0);
    }
    struct objc_super superInfo = {
        .receiver = cls,
        .super_class = class_getSuperclass(object_getClass(cls)),
    };
    return ((id (*)(struct objc_super *, SEL, struct _NSZone *))objc_msgSendSuper)(&superInfo, @selector(allocWithZone:), zone);
}

static void Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "[simdeck-camera] %s\n", message.UTF8String ?: "");
}

static BOOL DebugLoggingEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("SIMDECK_CAMERA_DEBUG");
        enabled = value && value[0] != '\0' && strcmp(value, "0") != 0;
    });
    return enabled;
}

static void DebugLog(NSString *format, ...) {
    if (!DebugLoggingEnabled()) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "[simdeck-camera] %s\n", message.UTF8String ?: "");
}

typedef struct {
    uint64_t generation;
    uint64_t sequence;
    uint64_t timestampNs;
    uint32_t mirrorMode;
    uint32_t ringSlot;
    uint32_t surfaceID;
} SimDeckFrameDescriptor;

typedef struct {
    uint64_t generation;
    size_t width;
    size_t height;
    OSType pixelFormat;
    CMVideoFormatDescriptionRef format;
} SimDeckFormatCache;

static SimDeckFormatCache gFormatCaches[2];

static BOOL ShouldInstallForCurrentProcess(void) {
    const char *rawTargets = getenv("SIMDECK_CAMERA_TARGET_BUNDLE_IDS");
    if (!rawTargets || rawTargets[0] == '\0') return YES;

    NSString *targets = [NSString stringWithUTF8String:rawTargets];
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"";
    for (NSString *rawTarget in [targets componentsSeparatedByString:@","]) {
        NSString *target = [rawTarget stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([target isEqualToString:@"__SIMDECK_USER_APPS__"] &&
            bundleID.length > 0 &&
            ![bundleID hasPrefix:@"com.apple."] &&
            ![bundleID hasSuffix:@".xctrunner"]) {
            return YES;
        }
        if ([target isEqualToString:bundleID] || [target isEqualToString:processName]) return YES;
    }
    return NO;
}

static BOOL IsBrowserCameraProcess(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"";
    return [bundleID isEqualToString:@"com.apple.mobilesafari"] ||
           [bundleID isEqualToString:@"com.apple.SafariViewService"] ||
           [processName isEqualToString:@"MobileSafari"] ||
           [processName isEqualToString:@"SafariViewService"] ||
           [processName isEqualToString:@"com.apple.WebKit.GPU"];
}

static BOOL IsBrowserUIProcess(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"";
    return [bundleID isEqualToString:@"com.apple.mobilesafari"] ||
           [bundleID isEqualToString:@"com.apple.SafariViewService"] ||
           [processName isEqualToString:@"MobileSafari"] ||
           [processName isEqualToString:@"SafariViewService"];
}

static BOOL OpenSharedCamera(void) {
    if (gHeader) return YES;
    const char *name = getenv("SIMDECK_CAMERA_SHM_NAME");
    if (!name || name[0] == '\0') {
        name = getenv("SIMCAM_SHM_NAME");
    }
    if (!name || name[0] == '\0') {
        return NO;
    }
    int fd = shm_open(name, O_RDWR, 0);
    if (fd < 0) {
        Log(@"unable to open shared memory %s", name);
        return NO;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)SIMDECK_CAMERA_HEADER_SIZE) {
        close(fd);
        return NO;
    }
    void *mapped = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        return NO;
    }
    SimDeckCameraHeader *header = (SimDeckCameraHeader *)mapped;
    if (header->magic != SIMDECK_CAMERA_MAGIC || header->version != SIMDECK_CAMERA_VERSION) {
        munmap(mapped, (size_t)st.st_size);
        return NO;
    }
    gHeader = header;
    gFrameMapSize = (size_t)st.st_size;
    // Surface use counts are shared atomic references across the app and browser
    // camera processes. consumerPid is observability only; resetting counts here
    // would let a later Safari consumer reuse a surface still retained by the app.
    __sync_lock_test_and_set(&gHeader->consumerPid, (uint32_t)getpid());
    DebugLog(@"attached surface feed %ux%u", header->width, header->height);
    return YES;
}

static BOOL BrowserCameraDeviceAvailable(void) {
    return IsBrowserUIProcess() || OpenSharedCamera();
}

static NSInteger gConsumerSlot = -1;
static uint32_t gProcessActiveConsumers = 0;

static BOOL EnsureConsumerSlot(void) {
    if (!OpenSharedCamera()) return NO;
    uint32_t pid = (uint32_t)getpid();
    if (gConsumerSlot >= 0 &&
        gConsumerSlot < SIMDECK_CAMERA_CONSUMER_SLOT_COUNT &&
        __atomic_load_n(&gHeader->consumers[gConsumerSlot].pid, __ATOMIC_ACQUIRE) == pid) {
        return YES;
    }
    for (uint32_t index = 0; index < SIMDECK_CAMERA_CONSUMER_SLOT_COUNT; index += 1) {
        uint32_t current = __atomic_load_n(&gHeader->consumers[index].pid, __ATOMIC_ACQUIRE);
        if (current == pid ||
            (current == 0 && __sync_bool_compare_and_swap(&gHeader->consumers[index].pid, 0, pid))) {
            gConsumerSlot = (NSInteger)index;
            return YES;
        }
    }
    return NO;
}

static void RegisterCameraConsumer(void) {
    if (!EnsureConsumerSlot()) return;
    gProcessActiveConsumers += 1;
    __atomic_store_n(&gHeader->consumers[gConsumerSlot].count,
                     gProcessActiveConsumers,
                     __ATOMIC_RELEASE);
    __sync_fetch_and_add(&gHeader->consumerRevision, 1);
}

static void UnregisterCameraConsumer(void) {
    if (!gHeader || gConsumerSlot < 0 || gProcessActiveConsumers == 0) return;
    gProcessActiveConsumers -= 1;
    __atomic_store_n(&gHeader->consumers[gConsumerSlot].count,
                     gProcessActiveConsumers,
                     __ATOMIC_RELEASE);
    if (gProcessActiveConsumers == 0) {
        __sync_bool_compare_and_swap(&gHeader->consumers[gConsumerSlot].pid,
                                     (uint32_t)getpid(),
                                     0);
        gConsumerSlot = -1;
    }
    __sync_fetch_and_add(&gHeader->consumerRevision, 1);
}

static CVPixelBufferRef CurrentPixelBuffer(BOOL requireNewFrame,
                                           SimDeckFrameDescriptor *outDescriptor) {
    if (!OpenSharedCamera()) return NULL;
    if (gFrameMapSize < SIMDECK_CAMERA_HEADER_SIZE) return NULL;
    SimDeckFrameDescriptor descriptor = {0};
    BOOL acquired = NO;
    for (int attempt = 0; attempt < 4; attempt += 1) {
        uint64_t before = gHeader->sequence;
        if ((before & 1u) != 0) {
            continue;
        }
        uint32_t slot = gHeader->ringSlot;
        if (slot >= SIMDECK_CAMERA_SURFACE_RING_SIZE) return NULL;
        descriptor.generation = gHeader->generation;
        descriptor.sequence = before;
        descriptor.timestampNs = gHeader->timestampNs;
        descriptor.mirrorMode = SimDeckCameraLoadMirrorMode(gHeader);
        descriptor.ringSlot = slot;
        descriptor.surfaceID = gHeader->surfaceIds[slot];
        uint64_t after = gHeader->sequence;
        if (before == after && (after & 1u) == 0) {
            if (requireNewFrame && before == gLastDeliveredSequence) return NULL;
            if (descriptor.surfaceID == 0 || descriptor.sequence == 0) return NULL;
            __sync_fetch_and_add(&gHeader->surfaceUseCounts[slot], 1);
            if (gHeader->sequence != before || gHeader->surfaceIds[slot] != descriptor.surfaceID) {
                __sync_fetch_and_sub(&gHeader->surfaceUseCounts[slot], 1);
                descriptor.surfaceID = 0;
                continue;
            }
            acquired = YES;
            break;
        }
    }
    if (!acquired) return NULL;
    IOSurfaceRef surface = IOSurfaceLookup(descriptor.surfaceID);
    if (!surface) {
        __sync_fetch_and_sub(&gHeader->surfaceUseCounts[descriptor.ringSlot], 1);
        __sync_fetch_and_add(&gHeader->surfaceLookupFailures, 1);
        return NULL;
    }
    CVPixelBufferRef pixelBuffer = NULL;
    CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &pixelBuffer);
    // The shared count only closes the descriptor-to-IOSurfaceLookup race. The
    // returned pixel buffer retains the IOSurface for its downstream lifetime.
    __sync_fetch_and_sub(&gHeader->surfaceUseCounts[descriptor.ringSlot], 1);
    CFRelease(surface);
    if (!pixelBuffer) {
        __sync_fetch_and_add(&gHeader->surfaceLookupFailures, 1);
        return NULL;
    }
    ApplyColorAttachments(pixelBuffer);
    if (requireNewFrame) gLastDeliveredSequence = descriptor.sequence;
    gHeader->consumedSequence = descriptor.sequence;
    if (outDescriptor) *outDescriptor = descriptor;
    return pixelBuffer;
}

static CMVideoFormatDescriptionRef FormatForPixelBuffer(CVPixelBufferRef pixelBuffer,
                                                        uint64_t generation,
                                                        NSUInteger cacheIndex) {
    if (!pixelBuffer || cacheIndex >= 2) return NULL;
    SimDeckFormatCache *cache = &gFormatCaches[cacheIndex];
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (cache->format && cache->generation == generation &&
        cache->width == width && cache->height == height &&
        cache->pixelFormat == pixelFormat) {
        return cache->format;
    }
    if (cache->format) CFRelease(cache->format);
    cache->format = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                                    pixelBuffer,
                                                                    &cache->format);
    if (status != noErr || !cache->format) {
        return NULL;
    }
    cache->generation = generation;
    cache->width = width;
    cache->height = height;
    cache->pixelFormat = pixelFormat;
    return cache->format;
}

static CMSampleBufferRef CreateSampleBuffer(CVPixelBufferRef pixelBuffer,
                                            uint64_t generation,
                                            uint64_t timestampNs,
                                            NSUInteger cacheIndex) {
    CMVideoFormatDescriptionRef format = FormatForPixelBuffer(pixelBuffer, generation, cacheIndex);
    if (!format) {
        if (gHeader) __sync_fetch_and_add(&gHeader->sampleBufferFailures, 1);
        return NULL;
    }
    CMTime pts = CMTimeMake((int64_t)timestampNs, 1000000000);
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                               pixelBuffer,
                                                               format,
                                                               &timing,
                                                               &sample);
    if (sample) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
    }
    if (status != noErr && gHeader) __sync_fetch_and_add(&gHeader->sampleBufferFailures, 1);
    return status == noErr ? sample : NULL;
}

static CVPixelBufferRef ConvertToBGRA(CVPixelBufferRef source) {
    size_t width = CVPixelBufferGetWidth(source);
    size_t height = CVPixelBufferGetHeight(source);
    if (!gBGRAPool || gBGRAPoolWidth != width || gBGRAPoolHeight != height) {
        if (gBGRAPool) CVPixelBufferPoolRelease(gBGRAPool);
        gBGRAPool = NULL;
        NSDictionary *attributes = @{
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                NULL,
                                (__bridge CFDictionaryRef)attributes,
                                &gBGRAPool);
        gBGRAPoolWidth = width;
        gBGRAPoolHeight = height;
    }
    if (!gBGRAPool) return NULL;
    CVPixelBufferRef output = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, gBGRAPool, &output) != kCVReturnSuccess) {
        return NULL;
    }
    if (!gImageContext) {
        gImageContext = [[CIContext contextWithOptions:@{ kCIContextWorkingColorSpace: [NSNull null] }] retain];
    }
    CIImage *image = [CIImage imageWithCVPixelBuffer:source];
    if (!image) {
        CVPixelBufferRelease(output);
        return NULL;
    }
    [gImageContext render:image toCVPixelBuffer:output];
    if (gHeader) __sync_fetch_and_add(&gHeader->pixelConversions, 1);
    return output;
}

static CVPixelBufferRef MirrorPixelBuffer(CVPixelBufferRef source) {
    size_t width = CVPixelBufferGetWidth(source);
    size_t height = CVPixelBufferGetHeight(source);
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(source);
    BOOL isNV12 = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                  pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    if (!isNV12 && pixelFormat != kCVPixelFormatType_32BGRA) return NULL;

    if (!gMirrorPool || gMirrorPoolWidth != width || gMirrorPoolHeight != height ||
        gMirrorPoolPixelFormat != pixelFormat) {
        if (gMirrorPool) CVPixelBufferPoolRelease(gMirrorPool);
        gMirrorPool = NULL;
        NSDictionary *poolAttributes = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
        };
        NSDictionary *pixelBufferAttributes = @{
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height),
            (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                (__bridge CFDictionaryRef)poolAttributes,
                                (__bridge CFDictionaryRef)pixelBufferAttributes,
                                &gMirrorPool);
        gMirrorPoolWidth = width;
        gMirrorPoolHeight = height;
        gMirrorPoolPixelFormat = pixelFormat;
    }
    if (!gMirrorPool) return NULL;

    CVPixelBufferRef output = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, gMirrorPool, &output) != kCVReturnSuccess) {
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferRelease(output);
        return NULL;
    }
    if (CVPixelBufferLockBaseAddress(output, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(output);
        return NULL;
    }

    vImage_Error result = kvImageNoError;
    if (isNV12 && CVPixelBufferGetPlaneCount(source) == 2 && CVPixelBufferGetPlaneCount(output) == 2) {
        vImage_Buffer sourceY = {
            .data = CVPixelBufferGetBaseAddressOfPlane(source, 0),
            .height = CVPixelBufferGetHeightOfPlane(source, 0),
            .width = CVPixelBufferGetWidthOfPlane(source, 0),
            .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(source, 0),
        };
        vImage_Buffer outputY = {
            .data = CVPixelBufferGetBaseAddressOfPlane(output, 0),
            .height = CVPixelBufferGetHeightOfPlane(output, 0),
            .width = CVPixelBufferGetWidthOfPlane(output, 0),
            .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(output, 0),
        };
        vImage_Buffer sourceUV = {
            .data = CVPixelBufferGetBaseAddressOfPlane(source, 1),
            .height = CVPixelBufferGetHeightOfPlane(source, 1),
            .width = CVPixelBufferGetWidthOfPlane(source, 1),
            .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(source, 1),
        };
        vImage_Buffer outputUV = {
            .data = CVPixelBufferGetBaseAddressOfPlane(output, 1),
            .height = CVPixelBufferGetHeightOfPlane(output, 1),
            .width = CVPixelBufferGetWidthOfPlane(output, 1),
            .rowBytes = CVPixelBufferGetBytesPerRowOfPlane(output, 1),
        };
        result = vImageHorizontalReflect_Planar8(&sourceY, &outputY, kvImageNoFlags);
        if (result == kvImageNoError) {
            result = vImageHorizontalReflect_Planar16U(&sourceUV, &outputUV, kvImageNoFlags);
        }
    } else if (pixelFormat == kCVPixelFormatType_32BGRA) {
        vImage_Buffer sourceBGRA = {
            .data = CVPixelBufferGetBaseAddress(source),
            .height = height,
            .width = width,
            .rowBytes = CVPixelBufferGetBytesPerRow(source),
        };
        vImage_Buffer outputBGRA = {
            .data = CVPixelBufferGetBaseAddress(output),
            .height = height,
            .width = width,
            .rowBytes = CVPixelBufferGetBytesPerRow(output),
        };
        result = vImageHorizontalReflect_ARGB8888(&sourceBGRA, &outputBGRA, kvImageNoFlags);
    } else {
        result = kvImageInvalidParameter;
    }

    CVPixelBufferUnlockBaseAddress(output, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    if (result != kvImageNoError) {
        CVPixelBufferRelease(output);
        return NULL;
    }
    CVBufferPropagateAttachments(source, output);
    ApplyColorAttachments(output);
    if (gHeader) {
        __sync_fetch_and_add(&gHeader->geometryConversions, 1);
        __sync_fetch_and_add(&gHeader->fullFrameCopies, 1);
    }
    return output;
}

static UIImage *CurrentFrameImage(void) {
    SimDeckFrameDescriptor descriptor = {0};
    CVPixelBufferRef pixelBuffer = CurrentPixelBuffer(NO, &descriptor);
    if (!pixelBuffer) return nil;
    if (!gImageContext) {
        gImageContext = [[CIContext contextWithOptions:@{ kCIContextWorkingColorSpace: [NSNull null] }] retain];
    }
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (ciImage && descriptor.mirrorMode == SIMDECK_CAMERA_MIRROR_ON) {
        CGFloat width = (CGFloat)CVPixelBufferGetWidth(pixelBuffer);
        ciImage = [ciImage imageByApplyingTransform:CGAffineTransformMake(-1, 0, 0, 1, width, 0)];
    }
    CGImageRef image = ciImage
        ? [gImageContext createCGImage:ciImage fromRect:CGRectMake(0, 0,
                                                                  CVPixelBufferGetWidth(pixelBuffer),
                                                                  CVPixelBufferGetHeight(pixelBuffer))]
        : NULL;
    CVPixelBufferRelease(pixelBuffer);
    if (!image) return nil;
    UIImage *uiImage = [UIImage imageWithCGImage:image scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
    CGImageRelease(image);
    if (gHeader) {
        __sync_fetch_and_add(&gHeader->pixelConversions, 1);
        __sync_fetch_and_add(&gHeader->fullFrameCopies, 1);
    }
    return uiImage;
}

static OSType RequestedPixelFormat(AVCaptureVideoDataOutput *output, OSType sourceFormat) {
    NSDictionary *settings = objc_getAssociatedObject(output, &kOutputVideoSettingsKey);
    NSNumber *value = settings[(id)kCVPixelBufferPixelFormatTypeKey];
    return value ? (OSType)value.unsignedIntValue : sourceFormat;
}

static void DeliverSample(CMSampleBufferRef sample, AVCaptureVideoDataOutput *output) {
    if (!sample || !output) return;
    id delegate = objc_getAssociatedObject(output, &kOutputDelegateKey);
    dispatch_queue_t queue = objc_getAssociatedObject(output, &kOutputQueueKey);
    if (!delegate || ![delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        return;
    }
    @synchronized(output) {
        if ([objc_getAssociatedObject(output, &kOutputDeliveryPendingKey) boolValue]) {
            if (gHeader) __sync_fetch_and_add(&gHeader->consumerDroppedFrames, 1);
            return;
        }
        objc_setAssociatedObject(output, &kOutputDeliveryPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CFRetain(sample);
    AVCaptureConnection *connection = CameraConnectionForOutput(output);
    dispatch_async(queue ?: dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))objc_msgSend)(
            delegate,
            @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
            output,
            sample,
            connection);
        @synchronized(output) {
            objc_setAssociatedObject(output, &kOutputDeliveryPendingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CFRelease(sample);
    });
}

static void DeliverFrame(void) {
    BOOL mirrorChanged = NO;
    if (OpenSharedCamera()) {
        uint32_t mirrorMode = SimDeckCameraLoadMirrorMode(gHeader);
        mirrorChanged = mirrorMode != gLastAppliedMirrorMode;
        gLastAppliedMirrorMode = mirrorMode;
    }
    SimDeckFrameDescriptor descriptor = {0};
    CVPixelBufferRef pixelBuffer = CurrentPixelBuffer(!mirrorChanged, &descriptor);
    if (!pixelBuffer) return;
    OSType sourceFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    uint64_t presentationTimestampNs = (uint64_t)(CACurrentMediaTime() * 1000000000.0);
    CVPixelBufferRef mirroredBuffer = NULL;
    CVPixelBufferRef deliveryBuffer = pixelBuffer;
    if (descriptor.mirrorMode == SIMDECK_CAMERA_MIRROR_ON && !IsBrowserCameraProcess()) {
        mirroredBuffer = MirrorPixelBuffer(pixelBuffer);
        if (!mirroredBuffer) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
        deliveryBuffer = mirroredBuffer;
    }
    CMSampleBufferRef deliverySample = CreateSampleBuffer(deliveryBuffer,
                                                          descriptor.generation,
                                                          presentationTimestampNs,
                                                          0);
    CMSampleBufferRef previewSample = deliverySample;
    if (mirroredBuffer) {
        previewSample = CreateSampleBuffer(pixelBuffer,
                                           descriptor.generation,
                                           presentationTimestampNs,
                                           0);
    }
    CVPixelBufferRef bgraBuffer = NULL;
    CMSampleBufferRef bgraSample = NULL;
    NSArray *outputs = nil;
    @synchronized(gVideoOutputs) {
        outputs = [gVideoOutputs copy];
    }
    for (NSValue *value in outputs) {
        AVCaptureVideoDataOutput *output = (__bridge AVCaptureVideoDataOutput *)value.pointerValue;
        OSType requested = RequestedPixelFormat(output, sourceFormat);
        if (requested == kCVPixelFormatType_32BGRA && sourceFormat != kCVPixelFormatType_32BGRA) {
            if (!bgraBuffer) {
                bgraBuffer = ConvertToBGRA(deliveryBuffer);
                if (bgraBuffer) {
                    bgraSample = CreateSampleBuffer(bgraBuffer,
                                                    descriptor.generation,
                                                    presentationTimestampNs,
                                                    1);
                }
            }
            DeliverSample(bgraSample, output);
        } else {
            DeliverSample(deliverySample, output);
        }
    }
    [outputs release];

    if (previewSample) {
        NSArray<AVSampleBufferDisplayLayer *> *layers = nil;
        @synchronized(gPreviewLayers) {
            layers = gPreviewLayers.allObjects;
        }
        CFRetain(previewSample);
        dispatch_async(dispatch_get_main_queue(), ^{
            for (AVSampleBufferDisplayLayer *layer in layers) {
                CALayer *host = objc_getAssociatedObject(layer, &kPreviewHostKey);
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                if (host) layer.frame = host.bounds;
                if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
                    [layer flush];
                }
                [layer setAffineTransform:descriptor.mirrorMode == SIMDECK_CAMERA_MIRROR_ON
                    ? CGAffineTransformMakeScale(-1, 1)
                    : CGAffineTransformIdentity];
                [layer enqueueSampleBuffer:previewSample];
                [CATransaction commit];
            }
            CFRelease(previewSample);
        });
    }
    if (bgraSample) CFRelease(bgraSample);
    if (mirroredBuffer && previewSample) CFRelease(previewSample);
    if (deliverySample) CFRelease(deliverySample);
    if (bgraBuffer) CVPixelBufferRelease(bgraBuffer);
    if (mirroredBuffer) CVPixelBufferRelease(mirroredBuffer);
    CVPixelBufferRelease(pixelBuffer);
    if (gHeader) __sync_fetch_and_add(&gHeader->deliveredFrames, 1);
}

static void StartFrameTimer(void) {
    if (gFrameTimer) return;
    if (!gFrameQueue) {
        gFrameQueue = dispatch_queue_create("dev.nativescript.simdeck.camera.injector", DISPATCH_QUEUE_SERIAL);
    }
    gFrameTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gFrameQueue);
    dispatch_source_set_timer(gFrameTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 60),
                              (uint64_t)(NSEC_PER_MSEC));
    dispatch_source_set_event_handler(gFrameTimer, ^{
        DeliverFrame();
    });
    dispatch_resume(gFrameTimer);
}

static void AddSessionOutput(AVCaptureSession *session, AVCaptureOutput *output) {
    NSMutableArray *outputs = objc_getAssociatedObject(session, &kSessionOutputsKey);
    if (!outputs) {
        outputs = [NSMutableArray array];
        objc_setAssociatedObject(session, &kSessionOutputsKey, outputs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (![outputs containsObject:output]) [outputs addObject:output];
    if ([output isKindOfClass:AVCaptureVideoDataOutput.class]) {
        @synchronized(gVideoOutputs) {
            TrackPointer(gVideoOutputs, output);
        }
    }
}

static BOOL SimDeckIsFakeInput(id input) {
    return [objc_getAssociatedObject(input, &kInputFakeKey) boolValue];
}

static BOOL ShouldUseSimDeckInput(AVCaptureDevice *device) {
    if (!device || !OpenSharedCamera()) return NO;
    Class deviceClass = objc_getClass("SimDeckCameraDevice");
    if (deviceClass && [device isKindOfClass:deviceClass]) return YES;
    return IsBrowserCameraProcess() && [device hasMediaType:AVMediaTypeVideo];
}

static AVCaptureDeviceInput *SimDeckFakeInput(void) {
    static AVCaptureDeviceInput *input;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        input = (AVCaptureDeviceInput *)class_createInstance(AVCaptureDeviceInput.class, 0);
        objc_setAssociatedObject(input, &kInputFakeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        Class deviceClass = objc_getClass("SimDeckCameraDevice");
        id device = ((id (*)(Class, SEL))objc_msgSend)(deviceClass, @selector(sharedDevice));
        objc_setAssociatedObject(input, &kInputDeviceKey, device, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
    return input;
}

static BOOL ClassIsSubclassOf(Class cls, Class parent) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        if (current == parent) return YES;
    }
    return NO;
}

static void InstallVideoOutputDelegateHook(Class cls) {
    if (!cls) return;
    @synchronized(gHookedVideoOutputClasses) {
        NSString *name = NSStringFromClass(cls);
        if ([gHookedVideoOutputClasses containsObject:name]) return;
        [gHookedVideoOutputClasses addObject:name];
    }
    Method original = class_getInstanceMethod(cls, @selector(setSampleBufferDelegate:queue:));
    if (!original) {
        Log(@"missing video output delegate hook on %@", NSStringFromClass(cls));
        return;
    }
    class_replaceMethod(cls,
                        @selector(setSampleBufferDelegate:queue:),
                        (IMP)SimDeckSetSampleBufferDelegate,
                        method_getTypeEncoding(original));
    Method settings = class_getInstanceMethod(cls, @selector(setVideoSettings:));
    if (settings) {
        class_replaceMethod(cls,
                            @selector(setVideoSettings:),
                            (IMP)SimDeckSetVideoSettings,
                            method_getTypeEncoding(settings));
    }
    DebugLog(@"hooked video output delegate on %@", NSStringFromClass(cls));
}

static void InstallExistingVideoOutputDelegateHooks(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);
    for (int index = 0; index < count; index += 1) {
        Class cls = classes[index];
        if (ClassIsSubclassOf(cls, AVCaptureVideoDataOutput.class)) {
            InstallVideoOutputDelegateHook(cls);
        }
    }
    free(classes);
}

static void InstallVideoOutputAllocationHook(void) {
    Method alloc = class_getClassMethod(AVCaptureVideoDataOutput.class, @selector(allocWithZone:));
    Class meta = object_getClass(AVCaptureVideoDataOutput.class);
    if (!alloc || !meta) {
        Log(@"missing video output allocation hook");
        return;
    }
    class_replaceMethod(meta,
                        @selector(allocWithZone:),
                        (IMP)SimDeckVideoDataOutputAllocWithZone,
                        method_getTypeEncoding(alloc));
    DebugLog(@"hooked video output allocation");
}

@interface SimDeckCameraDevice : AVCaptureDevice
@end

@interface SimDeckCameraDiscoverySession : AVCaptureDeviceDiscoverySession
+ (instancetype)sharedSession;
@end

@interface SimDeckCameraFrameRateRange : AVFrameRateRange
+ (instancetype)sharedRange;
@end

@implementation SimDeckCameraFrameRateRange

+ (instancetype)sharedRange {
    static SimDeckCameraFrameRateRange *range;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        range = NSAllocateObject(self, 0, nil);
    });
    return range;
}

- (Float64)minFrameRate { return 1.0; }
- (Float64)maxFrameRate { return 60.0; }
- (CMTime)minFrameDuration { return CMTimeMake(1, 60); }
- (CMTime)maxFrameDuration { return CMTimeMake(1, 1); }

@end

@interface SimDeckCameraFormat : AVCaptureDeviceFormat
+ (instancetype)sharedFormat;
@end

@implementation SimDeckCameraFormat

+ (instancetype)sharedFormat {
    static SimDeckCameraFormat *format;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        format = NSAllocateObject(self, 0, nil);
    });
    return format;
}

- (AVMediaType)mediaType { return AVMediaTypeVideo; }

- (CMFormatDescriptionRef)formatDescription {
    DebugLog(@"providing SimDeck format description");
    static CMVideoFormatDescriptionRef description;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int32_t width = gHeader && gHeader->width > 0 ? (int32_t)gHeader->width : 1920;
        int32_t height = gHeader && gHeader->height > 0 ? (int32_t)gHeader->height : 1080;
        CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       width,
                                       height,
                                       NULL,
                                       &description);
    });
    return description;
}

- (NSArray<AVFrameRateRange *> *)videoSupportedFrameRateRanges {
    return @[ [SimDeckCameraFrameRateRange sharedRange] ];
}

- (CGFloat)videoMaxZoomFactor { return 1.0; }
- (BOOL)isVideoBinned { return NO; }
- (NSArray<NSValue *> *)supportedMaxPhotoDimensions { return @[]; }

@end

@implementation SimDeckCameraDevice

+ (instancetype)sharedDevice {
    static SimDeckCameraDevice *device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        device = NSAllocateObject(self, 0, nil);
    });
    return device;
}

- (NSString *)localizedName { return @"SimDeck Camera"; }
- (NSString *)uniqueID { return @"dev.nativescript.simdeck.camera"; }
- (NSString *)modelID { return @"SimDeck Camera"; }
- (NSString *)manufacturer { return @"SimDeck"; }
- (AVCaptureDevicePosition)position { return AVCaptureDevicePositionFront; }
- (BOOL)hasMediaType:(AVMediaType)mediaType { return IsVideoMediaType(mediaType); }
- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (NSArray<AVCaptureDeviceFormat *> *)formats { return @[ [SimDeckCameraFormat sharedFormat] ]; }
- (AVCaptureDeviceFormat *)activeFormat { return [SimDeckCameraFormat sharedFormat]; }
- (void)setActiveFormat:(AVCaptureDeviceFormat *)format { (void)format; }
- (CMTime)activeVideoMinFrameDuration { return CMTimeMake(1, 30); }
- (void)setActiveVideoMinFrameDuration:(CMTime)duration { (void)duration; }
- (CMTime)activeVideoMaxFrameDuration { return CMTimeMake(1, 30); }
- (void)setActiveVideoMaxFrameDuration:(CMTime)duration { (void)duration; }
- (BOOL)lockForConfiguration:(NSError **)outError {
    if (outError) *outError = nil;
    return YES;
}
- (void)unlockForConfiguration {}
- (CGFloat)videoZoomFactor { return 1.0; }
- (void)setVideoZoomFactor:(CGFloat)factor { (void)factor; }
- (BOOL)isWhiteBalanceModeSupported:(AVCaptureWhiteBalanceMode)mode { (void)mode; return NO; }
- (BOOL)hasTorch { return NO; }
- (AVCaptureTorchMode)torchMode { return AVCaptureTorchModeOff; }
- (BOOL)portraitEffectActive { return NO; }
- (NSInteger)minimumFocusDistance { return -1; }

@end

@implementation SimDeckCameraDiscoverySession

+ (instancetype)sharedSession {
    static SimDeckCameraDiscoverySession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        session = NSAllocateObject(self, 0, nil);
    });
    return session;
}

- (NSArray<AVCaptureDevice *> *)devices {
    return @[ (AVCaptureDevice *)[SimDeckCameraDevice sharedDevice] ];
}

@end

@interface SimDeckCameraInput : AVCaptureDeviceInput
@end

@implementation SimDeckCameraInput

- (AVCaptureDevice *)device {
    return (AVCaptureDevice *)[SimDeckCameraDevice sharedDevice];
}

@end

@interface SimDeckCameraConnection : AVCaptureConnection
+ (instancetype)connectionForOutput:(AVCaptureOutput *)output;
@end

@implementation SimDeckCameraConnection {
    __unsafe_unretained AVCaptureOutput *_output;
    AVCaptureVideoOrientation _orientation;
    BOOL _automaticallyAdjustsVideoMirroring;
    BOOL _videoMirrored;
    BOOL _enabled;
}

+ (instancetype)allocWithZone:(NSZone *)zone {
    (void)zone;
    return class_createInstance(self, 0);
}

+ (instancetype)connectionForOutput:(AVCaptureOutput *)output {
    SimDeckCameraConnection *connection = [self alloc];
    connection->_output = output;
    connection->_orientation = IsBrowserCameraProcess()
        ? AVCaptureVideoOrientationPortraitUpsideDown
        : AVCaptureVideoOrientationPortrait;
    connection->_automaticallyAdjustsVideoMirroring = YES;
    connection->_videoMirrored = YES;
    connection->_enabled = YES;
    return [connection autorelease];
}

- (AVCaptureOutput *)output { return _output; }
- (NSArray<AVCaptureInputPort *> *)inputPorts { return @[]; }
- (NSArray<AVCaptureAudioChannel *> *)audioChannels { return @[]; }
- (AVMediaType)mediaType { return AVMediaTypeVideo; }
- (AVCaptureDevice *)sourceDevice { return (AVCaptureDevice *)[SimDeckCameraDevice sharedDevice]; }
- (AVCaptureDeviceType)sourceDeviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (AVCaptureDevicePosition)sourceDevicePosition { return AVCaptureDevicePositionFront; }
- (BOOL)isActive { return YES; }
- (BOOL)isEnabled { return _enabled; }
- (void)setEnabled:(BOOL)enabled { _enabled = enabled; }
- (BOOL)isVideoOrientationSupported { return YES; }
- (AVCaptureVideoOrientation)videoOrientation { return _orientation; }
- (void)setVideoOrientation:(AVCaptureVideoOrientation)orientation { _orientation = orientation; }
- (BOOL)isVideoMirroringSupported { return YES; }
- (BOOL)isVideoMirrored {
    if (_automaticallyAdjustsVideoMirroring && gHeader) {
        return SimDeckCameraLoadMirrorMode(gHeader) == SIMDECK_CAMERA_MIRROR_ON;
    }
    return _videoMirrored;
}
- (void)setVideoMirrored:(BOOL)mirrored {
    _videoMirrored = mirrored;
    _automaticallyAdjustsVideoMirroring = NO;
}
- (BOOL)automaticallyAdjustsVideoMirroring { return _automaticallyAdjustsVideoMirroring; }
- (void)setAutomaticallyAdjustsVideoMirroring:(BOOL)automaticallyAdjustsVideoMirroring {
    _automaticallyAdjustsVideoMirroring = automaticallyAdjustsVideoMirroring;
}

@end

static AVCaptureConnection *CameraConnectionForOutput(AVCaptureOutput *output) {
    if (!output) return nil;
    AVCaptureConnection *connection = objc_getAssociatedObject(output, &kOutputConnectionKey);
    if (!connection) {
        connection = [SimDeckCameraConnection connectionForOutput:output];
        objc_setAssociatedObject(output,
                                 &kOutputConnectionKey,
                                 connection,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return connection;
}

@interface SimDeckCameraVideoDataOutput : AVCaptureVideoDataOutput
@end

@implementation SimDeckCameraVideoDataOutput

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
- (instancetype)init {
    struct objc_super superInfo = { self, NSObject.class };
    return ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superInfo, @selector(init));
}
#pragma clang diagnostic pop

- (void)setVideoSettings:(NSDictionary *)videoSettings {
    objc_setAssociatedObject(self, &kOutputVideoSettingsKey, videoSettings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSDictionary *)videoSettings {
    return objc_getAssociatedObject(self, &kOutputVideoSettingsKey);
}

- (void)setAlwaysDiscardsLateVideoFrames:(BOOL)alwaysDiscardsLateVideoFrames {
    objc_setAssociatedObject(self, &kOutputDiscardsLateFramesKey, @(alwaysDiscardsLateVideoFrames), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)alwaysDiscardsLateVideoFrames {
    NSNumber *value = objc_getAssociatedObject(self, &kOutputDiscardsLateFramesKey);
    return value ? value.boolValue : YES;
}

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    DebugLog(@"fake video output delegate set");
    SimDeckSetSampleBufferDelegate(self, _cmd, delegate, sampleBufferCallbackQueue);
}

- (AVCaptureConnection *)connectionWithMediaType:(AVMediaType)mediaType {
    return IsVideoMediaType(mediaType) ? CameraConnectionForOutput(self) : nil;
}

- (NSArray<AVCaptureConnection *> *)connections {
    AVCaptureConnection *connection = CameraConnectionForOutput(self);
    return connection ? @[ connection ] : @[];
}

@end

@interface SimDeckCameraPhoto : AVCapturePhoto
@property (nonatomic, strong) NSData *jpegData;
@end

@implementation SimDeckCameraPhoto

- (NSData *)fileDataRepresentation {
    return self.jpegData;
}

@end

@implementation AVCaptureDevice (SimDeckCamera)

+ (void)sd_setUserPreferredCamera:(AVCaptureDevice *)camera {
    if (IsBrowserCameraProcess() && BrowserCameraDeviceAvailable()) return;
    [self sd_setUserPreferredCamera:camera];
}

+ (void)sd_setSystemPreferredCamera:(AVCaptureDevice *)camera {
    if (IsBrowserCameraProcess() && BrowserCameraDeviceAvailable()) return;
    [self sd_setSystemPreferredCamera:camera];
}

+ (AVCaptureDevice *)sd_deviceWithUniqueID:(NSString *)uniqueID {
    if (IsBrowserCameraProcess() && BrowserCameraDeviceAvailable()) {
        DebugLog(@"resolving browser device %@ to SimDeck Camera", uniqueID);
        return (AVCaptureDevice *)[SimDeckCameraDevice sharedDevice];
    }
    AVCaptureDevice *device = [self sd_deviceWithUniqueID:uniqueID];
    if (device || !IsBrowserCameraProcess() || !OpenSharedCamera()) return device;

    for (AVCaptureDevice *candidate in [self sd_devicesWithMediaType:AVMediaTypeVideo]) {
        if ([candidate.uniqueID isEqualToString:uniqueID]) return candidate;
    }
    return nil;
}

- (NSString *)sd_browserLocalizedName {
    NSString *value = [self sd_browserLocalizedName];
    return value.length > 0 ? value : @"SimDeck Camera";
}

- (NSString *)sd_browserUniqueID {
    NSString *value = [self sd_browserUniqueID];
    return value.length > 0 ? value : @"dev.nativescript.simdeck.camera";
}

- (NSString *)sd_browserModelID {
    NSString *value = [self sd_browserModelID];
    return value.length > 0 ? value : @"SimDeck Camera";
}

- (NSString *)sd_browserManufacturer {
    NSString *value = [self sd_browserManufacturer];
    return value.length > 0 ? value : @"SimDeck";
}

- (AVCaptureDevicePosition)sd_browserPosition {
    AVCaptureDevicePosition value = [self sd_browserPosition];
    return value == AVCaptureDevicePositionUnspecified ? AVCaptureDevicePositionFront : value;
}

- (AVCaptureDeviceType)sd_browserDeviceType {
    AVCaptureDeviceType value = [self sd_browserDeviceType];
    return value.length > 0 ? value : AVCaptureDeviceTypeBuiltInWideAngleCamera;
}

- (BOOL)sd_browserIsConnected {
    return OpenSharedCamera() || [self sd_browserIsConnected];
}

- (BOOL)sd_browserIsSuspended {
    return OpenSharedCamera() ? NO : [self sd_browserIsSuspended];
}

- (NSArray<AVCaptureDeviceFormat *> *)sd_browserFormats {
    if (OpenSharedCamera()) {
        DebugLog(@"using SimDeck format for %@", NSStringFromClass(self.class));
        return @[ [SimDeckCameraFormat sharedFormat] ];
    }
    return [self sd_browserFormats];
}

- (AVCaptureDeviceFormat *)sd_browserActiveFormat {
    if (!OpenSharedCamera()) return [self sd_browserActiveFormat];
    AVCaptureDeviceFormat *format = objc_getAssociatedObject(self, &kBrowserActiveFormatKey);
    return format ?: [SimDeckCameraFormat sharedFormat];
}

- (void)sd_browserSetActiveFormat:(AVCaptureDeviceFormat *)format {
    if (!OpenSharedCamera()) {
        [self sd_browserSetActiveFormat:format];
        return;
    }
    objc_setAssociatedObject(self, &kBrowserActiveFormatKey, format, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CMTime)sd_browserActiveVideoMinFrameDuration {
    return OpenSharedCamera() ? CMTimeMake(1, 30) : [self sd_browserActiveVideoMinFrameDuration];
}

- (void)sd_browserSetActiveVideoMinFrameDuration:(CMTime)duration {
    if (!OpenSharedCamera()) [self sd_browserSetActiveVideoMinFrameDuration:duration];
}

- (CMTime)sd_browserActiveVideoMaxFrameDuration {
    return OpenSharedCamera() ? CMTimeMake(1, 30) : [self sd_browserActiveVideoMaxFrameDuration];
}

- (void)sd_browserSetActiveVideoMaxFrameDuration:(CMTime)duration {
    if (!OpenSharedCamera()) [self sd_browserSetActiveVideoMaxFrameDuration:duration];
}

- (BOOL)sd_browserLockForConfiguration:(NSError **)outError {
    if (!OpenSharedCamera()) return [self sd_browserLockForConfiguration:outError];
    if (outError) *outError = nil;
    return YES;
}

- (void)sd_browserUnlockForConfiguration {
    if (!OpenSharedCamera()) [self sd_browserUnlockForConfiguration];
}

- (CGFloat)sd_browserVideoZoomFactor {
    return OpenSharedCamera() ? 1.0 : [self sd_browserVideoZoomFactor];
}

- (void)sd_browserSetVideoZoomFactor:(CGFloat)factor {
    if (!OpenSharedCamera()) [self sd_browserSetVideoZoomFactor:factor];
}

+ (AVCaptureDevice *)sd_defaultDeviceWithMediaType:(AVMediaType)mediaType {
    if (IsBrowserCameraProcess() && IsVideoMediaType(mediaType) && BrowserCameraDeviceAvailable()) {
        DebugLog(@"providing default SimDeck camera");
        return (AVCaptureDevice *)[SimDeckCameraDevice sharedDevice];
    }
    AVCaptureDevice *device = [self sd_defaultDeviceWithMediaType:mediaType];
    if (device || !IsVideoMediaType(mediaType) || !OpenSharedCamera()) return device;
    return (AVCaptureDevice *)[SimDeckCameraDevice sharedDevice];
}

+ (AVCaptureDevice *)sd_defaultDeviceWithDeviceType:(AVCaptureDeviceType)deviceType
                                          mediaType:(AVMediaType)mediaType
                                           position:(AVCaptureDevicePosition)position {
    if (IsBrowserCameraProcess() && IsVideoMediaType(mediaType) && BrowserCameraDeviceAvailable()) {
        DebugLog(@"providing typed default SimDeck camera");
        return (AVCaptureDevice *)[SimDeckCameraDevice sharedDevice];
    }
    AVCaptureDevice *device = [self sd_defaultDeviceWithDeviceType:deviceType mediaType:mediaType position:position];
    if (device || !IsVideoMediaType(mediaType) || !OpenSharedCamera()) return device;
    return (AVCaptureDevice *)[SimDeckCameraDevice sharedDevice];
}

+ (NSArray<AVCaptureDevice *> *)sd_devicesWithMediaType:(AVMediaType)mediaType {
    if (IsBrowserCameraProcess() && IsVideoMediaType(mediaType) && BrowserCameraDeviceAvailable()) {
        DebugLog(@"providing SimDeck camera device list");
        return @[ (AVCaptureDevice *)[SimDeckCameraDevice sharedDevice] ];
    }
    NSArray *devices = [self sd_devicesWithMediaType:mediaType];
    if (devices.count > 0 || !IsVideoMediaType(mediaType)) return devices;
    return OpenSharedCamera() ? @[ (AVCaptureDevice *)[SimDeckCameraDevice sharedDevice] ] : @[];
}

+ (AVAuthorizationStatus)sd_authorizationStatusForMediaType:(AVMediaType)mediaType {
    if (IsBrowserCameraProcess()) return [self sd_authorizationStatusForMediaType:mediaType];
    if (IsVideoMediaType(mediaType)) return AVAuthorizationStatusAuthorized;
    return [self sd_authorizationStatusForMediaType:mediaType];
}

+ (void)sd_requestAccessForMediaType:(AVMediaType)mediaType completionHandler:(void (^)(BOOL granted))handler {
    if (IsBrowserCameraProcess()) {
        [self sd_requestAccessForMediaType:mediaType completionHandler:handler];
        return;
    }
    if (IsVideoMediaType(mediaType)) {
        if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(YES); });
        return;
    }
    [self sd_requestAccessForMediaType:mediaType completionHandler:handler];
}

@end

@implementation AVCaptureDeviceDiscoverySession (SimDeckCamera)

+ (instancetype)sd_discoverySessionWithDeviceTypes:(NSArray<AVCaptureDeviceType> *)deviceTypes
                                           mediaType:(AVMediaType)mediaType
                                            position:(AVCaptureDevicePosition)position {
    if (IsBrowserCameraProcess() && IsVideoMediaType(mediaType) && BrowserCameraDeviceAvailable()) {
        DebugLog(@"providing SimDeck camera discovery session");
        return (id)[SimDeckCameraDiscoverySession sharedSession];
    }
    return [self sd_discoverySessionWithDeviceTypes:deviceTypes mediaType:mediaType position:position];
}

- (NSArray<AVCaptureDevice *> *)sd_devices {
    NSArray *devices = [self sd_devices];
    if (devices.count > 0) {
        for (AVCaptureDevice *device in devices) {
            DebugLog(@"discovered %@ id=%@ name=%@ position=%ld connected=%d formats=%lu",
                     NSStringFromClass(device.class),
                     device.uniqueID,
                     device.localizedName,
                     (long)device.position,
                     device.isConnected,
                     (unsigned long)device.formats.count);
        }
        return devices;
    }
    return BrowserCameraDeviceAvailable() ? @[ (AVCaptureDevice *)[SimDeckCameraDevice sharedDevice] ] : @[];
}

@end

@implementation AVCaptureDeviceInput (SimDeckCamera)

+ (instancetype)sd_deviceInputWithDevice:(AVCaptureDevice *)device error:(NSError **)outError {
    if (ShouldUseSimDeckInput(device)) {
        if (outError) *outError = nil;
        return (id)SimDeckFakeInput();
    }
    id input = [self sd_deviceInputWithDevice:device error:outError];
    if (!input && OpenSharedCamera() && [device hasMediaType:AVMediaTypeVideo]) {
        if (outError) *outError = nil;
        return (id)SimDeckFakeInput();
    }
    return input;
}

- (instancetype)sd_initWithDevice:(AVCaptureDevice *)device error:(NSError **)outError {
    if (ShouldUseSimDeckInput(device)) {
        if (outError) *outError = nil;
        return (id)SimDeckFakeInput();
    }
    return [self sd_initWithDevice:device error:outError];
}

- (AVCaptureDevice *)sd_device {
    AVCaptureDevice *device = objc_getAssociatedObject(self, &kInputDeviceKey);
    return device ?: [self sd_device];
}

- (NSArray *)sd_ports {
    if (SimDeckIsFakeInput(self)) return @[];
    return [self sd_ports];
}

@end

@implementation AVCaptureVideoDataOutput (SimDeckCamera)

+ (id)sd_allocWithZone:(struct _NSZone *)zone {
    if (self == AVCaptureVideoDataOutput.class && OpenSharedCamera()) {
        return NSAllocateObject(SimDeckCameraVideoDataOutput.class, 0, nil);
    }
    return [self sd_allocWithZone:zone];
}

- (instancetype)sd_init {
    id output = [self sd_init];
    InstallVideoOutputDelegateHook(object_getClass(output));
    return output;
}

- (void)sd_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    SimDeckSetSampleBufferDelegate(self, _cmd, delegate, sampleBufferCallbackQueue);
}

@end

@implementation AVCapturePhotoOutput (SimDeckCamera)

- (void)sd_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    (void)settings;
    UIImage *image = delegate ? CurrentFrameImage() : nil;
    if (!image) {
        [self sd_capturePhotoWithSettings:settings delegate:delegate];
        return;
    }
    NSData *jpeg = UIImageJPEGRepresentation(image, 0.92);
    SimDeckCameraPhoto *photo = NSAllocateObject(SimDeckCameraPhoto.class, 0, nil);
    photo.jpegData = jpeg ?: [NSData data];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
            [delegate captureOutput:self didFinishProcessingPhoto:photo error:nil];
        }
    });
}

@end

@implementation AVCaptureSession (SimDeckCamera)

- (BOOL)sd_canAddInput:(AVCaptureInput *)input {
    if (SimDeckIsFakeInput(input)) return YES;
    return [self sd_canAddInput:input];
}

- (void)sd_addInput:(AVCaptureInput *)input {
    if (SimDeckIsFakeInput(input)) {
        NSMutableArray *inputs = objc_getAssociatedObject(self, &kSessionInputsKey);
        if (!inputs) {
            inputs = [NSMutableArray array];
            objc_setAssociatedObject(self, &kSessionInputsKey, inputs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (![inputs containsObject:input]) [inputs addObject:input];
        return;
    }
    [self sd_addInput:input];
}

- (BOOL)sd_canAddOutput:(AVCaptureOutput *)output {
    if ([output isKindOfClass:AVCaptureVideoDataOutput.class] || [output isKindOfClass:AVCapturePhotoOutput.class]) return YES;
    return [self sd_canAddOutput:output];
}

- (void)sd_addOutput:(AVCaptureOutput *)output {
    if ([output isKindOfClass:AVCaptureVideoDataOutput.class] || [output isKindOfClass:AVCapturePhotoOutput.class]) {
        AddSessionOutput(self, output);
        return;
    }
    [self sd_addOutput:output];
}

- (NSArray<AVCaptureInput *> *)sd_inputs {
    NSArray *original = [self sd_inputs];
    NSMutableArray *inputs = objc_getAssociatedObject(self, &kSessionInputsKey);
    if (inputs.count == 0) return original;
    return [original arrayByAddingObjectsFromArray:inputs];
}

- (NSArray<AVCaptureOutput *> *)sd_outputs {
    NSArray *original = [self sd_outputs];
    NSMutableArray *outputs = objc_getAssociatedObject(self, &kSessionOutputsKey);
    if (outputs.count == 0) return original;
    return [original arrayByAddingObjectsFromArray:outputs];
}

- (void)sd_startRunning {
    if (!OpenSharedCamera()) {
        [self sd_startRunning];
        return;
    }
    @synchronized(gSessions) {
        NSNumber *running = objc_getAssociatedObject(self, &kSessionRunningKey);
        if (running.boolValue) return;
        objc_setAssociatedObject(self, &kSessionRunningKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TrackPointer(gSessions, self);
        RegisterCameraConsumer();
    }
    StartFrameTimer();
}

- (void)sd_stopRunning {
    @synchronized(gSessions) {
        NSNumber *running = objc_getAssociatedObject(self, &kSessionRunningKey);
        if (!running) {
            [self sd_stopRunning];
            return;
        }
        if (!running.boolValue) return;
        objc_setAssociatedObject(self, &kSessionRunningKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UnregisterCameraConsumer();
    }
}

- (BOOL)sd_isRunning {
    NSNumber *running = objc_getAssociatedObject(self, &kSessionRunningKey);
    if (running) return running.boolValue;
    return [self sd_isRunning];
}

@end

@interface SimDeckPickerOverlayView : UIView
@end

@implementation SimDeckPickerOverlayView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}

@end

@interface SimDeckPickerOverlayWindow : UIWindow
@end

@implementation SimDeckPickerOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self || hit == self.rootViewController.view ? nil : hit;
}

@end

@interface SimDeckPickerCaptureControl : UIControl
@property (nonatomic, assign) UIImagePickerController *picker;
- (instancetype)initWithPicker:(UIImagePickerController *)picker;
- (void)capture;
@end

@implementation SimDeckPickerCaptureControl

- (instancetype)initWithPicker:(UIImagePickerController *)picker {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.picker = picker;
        self.backgroundColor = UIColor.clearColor;
        self.accessibilityLabel = @"SimDeck Capture";
        [self addTarget:self action:@selector(capture) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)capture {
    UIImagePickerController *picker = [self.picker retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        SendPickerCapture(picker);
        [picker release];
    });
}

@end

static CGRect PickerCaptureFrame(UIView *view) {
    CGRect bounds = view.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat size = MAX((CGFloat)104.0, MIN(width, height) * (CGFloat)0.26);
    if (width > height) {
        CGFloat centerX = width - MAX((CGFloat)120.0, height * (CGFloat)0.24);
        CGFloat centerY = height * (CGFloat)0.5;
        return CGRectMake(centerX - size * (CGFloat)0.5, centerY - size * (CGFloat)0.5, size, size);
    }
    CGFloat centerX = width * (CGFloat)0.5;
    CGFloat centerY = height - MAX((CGFloat)140.0, width * (CGFloat)0.35);
    return CGRectMake(centerX - size * (CGFloat)0.5, centerY - size * (CGFloat)0.5, size, size);
}

static void SendPickerCapture(UIImagePickerController *picker) {
    if (!picker) return;
    UIImage *image = CurrentFrameImage();
    if (!image) return;
    DebugLog(@"sending UIImagePicker simulated capture");
    NSDictionary *info = @{
        UIImagePickerControllerMediaType: @"public.image",
        UIImagePickerControllerOriginalImage: image,
        UIImagePickerControllerMediaMetadata: @{},
    };
    id<UIImagePickerControllerDelegate, UINavigationControllerDelegate> delegate = picker.delegate;
    if ([delegate respondsToSelector:@selector(imagePickerController:didFinishPickingMediaWithInfo:)]) {
        [delegate imagePickerController:picker didFinishPickingMediaWithInfo:info];
    } else {
        [picker dismissViewControllerAnimated:YES completion:nil];
    }
}

static CGRect PickerPreviewFrame(UIView *view) {
    CGRect bounds = view.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width <= 0 || height <= 0) return bounds;
    if (width > height) {
        CGFloat previewWidth = MIN(width, height * 4.0 / 3.0);
        CGFloat x = (width - previewWidth) * 0.5;
        return CGRectMake(x, 0, previewWidth, height);
    }
    CGFloat previewHeight = MIN(height, width * 4.0 / 3.0);
    CGFloat bottomControls = MAX((CGFloat)150.0, width * (CGFloat)0.48);
    CGFloat y = height - previewHeight - bottomControls;
    if (y < 0) {
        y = (height - previewHeight) * 0.5;
    }
    y = MAX((CGFloat)0.0, MIN(y, height - previewHeight));
    return CGRectMake(0, y, width, previewHeight);
}

static void InstallPickerOverlay(UIImagePickerController *picker) {
    if (!picker || !OpenSharedCamera()) return;
    if (picker.sourceType != UIImagePickerControllerSourceTypeCamera) return;
    UIView *root = picker.view;
    if (!root) return;

    UIView *overlay = objc_getAssociatedObject(picker, &kPickerOverlayViewKey);
    if (!overlay) {
        overlay = [[[UIView alloc] initWithFrame:PickerPreviewFrame(root)] autorelease];
        overlay.userInteractionEnabled = NO;
        overlay.clipsToBounds = YES;
        overlay.backgroundColor = UIColor.clearColor;
        overlay.layer.contentsGravity = kCAGravityResizeAspectFill;
        overlay.layer.masksToBounds = YES;
        objc_setAssociatedObject(picker, &kPickerOverlayViewKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [root addSubview:overlay];
        DebugLog(@"installed UIImagePicker camera preview overlay");
    }
    overlay.frame = PickerPreviewFrame(root);
    RegisterOutputLayer(overlay.layer);

    SimDeckPickerOverlayView *cameraOverlay = objc_getAssociatedObject(picker, &kPickerCameraOverlayKey);
    if (!cameraOverlay) {
        cameraOverlay = [[[SimDeckPickerOverlayView alloc] initWithFrame:root.bounds] autorelease];
        cameraOverlay.backgroundColor = UIColor.clearColor;
        cameraOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(picker, &kPickerCameraOverlayKey, cameraOverlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        picker.cameraOverlayView = cameraOverlay;
    }
    cameraOverlay.frame = root.bounds;

    UIWindow *hostWindow = root.window;
    if (!hostWindow) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    hostWindow = window;
                    break;
                }
            }
            if (hostWindow) break;
        }
    }
    CGRect captureFrame = PickerCaptureFrame(root);
    SimDeckPickerOverlayWindow *captureWindow = objc_getAssociatedObject(picker, &kPickerCaptureWindowKey);
    if (!captureWindow) {
        captureWindow = [[[SimDeckPickerOverlayWindow alloc] initWithFrame:captureFrame] autorelease];
        captureWindow.windowLevel = UIWindowLevelAlert + 10.0;
        captureWindow.backgroundColor = UIColor.clearColor;
        UIViewController *rootController = [[[UIViewController alloc] init] autorelease];
        rootController.view = [[[SimDeckPickerOverlayView alloc] initWithFrame:captureWindow.bounds] autorelease];
        rootController.view.backgroundColor = UIColor.clearColor;
        rootController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        captureWindow.rootViewController = rootController;
        captureWindow.hidden = NO;
        objc_setAssociatedObject(picker, &kPickerCaptureWindowKey, captureWindow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (@available(iOS 13.0, *)) {
        if (hostWindow.windowScene && captureWindow.windowScene != hostWindow.windowScene) {
            captureWindow.windowScene = hostWindow.windowScene;
        }
    }
    captureWindow.frame = captureFrame;
    captureWindow.hidden = NO;
    UIView *captureRoot = captureWindow.rootViewController.view ?: cameraOverlay;
    captureRoot.frame = captureWindow.bounds;

    SimDeckPickerCaptureControl *capture = objc_getAssociatedObject(picker, &kPickerCaptureControlKey);
    if (!capture) {
        capture = [[[SimDeckPickerCaptureControl alloc] initWithPicker:picker] autorelease];
        objc_setAssociatedObject(picker, &kPickerCaptureControlKey, capture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [captureRoot addSubview:capture];
        DebugLog(@"installed UIImagePicker capture control");
    } else if (capture.superview != captureRoot) {
        [capture removeFromSuperview];
        [captureRoot addSubview:capture];
    }
    capture.frame = captureRoot.bounds;
    [captureRoot bringSubviewToFront:capture];
}

static void HidePickerOverlayWindow(UIImagePickerController *picker) {
    UIWindow *captureWindow = objc_getAssociatedObject(picker, &kPickerCaptureWindowKey);
    captureWindow.hidden = YES;
}

@implementation UIViewController (SimDeckCameraPicker)

- (void)sd_viewDidAppear:(BOOL)animated {
    [self sd_viewDidAppear:animated];
    if ([self isKindOfClass:UIImagePickerController.class]) {
        InstallPickerOverlay((UIImagePickerController *)self);
    }
}

- (void)sd_viewDidLayoutSubviews {
    [self sd_viewDidLayoutSubviews];
    if ([self isKindOfClass:UIImagePickerController.class]) {
        InstallPickerOverlay((UIImagePickerController *)self);
    }
}

- (void)sd_viewDidDisappear:(BOOL)animated {
    [self sd_viewDidDisappear:animated];
    if ([self isKindOfClass:UIImagePickerController.class]) {
        HidePickerOverlayWindow((UIImagePickerController *)self);
    }
}

@end

@implementation AVCaptureVideoPreviewLayer (SimDeckCamera)

+ (instancetype)sd_layerWithSession:(AVCaptureSession *)session {
    if (OpenSharedCamera()) {
        AVCaptureVideoPreviewLayer *layer = [self sd_layerWithSession:nil];
        objc_setAssociatedObject(layer, &kPreviewSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RegisterPreviewLayer(layer);
        return layer;
    }
    AVCaptureVideoPreviewLayer *layer = [self sd_layerWithSession:session];
    return layer;
}

- (instancetype)sd_initWithSession:(AVCaptureSession *)session {
    if (OpenSharedCamera()) {
        id layer = [self sd_initWithSession:nil];
        if (layer) {
            objc_setAssociatedObject(layer, &kPreviewSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            RegisterPreviewLayer(layer);
        }
        return layer;
    }
    id layer = [self sd_initWithSession:session];
    return layer;
}

- (void)sd_setSession:(AVCaptureSession *)session {
    if (OpenSharedCamera() && session) {
        objc_setAssociatedObject(self, &kPreviewSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RegisterPreviewLayer(self);
        return;
    }
    [self sd_setSession:session];
}

- (AVCaptureSession *)sd_session {
    AVCaptureSession *session = objc_getAssociatedObject(self, &kPreviewSessionKey);
    return session ?: [self sd_session];
}

@end

static void ExchangeInstance(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (!a || !b) {
        Log(@"missing instance method %@ on %@", NSStringFromSelector(original), NSStringFromClass(cls));
        return;
    }
    method_exchangeImplementations(a, b);
}

static void ExchangeClass(Class cls, SEL original, SEL replacement) {
    Method a = class_getClassMethod(cls, original);
    Method b = class_getClassMethod(cls, replacement);
    if (!a || !b) {
        Log(@"missing class method %@ on %@", NSStringFromSelector(original), NSStringFromClass(cls));
        return;
    }
    method_exchangeImplementations(a, b);
}

static void InstallSubclassFallback(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(AVCaptureDevice.class, replacement);
    if (!originalMethod || !replacementMethod) {
        Log(@"missing browser camera method %@ on %@", NSStringFromSelector(original), NSStringFromClass(cls));
        return;
    }
    class_addMethod(cls,
                    replacement,
                    method_getImplementation(originalMethod),
                    method_getTypeEncoding(originalMethod));
    class_replaceMethod(cls,
                        original,
                        method_getImplementation(replacementMethod),
                        method_getTypeEncoding(replacementMethod));
}

static void InstallBrowserCameraDeviceMetadataHooks(void) {
    Class cls = NSClassFromString(@"AVCaptureFigVideoDevice");
    if (!cls) {
        Log(@"missing AVCaptureFigVideoDevice");
        return;
    }
    InstallSubclassFallback(cls, @selector(localizedName), @selector(sd_browserLocalizedName));
    InstallSubclassFallback(cls, @selector(uniqueID), @selector(sd_browserUniqueID));
    InstallSubclassFallback(cls, @selector(modelID), @selector(sd_browserModelID));
    InstallSubclassFallback(cls, @selector(manufacturer), @selector(sd_browserManufacturer));
    InstallSubclassFallback(cls, @selector(position), @selector(sd_browserPosition));
    InstallSubclassFallback(cls, @selector(deviceType), @selector(sd_browserDeviceType));
    InstallSubclassFallback(cls, @selector(isConnected), @selector(sd_browserIsConnected));
    InstallSubclassFallback(cls, @selector(isSuspended), @selector(sd_browserIsSuspended));
    InstallSubclassFallback(cls, @selector(formats), @selector(sd_browserFormats));
    InstallSubclassFallback(cls, @selector(activeFormat), @selector(sd_browserActiveFormat));
    InstallSubclassFallback(cls, @selector(setActiveFormat:), @selector(sd_browserSetActiveFormat:));
    InstallSubclassFallback(cls, @selector(activeVideoMinFrameDuration), @selector(sd_browserActiveVideoMinFrameDuration));
    InstallSubclassFallback(cls, @selector(setActiveVideoMinFrameDuration:), @selector(sd_browserSetActiveVideoMinFrameDuration:));
    InstallSubclassFallback(cls, @selector(activeVideoMaxFrameDuration), @selector(sd_browserActiveVideoMaxFrameDuration));
    InstallSubclassFallback(cls, @selector(setActiveVideoMaxFrameDuration:), @selector(sd_browserSetActiveVideoMaxFrameDuration:));
    InstallSubclassFallback(cls, @selector(lockForConfiguration:), @selector(sd_browserLockForConfiguration:));
    InstallSubclassFallback(cls, @selector(unlockForConfiguration), @selector(sd_browserUnlockForConfiguration));
    InstallSubclassFallback(cls, @selector(videoZoomFactor), @selector(sd_browserVideoZoomFactor));
    InstallSubclassFallback(cls, @selector(setVideoZoomFactor:), @selector(sd_browserSetVideoZoomFactor:));
}

__attribute__((constructor))
static void SimDeckCameraInstall(void) {
    @autoreleasepool {
        if (!ShouldInstallForCurrentProcess()) return;
        if (IsBrowserUIProcess()) {
            ExchangeClass(AVCaptureDevice.class, @selector(defaultDeviceWithMediaType:), @selector(sd_defaultDeviceWithMediaType:));
            ExchangeClass(AVCaptureDevice.class, @selector(defaultDeviceWithDeviceType:mediaType:position:), @selector(sd_defaultDeviceWithDeviceType:mediaType:position:));
            ExchangeClass(AVCaptureDevice.class, @selector(deviceWithUniqueID:), @selector(sd_deviceWithUniqueID:));
            ExchangeClass(AVCaptureDevice.class, @selector(devicesWithMediaType:), @selector(sd_devicesWithMediaType:));
            ExchangeClass(AVCaptureDevice.class, @selector(setUserPreferredCamera:), @selector(sd_setUserPreferredCamera:));
            ExchangeClass(AVCaptureDevice.class, @selector(setSystemPreferredCamera:), @selector(sd_setSystemPreferredCamera:));
            ExchangeClass(AVCaptureDeviceDiscoverySession.class,
                          @selector(discoverySessionWithDeviceTypes:mediaType:position:),
                          @selector(sd_discoverySessionWithDeviceTypes:mediaType:position:));
            DebugLog(@"installed browser device enumeration hooks");
            return;
        }
        gSessions = [[NSMutableArray alloc] init];
        gVideoOutputs = [[NSMutableArray alloc] init];
        gPreviewLayers = [[NSHashTable weakObjectsHashTable] retain];
        gHookedVideoOutputClasses = [[NSMutableSet alloc] init];
        OpenSharedCamera();
        if (IsBrowserCameraProcess()) InstallBrowserCameraDeviceMetadataHooks();

        ExchangeClass(AVCaptureDevice.class, @selector(defaultDeviceWithMediaType:), @selector(sd_defaultDeviceWithMediaType:));
        ExchangeClass(AVCaptureDevice.class, @selector(defaultDeviceWithDeviceType:mediaType:position:), @selector(sd_defaultDeviceWithDeviceType:mediaType:position:));
        ExchangeClass(AVCaptureDevice.class, @selector(deviceWithUniqueID:), @selector(sd_deviceWithUniqueID:));
        ExchangeClass(AVCaptureDevice.class, @selector(devicesWithMediaType:), @selector(sd_devicesWithMediaType:));
        ExchangeClass(AVCaptureDevice.class, @selector(authorizationStatusForMediaType:), @selector(sd_authorizationStatusForMediaType:));
        ExchangeClass(AVCaptureDevice.class, @selector(requestAccessForMediaType:completionHandler:), @selector(sd_requestAccessForMediaType:completionHandler:));
        if (IsBrowserCameraProcess()) {
            ExchangeClass(AVCaptureDevice.class, @selector(setUserPreferredCamera:), @selector(sd_setUserPreferredCamera:));
            ExchangeClass(AVCaptureDevice.class, @selector(setSystemPreferredCamera:), @selector(sd_setSystemPreferredCamera:));
        }
        ExchangeClass(AVCaptureDeviceDiscoverySession.class,
                      @selector(discoverySessionWithDeviceTypes:mediaType:position:),
                      @selector(sd_discoverySessionWithDeviceTypes:mediaType:position:));
        ExchangeInstance(AVCaptureDeviceDiscoverySession.class, @selector(devices), @selector(sd_devices));

        ExchangeClass(AVCaptureDeviceInput.class, @selector(deviceInputWithDevice:error:), @selector(sd_deviceInputWithDevice:error:));
        ExchangeInstance(AVCaptureDeviceInput.class, @selector(initWithDevice:error:), @selector(sd_initWithDevice:error:));
        ExchangeInstance(AVCaptureDeviceInput.class, @selector(device), @selector(sd_device));
        ExchangeInstance(AVCaptureDeviceInput.class, @selector(ports), @selector(sd_ports));

        InstallVideoOutputAllocationHook();
        InstallExistingVideoOutputDelegateHooks();
        ExchangeInstance(AVCapturePhotoOutput.class, @selector(capturePhotoWithSettings:delegate:), @selector(sd_capturePhotoWithSettings:delegate:));

        ExchangeInstance(AVCaptureSession.class, @selector(canAddInput:), @selector(sd_canAddInput:));
        ExchangeInstance(AVCaptureSession.class, @selector(addInput:), @selector(sd_addInput:));
        ExchangeInstance(AVCaptureSession.class, @selector(canAddOutput:), @selector(sd_canAddOutput:));
        ExchangeInstance(AVCaptureSession.class, @selector(addOutput:), @selector(sd_addOutput:));
        ExchangeInstance(AVCaptureSession.class, @selector(inputs), @selector(sd_inputs));
        ExchangeInstance(AVCaptureSession.class, @selector(outputs), @selector(sd_outputs));
        ExchangeInstance(AVCaptureSession.class, @selector(startRunning), @selector(sd_startRunning));
        ExchangeInstance(AVCaptureSession.class, @selector(stopRunning), @selector(sd_stopRunning));
        ExchangeInstance(AVCaptureSession.class, @selector(isRunning), @selector(sd_isRunning));

        if (!IsBrowserCameraProcess()) {
            ExchangeInstance(UIViewController.class, @selector(viewDidAppear:), @selector(sd_viewDidAppear:));
            ExchangeInstance(UIViewController.class, @selector(viewDidLayoutSubviews), @selector(sd_viewDidLayoutSubviews));
            ExchangeInstance(UIViewController.class, @selector(viewDidDisappear:), @selector(sd_viewDidDisappear:));
            ExchangeClass(AVCaptureVideoPreviewLayer.class, @selector(layerWithSession:), @selector(sd_layerWithSession:));
            ExchangeInstance(AVCaptureVideoPreviewLayer.class, @selector(initWithSession:), @selector(sd_initWithSession:));
            ExchangeInstance(AVCaptureVideoPreviewLayer.class, @selector(setSession:), @selector(sd_setSession:));
            ExchangeInstance(AVCaptureVideoPreviewLayer.class, @selector(session), @selector(sd_session));
        }
        DebugLog(@"installed");
    }
}
