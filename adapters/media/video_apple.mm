// Video decode on Apple platforms: AVAssetReader streams a track's
// frames off the hardware decoder one sample buffer at a time, so a
// live texture pulls the next in O(1). Looping recreates the reader,
// the only way AVAssetReader rewinds. No vendor type escapes.

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <new>

// This TU keeps exceptions enabled: AVFoundation raises NSException on
// reader misuse, and the modern ObjC runtime unwinds those as C++
// exceptions regardless of the C++ flag. Every extern "C" entry is a
// guard mapping any unwind to its failure value, never into Zig.
#define GOSS_SHIM_GUARD(ret_type, failure_value, call)                        \
  try {                                                                       \
    @try {                                                                    \
      return (call);                                                          \
    } @catch (NSException* e) {                                               \
      fprintf(stderr, "gosslens video: %s: %s\n", e.name.UTF8String,          \
              e.reason ? e.reason.UTF8String : "");                           \
      return (failure_value);                                                 \
    }                                                                         \
  } catch (...) {                                                             \
    return (failure_value);                                                   \
  }

namespace {

struct VideoDecoder {
  AVURLAsset* asset = nil;
  AVAssetTrack* track = nil;
  AVAssetReader* reader = nil;
  AVAssetReaderTrackOutput* output = nil;
  uint32_t width = 0;
  uint32_t height = 0;
  int64_t duration_us = 0;
};

// A fresh reader over the retained track, positioned at a time. The prior reader,
// if any, is cancelled first. AVAssetReader is forward-only, so rebuilding it with
// a time range IS the seek: it decodes from the keyframe at or before the target,
// which is what a container's index can offer and what a scrubber needs.
bool startReaderAt(VideoDecoder* d, int64_t from_us) {
  if (d->reader) {
    [d->reader cancelReading];
    d->reader = nil;
    d->output = nil;
  }
  NSError* error = nil;
  AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:d->asset error:&error];
  if (reader == nil || error != nil) return false;
  if (from_us > 0) {
    const CMTime start = CMTimeMake(from_us, 1000000);
    reader.timeRange = CMTimeRangeMake(start, kCMTimePositiveInfinity);
  }
  AVAssetReaderTrackOutput* output = [[AVAssetReaderTrackOutput alloc]
      initWithTrack:d->track
     outputSettings:@{(NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)}];
  if (![reader canAddOutput:output]) return false;
  [reader addOutput:output];
  if (![reader startReading]) return false;
  d->reader = reader;
  d->output = output;
  return true;
}

bool startReader(VideoDecoder* d) { return startReaderAt(d, 0); }

void* video_open_impl(const uint8_t* path, size_t path_len,
                      uint32_t* out_width, uint32_t* out_height) {
  if (path == nullptr || path_len == 0) return nullptr;
  @autoreleasepool {
    NSString* ns_path = [[NSString alloc] initWithBytes:path
                                                 length:path_len
                                               encoding:NSUTF8StringEncoding];
    if (ns_path == nil) return nullptr;
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:ns_path] options:nil];
    __block NSArray<AVAssetTrack*>* tracks = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeVideo
                 completionHandler:^(NSArray<AVAssetTrack*>* result, NSError* load_error) {
                   tracks = load_error == nil ? result : nil;
                   dispatch_semaphore_signal(loaded);
                 }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    if (tracks.count == 0) return nullptr;

    auto* d = new (std::nothrow) VideoDecoder();
    if (d == nullptr) return nullptr;
    d->asset = asset;
    d->track = tracks.firstObject;
    d->width = (uint32_t)d->track.naturalSize.width;
    d->height = (uint32_t)d->track.naturalSize.height;
    const CMTime dur = d->track.timeRange.duration;
    d->duration_us = CMTIME_IS_VALID(dur) ? (int64_t)(CMTimeGetSeconds(dur) * 1000000.0) : 0;
    if (!startReader(d)) {
      delete d;
      return nullptr;
    }
    if (out_width) *out_width = d->width;
    if (out_height) *out_height = d->height;
    return d;
  }
}

