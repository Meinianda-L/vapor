// VaporBoost: Metal present-interception layer for games running under Wine.
//
// Injected with DYLD_INSERT_LIBRARIES. Every graphics backend Vapor uses
// (D3DMetal, DXMT, DXVK+MoltenVK) ends in CAMetalLayer, so hooking the layer and
// the command-buffer present path covers all of them without touching their code.
//
// The game renders into an off-screen texture at its own resolution. At present
// time VaporBoost encodes, into the game's command buffer:
//   1. optical flow (motion vectors from colour only, for games without MV)
//   2. MetalFX frame interpolation (one generated frame between real frames)
//   3. MetalFX spatial upscaling to the layer's native pixel size
// and then presents the generated frame followed by the real frame.
//
// Environment:
//   VAPOR_BOOST          off | upscale | framegen | upscale,framegen   (default off)
//   VAPOR_BOOST_OUTPUT   WxH  force output size (testing)
//   VAPOR_BOOST_STATS    path  write JSON counters at exit
//   VAPOR_BOOST_CAPTURE  dir   dump output frames as raw BGRA (testing)
//   VAPOR_BOOST_CAPTURE_FRAMES  comma list of app frame indices to dump
//   VAPOR_BOOST_MV_SIGN  1 | -1  motion-vector sign convention (default 1)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdatomic.h>

enum { VBUpscale = 1, VBFramegen = 2 };

static int gMode;
static CGSize gForcedOutput;
static NSString *gCaptureDir;
static NSSet<NSNumber *> *gCaptureFrames;
static float gMVSign = 1;

static atomic_long gAppPresents, gRealPresents, gGeneratedPresents, gUpscaledPresents, gPassthrough;
static NSMutableArray<NSString *> *gErrors;
static NSString *gSizes = @"";

static void vb_log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "[VaporBoost] %s\n", s.UTF8String);
}

static void vb_error(NSString *msg) {
    @synchronized (gErrors) {
        if (gErrors.count < 32) [gErrors addObject:msg];
    }
    vb_log(@"error: %@", msg);
}

#pragma mark - Shaders

static NSString *const kFlowSource = @
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"kernel void luma_down4(texture2d<float, access::read> src [[texture(0)]],\n"
"                       texture2d<float, access::write> dst [[texture(1)]],\n"
"                       uint2 gid [[thread_position_in_grid]]) {\n"
"    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;\n"
"    uint2 lim = uint2(src.get_width() - 1, src.get_height() - 1);\n"
"    float acc = 0;\n"
"    for (uint y = 0; y < 4; y++) for (uint x = 0; x < 4; x++)\n"
"        acc += dot(src.read(min(gid * 4 + uint2(x, y), lim)).rgb, float3(0.299, 0.587, 0.114));\n"
"    dst.write(float4(acc / 16), gid);\n"
"}\n"
// 8x8 block SAD search (+-6 px at quarter res = +-24 px full res); output in full-res pixels.
"kernel void block_match(texture2d<float, access::read> cur [[texture(0)]],\n"
"                        texture2d<float, access::read> prev [[texture(1)]],\n"
"                        texture2d<float, access::write> motion [[texture(2)]],\n"
"                        constant float &sign [[buffer(0)]],\n"
"                        uint2 gid [[thread_position_in_grid]]) {\n"
"    if (gid.x >= motion.get_width() || gid.y >= motion.get_height()) return;\n"
"    int2 base = int2(gid) * 8;\n"
"    int2 size = int2(cur.get_width(), cur.get_height());\n"
"    float best = 1e9; int2 bestOff = 0;\n"
"    for (int dy = -6; dy <= 6; dy++) for (int dx = -6; dx <= 6; dx++) {\n"
"        float sad = 0;\n"
"        for (int y = 0; y < 8; y += 2) for (int x = 0; x < 8; x += 2) {\n"
"            int2 c = clamp(base + int2(x, y), int2(0), size - 1);\n"
"            int2 q = clamp(c + int2(dx, dy), int2(0), size - 1);\n"
"            sad += abs(cur.read(uint2(c)).r - prev.read(uint2(q)).r);\n"
"        }\n"
"        sad += 0.0005 * float(abs(dx) + abs(dy));\n"   // prefer small motion on ties
"        if (sad < best) { best = sad; bestOff = int2(dx, dy); }\n"
"    }\n"
"    motion.write(float4(float2(bestOff) * 4.0 * sign, 0, 0), gid);\n"
"}\n"
"kernel void upsample_motion(texture2d<float, access::read> lo [[texture(0)]],\n"
"                            texture2d<float, access::write> hi [[texture(1)]],\n"
"                            uint2 gid [[thread_position_in_grid]]) {\n"
"    if (gid.x >= hi.get_width() || gid.y >= hi.get_height()) return;\n"
"    uint2 l = min(gid / 32, uint2(lo.get_width() - 1, lo.get_height() - 1));\n"
"    hi.write(lo.read(l), gid);\n"
"}\n";

