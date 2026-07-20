#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <VideoToolbox/VideoToolbox.h>

#import "SimDeckCameraShared.h"

#import <CoreVideo/CoreVideo.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <signal.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

#define SIMDECK_CAMERA_DEFAULT_WIDTH 1280u
#define SIMDECK_CAMERA_DEFAULT_HEIGHT 720u

typedef struct {
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef format;
} SimDeckBrowserH264Decoder;

@interface SimDeckCameraContext : NSObject {
@public
    NSString *udid;
    uint32_t width;
    uint32_t height;
    char *shmName;
    SimDeckCameraHeader *header;
    size_t mappedSize;
    dispatch_queue_t writeQueue;
    dispatch_source_t placeholderTimer;
    atomic_uint sourceGeneration;
    atomic_ullong publishedFrames;
    atomic_ullong droppedFrames;
    NSString *sourceName;
    NSString *sourceArgument;
    uint32_t sourceKind;
    OSType lastPixelFormat;
    BOOL serviceStarted;
    SimDeckBrowserH264Decoder browserDecoder;
    pthread_mutex_t browserFrameLock;
    dispatch_queue_t browserPublishQueue;
    CVPixelBufferRef latestBrowserPixelBuffer;
    BOOL browserPublishScheduled;
    atomic_ullong browserDecodeErrors;
    atomic_ullong browserDecodedFrames;
    atomic_ullong browserPublishedFrames;
    atomic_ullong browserDecoderLatencyTotalNs;
    atomic_ullong browserDecoderLatencyMaxNs;
    atomic_ullong browserSurfaceLatencyTotalNs;
    atomic_ullong browserSurfaceLatencyMaxNs;
    atomic_ullong browserPipelineLatencyTotalNs;
    atomic_ullong browserPipelineLatencyMaxNs;
    atomic_uint lastCameraSequence;
    uint64_t latestBrowserAssembledNs;
    uint64_t latestBrowserDecodedNs;
    CVPixelBufferRef surfaceRing[SIMDECK_CAMERA_SURFACE_RING_SIZE];
    uint32_t nextSurfaceSlot;
    uint64_t surfaceGeneration;
    atomic_ullong surfacePublicationFailures;
}
@end

@implementation SimDeckCameraContext

- (instancetype)init {
    self = [super init];
    if (self) {
        width = SIMDECK_CAMERA_DEFAULT_WIDTH;
        height = SIMDECK_CAMERA_DEFAULT_HEIGHT;
        sourceKind = SIMDECK_CAMERA_SOURCE_PLACEHOLDER;
        pthread_mutex_init(&browserFrameLock, NULL);
    }
    return self;
}

- (void)dealloc {
    pthread_mutex_destroy(&browserFrameLock);
}

@end

static void StopBrowserSource(SimDeckCameraContext *context);

static NSMutableDictionary<NSString *, SimDeckCameraContext *> *CameraContexts(void) {
    static NSMutableDictionary<NSString *, SimDeckCameraContext *> *contexts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ contexts = [NSMutableDictionary dictionary]; });
    return contexts;
}

static NSObject *CameraLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
    });
    return lock;
}

static void RunOnMainSync(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static uint64_t NowNs(void) {
    return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000000000.0);
}

static void UpdateAtomicMaximum(atomic_ullong *target, uint64_t value) {
    uint64_t previous = atomic_load(target);
    while (value > previous && !atomic_compare_exchange_weak(target, &previous, value)) {}
}

static NSString *StringFromCString(const char *value) {
    return value ? [NSString stringWithUTF8String:value] ?: @"" : @"";
}

static NSString *FourCCString(OSType value) {
    char chars[5] = {
        (char)((value >> 24) & 0xff),
        (char)((value >> 16) & 0xff),
        (char)((value >> 8) & 0xff),
        (char)(value & 0xff),
        '\0',
    };
    for (NSUInteger index = 0; index < 4; index += 1) {
        if (chars[index] < 32 || chars[index] > 126) {
            return [NSString stringWithFormat:@"0x%08x", value];
        }
    }
    return [NSString stringWithUTF8String:chars] ?: [NSString stringWithFormat:@"0x%08x", value];
}

static uint32_t SourceKindForName(NSString *name) {
    NSString *lower = name.lowercaseString;
    if ([lower isEqualToString:@"image"]) return SIMDECK_CAMERA_SOURCE_IMAGE;
    if ([lower isEqualToString:@"video"]) return SIMDECK_CAMERA_SOURCE_VIDEO;
    if ([lower isEqualToString:@"camera"]) return SIMDECK_CAMERA_SOURCE_CAMERA;
    return SIMDECK_CAMERA_SOURCE_PLACEHOLDER;
}

static NSString *SourceNameForKind(uint32_t kind) {
    switch (kind) {
        case SIMDECK_CAMERA_SOURCE_IMAGE: return @"image";
        case SIMDECK_CAMERA_SOURCE_VIDEO: return @"video";
        case SIMDECK_CAMERA_SOURCE_CAMERA: return @"camera";
        default: return @"placeholder";
    }
}

static NSString *MirrorName(uint32_t mode) {
    switch (mode) {
        case SIMDECK_CAMERA_MIRROR_ON: return @"on";
        case SIMDECK_CAMERA_MIRROR_OFF: return @"off";
        default: return @"auto";
    }
}

static uint32_t MirrorModeForName(NSString *name) {
    NSString *lower = name.lowercaseString;
    if ([lower isEqualToString:@"on"]) return SIMDECK_CAMERA_MIRROR_ON;
    if ([lower isEqualToString:@"off"]) return SIMDECK_CAMERA_MIRROR_OFF;
    return SIMDECK_CAMERA_MIRROR_AUTO;
}

static void SetSourceMetadata(SimDeckCameraContext *context, uint32_t sourceKind, NSString *argument) {
    if (!context->header) return;
    context->header->sourceKind = sourceKind;
    memset(context->header->sourceLabel, 0, sizeof(context->header->sourceLabel));
    NSString *label = argument.length > 0 ? argument : SourceNameForKind(sourceKind);
    NSData *labelData = [label dataUsingEncoding:NSUTF8StringEncoding];
    if (labelData.length > 0) {
        memcpy(context->header->sourceLabel,
               labelData.bytes,
               MIN(labelData.length, sizeof(context->header->sourceLabel) - 1));
    }
}

static void SetSourceState(SimDeckCameraContext *context,
                           uint32_t sourceKind,
                           NSString *name,
                           NSString *argument) {
    context->sourceKind = sourceKind;
    context->sourceName = [name copy];
    context->sourceArgument = [argument copy];
}

static uint32_t ColorRangeForPixelFormat(OSType format) {
    if (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        return SIMDECK_CAMERA_COLOR_RANGE_VIDEO;
    }
    if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        format == kCVPixelFormatType_32BGRA) {
        return SIMDECK_CAMERA_COLOR_RANGE_FULL;
    }
    return SIMDECK_CAMERA_COLOR_RANGE_UNKNOWN;
}

