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
#import <fcntl.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

#define SIMDECK_CAMERA_DEFAULT_WIDTH 1280u
#define SIMDECK_CAMERA_DEFAULT_HEIGHT 720u

static uint32_t gWidth = SIMDECK_CAMERA_DEFAULT_WIDTH;
static uint32_t gHeight = SIMDECK_CAMERA_DEFAULT_HEIGHT;
static char *gShmName = NULL;
static SimDeckCameraHeader *gHeader = NULL;
static size_t gMappedSize = 0;
static dispatch_queue_t gWriteQueue;
static dispatch_source_t gPlaceholderTimer;
static atomic_uint gSourceGeneration;
static atomic_ullong gPublishedFrames;
static atomic_ullong gDroppedFrames;
static NSString *gSourceName = nil;
static NSString *gSourceArgument = nil;
static uint32_t gSourceKind = SIMDECK_CAMERA_SOURCE_PLACEHOLDER;
static OSType gLastPixelFormat = 0;
static BOOL gServiceStarted = NO;
static NSString *gActiveUDID = nil;

typedef struct {
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef format;
} SimDeckBrowserH264Decoder;

static SimDeckBrowserH264Decoder gBrowserDecoder;
static pthread_mutex_t gBrowserFrameLock = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t gBrowserPublishQueue;
static CVPixelBufferRef gLatestBrowserPixelBuffer = NULL;
static BOOL gBrowserPublishScheduled = NO;
static atomic_ullong gBrowserDecodeErrors;
static atomic_uint gLastCameraSequence;
static CVPixelBufferRef gSurfaceRing[SIMDECK_CAMERA_SURFACE_RING_SIZE];
static uint32_t gNextSurfaceSlot;
static uint64_t gSurfaceGeneration;
static atomic_ullong gSurfacePublicationFailures;

static void StopBrowserSource(void);

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

static void SetSourceMetadata(uint32_t sourceKind, NSString *argument) {
    if (!gHeader) return;
    gHeader->sourceKind = sourceKind;
    memset(gHeader->sourceLabel, 0, sizeof(gHeader->sourceLabel));
    NSString *label = argument.length > 0 ? argument : SourceNameForKind(sourceKind);
    NSData *labelData = [label dataUsingEncoding:NSUTF8StringEncoding];
    if (labelData.length > 0) {
        memcpy(gHeader->sourceLabel,
               labelData.bytes,
               MIN(labelData.length, sizeof(gHeader->sourceLabel) - 1));
    }
}

static void SetSourceState(uint32_t sourceKind, NSString *name, NSString *argument) {
    gSourceKind = sourceKind;
    gSourceName = [name copy];
    gSourceArgument = [argument copy];
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

static BOOL PublishSurface(CVPixelBufferRef pixelBuffer, uint32_t sourceKind, NSString *label) {
    if (!pixelBuffer || !gHeader) return NO;
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    IOSurfaceID surfaceID = surface ? IOSurfaceGetID(surface) : 0;
    if (!surface || surfaceID == 0) {
        atomic_fetch_add(&gSurfacePublicationFailures, 1);
        atomic_fetch_add(&gDroppedFrames, 1);
        return NO;
    }

    __block BOOL published = NO;
    dispatch_sync(gWriteQueue, ^{
        if (!gHeader) return;
        uint32_t slot = UINT32_MAX;
        for (uint32_t offset = 0; offset < SIMDECK_CAMERA_SURFACE_RING_SIZE; offset += 1) {
            uint32_t candidate = (gNextSurfaceSlot + offset) % SIMDECK_CAMERA_SURFACE_RING_SIZE;
            if (!gSurfaceRing[candidate] || gHeader->surfaceUseCounts[candidate] == 0) {
                slot = candidate;
                break;
            }
        }
        if (slot == UINT32_MAX) {
            atomic_fetch_add(&gDroppedFrames, 1);
            return;
        }

        size_t width = CVPixelBufferGetWidth(pixelBuffer);
        size_t height = CVPixelBufferGetHeight(pixelBuffer);
        OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
        BOOL formatChanged = gHeader->width != width ||
            gHeader->height != height ||
            gHeader->pixelFormat != format;
        gHeader->sequence += 1;
        CVPixelBufferRetain(pixelBuffer);
        if (gSurfaceRing[slot]) CVPixelBufferRelease(gSurfaceRing[slot]);
        gSurfaceRing[slot] = pixelBuffer;
        gNextSurfaceSlot = (slot + 1) % SIMDECK_CAMERA_SURFACE_RING_SIZE;

        if (formatChanged) gSurfaceGeneration += 1;
        gHeader->generation = gSurfaceGeneration;
        gHeader->width = (uint32_t)width;
        gHeader->height = (uint32_t)height;
        gHeader->pixelFormat = format;
        gHeader->colorRange = ColorRangeForPixelFormat(format);
        gHeader->orientation = SIMDECK_CAMERA_ORIENTATION_UP;
        gHeader->sourceKind = sourceKind;
        gHeader->ringSlot = slot;
        gHeader->surfaceIds[slot] = surfaceID;
        gHeader->timestampNs = NowNs();
        SetSourceMetadata(sourceKind, label);
        gHeader->sequence += 1;
        gWidth = (uint32_t)width;
        gHeight = (uint32_t)height;
        gLastPixelFormat = format;
        atomic_fetch_add(&gPublishedFrames, 1);
        published = YES;
    });
    return published;
}

static void PublishPixelBuffer(CVPixelBufferRef pixelBuffer, uint32_t sourceKind, NSString *label) {
    if (!pixelBuffer) return;
    if (CVPixelBufferGetIOSurface(pixelBuffer)) {
        PublishSurface(pixelBuffer, sourceKind, label);
        return;
    }

    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    CVPixelBufferRef output = CreateGlobalPixelBuffer(width, height, kCVPixelFormatType_32BGRA);
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!output || !image) {
        if (output) CVPixelBufferRelease(output);
        atomic_fetch_add(&gDroppedFrames, 1);
        return;
    }
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace: [NSNull null] }];
    });
    [context render:image toCVPixelBuffer:output];
    if (gHeader) {
        gHeader->pixelConversions += 1;
        gHeader->fullFrameCopies += 1;
    }
    PublishSurface(output, sourceKind, label);
    CVPixelBufferRelease(output);
}