int32_t video_read_impl(void* handle, uint8_t* out_bgra, size_t capacity,
                        uint32_t* out_width, uint32_t* out_height, int64_t* out_pts_us) {
  auto* d = static_cast<VideoDecoder*>(handle);
  if (d == nullptr || d->output == nullptr || out_bgra == nullptr) return -1;
  @autoreleasepool {
    CMSampleBufferRef sample = [d->output copyNextSampleBuffer];
    if (sample == nullptr) {
      return d->reader.status == AVAssetReaderStatusCompleted ? 1 : -1;
    }
    if (out_pts_us) {
      const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
      *out_pts_us = CMTIME_IS_VALID(pts) ? (int64_t)(CMTimeGetSeconds(pts) * 1000000.0) : -1;
    }
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (image == nullptr) {
      CFRelease(sample);
      return -1;
    }
    CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    const size_t width = CVPixelBufferGetWidth(image);
    const size_t height = CVPixelBufferGetHeight(image);
    const size_t stride = CVPixelBufferGetBytesPerRow(image);
    const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(image);
    int32_t status = 0;
    if (capacity < width * height * 4 || base == nullptr) {
      status = -1;
    } else {
      for (size_t y = 0; y < height; y++) {
        memcpy(out_bgra + y * width * 4, base + y * stride, width * 4);
      }
      if (out_width) *out_width = (uint32_t)width;
      if (out_height) *out_height = (uint32_t)height;
    }
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    CFRelease(sample);
    return status;
  }
}

int32_t video_reset_impl(void* handle) {
  auto* d = static_cast<VideoDecoder*>(handle);
  if (d == nullptr) return -1;
  @autoreleasepool {
    return startReader(d) ? 0 : -1;
  }
}

// Rebuilds the reader from the requested time. Out of range is refused rather
// than clamped: a clamped seek returns the wrong frame and a scrubber cannot tell.
int32_t video_seek_impl(void* handle, int64_t target_us) {
  auto* d = static_cast<VideoDecoder*>(handle);
  if (d == nullptr || target_us < 0) return -1;
  if (d->duration_us > 0 && target_us > d->duration_us) return -1;
  @autoreleasepool {
    return startReaderAt(d, target_us) ? 0 : -1;
  }
}

int64_t video_duration_impl(void* handle) {
  auto* d = static_cast<VideoDecoder*>(handle);
  return d == nullptr ? 0 : d->duration_us;
}

void video_close_impl(void* handle) {
  auto* d = static_cast<VideoDecoder*>(handle);
  if (d == nullptr) return;
  @autoreleasepool {
    if (d->reader) [d->reader cancelReading];
  }
  delete d;
}

// The boundary proof's throw site: mode 0 raises an NSException, mode 1
// throws a C++ exception. Reached only by the guard test.
int32_t media_boundary_probe_impl(uint32_t mode) {
  if (mode == 0) {
    [NSException raise:@"GossBoundaryProbe" format:@"deliberate objc raise"];
  }
  if (mode == 1) {
    throw std::bad_alloc();
  }
  return 0;
}

}  // namespace

extern "C" void* goss_video_open(const uint8_t* path, size_t path_len,
                                 uint32_t* out_width, uint32_t* out_height) {
  GOSS_SHIM_GUARD(void*, nullptr, video_open_impl(path, path_len, out_width, out_height))
}

// Copies the next decoded frame's BGRA pixels into the caller's buffer.
// Returns 0 on a frame, 1 at end of stream (caller loops via reset), -1
// on error.
extern "C" int32_t goss_video_read(void* handle, uint8_t* out_bgra, size_t capacity,
                                   uint32_t* out_width, uint32_t* out_height,
                                   int64_t* out_pts_us) {
  GOSS_SHIM_GUARD(int32_t, -1, video_read_impl(handle, out_bgra, capacity, out_width, out_height, out_pts_us))
}

extern "C" int32_t goss_video_seek(void* handle, int64_t target_us) {
  GOSS_SHIM_GUARD(int32_t, -1, video_seek_impl(handle, target_us))
}

extern "C" int64_t goss_video_duration(void* handle) {
  GOSS_SHIM_GUARD(int64_t, 0, video_duration_impl(handle))
}

extern "C" int32_t goss_video_reset(void* handle) {
  GOSS_SHIM_GUARD(int32_t, -1, video_reset_impl(handle))
}

extern "C" void goss_video_close(void* handle) {
  GOSS_SHIM_GUARD(void, (void)0, video_close_impl(handle))
}

// Proves a throw behind this boundary surfaces as a status, never a
// crash: -1 for either exception flavor, 0 when nothing throws.
extern "C" int32_t goss_media_boundary_probe(uint32_t mode) {
  GOSS_SHIM_GUARD(int32_t, -1, media_boundary_probe_impl(mode))
}
