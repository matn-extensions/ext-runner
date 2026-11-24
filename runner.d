module matn.extension.runner;

import core.thread : Thread;
import std.algorithm : max, min, clamp, canFind;
import std.conv : to;
import std.file : exists, isFile, isDir;
import std.path : buildPath, dirName, baseName, extension, absolutePath;
import std.process : executeShell, Config;
import std.string : split, splitLines, strip, startsWith;

import matn.platform.sdl;
import matn.platform.font : FontEngine;
import matn.ui.grid.cell;
import matn.ui.grid.grid;
import matn.extension.base;

/// Error or warning location parsed from compiler / runtime output
struct TaskLocation
{
    string filePath;
    int line = 1; // 1-based
    int col = 1;  // 1-based
    bool isValid = false;
}

/// Specification of a runnable command task
struct TaskSpec
{
    string name;
    string command;
    string workDir;
}

struct RunnerContext
{
    int gridCols;
    int gridRows;
    Color bg;
    Color barBg;
    Color text;
    Color muted;
    Color accent;
    Color border;
    Color activeLine;
    bool isLight;

    void delegate(string filePath, int line, int col) onJumpToLocation;
    void delegate(string msg, ExtensionNotifySeverity sev) onNotify;
}

/// Swiss Army Knife Task Runner and Interactive Output Console
class RunnerExtension : Extension, VisualExtension
{
    private bool _visible = false;
    @property bool visible() const { return _visible; }
    @property void visible(bool val) { _visible = val; }
    override @property bool isVisible() const { return isActive && _visible; }

    void toggle()
    {
        _visible = !_visible;
    }

    void open()
    {
        _visible = true;
    }

    void close()
    {
        _visible = false;
    }

    // Task state
    bool isRunning = false;
    bool hasFinished = false;
    int exitCode = 0;
    ulong durationMs = 0;
    string currentTaskName = "";
    string currentCommand = "";
    string currentWorkDir = "";

    // Output buffer
    string[] lines;
    int scrollOffset = 0;
    int selectedLineIdx = -1;

    // Console window layout
    int panelX = 0;
    int panelY = 0;
    int panelW = 0;
    int panelH = 0;

    struct ClickBtn
    {
        int colStart;
        int colEnd;
        int row;
        string id;
    }
    private ClickBtn[] buttons;

    this()
    {
        super(ExtensionManifest(
            "matn.runner",
            "Task Runner & Output Console",
            "1.0.0",
            "Matn Core",
            "Swiss Army Knife task runner, build system, and interactive output console for D and other languages",
            true
        ));
    }

    void clearOutput()
    {
        lines = [];
        scrollOffset = 0;
        selectedLineIdx = -1;
    }

    void runTask(string name, string cmd, string workDir, RunnerContext ctx)
    {
        if (isRunning)
        {
            if (ctx.onNotify)
                ctx.onNotify("Task '" ~ currentTaskName ~ "' is already running", ExtensionNotifySeverity.warning);
            return;
        }

        currentTaskName = name;
        currentCommand = cmd;
        currentWorkDir = workDir;
        lines = [];
        lines ~= "▶ [Task] " ~ name ~ " :: " ~ cmd;
        if (workDir.length > 0)
            lines ~= "  [Directory] " ~ workDir;
        lines ~= "------------------------------------------------------------";

        isRunning = true;
        hasFinished = false;
        exitCode = 0;
        durationMs = 0;
        scrollOffset = 0;
        selectedLineIdx = -1;
        visible = true;

        if (ctx.onNotify)
            ctx.onNotify("▶ Running " ~ name ~ "...", ExtensionNotifySeverity.info);

        ulong startTicks = SDL_GetTicks();

        auto thr = new Thread({
            try
            {
                auto res = executeShell(cmd, null, Config.none, size_t.max, workDir.length ? workDir : null);
                ulong dur = SDL_GetTicks() - startTicks;
                durationMs = dur;
                exitCode = res.status;

                foreach (ln; res.output.splitLines())
                {
                    lines ~= ln;
                }
                lines ~= "------------------------------------------------------------";

                string durStr = (dur >= 1000)
                    ? (to!string(dur / 1000) ~ "." ~ to!string((dur % 1000) / 100) ~ "s")
                    : (to!string(dur) ~ "ms");

                if (res.status == 0)
                {
                    lines ~= "✓ Completed successfully in " ~ durStr ~ " (exit code 0)";
                    if (ctx.onNotify)
                        ctx.onNotify("✓ " ~ name ~ " passed in " ~ durStr, ExtensionNotifySeverity.info);
                }
                else
                {
                    lines ~= "✗ Failed with exit code " ~ to!string(res.status) ~ " in " ~ durStr;
                    if (ctx.onNotify)
                        ctx.onNotify("✗ " ~ name ~ " failed (exit code " ~ to!string(res.status) ~ ")", ExtensionNotifySeverity.error);
                }
                hasFinished = true;
                isRunning = false;

                // Auto-scroll to bottom of output
                if (lines.length > 10)
                    scrollOffset = max(0, cast(int) lines.length - 10);
            }
            catch (Exception e)
            {
                lines ~= "[Error] " ~ e.msg;
                hasFinished = true;
                isRunning = false;
                exitCode = -1;
            }
        });
        thr.isDaemon = true;
        thr.start();
    }