static void DrawPlaceholderFrame(uint32_t frameIndex) {
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
    PublishSurface(pixelBuffer, SIMDECK_CAMERA_SOURCE_PLACEHOLDER, @"placeholder");
    CVPixelBufferRelease(pixelBuffer);
}

static BOOL PublishImageAtPath(NSString *path, NSString **error) {
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
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixelBuffer),
                                                 sourceWidth,
                                                 sourceHeight,
                                                 8,
                                                 CVPixelBufferGetBytesPerRow(pixelBuffer),
                                                 colorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        if (error) *error = @"Unable to allocate image conversion buffer.";
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return NO;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, sourceWidth, sourceHeight), cgImage);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    BOOL published = PublishSurface(pixelBuffer, SIMDECK_CAMERA_SOURCE_IMAGE, path);
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

static void PublishBrowserPixelBuffer(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer || !gHeader || gSourceKind != SIMDECK_CAMERA_SOURCE_CAMERA) return;
    PublishSurface(pixelBuffer, SIMDECK_CAMERA_SOURCE_CAMERA, @"camera");
}

static void DrainLatestBrowserFrame(void) {
    while (gSourceKind == SIMDECK_CAMERA_SOURCE_CAMERA) {
        pthread_mutex_lock(&gBrowserFrameLock);
        CVPixelBufferRef pixelBuffer = gLatestBrowserPixelBuffer;
        gLatestBrowserPixelBuffer = NULL;
        if (!pixelBuffer) gBrowserPublishScheduled = NO;
        pthread_mutex_unlock(&gBrowserFrameLock);
        if (!pixelBuffer) return;
        PublishBrowserPixelBuffer(pixelBuffer);
        CVPixelBufferRelease(pixelBuffer);
    }
}

static void BrowserH264Output(void *refCon,
                              void *sourceFrameRefCon,
                              OSStatus status,
                              VTDecodeInfoFlags infoFlags,
                              CVImageBufferRef imageBuffer,
                              CMTime presentationTimeStamp,
                              CMTime presentationDuration) {
    (void)refCon;
    (void)sourceFrameRefCon;
    (void)infoFlags;
    (void)presentationTimeStamp;
    (void)presentationDuration;
    if (status != noErr) {
        atomic_fetch_add(&gBrowserDecodeErrors, 1);
        return;
    }
    if (!imageBuffer || gSourceKind != SIMDECK_CAMERA_SOURCE_CAMERA) return;

    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)imageBuffer;
    CVPixelBufferRetain(pixelBuffer);
    BOOL schedulePublisher = NO;
    pthread_mutex_lock(&gBrowserFrameLock);
    if (gLatestBrowserPixelBuffer) {
        CVPixelBufferRelease(gLatestBrowserPixelBuffer);
        atomic_fetch_add(&gDroppedFrames, 1);
    }
    gLatestBrowserPixelBuffer = pixelBuffer;
    if (!gBrowserPublishScheduled) {
        gBrowserPublishScheduled = YES;
        schedulePublisher = YES;
    }
    pthread_mutex_unlock(&gBrowserFrameLock);
    if (schedulePublisher) {
        dispatch_async(gBrowserPublishQueue, ^{ DrainLatestBrowserFrame(); });
    }
}

