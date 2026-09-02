//! The TFLite backend on targets without the compiled inference runtime
//! (the web): loading refuses, so ml_engine routes every model to the
//! self-contained ONNX engine and a TFLite file degrades to an inert node.

pub const Error = error{ModelRejected};

pub const Engine = struct {
    pub fn init(model_bytes: []const u8, threads: i32) Error!Engine {
        _ = model_bytes;
        _ = threads;
        return error.ModelRejected;
    }

    pub fn deinit(self: *Engine) void {
        _ = self;
    }

    pub fn inputCount(self: *const Engine) usize {
        _ = self;
        return 0;
    }

    pub fn outputCount(self: *const Engine) usize {
        _ = self;
        return 0;
    }

    pub fn inputDims(self: *const Engine, index: usize, dims: []i32) anyerror![]i32 {
        _ = self;
        _ = index;
        _ = dims;
        return error.ModelRejected;
    }

    pub fn outputDims(self: *const Engine, index: usize, dims: []i32) anyerror![]i32 {
        _ = self;
        _ = index;
        _ = dims;
        return error.ModelRejected;
    }

    pub fn writeInput(self: *Engine, index: usize, bytes: []const u8) anyerror!void {
        _ = self;
        _ = index;
        _ = bytes;
        return error.ModelRejected;
    }

    pub fn invoke(self: *Engine) anyerror!void {
        _ = self;
        return error.ModelRejected;
    }

    pub fn outputFloats(self: *const Engine, index: usize) anyerror![]const f32 {
        _ = self;
        _ = index;
        return error.ModelRejected;
    }
};