#pragma mark - Per-layer state

@interface VBState : NSObject
@property (nonatomic) CGSize appSize;          // what the game asked for
@property (nonatomic) BOOL appSizeSet;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;   // for direct -present calls
@property (nonatomic) MTLPixelFormat format;
@property (nonatomic) CGSize builtApp, builtOut;
@property (nonatomic, strong) NSArray<id<MTLTexture>> *ring;
@property (nonatomic) NSUInteger ringIndex;
@property (nonatomic, strong) id<MTLTexture> prev, generated;
@property (nonatomic) BOOL hasPrev;
@property (nonatomic, strong) id<MTLFXSpatialScaler> scaler;
@property (nonatomic, strong) id<MTLFXFrameInterpolator> interpolator;
@property (nonatomic, strong) id<MTLTexture> lumaCur, lumaPrev, mvLo, mvHi, depth;
@property (nonatomic, strong) id<MTLComputePipelineState> downPSO, matchPSO, upPSO;
@property (nonatomic) BOOL depthCleared;
@property (nonatomic) CFTimeInterval lastPresent, frameInterval;
@property (nonatomic) long frameIndex;
@end
@implementation VBState
@end

static const void *kStateKey = &kStateKey;

static VBState *vb_state(CAMetalLayer *layer) {
    VBState *s = objc_getAssociatedObject(layer, kStateKey);
    if (!s) {
        s = [VBState new];
        objc_setAssociatedObject(layer, kStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

static CGSize vb_output_size(CAMetalLayer *layer, CGSize app) {
    if (gForcedOutput.width > 0) return gForcedOutput;
    CGFloat scale = layer.contentsScale > 0 ? layer.contentsScale : 1;
    CGSize out = CGSizeMake(round(layer.bounds.size.width * scale), round(layer.bounds.size.height * scale));
    return (out.width > 0 && out.height > 0) ? out : app;
}

static BOOL vb_upscale_active(CGSize app, CGSize out) {
    return (gMode & VBUpscale) && out.width > app.width + 0.5;
}

static id<MTLTexture> vb_texture(id<MTLDevice> dev, NSUInteger w, NSUInteger h, MTLPixelFormat fmt, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
    d.usage = usage;
    d.storageMode = MTLStorageModePrivate;
    return [dev newTextureWithDescriptor:d];
}

// (Re)builds textures and MetalFX objects when sizes or format change.
static BOOL vb_prepare(VBState *s, CAMetalLayer *layer, CGSize app, CGSize out) {
    if (s.ring && CGSizeEqualToSize(s.builtApp, app) && CGSizeEqualToSize(s.builtOut, out) && s.format == layer.pixelFormat)
        return YES;
    id<MTLDevice> dev = layer.device;
    s.device = dev;
    s.queue = s.queue ?: [dev newCommandQueue];
    s.format = layer.pixelFormat;
    NSUInteger aw = (NSUInteger)app.width, ah = (NSUInteger)app.height;
    NSUInteger ow = (NSUInteger)out.width, oh = (NSUInteger)out.height;

    s.scaler = nil;
    if (vb_upscale_active(app, out)) {
        MTLFXSpatialScalerDescriptor *sd = [MTLFXSpatialScalerDescriptor new];
        sd.inputWidth = aw; sd.inputHeight = ah; sd.outputWidth = ow; sd.outputHeight = oh;
        sd.colorTextureFormat = s.format; sd.outputTextureFormat = s.format;
        sd.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        s.scaler = [sd newSpatialScalerWithDevice:dev];
        if (!s.scaler) vb_error([NSString stringWithFormat:@"spatial scaler unsupported for format %lu", (unsigned long)s.format]);
    }

    s.interpolator = nil;
    if (gMode & VBFramegen) {
        MTLFXFrameInterpolatorDescriptor *fd = [MTLFXFrameInterpolatorDescriptor new];
        fd.inputWidth = aw; fd.inputHeight = ah; fd.outputWidth = aw; fd.outputHeight = ah;
        fd.colorTextureFormat = s.format; fd.outputTextureFormat = s.format;
        fd.depthTextureFormat = MTLPixelFormatDepth32Float;
        fd.motionTextureFormat = MTLPixelFormatRG16Float;
        s.interpolator = [fd newFrameInterpolatorWithDevice:dev];
        if (!s.interpolator) vb_error([NSString stringWithFormat:@"frame interpolator unsupported for format %lu", (unsigned long)s.format]);
    }

    MTLTextureUsage colorUsage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    if (s.scaler) colorUsage |= s.scaler.colorTextureUsage;
    if (s.interpolator) colorUsage |= s.interpolator.colorTextureUsage;
    NSMutableArray *ring = [NSMutableArray array];
    for (int i = 0; i < 3; i++) [ring addObject:vb_texture(dev, aw, ah, s.format, colorUsage)];
    s.ring = ring;
    s.ringIndex = 0;
    s.prev = vb_texture(dev, aw, ah, s.format, colorUsage);
    s.hasPrev = NO;

    if (s.interpolator) {
        s.generated = vb_texture(dev, aw, ah, s.format, colorUsage | s.interpolator.outputTextureUsage);
        s.depth = vb_texture(dev, aw, ah, MTLPixelFormatDepth32Float, MTLTextureUsageRenderTarget | s.interpolator.depthTextureUsage);
        s.depthCleared = NO;
        MTLTextureUsage mvUsage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | s.interpolator.motionTextureUsage;
        s.lumaCur = vb_texture(dev, MAX(aw / 4, 1), MAX(ah / 4, 1), MTLPixelFormatR16Float, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
        s.lumaPrev = vb_texture(dev, MAX(aw / 4, 1), MAX(ah / 4, 1), MTLPixelFormatR16Float, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
        s.mvLo = vb_texture(dev, MAX(aw / 32, 1), MAX(ah / 32, 1), MTLPixelFormatRG16Float, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
        s.mvHi = vb_texture(dev, aw, ah, MTLPixelFormatRG16Float, mvUsage);
        if (!s.downPSO) {
            NSError *err = nil;
            id<MTLLibrary> lib = [dev newLibraryWithSource:kFlowSource options:nil error:&err];
            if (!lib) { vb_error([NSString stringWithFormat:@"flow shader: %@", err]); s.interpolator = nil; }
            else {
                s.downPSO = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"luma_down4"] error:&err];
                s.matchPSO = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"block_match"] error:&err];
                s.upPSO = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"upsample_motion"] error:&err];
            }
        }
    }
    s.builtApp = app; s.builtOut = out;
    @synchronized (gErrors) {
        gSizes = [NSString stringWithFormat:@"%.0fx%.0f->%.0fx%.0f fmt=%lu scaler=%d interp=%d",
                  app.width, app.height, out.width, out.height, (unsigned long)s.format, s.scaler != nil, s.interpolator != nil];
    }
    vb_log(@"prepared %@", gSizes);
    return YES;
}