    void reRun(RunnerContext ctx)
    {
        if (currentCommand.length > 0)
        {
            runTask(currentTaskName, currentCommand, currentWorkDir, ctx);
        }
    }

    static TaskSpec detectRunTask(string filePath, string projectRoot)
    {
        string ext = filePath.extension;

        // 1. D Language
        if (ext == ".d" || exists(buildPath(projectRoot, "dub.json")) || exists(buildPath(projectRoot, "dub.sdl")))
        {
            if (exists(buildPath(projectRoot, "dub.json")) || exists(buildPath(projectRoot, "dub.sdl")))
                return TaskSpec("DUB Run", "dub run", projectRoot);
            else if (filePath.length > 0)
                return TaskSpec("RDMD Run", "rdmd \"" ~ filePath ~ "\"", dirName(filePath));
        }

        // 2. Rust
        if (ext == ".rs" || exists(buildPath(projectRoot, "Cargo.toml")))
        {
            if (exists(buildPath(projectRoot, "Cargo.toml")))
                return TaskSpec("Cargo Run", "cargo run", projectRoot);
            else if (filePath.length > 0)
                return TaskSpec("Rust Run", "rustc \"" ~ filePath ~ "\" -o /tmp/matn_rust_out && /tmp/matn_rust_out", dirName(filePath));
        }

        // 3. Python
        if (ext == ".py")
        {
            return TaskSpec("Python Run", "python3 \"" ~ filePath ~ "\"", dirName(filePath));
        }

        // 4. Go
        if (ext == ".go" || exists(buildPath(projectRoot, "go.mod")))
        {
            if (exists(buildPath(projectRoot, "go.mod")))
                return TaskSpec("Go Run", "go run .", projectRoot);
            else if (filePath.length > 0)
                return TaskSpec("Go Run", "go run \"" ~ filePath ~ "\"", dirName(filePath));
        }

        // 5. C / C++
        if (ext == ".c")
        {
            if (exists(buildPath(projectRoot, "Makefile")))
                return TaskSpec("Make", "make", projectRoot);
            return TaskSpec("C Run", "gcc -Wall -O2 \"" ~ filePath ~ "\" -o /tmp/matn_c_out && /tmp/matn_c_out", dirName(filePath));
        }
        if (ext == ".cpp" || ext == ".cc" || ext == ".cxx")
        {
            if (exists(buildPath(projectRoot, "Makefile")))
                return TaskSpec("Make", "make", projectRoot);
            return TaskSpec("C++ Run", "g++ -Wall -O2 \"" ~ filePath ~ "\" -o /tmp/matn_cpp_out && /tmp/matn_cpp_out", dirName(filePath));
        }

        // 6. Zig
        if (ext == ".zig" || exists(buildPath(projectRoot, "build.zig")))
        {
            if (exists(buildPath(projectRoot, "build.zig")))
                return TaskSpec("Zig Run", "zig build run", projectRoot);
            else if (filePath.length > 0)
                return TaskSpec("Zig Run", "zig run \"" ~ filePath ~ "\"", dirName(filePath));
        }

        // 7. Shell
        if (ext == ".sh" || ext == ".bash")
        {
            return TaskSpec("Shell Run", "sh \"" ~ filePath ~ "\"", dirName(filePath));
        }

        // 8. JS / TS
        if (ext == ".js" || ext == ".ts")
        {
            if (exists(buildPath(projectRoot, "package.json")))
                return TaskSpec("NPM Start", "npm start", projectRoot);
            return TaskSpec("Node Run", "node \"" ~ filePath ~ "\"", dirName(filePath));
        }

        return TaskSpec("Run", "echo 'No runnable configuration detected'", projectRoot);
    }

