// ScreenCaptureKit behind the screen-capture boundary. Every entry point catches
// at the boundary and returns a status, because an NSException crossing into Zig
// is an unwind Zig has no frame for.
//
// ScreenCaptureKit is asynchronous by design: it hands frames to a delegate. A
// latest-wins mailbox turns that into the pull the seam wants, so a caller reads
// the newest frame rather than queueing behind a stream it cannot drain.

#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <stdint.h>
#include <string.h>

namespace {

constexpr size_t kMaxTitleBytes = 128;

struct CSurface {
    uint64_t id;
    uint32_t kind;
    float logical_width;
    float logical_height;
    float origin_x;
    float origin_y;
    float scale;
    uint32_t title_len;
    uint8_t title[kMaxTitleBytes];
};

void copyTitle(CSurface *out, NSString *title) {
    out->title_len = 0;
    if (title == nil) return;
    const char *utf8 = [title UTF8String];
    if (utf8 == nullptr) return;
    size_t len = strnlen(utf8, kMaxTitleBytes);
    memcpy(out->title, utf8, len);
    out->title_len = (uint32_t)len;
}

}  // namespace

/// The delegate keeps one frame: the newest. A screen is static most of the time,
/// so `fresh` is what lets a reader answer "nothing changed" without a copy.
@interface GossScreenSink : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, assign) CVPixelBufferRef latest;
@property(nonatomic, assign) int64_t timestamp_us;
@property(nonatomic, assign) BOOL fresh;
@property(nonatomic, assign) BOOL failed;
@property(nonatomic, strong) NSLock *lock;
@end

@implementation GossScreenSink

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _latest = NULL;
        _fresh = NO;
        _failed = NO;
    }
    return self;
}

- (void)dealloc {
    if (_latest) CVPixelBufferRelease(_latest);
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    if (!CMSampleBufferIsValid(sampleBuffer)) return;
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (buffer == NULL) return;

    CVPixelBufferRetain(buffer);
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    [self.lock lock];
    // Latest wins: the previous frame is released rather than queued, so a slow
    // reader falls behind by one frame instead of by a growing backlog.
    if (self.latest) CVPixelBufferRelease(self.latest);
    self.latest = buffer;
    self.timestamp_us = CMTIME_IS_VALID(pts) ? (int64_t)(CMTimeGetSeconds(pts) * 1e6) : 0;
    self.fresh = YES;
    [self.lock unlock];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    [self.lock lock];
    self.failed = YES;
    [self.lock unlock];
}

@end