static void ReleaseBrowserH264Decoder(void) {
    if (gBrowserDecoder.session) {
        VTDecompressionSessionWaitForAsynchronousFrames(gBrowserDecoder.session);
        VTDecompressionSessionInvalidate(gBrowserDecoder.session);
        CFRelease(gBrowserDecoder.session);
        gBrowserDecoder.session = NULL;
    }
    if (gBrowserDecoder.format) {
        CFRelease(gBrowserDecoder.format);
        gBrowserDecoder.format = NULL;
    }
}

static BOOL ConfigureBrowserH264Decoder(NSData *configuration, NSString **error) {
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

    ReleaseBrowserH264Decoder();
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        parameterSetCount,
        parameterSets,
        parameterSetSizes,
        (int)nalLengthSize,
        &gBrowserDecoder.format
    );
    if (status != noErr || !gBrowserDecoder.format) {
        if (error) *error = [NSString stringWithFormat:@"Camera H.264 format creation failed (%d).", status];
        return NO;
    }
    NSDictionary *pixelAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: GlobalSurfacePropertiesForSimulatorLookup(),
    };
    VTDecompressionOutputCallbackRecord callback = {
        .decompressionOutputCallback = BrowserH264Output,
        .decompressionOutputRefCon = NULL,
    };
    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        gBrowserDecoder.format,
        NULL,
        (__bridge CFDictionaryRef)pixelAttributes,
        &callback,
        &gBrowserDecoder.session
    );
    if (status != noErr || !gBrowserDecoder.session) {
        if (error) *error = [NSString stringWithFormat:@"Camera H.264 decoder creation failed (%d).", status];
        ReleaseBrowserH264Decoder();
        return NO;
    }
    VTSessionSetProperty(gBrowserDecoder.session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    atomic_store(&gBrowserDecodeErrors, 0);
    atomic_store(&gLastCameraSequence, 0);
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

static BOOL DecodeBrowserH264Frame(const uint8_t *frame,
                                   size_t frameLength,
                                   BOOL keyFrame,
                                   void *owner,
                                   SimDeckCameraReleaseCallback releaseOwner,
                                   NSString **error) {
    if (!gBrowserDecoder.session || !gBrowserDecoder.format) {
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
        gBrowserDecoder.format,
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
    VTDecodeInfoFlags info = 0;
    status = VTDecompressionSessionDecodeFrame(
        gBrowserDecoder.session,
        sample,
        kVTDecodeFrame_EnableAsynchronousDecompression,
        NULL,
        &info
    );
    CFRelease(sample);
    if (status != noErr) {
        if (error) *error = [NSString stringWithFormat:@"Camera H.264 decode failed (%d).", status];
        return NO;
    }
    return YES;
}

static void StopBrowserSource(void) {
    ReleaseBrowserH264Decoder();
    if (gBrowserPublishQueue) dispatch_sync(gBrowserPublishQueue, ^{});
    pthread_mutex_lock(&gBrowserFrameLock);
    if (gLatestBrowserPixelBuffer) {
        CVPixelBufferRelease(gLatestBrowserPixelBuffer);
        gLatestBrowserPixelBuffer = NULL;
    }
    gBrowserPublishScheduled = NO;
    pthread_mutex_unlock(&gBrowserFrameLock);
}

static void StopCurrentSource(void) {
    atomic_fetch_add(&gSourceGeneration, 1);
    if (gSourceKind == SIMDECK_CAMERA_SOURCE_CAMERA) {
        StopBrowserSource();
    }
    if (gPlaceholderTimer) {
        dispatch_source_cancel(gPlaceholderTimer);
        gPlaceholderTimer = nil;
    }
}

static BOOL StartBrowserSource(NSString **error) {
    (void)error;
    StopCurrentSource();
    if (!gBrowserPublishQueue) {
        gBrowserPublishQueue = dispatch_queue_create("dev.nativescript.simdeck.camera.stream", DISPATCH_QUEUE_SERIAL);
    }
    atomic_store(&gBrowserDecodeErrors, 0);
    atomic_store(&gLastCameraSequence, 0);
    SetSourceState(SIMDECK_CAMERA_SOURCE_CAMERA, @"camera", nil);
    SetSourceMetadata(SIMDECK_CAMERA_SOURCE_CAMERA, @"camera");
    return YES;
}

static BOOL StartPlaceholder(NSString **error) {
    (void)error;
    StopCurrentSource();
    SetSourceState(SIMDECK_CAMERA_SOURCE_PLACEHOLDER, @"placeholder", nil);
    __block uint32_t frame = 0;
    DrawPlaceholderFrame(frame);
    dispatch_queue_t queue = dispatch_queue_create("dev.nativescript.simdeck.camera.placeholder", DISPATCH_QUEUE_SERIAL);
    gPlaceholderTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(gPlaceholderTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 30),
                              (uint64_t)(NSEC_PER_MSEC * 5));
    dispatch_source_set_event_handler(gPlaceholderTimer, ^{
        DrawPlaceholderFrame(frame++);
    });
    dispatch_resume(gPlaceholderTimer);
    return YES;
}

static BOOL StartImage(NSString *path, NSString **error) {
    if (!CanDecodeImageAtPath(path, error)) {
        return NO;
    }
    StopCurrentSource();
    if (!PublishImageAtPath(path, error)) {
        return NO;
    }
    SetSourceState(SIMDECK_CAMERA_SOURCE_IMAGE, @"image", path);
    return YES;
}

static BOOL StartVideo(NSString *path, NSString **error) {
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
    StopCurrentSource();
    SetSourceState(SIMDECK_CAMERA_SOURCE_VIDEO, @"video", path);
    unsigned generation = atomic_load(&gSourceGeneration);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (atomic_load(&gSourceGeneration) == generation) {
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
                while (atomic_load(&gSourceGeneration) == generation && reader.status == AVAssetReaderStatusReading) {
                    CMSampleBufferRef sample = [output copyNextSampleBuffer];
                    if (!sample) break;
                    PublishPixelBuffer(CMSampleBufferGetImageBuffer(sample), SIMDECK_CAMERA_SOURCE_VIDEO, path);
                    CFRelease(sample);
                    usleep(33333);
                }
            }
        }
    });
    return YES;
}