    static TaskSpec detectBuildTask(string filePath, string projectRoot)
    {
        if (exists(buildPath(projectRoot, "dub.json")) || exists(buildPath(projectRoot, "dub.sdl")) || filePath.extension == ".d")
            return TaskSpec("DUB Build", "dub build", projectRoot);
        if (exists(buildPath(projectRoot, "Cargo.toml")) || filePath.extension == ".rs")
            return TaskSpec("Cargo Build", "cargo build", projectRoot);
        if (exists(buildPath(projectRoot, "go.mod")) || filePath.extension == ".go")
            return TaskSpec("Go Build", "go build", projectRoot);
        if (exists(buildPath(projectRoot, "Makefile")))
            return TaskSpec("Make Build", "make", projectRoot);
        if (exists(buildPath(projectRoot, "CMakeLists.txt")))
            return TaskSpec("CMake Build", "cmake --build build", projectRoot);
        if (exists(buildPath(projectRoot, "build.zig")))
            return TaskSpec("Zig Build", "zig build", projectRoot);
        return TaskSpec("Build", "echo 'No build configuration found'", projectRoot);
    }

    static TaskSpec detectTestTask(string filePath, string projectRoot)
    {
        if (exists(buildPath(projectRoot, "dub.json")) || exists(buildPath(projectRoot, "dub.sdl")) || filePath.extension == ".d")
            return TaskSpec("DUB Test", "dub test", projectRoot);
        if (exists(buildPath(projectRoot, "Cargo.toml")) || filePath.extension == ".rs")
            return TaskSpec("Cargo Test", "cargo test", projectRoot);
        if (exists(buildPath(projectRoot, "go.mod")) || filePath.extension == ".go")
            return TaskSpec("Go Test", "go test ./...", projectRoot);
        if (filePath.extension == ".py")
            return TaskSpec("Pytest", "pytest", projectRoot);
        if (exists(buildPath(projectRoot, "Makefile")))
            return TaskSpec("Make Test", "make test", projectRoot);
        return TaskSpec("Test", "echo 'No test runner found'", projectRoot);
    }

    static TaskLocation parseLocation(string line, string projectRoot)
    {
        TaskLocation loc;
        loc.isValid = false;
        if (line.length == 0) return loc;

        // 1. D / C++ format: path/file.d(123,45): or path/file.d(123):
        int parenOpen = -1;
        int parenClose = -1;
        int colonAfter = -1;
        foreach (i, c; line)
        {
            if (c == '(' && parenOpen == -1) parenOpen = cast(int) i;
            else if (c == ')' && parenOpen != -1 && parenClose == -1) parenClose = cast(int) i;
            else if (c == ':' && parenClose != -1) { colonAfter = cast(int) i; break; }
        }
        if (parenOpen > 0 && parenClose > parenOpen && colonAfter > parenClose)
        {
            string filePart = line[0 .. parenOpen].strip();
            string numPart = line[parenOpen + 1 .. parenClose];
            auto parts = numPart.split(",");
            if (parts.length >= 1)
            {
                try
                {
                    int l = to!int(parts[0].strip());
                    int c = (parts.length >= 2) ? to!int(parts[1].strip()) : 1;
                    string resolved = filePart;
                    if (!exists(resolved) && projectRoot.length > 0)
                        resolved = buildPath(projectRoot, filePart);
                    loc.filePath = resolved;
                    loc.line = l;
                    loc.col = c;
                    loc.isValid = true;
                    return loc;
                }
                catch (Exception) {}
            }
        }

        // 2. Rust / GCC / Clang / Go format: path/file.rs:123:45:
        auto colons = line.split(":");
        if (colons.length >= 3)
        {
            string filePart = colons[0].strip();
            try
            {
                int l = to!int(colons[1].strip());
                int c = to!int(colons[2].strip());
                string resolved = filePart;
                if (!exists(resolved) && projectRoot.length > 0)
                    resolved = buildPath(projectRoot, filePart);
                loc.filePath = resolved;
                loc.line = l;
                loc.col = c;
                loc.isValid = true;
                return loc;
            }
            catch (Exception) {}
        }

        return loc;
    }