static BOOL AttachmentEquals(CVPixelBufferRef pixelBuffer, CFStringRef key, CFStringRef expected) {
    CFTypeRef value = CVBufferCopyAttachment(pixelBuffer, key, NULL);
    BOOL matches = value && CFEqual(value, expected);
    if (value) CFRelease(value);
    return matches;
}

static uint32_t ColorPrimariesForPixelBuffer(CVPixelBufferRef pixelBuffer) {
    if (AttachmentEquals(pixelBuffer,
                         kCVImageBufferColorPrimariesKey,
                         kCVImageBufferColorPrimaries_ITU_R_709_2)) {
        return SIMDECK_CAMERA_COLOR_PRIMARIES_ITU_R_709_2;
    }
    if (AttachmentEquals(pixelBuffer,
                         kCVImageBufferColorPrimariesKey,
                         kCVImageBufferColorPrimaries_P3_D65)) {
        return SIMDECK_CAMERA_COLOR_PRIMARIES_P3_D65;
    }
    if (AttachmentEquals(pixelBuffer,
                         kCVImageBufferColorPrimariesKey,
                         kCVImageBufferColorPrimaries_ITU_R_2020)) {
        return SIMDECK_CAMERA_COLOR_PRIMARIES_ITU_R_2020;
    }
    return SIMDECK_CAMERA_COLOR_PRIMARIES_UNKNOWN;
}

static uint32_t TransferFunctionForPixelBuffer(CVPixelBufferRef pixelBuffer) {
    if (AttachmentEquals(pixelBuffer,
                         kCVImageBufferTransferFunctionKey,
                         kCVImageBufferTransferFunction_ITU_R_709_2)) {
        return SIMDECK_CAMERA_TRANSFER_FUNCTION_ITU_R_709_2;
    }
    if (AttachmentEquals(pixelBuffer,
                         kCVImageBufferTransferFunctionKey,
                         kCVImageBufferTransferFunction_sRGB)) {
        return SIMDECK_CAMERA_TRANSFER_FUNCTION_SRGB;
    }
    if (AttachmentEquals(pixelBuffer,
                         kCVImageBufferTransferFunctionKey,
                         kCVImageBufferTransferFunction_ITU_R_2020)) {
        return SIMDECK_CAMERA_TRANSFER_FUNCTION_ITU_R_2020;
    }
    return SIMDECK_CAMERA_TRANSFER_FUNCTION_UNKNOWN;
}

static uint32_t YCbCrMatrixForPixelBuffer(CVPixelBufferRef pixelBuffer) {
    if (AttachmentEquals(pixelBuffer,
                         kCVImageBufferYCbCrMatrixKey,
                         kCVImageBufferYCbCrMatrix_ITU_R_601_4)) {
        return SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_601_4;
    }
    if (AttachmentEquals(pixelBuffer,
                         kCVImageBufferYCbCrMatrixKey,
                         kCVImageBufferYCbCrMatrix_ITU_R_709_2)) {
        return SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_709_2;
    }
    if (AttachmentEquals(pixelBuffer,
                         kCVImageBufferYCbCrMatrixKey,
                         kCVImageBufferYCbCrMatrix_ITU_R_2020)) {
        return SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_2020;
    }
    return SIMDECK_CAMERA_YCBCR_MATRIX_UNKNOWN;
}

static BOOL IsBiPlanarYUV(OSType format) {
    return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

static NSString *ColorRangeName(uint32_t value) {
    switch (value) {
        case SIMDECK_CAMERA_COLOR_RANGE_VIDEO: return @"video";
        case SIMDECK_CAMERA_COLOR_RANGE_FULL: return @"full";
        default: return @"unknown";
    }
}

static NSString *ColorPrimariesName(uint32_t value) {
    switch (value) {
        case SIMDECK_CAMERA_COLOR_PRIMARIES_ITU_R_709_2: return @"bt709";
        case SIMDECK_CAMERA_COLOR_PRIMARIES_P3_D65: return @"p3-d65";
        case SIMDECK_CAMERA_COLOR_PRIMARIES_ITU_R_2020: return @"bt2020";
        default: return @"unknown";
    }
}

static NSString *TransferFunctionName(uint32_t value) {
    switch (value) {
        case SIMDECK_CAMERA_TRANSFER_FUNCTION_ITU_R_709_2: return @"bt709";
        case SIMDECK_CAMERA_TRANSFER_FUNCTION_SRGB: return @"srgb";
        case SIMDECK_CAMERA_TRANSFER_FUNCTION_ITU_R_2020: return @"bt2020";
        default: return @"unknown";
    }
}

static NSString *YCbCrMatrixName(uint32_t value) {
    switch (value) {
        case SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_601_4: return @"bt601";
        case SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_709_2: return @"bt709";
        case SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_2020: return @"bt2020";
        default: return @"unknown";
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSDictionary *GlobalSurfacePropertiesForSimulatorLookup(void) {
    return @{ (id)kIOSurfaceIsGlobal: @YES };
}
#pragma clang diagnostic pop

static CVPixelBufferRef CreateGlobalPixelBuffer(size_t width, size_t height, OSType format) {
    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: GlobalSurfacePropertiesForSimulatorLookup(),
    };
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width,
                                          height,
                                          format,
                                          (__bridge CFDictionaryRef)attributes,
                                          &pixelBuffer);
    return result == kCVReturnSuccess ? pixelBuffer : NULL;
}

static BOOL PublishSurface(SimDeckCameraContext *context,
                           CVPixelBufferRef pixelBuffer,
                           uint32_t sourceKind,
                           NSString *label) {
    if (!pixelBuffer || !context->header) return NO;
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    IOSurfaceID surfaceID = surface ? IOSurfaceGetID(surface) : 0;
    if (!surface || surfaceID == 0) {
        atomic_fetch_add(&context->surfacePublicationFailures, 1);
        atomic_fetch_add(&context->droppedFrames, 1);
        return NO;
    }

    __block BOOL published = NO;
    dispatch_sync(context->writeQueue, ^{
        if (!context->header) return;
        uint32_t slot = UINT32_MAX;
        for (uint32_t offset = 0; offset < SIMDECK_CAMERA_SURFACE_RING_SIZE; offset += 1) {
            uint32_t candidate = (context->nextSurfaceSlot + offset) % SIMDECK_CAMERA_SURFACE_RING_SIZE;
            if (!context->surfaceRing[candidate] || context->header->surfaceUseCounts[candidate] == 0) {
                slot = candidate;
                break;
            }
        }
        if (slot == UINT32_MAX) {
            atomic_fetch_add(&context->droppedFrames, 1);
            return;
        }

        size_t width = CVPixelBufferGetWidth(pixelBuffer);
        size_t height = CVPixelBufferGetHeight(pixelBuffer);
        OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
        uint32_t colorPrimaries = ColorPrimariesForPixelBuffer(pixelBuffer);
        uint32_t transferFunction = TransferFunctionForPixelBuffer(pixelBuffer);
        uint32_t yCbCrMatrix = YCbCrMatrixForPixelBuffer(pixelBuffer);
        if (IsBiPlanarYUV(format)) {
            if (colorPrimaries == SIMDECK_CAMERA_COLOR_PRIMARIES_UNKNOWN) {
                colorPrimaries = SIMDECK_CAMERA_COLOR_PRIMARIES_ITU_R_709_2;
            }
            if (transferFunction == SIMDECK_CAMERA_TRANSFER_FUNCTION_UNKNOWN) {
                transferFunction = SIMDECK_CAMERA_TRANSFER_FUNCTION_ITU_R_709_2;
            }
            if (yCbCrMatrix == SIMDECK_CAMERA_YCBCR_MATRIX_UNKNOWN) {
                yCbCrMatrix = width >= 1280
                    ? SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_709_2
                    : SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_601_4;
            }
        }
        BOOL formatChanged = context->header->width != width ||
            context->header->height != height ||
            context->header->pixelFormat != format;
        context->header->sequence += 1;
        CVPixelBufferRetain(pixelBuffer);
        if (context->surfaceRing[slot]) CVPixelBufferRelease(context->surfaceRing[slot]);
        context->surfaceRing[slot] = pixelBuffer;
        context->nextSurfaceSlot = (slot + 1) % SIMDECK_CAMERA_SURFACE_RING_SIZE;

        if (formatChanged) context->surfaceGeneration += 1;
        context->header->generation = context->surfaceGeneration;
        context->header->width = (uint32_t)width;
        context->header->height = (uint32_t)height;
        context->header->pixelFormat = format;
        context->header->colorRange = ColorRangeForPixelFormat(format);
        context->header->colorPrimaries = colorPrimaries;
        context->header->transferFunction = transferFunction;
        context->header->yCbCrMatrix = yCbCrMatrix;
        context->header->orientation = SIMDECK_CAMERA_ORIENTATION_UP;
        context->header->sourceKind = sourceKind;
        context->header->ringSlot = slot;
        context->header->surfaceIds[slot] = surfaceID;
        context->header->timestampNs = NowNs();
        SetSourceMetadata(context, sourceKind, label);
        context->header->sequence += 1;
        context->width = (uint32_t)width;
        context->height = (uint32_t)height;
        context->lastPixelFormat = format;
        atomic_fetch_add(&context->publishedFrames, 1);
        published = YES;
    });
    return published;
}

static void PublishPixelBuffer(SimDeckCameraContext *context,
                               CVPixelBufferRef pixelBuffer,
                               uint32_t sourceKind,
                               NSString *label) {
    if (!pixelBuffer) return;
    if (CVPixelBufferGetIOSurface(pixelBuffer)) {
        PublishSurface(context, pixelBuffer, sourceKind, label);
        return;
    }

    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    CVPixelBufferRef output = CreateGlobalPixelBuffer(width, height, kCVPixelFormatType_32BGRA);
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!output || !image) {
        if (output) CVPixelBufferRelease(output);
        atomic_fetch_add(&context->droppedFrames, 1);
        return;
    }
    static CIContext *imageContext;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        imageContext = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace: [NSNull null] }];
    });
    [imageContext render:image toCVPixelBuffer:output];
    if (context->header) {
        context->header->pixelConversions += 1;
        context->header->fullFrameCopies += 1;
    }
    PublishSurface(context, output, sourceKind, label);
    CVPixelBufferRelease(output);
}

