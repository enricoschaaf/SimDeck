#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import "SimDeckCameraShared.h"

#import <CoreVideo/CoreVideo.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <pthread.h>
#import <signal.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

static uint32_t gWidth = 1280;
static uint32_t gHeight = 720;
static char *gShmName = NULL;
static SimDeckCameraHeader *gHeader = NULL;
static uint8_t *gPixels = NULL;
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
static CIContext *gBrowserRenderContext;
static atomic_ullong gBrowserDecodeErrors;
static atomic_uint gLastCameraSequence;

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

static void PublishBGRA(const uint8_t *source,
                        uint32_t sourceWidth,
                        uint32_t sourceHeight,
                        size_t sourceBytesPerRow,
                        uint32_t sourceKind,
                        NSString *label) {
    if (!gHeader || !gPixels || !source || sourceWidth == 0 || sourceHeight == 0) return;
    dispatch_sync(gWriteQueue, ^{
        gHeader->sequence += 1;
        for (uint32_t y = 0; y < gHeight; y += 1) {
            uint32_t sy = (uint32_t)(((uint64_t)y * sourceHeight) / MAX(gHeight, 1));
            const uint8_t *sourceRow = source + ((size_t)sy * sourceBytesPerRow);
            uint8_t *destRow = gPixels + ((size_t)y * gHeader->bytesPerRow);
            for (uint32_t x = 0; x < gWidth; x += 1) {
                uint32_t sx = (uint32_t)(((uint64_t)x * sourceWidth) / MAX(gWidth, 1));
                const uint8_t *pixel = sourceRow + ((size_t)sx * 4);
                uint8_t *out = destRow + ((size_t)x * 4);
                out[0] = pixel[0];
                out[1] = pixel[1];
                out[2] = pixel[2];
                out[3] = 0xff;
            }
        }
        gHeader->timestampNs = NowNs();
        gHeader->sourceKind = sourceKind;
        SetSourceMetadata(sourceKind, label);
        gHeader->sequence += 1;
        atomic_fetch_add(&gPublishedFrames, 1);
    });
}

static void PublishPixelBuffer(CVPixelBufferRef pixelBuffer, uint32_t sourceKind, NSString *label) {
    if (!pixelBuffer) return;
    OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
    gLastPixelFormat = format;
    if (format == kCVPixelFormatType_32BGRA) {
        CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        PublishBGRA((const uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer),
                    (uint32_t)CVPixelBufferGetWidth(pixelBuffer),
                    (uint32_t)CVPixelBufferGetHeight(pixelBuffer),
                    CVPixelBufferGetBytesPerRow(pixelBuffer),
                    sourceKind,
                    label);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }

    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!image) {
        atomic_fetch_add(&gDroppedFrames, 1);
        return;
    }
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        context = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace: [NSNull null] }];
    });
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t bytesPerRow = width * 4;
    NSMutableData *data = [NSMutableData dataWithLength:bytesPerRow * height];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [context render:image
           toBitmap:data.mutableBytes
           rowBytes:bytesPerRow
             bounds:CGRectMake(0, 0, width, height)
             format:kCIFormatBGRA8
         colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);
    PublishBGRA(data.bytes,
                (uint32_t)width,
                (uint32_t)height,
                bytesPerRow,
                sourceKind,
                label);
}

static void DrawPlaceholderFrame(uint32_t frameIndex) {
    if (!gHeader || !gPixels) return;
    dispatch_sync(gWriteQueue, ^{
        gHeader->sequence += 1;
        for (uint32_t y = 0; y < gHeight; y += 1) {
            uint8_t *row = gPixels + ((size_t)y * gHeader->bytesPerRow);
            for (uint32_t x = 0; x < gWidth; x += 1) {
                uint8_t *p = row + ((size_t)x * 4);
                uint8_t stripe = (uint8_t)(((x / 80) + (frameIndex / 6)) % 2 ? 56 : 24);
                p[0] = (uint8_t)((x + frameIndex * 7) % 256);
                p[1] = (uint8_t)((y + frameIndex * 3) % 256);
                p[2] = (uint8_t)(180 + stripe);
                p[3] = 0xff;
            }
        }
        gHeader->timestampNs = NowNs();
        SetSourceMetadata(SIMDECK_CAMERA_SOURCE_PLACEHOLDER, @"placeholder");
        gHeader->sequence += 1;
        atomic_fetch_add(&gPublishedFrames, 1);
    });
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
    size_t bytesPerRow = sourceWidth * 4;
    NSMutableData *data = [NSMutableData dataWithLength:bytesPerRow * sourceHeight];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(data.mutableBytes,
                                                 sourceWidth,
                                                 sourceHeight,
                                                 8,
                                                 bytesPerRow,
                                                 colorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        if (error) *error = @"Unable to allocate image conversion buffer.";
        return NO;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, sourceWidth, sourceHeight), cgImage);
    CGContextRelease(context);
    PublishBGRA(data.bytes,
                (uint32_t)sourceWidth,
                (uint32_t)sourceHeight,
                bytesPerRow,
                SIMDECK_CAMERA_SOURCE_IMAGE,
                path);
    return YES;
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
    if (!pixelBuffer || !gHeader || !gPixels || gSourceKind != SIMDECK_CAMERA_SOURCE_CAMERA) return;
    gLastPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    CIImage *source = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!source) {
        atomic_fetch_add(&gDroppedFrames, 1);
        return;
    }
    size_t sourceWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t sourceHeight = CVPixelBufferGetHeight(pixelBuffer);
    if (sourceWidth == 0 || sourceHeight == 0) return;
    CGFloat scale = MIN((CGFloat)gWidth / sourceWidth, (CGFloat)gHeight / sourceHeight);
    CIImage *scaled = [source imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect scaledExtent = scaled.extent;
    CGFloat targetX = ((CGFloat)gWidth - scaledExtent.size.width) / 2.0 - scaledExtent.origin.x;
    CGFloat targetY = ((CGFloat)gHeight - scaledExtent.size.height) / 2.0 - scaledExtent.origin.y;
    CIImage *positioned = [scaled imageByApplyingTransform:CGAffineTransformMakeTranslation(targetX, targetY)];
    CGRect outputBounds = CGRectMake(0, 0, gWidth, gHeight);
    CIImage *background = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
        imageByCroppingToRect:outputBounds];
    CIImage *composed = [positioned imageByCompositingOverImage:background];
    dispatch_sync(gWriteQueue, ^{
        gHeader->sequence += 1;
        [gBrowserRenderContext render:composed
                             toBitmap:gPixels
                             rowBytes:gHeader->bytesPerRow
                               bounds:outputBounds
                               format:kCIFormatBGRA8
                           colorSpace:nil];
        gHeader->timestampNs = NowNs();
        SetSourceMetadata(SIMDECK_CAMERA_SOURCE_CAMERA, @"camera");
        gHeader->sequence += 1;
        atomic_fetch_add(&gPublishedFrames, 1);
    });
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
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
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

