const std = @import("std");
const process = @import("process_support.zig");

fn bash(script: [*:0]const u8) !process.Result {
    const args = [_:null]?[*:0]const u8{ "bash", "-c", script };
    return process.run(&args, null);
}

test "Bash flag completion and argument positions" {
    const result = try bash(
        \\source completions/zsqt.bash
        \\COMP_WORDS=(zsqt --d); COMP_CWORD=1; _zsqt_complete
        \\test "${#COMPREPLY[@]}" -eq 1 && test "${COMPREPLY[0]}" = --debug || exit 1
        \\COMP_WORDS=(zsqt --); COMP_CWORD=1; _zsqt_complete
        \\test "${#COMPREPLY[@]}" -eq 4 || exit 5
        \\COMP_WORDS=(zsqt --r); COMP_CWORD=1; _zsqt_complete
        \\test "${#COMPREPLY[@]}" -eq 1 && test "${COMPREPLY[0]}" = --recover || exit 2
        \\COMP_WORDS=(zsqt --debug --); COMP_CWORD=2; _zsqt_complete
        \\test "${#COMPREPLY[@]}" -eq 0 || exit 3
        \\COMP_WORDS=(zsqt --check READ); COMP_CWORD=2; _zsqt_complete
        \\test "${COMPREPLY[0]}" = README.md || exit 4
    );
    if (result.status != 0) std.debug.print("{s}\n{s}\n", .{ result.out(), result.err() });
    try std.testing.expectEqual(@as(c_int, 0), result.status);
}

test "completion definitions list supported flags" {
    const result = try bash(
        \\for file in completions/zsqt.bash completions/_zsqt completions/zsqt.fish; do
        \\  for flag in check recover debug help; do
        \\    grep -q -- "$flag" "$file" || exit 1
        \\  done
        \\done
    );
    try std.testing.expectEqual(@as(c_int, 0), result.status);
}