static void DrawPlaceholderFrame(SimDeckCameraContext *context, uint32_t frameIndex) {
    const uint32_t width = SIMDECK_CAMERA_DEFAULT_WIDTH;
    const uint32_t height = SIMDECK_CAMERA_DEFAULT_HEIGHT;
    CVPixelBufferRef pixelBuffer = CreateGlobalPixelBuffer(width, height, kCVPixelFormatType_32BGRA);
    if (!pixelBuffer) return;
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    for (uint32_t y = 0; y < height; y += 1) {
        uint8_t *row = base + ((size_t)y * bytesPerRow);
        for (uint32_t x = 0; x < width; x += 1) {
            uint8_t *p = row + ((size_t)x * 4);
            uint8_t stripe = (uint8_t)(((x / 80) + (frameIndex / 6)) % 2 ? 56 : 24);
            p[0] = (uint8_t)((x + frameIndex * 7) % 256);
            p[1] = (uint8_t)((y + frameIndex * 3) % 256);
            p[2] = (uint8_t)(180 + stripe);
            p[3] = 0xff;
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    PublishSurface(context, pixelBuffer, SIMDECK_CAMERA_SOURCE_PLACEHOLDER, @"placeholder");
    CVPixelBufferRelease(pixelBuffer);
}

static BOOL PublishImageAtPath(SimDeckCameraContext *context, NSString *path, NSString **error) {
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) {
        if (error) *error = [NSString stringWithFormat:@"Unable to decode image at %@", path];
        return NO;
    }
    size_t sourceWidth = CGImageGetWidth(cgImage);
    size_t sourceHeight = CGImageGetHeight(cgImage);
    CVPixelBufferRef pixelBuffer = CreateGlobalPixelBuffer(sourceWidth, sourceHeight, kCVPixelFormatType_32BGRA);
    if (!pixelBuffer) {
        if (error) *error = @"Unable to allocate image surface.";
        return NO;
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmapContext = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer),
                                                       sourceWidth,
                                                       sourceHeight,
                                                       8,
                                                       CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                       colorSpace,
                                                       kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);
    if (!bitmapContext) {
        if (error) *error = @"Unable to allocate image conversion buffer.";
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return NO;
    }
    CGContextDrawImage(bitmapContext, CGRectMake(0, 0, sourceWidth, sourceHeight), cgImage);
    CGContextRelease(bitmapContext);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    BOOL published = PublishSurface(context, pixelBuffer, SIMDECK_CAMERA_SOURCE_IMAGE, path);
    CVPixelBufferRelease(pixelBuffer);
    return published;
}

static BOOL CanDecodeImageAtPath(NSString *path, NSString **error) {
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    if ([image CGImageForProposedRect:NULL context:nil hints:nil]) {
        return YES;
    }
    if (error) *error = [NSString stringWithFormat:@"Unable to decode image at %@", path];
    return NO;
}

static void PublishBrowserPixelBuffer(SimDeckCameraContext *context,
                                      CVPixelBufferRef pixelBuffer,
                                      uint64_t assembledTimestampNs,
                                      uint64_t decodedTimestampNs) {
    if (!pixelBuffer || !context->header || context->sourceKind != SIMDECK_CAMERA_SOURCE_CAMERA) return;
    if (!PublishSurface(context, pixelBuffer, SIMDECK_CAMERA_SOURCE_CAMERA, @"camera")) return;
    uint64_t publishedTimestampNs = NowNs();
    atomic_fetch_add(&context->browserPublishedFrames, 1);
    if (decodedTimestampNs > 0 && publishedTimestampNs >= decodedTimestampNs) {
        uint64_t latency = publishedTimestampNs - decodedTimestampNs;
        atomic_fetch_add(&context->browserSurfaceLatencyTotalNs, latency);
        UpdateAtomicMaximum(&context->browserSurfaceLatencyMaxNs, latency);
    }
    if (assembledTimestampNs > 0 && publishedTimestampNs >= assembledTimestampNs) {
        uint64_t latency = publishedTimestampNs - assembledTimestampNs;
        atomic_fetch_add(&context->browserPipelineLatencyTotalNs, latency);
        UpdateAtomicMaximum(&context->browserPipelineLatencyMaxNs, latency);
    }
}