static BOOL SwitchSource(NSString *source, NSString *argument, NSString **error) {
    uint32_t kind = SourceKindForName(source);
    switch (kind) {
        case SIMDECK_CAMERA_SOURCE_IMAGE:
            return StartImage(argument ?: @"", error);
        case SIMDECK_CAMERA_SOURCE_VIDEO:
            return StartVideo(argument ?: @"", error);
        case SIMDECK_CAMERA_SOURCE_CAMERA:
            return StartBrowserSource(error);
        default:
            return StartPlaceholder(error);
    }
}

static NSDictionary *StatusPayload(BOOL ok, NSString *error) {
    NSMutableDictionary *payload = [@{
        @"ok": @(ok),
        @"alive": @YES,
        @"source": gSourceName ?: SourceNameForKind(gSourceKind),
        @"mirror": gHeader ? MirrorName(gHeader->mirrorMode) : @"auto",
        @"width": @(gWidth),
        @"height": @(gHeight),
        @"processId": @((int)getpid()),
        @"sequence": gHeader ? @(gHeader->sequence) : @0,
        @"frames": @(atomic_load(&gPublishedFrames)),
        @"droppedFrames": @(atomic_load(&gDroppedFrames)),
        @"surfacePublicationFailures": @(atomic_load(&gSurfacePublicationFailures)),
    } mutableCopy];
    if (gSourceArgument.length > 0) payload[@"arg"] = gSourceArgument;
    if (gHeader) payload[@"sourceLabel"] = StringFromCString(gHeader->sourceLabel);
    if (gHeader) {
        payload[@"surfaceGeneration"] = @(gHeader->generation);
        payload[@"surfaceSlot"] = @(gHeader->ringSlot);
        payload[@"surfaceId"] = @(gHeader->surfaceIds[gHeader->ringSlot]);
        payload[@"consumedSequence"] = @(gHeader->consumedSequence);
        payload[@"surfaceLookupFailures"] = @(gHeader->surfaceLookupFailures);
        payload[@"geometryConversions"] = @(gHeader->geometryConversions);
        payload[@"pixelConversions"] = @(gHeader->pixelConversions);
        payload[@"fullFrameCopies"] = @(gHeader->fullFrameCopies);
        payload[@"sampleBufferFailures"] = @(gHeader->sampleBufferFailures);
        payload[@"deliveredFrames"] = @(gHeader->deliveredFrames);
        payload[@"consumerDroppedFrames"] = @(gHeader->consumerDroppedFrames);
        NSMutableArray *surfaceUseCounts = [NSMutableArray arrayWithCapacity:SIMDECK_CAMERA_SURFACE_RING_SIZE];
        for (uint32_t slot = 0; slot < SIMDECK_CAMERA_SURFACE_RING_SIZE; slot += 1) {
            [surfaceUseCounts addObject:@(gHeader->surfaceUseCounts[slot])];
        }
        payload[@"surfaceUseCounts"] = surfaceUseCounts;
    }
    if (gLastPixelFormat != 0) payload[@"pixelFormat"] = FourCCString(gLastPixelFormat);
    if (gSourceKind == SIMDECK_CAMERA_SOURCE_CAMERA) {
        payload[@"decodeErrors"] = @(atomic_load(&gBrowserDecodeErrors));
        payload[@"cameraSequence"] = @(atomic_load(&gLastCameraSequence));
    }
    if (error.length > 0) payload[@"error"] = error;
    return payload;
}