    void render(GlyphGrid grid, RunnerContext ctx)
    {
        if (!isVisible || grid is null) return;

        buttons = [];

        // Bottom docked panel with clean dimensions
        panelW = clamp(cast(int)(ctx.gridCols * 0.94), 60, ctx.gridCols - 2);
        panelH = clamp(cast(int)(ctx.gridRows * 0.44), 10, ctx.gridRows - 4);
        panelX = max(0, (ctx.gridCols - panelW) / 2);
        panelY = max(0, ctx.gridRows - panelH - 1);

        bool isLight = ctx.isLight || ctx.bg.isLight;
        Color cardBg = ctx.barBg;
        Color headerBg = isLight ? ctx.barBg.darken(6) : ctx.barBg.lighten(6);
        Color selRowBg = ctx.activeLine;
        Color errColor = isLight ? Color(200, 30, 40, 255) : Color(245, 90, 100, 255);
        Color warnColor = isLight ? Color(180, 110, 10, 255) : Color(245, 185, 80, 255);
        Color successColor = isLight ? Color(30, 140, 70, 255) : Color(110, 225, 140, 255);

        // 1. Fill background
        grid.fillRect(panelX, panelY, panelW, panelH, ' ', CellStyle(ctx.text, cardBg));

        // 2. Header Bar
        grid.fillRect(panelX, panelY, panelW, 1, ' ', CellStyle(ctx.text, headerBg));

        // Title and status
        string statusBadge = isRunning ? "▶ RUNNING" : (hasFinished ? (exitCode == 0 ? "✓ SUCCESS" : "✗ FAILED") : "CONSOLE");
        Color statusColor = isRunning ? ctx.accent : (hasFinished ? (exitCode == 0 ? successColor : errColor) : ctx.muted);

        grid.putString(panelX + 1, panelY, to!dstring(statusBadge), CellStyle(statusColor, headerBg, CellAttr.bold));
        int curCol = panelX + 2 + cast(int) statusBadge.length;

        if (currentTaskName.length > 0)
        {
            string taskPill = " [" ~ currentTaskName ~ "] ";
            grid.putString(curCol, panelY, to!dstring(taskPill), CellStyle(ctx.text, headerBg, CellAttr.bold));
            curCol += cast(int) taskPill.length;
        }

        if (durationMs > 0)
        {
            string durStr = (durationMs >= 1000)
                ? (to!string(durationMs / 1000) ~ "." ~ to!string((durationMs % 1000) / 100) ~ "s")
                : (to!string(durationMs) ~ "ms");
            grid.putString(curCol, panelY, to!dstring("(" ~ durStr ~ ")"), CellStyle(ctx.muted, headerBg));
        }

        // Action buttons on right: [↺ Re-run] [󰅖 Clear] [✕ Close]
        int rightCol = panelX + panelW - 1;

        // [✕]
        rightCol -= 3;
        grid.putString(rightCol, panelY, "[✕]"d, CellStyle(ctx.muted, headerBg, CellAttr.bold));
        buttons ~= ClickBtn(rightCol, rightCol + 3, panelY, "close");
        rightCol -= 1;

        // [Clear]
        rightCol -= 7;
        grid.putString(rightCol, panelY, "[Clear]"d, CellStyle(ctx.muted, headerBg));
        buttons ~= ClickBtn(rightCol, rightCol + 7, panelY, "clear");
        rightCol -= 1;

        // [Re-run]
        rightCol -= 8;
        grid.putString(rightCol, panelY, "[Re-run]"d, CellStyle(ctx.accent, headerBg, CellAttr.bold));
        buttons ~= ClickBtn(rightCol, rightCol + 8, panelY, "rerun");

        // 3. Output Lines
        int viewH = max(1, panelH - 2);
        if (lines.length == 0)
        {
            grid.putString(panelX + 2, panelY + 2, "Ready. Press F5 to run current file or project."d, CellStyle(ctx.muted, cardBg));
            return;
        }

        scrollOffset = clamp(scrollOffset, 0, max(0, cast(int) lines.length - viewH));

        foreach (r; 0 .. viewH)
        {
            int lineIdx = scrollOffset + r;
            if (lineIdx >= lines.length) break;

            int rowY = panelY + 1 + r;
            string ln = lines[lineIdx];
            bool isSel = (lineIdx == selectedLineIdx);

            Color rowBg = isSel ? selRowBg : cardBg;
            Color rowFg = ctx.text;
            ubyte rowAttr = isSel ? CellAttr.bold : CellAttr.none;

            if (ln.canFind("Error:") || ln.canFind("error:") || ln.canFind("FAILED") || ln.canFind("✗"))
            {
                rowFg = errColor;
                rowAttr = CellAttr.bold;
            }
            else if (ln.canFind("Warning:") || ln.canFind("warning:"))
            {
                rowFg = warnColor;
            }
            else if (ln.canFind("✓") || ln.canFind("success") || ln.canFind("PASSED"))
            {
                rowFg = successColor;
            }
            else if (ln.startsWith("▶") || ln.startsWith("["))
            {
                rowFg = ctx.accent;
            }

            if (isSel)
            {
                grid.fillRect(panelX + 1, rowY, panelW - 2, 1, ' ', CellStyle(rowFg, rowBg));
            }

            int availChars = panelW - 4;
            if (ln.length > availChars)
                ln = ln[0 .. availChars - 1] ~ "…";

            grid.putString(panelX + 2, rowY, to!dstring(ln), CellStyle(rowFg, rowBg, rowAttr));
        }

        // Scroll indicator
        if (lines.length > viewH)
        {
            int barY = panelY + 1 + (scrollOffset * viewH) / max(1, cast(int) lines.length);
            grid.putCell(panelX + panelW - 2, clamp(barY, panelY + 1, panelY + panelH - 2), '█', CellStyle(ctx.muted, cardBg));
        }
    }