#pragma mark - Drawable proxy

@interface VBDrawable : NSProxy <CAMetalDrawable>
@property (nonatomic, strong) id<CAMetalDrawable> real;
@property (nonatomic, strong) id<MTLTexture> offscreen;
@property (nonatomic, weak) CAMetalLayer *ownerLayer;
@end

static void vb_present(VBDrawable *proxy, id<MTLCommandBuffer> cb, int kind, double value);

@implementation VBDrawable
- (id<MTLTexture>)texture { return self.offscreen; }
- (CAMetalLayer *)layer { return self.ownerLayer; }
- (void)present { vb_present(self, nil, 0, 0); }
- (void)presentAtTime:(CFTimeInterval)t { vb_present(self, nil, 1, t); }
- (void)presentAfterMinimumDuration:(CFTimeInterval)d { vb_present(self, nil, 2, d); }
- (CFTimeInterval)presentedTime { return self.real.presentedTime; }
- (NSUInteger)drawableID { return self.real.drawableID; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)block { [self.real addPresentedHandler:block]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [(NSObject *)self.real methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)inv { [inv invokeWithTarget:self.real]; }
- (BOOL)conformsToProtocol:(Protocol *)p { return [(NSObject *)self.real conformsToProtocol:p]; }
- (BOOL)respondsToSelector:(SEL)sel { return [(NSObject *)self.real respondsToSelector:sel]; }
@end

#pragma mark - Original implementations

static IMP gOrigNextDrawable, gOrigSetDrawableSize, gOrigDrawableSize, gOrigSetFBOnly;
static IMP gOrigPresent, gOrigPresentAt, gOrigPresentAfter;

static id<CAMetalDrawable> vb_real_next(CAMetalLayer *layer) {
    return ((id (*)(id, SEL))gOrigNextDrawable)(layer, @selector(nextDrawable));
}

static void vb_cb_present(id<MTLCommandBuffer> cb, id<CAMetalDrawable> d, int kind, double v) {
    atomic_fetch_add(&gRealPresents, 1);
    switch (kind) {
        case 1: ((void (*)(id, SEL, id, CFTimeInterval))gOrigPresentAt)(cb, @selector(presentDrawable:atTime:), d, v); break;
        case 2: ((void (*)(id, SEL, id, CFTimeInterval))gOrigPresentAfter)(cb, @selector(presentDrawable:afterMinimumDuration:), d, v); break;
        default: ((void (*)(id, SEL, id))gOrigPresent)(cb, @selector(presentDrawable:), d); break;
    }
}

#pragma mark - Capture (testing)

static void vb_capture(id<MTLCommandBuffer> cb, id<MTLTexture> tex, NSString *name) {
    if (!gCaptureDir) return;
    NSUInteger w = tex.width, h = tex.height, bpr = w * 4;
    id<MTLBuffer> buf = [tex.device newBufferWithLength:bpr * h options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
            sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:0
destinationBytesPerRow:bpr destinationBytesPerImage:bpr * h];
    [b endEncoding];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        NSString *path = [gCaptureDir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@_%lux%lu.bgra", name, (unsigned long)w, (unsigned long)h]];
        [[NSData dataWithBytes:buf.contents length:bpr * h] writeToFile:path atomically:YES];
    }];
}

