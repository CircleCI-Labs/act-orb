package compile

import (
	"fmt"
	"sort"
	"strings"
)

// RunsOnTarget is what a GitHub Actions `runs-on:` label compiles to: a
// CircleCI machine executor (act needs a real Docker daemon to launch its own
// per-step containers, which is why the act orb's own default job template
// uses `machine:`, not `docker:` — see cci-labs/act@1.0.5's `act` job,
// executor `default` (machine, image ubuntu-2404:current)) plus the
// `--platform <label>=<image>` mapping act itself needs to pick a container
// image for the *inner* job it runs.
type RunsOnTarget struct {
	MachineImage  string // CircleCI machine executor image; empty for a self-hosted runner (SelfHosted true)
	ResourceClass string // CircleCI resource_class
	ActPlatform   string // value for act's --platform label=image, e.g. "ubuntu-latest=catthehacker/ubuntu:act-latest"
	SelfHosted    bool   // render `machine: true` (no image:) instead of `machine: {image: ...}` — see ResolveSelfHostedRunsOn
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

	// "self-hosted" is deliberately NOT a key here — bare `runs-on:
	// self-hosted` and list-form `runs-on: [self-hosted, ...]` are both
	// routed to ResolveSelfHostedRunsOn below instead, since CircleCI DOES
	// have a real equivalent (self-hosted runner resource classes) once a
	// runner namespace is known. See that function's doc comment. Calling
	// ResolveRunsOn("self-hosted") directly (nobody should) falls through
	// to the generic "no entry in the table" branch, which is correct: this
	// particular table is GitHub-hosted-label-only by design.
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

// selfHostedNamespace is the CircleCI runner namespace ("orgname" in
// "orgname/linux-x64") this compile run should resolve self-hosted `runs-on:`
// labels against. Package-level for simplicity in this prototype, same
// pattern as sourceWorkflowRelPath (render.go) — set once via
// SetSelfHostedNamespace before calling Compile.
var selfHostedNamespace string

// SetSelfHostedNamespace configures the CircleCI runner namespace used to
// resolve `runs-on: self-hosted` / `runs-on: [self-hosted, ...]` into a
// resource_class (see ResolveSelfHostedRunsOn). Leaving it unset means any
// self-hosted runs-on in the workflow is a hard compile error naming why.
func SetSelfHostedNamespace(ns string) { selfHostedNamespace = ns }

// selfHostedExtraLabels are the only GitHub runner labels, besides the
// literal "self-hosted" label itself, this compiler knows how to fold into
// a CircleCI resource-class name. This is deliberately closed: an
// unrecognized extra label is a hard error, never a guess.
var selfHostedExtraLabels = map[string]bool{
	"linux": true, "x64": true, "arm64": true, "arm": true, "x86": true,
}

// ResolveSelfHostedRunsOn maps GitHub's self-hosted `runs-on:` convention —
// a bare "self-hosted" label, or a label list like
// `[self-hosted, linux, x64]` — onto a CircleCI self-hosted runner
// resource_class (`machine: true` + `resource_class: <namespace>/<name>`;
// see circleci.com/docs/reference/configuration-reference/#resourceclass,
// "Self-hosted runner").
//
// CircleCI resource classes are created per-organization with whatever
// name that organization chose (there is no universal label->resource-
// class mapping this compiler could look up) — so it CANNOT know your
// actual resource class name. Rather than guess, this function requires a
// namespace to be configured (SetSelfHostedNamespace /
// --self-hosted-namespace) and then applies one explicit, documented
// naming convention: the extra labels (everything except "self-hosted"
// itself), sorted and dash-joined, or literally "self-hosted" when there
// are none — e.g. `[self-hosted, linux, x64]` with namespace "acme" becomes
// resource_class "acme/linux-x64". Your organization's actual self-hosted
// resource classes must be named to match this convention (see
// tools/ghac/README.md) — this function does not and cannot verify that
// against your real CircleCI account at compile time; a mismatched name
// just means the generated job queues forever waiting for a runner, the
// same failure mode as a typo'd resource_class in hand-written config.
//
// Only labels this function actually recognizes ever reach that naming
// convention: an extra label outside selfHostedExtraLabels is a hard
// error (nothing to fall back to). Windows/macOS self-hosted labels get
// their own explicit reason, mirroring windows-latest/macos-latest above:
// act needs a Linux Docker host to run job steps no matter which machine
// the CircleCI self-hosted runner itself is, so a self-hosted target
// that isn't Linux is refused the same way, not silently attempted.
func ResolveSelfHostedRunsOn(labels []string) (RunsOnTarget, error) {
	hasSelfHosted := false
	var extra []string
	for _, raw := range labels {
		l := strings.ToLower(raw)
		if l == "self-hosted" {
			hasSelfHosted = true
			continue
		}
		extra = append(extra, l)
	}
	if !hasSelfHosted {
		return RunsOnTarget{}, fmt.Errorf(
			"runs-on: %v is a label list without \"self-hosted\" in it — this compiler only resolves "+
				"runs-on: lists for the self-hosted-runner convention; a custom label list that isn't "+
				"targeting a self-hosted runner has no entry in the mapping table (runson.go)", labels)
	}
	for _, l := range extra {
		switch l {
		case "windows", "windows-latest", "windows-2022":
			return RunsOnTarget{}, fmt.Errorf(
				"runs-on: %v requests a Windows self-hosted runner — act cannot execute a Windows job "+
					"from a Linux Docker host, the same limitation as windows-latest/windows-2022 for "+
					"GitHub-hosted runners. Out of MVP scope.", labels)
		case "macos", "macos-latest", "macos-14":
			return RunsOnTarget{}, fmt.Errorf(
				"runs-on: %v requests a macOS self-hosted runner — act has no macOS container runtime, "+
					"the same limitation as macos-latest/macos-14 for GitHub-hosted runners. Out of MVP scope.",
				labels)
		}
	}
	hasLinux := false
	for _, l := range extra {
		if !selfHostedExtraLabels[l] {
			return RunsOnTarget{}, fmt.Errorf(
				"runs-on: %v includes the self-hosted label %q, which this compiler doesn't know how to "+
					"fold into a CircleCI resource-class name (only linux/x64/arm64/arm/x86 are recognized "+
					"alongside self-hosted — see selfHostedExtraLabels in runson.go). Add it there "+
					"deliberately, or use a recognized label", labels, l)
		}
		if l == "linux" {
			hasLinux = true
		}
	}
	if len(extra) > 0 && !hasLinux {
		return RunsOnTarget{}, fmt.Errorf(
			"runs-on: %v does not include a \"linux\" label — act needs a Linux Docker host to run job "+
				"steps regardless of which machine the CircleCI self-hosted runner itself is, and this "+
				"compiler won't assume that without an explicit linux label", labels)
	}
	if selfHostedNamespace == "" {
		return RunsOnTarget{}, fmt.Errorf(
			"runs-on: %v targets a self-hosted runner, but no CircleCI runner namespace was configured "+
				"for this compile (pass --self-hosted-namespace to ghac compile / gha-render-job) — there "+
				"is no way to derive a resource_class without knowing your organization's runner namespace",
			labels)
	}
	sort.Strings(extra)
	name := "self-hosted"
	if len(extra) > 0 {
		name = strings.Join(extra, "-")
	}
	return RunsOnTarget{
		ResourceClass: selfHostedNamespace + "/" + name,
		// act still needs a Linux container image to launch each step's own
		// container in, independent of which physical machine is running the
		// CircleCI job itself — the self-hosted machine only needs to supply
		// a working Docker daemon (the same requirement machine-runner's own
		// docs already put on the runner operator).
		ActPlatform: "ubuntu-latest=catthehacker/ubuntu:act-latest",
		SelfHosted:  true,
	}, nil
}
