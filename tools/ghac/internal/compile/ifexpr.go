package compile

import (
	"fmt"
	"regexp"
	"strings"
)

// BranchFilter is a CircleCI workflow-job `filters:` block, expressed as
// "only" allow-lists. CircleCI's own default (no filters:) already means
// "all branches, no tags," so BranchesOnly/TagsOnly being empty is not the
// same as "run nowhere" — it's rendered by asFilters (compile.go) as no
// filters: key at all when nothing needs restricting.
type BranchFilter struct {
	BranchesOnly       []string // exact branch names
	TagsOnly           []string // exact tag names, or "/.*/" for "any tag"
	ExcludeAllBranches bool     // set when the source meant "tags only": CircleCI runs branch pushes by default, so a tags-only condition must also say branches: ignore: /.*/
}

// Recognized job-level `if:` forms, and ONLY these. Each is a full-expression
// match (optionally wrapped in ${{ }}) — anything else is a hard compile
// error naming the raw expression text, never a silent pass-through. This is
// deliberately far short of a GitHub expression-language implementation —
// see the honest-limits table in the top-level README for where the line is
// and why.
var (
	reWrap        = regexp.MustCompile(`^\$\{\{\s*(.*?)\s*\}\}$`)
	reRefEqBranch = regexp.MustCompile(`^github\.ref\s*==\s*'refs/heads/([^']+)'$`)
	reRefEqTag    = regexp.MustCompile(`^github\.ref\s*==\s*'refs/tags/([^']+)'$`)
	reRefNameEq   = regexp.MustCompile(`^github\.ref_name\s*==\s*'([^']+)'$`)
	reStartsHeads = regexp.MustCompile(`^startsWith\(\s*github\.ref\s*,\s*'refs/heads/'\s*\)$`)
	reStartsTags  = regexp.MustCompile(`^startsWith\(\s*github\.ref\s*,\s*'refs/tags/'\s*\)$`)
)

// ClassifyIf turns a supported job-level `if:` expression into a CircleCI
// branch/tag filter, or nil if the expression is equivalent to CircleCI's
// unfiltered default. It rejects, by name, anything it does not specifically
// recognize — no attempt to interpret arbitrary boolean/function expressions.
func ClassifyIf(raw string) (*BranchFilter, error) {
	expr := strings.TrimSpace(raw)
	if expr == "" {
		return nil, nil
	}
	if m := reWrap.FindStringSubmatch(expr); m != nil {
		expr = m[1]
	}

	switch {
	case reRefEqBranch.MatchString(expr):
		b := reRefEqBranch.FindStringSubmatch(expr)[1]
		return &BranchFilter{BranchesOnly: []string{b}}, nil
	case reRefEqTag.MatchString(expr):
		t := reRefEqTag.FindStringSubmatch(expr)[1]
		return &BranchFilter{TagsOnly: []string{t}, ExcludeAllBranches: true}, nil
	case reRefNameEq.MatchString(expr):
		// github.ref_name is ambiguous between a branch and a tag name; GitHub
		// itself only disambiguates via github.ref_type, which this compiler
		// does not attempt to read. Treat it as a branch name — the common
		// case — and say so in generated-config commentary rather than guess
		// silently forever.
		b := reRefNameEq.FindStringSubmatch(expr)[1]
		return &BranchFilter{BranchesOnly: []string{b}}, nil
	case reStartsHeads.MatchString(expr):
		// "any branch, no tags" is already CircleCI's unfiltered default.
		return nil, nil
	case reStartsTags.MatchString(expr):
		return &BranchFilter{TagsOnly: []string{"/.*/"}, ExcludeAllBranches: true}, nil
	default:
		return nil, fmt.Errorf(
			"if: %q is not one of the supported branch/tag forms "+
				"(github.ref == 'refs/heads/X', github.ref == 'refs/tags/X', github.ref_name == 'X', "+
				"startsWith(github.ref, 'refs/heads/'|'refs/tags/')). Refusing rather than guessing", raw)
	}
}