static void DrainLatestBrowserFrame(SimDeckCameraContext *context) {
    while (context->sourceKind == SIMDECK_CAMERA_SOURCE_CAMERA) {
        pthread_mutex_lock(&context->browserFrameLock);
        CVPixelBufferRef pixelBuffer = context->latestBrowserPixelBuffer;
        uint64_t assembledTimestampNs = context->latestBrowserAssembledNs;
        uint64_t decodedTimestampNs = context->latestBrowserDecodedNs;
        context->latestBrowserPixelBuffer = NULL;
        context->latestBrowserAssembledNs = 0;
        context->latestBrowserDecodedNs = 0;
        if (!pixelBuffer) context->browserPublishScheduled = NO;
        pthread_mutex_unlock(&context->browserFrameLock);
        if (!pixelBuffer) return;
        PublishBrowserPixelBuffer(context, pixelBuffer, assembledTimestampNs, decodedTimestampNs);
        CVPixelBufferRelease(pixelBuffer);
    }
}

typedef struct {
    uint64_t assembledTimestampNs;
} SimDeckCameraDecodeTiming;

static void BrowserH264Output(void *refCon,
                              void *sourceFrameRefCon,
                              OSStatus status,
                              VTDecodeInfoFlags infoFlags,
                              CVImageBufferRef imageBuffer,
                              CMTime presentationTimeStamp,
                              CMTime presentationDuration) {
    SimDeckCameraContext *context = (__bridge SimDeckCameraContext *)refCon;
    (void)infoFlags;
    (void)presentationTimeStamp;
    (void)presentationDuration;
    SimDeckCameraDecodeTiming *timing = sourceFrameRefCon;
    uint64_t assembledTimestampNs = timing ? timing->assembledTimestampNs : 0;
    if (timing) free(timing);
    if (status != noErr) {
        atomic_fetch_add(&context->browserDecodeErrors, 1);
        return;
    }
    if (!imageBuffer || context->sourceKind != SIMDECK_CAMERA_SOURCE_CAMERA) return;

    uint64_t decodedTimestampNs = NowNs();
    atomic_fetch_add(&context->browserDecodedFrames, 1);
    if (assembledTimestampNs > 0 && decodedTimestampNs >= assembledTimestampNs) {
        uint64_t latency = decodedTimestampNs - assembledTimestampNs;
        atomic_fetch_add(&context->browserDecoderLatencyTotalNs, latency);
        UpdateAtomicMaximum(&context->browserDecoderLatencyMaxNs, latency);
    }

    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)imageBuffer;
    CVPixelBufferRetain(pixelBuffer);
    BOOL schedulePublisher = NO;
    pthread_mutex_lock(&context->browserFrameLock);
    if (context->latestBrowserPixelBuffer) {
        CVPixelBufferRelease(context->latestBrowserPixelBuffer);
        atomic_fetch_add(&context->droppedFrames, 1);
    }
    context->latestBrowserPixelBuffer = pixelBuffer;
    context->latestBrowserAssembledNs = assembledTimestampNs;
    context->latestBrowserDecodedNs = decodedTimestampNs;
    if (!context->browserPublishScheduled) {
        context->browserPublishScheduled = YES;
        schedulePublisher = YES;
    }
    pthread_mutex_unlock(&context->browserFrameLock);
    if (schedulePublisher) {
        dispatch_async(context->browserPublishQueue, ^{ DrainLatestBrowserFrame(context); });
    }
}

static void ReleaseBrowserH264Decoder(SimDeckCameraContext *context) {
    if (context->browserDecoder.session) {
        VTDecompressionSessionWaitForAsynchronousFrames(context->browserDecoder.session);
        VTDecompressionSessionInvalidate(context->browserDecoder.session);
        CFRelease(context->browserDecoder.session);
        context->browserDecoder.session = NULL;
    }
    if (context->browserDecoder.format) {
        CFRelease(context->browserDecoder.format);
        context->browserDecoder.format = NULL;
    }
}

static BOOL ConfigureBrowserH264Decoder(SimDeckCameraContext *context,
                                        NSData *configuration,
                                        NSString **error) {
    const uint8_t *bytes = configuration.bytes;
    NSUInteger length = configuration.length;
    if (length < 7 || bytes[0] != 1) {
        if (error) *error = @"Invalid camera H.264 decoder configuration.";
        return NO;
    }
    size_t nalLengthSize = (bytes[4] & 0x03) + 1;
    NSUInteger offset = 5;
    NSUInteger sequenceCount = bytes[offset++] & 0x1f;
    const uint8_t *parameterSets[64];
    size_t parameterSetSizes[64];
    size_t parameterSetCount = 0;
    for (NSUInteger index = 0; index < sequenceCount; index += 1) {
        if (offset + 2 > length || parameterSetCount >= 64) {
            if (error) *error = @"Invalid camera H.264 decoder configuration.";
            return NO;
        }
        NSUInteger size = ((NSUInteger)bytes[offset] << 8) | bytes[offset + 1];
        offset += 2;
        if (size == 0 || offset + size > length) {
            if (error) *error = @"Invalid camera H.264 decoder configuration.";
            return NO;
        }
        parameterSets[parameterSetCount] = bytes + offset;
        parameterSetSizes[parameterSetCount++] = size;
        offset += size;
    }
    if (offset >= length) {
        if (error) *error = @"Invalid camera H.264 decoder configuration.";
        return NO;
    }
    NSUInteger pictureCount = bytes[offset++];
    for (NSUInteger index = 0; index < pictureCount; index += 1) {
        if (offset + 2 > length || parameterSetCount >= 64) {
            if (error) *error = @"Invalid camera H.264 decoder configuration.";
            return NO;
        }
        NSUInteger size = ((NSUInteger)bytes[offset] << 8) | bytes[offset + 1];
        offset += 2;
        if (size == 0 || offset + size > length) {
            if (error) *error = @"Invalid camera H.264 decoder configuration.";
            return NO;
        }
        parameterSets[parameterSetCount] = bytes + offset;
        parameterSetSizes[parameterSetCount++] = size;
        offset += size;
    }
    if (sequenceCount == 0 || pictureCount == 0) {
        if (error) *error = @"Camera H.264 configuration has no parameter sets.";
        return NO;
    }

    ReleaseBrowserH264Decoder(context);
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        parameterSetCount,
        parameterSets,
        parameterSetSizes,
        (int)nalLengthSize,
        &context->browserDecoder.format
    );
    if (status != noErr || !context->browserDecoder.format) {
        if (error) *error = [NSString stringWithFormat:@"Camera H.264 format creation failed (%d).", status];
        return NO;
    }
    NSDictionary *pixelAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: GlobalSurfacePropertiesForSimulatorLookup(),
    };
    VTDecompressionOutputCallbackRecord callback = {
        .decompressionOutputCallback = BrowserH264Output,
        .decompressionOutputRefCon = (__bridge void *)context,
    };
    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        context->browserDecoder.format,
        NULL,
        (__bridge CFDictionaryRef)pixelAttributes,
        &callback,
        &context->browserDecoder.session
    );
    if (status != noErr || !context->browserDecoder.session) {
        if (error) *error = [NSString stringWithFormat:@"Camera H.264 decoder creation failed (%d).", status];
        ReleaseBrowserH264Decoder(context);
        return NO;
    }
    VTSessionSetProperty(context->browserDecoder.session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    atomic_store(&context->browserDecodeErrors, 0);
    atomic_store(&context->lastCameraSequence, 0);
    return YES;
}

