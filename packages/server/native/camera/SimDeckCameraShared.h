#pragma once

#include <stdint.h>

#define SIMDECK_CAMERA_MAGIC 0x4d434453u
#define SIMDECK_CAMERA_VERSION 5u
#define SIMDECK_CAMERA_HEADER_SIZE 4096u
#define SIMDECK_CAMERA_SURFACE_RING_SIZE 6u
#define SIMDECK_CAMERA_CONSUMER_SLOT_COUNT 16u
#define SIMDECK_CAMERA_SOURCE_PLACEHOLDER 1u
#define SIMDECK_CAMERA_SOURCE_IMAGE 2u
#define SIMDECK_CAMERA_SOURCE_VIDEO 3u
#define SIMDECK_CAMERA_SOURCE_CAMERA 4u
#define SIMDECK_CAMERA_MIRROR_AUTO 0u
#define SIMDECK_CAMERA_MIRROR_OFF 1u
#define SIMDECK_CAMERA_MIRROR_ON 2u
#define SIMDECK_CAMERA_COLOR_RANGE_UNKNOWN 0u
#define SIMDECK_CAMERA_COLOR_RANGE_VIDEO 1u
#define SIMDECK_CAMERA_COLOR_RANGE_FULL 2u
#define SIMDECK_CAMERA_COLOR_PRIMARIES_UNKNOWN 0u
#define SIMDECK_CAMERA_COLOR_PRIMARIES_ITU_R_709_2 1u
#define SIMDECK_CAMERA_COLOR_PRIMARIES_P3_D65 2u
#define SIMDECK_CAMERA_COLOR_PRIMARIES_ITU_R_2020 3u
#define SIMDECK_CAMERA_TRANSFER_FUNCTION_UNKNOWN 0u
#define SIMDECK_CAMERA_TRANSFER_FUNCTION_ITU_R_709_2 1u
#define SIMDECK_CAMERA_TRANSFER_FUNCTION_SRGB 2u
#define SIMDECK_CAMERA_TRANSFER_FUNCTION_ITU_R_2020 3u
#define SIMDECK_CAMERA_YCBCR_MATRIX_UNKNOWN 0u
#define SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_601_4 1u
#define SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_709_2 2u
#define SIMDECK_CAMERA_YCBCR_MATRIX_ITU_R_2020 3u
#define SIMDECK_CAMERA_ORIENTATION_UP 1u

typedef struct SimDeckCameraConsumerSlot {
    volatile uint32_t pid;
    volatile uint32_t count;
} SimDeckCameraConsumerSlot;

typedef struct SimDeckCameraHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t headerSize;
    uint32_t descriptorSize;
    volatile uint64_t generation;
    volatile uint64_t sequence;
    uint32_t width;
    uint32_t height;
    uint32_t pixelFormat;
    uint32_t colorRange;
    uint32_t colorPrimaries;
    uint32_t transferFunction;
    uint32_t yCbCrMatrix;
    uint32_t orientation;
    uint32_t sourceKind;
    volatile uint32_t mirrorMode;
    uint32_t ringSlot;
    uint32_t ringSize;
    uint32_t surfaceIds[SIMDECK_CAMERA_SURFACE_RING_SIZE];
    volatile uint32_t surfaceUseCounts[SIMDECK_CAMERA_SURFACE_RING_SIZE];
    volatile uint32_t consumerPid;
    uint64_t timestampNs;
    volatile uint64_t consumedSequence;
    volatile uint64_t surfaceLookupFailures;
    volatile uint64_t geometryConversions;
    volatile uint64_t pixelConversions;
    volatile uint64_t fullFrameCopies;
    volatile uint64_t sampleBufferFailures;
    volatile uint64_t deliveredFrames;
    volatile uint64_t consumerDroppedFrames;
    volatile uint64_t consumerRevision;
    volatile uint64_t consumerActivityTimestampNs;
    SimDeckCameraConsumerSlot consumers[SIMDECK_CAMERA_CONSUMER_SLOT_COUNT];
    char sourceLabel[240];
} SimDeckCameraHeader;

static inline uint32_t SimDeckCameraLoadMirrorMode(const SimDeckCameraHeader *header) {
    return __atomic_load_n(&header->mirrorMode, __ATOMIC_ACQUIRE);
}

static inline void SimDeckCameraStoreMirrorMode(SimDeckCameraHeader *header, uint32_t value) {
    __atomic_store_n(&header->mirrorMode, value, __ATOMIC_RELEASE);
}

static inline uint64_t SimDeckCameraBufferSize(void) {
    return (uint64_t)SIMDECK_CAMERA_HEADER_SIZE;
}
