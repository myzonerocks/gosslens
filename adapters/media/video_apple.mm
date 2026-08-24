// Video decode on Apple platforms: AVAssetReader streams a track's
// frames off the hardware decoder one sample buffer at a time, so a
// live texture pulls the next in O(1). Looping recreates the reader,
// the only way AVAssetReader rewinds. No vendor type escapes.

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace {

struct VideoDecoder {
  AVURLAsset* asset = nil;
  AVAssetTrack* track = nil;
  AVAssetReader* reader = nil;
  AVAssetReaderTrackOutput* output = nil;
  uint32_t width = 0;
  uint32_t height = 0;
};

// A fresh reader over the retained track, positioned at the start. The
// prior reader, if any, is cancelled first. AVAssetReader is
// forward-only, so this is both the initial start and the loop rewind.
bool startReader(VideoDecoder* d) {
  if (d->reader) {
    [d->reader cancelReading];
    d->reader = nil;
    d->output = nil;
  }
  NSError* error = nil;
  AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:d->asset error:&error];
  if (reader == nil || error != nil) return false;
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

}  // namespace

extern "C" void* goss_video_open(const uint8_t* path, size_t path_len,
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

    auto* d = new VideoDecoder();
    d->asset = asset;
    d->track = tracks.firstObject;
    d->width = (uint32_t)d->track.naturalSize.width;
    d->height = (uint32_t)d->track.naturalSize.height;
    if (!startReader(d)) {
      delete d;
      return nullptr;
    }
    if (out_width) *out_width = d->width;
    if (out_height) *out_height = d->height;
    return d;
  }
}

// Copies the next decoded frame's BGRA pixels into the caller's buffer.
// Returns 0 on a frame, 1 at end of stream (caller loops via reset), -1
// on error.
extern "C" int32_t goss_video_read(void* handle, uint8_t* out_bgra, size_t capacity,
                                   uint32_t* out_width, uint32_t* out_height) {
  auto* d = static_cast<VideoDecoder*>(handle);
  if (d == nullptr || d->output == nullptr || out_bgra == nullptr) return -1;
  @autoreleasepool {
    CMSampleBufferRef sample = [d->output copyNextSampleBuffer];
    if (sample == nullptr) {
      return d->reader.status == AVAssetReaderStatusCompleted ? 1 : -1;
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

extern "C" int32_t goss_video_reset(void* handle) {
  auto* d = static_cast<VideoDecoder*>(handle);
  if (d == nullptr) return -1;
  @autoreleasepool {
    return startReader(d) ? 0 : -1;
  }
}

extern "C" void goss_video_close(void* handle) {
  auto* d = static_cast<VideoDecoder*>(handle);
  if (d == nullptr) return;
  @autoreleasepool {
    if (d->reader) [d->reader cancelReading];
  }
  delete d;
}
