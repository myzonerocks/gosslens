//! Source-tracked gate. Enforces both directions of the repository's ignore
//! policy plus commit provenance, locally (git hooks) and in CI.
//!
//!   --staged            pre-commit: staged files through every check
//!   --tree              CI/local: all tracked files through every check
//!   --commit-msg <file> commit-msg hook: scan the message being written
//!   --log <range>       CI: scan commit messages in a rev range
//!   --diff <range>      CI: scan added lines in a rev range for comment hygiene
//!   --pr-body <file>    CI: scan a PR body for provenance and shape
//!
//! Direction one, outbound: no layer of ignore (repo, .git/info/exclude, or a
//! contributor's global file) may hide source this repository owns. Every
//! owned top-level tree must carry a `!tree/**` re-include in .gitignore, and
//! any file that is ignored must be ignored by this repository's own
//! .gitignore, never by a personal layer.
//!
//! Direction two, inbound: private docs, vendored trees, model weights, build
//! outputs, archives, and oversized binaries never enter history. History is
//! forever; the repository being private today proves nothing about tomorrow.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const max_file_scan_bytes: usize = 1 << 20;
const max_staged_file_bytes: u64 = 4 << 20;

// Trees whose contents must never be committed. Anything staged under these
// prefixes was force-added past the ignore file.
const forbidden_prefixes = [_][]const u8{
    "docs/private/",
    ".models/",
    ".vendor/",
    ".vendor-archives/",
    "zig-out/",
    ".zig-cache/",
    ".local/",
};

// Path segments that only ever appear inside build detritus.
const forbidden_segments = [_][]const u8{
    "node_modules",
    "DerivedData",
    ".gradle",
    ".build",
};

// Artifact classes that are fetched or built, never tracked.
const forbidden_extensions = [_][]const u8{
    ".task", ".gguf",   ".tflite", ".onnx", ".safetensors",
    ".zip",  ".tar",    ".tgz",    ".xz",   ".gz",
    ".7z",   ".a",      ".so",     ".dylib", ".dll",
    ".o",    ".jar",    ".aar",    ".apk",  ".ipa",
    ".wasm", ".ptau",   ".pt",     ".h5",   ".out",
    ".jpg",  ".jpeg",   ".png",    ".webp", ".bmp",
};

// Ignored-by-design prefixes that are skipped before the foreign-layer check;
// they hold thousands of cache files and are attributed to the repo ignore.
const design_ignored_prefixes = [_][]const u8{
    ".zig-cache/",
    "zig-out/",
    ".local/",
    ".vendor/",
    ".vendor-archives/",
    ".models/",
    ".git/",
};

// Provenance tokens are assembled from halves so this file never contains the
// literal strings it bans.
const banned_tokens = [_][]const u8{
    "cla" ++ "ude",
    "anthro" ++ "pic",
    "chat" ++ "gpt",
    "open" ++ "ai",
    "copi" ++ "lot",
    "gem" ++ "ini",
    "deep" ++ "seek",
    "co-auth" ++ "ored-by",
    "generated " ++ "with",
    "ai-gen" ++ "erated",
};

// A comment states what the code does and why; it never narrates the
// investigation that led here (what was checked, how confident the
// author is, when it happened) or cites a planning document. These
// markers catch that shape on added comment lines - this project's own
// recurring mistake, not a hypothetical. Local-only material is caught
// by its directory, never by enumerating its filenames here.
const verbose_comment_markers = [_][]const u8{
    "verified",       "confirmed",     "not assumed",
    "found that",     "found a real",  "real finding",
    "real question",  "real, proven",  "real and proven",
    "owner-directed", "owner-ordered", "SPEC.md",
    "docs/private",
};

// A comment explains the one thing a reader can't already see; it is
// not an essay. A run of consecutive added comment lines past this is
// the project's own recurring mistake (a narrated investigation where
// a sentence would do), not a hypothetical.
const max_comment_block_lines: usize = 4;

// W7: a signature crossing C carries at most four scalar float
// parameters. A [3]/[4] float group crosses by pointer, since spilling
// past the argument registers is the x86 marshalling bug that corrupts
// the group. The fifth consecutive scalar float is the rejection line.
const max_scalar_float_params: usize = 4;

// The frozen public ABI ops that already shipped loose float spreads.
// Conformance pins their lowering; they migrate to by-pointer groups at
// the next ABI major, when the frozen surface may change shape.
const frozen_float_spread = [_][]const u8{
    "goss_session_brush_set_style",
    "goss_session_ar_brush_set_style",
    "goss_session_set_source_composite",
    "goss_session_grab",
    "goss_session_ar_brush_point",
    "goss_session_add_collider",
    "goss_session_erase_collider",
};

// A PR body is a short paragraph, not a report: what changed and why,
// nothing about how the change was proven out. Modeled on how ghostty's
// own PRs read - three sentences, no headers, no checklist.
const max_pr_body_lines: usize = 12;
const max_pr_body_bytes: usize = 900;

const banned_pr_body_headers = [_][]const u8{
    "summary",     "test plan",  "testing",   "changes",
    "overview",    "background", "motivation", "what changed",
    "how tested",  "verification",
};