#pragma mark - Core present path

static void vb_copy(id<MTLCommandBuffer> cb, id<MTLTexture> src, id<MTLTexture> dst) {
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:src toTexture:dst];
    [b endEncoding];
}

// Writes `src` (app res) into the real drawable texture, upscaling if active.
static void vb_resolve(VBState *s, id<MTLCommandBuffer> cb, id<MTLTexture> src, id<MTLTexture> dst) {
    if (s.scaler && src.width != dst.width) {
        s.scaler.colorTexture = src;
        s.scaler.outputTexture = dst;
        [s.scaler encodeToCommandBuffer:cb];
        atomic_fetch_add(&gUpscaledPresents, 1);
    } else if (src.width == dst.width && src.height == dst.height) {
        vb_copy(cb, src, dst);
    } else {
        vb_error(@"size mismatch without scaler");
        vb_copy(cb, src, dst);
    }
}

static void vb_dispatch(id<MTLCommandBuffer> cb, id<MTLComputePipelineState> pso, NSArray<id<MTLTexture>> *texs,
                        NSUInteger w, NSUInteger h, const float *sign) {
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:pso];
    for (NSUInteger i = 0; i < texs.count; i++) [e setTexture:texs[i] atIndex:i];
    if (sign) [e setBytes:sign length:sizeof(float) atIndex:0];
    [e dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [e endEncoding];
}

