package compile

import "fmt"

// RunsOnTarget is what a GitHub Actions `runs-on:` label compiles to: a
// CircleCI machine executor (act needs a real Docker daemon to launch its own
// per-step containers, which is why the act orb's own default job template
// uses `machine:`, not `docker:` — see cci-labs/act@1.0.5's `act` job,
// executor `default` (machine, image ubuntu-2404:current)) plus the
// `--platform <label>=<image>` mapping act itself needs to pick a container
// image for the *inner* job it runs.
type RunsOnTarget struct {
	MachineImage  string // CircleCI machine executor image
	ResourceClass string // CircleCI resource_class
	ActPlatform   string // value for act's --platform label=image, e.g. "ubuntu-latest=catthehacker/ubuntu:act-latest"
}

// unsupportedRunsOn marks a label we recognize by name but deliberately do
// not map, with a human reason — distinct from a label we've simply never
// heard of. Both are hard errors; only the message differs.
type unsupportedRunsOn struct {
	reason string
}

// runsOnTable is the explicit, closed mapping. Anything not a key here is a
// hard compile error — never a best-effort guess. Extend this table as the
// bridge-orb team decides to support more labels; do not add fallback logic.
var runsOnTable = map[string]any{
	"ubuntu-latest": RunsOnTarget{
		MachineImage:  "ubuntu-2404:current",
		ResourceClass: "medium",
		ActPlatform:   "ubuntu-latest=catthehacker/ubuntu:act-latest",
	},
	"ubuntu-24.04": RunsOnTarget{
		MachineImage:  "ubuntu-2404:current",
		ResourceClass: "medium",
		ActPlatform:   "ubuntu-24.04=catthehacker/ubuntu:act-24.04",
	},
	"ubuntu-22.04": RunsOnTarget{
		MachineImage:  "ubuntu-2204:current",
		ResourceClass: "medium",
		ActPlatform:   "ubuntu-22.04=catthehacker/ubuntu:act-22.04",
	},
	"ubuntu-20.04": RunsOnTarget{
		MachineImage:  "ubuntu-2004:current",
		ResourceClass: "medium",
		ActPlatform:   "ubuntu-20.04=catthehacker/ubuntu:act-20.04",
	},

	// Explicitly-considered, explicitly-refused labels. Listed by name so a
	// user gets "here is why," not "label not found."
	"windows-latest": unsupportedRunsOn{reason: "act cannot execute a Windows job from a Linux Docker host; there is no CircleCI executor that changes this. Out of MVP scope."},
	"windows-2022":   unsupportedRunsOn{reason: "act cannot execute a Windows job from a Linux Docker host; there is no CircleCI executor that changes this. Out of MVP scope."},
	"macos-latest":   unsupportedRunsOn{reason: "act has no macOS container runtime; a CircleCI macOS executor exists but act does not run on it. Out of MVP scope."},
	"macos-14":       unsupportedRunsOn{reason: "act has no macOS container runtime; a CircleCI macOS executor exists but act does not run on it. Out of MVP scope."},
	"self-hosted":    unsupportedRunsOn{reason: "self-hosted runner labels have no meaning on CircleCI; this compiler only maps GitHub-hosted runner labels to CircleCI executors."},
}

// ResolveRunsOn maps a single GitHub `runs-on:` label to a CircleCI executor.
// It never guesses: an unrecognized label is an error naming the label; a
// recognized-but-refused label is an error naming the reason.
func ResolveRunsOn(label string) (RunsOnTarget, error) {
	v, ok := runsOnTable[label]
	if !ok {
		return RunsOnTarget{}, fmt.Errorf(
			"runs-on %q has no entry in the compiler's runs-on mapping table. "+
				"This is a closed, explicit table (internal/compile/runson.go) — "+
				"add a mapping there deliberately, or use a supported label (%s)",
			label, supportedLabelsList())
	}
	switch t := v.(type) {
	case RunsOnTarget:
		return t, nil
	case unsupportedRunsOn:
		return RunsOnTarget{}, fmt.Errorf("runs-on %q is explicitly unsupported: %s", label, t.reason)
	default:
		panic("unreachable")
	}
}

func supportedLabelsList() string {
	out := ""
	for _, l := range []string{"ubuntu-latest", "ubuntu-24.04", "ubuntu-22.04", "ubuntu-20.04"} {
		if out != "" {
			out += ", "
		}
		out += l
	}
	return out
}