const Gate = struct {
    arena: Allocator,
    io: Io,
    violations: std.ArrayList([]const u8) = .empty,

    fn flag(g: *Gate, comptime fmt: []const u8, args: anytype) !void {
        try g.violations.append(g.arena, try std.fmt.allocPrint(g.arena, fmt, args));
    }

    fn git(g: *Gate, argv: []const []const u8, ok_codes: []const u8) ![]u8 {
        const res = std.process.run(g.arena, g.io, .{ .argv = argv }) catch |err| {
            std.debug.print("gate: cannot run {s}: {t}\n", .{ argv[0], err });
            return error.GitUnavailable;
        };
        switch (res.term) {
            .exited => |code| {
                if (std.mem.indexOfScalar(u8, ok_codes, code) == null) {
                    std.debug.print("gate: {s} exited {d}: {s}\n", .{ argv[1], code, res.stderr });
                    return error.GitFailed;
                }
            },
            else => {
                std.debug.print("gate: {s} terminated abnormally\n", .{argv[1]});
                return error.GitFailed;
            },
        }
        return res.stdout;
    }

    fn nulSeparated(g: *Gate, out: []u8) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, out, 0);
        while (it.next()) |p| try list.append(g.arena, p);
        return list.items;
    }

    // Direction one: the re-include list and the foreign-layer check.
    fn checkIgnoreIntegrity(g: *Gate) !void {
        const gitignore = Io.Dir.cwd().readFileAlloc(g.io, ".gitignore", g.arena, .limited(1 << 16)) catch {
            try g.flag("ignore-integrity: .gitignore missing at repo root", .{});
            return;
        };

        var root = try Io.Dir.cwd().openDir(g.io, ".", .{ .iterate = true });
        defer root.close(g.io);
        var dir_it = root.iterate();
        while (try dir_it.next(g.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (std.mem.eql(u8, entry.name, "zig-out")) continue;
            const line = try std.fmt.allocPrint(g.arena, "!{s}/**", .{entry.name});
            if (!hasLine(gitignore, line)) {
                try g.flag("ignore-integrity: owned tree '{s}' lacks a '{s}' re-include in .gitignore", .{ entry.name, line });
            }
        }

        const ignored_out = try g.git(&.{ "git", "ls-files", "--others", "--ignored", "--exclude-standard", "-z" }, &.{0});
        const ignored = try g.nulSeparated(ignored_out);

        var to_check: std.ArrayList([]const u8) = .empty;
        for (ignored) |path| {
            if (hasAnyPrefix(path, &design_ignored_prefixes)) continue;
            try to_check.append(g.arena, path);
        }

        var i: usize = 0;
        while (i < to_check.items.len) : (i += 50) {
            const chunk = to_check.items[i..@min(i + 50, to_check.items.len)];
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(g.arena, &.{ "git", "check-ignore", "-v", "--" });
            try argv.appendSlice(g.arena, chunk);
            // exit 1 means nothing matched, which cannot happen for known-ignored paths
            const out = try g.git(argv.items, &.{ 0, 1 });
            var lines = std.mem.tokenizeScalar(u8, out, '\n');
            while (lines.next()) |line| {
                // <source>:<linenum>:<pattern>\t<pathname>
                const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
                const source = line[0 .. std.mem.indexOfScalar(u8, line[0..tab], ':') orelse continue];
                const path = line[tab + 1 ..];
                if (!std.mem.eql(u8, source, ".gitignore")) {
                    try g.flag("ignore-integrity: '{s}' is hidden by a foreign ignore layer ({s}); the repo .gitignore is the only authority", .{ path, source });
                }
            }
        }
    }

    // Direction two: nothing forbidden, no build detritus, no artifact
    // classes, nothing oversized.
    fn checkInbound(g: *Gate, paths: []const []const u8) !void {
        for (paths) |path| {
            if (forbiddenPrefix(path)) |p| {
                try g.flag("inbound: '{s}' is inside forbidden tree '{s}'", .{ path, p });
                continue;
            }
            if (forbiddenSegment(path)) |s| {
                try g.flag("inbound: '{s}' contains build-detritus segment '{s}'", .{ path, s });
                continue;
            }
            if (forbiddenExtension(path)) |e| {
                try g.flag("inbound: '{s}' has forbidden artifact extension '{s}'", .{ path, e });
                continue;
            }
            const stat = Io.Dir.cwd().statFile(g.io, path, .{}) catch continue;
            if (stat.size > max_staged_file_bytes) {
                try g.flag("inbound: '{s}' is {d} bytes; files over {d} bytes are fetched via a tracked lock, not committed", .{ path, stat.size, max_staged_file_bytes });
            }
        }
    }

    fn checkFileProvenance(g: *Gate, paths: []const []const u8) !void {
        for (paths) |path| {
            const stat = Io.Dir.cwd().statFile(g.io, path, .{}) catch continue;
            if (stat.size > max_file_scan_bytes) continue;
            const content = Io.Dir.cwd().readFileAlloc(g.io, path, g.arena, .limited(max_file_scan_bytes)) catch continue;
            if (looksBinary(content)) continue;
            if (findBannedToken(content)) |tok| {
                try g.flag("provenance: '{s}' contains banned token '{s}'", .{ path, tok });
            }
        }
    }

    fn checkMessage(g: *Gate, message: []const u8, context: []const u8) !void {
        if (findBannedToken(message)) |tok| {
            try g.flag("provenance: {s} contains banned token '{s}'", .{ context, tok });
        }
    }

    // Scans added lines in a unified diff for comment-hygiene violations.
    // diff_args are appended to `git diff` (e.g. `--cached ...` for
    // staged, or a rev range for CI) so this one scanner serves both.
    fn checkCommentHygiene(g: *Gate, diff_args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(g.arena, &.{ "git", "diff", "--diff-filter=ACMR", "-U0" });
        try argv.appendSlice(g.arena, diff_args);
        const out = try g.git(argv.items, &.{0});

        var current_path: []const u8 = "";
        var run_len: usize = 0;
        var run_first: []const u8 = "";

        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "+++ ")) {
                try g.flagOverlongCommentBlock(current_path, run_len, run_first);
                run_len = 0;
                const rest = line["+++ ".len..];
                current_path = if (std.mem.startsWith(u8, rest, "b/")) rest["b/".len..] else rest;
                continue;
            }
            const is_added = std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++") and !isGeneratedWrapperScript(current_path) and !isProseFile(current_path);
            const content = if (is_added) line[1..] else "";
            const is_added_comment = is_added and isCommentLine(content);

            if (is_added_comment) {
                if (run_len == 0) run_first = std.mem.trim(u8, content, " \t");
                run_len += 1;
            } else {
                try g.flagOverlongCommentBlock(current_path, run_len, run_first);
                run_len = 0;
            }

            if (!is_added_comment) continue;
            if (findVerboseMarker(content)) |marker| {
                try g.flag("comment-hygiene: '{s}' has a verbose comment (matched '{s}'): {s}", .{ current_path, marker, std.mem.trim(u8, content, " \t") });
            }
        }
        try g.flagOverlongCommentBlock(current_path, run_len, run_first);
    }

    fn flagOverlongCommentBlock(g: *Gate, path: []const u8, run_len: usize, first_line: []const u8) !void {
        if (run_len <= max_comment_block_lines) return;
        try g.flag("comment-hygiene: '{s}' adds a {d}-line comment block starting '{s}'; say it in {d} lines or fewer", .{ path, run_len, first_line, max_comment_block_lines });
    }

    // A short paragraph: what changed and why, nothing about how it was
    // tested. No markdown headers, no checklist syntax, no banned
    // section words as a leading line - those are the report-shaped
    // tells this scanner exists to catch, not a style nitpick.
    fn checkProseShape(g: *Gate, text: []const u8, context: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > max_pr_body_bytes) {
            try g.flag("body-shape: {s} is {d} bytes; keep it to a short paragraph, under {d}", .{ context, trimmed.len, max_pr_body_bytes });
        }

        var line_count: usize = 0;
        var lines = std.mem.splitScalar(u8, trimmed, '\n');
        while (lines.next()) |line| {
            line_count += 1;
            const stripped = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, stripped, "#")) {
                try g.flag("body-shape: {s} uses a markdown header ('{s}'); write prose, not a report", .{ context, stripped });
            }
            if (isChecklistLine(stripped)) {
                try g.flag("body-shape: {s} has a checklist line ('{s}'); a test plan belongs in the PR run, not the body", .{ context, stripped });
            }
            const header_word = headerLikeLine(stripped);
            if (header_word) |w| {
                try g.flag("body-shape: {s} opens a section with '{s}'; write one paragraph instead", .{ context, w });
            }
        }
        if (line_count > max_pr_body_lines) {
            try g.flag("body-shape: {s} is {d} lines; keep it to {d} or fewer, like a short paragraph", .{ context, line_count, max_pr_body_lines });
        }
    }

    // A long dash (em-dash always, en-dash outside a number range) is a machine
    // writing tell. Flags each hit with a quote and the fix. Runs on doc prose,
    // commit messages, and PR bodies.
    fn checkClauseDashes(g: *Gate, text: []const u8, context: []const u8) !void {
        var from: usize = 0;
        while (nextBadDash(text, from)) |idx| {
            const snippet = clauseSnippet(text, idx);
            try g.flag("long-dash: {s} uses a long dash (\"{s}\"); a long dash reads as AI-written, so use a plain hyphen '-' or restructure the sentence. En-dashes are only for number ranges.", .{ context, snippet });
            from = idx + 3;
        }
    }

    fn checkProseDashes(g: *Gate, paths: []const []const u8) !void {
        for (paths) |path| {
            if (!isMarkdownDoc(path)) continue;
            const stat = Io.Dir.cwd().statFile(g.io, path, .{}) catch continue;
            if (stat.size > max_file_scan_bytes) continue;
            const content = Io.Dir.cwd().readFileAlloc(g.io, path, g.arena, .limited(max_file_scan_bytes)) catch continue;
            const ctx = try std.fmt.allocPrint(g.arena, "'{s}'", .{path});
            try g.checkClauseDashes(content, ctx);
        }
    }

    fn stagedPaths(g: *Gate) ![][]const u8 {
        const out = try g.git(&.{ "git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z" }, &.{0});
        return g.nulSeparated(out);
    }

    fn trackedPaths(g: *Gate) ![][]const u8 {
        const out = try g.git(&.{ "git", "ls-files", "-z" }, &.{0});
        return g.nulSeparated(out);
    }

    fn checkLogRange(g: *Gate, range: []const u8) !void {
        const out = try g.git(&.{ "git", "log", "--format=%H%x1f%B%x00", range }, &.{0});
        var records = std.mem.tokenizeScalar(u8, out, 0);
        while (records.next()) |rec| {
            const sep = std.mem.indexOfScalar(u8, rec, 0x1f) orelse continue;
            const sha = std.mem.trim(u8, rec[0..sep], "\n");
            const body = rec[sep + 1 ..];
            const ctx = try std.fmt.allocPrint(g.arena, "commit {s}", .{sha[0..@min(sha.len, 12)]});
            try g.checkMessage(body, ctx);
            try g.checkClauseDashes(body, ctx);
        }
    }

    // The exception stance is mechanical: every C++ TU build.zig compiles
    // either carries -fno-exceptions or its file shows a guard on every
    // extern "C" entry. Emcc-side compiles carry the flag in their own
    // argument arrays and have no unguarded extern "C" sources.
    fn checkBoundaryStance(g: *Gate) !void {
        const text = Io.Dir.cwd().readFileAlloc(g.io, "build.zig", g.arena, .limited(1 << 22)) catch {
            try g.flag("boundary: build.zig unreadable, cannot check the exception stance", .{});
            return;
        };
        const scopes = try splitFnScopes(g.arena, text);
        for (scopes) |scope| {
            // A compile-forwarding helper takes its flags as a parameter;
            // its stance is judged where it is called, not here.
            const signature = scope.body[0 .. std.mem.indexOfScalar(u8, scope.body, '\n') orelse scope.body.len];
            if (std.mem.indexOf(u8, signature, ", flags: []const []const u8") != null) continue;
            var scope_dynamic_checked = false;
            var search: usize = 0;
            while (std.mem.indexOfPos(u8, scope.body, search, "addCSourceFile(")) |at| {
                const open = at + "addCSourceFile".len;
                const args = balancedParens(scope.body, open) orelse {
                    search = at + 1;
                    continue;
                };
                search = open + 1 + args.len;
                const no_exceptions = try g.siteHasNoExceptions(scopes, scope, args);
                const literals = try collectStringLiterals(g.arena, args);
                var found_cxx = false;
                var found_other_source = false;
                for (literals) |lit| {
                    if (std.mem.indexOf(u8, lit, "{s}") != null) continue;
                    if (isExtensionToken(lit)) continue;
                    if (isCxxSourcePath(lit)) {
                        found_cxx = true;
                        const path = try g.resolveCompilePath(scope, lit);
                        if (no_exceptions) {
                            try g.verifyNoExceptionsTu(path);
                        } else {
                            try g.verifyGuardedTu(path);
                        }
                    } else if (std.mem.lastIndexOfScalar(u8, lit, '.') != null and std.mem.indexOfScalar(u8, lit, ' ') == null) {
                        found_other_source = true;
                    }
                }
                if (!found_cxx and !found_other_source and !no_exceptions and !scope_dynamic_checked) {
                    scope_dynamic_checked = true;
                    try g.verifyScopeDynamic(scope);
                }
            }
        }
    }

    // Stance for one addCSourceFile call: an inline flags literal decides
    // alone; a flags-building helper the call names decides next; the
    // enclosing function's own unconditional flag decides last.
    fn siteHasNoExceptions(g: *Gate, scopes: []const FnScope, scope: FnScope, args: []const u8) !bool {
        if (std.mem.indexOf(u8, args, "-fno-exceptions") != null) return true;
        if (std.mem.indexOf(u8, args, ".flags = &.{") != null) return false;
        for (scopes) |s| {
            if (s.name.len == 0) continue;
            const needle = try std.fmt.allocPrint(g.arena, "{s}(", .{s.name});
            if (std.mem.indexOf(u8, args, needle) != null and hasUnconditionalNoExceptions(s.body)) return true;
        }
        return hasUnconditionalNoExceptions(scope.body);
    }

    // Relative source names sit next to a root the same scope names in a
    // b.fmt pattern or include path; the joined path that exists wins.
    fn resolveCompilePath(g: *Gate, scope: FnScope, lit: []const u8) ![]const u8 {
        if (Io.Dir.cwd().statFile(g.io, lit, .{})) |_| return lit else |_| {}
        const roots = try collectStringLiterals(g.arena, scope.body);
        for (roots) |root_lit| {
            if (!std.mem.startsWith(u8, root_lit, ".vendor")) continue;
            var root = root_lit;
            if (std.mem.indexOf(u8, root, "{s}")) |cut| root = root[0..cut];
            root = std.mem.trimEnd(u8, root, "/");
            const joined = try std.fmt.allocPrint(g.arena, "{s}/{s}", .{ root, lit });
            if (Io.Dir.cwd().statFile(g.io, joined, .{})) |_| return joined else |_| {}
        }
        return lit;
    }

    // A dynamic compile loop without the flag: every C++ file the scope
    // names or globs must pass the per-file guard grep. A loop over only
    // C sources is out of scope and passes.
    fn verifyScopeDynamic(g: *Gate, scope: FnScope) !void {
        var found_cxx = false;
        var found_c = false;
        const scope_lits = try collectStringLiterals(g.arena, scope.body);
        for (scope_lits) |lit| {
            if (std.mem.indexOf(u8, lit, "{s}") != null) continue;
            if (isExtensionToken(lit)) continue;
            if (isCxxSourcePath(lit)) {
                found_cxx = true;
                try g.verifyGuardedTu(try g.resolveCompilePath(scope, lit));
            } else if (std.mem.endsWith(u8, lit, ".c") or std.mem.endsWith(u8, lit, ".m") or std.mem.endsWith(u8, lit, ".S")) {
                found_c = true;
            }
        }
        inline for (.{ "listFilesRecursive(b, ", "listFiles(b, ", "addCxxDir(b, " }) |marker| {
            const paren_at = comptime std.mem.indexOfScalar(u8, marker, '(').?;
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, scope.body, from, marker)) |at| {
                from = at + marker.len;
                const call_args = balancedParens(scope.body, at + paren_at) orelse scope.body[at..@min(at + 200, scope.body.len)];
                const lits = try collectStringLiterals(g.arena, call_args);
                var dir: ?[]const u8 = null;
                var ext: []const u8 = ".cpp";
                for (lits) |lit| {
                    if (lit.len > 0 and lit[0] == '.' and std.mem.indexOfScalar(u8, lit, '/') == null) {
                        ext = lit;
                    } else if (dir == null and std.mem.indexOfScalar(u8, lit, '/') != null) {
                        dir = lit;
                    }
                }
                if (!isCxxSourcePath(ext)) continue;
                found_cxx = true;
                const d = dir orelse {
                    try g.flag("boundary: '{s}' compiles a C++ glob without -fno-exceptions and the directory is not a literal; add the flag", .{scope.name});
                    continue;
                };
                try g.verifyGuardedTree(d, ext);
            }
        }
        if (!found_cxx and !found_c) {
            try g.flag("boundary: '{s}' has a dynamic compile without -fno-exceptions that cannot be enumerated; add the flag", .{scope.name});
        }
    }

    fn verifyGuardedTree(g: *Gate, dir_path: []const u8, ext: []const u8) !void {
        var dir = Io.Dir.cwd().openDir(g.io, dir_path, .{ .iterate = true }) catch {
            try g.flag("boundary: cannot open '{s}' to check the exception stance of its compiles", .{dir_path});
            return;
        };
        defer dir.close(g.io);
        var it = dir.iterate();
        while (try it.next(g.io)) |entry| {
            const child = try std.fmt.allocPrint(g.arena, "{s}/{s}", .{ dir_path, entry.name });
            switch (entry.kind) {
                .directory => try g.verifyGuardedTree(child, ext),
                .file => if (std.mem.endsWith(u8, entry.name, ext)) try g.verifyGuardedTu(child),
                else => {},
            }
        }
    }

    // An exceptions-enabled TU with extern "C" entries: vendor files must
    // show a catch; first-party shims must guard every entry.
    fn verifyGuardedTu(g: *Gate, path: []const u8) !void {
        const content = Io.Dir.cwd().readFileAlloc(g.io, path, g.arena, .limited(max_file_scan_bytes)) catch {
            try g.flag("boundary: cannot read '{s}' to check guards for its exceptions-enabled compile", .{path});
            return;
        };
        const entries = countLineAnchored(content, "extern \"C\"");
        if (entries == 0) return;
        if (std.mem.startsWith(u8, path, ".vendor/")) {
            if (std.mem.indexOf(u8, content, "catch") == null) {
                try g.flag("boundary: vendor TU '{s}' compiles with exceptions enabled, has extern \"C\" and no catch; give its flags -fno-exceptions", .{path});
            }
            return;
        }
        const total = std.mem.count(u8, content, "GOSS_SHIM_GUARD");
        const defines = std.mem.count(u8, content, "#define GOSS_SHIM_GUARD");
        const guards = total - defines;
        if (defines == 0 or guards < entries) {
            try g.flag("boundary: '{s}' compiles with exceptions enabled but its {d} extern \"C\" entries carry {d} GOSS_SHIM_GUARD guards; guard every entry or compile -fno-exceptions", .{ path, entries, guards });
        }
    }

    // A first-party -fno-exceptions TU with extern "C" entries opens with
    // the stance comment, so the file itself names what enforces it.
    fn verifyNoExceptionsTu(g: *Gate, path: []const u8) !void {
        if (std.mem.startsWith(u8, path, ".vendor/")) return;
        const content = Io.Dir.cwd().readFileAlloc(g.io, path, g.arena, .limited(max_file_scan_bytes)) catch {
            try g.flag("boundary: cannot read '{s}' to check its stance comment", .{path});
            return;
        };
        if (countLineAnchored(content, "extern \"C\"") == 0) return;
        const first_line = content[0 .. std.mem.indexOfScalar(u8, content, '\n') orelse content.len];
        if (std.mem.indexOf(u8, first_line, "-fno-exceptions") == null) {
            try g.flag("boundary: '{s}' compiles -fno-exceptions but its first line does not state the stance and the build.zig site that sets it", .{path});
        }
    }

    // W7 mechanical check: no C-crossing signature carries more than four
    // consecutive scalar floats. Covers the public header and the physics
    // extern boundary; only the frozen public spreads are exempt.
    fn checkFloatCap(g: *Gate) !void {
        try g.checkFloatCapHeader("include/gosslens.h");
        try g.checkFloatCapExterns("adapters/physics/physics.zig");
    }

    // Every goss_ prototype in the C header: the identifier before a '('
    // names the callee, the balanced parens hold its parameters.
    fn checkFloatCapHeader(g: *Gate, path: []const u8) !void {
        const raw = Io.Dir.cwd().readFileAlloc(g.io, path, g.arena, .limited(1 << 20)) catch {
            try g.flag("float-cap: cannot read '{s}' to count scalar floats per signature", .{path});
            return;
        };
        const text = try stripCComments(g.arena, raw);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '(') continue;
            var start = i;
            while (start > 0 and (std.ascii.isAlphanumeric(text[start - 1]) or text[start - 1] == '_')) start -= 1;
            const name = text[start..i];
            if (!std.mem.startsWith(u8, name, "goss_")) continue;
            const args = balancedParens(text, i) orelse continue;
            const run = maxConsecutiveScalarFloats(args, false);
            if (run > max_scalar_float_params and !isFrozenSpread(name)) {
                try g.flag("float-cap: '{s}' passes {d} consecutive scalar floats across C; pass the [3]/[4] group by pointer (const float*), the cap is {d}", .{ name, run, max_scalar_float_params });
            }
        }
    }

    // Every extern fn goss_ declaration in the physics shim boundary.
    fn checkFloatCapExterns(g: *Gate, path: []const u8) !void {
        const text = Io.Dir.cwd().readFileAlloc(g.io, path, g.arena, .limited(1 << 20)) catch {
            try g.flag("float-cap: cannot read '{s}' to count scalar floats per extern", .{path});
            return;
        };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "extern fn goss_")) continue;
            const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
            const name = std.mem.trim(u8, trimmed["extern fn ".len..open], " \t");
            const args = balancedParens(trimmed, open) orelse continue;
            const run = maxConsecutiveScalarFloats(args, true);
            if (run > max_scalar_float_params and !isFrozenSpread(name)) {
                try g.flag("float-cap: extern '{s}' passes {d} consecutive scalar f32 across C; pass the [3]/[4] group as *const [N]f32, the cap is {d}", .{ name, run, max_scalar_float_params });
            }
        }
    }
};

