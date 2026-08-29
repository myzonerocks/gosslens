//! Binding to the inference runtime's C interface. One Engine owns a
//! loaded model, its interpreter, and the cpu delegate; callers feed input
//! tensors and read outputs as plain slices. The model bytes must outlive
//! the engine: the runtime maps them in place rather than copying.

const std = @import("std");
const builtin = @import("builtin");
const ml_delegate = @import("ml_delegate");

pub const Backend = ml_delegate.Backend;

pub const c = @cImport({
    @cInclude("tflite/c/c_api.h");
    @cInclude("tflite/core/c/c_api_opaque.h");
    @cInclude("tflite/delegates/xnnpack/xnnpack_delegate.h");
    @cInclude("tflite/delegates/coreml/coreml_delegate.h");
    @cInclude("tflite/delegates/nnapi/nnapi_delegate_c_api.h");
});

pub const Error = error{
    ModelRejected,
    InterpreterUnavailable,
    AllocationFailed,
    InvokeFailed,
    TensorShapeMismatch,
    TensorMissing,
};

/// A model naming this many distinct custom ops has no real model on
/// this project's roadmap to justify a dynamic list for - every known
/// case (today, just Convolution2DTransposeBias) needs exactly one.
const max_custom_ops = 4;

/// The reporter callback type exactly as the C API declares it on this
/// target, so the va_list parameter keeps the platform's own ABI shape.
const ReporterFn = @typeInfo(@TypeOf(c.TfLiteModelCreateWithErrorReporter)).@"fn".params[2].type.?;
const VaListArg = @typeInfo(std.meta.Child(std.meta.Child(ReporterFn))).@"fn".params[2].type.?;

/// Routes every model and interpreter diagnostic to stderr; without a
/// reporter the runtime discards the vendor's reason for each failure.
fn reportRuntimeError(user_data: ?*anyopaque, format: [*c]const u8, args: VaListArg) callconv(.c) void {
    _ = user_data;
    const libc = struct {
        extern fn vsnprintf(buf: [*c]u8, size: usize, fmt: [*c]const u8, ap: VaListArg) c_int;
    };
    var buf: [512]u8 = undefined;
    const wrote = libc.vsnprintf(&buf, buf.len, format, args);
    const len: usize = if (wrote < 0) 0 else @min(@as(usize, @intCast(wrote)), buf.len - 1);
    std.debug.print("tflite: {s}\n", .{buf[0..len]});
}

/// Creates the delegate for one backend, or null if this target cannot (the
/// accelerator paths compile only where their runtime exists, so a host build
/// never references the Apple or Android delegate symbols).
fn createBackendDelegate(backend: Backend, threads: i32) ?*c.TfLiteDelegate {
    switch (backend) {
        .xnnpack => {
            var options = c.TfLiteXNNPackDelegateOptionsDefault();
            options.num_threads = threads;
            return c.TfLiteXNNPackDelegateCreate(&options);
        },
        .coreml => {
            if (comptime builtin.target.os.tag == .ios or builtin.target.os.tag == .tvos) {
                var options: c.TfLiteCoreMlDelegateOptions = std.mem.zeroes(c.TfLiteCoreMlDelegateOptions);
                options.enabled_devices = c.TfLiteCoreMlDelegateDevicesWithNeuralEngine;
                return c.TfLiteCoreMlDelegateCreate(&options);
            }
            return null;
        },
        .nnapi => {
            if (comptime builtin.target.abi.isAndroid()) {
                var options = c.TfLiteNnapiDelegateOptionsDefault();
                return c.TfLiteNnapiDelegateCreate(&options);
            }
            return null;
        },
    }
}

fn deleteBackendDelegate(backend: Backend, delegate: *c.TfLiteDelegate) void {
    switch (backend) {
        .xnnpack => c.TfLiteXNNPackDelegateDelete(delegate),
        .coreml => if (comptime builtin.target.os.tag == .ios or builtin.target.os.tag == .tvos) c.TfLiteCoreMlDelegateDelete(delegate),
        .nnapi => if (comptime builtin.target.abi.isAndroid()) c.TfLiteNnapiDelegateDelete(delegate),
    }
}