typedef void (*SimDeckCameraReleaseCallback)(void *owner);

typedef struct {
    void *owner;
    SimDeckCameraReleaseCallback releaseOwner;
} SimDeckCameraFrameOwner;

static void ReleaseCameraFrameBlock(void *refCon, void *memoryBlock, size_t sizeInBytes) {
    (void)memoryBlock;
    (void)sizeInBytes;
    SimDeckCameraFrameOwner *frameOwner = refCon;
    frameOwner->releaseOwner(frameOwner->owner);
    free(frameOwner);
}

static BOOL DecodeBrowserH264Frame(SimDeckCameraContext *context,
                                   const uint8_t *frame,
                                   size_t frameLength,
                                   BOOL keyFrame,
                                   uint64_t assembledTimestampNs,
                                   void *owner,
                                   SimDeckCameraReleaseCallback releaseOwner,
                                   NSString **error) {
    if (!context->browserDecoder.session || !context->browserDecoder.format) {
        if (error) *error = @"Camera H.264 decoder is not configured.";
        releaseOwner(owner);
        return NO;
    }
    SimDeckCameraFrameOwner *frameOwner = malloc(sizeof(SimDeckCameraFrameOwner));
    if (!frameOwner) {
        if (error) *error = @"Unable to allocate camera H.264 frame ownership.";
        releaseOwner(owner);
        return NO;
    }
    frameOwner->owner = owner;
    frameOwner->releaseOwner = releaseOwner;
    CMBlockBufferCustomBlockSource blockSource = {0};
    blockSource.version = kCMBlockBufferCustomBlockSourceVersion;
    blockSource.FreeBlock = ReleaseCameraFrameBlock;
    blockSource.refCon = frameOwner;
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        (void *)frame,
        frameLength,
        kCFAllocatorNull,
        &blockSource,
        0,
        frameLength,
        0,
        &block
    );
    if (status != noErr || !block) {
        releaseOwner(owner);
        free(frameOwner);
        if (error) *error = [NSString stringWithFormat:@"Camera H.264 block creation failed (%d).", status];
        return NO;
    }
    CMSampleBufferRef sample = NULL;
    size_t sampleSize = frameLength;
    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        block,
        context->browserDecoder.format,
        1,
        0,
        NULL,
        1,
        &sampleSize,
        &sample
    );
    if (block) CFRelease(block);
    if (status != noErr || !sample) {
        if (error) *error = [NSString stringWithFormat:@"Camera H.264 sample creation failed (%d).", status];
        if (sample) CFRelease(sample);
        return NO;
    }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        if (!keyFrame) CFDictionarySetValue(attachment, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
    }
    SimDeckCameraDecodeTiming *timing = malloc(sizeof(SimDeckCameraDecodeTiming));
    if (!timing) {
        if (error) *error = @"Unable to allocate camera decode timing.";
        CFRelease(sample);
        return NO;
    }
    timing->assembledTimestampNs = assembledTimestampNs;
    VTDecodeInfoFlags info = 0;
    status = VTDecompressionSessionDecodeFrame(
        context->browserDecoder.session,
        sample,
        kVTDecodeFrame_EnableAsynchronousDecompression,
        timing,
        &info
    );
    CFRelease(sample);
    if (status != noErr) {
        free(timing);
        if (error) *error = [NSString stringWithFormat:@"Camera H.264 decode failed (%d).", status];
        return NO;
    }
    return YES;
}

static void StopBrowserSource(SimDeckCameraContext *context) {
    ReleaseBrowserH264Decoder(context);
    if (context->browserPublishQueue) dispatch_sync(context->browserPublishQueue, ^{});
    pthread_mutex_lock(&context->browserFrameLock);
    if (context->latestBrowserPixelBuffer) {
        CVPixelBufferRelease(context->latestBrowserPixelBuffer);
        context->latestBrowserPixelBuffer = NULL;
    }
    context->browserPublishScheduled = NO;
    context->latestBrowserAssembledNs = 0;
    context->latestBrowserDecodedNs = 0;
    pthread_mutex_unlock(&context->browserFrameLock);
}

static void StopCurrentSource(SimDeckCameraContext *context) {
    atomic_fetch_add(&context->sourceGeneration, 1);
    if (context->sourceKind == SIMDECK_CAMERA_SOURCE_CAMERA) {
        StopBrowserSource(context);
    }
    if (context->placeholderTimer) {
        dispatch_source_cancel(context->placeholderTimer);
        context->placeholderTimer = nil;
    }
}

static BOOL StartBrowserSource(SimDeckCameraContext *context, NSString **error) {
    (void)error;
    StopCurrentSource(context);
    if (!context->browserPublishQueue) {
        context->browserPublishQueue = dispatch_queue_create("dev.nativescript.simdeck.camera.stream", DISPATCH_QUEUE_SERIAL);
    }
    atomic_store(&context->browserDecodeErrors, 0);
    atomic_store(&context->browserDecodedFrames, 0);
    atomic_store(&context->browserPublishedFrames, 0);
    atomic_store(&context->browserDecoderLatencyTotalNs, 0);
    atomic_store(&context->browserDecoderLatencyMaxNs, 0);
    atomic_store(&context->browserSurfaceLatencyTotalNs, 0);
    atomic_store(&context->browserSurfaceLatencyMaxNs, 0);
    atomic_store(&context->browserPipelineLatencyTotalNs, 0);
    atomic_store(&context->browserPipelineLatencyMaxNs, 0);
    atomic_store(&context->lastCameraSequence, 0);
    SetSourceState(context, SIMDECK_CAMERA_SOURCE_CAMERA, @"camera", nil);
    SetSourceMetadata(context, SIMDECK_CAMERA_SOURCE_CAMERA, @"camera");
    return YES;
}

static BOOL StartPlaceholder(SimDeckCameraContext *context, NSString **error) {
    (void)error;
    StopCurrentSource(context);
    SetSourceState(context, SIMDECK_CAMERA_SOURCE_PLACEHOLDER, @"placeholder", nil);
    __block uint32_t frame = 0;
    DrawPlaceholderFrame(context, frame);
    dispatch_queue_t queue = dispatch_queue_create("dev.nativescript.simdeck.camera.placeholder", DISPATCH_QUEUE_SERIAL);
    context->placeholderTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(context->placeholderTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 30),
                              (uint64_t)(NSEC_PER_MSEC * 5));
    dispatch_source_set_event_handler(context->placeholderTimer, ^{
        DrawPlaceholderFrame(context, frame++);
    });
    dispatch_resume(context->placeholderTimer);
    return YES;
}