fn isFrozenSpread(name: []const u8) bool {
    for (frozen_float_spread) |f| {
        if (std.mem.eql(u8, name, f)) return true;
    }
    return false;
}

// The longest run of adjacent scalar-float parameters in an argument
// list. A pointer or array parameter (the by-pointer group) breaks the
// run, as does any non-float. `zig` picks the f32 spelling.
fn maxConsecutiveScalarFloats(args: []const u8, zig: bool) usize {
    var best: usize = 0;
    var cur: usize = 0;
    var it = std.mem.splitScalar(u8, args, ',');
    while (it.next()) |raw| {
        const param = std.mem.trim(u8, raw, " \t\r\n");
        if (param.len == 0) continue;
        const scalar = if (zig) isZigScalarFloat(param) else isCScalarFloat(param);
        if (scalar) {
            cur += 1;
            if (cur > best) best = cur;
        } else {
            cur = 0;
        }
    }
    return best;
}

// A C parameter that is a bare `float`: a pointer or array is the
// by-pointer form and does not count.
fn isCScalarFloat(param: []const u8) bool {
    if (std.mem.indexOfScalar(u8, param, '*') != null) return false;
    if (std.mem.indexOfScalar(u8, param, '[') != null) return false;
    var toks = std.mem.tokenizeAny(u8, param, " \t");
    while (toks.next()) |tok| {
        if (std.mem.eql(u8, tok, "float")) return true;
    }
    return false;
}

