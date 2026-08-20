package compile

import (
	"fmt"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// This is where the "expression-language wall" actually sits for this
// compiler. `act` runs the real, unmodified workflow file, so it resolves
// almost every GitHub expression itself (github.*, secrets.*, vars.*,
// matrix.*, env.*, inputs.*, step outputs *within* a job) — we don't
// reimplement any of that. The one context act cannot resolve on its own is
// `needs.<job>.outputs.<name>` when a job is compiled to run standalone,
// because act's own planner (pkg/model/planner.go createStages) treats
// `needs:` as "also run that job, in this same process" — verified by
// reading it — which is exactly what we do NOT want once each GitHub job is
// its own CircleCI job. So we strip `needs:` from the per-job generated file
// and rewrite the *literal text* of any `${{ needs.X.outputs.Y }}`
// expression to `${{ env.CCI_NEEDS_X_Y }}`, then arrange (in compile.go) for
// that env var to actually be set at job runtime from a CircleCI workspace
// file written by the upstream job.
//
// That textual rewrite only handles the single, exact, whole-expression form
// `needs.<job>.outputs.<name>`. Anything else that mentions `needs.` inside
// a ${{ }} block — needs.<job>.result, needs.<job>.outputs.<name> used in a
// larger boolean/string expression, fromJSON(needs...), etc. — is a hard
// compile error naming the raw expression. We are not writing a GitHub
// expression-language evaluator; we are pattern-matching one specific shape
// safely.
var (
	reBraces    = regexp.MustCompile(`\$\{\{([^}]*)\}\}`)
	reNeedsOnly = regexp.MustCompile(`^needs\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)$`)
)

// NeedsOutputRef is one resolved `needs.<Job>.outputs.<Output>` reference
// found in a downstream job's steps.
type NeedsOutputRef struct {
	Job    string
	Output string
	EnvVar string // CCI_NEEDS_<JOB>_<OUTPUT>, sanitized/uppercased
}

func envVarFor(job, output string) string {
	san := func(s string) string {
		s = strings.ToUpper(s)
		var b strings.Builder
		for _, r := range s {
			if (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
				b.WriteRune(r)
			} else {
				b.WriteRune('_')
			}
		}
		return b.String()
	}
	return fmt.Sprintf("CCI_NEEDS_%s_%s", san(job), san(output))
}

// rewriteNeedsRefs scans every string scalar under node, rewriting exact
// `${{ needs.<job>.outputs.<name> }}` expressions in place to
// `${{ env.CCI_NEEDS_<JOB>_<NAME> }}` and collecting one NeedsOutputRef per
// distinct (job, output) pair encountered. declaredNeeds restricts which
// upstream job names are legal to reference (the job's own `needs:` list) —
// referencing an undeclared job's outputs is a hard error, matching
// GitHub's own rule that needs.X is only populated for a declared need.
func rewriteNeedsRefs(node *yaml.Node, declaredNeeds map[string]bool) ([]NeedsOutputRef, error) {
	seen := map[string]NeedsOutputRef{}
	var walkErr error

	var walk func(n *yaml.Node)
	walk = func(n *yaml.Node) {
		if n == nil || walkErr != nil {
			return
		}
		if n.Kind == yaml.ScalarNode && (n.Tag == "!!str" || n.Tag == "") {
			newVal, refs, err := rewriteScalar(n.Value, declaredNeeds)
			if err != nil {
				walkErr = err
				return
			}
			n.Value = newVal
			for _, r := range refs {
				seen[r.Job+"\x00"+r.Output] = r
			}
			return
		}
		for _, c := range n.Content {
			walk(c)
		}
	}
	walk(node)
	if walkErr != nil {
		return nil, walkErr
	}

	out := make([]NeedsOutputRef, 0, len(seen))
	for _, r := range seen {
		out = append(out, r)
	}
	return out, nil
}

func rewriteScalar(val string, declaredNeeds map[string]bool) (string, []NeedsOutputRef, error) {
	if !strings.Contains(val, "needs.") {
		return val, nil, nil
	}
	var refs []NeedsOutputRef
	replaced := reBraces.ReplaceAllStringFunc(val, func(whole string) string {
		inner := strings.TrimSpace(reBraces.FindStringSubmatch(whole)[1])
		if !strings.Contains(inner, "needs.") {
			return whole
		}
		m := reNeedsOnly.FindStringSubmatch(inner)
		if m == nil {
			// leave a marker; caller below turns this into a real error with context
			return "\x00UNSUPPORTED\x00" + whole + "\x00"
		}
		job, output := m[1], m[2]
		if !declaredNeeds[job] {
			return "\x00UNDECLARED\x00" + whole + "\x00" + job
		}
		env := envVarFor(job, output)
		refs = append(refs, NeedsOutputRef{Job: job, Output: output, EnvVar: env})
		return "${{ env." + env + " }}"
	})
	if strings.Contains(replaced, "\x00UNSUPPORTED\x00") {
		i := strings.Index(replaced, "\x00UNSUPPORTED\x00") + len("\x00UNSUPPORTED\x00")
		j := strings.Index(replaced[i:], "\x00")
		expr := replaced[i : i+j]
		return "", nil, fmt.Errorf(
			"unsupported needs.* expression %s (in %q): only the exact whole-expression form "+
				"${{ needs.<job>.outputs.<name> }} is supported — needs.<job>.result, needs.* combined "+
				"with other operators, and needs.* inside function calls are all out of MVP scope",
			expr, val)
	}
	if strings.Contains(replaced, "\x00UNDECLARED\x00") {
		i := strings.Index(replaced, "\x00UNDECLARED\x00") + len("\x00UNDECLARED\x00")
		rest := replaced[i:]
		parts := strings.SplitN(rest, "\x00", 2)
		expr := parts[0]
		job := ""
		if len(parts) > 1 {
			job = parts[1]
		}
		return "", nil, fmt.Errorf(
			"%s references needs.%s, but %q is not in this job's needs: list — "+
				"GitHub itself would also refuse this at runtime (needs.<job> is only populated "+
				"for declared dependencies)", expr, job, job)
	}
	return replaced, refs, nil
}
