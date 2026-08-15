// Package compile implements the GitHub Actions workflow -> CircleCI config
// compiler prototype described in gha-capability-spikes/workflow-compiler.
//
// Scope (MVP): multi-job workflows connected only by `needs:`. See the
// top-level README for the full supported/rejected/no-silent-gaps table.
package compile

import (
	"bytes"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// actOrbVersion pins the act orb version the generated config's `act/act`
// and `act/gha-render-job` steps resolve against. Provisionally the dev tag
// this feature itself ships under (cci-labs/act@dev:upgrade-bridge-family-parity)
// -- `act/gha-render-job` does not exist in any published stable release yet
// (this compiler and that command landed together), so a stable version pin
// would make every compiled config fail to resolve. TODO once this lands on
// main and gets a real release: bump this to that stable version and drop
// the "provisionally" above -- tracked in tools/ghac/README.md.
const actOrbVersion = "cci-labs/act@dev:upgrade-bridge-family-parity"

// Job is one compiled GitHub Actions job.
type Job struct {
	ID          string
	Node        *yaml.Node // deep copy of this job's original mapping node
	RunsOnLabel string
	Executor    RunsOnTarget
	Needs       []string
	Filter      *BranchFilter
	Outputs     map[string]string // output name -> raw "${{ steps.X.outputs.Y }}" expression
	NeedsUsed   []NeedsOutputRef  // needs.*.outputs.* refs found in this job's own steps
}

// Result is everything the compiler produced from one workflow file.
type Result struct {
	// ConfigYAML is the generated CircleCI config.yml body (the config that
	// would be POSTed to the continuation API).
	ConfigYAML string
	// GeneratedWorkflows maps "generated/<job-id>.yml" -> file content. These
	// are the per-job, needs-stripped, needs.*-rewritten workflow files that
	// each compiled CircleCI job hands to `act/act` via workflow-file:.
	// They must be persisted to the CircleCI workspace by the setup job
	// (see docs/setup-config.yml) so downstream jobs can attach_workspace
	// and find them.
	GeneratedWorkflows map[string]string
	// Jobs is exposed for tests/introspection.
	Jobs []*Job
}

// UnsupportedError is returned for any construct explicitly out of MVP
// scope. Its message always names the construct and the job/field it was
// found in — never a bare "compile failed."
type UnsupportedError struct{ msg string }

func (e *UnsupportedError) Error() string { return e.msg }

func unsupported(format string, args ...any) error {
	return &UnsupportedError{msg: fmt.Sprintf(format, args...)}
}

var reOutputExpr = regexp.MustCompile(`^\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)\s*\}\}$`)

// Compile reads raw GitHub Actions workflow YAML and produces a CircleCI
// config plus the per-job workflow files it depends on.
func Compile(workflowYAML []byte, sourcePath string) (*Result, error) {
	var doc yaml.Node
	if err := yaml.Unmarshal(workflowYAML, &doc); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", sourcePath, err)
	}
	if len(doc.Content) == 0 {
		return nil, fmt.Errorf("%s: empty document", sourcePath)
	}
	root := doc.Content[0]
	if root.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("%s: top level must be a mapping", sourcePath)
	}

	if mapGet(root, "concurrency") != nil {
		return nil, unsupported("workflow-level concurrency: is out of MVP scope (no CircleCI equivalent is wired up yet)")
	}
	if mapGet(root, "permissions") != nil {
		return nil, unsupported("workflow-level permissions: is out of MVP scope")
	}

	jobsNode := mapGet(root, "jobs")
	if jobsNode == nil || jobsNode.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("%s: no jobs: mapping found", sourcePath)
	}

	jobIDs := mapKeys(jobsNode)
	jobs := make([]*Job, 0, len(jobIDs))
	byID := map[string]*Job{}

	for _, id := range jobIDs {
		jn := mapGet(jobsNode, id)
		if jn.Kind != yaml.MappingNode {
			return nil, fmt.Errorf("job %q: expected a mapping", id)
		}

		for _, forbidden := range []string{"strategy", "services", "uses", "permissions", "concurrency", "environment"} {
			if mapGet(jn, forbidden) != nil {
				reason := map[string]string{
					"strategy":    "matrix builds (strategy:) are out of MVP scope — each matrix cell would need its own CircleCI job with its own act/act invocation and its own needs/outputs wiring, none of which this compiler does yet",
					"services":    "job-level services: containers are out of MVP scope — CircleCI's own docker-executor sidecar model or a manual service container in the act/act step would both need explicit wiring",
					"uses":        "this job calls a reusable workflow (uses:) — out of MVP scope, and a fundamentally different compile shape (the callee's jobs would need compiling too)",
					"permissions": "job-level permissions: is out of MVP scope",
					"concurrency": "job-level concurrency: is out of MVP scope",
					"environment": "job-level environment: (deployment environments/protection rules) has no CircleCI equivalent this compiler wires up; out of MVP scope",
				}[forbidden]
				return nil, unsupported("job %q uses %s: %s", id, forbidden, reason)
			}
		}

		runsOnNode := mapGet(jn, "runs-on")
		if runsOnNode == nil {
			return nil, fmt.Errorf("job %q: missing runs-on:", id)
		}
		if runsOnNode.Kind != yaml.ScalarNode {
			return nil, unsupported("job %q: runs-on: must be a single string label; runs-on: lists (e.g. [self-hosted, linux, x64]) are out of MVP scope", id)
		}
		exec, err := ResolveRunsOn(runsOnNode.Value)
		if err != nil {
			return nil, unsupported("job %q: %s", id, err)
		}

		needs := stringList(mapGet(jn, "needs"))

		var filter *BranchFilter
		if ifNode := mapGet(jn, "if"); ifNode != nil {
			if ifNode.Kind != yaml.ScalarNode {
				return nil, unsupported("job %q: if: must be a string expression", id)
			}
			f, err := ClassifyIf(ifNode.Value)
			if err != nil {
				return nil, unsupported("job %q: %s", id, err)
			}
			filter = f
		}

		outputs := map[string]string{}
		if outNode := mapGet(jn, "outputs"); outNode != nil {
			if outNode.Kind != yaml.MappingNode {
				return nil, fmt.Errorf("job %q: outputs: must be a mapping", id)
			}
			for _, name := range mapKeys(outNode) {
				vn := mapGet(outNode, name)
				if vn.Kind != yaml.ScalarNode || !reOutputExpr.MatchString(strings.TrimSpace(vn.Value)) {
					return nil, unsupported(
						"job %q output %q = %q is not of the supported form ${{ steps.<id>.outputs.<name> }} — "+
							"literal output values and any other expression shape are out of MVP scope",
						id, name, vn.Value)
				}
				outputs[name] = vn.Value
			}
		}

		if mapGet(jn, "steps") == nil {
			return nil, fmt.Errorf("job %q: no steps:", id)
		}

		j := &Job{
			ID:          id,
			Node:        deepCopy(jn),
			RunsOnLabel: runsOnNode.Value,
			Executor:    exec,
			Needs:       needs,
			Filter:      filter,
			Outputs:     outputs,
		}
		jobs = append(jobs, j)
		byID[id] = j
	}

	// needs.*.outputs.* scan + rewrite, now that every job's declared needs:
	// list is known (a job may only reference a job it actually needs).
	for _, j := range jobs {
		declared := map[string]bool{}
		for _, n := range j.Needs {
			declared[n] = true
		}
		stepsNode := mapGet(j.Node, "steps")
		refs, err := rewriteNeedsRefs(stepsNode, declared)
		if err != nil {
			return nil, unsupported("job %q: %s", j.ID, err)
		}
		// also scan the job-level env: block, if any
		if envNode := mapGet(j.Node, "env"); envNode != nil {
			envRefs, err := rewriteNeedsRefs(envNode, declared)
			if err != nil {
				return nil, unsupported("job %q: %s", j.ID, err)
			}
			refs = append(refs, envRefs...)
		}
		j.NeedsUsed = dedupeRefs(refs)
		for _, r := range j.NeedsUsed {
			up, ok := byID[r.Job]
			if !ok {
				return nil, unsupported("job %q needs output %q from job %q, which does not exist in this workflow", j.ID, r.Output, r.Job)
			}
			if _, ok := up.Outputs[r.Output]; !ok {
				return nil, unsupported("job %q references needs.%s.outputs.%s, but job %q declares no such output (it declares: %v)", j.ID, r.Job, r.Output, r.Job, outputNames(up.Outputs))
			}
		}
	}

	// Now build: per-job generated workflow files, then the CircleCI config.
	generated := map[string]string{}
	nameNode := mapGet(root, "name")
	onNode := mapGet(root, "on")

	for _, j := range jobs {
		fileNode := buildPerJobWorkflowDoc(nameNode, onNode, j)
		buf, err := marshalYAML(fileNode)
		if err != nil {
			return nil, fmt.Errorf("job %q: marshaling generated workflow: %w", j.ID, err)
		}
		generated[fmt.Sprintf("generated/%s.yml", j.ID)] = buf
	}

	configYAML, err := buildCircleCIConfig(jobs)
	if err != nil {
		return nil, err
	}

	return &Result{
		ConfigYAML:         configYAML,
		GeneratedWorkflows: generated,
		Jobs:               jobs,
	}, nil
}