// A Zig extern parameter whose type is exactly `f32`; `*const [3]f32`
// and `[*]const f32` are the by-pointer forms and do not count.
fn isZigScalarFloat(param: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, param, ':') orelse return false;
    const ty = std.mem.trim(u8, param[colon + 1 ..], " \t\r\n");
    return std.mem.eql(u8, ty, "f32");
}

// Blanks C block and line comments so a '(' or the word float inside a
// comment cannot be read as part of a signature.
fn stripCComments(arena: Allocator, text: []const u8) ![]u8 {
    const out = try arena.alloc(u8, text.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
            i += 2;
            while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) i += 1;
            i = @min(i + 2, text.len);
            out[n] = ' ';
            n += 1;
            continue;
        }
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        out[n] = text[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var g: Gate = .{ .arena = arena, .io = init.io };

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program path
    const mode = args.next() orelse {
        std.debug.print("gate: usage: gate --staged | --tree | --commit-msg <file> | --log <range> | --diff <range> | --pr-body <file>\n", .{});
        return 2;
    };

    if (std.mem.eql(u8, mode, "--staged")) {
        const paths = try g.stagedPaths();
        try g.checkIgnoreIntegrity();
        try g.checkInbound(paths);
        try g.checkFileProvenance(paths);
        try g.checkCommentHygiene(&.{"--cached"});
        try g.checkProseDashes(paths);
        try g.checkBoundaryStance();
        try g.checkFloatCap();
    } else if (std.mem.eql(u8, mode, "--tree")) {
        const paths = try g.trackedPaths();
        try g.checkIgnoreIntegrity();
        try g.checkInbound(paths);
        try g.checkFileProvenance(paths);
        try g.checkProseDashes(paths);
        try g.checkBoundaryStance();
        try g.checkFloatCap();
    } else if (std.mem.eql(u8, mode, "--commit-msg")) {
        const file = args.next() orelse {
            std.debug.print("gate: --commit-msg needs a file argument\n", .{});
            return 2;
        };
        const message = try Io.Dir.cwd().readFileAlloc(g.io, file, arena, .limited(max_file_scan_bytes));
        try g.checkMessage(message, "commit message");
        try g.checkClauseDashes(message, "commit message");
    } else if (std.mem.eql(u8, mode, "--log")) {
        const range = args.next() orelse {
            std.debug.print("gate: --log needs a rev range argument\n", .{});
            return 2;
        };
        try g.checkLogRange(range);
    } else if (std.mem.eql(u8, mode, "--diff")) {
        const range = args.next() orelse {
            std.debug.print("gate: --diff needs a rev range argument\n", .{});
            return 2;
        };
        try g.checkCommentHygiene(&.{range});
    } else if (std.mem.eql(u8, mode, "--pr-body")) {
        const file = args.next() orelse {
            std.debug.print("gate: --pr-body needs a file argument\n", .{});
            return 2;
        };
        const body = try Io.Dir.cwd().readFileAlloc(g.io, file, arena, .limited(max_file_scan_bytes));
        try g.checkMessage(body, "PR body");
        try g.checkProseShape(body, "PR body");
        try g.checkClauseDashes(body, "PR body");
    } else {
        std.debug.print("gate: unknown mode '{s}'\n", .{mode});
        return 2;
    }

    if (g.violations.items.len != 0) {
        for (g.violations.items) |v| std.debug.print("gate: {s}\n", .{v});
        std.debug.print("gate: {d} violation(s)\n", .{g.violations.items.len});
        return 1;
    }
    return 0;
}

