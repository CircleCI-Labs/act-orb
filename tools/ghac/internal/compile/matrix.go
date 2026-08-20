package compile

import (
	"fmt"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// This file maps GitHub's `strategy.matrix` onto CircleCI's own native
// `matrix:` workflow-job stanza (see the configuration reference's `matrix`
// key: `parameters`/`exclude`/`alias`, and "Dependencies and matrix jobs"
// for how a matrix's `alias` — defaulting to the job name — is what a
// downstream job's `requires:` list actually references). That means a
// simple cross-product matrix compiles to a REAL CircleCI matrix: the
// generated job becomes a parameterized CircleCI job (one string parameter
// per matrix key) and the workflow invokes it with `matrix: parameters:`,
// exactly the shape circleci/docs describes.
//
// `exclude` has a clean, exact mapping: GitHub's exclude entries may name
// only a SUBSET of the matrix's keys (matching every combination whose
// values agree on that subset); CircleCI's own exclude entries are argument
// maps, and rather than guess whether CircleCI itself resolves a subset the
// same way, this compiler always expands every exclude entry into the full
// set of complete, every-key-present combinations it denotes (cross-
// producting over whatever keys the entry left unspecified) before handing
// it to CircleCI. A fully-specified entry is the degenerate case of that
// expansion (nothing left to cross-product), so this is one code path, not
// two, and it is correct regardless of whether CircleCI's own exclude
// matching happens to be exact-only or subset-aware.
//
// `include` has no equally clean mapping in general — GitHub's `include`
// can (a) add a brand-new, fully-specified combination, (b) widen an
// existing combination with extra keys, or (c) inject keys that don't
// exist in the base matrix at all, matching against whatever subset of
// keys the entry does share with the base matrix. Only (a) is tractable
// without guessing: an include entry whose key set is EXACTLY the base
// matrix's own key set denotes one unambiguous extra combination, which
// this compiler expands into a separate, explicit, non-matrix job
// invocation (calling the same parameterized job with literal parameter
// values instead of a `matrix:` block) — see render.go's
// renderMatrixWorkflowEntries. Anything shaped like (b) or (c) is rejected
// by name: this compiler will not guess which existing cells an include
// entry's extra keys were meant to widen.
var (
	reMatrixKey  = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_-]*$`)
	reMatrixOnly = regexp.MustCompile(`^matrix\.([A-Za-z0-9_-]+)$`)
)

// reservedJobInvocationParams are the CircleCI-reserved keys at a workflow
// job-invocation site (configuration-reference's `parameters` (job) section
// lists these). A matrix key colliding with one of these would be
// ambiguous at the call site, so it's rejected up front rather than risking
// a generated config where "requires" or "filters" silently means the
// wrong thing.
var reservedJobInvocationParams = map[string]bool{
	"name": true, "requires": true, "context": true,
	"type": true, "filters": true, "matrix": true,
}

// MatrixSpec is one job's parsed, validated strategy.matrix, already
// resolved into exactly what render.go needs: the parameter keys/values
// CircleCI's own matrix stanza cross-products, a fully-expanded exclude
// list ready to hand to CircleCI verbatim, and any include-added
// combinations that must instead become separate discrete job invocations.
type MatrixSpec struct {
	Keys    []string            // matrix parameter keys, sorted for deterministic output
	Values  map[string][]string // key -> declared values (raw scalar text, original order)
	Exclude []map[string]string // fully-expanded (every key present) combinations to exclude
	Include []map[string]string // fully-expanded EXTRA combinations from `include`, each with every key present, none already in the base cross product
}

func matrixEnvVarFor(key string) string {
	return "CCI_MATRIX_" + sanitizeEnv(key)
}

// parseStrategy reads a job's `strategy:` block, if any. Returns (nil, nil)
// for a job with no strategy: at all. Every construct under strategy: that
// this compiler doesn't implement is a named rejection, never a silent
// no-op — including fail-fast/max-parallel, which are accepted or rejected
// explicitly rather than just being left unread.
func parseStrategy(jn *yaml.Node, jobID string) (*MatrixSpec, error) {
	strategyNode := mapGet(jn, "strategy")
	if strategyNode == nil {
		return nil, nil
	}
	if strategyNode.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("job %q: strategy: must be a mapping", jobID)
	}

	if mpNode := mapGet(strategyNode, "max-parallel"); mpNode != nil {
		return nil, fmt.Errorf(
			"job %q: strategy.max-parallel is out of MVP scope — CircleCI has no per-matrix "+
				"concurrency cap (workflow-level concurrency: is already out of MVP scope too, "+
				"for the same reason: nothing wires it up yet). Remove max-parallel or accept "+
				"unlimited matrix parallelism", jobID)
	}
	// fail-fast is deliberately accepted either way (true, false, or absent
	// — GitHub's own default is true) rather than rejected: CircleCI simply
	// has no way to cancel sibling matrix jobs on a failure, so this
	// compiler documents that gap in the generated config's comments
	// (render.go) instead of blocking the single highest-value target
	// (matrix itself) on a scheduling nicety neither platform treats as a
	// correctness guarantee — GitHub's own fail-fast only stops jobs that
	// haven't started yet; it never changes whether the workflow's overall
	// result is a failure.

	matrixNode := mapGet(strategyNode, "matrix")
	if matrixNode == nil {
		return nil, fmt.Errorf(
			"job %q: strategy: without a matrix: has no CircleCI equivalent this compiler wires up "+
				"(fail-fast/max-parallel alone don't define a job identity to compile against)", jobID)
	}
	if matrixNode.Kind != yaml.MappingNode {
		return nil, fmt.Errorf("job %q: strategy.matrix: must be a mapping", jobID)
	}

	values := map[string][]string{}
	var includeNode, excludeNode *yaml.Node
	var keys []string
	for _, k := range mapKeys(matrixNode) {
		switch k {
		case "include":
			includeNode = mapGet(matrixNode, k)
			continue
		case "exclude":
			excludeNode = mapGet(matrixNode, k)
			continue
		}
		if !reMatrixKey.MatchString(k) {
			return nil, fmt.Errorf(
				"job %q: strategy.matrix key %q is not a plain identifier (letters/digits/underscore/dash) "+
					"this compiler can turn into a CircleCI job parameter name", jobID, k)
		}
		if reservedJobInvocationParams[k] {
			return nil, fmt.Errorf(
				"job %q: strategy.matrix key %q collides with a CircleCI-reserved job-invocation key "+
					"(name/requires/context/type/filters/matrix) — rename this matrix axis", jobID, k)
		}
		vn := mapGet(matrixNode, k)
		if vn.Kind != yaml.SequenceNode {
			return nil, fmt.Errorf(
				"job %q: strategy.matrix.%s must be a list of values", jobID, k)
		}
		var vals []string
		for _, c := range vn.Content {
			if c.Kind != yaml.ScalarNode {
				return nil, fmt.Errorf(
					"job %q: strategy.matrix.%s has a non-scalar value — this compiler only supports "+
						"scalar (string/number/boolean) matrix values, not nested lists or maps as one axis' value",
					jobID, k)
			}
			vals = append(vals, c.Value)
		}
		if len(vals) == 0 {
			return nil, fmt.Errorf("job %q: strategy.matrix.%s is an empty list", jobID, k)
		}
		values[k] = vals
		keys = append(keys, k)
	}
	if len(keys) == 0 {
		return nil, fmt.Errorf(
			"job %q: strategy.matrix has no parameter keys (only include/exclude, if anything) — "+
				"nothing to cross-product", jobID)
	}
	sort.Strings(keys)

	exclude, err := expandExclude(excludeNode, keys, values, jobID)
	if err != nil {
		return nil, err
	}
	include, err := expandInclude(includeNode, keys, values, jobID)
	if err != nil {
		return nil, err
	}

	return &MatrixSpec{Keys: keys, Values: values, Exclude: exclude, Include: include}, nil
}

// crossProduct returns every combination of values across keys (in the
// given key order), as full key->value maps.
func crossProduct(keys []string, values map[string][]string) []map[string]string {
	combos := []map[string]string{{}}
	for _, k := range keys {
		var next []map[string]string
		for _, c := range combos {
			for _, v := range values[k] {
				nc := make(map[string]string, len(c)+1)
				for kk, vv := range c {
					nc[kk] = vv
				}
				nc[k] = v
				next = append(next, nc)
			}
		}
		combos = next
	}
	return combos
}

func mapEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

// expandExclude turns strategy.matrix.exclude into a list of fully-
// specified (every base key present) combinations, cross-producting over
// whatever keys each entry left unspecified. See the file-level comment
// for why this is always a full expansion rather than passing partial
// entries through as-is.
func expandExclude(excludeNode *yaml.Node, keys []string, values map[string][]string, jobID string) ([]map[string]string, error) {
	if excludeNode == nil {
		return nil, nil
	}
	if excludeNode.Kind != yaml.SequenceNode {
		return nil, fmt.Errorf("job %q: strategy.matrix.exclude must be a list", jobID)
	}
	var out []map[string]string
	for _, entry := range excludeNode.Content {
		if entry.Kind != yaml.MappingNode {
			return nil, fmt.Errorf("job %q: strategy.matrix.exclude entries must be mappings", jobID)
		}
		fixed := map[string]string{}
		for _, ek := range mapKeys(entry) {
			if !contains(keys, ek) {
				return nil, fmt.Errorf(
					"job %q: strategy.matrix.exclude entry references %q, which isn't one of this "+
						"matrix's own parameters (%v)", jobID, ek, keys)
			}
			fixed[ek] = mapGet(entry, ek).Value
		}
		var missing []string
		for _, k := range keys {
			if _, ok := fixed[k]; !ok {
				missing = append(missing, k)
			}
		}
		for _, combo := range crossProduct(missing, values) {
			full := map[string]string{}
			for k, v := range fixed {
				full[k] = v
			}
			for k, v := range combo {
				full[k] = v
			}
			out = append(out, full)
		}
	}
	return out, nil
}

// expandInclude turns strategy.matrix.include into extra, fully-specified
// combinations not already in the base cross product — only for entries
// whose key set is EXACTLY the base matrix's own keys (see file-level
// comment for why anything else is rejected rather than guessed).
func expandInclude(includeNode *yaml.Node, keys []string, values map[string][]string, jobID string) ([]map[string]string, error) {
	if includeNode == nil {
		return nil, nil
	}
	if includeNode.Kind != yaml.SequenceNode {
		return nil, fmt.Errorf("job %q: strategy.matrix.include must be a list", jobID)
	}
	base := crossProduct(keys, values)
	var extra []map[string]string
	for _, entry := range includeNode.Content {
		if entry.Kind != yaml.MappingNode {
			return nil, fmt.Errorf("job %q: strategy.matrix.include entries must be mappings", jobID)
		}
		entryKeys := mapKeys(entry)
		if !sameKeySet(entryKeys, keys) {
			return nil, fmt.Errorf(
				"job %q: strategy.matrix.include entry (keys %v) does not specify exactly this matrix's "+
					"own keys (%v) — include entries that omit a matrix key, or add a key not already in "+
					"the matrix, widen or augment existing cells under GitHub's semantics, and this "+
					"compiler won't guess which cells that means. Only include entries that add one "+
					"complete new combination (every existing matrix key, no new ones) are supported",
				jobID, entryKeys, keys)
		}
		combo := map[string]string{}
		for _, k := range entryKeys {
			combo[k] = mapGet(entry, k).Value
		}
		redundant := false
		for _, b := range base {
			if mapEqual(b, combo) {
				redundant = true
				break
			}
		}
		if redundant {
			continue // matches GitHub's own no-op behavior for an include entry that adds nothing new
		}
		dup := false
		for _, e := range extra {
			if mapEqual(e, combo) {
				dup = true
				break
			}
		}
		if !dup {
			extra = append(extra, combo)
		}
	}
	return extra, nil
}

// includeJobName is the deterministic CircleCI job-invocation name for one
// include-added discrete combination: <job-id>-<value1>-<value2>..., values
// taken in the matrix's own sorted key order (Keys) so the name is stable
// regardless of map iteration order. Job invocation names commonly contain
// dots (the configuration reference's own matrix examples use versions like
// "build-macos-0.1"), so no extra sanitization is applied beyond what
// strategy.matrix's own scalar-value parsing already required.
func includeJobName(jobID string, keys []string, combo map[string]string) string {
	parts := make([]string, 0, len(keys)+1)
	parts = append(parts, jobID)
	for _, k := range keys {
		parts = append(parts, combo[k])
	}
	return strings.Join(parts, "-")
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func sameKeySet(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	set := map[string]bool{}
	for _, x := range a {
		set[x] = true
	}
	for _, x := range b {
		if !set[x] {
			return false
		}
	}
	return true
}

// MatrixRef is one `${{ matrix.<key> }}` reference found and rewritten in a
// matrixed job's own steps/env.
type MatrixRef struct {
	Key    string
	EnvVar string
}

// rewriteMatrixRefs mirrors rewriteNeedsRefs (needs.go) exactly, for the
// same reason: it rewrites the exact whole-expression form
// `${{ matrix.<key> }}` to `${{ env.CCI_MATRIX_<KEY> }}` in place, and
// rejects — by name, quoting the raw expression — any other shape that
// mentions `matrix.` (matrix.os == 'x', fromJSON(matrix.foo), etc.). The
// env var is populated for real at CircleCI job runtime from that job's own
// `environment:` block (render.go), driven by `<< parameters.<key> >>` —
// the same "compile-time parameter substitution, then ordinary shell env"
// path needs.go already established for needs.*.outputs.*, not a new
// mechanism.
func rewriteMatrixRefs(node *yaml.Node, declaredKeys map[string]bool) ([]MatrixRef, error) {
	seen := map[string]MatrixRef{}
	var walkErr error

	var walk func(n *yaml.Node)
	walk = func(n *yaml.Node) {
		if n == nil || walkErr != nil {
			return
		}
		if n.Kind == yaml.ScalarNode && (n.Tag == "!!str" || n.Tag == "") {
			newVal, refs, err := rewriteMatrixScalar(n.Value, declaredKeys)
			if err != nil {
				walkErr = err
				return
			}
			n.Value = newVal
			for _, r := range refs {
				seen[r.Key] = r
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

	out := make([]MatrixRef, 0, len(seen))
	for _, r := range seen {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}

func rewriteMatrixScalar(val string, declaredKeys map[string]bool) (string, []MatrixRef, error) {
	if !strings.Contains(val, "matrix.") {
		return val, nil, nil
	}
	var refs []MatrixRef
	replaced := reBraces.ReplaceAllStringFunc(val, func(whole string) string {
		inner := strings.TrimSpace(reBraces.FindStringSubmatch(whole)[1])
		if !strings.Contains(inner, "matrix.") {
			return whole
		}
		m := reMatrixOnly.FindStringSubmatch(inner)
		if m == nil {
			return "\x00UNSUPPORTED_MATRIX\x00" + whole + "\x00"
		}
		key := m[1]
		if !declaredKeys[key] {
			return "\x00UNDECLARED_MATRIX\x00" + whole + "\x00" + key
		}
		env := matrixEnvVarFor(key)
		refs = append(refs, MatrixRef{Key: key, EnvVar: env})
		return "${{ env." + env + " }}"
	})
	if strings.Contains(replaced, "\x00UNSUPPORTED_MATRIX\x00") {
		i := strings.Index(replaced, "\x00UNSUPPORTED_MATRIX\x00") + len("\x00UNSUPPORTED_MATRIX\x00")
		j := strings.Index(replaced[i:], "\x00")
		expr := replaced[i : i+j]
		return "", nil, fmt.Errorf(
			"unsupported matrix.* expression %s (in %q): only the exact whole-expression form "+
				"${{ matrix.<key> }} is supported — matrix.* combined with other operators or inside "+
				"a function call is out of MVP scope", expr, val)
	}
	if strings.Contains(replaced, "\x00UNDECLARED_MATRIX\x00") {
		i := strings.Index(replaced, "\x00UNDECLARED_MATRIX\x00") + len("\x00UNDECLARED_MATRIX\x00")
		rest := replaced[i:]
		parts := strings.SplitN(rest, "\x00", 2)
		expr := parts[0]
		key := ""
		if len(parts) > 1 {
			key = parts[1]
		}
		return "", nil, fmt.Errorf(
			"%s references matrix.%s, but this job's strategy.matrix declares no such key", expr, key)
	}
	return replaced, refs, nil
}