static BOOL StartImage(SimDeckCameraContext *context, NSString *path, NSString **error) {
    if (!CanDecodeImageAtPath(path, error)) {
        return NO;
    }
    StopCurrentSource(context);
    if (!PublishImageAtPath(context, path, error)) {
        return NO;
    }
    SetSourceState(context, SIMDECK_CAMERA_SOURCE_IMAGE, @"image", path);
    return YES;
}

static BOOL StartVideo(SimDeckCameraContext *context, NSString *path, NSString **error) {
    NSURL *url = nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:path ?: @""];
    if (components.scheme.length > 0) {
        url = components.URL;
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        url = [NSURL fileURLWithPath:path];
    }
    if (!url) {
        if (error) *error = [NSString stringWithFormat:@"Video file does not exist: %@", path];
        return NO;
    }
    StopCurrentSource(context);
    SetSourceState(context, SIMDECK_CAMERA_SOURCE_VIDEO, @"video", path);
    unsigned generation = atomic_load(&context->sourceGeneration);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (atomic_load(&context->sourceGeneration) == generation) {
            @autoreleasepool {
                AVAsset *asset = [AVAsset assetWithURL:url];
                dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
                    dispatch_semaphore_signal(loaded);
                }];
                if (dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
                    fprintf(stderr, "simdeck-camera: video track loading timed out\n");
                    continue;
                }
                NSError *trackError = nil;
                if ([asset statusOfValueForKey:@"tracks" error:&trackError] != AVKeyValueStatusLoaded) {
                    fprintf(stderr, "simdeck-camera: video track loading failed: %s\n", trackError.localizedDescription.UTF8String);
                    usleep(300 * 1000);
                    continue;
                }
                NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
                AVAssetTrack *track = tracks.firstObject;
                if (!track) {
                    usleep(300 * 1000);
                    continue;
                }
                NSError *readerError = nil;
                AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
                if (!reader) {
                    fprintf(stderr, "simdeck-camera: video reader failed: %s\n", readerError.localizedDescription.UTF8String);
                    usleep(300 * 1000);
                    continue;
                }
                NSDictionary *settings = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                    (id)kCVPixelBufferIOSurfacePropertiesKey: GlobalSurfacePropertiesForSimulatorLookup(),
                };
                AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
                output.alwaysCopiesSampleData = NO;
                if (![reader canAddOutput:output]) {
                    usleep(300 * 1000);
                    continue;
                }
                [reader addOutput:output];
                if (![reader startReading]) {
                    usleep(300 * 1000);
                    continue;
                }
                while (atomic_load(&context->sourceGeneration) == generation && reader.status == AVAssetReaderStatusReading) {
                    CMSampleBufferRef sample = [output copyNextSampleBuffer];
                    if (!sample) break;
                    PublishPixelBuffer(context,
                                       CMSampleBufferGetImageBuffer(sample),
                                       SIMDECK_CAMERA_SOURCE_VIDEO,
                                       path);
                    CFRelease(sample);
                    usleep(33333);
                }
            }
        }
    });
    return YES;
}

static BOOL SwitchSource(SimDeckCameraContext *context,
                         NSString *source,
                         NSString *argument,
                         NSString **error) {
    uint32_t kind = SourceKindForName(source);
    switch (kind) {
        case SIMDECK_CAMERA_SOURCE_IMAGE:
            return StartImage(context, argument ?: @"", error);
        case SIMDECK_CAMERA_SOURCE_VIDEO:
            return StartVideo(context, argument ?: @"", error);
        case SIMDECK_CAMERA_SOURCE_CAMERA:
            return StartBrowserSource(context, error);
        default:
            return StartPlaceholder(context, error);
    }
}

static NSDictionary *StatusPayload(SimDeckCameraContext *context, BOOL ok, NSString *error) {
    NSMutableDictionary *payload = [@{
        @"ok": @(ok),
        @"alive": @YES,
        @"source": context->sourceName ?: SourceNameForKind(context->sourceKind),
        @"mirror": context->header ? MirrorName(SimDeckCameraLoadMirrorMode(context->header)) : @"auto",
        @"width": @(context->width),
        @"height": @(context->height),
        @"processId": @((int)getpid()),
        @"sequence": context->header ? @(context->header->sequence) : @0,
        @"frames": @(atomic_load(&context->publishedFrames)),
        @"droppedFrames": @(atomic_load(&context->droppedFrames)),
        @"surfacePublicationFailures": @(atomic_load(&context->surfacePublicationFailures)),
    } mutableCopy];
    if (context->sourceArgument.length > 0) payload[@"arg"] = context->sourceArgument;
    if (context->header) payload[@"sourceLabel"] = StringFromCString(context->header->sourceLabel);
    if (context->header) {
        uint32_t activeConsumers = 0;
        NSMutableArray *consumerProcesses = [NSMutableArray array];
        for (uint32_t index = 0; index < SIMDECK_CAMERA_CONSUMER_SLOT_COUNT; index += 1) {
            SimDeckCameraConsumerSlot *slot = &context->header->consumers[index];
            uint32_t pid = __atomic_load_n(&slot->pid, __ATOMIC_ACQUIRE);
            uint32_t count = __atomic_load_n(&slot->count, __ATOMIC_ACQUIRE);
            if (pid == 0 || count == 0) continue;
            errno = 0;
            if (kill((pid_t)pid, 0) != 0 && errno == ESRCH) {
                __atomic_store_n(&slot->count, 0, __ATOMIC_RELEASE);
                __sync_bool_compare_and_swap(&slot->pid, pid, 0);
                __sync_fetch_and_add(&context->header->consumerRevision, 1);
                continue;
            }
            activeConsumers += count;
            [consumerProcesses addObject:@{ @"pid": @(pid), @"count": @(count) }];
        }
        payload[@"activeConsumers"] = @(activeConsumers);
        payload[@"consumerRevision"] = @(context->header->consumerRevision);
        payload[@"consumerProcesses"] = consumerProcesses;
        payload[@"surfaceGeneration"] = @(context->header->generation);
        payload[@"surfaceSlot"] = @(context->header->ringSlot);
        payload[@"surfaceId"] = @(context->header->surfaceIds[context->header->ringSlot]);
        payload[@"consumedSequence"] = @(context->header->consumedSequence);
        payload[@"surfaceLookupFailures"] = @(context->header->surfaceLookupFailures);
        payload[@"geometryConversions"] = @(context->header->geometryConversions);
        payload[@"pixelConversions"] = @(context->header->pixelConversions);
        payload[@"fullFrameCopies"] = @(context->header->fullFrameCopies);
        payload[@"sampleBufferFailures"] = @(context->header->sampleBufferFailures);
        payload[@"deliveredFrames"] = @(context->header->deliveredFrames);
        payload[@"consumerDroppedFrames"] = @(context->header->consumerDroppedFrames);
        payload[@"colorRange"] = ColorRangeName(context->header->colorRange);
        payload[@"colorPrimaries"] = ColorPrimariesName(context->header->colorPrimaries);
        payload[@"transferFunction"] = TransferFunctionName(context->header->transferFunction);
        payload[@"yCbCrMatrix"] = YCbCrMatrixName(context->header->yCbCrMatrix);
        NSMutableArray *surfaceUseCounts = [NSMutableArray arrayWithCapacity:SIMDECK_CAMERA_SURFACE_RING_SIZE];
        for (uint32_t slot = 0; slot < SIMDECK_CAMERA_SURFACE_RING_SIZE; slot += 1) {
            [surfaceUseCounts addObject:@(context->header->surfaceUseCounts[slot])];
        }
        payload[@"surfaceUseCounts"] = surfaceUseCounts;
    }
    if (context->lastPixelFormat != 0) payload[@"pixelFormat"] = FourCCString(context->lastPixelFormat);
    if (context->sourceKind == SIMDECK_CAMERA_SOURCE_CAMERA) {
        uint64_t decodedFrames = atomic_load(&context->browserDecodedFrames);
        uint64_t publishedFrames = atomic_load(&context->browserPublishedFrames);
        payload[@"decodeErrors"] = @(atomic_load(&context->browserDecodeErrors));
        payload[@"decodedFrames"] = @(decodedFrames);
        payload[@"publishedFrames"] = @(publishedFrames);
        payload[@"averageDecoderLatencyMs"] = @(decodedFrames > 0
            ? (double)atomic_load(&context->browserDecoderLatencyTotalNs) / (double)decodedFrames / 1000000.0
            : 0.0);
        payload[@"maximumDecoderLatencyMs"] = @((double)atomic_load(&context->browserDecoderLatencyMaxNs) / 1000000.0);
        payload[@"averageSurfacePublicationLatencyMs"] = @(publishedFrames > 0
            ? (double)atomic_load(&context->browserSurfaceLatencyTotalNs) / (double)publishedFrames / 1000000.0
            : 0.0);
        payload[@"maximumSurfacePublicationLatencyMs"] = @((double)atomic_load(&context->browserSurfaceLatencyMaxNs) / 1000000.0);
        payload[@"averagePipelineLatencyMs"] = @(publishedFrames > 0
            ? (double)atomic_load(&context->browserPipelineLatencyTotalNs) / (double)publishedFrames / 1000000.0
            : 0.0);
        payload[@"maximumPipelineLatencyMs"] = @((double)atomic_load(&context->browserPipelineLatencyMaxNs) / 1000000.0);
        payload[@"cameraSequence"] = @(atomic_load(&context->lastCameraSequence));
    }
    if (error.length > 0) payload[@"error"] = error;
    return payload;
}