// Generates the in-between frame from s.prev -> cur into s.generated.
static BOOL vb_generate(VBState *s, id<MTLCommandBuffer> cb, id<MTLTexture> cur) {
    if (!s.interpolator || !s.hasPrev) return NO;
    if (!s.depthCleared) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = s.depth;
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.clearDepth = 1.0;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        s.depthCleared = YES;
    }
    NSUInteger qw = s.lumaCur.width, qh = s.lumaCur.height;
    vb_dispatch(cb, s.downPSO, @[cur, s.lumaCur], qw, qh, NULL);
    vb_dispatch(cb, s.downPSO, @[s.prev, s.lumaPrev], qw, qh, NULL);
    vb_dispatch(cb, s.matchPSO, @[s.lumaCur, s.lumaPrev, s.mvLo], s.mvLo.width, s.mvLo.height, &gMVSign);
    vb_dispatch(cb, s.upPSO, @[s.mvLo, s.mvHi], s.mvHi.width, s.mvHi.height, NULL);

    id<MTLFXFrameInterpolator> fi = s.interpolator;
    fi.colorTexture = cur;
    fi.prevColorTexture = s.prev;
    fi.depthTexture = s.depth;
    fi.motionTexture = s.mvHi;
    fi.outputTexture = s.generated;
    fi.motionVectorScaleX = 1; fi.motionVectorScaleY = 1;
    fi.deltaTime = s.frameInterval > 0 ? (float)s.frameInterval : 1.0f / 60;
    fi.fieldOfView = 60; fi.aspectRatio = (float)cur.width / (float)cur.height;
    fi.nearPlane = 0.1f; fi.farPlane = 1000;
    fi.shouldResetHistory = NO;
    [fi encodeToCommandBuffer:cb];
    return YES;
}

static void vb_present_on(VBDrawable *proxy, id<MTLCommandBuffer> cb, int kind, double value) {
    CAMetalLayer *layer = proxy.ownerLayer;
    VBState *s = vb_state(layer);
    long frame = s.frameIndex++;
    atomic_fetch_add(&gAppPresents, 1);

    CFTimeInterval now = CACurrentMediaTime();
    if (s.lastPresent > 0) {
        CFTimeInterval dt = now - s.lastPresent;
        s.frameInterval = s.frameInterval > 0 ? s.frameInterval * 0.9 + dt * 0.1 : dt;
    }
    s.lastPresent = now;

    id<MTLTexture> cur = proxy.offscreen;
    BOOL capture = gCaptureDir && [gCaptureFrames containsObject:@(frame)];

    if (vb_generate(s, cb, cur)) {
        id<CAMetalDrawable> extra = vb_real_next(layer);
        if (extra) {
            vb_resolve(s, cb, s.generated, extra.texture);
            if (capture) vb_capture(cb, extra.texture, [NSString stringWithFormat:@"f%03ld_gen", frame]);
            vb_cb_present(cb, extra, 0, 0);
            atomic_fetch_add(&gGeneratedPresents, 1);
            // Pace the real frame half an interval after the generated one.
            kind = 2; value = s.frameInterval > 0 ? s.frameInterval / 2 : 0;
        }
    }
    vb_resolve(s, cb, cur, proxy.real.texture);
    if (capture) vb_capture(cb, proxy.real.texture, [NSString stringWithFormat:@"f%03ld_real", frame]);
    if (s.interpolator) { vb_copy(cb, cur, s.prev); s.hasPrev = YES; }
    vb_cb_present(cb, proxy.real, kind, value);
}

static void vb_present(VBDrawable *proxy, id<MTLCommandBuffer> cb, int kind, double value) {
    if (cb) { vb_present_on(proxy, cb, kind, value); return; }
    VBState *s = vb_state(proxy.ownerLayer);
    id<MTLCommandBuffer> own = [s.queue commandBuffer];
    vb_present_on(proxy, own, kind, value);
    [own commit];
}