static int OpenSharedMemory(void) {
    if (!gShmName) return -1;
    shm_unlink(gShmName);
    gMappedSize = (size_t)SimDeckCameraBufferSize();
    int fd = shm_open(gShmName, O_CREAT | O_RDWR, 0644);
    if (fd < 0) {
        perror("shm_open");
        return -1;
    }
    if (ftruncate(fd, (off_t)gMappedSize) != 0) {
        perror("ftruncate");
        close(fd);
        return -1;
    }
    void *mapped = mmap(NULL, gMappedSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        perror("mmap");
        return -1;
    }
    gHeader = (SimDeckCameraHeader *)mapped;
    memset(gHeader, 0, SIMDECK_CAMERA_HEADER_SIZE);
    gHeader->magic = SIMDECK_CAMERA_MAGIC;
    gHeader->version = SIMDECK_CAMERA_VERSION;
    gHeader->headerSize = SIMDECK_CAMERA_HEADER_SIZE;
    gHeader->descriptorSize = sizeof(SimDeckCameraHeader);
    gHeader->generation = 1;
    gHeader->width = gWidth;
    gHeader->height = gHeight;
    gHeader->pixelFormat = kCVPixelFormatType_32BGRA;
    gHeader->colorRange = SIMDECK_CAMERA_COLOR_RANGE_FULL;
    gHeader->orientation = SIMDECK_CAMERA_ORIENTATION_UP;
    gHeader->mirrorMode = SIMDECK_CAMERA_MIRROR_AUTO;
    gHeader->ringSize = SIMDECK_CAMERA_SURFACE_RING_SIZE;
    gSurfaceGeneration = 1;
    gNextSurfaceSlot = 0;
    return 0;
}