static int OpenSharedMemory(SimDeckCameraContext *context) {
    if (!context->shmName) return -1;
    shm_unlink(context->shmName);
    context->mappedSize = (size_t)SimDeckCameraBufferSize();
    int fd = shm_open(context->shmName, O_CREAT | O_RDWR, 0644);
    if (fd < 0) {
        perror("shm_open");
        return -1;
    }
    if (ftruncate(fd, (off_t)context->mappedSize) != 0) {
        perror("ftruncate");
        close(fd);
        return -1;
    }
    void *mapped = mmap(NULL, context->mappedSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        perror("mmap");
        return -1;
    }
    context->header = (SimDeckCameraHeader *)mapped;
    memset(context->header, 0, SIMDECK_CAMERA_HEADER_SIZE);
    context->header->magic = SIMDECK_CAMERA_MAGIC;
    context->header->version = SIMDECK_CAMERA_VERSION;
    context->header->headerSize = SIMDECK_CAMERA_HEADER_SIZE;
    context->header->descriptorSize = sizeof(SimDeckCameraHeader);
    context->header->generation = 1;
    context->header->width = context->width;
    context->header->height = context->height;
    context->header->pixelFormat = kCVPixelFormatType_32BGRA;
    context->header->colorRange = SIMDECK_CAMERA_COLOR_RANGE_FULL;
    context->header->orientation = SIMDECK_CAMERA_ORIENTATION_UP;
    SimDeckCameraStoreMirrorMode(context->header, SIMDECK_CAMERA_MIRROR_AUTO);
    context->header->ringSize = SIMDECK_CAMERA_SURFACE_RING_SIZE;
    context->surfaceGeneration = 1;
    context->nextSurfaceSlot = 0;
    return 0;
}

static void Cleanup(SimDeckCameraContext *context) {
    StopCurrentSource(context);
    __block SimDeckCameraHeader *mappedHeader = NULL;
    __block size_t mappedSize = 0;
    if (context->writeQueue) {
        dispatch_sync(context->writeQueue, ^{
            mappedHeader = context->header;
            mappedSize = context->mappedSize;
            context->header = NULL;
            context->mappedSize = 0;
        });
    } else {
        mappedHeader = context->header;
        mappedSize = context->mappedSize;
        context->header = NULL;
        context->mappedSize = 0;
    }
    if (mappedHeader) {
        munmap(mappedHeader, mappedSize);
    }
    for (uint32_t slot = 0; slot < SIMDECK_CAMERA_SURFACE_RING_SIZE; slot += 1) {
        if (context->surfaceRing[slot]) {
            CVPixelBufferRelease(context->surfaceRing[slot]);
            context->surfaceRing[slot] = NULL;
        }
    }
    if (context->shmName) {
        shm_unlink(context->shmName);
        free(context->shmName);
        context->shmName = NULL;
    }
    context->sourceName = nil;
    context->sourceArgument = nil;
    context->sourceKind = SIMDECK_CAMERA_SOURCE_PLACEHOLDER;
    context->serviceStarted = NO;
}

static char *CopyCString(NSString *value) {
    const char *utf8 = value.UTF8String ?: "";
    char *copy = strdup(utf8);
    return copy ?: strdup("");
}

static void SetNativeError(char **errorMessage, NSString *message) {
    if (errorMessage) {
        *errorMessage = CopyCString(message ?: @"Unknown camera error.");
    }
}

static char *JSONCString(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload ?: @{} options:0 error:nil];
    if (!data) {
        return CopyCString(@"{}");
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
    return CopyCString(json);
}

