package compile

import (
	"os"
	"strings"
	"testing"
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
	if _, err := ResolveRunsOn("self-hosted"); err == nil {
		t.Error("self-hosted should be a hard error")
	} else if !strings.Contains(err.Error(), "no meaning on CircleCI") {
		t.Errorf("self-hosted error should explain why, got: %v", err)
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
		if !strings.Contains(res.ConfigYAML, "cci-labs/act@1.0.5") {
			t.Errorf("%s: generated config doesn't pin the act orb version", c.file)
		}
	}
}