fn hasLine(text: []const u8, wanted: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), wanted)) return true;
    }
    return false;
}

fn hasAnyPrefix(path: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, path, p)) return true;
    }
    return false;
}

fn forbiddenPrefix(path: []const u8) ?[]const u8 {
    for (forbidden_prefixes) |p| {
        if (std.mem.startsWith(u8, path, p)) return p;
    }
    return null;
}

fn forbiddenSegment(path: []const u8) ?[]const u8 {
    var segs = std.mem.tokenizeScalar(u8, path, '/');
    while (segs.next()) |seg| {
        for (forbidden_segments) |bad| {
            if (std.mem.eql(u8, seg, bad)) return bad;
        }
        if (std.mem.endsWith(u8, seg, ".xcframework")) return ".xcframework";
    }
    return null;
}

fn forbiddenExtension(path: []const u8) ?[]const u8 {
    // A reference lens's own assets/*.png is real bundle content the
    // format itself defines (lut.pass and blend.pass name an asset by
    // id the same way shader.pass names a .glsl source file) - not a
    // fetched or built artifact like every other extension here.
    if (std.mem.startsWith(u8, path, "lenses/") and std.mem.endsWith(u8, path, ".png") and std.mem.indexOf(u8, path, "/assets/") != null) {
        return null;
    }
    // The web demo's own beauty LUT textures - same reasoning, real
    // bundle content copied in once rather than fetched or built.
    if (std.mem.startsWith(u8, path, "sdk/ts/demo/res/") and std.mem.endsWith(u8, path, ".png")) {
        return null;
    }
    // Gradle's own bootstrap stub, not a build output - JitPack (and
    // anyone else) clones this repo and runs ./gradlew directly, which
    // does not exist without the jar next to it.
    if (std.mem.eql(u8, path, "sdk/kotlin/gradle/wrapper/gradle-wrapper.jar")) {
        return null;
    }
    for (forbidden_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return ext;
    }
    return null;
}

fn looksBinary(content: []const u8) bool {
    const probe = content[0..@min(content.len, 4096)];
    return std.mem.indexOfScalar(u8, probe, 0) != null;
}

fn findBannedToken(text: []const u8) ?[]const u8 {
    for (banned_tokens) |tok| {
        if (std.ascii.indexOfIgnoreCase(text, tok) != null) return tok;
    }
    return null;
}

// Gradle's own wrapper script - `gradle wrapper` generates it verbatim
// and it is never hand-edited, the same reasoning a vendored tree gets.
fn isGeneratedWrapperScript(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "/gradlew") or std.mem.eql(u8, path, "gradlew");
}

// Markdown is prose, not source - its `#` headings and `*` bullets look
// like comment syntax to this scanner but are the document itself.
// Patch files carry verbatim upstream diff content, not authored
// comments, so they get the same pass.
fn isProseFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".patch");
}

