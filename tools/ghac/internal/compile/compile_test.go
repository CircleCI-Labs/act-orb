package compile

import (
	"os"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestClassifyIf(t *testing.T) {
	cases := []struct {
		in      string
		wantErr bool
		wantNil bool // supported no-op (matches CircleCI default)
	}{
		{in: "github.ref == 'refs/heads/main'", wantErr: false},
		{in: "${{ github.ref == 'refs/heads/main' }}", wantErr: false},
		{in: "github.ref == 'refs/tags/v1'", wantErr: false},
		{in: "github.ref_name == 'release'", wantErr: false},
		{in: "startsWith(github.ref, 'refs/heads/')", wantErr: false, wantNil: true},
		{in: "startsWith(github.ref, 'refs/tags/')", wantErr: false},
		{in: "github.event_name == 'workflow_dispatch'", wantErr: true},
		{in: "needs.build.result == 'success'", wantErr: true},
		{in: "", wantErr: false, wantNil: true},
	}
	for _, c := range cases {
		f, err := ClassifyIf(c.in)
		if c.wantErr && err == nil {
			t.Errorf("ClassifyIf(%q): expected error, got none", c.in)
		}
		if !c.wantErr && err != nil {
			t.Errorf("ClassifyIf(%q): unexpected error: %v", c.in, err)
		}
		if c.wantNil && f != nil {
			t.Errorf("ClassifyIf(%q): expected nil filter, got %+v", c.in, f)
		}
	}
}

func TestResolveRunsOn(t *testing.T) {
	if _, err := ResolveRunsOn("ubuntu-latest"); err != nil {
		t.Errorf("ubuntu-latest should resolve: %v", err)
	}
	// "self-hosted" is deliberately not in this table at all anymore — see
	// TestResolveSelfHostedRunsOn below for how it's actually resolved.
	if _, err := ResolveRunsOn("self-hosted"); err == nil {
		t.Error("self-hosted should not resolve via the GitHub-hosted-label table")
	} else if !strings.Contains(err.Error(), "runson.go") {
		t.Errorf("self-hosted-via-ResolveRunsOn error should point at the table, got: %v", err)
	}
	if _, err := ResolveRunsOn("windows-latest"); err == nil {
		t.Error("windows-latest should be a hard error")
	}
	if _, err := ResolveRunsOn("some-made-up-label"); err == nil {
		t.Error("unknown label should be a hard error")
	} else if !strings.Contains(err.Error(), "runson.go") {
		t.Errorf("unknown-label error should point at the table, got: %v", err)
	}
}

func TestResolveSelfHostedRunsOn(t *testing.T) {
	defer SetSelfHostedNamespace("")

	SetSelfHostedNamespace("")
	if _, err := ResolveSelfHostedRunsOn([]string{"self-hosted"}); err == nil {
		t.Error("bare self-hosted with no namespace configured should be a hard error")
	} else if !strings.Contains(err.Error(), "self-hosted-namespace") {
		t.Errorf("missing-namespace error should say so, got: %v", err)
	}

	SetSelfHostedNamespace("acme")
	tgt, err := ResolveSelfHostedRunsOn([]string{"self-hosted"})
	if err != nil {
		t.Fatalf("bare self-hosted with a namespace should resolve: %v", err)
	}
	if tgt.ResourceClass != "acme/self-hosted" || !tgt.SelfHosted {
		t.Errorf("bare self-hosted resolved to %+v", tgt)
	}

	tgt, err = ResolveSelfHostedRunsOn([]string{"self-hosted", "linux", "x64"})
	if err != nil {
		t.Fatalf("self-hosted+linux+x64 should resolve: %v", err)
	}
	if tgt.ResourceClass != "acme/linux-x64" {
		t.Errorf("self-hosted+linux+x64 resolved to resource_class %q, want acme/linux-x64", tgt.ResourceClass)
	}

	if _, err := ResolveSelfHostedRunsOn([]string{"self-hosted", "windows"}); err == nil {
		t.Error("self-hosted+windows should be a hard error (act needs a Linux Docker host)")
	}
	if _, err := ResolveSelfHostedRunsOn([]string{"self-hosted", "gpu-box"}); err == nil {
		t.Error("self-hosted with an unrecognized extra label should be a hard error, not a guess")
	}
	if _, err := ResolveSelfHostedRunsOn([]string{"self-hosted", "x64"}); err == nil {
		t.Error("self-hosted with an arch label but no linux label should be a hard error")
	}
	if _, err := ResolveSelfHostedRunsOn([]string{"linux", "x64"}); err == nil {
		t.Error("a label list without self-hosted at all should be a hard error")
	}
}

func TestRewriteScalar_SupportedForm(t *testing.T) {
	declared := map[string]bool{"build": true}
	out, refs, err := rewriteScalar("v=${{ needs.build.outputs.version }}", declared)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out != "v=${{ env.CCI_NEEDS_BUILD_VERSION }}" {
		t.Errorf("got %q", out)
	}
	if len(refs) != 1 || refs[0].Job != "build" || refs[0].Output != "version" {
		t.Errorf("got refs %+v", refs)
	}
}

func TestRewriteScalar_UnsupportedShape(t *testing.T) {
	declared := map[string]bool{"build": true}
	_, _, err := rewriteScalar("${{ needs.build.result }}", declared)
	if err == nil {
		t.Fatal("expected error for needs.build.result")
	}
	if !strings.Contains(err.Error(), "unsupported needs.* expression") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestRewriteScalar_UndeclaredNeed(t *testing.T) {
	declared := map[string]bool{"other": true}
	_, _, err := rewriteScalar("${{ needs.build.outputs.version }}", declared)
	if err == nil {
		t.Fatal("expected error for undeclared need")
	}
	if !strings.Contains(err.Error(), "not in this job's needs") {
		t.Errorf("wrong error: %v", err)
	}
}

func TestRewriteScalar_LeavesOtherExpressionsAlone(t *testing.T) {
	declared := map[string]bool{}
	out, refs, err := rewriteScalar("${{ github.sha }} and ${{ secrets.TOKEN }}", declared)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out != "${{ github.sha }} and ${{ secrets.TOKEN }}" {
		t.Errorf("expression without needs. should pass through untouched, got %q", out)
	}
	if len(refs) != 0 {
		t.Errorf("expected no refs, got %+v", refs)
	}
}

// Integration: every fixture must produce exactly the pass/reject outcome
// the fixture's name promises, and every passing fixture's config must
// parse and contain the expected job graph shape.
func TestFixtures(t *testing.T) {
	SetSelfHostedNamespace("acme")
	defer SetSelfHostedNamespace("")

	cases := []struct {
		file     string
		wantErr  bool
		wantJobs []string
	}{
		{file: "../../fixtures/01-single-job.yml", wantJobs: []string{"build"}},
		{file: "../../fixtures/02-needs-chain.yml", wantJobs: []string{"lint", "build", "test"}},
		{file: "../../fixtures/03-outputs-flow.yml", wantJobs: []string{"version", "publish"}},
		{file: "../../fixtures/04-matrix-rejected.yml", wantErr: true},
		{file: "../../fixtures/05-bad-if-rejected.yml", wantErr: true},
		{file: "../../fixtures/06-self-hosted-rejected.yml", wantErr: true},
		{file: "../../fixtures/07-needs-result-rejected.yml", wantErr: true},
		{file: "../../fixtures/08-matrix-2x2.yml", wantJobs: []string{"test"}},
		{file: "../../fixtures/09-matrix-include.yml", wantJobs: []string{"build", "publish"}},
		{file: "../../fixtures/10-matrix-needs.yml", wantJobs: []string{"build", "deploy"}},
		{file: "../../fixtures/11-self-hosted-runner.yml", wantJobs: []string{"build"}},
	}
	for _, c := range cases {
		data, err := os.ReadFile(c.file)
		if err != nil {
			t.Fatalf("reading %s: %v", c.file, err)
		}
		res, err := Compile(data, c.file)
		if c.wantErr {
			if err == nil {
				t.Errorf("%s: expected a compile error, got none", c.file)
			} else if _, ok := err.(*UnsupportedError); !ok {
				t.Errorf("%s: error should be *UnsupportedError (named, expected rejection), got %T: %v", c.file, err, err)
			}
			continue
		}
		if err != nil {
			t.Fatalf("%s: unexpected error: %v", c.file, err)
		}
		if len(res.Jobs) != len(c.wantJobs) {
			t.Errorf("%s: got %d jobs, want %d", c.file, len(res.Jobs), len(c.wantJobs))
		}
		for i, j := range res.Jobs {
			if i < len(c.wantJobs) && j.ID != c.wantJobs[i] {
				t.Errorf("%s: job[%d] = %q, want %q", c.file, i, j.ID, c.wantJobs[i])
			}
		}
		if !strings.Contains(res.ConfigYAML, actOrbVersion) {
			t.Errorf("%s: generated config doesn't pin the act orb version", c.file)
		}
	}
}

// TestMatrix2x2 checks the shape of the generated config for a plain
// cross-product matrix: a real CircleCI `matrix:` stanza with both
// parameter lists, no exclude:, no extra discrete job invocations.
func TestMatrix2x2(t *testing.T) {
	data, err := os.ReadFile("../../fixtures/08-matrix-2x2.yml")
	if err != nil {
		t.Fatal(err)
	}
	res, err := Compile(data, "08-matrix-2x2.yml")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(res.Jobs) != 1 {
		t.Fatalf("got %d jobs, want 1", len(res.Jobs))
	}
	j := res.Jobs[0]
	if j.Matrix == nil {
		t.Fatal("expected a MatrixSpec")
	}
	if want := []string{"node-version", "os"}; !stringSlicesEqual(j.Matrix.Keys, want) {
		t.Errorf("Matrix.Keys = %v, want %v (sorted)", j.Matrix.Keys, want)
	}
	if len(j.Matrix.Exclude) != 0 {
		t.Errorf("expected no excludes, got %v", j.Matrix.Exclude)
	}
	if len(j.Matrix.Include) != 0 {
		t.Errorf("expected no include-added combos, got %v", j.Matrix.Include)
	}
	if !strings.Contains(res.ConfigYAML, "matrix:") {
		t.Error("generated config missing a matrix: stanza")
	}
	if !strings.Contains(res.ConfigYAML, "parameters:") {
		t.Error("generated config missing the job's parameters: block")
	}
	if !strings.Contains(res.ConfigYAML, "CCI_MATRIX_OS") || !strings.Contains(res.ConfigYAML, "CCI_MATRIX_NODE_VERSION") {
		t.Error("generated config missing the matrix env var plumbing")
	}
}

// TestMatrixInclude checks that an include entry with the full key set
// becomes one extra discrete job invocation, and that a downstream job's
// requires: picks up both the matrix alias and that extra invocation.
func TestMatrixInclude(t *testing.T) {
	data, err := os.ReadFile("../../fixtures/09-matrix-include.yml")
	if err != nil {
		t.Fatal(err)
	}
	res, err := Compile(data, "09-matrix-include.yml")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var build *Job
	for _, j := range res.Jobs {
		if j.ID == "build" {
			build = j
		}
	}
	if build == nil || build.Matrix == nil {
		t.Fatal("expected a matrixed 'build' job")
	}
	if len(build.Matrix.Include) != 1 {
		t.Fatalf("expected exactly 1 include-added combo, got %v", build.Matrix.Include)
	}
	extraName := includeJobName(build.ID, build.Matrix.Keys, build.Matrix.Include[0])
	if !strings.Contains(res.ConfigYAML, "name: "+extraName) {
		t.Errorf("generated config missing the extra discrete job invocation %q:\n%s", extraName, res.ConfigYAML)
	}
	// publish's requires: must list both the matrix alias ("build") and the
	// extra discrete invocation's name.
	names := build.requirableNames()
	if !stringSlicesEqual(names, []string{"build", extraName}) {
		t.Errorf("requirableNames() = %v, want [build %s]", names, extraName)
	}
}

func TestExpandExcludePartial(t *testing.T) {
	keys := []string{"os", "version"}
	values := map[string][]string{
		"os":      {"a", "b"},
		"version": {"1", "2"},
	}
	// A partial exclude entry (only "os") must expand to one full-key entry
	// per value of the omitted key ("version").
	node := mustParseYAML(t, `[{os: a}]`)
	out, err := expandExclude(node, keys, values, "job")
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 2 {
		t.Fatalf("expected 2 fully-expanded exclude entries, got %v", out)
	}
	want := []map[string]string{{"os": "a", "version": "1"}, {"os": "a", "version": "2"}}
	for _, w := range want {
		found := false
		for _, o := range out {
			if mapEqual(o, w) {
				found = true
			}
		}
		if !found {
			t.Errorf("missing expanded exclude entry %v in %v", w, out)
		}
	}
}

func TestExpandIncludeRejectsPartialKeySet(t *testing.T) {
	keys := []string{"os", "version"}
	values := map[string][]string{
		"os":      {"a", "b"},
		"version": {"1", "2"},
	}
	node := mustParseYAML(t, `[{os: c}]`) // missing "version"
	if _, err := expandInclude(node, keys, values, "job"); err == nil {
		t.Error("include entry missing a base matrix key should be rejected")
	}
}

func TestExpandIncludeDropsRedundant(t *testing.T) {
	keys := []string{"os"}
	values := map[string][]string{"os": {"a", "b"}}
	node := mustParseYAML(t, `[{os: a}]`) // already in the base cross product
	out, err := expandInclude(node, keys, values, "job")
	if err != nil {
		t.Fatal(err)
	}
	if len(out) != 0 {
		t.Errorf("redundant include entry should be dropped as a no-op, got %v", out)
	}
}

func TestRewriteMatrixScalar(t *testing.T) {
	declared := map[string]bool{"os": true}
	out, refs, err := rewriteMatrixScalar("running on ${{ matrix.os }}", declared)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out != "running on ${{ env.CCI_MATRIX_OS }}" {
		t.Errorf("got %q", out)
	}
	if len(refs) != 1 || refs[0].Key != "os" {
		t.Errorf("got refs %+v", refs)
	}

	if _, _, err := rewriteMatrixScalar("${{ matrix.os == 'linux' }}", declared); err == nil {
		t.Error("matrix.* combined with an operator should be rejected")
	}
	if _, _, err := rewriteMatrixScalar("${{ matrix.arch }}", declared); err == nil {
		t.Error("referencing an undeclared matrix key should be rejected")
	}
}

func mustParseYAML(t *testing.T, s string) *yaml.Node {
	t.Helper()
	var n yaml.Node
	if err := yaml.Unmarshal([]byte(s), &n); err != nil {
		t.Fatal(err)
	}
	return n.Content[0]
}

func stringSlicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
