package shader_reflection

import "core:os"
import "core:testing"

@(test)
shader_reflection_targets :: proc(t: ^testing.T) {
	command := [?]string{"odin", "run", "tests/shader_reflection_runner"}
	state, stdout, stderr, err := os.process_exec({command = command[:]}, context.allocator)
	defer delete(stdout)
	defer delete(stderr)

	testing.expectf(t, err == nil, "failed to run shader reflection runner: %v", err)
	testing.expectf(
		t,
		state.exited && state.exit_code == 0,
		"shader reflection runner failed: exit=%d stdout=%s stderr=%s",
		state.exit_code,
		string(stdout),
		string(stderr),
	)
}