#pragma mark - Hooks: CAMetalLayer

static void hk_setDrawableSize(CAMetalLayer *self, SEL _cmd, CGSize size) {
    VBState *s = vb_state(self);
    s.appSize = size; s.appSizeSet = YES;
    CGSize out = vb_output_size(self, size);
    CGSize real = vb_upscale_active(size, out) ? out : size;
    ((void (*)(id, SEL, CGSize))gOrigSetDrawableSize)(self, _cmd, real);
}

static CGSize hk_drawableSize(CAMetalLayer *self, SEL _cmd) {
    VBState *s = objc_getAssociatedObject(self, kStateKey);
    if (s.appSizeSet) return s.appSize;
    return ((CGSize (*)(id, SEL))gOrigDrawableSize)(self, _cmd);
}

static void hk_setFramebufferOnly(CAMetalLayer *self, SEL _cmd, BOOL v) {
    // Upscaling and frame generation write into the drawable with compute/blit.
    ((void (*)(id, SEL, BOOL))gOrigSetFBOnly)(self, _cmd, gMode ? NO : v);
}

static void vb_hook_command_buffers(id<MTLDevice> dev);

static id hk_nextDrawable(CAMetalLayer *self, SEL _cmd) {
    if (!gMode || !self.device) return vb_real_next(self);
    VBState *s = vb_state(self);
    vb_hook_command_buffers(self.device);
    if (self.framebufferOnly) ((void (*)(id, SEL, BOOL))gOrigSetFBOnly)(self, @selector(setFramebufferOnly:), NO);

    CGSize app = s.appSizeSet ? s.appSize : ((CGSize (*)(id, SEL))gOrigDrawableSize)(self, @selector(drawableSize));
    if (!s.appSizeSet) { s.appSize = app; s.appSizeSet = YES; }
    CGSize out = vb_output_size(self, app);
    if (!vb_upscale_active(app, out)) out = app;
    CGSize realSize = ((CGSize (*)(id, SEL))gOrigDrawableSize)(self, @selector(drawableSize));
    if (!CGSizeEqualToSize(realSize, out)) ((void (*)(id, SEL, CGSize))gOrigSetDrawableSize)(self, @selector(setDrawableSize:), out);

    if (!vb_upscale_active(app, out) && !(gMode & VBFramegen)) {
        atomic_fetch_add(&gPassthrough, 1);
        return vb_real_next(self);
    }
    vb_prepare(s, self, app, out);
    id<CAMetalDrawable> real = vb_real_next(self);
    if (!real) return nil;
    VBDrawable *proxy = [VBDrawable alloc];
    proxy.real = real;
    proxy.ownerLayer = self;
    proxy.offscreen = s.ring[s.ringIndex];
    s.ringIndex = (s.ringIndex + 1) % s.ring.count;
    return proxy;
}

#pragma mark - Hooks: MTLCommandBuffer present

static void hk_present(id self, SEL _cmd, id d) {
    if (object_getClass(d) == [VBDrawable class]) { vb_present(d, self, 0, 0); return; }
    vb_cb_present(self, d, 0, 0);
}
static void hk_presentAt(id self, SEL _cmd, id d, CFTimeInterval t) {
    if (object_getClass(d) == [VBDrawable class]) { vb_present(d, self, 1, t); return; }
    vb_cb_present(self, d, 1, t);
}
static void hk_presentAfter(id self, SEL _cmd, id d, CFTimeInterval t) {
    if (object_getClass(d) == [VBDrawable class]) { vb_present(d, self, 2, t); return; }
    vb_cb_present(self, d, 2, t);
}

static NSMutableSet<Class> *gHookedCB;