static BOOL DecodeBrowserH264Frame(NSData *frame, BOOL keyFrame, NSString **error) {
    if (!gBrowserDecoder.session || !gBrowserDecoder.format) {
        if (error) *error = @"Camera H.264 decoder is not configured.";
        return NO;
    }
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        NULL,
        frame.length,
        kCFAllocatorDefault,
        NULL,
        0,
        frame.length,
        0,
        &block
    );
    if (status == noErr) {
        status = CMBlockBufferReplaceDataBytes(frame.bytes, block, 0, frame.length);
    }
    CMSampleBufferRef sample = NULL;
    if (status == noErr) {
        size_t sampleSize = frame.length;
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
    }
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
    if (!gBrowserRenderContext) {
        gBrowserRenderContext = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
            kCIContextCacheIntermediates: @NO,
            kCIContextWorkingColorSpace: [NSNull null],
        }];
    }
    atomic_store(&gBrowserDecodeErrors, 0);
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
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
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
    } mutableCopy];
    if (gSourceArgument.length > 0) payload[@"arg"] = gSourceArgument;
    if (gHeader) payload[@"sourceLabel"] = StringFromCString(gHeader->sourceLabel);
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
    gMappedSize = (size_t)SimDeckCameraBufferSize(gWidth, gHeight);
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
    gHeader->width = gWidth;
    gHeader->height = gHeight;
    gHeader->bytesPerRow = gWidth * 4;
    gHeader->pixelFormat = kCVPixelFormatType_32BGRA;
    gHeader->mirrorMode = SIMDECK_CAMERA_MIRROR_AUTO;
    gPixels = ((uint8_t *)mapped) + SIMDECK_CAMERA_HEADER_SIZE;
    return 0;
}

static void Cleanup(void) {
    StopCurrentSource();
    if (gHeader) {
        munmap(gHeader, gMappedSize);
        gHeader = NULL;
    }
    if (gShmName) {
        shm_unlink(gShmName);
        free(gShmName);
        gShmName = NULL;
    }
    gPixels = NULL;
    gMappedSize = 0;
    gSourceName = nil;
    gSourceArgument = nil;
    gSourceKind = SIMDECK_CAMERA_SOURCE_PLACEHOLDER;
    gActiveUDID = nil;
    gServiceStarted = NO;
}

static void SignalHandler(int signalNumber) {
    (void)signalNumber;
    Cleanup();
    _exit(0);
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
                gLastPixelFormat = 0;
                [NSApplication sharedApplication];
                [NSApp finishLaunching];
                signal(SIGINT, SignalHandler);
                signal(SIGTERM, SignalHandler);
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

bool simdeck_camera_publish_packet(const char *udid,
                                   const uint8_t *packet,
                                   size_t packetLength,
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
            } else if (!packet || packetLength < 2 || packetLength > 2 * 1024 * 1024) {
                nativeError = @"Invalid camera H.264 packet size.";
            } else if (packet[0] == 1) {
                ok = ConfigureBrowserH264Decoder(
                    [NSData dataWithBytes:packet + 1 length:packetLength - 1],
                    &nativeError
                );
            } else if (packet[0] == 2 && packetLength > 6) {
                uint32_t sequence = ((uint32_t)packet[2] << 24)
                    | ((uint32_t)packet[3] << 16)
                    | ((uint32_t)packet[4] << 8)
                    | (uint32_t)packet[5];
                uint32_t previous = atomic_exchange(&gLastCameraSequence, sequence);
                if (previous != 0 && sequence != previous + 1) {
                    atomic_fetch_add(&gDroppedFrames, 1);
                }
                ok = DecodeBrowserH264Frame(
                    [NSData dataWithBytes:packet + 6 length:packetLength - 6],
                    packet[1] == 1,
                    &nativeError
                );
            } else {
                nativeError = @"Unknown camera H.264 packet.";
            }
        }
    }
    if (!ok) SetNativeError(errorMessage, nativeError);
    return ok;
}