namespace {

struct Capture {
    SCStream *stream;
    GossScreenSink *sink;
    uint32_t width;
    uint32_t height;
};

/// The shareable content, fetched synchronously. ScreenCaptureKit only offers the
/// async form, and the seam is a pull, so the wait is bounded and a timeout reads
/// as "nothing to capture" rather than hanging a frame.
SCShareableContent *shareableContent(void) {
    __block SCShareableContent *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                              onScreenWindowsOnly:YES
                                completionHandler:^(SCShareableContent *content, NSError *error) {
        if (error == nil) result = content;
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    return result;
}

}  // namespace

extern "C" int32_t goss_screen_enumerate(CSurface *out, size_t capacity, uint32_t *out_count) {
    if (out == nullptr || out_count == nullptr) return -1;
    *out_count = 0;
    @try {
        @autoreleasepool {
            SCShareableContent *content = shareableContent();
            // No permission and no content read the same way on purpose: a host
            // sees nothing to capture and prompts, rather than reading an error
            // it cannot act on.
            if (content == nil) return 0;

            size_t written = 0;
            for (SCDisplay *display in content.displays) {
                if (written >= capacity) break;
                CSurface *entry = &out[written];
                memset(entry, 0, sizeof(*entry));
                entry->id = (uint64_t)display.displayID;
                entry->kind = 0;
                entry->logical_width = (float)display.frame.size.width;
                entry->logical_height = (float)display.frame.size.height;
                entry->origin_x = (float)display.frame.origin.x;
                entry->origin_y = (float)display.frame.origin.y;
                // The backing scale, from the pixel width the display reports
                // against the logical width above.
                entry->scale = display.frame.size.width > 0
                    ? (float)(display.width / display.frame.size.width)
                    : 1.0f;
                copyTitle(entry, [NSString stringWithFormat:@"Display %u", (unsigned)display.displayID]);
                written += 1;
            }
            for (SCWindow *window in content.windows) {
                if (written >= capacity) break;
                if (window.frame.size.width < 1 || window.frame.size.height < 1) continue;
                CSurface *entry = &out[written];
                memset(entry, 0, sizeof(*entry));
                entry->id = (uint64_t)window.windowID;
                entry->kind = 1;
                entry->logical_width = (float)window.frame.size.width;
                entry->logical_height = (float)window.frame.size.height;
                entry->origin_x = (float)window.frame.origin.x;
                entry->origin_y = (float)window.frame.origin.y;
                entry->scale = 1.0f;
                NSString *title = window.title.length > 0 ? window.title : window.owningApplication.applicationName;
                copyTitle(entry, title);
                written += 1;
            }
            *out_count = (uint32_t)written;
            return 0;
        }
    } @catch (NSException *e) {
        return -1;
    }
}

extern "C" void *goss_screen_open(uint64_t id, float scale, uint32_t *out_width, uint32_t *out_height) {
    if (out_width == nullptr || out_height == nullptr) return nullptr;
    @try {
        @autoreleasepool {
            SCShareableContent *content = shareableContent();
            if (content == nil) return nullptr;

            SCContentFilter *filter = nil;
            float logical_w = 0;
            float logical_h = 0;
            float native_scale = 1;

            for (SCDisplay *display in content.displays) {
                if ((uint64_t)display.displayID != id) continue;
                filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
                logical_w = (float)display.frame.size.width;
                logical_h = (float)display.frame.size.height;
                native_scale = logical_w > 0 ? (float)(display.width / display.frame.size.width) : 1.0f;
                break;
            }
            if (filter == nil) {
                for (SCWindow *window in content.windows) {
                    if ((uint64_t)window.windowID != id) continue;
                    filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
                    logical_w = (float)window.frame.size.width;
                    logical_h = (float)window.frame.size.height;
                    break;
                }
            }
            if (filter == nil) return nullptr;

            const float used_scale = scale > 0 ? scale : native_scale;
            uint32_t width = (uint32_t)(logical_w * used_scale);
            uint32_t height = (uint32_t)(logical_h * used_scale);
            if (width == 0 || height == 0) return nullptr;

            SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
            config.width = width;
            config.height = height;
            // BGRA, the order every screen API vends and the one the renderer
            // uploads without a per-pixel swap.
            config.pixelFormat = kCVPixelFormatType_32BGRA;
            config.showsCursor = YES;
            config.queueDepth = 3;

            GossScreenSink *sink = [[GossScreenSink alloc] init];
            NSError *error = nil;
            SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:sink];
            if (stream == nil) return nullptr;
            if (![stream addStreamOutput:sink
                                    type:SCStreamOutputTypeScreen
                      sampleHandlerQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)
                                   error:&error]) {
                return nullptr;
            }

            __block BOOL started = NO;
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [stream startCaptureWithCompletionHandler:^(NSError *start_error) {
                started = (start_error == nil);
                dispatch_semaphore_signal(done);
            }];
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
            if (!started) return nullptr;

            Capture *capture = new Capture{stream, sink, width, height};
            // Retained by hand: the stream and the sink outlive this autorelease
            // pool and are released in close.
            CFRetain((CFTypeRef)stream);
            CFRetain((CFTypeRef)sink);
            *out_width = width;
            *out_height = height;
            return capture;
        }
    } @catch (NSException *e) {
        return nullptr;
    }
}

extern "C" int32_t goss_screen_read(void *handle, uint8_t *out_bgra, size_t capacity,
                                    uint32_t *out_width, uint32_t *out_height,
                                    int64_t *out_timestamp_us) {
    if (handle == nullptr || out_bgra == nullptr) return -1;
    Capture *capture = (Capture *)handle;
    @try {
        @autoreleasepool {
            GossScreenSink *sink = capture->sink;
            [sink.lock lock];
            if (sink.failed) {
                [sink.lock unlock];
                return -1;
            }
            // A screen that has not changed is its own answer, so a still desktop
            // costs no copy at all.
            if (!sink.fresh || sink.latest == NULL) {
                [sink.lock unlock];
                return 1;
            }
            CVPixelBufferRef buffer = sink.latest;
            CVPixelBufferRetain(buffer);
            int64_t timestamp = sink.timestamp_us;
            sink.fresh = NO;
            [sink.lock unlock];

            CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
            const size_t width = CVPixelBufferGetWidth(buffer);
            const size_t height = CVPixelBufferGetHeight(buffer);
            const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
            const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(buffer);
            int32_t status = 0;
            if (base == nullptr || capacity < width * height * 4) {
                status = -1;
            } else {
                // Row by row: the surface's stride is its own and almost never the
                // tight width, so a single memcpy would shear the image.
                for (size_t y = 0; y < height; y += 1) {
                    memcpy(out_bgra + y * width * 4, base + y * stride, width * 4);
                }
                if (out_width) *out_width = (uint32_t)width;
                if (out_height) *out_height = (uint32_t)height;
                if (out_timestamp_us) *out_timestamp_us = timestamp;
            }
            CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
            CVPixelBufferRelease(buffer);
            return status;
        }
    } @catch (NSException *e) {
        return -1;
    }
}

extern "C" void goss_screen_close(void *handle) {
    if (handle == nullptr) return;
    Capture *capture = (Capture *)handle;
    @try {
        @autoreleasepool {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [capture->stream stopCaptureWithCompletionHandler:^(NSError *error) {
                dispatch_semaphore_signal(done);
            }];
            dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            CFRelease((CFTypeRef)capture->stream);
            CFRelease((CFTypeRef)capture->sink);
        }
    } @catch (NSException *e) {
        // Nothing to do but release the rest: a throw here must not leak the
        // allocation below.
    }
    delete capture;
}