pub const Engine = struct {
    model: *c.TfLiteModel,
    options: *c.TfLiteInterpreterOptions,
    delegate: *c.TfLiteDelegate,
    interpreter: *c.TfLiteInterpreter,
    /// The delegate the scheduler settled on: the platform accelerator when it
    /// built, else the XNNPACK CPU fallback. deinit deletes by this.
    backend: Backend,
    /// Owned custom-op registrations, if any: TfLiteOperator's own docs
    /// require it outlive every interpreter built from the options it
    /// was added to, so the engine that owns the interpreter is exactly
    /// where its lifetime belongs too, not leaked onto every caller.
    custom_ops: [max_custom_ops]?*c.TfLiteOperator = @splat(null),

    /// Threads bound the delegate's worker pool. Camera inference wants a
    /// small fixed pool: enough to hit frame budget, never enough to
    /// starve the render thread.
    pub fn init(model_bytes: []const u8, threads: i32) Error!Engine {
        return initWithCustomOps(model_bytes, threads, &.{});
    }

    /// Like init, but registers every op in `custom_ops` (each a
    /// module's own register(options) -> *TfLiteOperator function)
    /// before the interpreter loads the model - the only way a model
    /// naming an op the stock resolver doesn't know can load at all.
    /// Empty for every model that doesn't need one, which is why init()
    /// stays the plain entry point.
    pub fn initWithCustomOps(model_bytes: []const u8, threads: i32, custom_ops: []const *const fn (*c.TfLiteInterpreterOptions) *c.TfLiteOperator) Error!Engine {
        std.debug.assert(custom_ops.len <= max_custom_ops);
        const model = c.TfLiteModelCreateWithErrorReporter(model_bytes.ptr, model_bytes.len, reportRuntimeError, null) orelse
            return error.ModelRejected;
        errdefer c.TfLiteModelDelete(model);

        // Try the platform accelerator first, then the XNNPACK CPU fallback, so
        // a device runs on its NPU where it can and every target still loads.
        var order_buf: [ml_delegate.max_backends]Backend = undefined;
        const order = ml_delegate.delegateOrderFor(.auto, builtin.target.os.tag, comptime builtin.target.abi.isAndroid(), &order_buf);
        for (order) |backend| {
            if (tryBuild(model, backend, threads, custom_ops)) |built| return built;
        }
        return error.InterpreterUnavailable;
    }

    /// Builds an interpreter for one backend, cleaning up and returning null if
    /// any step fails so the caller can try the next backend. The model outlives
    /// every attempt; only the per-attempt options, delegate, and interpreter
    /// are torn down on failure.
    fn tryBuild(model: *c.TfLiteModel, backend: Backend, threads: i32, custom_ops: []const *const fn (*c.TfLiteInterpreterOptions) *c.TfLiteOperator) ?Engine {
        const options = c.TfLiteInterpreterOptionsCreate() orelse return null;
        var built = false;
        defer if (!built) c.TfLiteInterpreterOptionsDelete(options);
        c.TfLiteInterpreterOptionsSetErrorReporter(options, reportRuntimeError, null);
        c.TfLiteInterpreterOptionsSetNumThreads(options, threads);

        var registered: [max_custom_ops]?*c.TfLiteOperator = @splat(null);
        defer if (!built) for (registered) |maybe_op| {
            if (maybe_op) |op| c.TfLiteOperatorDelete(op);
        };
        for (custom_ops, 0..) |register, i| registered[i] = register(options);

        const delegate = createBackendDelegate(backend, threads) orelse return null;
        defer if (!built) deleteBackendDelegate(backend, delegate);
        c.TfLiteInterpreterOptionsAddDelegate(options, delegate);

        const interpreter = c.TfLiteInterpreterCreate(model, options) orelse return null;
        defer if (!built) c.TfLiteInterpreterDelete(interpreter);
        if (c.TfLiteInterpreterAllocateTensors(interpreter) != c.kTfLiteOk) return null;

        built = true;
        return .{ .model = model, .options = options, .delegate = delegate, .interpreter = interpreter, .backend = backend, .custom_ops = registered };
    }

    pub fn deinit(engine: *Engine) void {
        c.TfLiteInterpreterDelete(engine.interpreter);
        c.TfLiteInterpreterOptionsDelete(engine.options);
        deleteBackendDelegate(engine.backend, engine.delegate);
        c.TfLiteModelDelete(engine.model);
        for (engine.custom_ops) |maybe_op| {
            if (maybe_op) |op| c.TfLiteOperatorDelete(op);
        }
        engine.* = undefined;
    }

    /// The delegate this engine runs on, so a caller can confirm the scheduler
    /// took the accelerator or the CPU fallback.
    pub fn activeBackend(engine: *const Engine) Backend {
        return engine.backend;
    }

    pub fn inputCount(engine: *const Engine) usize {
        return @intCast(c.TfLiteInterpreterGetInputTensorCount(engine.interpreter));
    }

    pub fn outputCount(engine: *const Engine) usize {
        return @intCast(c.TfLiteInterpreterGetOutputTensorCount(engine.interpreter));
    }

    /// Writes one input tensor. The slice length must match the tensor's
    /// byte size exactly; a mismatch means the caller's preprocessing and
    /// the model disagree, which must fail loudly rather than truncate.
    pub fn writeInput(engine: *Engine, index: usize, bytes: []const u8) Error!void {
        const tensor = c.TfLiteInterpreterGetInputTensor(engine.interpreter, @intCast(index)) orelse
            return error.TensorMissing;
        if (c.TfLiteTensorByteSize(tensor) != bytes.len) return error.TensorShapeMismatch;
        if (c.TfLiteTensorCopyFromBuffer(tensor, bytes.ptr, bytes.len) != c.kTfLiteOk) {
            return error.TensorShapeMismatch;
        }
    }

    pub fn invoke(engine: *Engine) Error!void {
        if (c.TfLiteInterpreterInvoke(engine.interpreter) != c.kTfLiteOk) {
            return error.InvokeFailed;
        }
    }

    /// Reads one output tensor as raw bytes, valid until the next invoke.
    pub fn output(engine: *const Engine, index: usize) Error![]const u8 {
        const tensor = c.TfLiteInterpreterGetOutputTensor(engine.interpreter, @intCast(index)) orelse
            return error.TensorMissing;
        const data = c.TfLiteTensorData(tensor) orelse return error.TensorMissing;
        return @as([*]const u8, @ptrCast(data))[0..c.TfLiteTensorByteSize(tensor)];
    }

    /// Reads one output tensor as floats. Camera models emit float32
    /// landmarks and scores; a different element type is a wiring defect.
    pub fn outputFloats(engine: *const Engine, index: usize) Error![]const f32 {
        const tensor = c.TfLiteInterpreterGetOutputTensor(engine.interpreter, @intCast(index)) orelse
            return error.TensorMissing;
        if (c.TfLiteTensorType(tensor) != c.kTfLiteFloat32) return error.TensorShapeMismatch;
        const data = c.TfLiteTensorData(tensor) orelse return error.TensorMissing;
        const count = c.TfLiteTensorByteSize(tensor) / @sizeOf(f32);
        return @as([*]const f32, @alignCast(@ptrCast(data)))[0..count];
    }

    pub fn outputDims(engine: *const Engine, index: usize, dims: []i32) Error![]i32 {
        const tensor = c.TfLiteInterpreterGetOutputTensor(engine.interpreter, @intCast(index)) orelse
            return error.TensorMissing;
        const count: usize = @intCast(c.TfLiteTensorNumDims(tensor));
        if (count > dims.len) return error.TensorShapeMismatch;
        for (dims[0..count], 0..) |*dim, at| {
            dim.* = c.TfLiteTensorDim(tensor, @intCast(at));
        }
        return dims[0..count];
    }

    pub fn inputDims(engine: *const Engine, index: usize, dims: []i32) Error![]i32 {
        const tensor = c.TfLiteInterpreterGetInputTensor(engine.interpreter, @intCast(index)) orelse
            return error.TensorMissing;
        const count: usize = @intCast(c.TfLiteTensorNumDims(tensor));
        if (count > dims.len) return error.TensorShapeMismatch;
        for (dims[0..count], 0..) |*dim, at| {
            dim.* = c.TfLiteTensorDim(tensor, @intCast(at));
        }
        return dims[0..count];
    }
};