    void renderReal(SDL_Renderer* renderer, FontEngine font, float padX, float padY, Color accentCol, Color borderCol)
    {
        if (!isVisible || renderer is null) return;

        SDL_FRect r;
        r.x = padX + panelX * font.charWidth;
        r.y = padY + panelY * font.lineHeight;
        r.w = panelW * font.charWidth;
        r.h = panelH * font.lineHeight;

        SDL_SetRenderDrawColor(renderer, borderCol.r, borderCol.g, borderCol.b, 255);
        SDL_RenderRect(renderer, &r);
    }

    bool handleMouseMove(int col, int row, RunnerContext ctx)
    {
        if (!isVisible) return false;

        if (col >= panelX && col < panelX + panelW && row >= panelY && row < panelY + panelH)
        {
            if (row > panelY && row < panelY + panelH - 1)
            {
                int lineIdx = scrollOffset + (row - panelY - 1);
                if (lineIdx >= 0 && lineIdx < lines.length)
                    selectedLineIdx = lineIdx;
            }
            return true;
        }
        return false;
    }

    bool handleMouseDown(int col, int row, RunnerContext ctx, string projectRoot)
    {
        if (!isVisible) return false;

        // Check if inside panel
        if (col < panelX || col >= panelX + panelW || row < panelY || row >= panelY + panelH)
        {
            return false;
        }

        // Header buttons
        if (row == panelY)
        {
            foreach (ref btn; buttons)
            {
                if (col >= btn.colStart && col < btn.colEnd)
                {
                    switch (btn.id)
                    {
                    case "close":
                        close();
                        return true;
                    case "clear":
                        clearOutput();
                        return true;
                    case "rerun":
                        reRun(ctx);
                        return true;
                    default:
                        break;
                    }
                }
            }
            return true;
        }

        // Click on output line: try to jump to location
        int lineIdx = scrollOffset + (row - panelY - 1);
        if (lineIdx >= 0 && lineIdx < lines.length)
        {
            selectedLineIdx = lineIdx;
            auto loc = parseLocation(lines[lineIdx], projectRoot);
            if (loc.isValid && ctx.onJumpToLocation)
            {
                ctx.onJumpToLocation(loc.filePath, loc.line - 1, loc.col - 1);
                return true;
            }
        }

        return true;
    }