static void Cleanup(void) {
    StopCurrentSource();
    __block SimDeckCameraHeader *mappedHeader = NULL;
    __block size_t mappedSize = 0;
    if (gWriteQueue) {
        dispatch_sync(gWriteQueue, ^{
            mappedHeader = gHeader;
            mappedSize = gMappedSize;
            gHeader = NULL;
            gMappedSize = 0;
        });
    } else {
        mappedHeader = gHeader;
        mappedSize = gMappedSize;
        gHeader = NULL;
        gMappedSize = 0;
    }
    if (mappedHeader) {
        munmap(mappedHeader, mappedSize);
    }
    for (uint32_t slot = 0; slot < SIMDECK_CAMERA_SURFACE_RING_SIZE; slot += 1) {
        if (gSurfaceRing[slot]) {
            CVPixelBufferRelease(gSurfaceRing[slot]);
            gSurfaceRing[slot] = NULL;
        }
    }
    if (gShmName) {
        shm_unlink(gShmName);
        free(gShmName);
        gShmName = NULL;
    }
    gSourceName = nil;
    gSourceArgument = nil;
    gSourceKind = SIMDECK_CAMERA_SOURCE_PLACEHOLDER;
    gActiveUDID = nil;
    gServiceStarted = NO;
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
                Cleanup();
                if (!shmName || shmName[0] != '/') {
                    nativeError = @"Camera shared memory name must start with `/`.";
                    return;
                }
                gActiveUDID = [StringFromCString(udid) copy];
                gShmName = strdup(shmName);
                gWriteQueue = dispatch_queue_create("dev.nativescript.simdeck.camera.writer", DISPATCH_QUEUE_SERIAL);
                atomic_store(&gPublishedFrames, 0);
                atomic_store(&gDroppedFrames, 0);
                atomic_store(&gSurfacePublicationFailures, 0);
                gLastPixelFormat = 0;
                [NSApplication sharedApplication];
                [NSApp finishLaunching];
                if (OpenSharedMemory() != 0) {
                    nativeError = @"Unable to open camera shared memory.";
                    Cleanup();
                    return;
                }
                if (gHeader) {
                    gHeader->mirrorMode = MirrorModeForName(StringFromCString(mirror));
                }
                if (!SwitchSource(StringFromCString(source), StringFromCString(sourceArgument), &nativeError)) {
                    Cleanup();
                    return;
                }
                gServiceStarted = YES;
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
                if (!gServiceStarted || (requestedUDID.length > 0 && gActiveUDID.length > 0 && ![requestedUDID isEqualToString:gActiveUDID])) {
                    result = JSONCString(@{ @"ok": @YES, @"alive": @NO });
                    return;
                }
                result = JSONCString(StatusPayload(YES, nil));
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
                if (!gServiceStarted || (requestedUDID.length > 0 && gActiveUDID.length > 0 && ![requestedUDID isEqualToString:gActiveUDID])) {
                    nativeError = @"Camera simulation is not running for this simulator.";
                    return;
                }
                BOOL hasMirrorUpdate = mirror && mirror[0] && gHeader;
                uint32_t previousMirrorMode = hasMirrorUpdate ? gHeader->mirrorMode : SIMDECK_CAMERA_MIRROR_AUTO;
                if (mirror && mirror[0] && gHeader) {
                    gHeader->mirrorMode = MirrorModeForName(StringFromCString(mirror));
                }
                if (source && source[0] && !SwitchSource(StringFromCString(source), StringFromCString(sourceArgument), &nativeError)) {
                    if (hasMirrorUpdate && gHeader) {
                        gHeader->mirrorMode = previousMirrorMode;
                    }
                    return;
                }
                result = JSONCString(StatusPayload(YES, nil));
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
                if (requestedUDID.length == 0 || gActiveUDID.length == 0 || [requestedUDID isEqualToString:gActiveUDID]) {
                    Cleanup();
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
            if (!gServiceStarted || ![requestedUDID isEqualToString:gActiveUDID]) {
                nativeError = @"Camera simulation is not running for this simulator.";
            } else if (gSourceKind != SIMDECK_CAMERA_SOURCE_CAMERA) {
                nativeError = @"Camera source is not active.";
            } else if (!configuration || configurationLength == 0 || configurationLength > 2 * 1024 * 1024) {
                nativeError = @"Invalid camera H.264 configuration size.";
            } else {
                ok = ConfigureBrowserH264Decoder(
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
                                      void *owner,
                                      SimDeckCameraReleaseCallback releaseOwner,
                                      char **errorMessage) {
    __block BOOL ok = NO;
    __block BOOL ownershipTransferred = NO;
    __block NSString *nativeError = nil;
    @autoreleasepool {
        @synchronized (CameraLock()) {
            NSString *requestedUDID = StringFromCString(udid);
            if (!releaseOwner) {
                nativeError = @"Camera H.264 frame release callback is missing.";
            } else if (!gServiceStarted || ![requestedUDID isEqualToString:gActiveUDID]) {
                nativeError = @"Camera simulation is not running for this simulator.";
            } else if (gSourceKind != SIMDECK_CAMERA_SOURCE_CAMERA) {
                nativeError = @"Camera source is not active.";
            } else if (!frame || frameLength == 0 || frameLength > 2 * 1024 * 1024) {
                nativeError = @"Invalid camera H.264 frame size.";
            } else {
                uint32_t previous = atomic_exchange(&gLastCameraSequence, sequence);
                if (previous != 0 && sequence != previous + 1) {
                    atomic_fetch_add(&gDroppedFrames, 1);
                }
                ownershipTransferred = YES;
                ok = DecodeBrowserH264Frame(
                    frame,
                    frameLength,
                    keyFrame,
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