// A `#`-led line that is real C/ObjC code (#define, #include, #if...),
// not a shell/Python/YAML comment - the two share a leading marker.
fn isPreprocessorDirective(trimmed: []const u8) bool {
    const rest = std.mem.trimStart(u8, trimmed[1..], " \t");
    // Deliberately excludes if/ifdef/ifndef/else/elif/endif - real
    // directives, but also how plenty of plain-English comments open.
    const directives = [_][]const u8{ "define", "include", "pragma", "import" };
    for (directives) |word| {
        if (std.mem.startsWith(u8, rest, word)) {
            const after = rest[word.len..];
            if (after.len == 0 or !std.ascii.isAlphanumeric(after[0])) return true;
        }
    }
    return false;
}

fn isCommentLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    // A `*` line is a block-comment continuation only when the star
    // stands alone or is followed by a space or `/` - a pointer store
    // like `*ptr = x;` is code, not commentary.
    const star_continuation = std.mem.startsWith(u8, trimmed, "*") and
        (trimmed.len == 1 or trimmed[1] == ' ' or trimmed[1] == '/');
    return std.mem.startsWith(u8, trimmed, "//") or
        std.mem.startsWith(u8, trimmed, "///") or
        star_continuation or
        (std.mem.startsWith(u8, trimmed, "#") and !isPreprocessorDirective(trimmed));
}

fn hasIsoDate(line: []const u8) bool {
    if (line.len < 10) return false;
    var i: usize = 0;
    while (i + 10 <= line.len) : (i += 1) {
        const s = line[i..][0..10];
        if (s[0] == '2' and s[1] == '0' and
            std.ascii.isDigit(s[2]) and std.ascii.isDigit(s[3]) and
            s[4] == '-' and std.ascii.isDigit(s[5]) and std.ascii.isDigit(s[6]) and
            s[7] == '-' and std.ascii.isDigit(s[8]) and std.ascii.isDigit(s[9]))
        {
            return true;
        }
    }
    return false;
}

// A line that is just a banned word, optionally with a trailing colon
// or markdown bold - "Summary", "**Test plan**", "Testing:" - read as a
// report's section header, not a sentence that happens to contain the
// word.
fn headerLikeLine(line: []const u8) ?[]const u8 {
    var body = std.mem.trim(u8, line, "*# \t");
    if (std.mem.endsWith(u8, body, ":")) body = body[0 .. body.len - 1];
    for (banned_pr_body_headers) |word| {
        if (std.ascii.eqlIgnoreCase(body, word)) return word;
    }
    return null;
}

fn isChecklistLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "- [ ]") or std.mem.startsWith(u8, line, "- [x]");
}

fn findVerboseMarker(line: []const u8) ?[]const u8 {
    for (verbose_comment_markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(line, marker) != null) return marker;
    }
    if (hasIsoDate(line)) return "a dated timeline entry, not a fact about the code";
    return null;
}

// A long dash at the start of s: the em-dash (U+2014) or en-dash (U+2013),
// both three bytes under E2 80. Returns the third byte (0x94 or 0x93) or null.
fn dashByte(s: []const u8) ?u8 {
    if (s.len >= 3 and s[0] == 0xE2 and s[1] == 0x80 and (s[2] == 0x94 or s[2] == 0x93)) return s[2];
    return null;
}

fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// Index of the next long dash that reads as AI-written, or null. The em-dash
// is always the tell. The en-dash is allowed only as a numeric range (a digit
// on both sides, like 2013-2015); anywhere else it is flagged too. A plain
// ascii hyphen '-' is never a hit.
fn nextBadDash(text: []const u8, from: usize) ?usize {
    var i: usize = from;
    while (i < text.len) : (i += 1) {
        const kind = dashByte(text[i..]) orelse continue;
        if (kind == 0x94) return i; // em-dash: always the tell
        const range = i > 0 and isAsciiDigit(text[i - 1]) and i + 3 < text.len and isAsciiDigit(text[i + 3]);
        if (!range) return i; // en-dash outside a numeric range
        i += 2;
    }
    return null;
}

fn hasBadDash(text: []const u8) bool {
    return nextBadDash(text, 0) != null;
}

// A short quote around the dash, bounded to its own line and a small
// window so a violation shows the joined clause, not the paragraph.
fn clauseSnippet(text: []const u8, dash_index: usize) []const u8 {
    var line_start: usize = dash_index;
    while (line_start > 0 and text[line_start - 1] != '\n') line_start -= 1;
    var line_end: usize = dash_index;
    while (line_end < text.len and text[line_end] != '\n') line_end += 1;
    const window: usize = 24;
    const start = if (dash_index - line_start > window) dash_index - window else line_start;
    const stop = if (line_end - dash_index > window) dash_index + window else line_end;
    return std.mem.trim(u8, text[start..stop], " \t\r");
}

// Authored markdown prose, the only files scanned for clause dashes. The
// private docs tree is gitignored and never scanned; source keeps its
// own spaced hyphens and is out of scope.
fn isMarkdownDoc(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".md")) return false;
    if (std.mem.startsWith(u8, path, "docs/private/")) return false;
    return true;
}

const FnScope = struct {
    name: []const u8,
    body: []const u8,
};

// build.zig cut at every column-zero fn so each compile site can be
// judged against the flags its own function builds.
fn splitFnScopes(arena: Allocator, text: []const u8) ![]FnScope {
    var scopes: std.ArrayList(FnScope) = .empty;
    var name: []const u8 = "";
    var start: usize = 0;
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        if (topLevelFnName(text[line_start..line_end])) |fn_name| {
            try scopes.append(arena, .{ .name = name, .body = text[start..line_start] });
            name = fn_name;
            start = line_start;
        }
        line_start = line_end + 1;
    }
    try scopes.append(arena, .{ .name = name, .body = text[start..] });
    return scopes.items;
}

fn topLevelFnName(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t') return null;
    var rest = line;
    if (std.mem.startsWith(u8, rest, "pub ")) rest = rest["pub ".len..];
    if (!std.mem.startsWith(u8, rest, "fn ")) return null;
    const after = rest["fn ".len..];
    const paren = std.mem.indexOfScalar(u8, after, '(') orelse return null;
    return after[0..paren];
}

// True when a scope carries the flag on a line of its own, not behind a
// per-target conditional - the wasm-only shape this check exists to ban.
fn hasUnconditionalNoExceptions(body: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "-fno-exceptions") == null) continue;
        if (std.mem.indexOf(u8, line, "if (") != null) continue;
        return true;
    }
    return false;
}

// The text between the parens that open at `open`, or null if they
// never close. String contents are not paren-balanced; build.zig's
// compile-site arguments carry no parens inside their literals.
fn balancedParens(text: []const u8, open: usize) ?[]const u8 {
    if (open >= text.len or text[open] != '(') return null;
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        if (text[i] == '(') {
            depth += 1;
        } else if (text[i] == ')') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return text[open + 1 .. i];
        }
    }
    return null;
}

fn collectStringLiterals(arena: Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '"') continue;
        var j = i + 1;
        while (j < text.len and text[j] != '"') : (j += 1) {
            if (text[j] == '\\') j += 1;
        }
        if (j >= text.len) break;
        try out.append(arena, text[i + 1 .. j]);
        i = j;
    }
    return out.items;
}