bool simdeck_camera_start(const char *udid,
                          const char *shmName,
                          const char *source,
                          const char *sourceArgument,
                          const char *mirror,
                          char **errorMessage) {
    __block BOOL ok = NO;
    __block NSString *nativeError = nil;
    RunOnMainSync(^{
        @autoreleasepool {
            @synchronized (CameraLock()) {
                NSString *requestedUDID = StringFromCString(udid);
                if (requestedUDID.length == 0) {
                    nativeError = @"Simulator UDID is required.";
                    return;
                }
                if (!shmName || shmName[0] != '/') {
                    nativeError = @"Camera shared memory name must start with `/`.";
                    return;
                }
                SimDeckCameraContext *previous = CameraContexts()[requestedUDID];
                if (previous) {
                    Cleanup(previous);
                    [CameraContexts() removeObjectForKey:requestedUDID];
                }
                SimDeckCameraContext *context = [SimDeckCameraContext new];
                context->udid = requestedUDID;
                context->shmName = strdup(shmName);
                context->writeQueue = dispatch_queue_create("dev.nativescript.simdeck.camera.writer", DISPATCH_QUEUE_SERIAL);
                atomic_store(&context->publishedFrames, 0);
                atomic_store(&context->droppedFrames, 0);
                atomic_store(&context->surfacePublicationFailures, 0);
                context->lastPixelFormat = 0;
                [NSApplication sharedApplication];
                [NSApp finishLaunching];
                if (OpenSharedMemory(context) != 0) {
                    nativeError = @"Unable to open camera shared memory.";
                    Cleanup(context);
                    return;
                }
                if (context->header) {
                    SimDeckCameraStoreMirrorMode(context->header,
                                                 MirrorModeForName(StringFromCString(mirror)));
                }
                if (!SwitchSource(context,
                                  StringFromCString(source),
                                  StringFromCString(sourceArgument),
                                  &nativeError)) {
                    Cleanup(context);
                    return;
                }
                context->serviceStarted = YES;
                CameraContexts()[requestedUDID] = context;
                ok = YES;
            }
        }
    });
    if (!ok) {
        SetNativeError(errorMessage, nativeError);
    }
    return ok;
}

char *simdeck_camera_status(const char *udid, char **errorMessage) {
    (void)errorMessage;
    __block char *result = NULL;
    RunOnMainSync(^{
        @autoreleasepool {
            @synchronized (CameraLock()) {
                NSString *requestedUDID = StringFromCString(udid);
                SimDeckCameraContext *context = CameraContexts()[requestedUDID];
                if (!context || !context->serviceStarted) {
                    result = JSONCString(@{ @"ok": @YES, @"alive": @NO });
                    return;
                }
                result = JSONCString(StatusPayload(context, YES, nil));
            }
        }
    });
    return result;
}

char *simdeck_camera_switch(const char *udid,
                            const char *source,
                            const char *sourceArgument,
                            const char *mirror,
                            char **errorMessage) {
    __block char *result = NULL;
    __block NSString *nativeError = nil;
    RunOnMainSync(^{
        @autoreleasepool {
            @synchronized (CameraLock()) {
                NSString *requestedUDID = StringFromCString(udid);
                SimDeckCameraContext *context = CameraContexts()[requestedUDID];
                if (!context || !context->serviceStarted) {
                    nativeError = @"Camera simulation is not running for this simulator.";
                    return;
                }
                BOOL hasMirrorUpdate = mirror && mirror[0] && context->header;
                uint32_t previousMirrorMode = hasMirrorUpdate
                    ? SimDeckCameraLoadMirrorMode(context->header)
                    : SIMDECK_CAMERA_MIRROR_AUTO;
                if (mirror && mirror[0] && context->header) {
                    SimDeckCameraStoreMirrorMode(context->header,
                                                 MirrorModeForName(StringFromCString(mirror)));
                }
                if (source && source[0] && !SwitchSource(context,
                                                         StringFromCString(source),
                                                         StringFromCString(sourceArgument),
                                                         &nativeError)) {
                    if (hasMirrorUpdate && context->header) {
                        SimDeckCameraStoreMirrorMode(context->header, previousMirrorMode);
                    }
                    return;
                }
                result = JSONCString(StatusPayload(context, YES, nil));
            }
        }
    });
    if (!result) {
        SetNativeError(errorMessage, nativeError);
    }
    return result;
}

bool simdeck_camera_stop(const char *udid, char **errorMessage) {
    (void)errorMessage;
    __block BOOL stopped = NO;
    RunOnMainSync(^{
        @autoreleasepool {
            @synchronized (CameraLock()) {
                NSString *requestedUDID = StringFromCString(udid);
                SimDeckCameraContext *context = CameraContexts()[requestedUDID];
                if (context) {
                    Cleanup(context);
                    [CameraContexts() removeObjectForKey:requestedUDID];
                }
                stopped = YES;
            }
        }
    });
    return stopped;
}

bool simdeck_camera_configure_h264(const char *udid,
                                   const uint8_t *configuration,
                                   size_t configurationLength,
                                   char **errorMessage) {
    __block BOOL ok = NO;
    __block NSString *nativeError = nil;
    @autoreleasepool {
        @synchronized (CameraLock()) {
            NSString *requestedUDID = StringFromCString(udid);
            SimDeckCameraContext *context = CameraContexts()[requestedUDID];
            if (!context || !context->serviceStarted) {
                nativeError = @"Camera simulation is not running for this simulator.";
            } else if (context->sourceKind != SIMDECK_CAMERA_SOURCE_CAMERA) {
                nativeError = @"Camera source is not active.";
            } else if (!configuration || configurationLength == 0 || configurationLength > 2 * 1024 * 1024) {
                nativeError = @"Invalid camera H.264 configuration size.";
            } else {
                ok = ConfigureBrowserH264Decoder(
                    context,
                    [NSData dataWithBytesNoCopy:(void *)configuration
                                         length:configurationLength
                                   freeWhenDone:NO],
                    &nativeError
                );
            }
        }
    }
    if (!ok) SetNativeError(errorMessage, nativeError);
    return ok;
}

bool simdeck_camera_decode_h264_frame(const char *udid,
                                      const uint8_t *frame,
                                      size_t frameLength,
                                      bool keyFrame,
                                      uint32_t sequence,
                                      uint64_t assembledTimestampNs,
                                      void *owner,
                                      SimDeckCameraReleaseCallback releaseOwner,
                                      char **errorMessage) {
    __block BOOL ok = NO;
    __block BOOL ownershipTransferred = NO;
    __block NSString *nativeError = nil;
    @autoreleasepool {
        @synchronized (CameraLock()) {
            NSString *requestedUDID = StringFromCString(udid);
            SimDeckCameraContext *context = CameraContexts()[requestedUDID];
            if (!releaseOwner) {
                nativeError = @"Camera H.264 frame release callback is missing.";
            } else if (!context || !context->serviceStarted) {
                nativeError = @"Camera simulation is not running for this simulator.";
            } else if (context->sourceKind != SIMDECK_CAMERA_SOURCE_CAMERA) {
                nativeError = @"Camera source is not active.";
            } else if (!frame || frameLength == 0 || frameLength > 2 * 1024 * 1024) {
                nativeError = @"Invalid camera H.264 frame size.";
            } else {
                uint32_t previous = atomic_exchange(&context->lastCameraSequence, sequence);
                if (previous != 0 && sequence != previous + 1) {
                    atomic_fetch_add(&context->droppedFrames, 1);
                }
                ownershipTransferred = YES;
                ok = DecodeBrowserH264Frame(
                    context,
                    frame,
                    frameLength,
                    keyFrame,
                    assembledTimestampNs,
                    owner,
                    releaseOwner,
                    &nativeError
                );
            }
        }
    }
    if (!ownershipTransferred && releaseOwner) releaseOwner(owner);
    if (!ok) SetNativeError(errorMessage, nativeError);
    return ok;
}