static void vb_hook_class(Class c) {
    @synchronized (gHookedCB) {
        if ([gHookedCB containsObject:c]) return;
        [gHookedCB addObject:c];
    }
    struct { SEL sel; IMP hook; IMP *orig; } hooks[] = {
        { @selector(presentDrawable:), (IMP)hk_present, &gOrigPresent },
        { @selector(presentDrawable:atTime:), (IMP)hk_presentAt, &gOrigPresentAt },
        { @selector(presentDrawable:afterMinimumDuration:), (IMP)hk_presentAfter, &gOrigPresentAfter },
    };
    for (size_t i = 0; i < sizeof hooks / sizeof hooks[0]; i++) {
        Method m = class_getInstanceMethod(c, hooks[i].sel);
        if (!m) continue;
        IMP prev = class_replaceMethod(c, hooks[i].sel, hooks[i].hook, method_getTypeEncoding(m));
        if (!*hooks[i].orig) *hooks[i].orig = prev ?: method_getImplementation(m);
    }
    vb_log(@"hooked command buffer class %s", class_getName(c));
}

static void vb_hook_command_buffers(id<MTLDevice> dev) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLCommandQueue> q = [dev newCommandQueue];
        vb_hook_class(object_getClass([q commandBuffer]));
        vb_hook_class(object_getClass([q commandBufferWithUnretainedReferences]));
    });
}

#pragma mark - Setup

static void vb_write_stats(void) {
    NSString *path = NSProcessInfo.processInfo.environment[@"VAPOR_BOOST_STATS"];
    if (!path) return;
    NSDictionary *stats = @{
        @"mode": @(gMode),
        @"appPresents": @(atomic_load(&gAppPresents)),
        @"realPresents": @(atomic_load(&gRealPresents)),
        @"generatedPresents": @(atomic_load(&gGeneratedPresents)),
        @"upscaledPresents": @(atomic_load(&gUpscaledPresents)),
        @"passthroughDrawables": @(atomic_load(&gPassthrough)),
        @"sizes": gSizes,
        @"errors": gErrors ?: @[],
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:stats options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:path atomically:YES];
}

static void vb_swizzle(Class c, SEL sel, IMP hook, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    *orig = method_getImplementation(m);
    class_replaceMethod(c, sel, hook, method_getTypeEncoding(m));
}

__attribute__((constructor)) static void vb_init(void) {
    @autoreleasepool {
        NSDictionary *env = NSProcessInfo.processInfo.environment;
        NSString *mode = [(NSString *)env[@"VAPOR_BOOST"] lowercaseString] ?: @"off";
        if ([mode containsString:@"upscale"]) gMode |= VBUpscale;
        if ([mode containsString:@"framegen"]) gMode |= VBFramegen;
        gErrors = [NSMutableArray array];
        gHookedCB = [NSMutableSet set];
        NSArray *wh = [env[@"VAPOR_BOOST_OUTPUT"] componentsSeparatedByString:@"x"];
        if (wh.count == 2) gForcedOutput = CGSizeMake([wh[0] doubleValue], [wh[1] doubleValue]);
        gCaptureDir = env[@"VAPOR_BOOST_CAPTURE"];
        NSMutableSet *frames = [NSMutableSet set];
        for (NSString *f in [env[@"VAPOR_BOOST_CAPTURE_FRAMES"] componentsSeparatedByString:@","])
            if (f.length) [frames addObject:@(f.integerValue)];
        gCaptureFrames = frames;
        if (env[@"VAPOR_BOOST_MV_SIGN"]) gMVSign = [env[@"VAPOR_BOOST_MV_SIGN"] floatValue];
        atexit(vb_write_stats);
        if (!gMode) return;

        Class layer = [CAMetalLayer class];
        vb_swizzle(layer, @selector(nextDrawable), (IMP)hk_nextDrawable, &gOrigNextDrawable);
        vb_swizzle(layer, @selector(setDrawableSize:), (IMP)hk_setDrawableSize, &gOrigSetDrawableSize);
        vb_swizzle(layer, @selector(drawableSize), (IMP)hk_drawableSize, &gOrigDrawableSize);
        vb_swizzle(layer, @selector(setFramebufferOnly:), (IMP)hk_setFramebufferOnly, &gOrigSetFBOnly);
        vb_log(@"active: mode=%@", mode);
    }
}