func outputNames(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func dedupeRefs(refs []NeedsOutputRef) []NeedsOutputRef {
	seen := map[string]bool{}
	out := make([]NeedsOutputRef, 0, len(refs))
	for _, r := range refs {
		k := r.Job + "/" + r.Output
		if seen[k] {
			continue
		}
		seen[k] = true
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Job != out[j].Job {
			return out[i].Job < out[j].Job
		}
		return out[i].Output < out[j].Output
	})
	return out
}

// buildPerJobWorkflowDoc produces the minimal single-job workflow file that
// gets handed to `act/act` for job j. It deliberately contains ONLY job j —
// not the rest of the original workflow — with `needs:` and `if:` removed.
//
// Why: act's own planner (pkg/model/planner.go, createStages) treats
// PlanJob(j) as "run j AND everything in its needs: graph, transitively, in
// this same process" (verified by reading it). That is exactly wrong once
// each GitHub job is its own CircleCI job — it would silently re-run
// upstream jobs a second time, inside the downstream job's container. If the
// needed job's node isn't even in the file, act's dependency-graph builder
// fails outright ("unable to build dependency graph") rather than silently
// skipping it, so needs: cannot just be left in and hope act ignores it —
// it must be removed, and this compiler removes it. `if:` is removed too
// because CircleCI's own workflow filters (built from the same source if:)
// already decide whether the job's CircleCI job runs at all; leaving GitHub's
// copy in place would just risk act re-evaluating branch/ref context that
// may not match CircleCI's and skipping a job CircleCI already decided to run.
func buildPerJobWorkflowDoc(name, on *yaml.Node, j *Job) *yaml.Node {
	jobNode := deepCopy(j.Node)
	mapDelete(jobNode, "needs")
	mapDelete(jobNode, "if")

	if len(j.Outputs) > 0 {
		appendOutputCaptureStep(jobNode, j)
	}

	pairs := []*yaml.Node{}
	pairs = append(pairs, strNode("name"), strNode(fmt.Sprintf("generated-for-circleci: %s", j.ID)))
	if on != nil {
		pairs = append(pairs, strNode("on"), deepCopy(on))
	} else {
		pairs = append(pairs, strNode("on"), strNode("push"))
	}
	if name != nil {
		_ = name // original workflow name kept only in the comment above; act doesn't need it
	}
	pairs = append(pairs, strNode("jobs"), mappingNode(strNode(j.ID), jobNode))

	doc := &yaml.Node{Kind: yaml.DocumentNode, Content: []*yaml.Node{mappingNode(pairs...)}}
	return doc
}