    bool handleKeyDown(uint key, uint mod, RunnerContext ctx, string projectRoot)
    {
        if (!isVisible) return false;

        int viewH = max(1, panelH - 2);

        if (key == 0x1b) // ESC
        {
            close();
            return true;
        }
        else if (key == 0x40000052) // UP
        {
            scrollOffset = max(0, scrollOffset - 1);
            return true;
        }
        else if (key == 0x40000051) // DOWN
        {
            scrollOffset = min(max(0, cast(int) lines.length - viewH), scrollOffset + 1);
            return true;
        }
        else if (key == 0x4000004b) // PAGEUP
        {
            scrollOffset = max(0, scrollOffset - viewH);
            return true;
        }
        else if (key == 0x4000004e) // PAGEDOWN
        {
            scrollOffset = min(max(0, cast(int) lines.length - viewH), scrollOffset + viewH);
            return true;
        }
        else if (key == 0x4000004a) // HOME
        {
            scrollOffset = 0;
            return true;
        }
        else if (key == 0x4000004d) // END
        {
            scrollOffset = max(0, cast(int) lines.length - viewH);
            return true;
        }
        else if (key == 13 || key == 0x40000058) // ENTER
        {
            if (selectedLineIdx >= 0 && selectedLineIdx < lines.length)
            {
                auto loc = parseLocation(lines[selectedLineIdx], projectRoot);
                if (loc.isValid && ctx.onJumpToLocation)
                {
                    ctx.onJumpToLocation(loc.filePath, loc.line - 1, loc.col - 1);
                    return true;
                }
            }
            return true;
        }

        return false;
    }

    void handleMouseWheel(int wheelY)
    {
        if (!isVisible) return;
        int viewH = max(1, panelH - 2);
        scrollOffset = clamp(scrollOffset - wheelY * 3, 0, max(0, cast(int) lines.length - viewH));
    }
}

unittest
{
    auto runner = new RunnerExtension();
    assert(runner.manifest.id == "matn.runner");
    assert(!runner.visible);

    runner.open();
    assert(runner.visible);
    runner.close();
    assert(!runner.visible);

    // Test location parser
    auto loc1 = RunnerExtension.parseLocation("source/app.d(12,5): Error: undefined identifier", "");
    assert(loc1.line == 12);
    assert(loc1.col == 5);

    auto loc2 = RunnerExtension.parseLocation("src/main.rs:42:10: error[E0425]: cannot find value", "");
    assert(loc2.line == 42);
    assert(loc2.col == 10);

    // Test task detector
    auto t1 = RunnerExtension.detectRunTask("app.d", "/tmp/dproj");
    assert(t1.command.canFind("rdmd") || t1.command.canFind("dub"));

    auto t2 = RunnerExtension.detectRunTask("main.py", "/tmp/pyproj");
    assert(t2.command.canFind("python3"));

    auto t3 = RunnerExtension.detectRunTask("main.rs", "/tmp/rsproj");
    assert(t3.command.canFind("cargo") || t3.command.canFind("rustc"));
}