fn isCxxSourcePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".cc") or
        std.mem.endsWith(u8, path, ".cpp") or
        std.mem.endsWith(u8, path, ".mm");
}

// A bare extension argument like ".cpp", as glob calls pass, never a
// compilable path of its own.
fn isExtensionToken(lit: []const u8) bool {
    return lit.len > 0 and lit[0] == '.' and std.mem.indexOfScalar(u8, lit, '/') == null;
}

// Occurrences that begin a line (after indentation), so a definition
// counts and a comment that merely mentions the phrase does not.
fn countLineAnchored(content: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), needle)) n += 1;
    }
    return n;
}

test "top-level trees require their re-include line" {
    const ignore = "!core/**\n!tools/**\ndocs/private/\n";
    try std.testing.expect(hasLine(ignore, "!core/**"));
    try std.testing.expect(hasLine(ignore, "!tools/**"));
    try std.testing.expect(!hasLine(ignore, "!lenses/**"));
}

test "forbidden prefixes catch force-added trees" {
    try std.testing.expectEqualStrings("docs/private/", forbiddenPrefix("docs/private/ENGINEERING.md").?);
    try std.testing.expectEqualStrings(".models/", forbiddenPrefix(".models/face.task").?);
    try std.testing.expectEqualStrings("zig-out/", forbiddenPrefix("zig-out/bin/gate").?);
    try std.testing.expect(forbiddenPrefix("docs/ROADMAP.md") == null);
    try std.testing.expect(forbiddenPrefix("core/graph/node.zig") == null);
}

test "forbidden segments catch build detritus anywhere in the path" {
    try std.testing.expectEqualStrings("node_modules", forbiddenSegment("sdk/ts/node_modules/x/y.js").?);
    try std.testing.expectEqualStrings(".build", forbiddenSegment("sdk/swift/.build/debug/a").?);
    try std.testing.expectEqualStrings(".xcframework", forbiddenSegment("sdk/swift/Gosslens.xcframework/Info.plist").?);
    try std.testing.expect(forbiddenSegment("core/graph/scheduler.zig") == null);
}

test "forbidden extensions catch artifact classes" {
    try std.testing.expectEqualStrings(".task", forbiddenExtension("face_landmarker.task").?);
    try std.testing.expectEqualStrings(".wasm", forbiddenExtension("sdk/ts/core.wasm").?);
    try std.testing.expectEqualStrings(".a", forbiddenExtension("libfoo.a").?);
    try std.testing.expectEqualStrings(".out", forbiddenExtension("a.out").?);
    try std.testing.expect(forbiddenExtension("core/math/mat4.zig") == null);
    try std.testing.expect(forbiddenExtension("include/gosslens.h") == null);
    // A png anywhere else is still a fetched/scratch artifact - only a
    // reference lens's own assets/ directory is real bundle content.
    try std.testing.expectEqualStrings(".png", forbiddenExtension("sdk/kotlin/demo/src/main/assets/res/mouth.png").?);
    try std.testing.expect(forbiddenExtension("lenses/reference/background-swap/assets/beach.png") == null);
    try std.testing.expect(forbiddenExtension("sdk/ts/demo/res/lookup_gray.png") == null);
    // A jar anywhere else is still a build output - only the Gradle
    // wrapper's own bootstrap stub is real, necessary bundle content.
    try std.testing.expectEqualStrings(".jar", forbiddenExtension("some/other/lib.jar").?);
    try std.testing.expect(forbiddenExtension("sdk/kotlin/gradle/wrapper/gradle-wrapper.jar") == null);
}

test "banned tokens match case-insensitively and only when present" {
    const dirty = "Co-Auth" ++ "ored-By: somebody";
    try std.testing.expect(findBannedToken(dirty) != null);
    const clean = "frame graph scheduling with bounded pools";
    try std.testing.expect(findBannedToken(clean) == null);
}

test "binary probe" {
    try std.testing.expect(looksBinary("\x00\x01\x02"));
    try std.testing.expect(!looksBinary("plain text"));
}

test "design-ignored prefixes are skipped" {
    try std.testing.expect(hasAnyPrefix(".zig-cache/h/x", &design_ignored_prefixes));
    try std.testing.expect(!hasAnyPrefix("core/x.zig", &design_ignored_prefixes));
}

test "comment lines are recognized across languages" {
    try std.testing.expect(isCommentLine("    // a comment"));
    try std.testing.expect(isCommentLine("/// a doc comment"));
    try std.testing.expect(isCommentLine("  # a shell comment"));
    try std.testing.expect(!isCommentLine("    const x = 1;"));
    // A block-comment continuation is a star alone or star-space; a
    // pointer store is code.
    try std.testing.expect(isCommentLine(" * continuation text"));
    try std.testing.expect(isCommentLine(" */"));
    try std.testing.expect(!isCommentLine("*previous_program = 0;"));
    try std.testing.expect(!isCommentLine("  *ptr += 1;"));
}

test "preprocessor directives are not comments, even though they share a shell comment's # marker" {
    try std.testing.expect(!isCommentLine("#define ANGLE_COMMIT_DATE \"2026-08-18\""));
    try std.testing.expect(!isCommentLine("#include <zlib.h>"));
    try std.testing.expect(!isCommentLine("#import <UIKit/UIKit.h>"));
    try std.testing.expect(!isCommentLine("#pragma once"));
    // if/ifdef/endif stay comment-classified on purpose - too many real
    // English comments open the same way ("# if this ever fires...").
    try std.testing.expect(isCommentLine("#if this ever fires, retry"));
    try std.testing.expect(isCommentLine("  # a shell comment"));
}

test "generated wrapper scripts are recognized, hand-written scripts are not" {
    try std.testing.expect(isGeneratedWrapperScript("sdk/kotlin/gradlew"));
    try std.testing.expect(isGeneratedWrapperScript("gradlew"));
    try std.testing.expect(!isGeneratedWrapperScript("sdk/kotlin/demo/prove-emulator.sh"));
}

test "markdown and patches are prose, source is not" {
    try std.testing.expect(isProseFile("NOTICE.md"));
    try std.testing.expect(isProseFile("docs/API.md"));
    try std.testing.expect(isProseFile("third_party/bgfx/patches/0001-webgpu-timer-query-noop.patch"));
    try std.testing.expect(!isProseFile("core/abi/abi.zig"));
    try std.testing.expect(!isProseFile("adapters/beauty/beauty_shim.cc"));
}

test "verbose comment markers are caught, plain ones are not" {
    try std.testing.expect(findVerboseMarker("// verified this is correct") != null);
    try std.testing.expect(findVerboseMarker("// see docs/private/notes.md for context") != null);
    try std.testing.expect(findVerboseMarker("// found 2026-08-17 that this works") != null);
    try std.testing.expect(findVerboseMarker("// converts YUV to RGB via a fixed matrix") == null);
}

test "header-like lines catch report section markers, not prose that mentions them" {
    try std.testing.expectEqualStrings("summary", headerLikeLine("Summary").?);
    try std.testing.expectEqualStrings("test plan", headerLikeLine("## Test plan").?);
    try std.testing.expectEqualStrings("testing", headerLikeLine("**Testing:**").?);
    try std.testing.expect(headerLikeLine("this change needed real testing before landing") == null);
    try std.testing.expect(headerLikeLine("adds a snapshot decoder option") == null);
}