// appendOutputCaptureStep adds one synthetic final step that writes this
// job's declared outputs to a file inside the checked-out working directory
// (which `act/act`'s default bind: true mounts straight from the host, per
// pkg/runner — no copy step, no artifact upload needed to get the file back
// out to the CircleCI job that invoked act). The values are captured via a
// step-level env: block (GitHub substitutes ${{ steps.X.outputs.Y }} into
// the env *value*, not into shell script text) and then shell-quoted with
// `printf %q` before being written as `export KEY=value` lines — the same
// injection class the bridge orbs' hand-rolled env/with parsers were
// already found to have (see map-parameter spike) is deliberately avoided
// here rather than reintroduced.
func appendOutputCaptureStep(jobNode *yaml.Node, j *Job) {
	names := outputNames(j.Outputs)

	envPairs := []*yaml.Node{}
	var script strings.Builder
	script.WriteString("mkdir -p \"$GITHUB_WORKSPACE/.circleci-outputs\"\n")
	script.WriteString("{\n")
	for _, name := range names {
		shellVar := "CCI_OUT_" + sanitizeEnv(name)
		envPairs = append(envPairs, strNode(shellVar), strNode(j.Outputs[name]))
		envVar := envVarFor(j.ID, name)
		script.WriteString(fmt.Sprintf("  printf 'export %s=%%q\\n' \"${%s}\"\n", envVar, shellVar))
	}
	script.WriteString(fmt.Sprintf("} > \"$GITHUB_WORKSPACE/.circleci-outputs/%s.env\"\n", j.ID))

	step := mappingNode(
		strNode("name"), strNode("circleci: capture job outputs"),
		strNode("if"), strNode("always()"),
		strNode("env"), mappingNode(envPairs...),
		strNode("run"), strNode(script.String()),
	)

	stepsNode := mapGet(jobNode, "steps")
	stepsNode.Content = append(stepsNode.Content, step)
}

func sanitizeEnv(s string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(s) {
		if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteRune('_')
		}
	}
	return b.String()
}

func marshalYAML(n *yaml.Node) (string, error) {
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(n); err != nil {
		return "", err
	}
	if err := enc.Close(); err != nil {
		return "", err
	}
	return buf.String(), nil
}