test "checklist lines are recognized" {
    try std.testing.expect(isChecklistLine("- [ ] zig build ci green"));
    try std.testing.expect(isChecklistLine("- [x] real device run"));
    try std.testing.expect(!isChecklistLine("- a plain bullet"));
}

test "any long dash is the AI tell; only a hyphen and a numeric range are fine" {
    // The em-dash is always the tell, before a lowercase clause...
    try std.testing.expect(hasBadDash("someone \xE2\x80\x94 every thread stays end-to-end encrypted"));
    // ...and equally before a capital (an appositive is not an exception).
    try std.testing.expect(hasBadDash("Melbourne \xE2\x80\x94 A city located in Victoria, AU."));
    try std.testing.expect(hasBadDash("Gosslens \xE2\x80\x94 Kotlin SDK"));
    // An en-dash between two digits is a numeric range, allowed.
    try std.testing.expect(!hasBadDash("2013\xE2\x80\x9315"));
    try std.testing.expect(!hasBadDash("10\xE2\x80\x9320"));
    // An en-dash anywhere else is flagged too.
    try std.testing.expect(hasBadDash("it stopped \xE2\x80\x93 then it resumed"));
    // A plain hyphen, spaced or in a range, is never a hit.
    try std.testing.expect(!hasBadDash("Melbourne - a city in Victoria, AU."));
    try std.testing.expect(!hasBadDash("a real web page - see the demo"));
}

test "only authored markdown prose is scanned for clause dashes" {
    try std.testing.expect(isMarkdownDoc("README.md"));
    try std.testing.expect(isMarkdownDoc("lenses/format.md"));
    try std.testing.expect(isMarkdownDoc("sdk/ts/README.md"));
    try std.testing.expect(!isMarkdownDoc("docs/private/notes.md"));
    try std.testing.expect(!isMarkdownDoc("core/graph/node.zig"));
    try std.testing.expect(!isMarkdownDoc("adapters/beauty/beauty_shim.cc"));
}

test "column-zero fn lines open a scope, nested and indented ones do not" {
    try std.testing.expectEqualStrings("buildJoltLib", topLevelFnName("fn buildJoltLib(b: *std.Build) void {").?);
    try std.testing.expectEqualStrings("build", topLevelFnName("pub fn build(b: *std.Build) void {").?);
    try std.testing.expect(topLevelFnName("    fn lessThan(_: void) bool {") == null);
    try std.testing.expect(topLevelFnName("const x = fn () void;") == null);
}

test "scope splitting keeps each fn body separate" {
    const text = "const a = 1;\nfn one(x: u32) void {\n  body1;\n}\nfn two() void {\n  body2;\n}\n";
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const scopes = try splitFnScopes(arena_state.allocator(), text);
    try std.testing.expectEqual(@as(usize, 3), scopes.len);
    try std.testing.expectEqualStrings("one", scopes[1].name);
    try std.testing.expect(std.mem.indexOf(u8, scopes[1].body, "body1") != null);
    try std.testing.expect(std.mem.indexOf(u8, scopes[1].body, "body2") == null);
    try std.testing.expectEqualStrings("two", scopes[2].name);
}

test "the flag counts only when it sits outside a per-target conditional" {
    try std.testing.expect(hasUnconditionalNoExceptions("flags.appendSlice(&.{ \"-std=c++17\", \"-fno-exceptions\" });"));
    try std.testing.expect(!hasUnconditionalNoExceptions("if (target.result.cpu.arch.isWasm()) flags.append(\"-fno-exceptions\");"));
    try std.testing.expect(!hasUnconditionalNoExceptions("flags.appendSlice(&.{ \"-std=c++17\", \"-w\" });"));
}

test "balanced parens capture one call's arguments" {
    const text = "addCSourceFile(.{ .file = b.path(\"a.cc\"), .flags = &.{ \"-w\" } }); more()";
    const open = std.mem.indexOfScalar(u8, text, '(').?;
    const args = balancedParens(text, open).?;
    try std.testing.expect(std.mem.indexOf(u8, args, "a.cc") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "more") == null);
}

test "string literals come out of a call's arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const lits = try collectStringLiterals(arena_state.allocator(), ".file = b.path(\"x.mm\"), .flags = &.{ \"-std=c++17\" }");
    try std.testing.expectEqual(@as(usize, 2), lits.len);
    try std.testing.expectEqualStrings("x.mm", lits[0]);
    try std.testing.expectEqualStrings("-std=c++17", lits[1]);
}

test "C++ source extensions are recognized, C and headers are not" {
    try std.testing.expect(isCxxSourcePath("adapters/beauty/beauty_shim.cc"));
    try std.testing.expect(isCxxSourcePath("adapters/physics/jolt_shim.cpp"));
    try std.testing.expect(isCxxSourcePath("adapters/media/video_apple.mm"));
    try std.testing.expect(!isCxxSourcePath("adapters/script/qjs_shim.c"));
    try std.testing.expect(!isCxxSourcePath("include/gosslens.h"));
}

test "consecutive scalar floats are counted, pointers and arrays break the run" {
    // C: a by-pointer group counts as zero; a loose spread counts fully.
    try std.testing.expectEqual(@as(usize, 5), maxConsecutiveScalarFloats("void* h, float r, float g, float b, float a, float width", false));
    try std.testing.expectEqual(@as(usize, 0), maxConsecutiveScalarFloats("void* h, const float* pos, const float* size, uint32_t m", false));
    try std.testing.expectEqual(@as(usize, 2), maxConsecutiveScalarFloats("const float* p, float min_distance, float max_distance", false));
    // A uint between two floats breaks the run.
    try std.testing.expectEqual(@as(usize, 4), maxConsecutiveScalarFloats("float opacity, uint32_t key_mode, float key_r, float key_g, float key_b, float similarity", false));
    // Zig: only a bare f32 counts, not *const [N]f32 or [*]const f32.
    try std.testing.expectEqual(@as(usize, 0), maxConsecutiveScalarFloats("handle: *anyopaque, pos: *const [3]f32, size: *const [3]f32", true));
    try std.testing.expectEqual(@as(usize, 3), maxConsecutiveScalarFloats("a: u32, rest_length: f32, frequency: f32, damping: f32", true));
    try std.testing.expectEqual(@as(usize, 0), maxConsecutiveScalarFloats("verts: [*]const f32, count: u32", true));
}

test "the frozen public spreads are exempt, other names are not" {
    try std.testing.expect(isFrozenSpread("goss_session_brush_set_style"));
    try std.testing.expect(isFrozenSpread("goss_session_ar_brush_set_style"));
    try std.testing.expect(!isFrozenSpread("goss_physics_body_add_oriented"));
    try std.testing.expect(!isFrozenSpread("goss_physics_constrain_spring"));
}

test "C comments are blanked so a paren or float inside one is not a signature" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cleaned = try stripCComments(arena_state.allocator(), "a /* float x( */ b // float y(\nc");
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "float") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, cleaned, '(') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, cleaned, 'c') != null);
}
