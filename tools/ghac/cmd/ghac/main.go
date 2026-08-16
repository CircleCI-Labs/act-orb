// ghac is the workflow-compiler prototype's CLI. Two subcommands:
//
//	ghac compile --in <workflow.yml> [--out <config.yml>] [--source-path <repo-relative path>] [--self-hosted-namespace <ns>]
//	    Validates the whole workflow and emits the CircleCI config.yml a
//	    setup job would submit via the continuation API.
//
//	ghac render-job --in <workflow.yml> --job <id> [--out <file>] [--source-path <repo-relative path>] [--self-hosted-namespace <ns>]
//	    Re-derives one job's rewritten, needs-stripped workflow file. Called
//	    from *inside* a real (continued) CircleCI job, at runtime, against
//	    the same checked-out source file — see render.go for why this
//	    happens per-job at runtime instead of once in the setup job.
//
// Both subcommands run the identical validation; render-job additionally
// requires that --job name a job that actually exists in the file.
// --self-hosted-namespace only matters if the workflow uses runs-on:
// self-hosted anywhere — see internal/compile/runson.go's
// ResolveSelfHostedRunsOn — but must be passed IDENTICALLY to every
// render-job call for a workflow that uses it anywhere, since Compile
// validates the whole file up front regardless of which one job you asked
// to render.
package main

import (
	"fmt"
	"os"

	"github.com/circleci-labs/gha-compiler/internal/compile"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "compile":
		cmdCompile(os.Args[2:])
	case "render-job":
		cmdRenderJob(os.Args[2:])
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "ghac: unknown subcommand %q\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `ghac — GitHub Actions workflow -> CircleCI config compiler (prototype)

Usage:
  ghac compile     --in <workflow.yml> [--out <config.yml>] [--source-path <path>]
  ghac render-job  --in <workflow.yml> --job <job-id> [--out <file>] [--source-path <path>]`)
}

func cmdCompile(args []string) {
	fs := parseFlags(args, "compile")
	data := readIn(fs.in)
	compile.SetSourceWorkflowRelPath(fs.sourcePath)
	compile.SetSelfHostedNamespace(fs.selfHostedNamespace)
	res, err := compile.Compile(data, fs.in)
	fail(err)
	writeOut(fs.out, res.ConfigYAML)
}

func cmdRenderJob(args []string) {
	fs := parseFlags(args, "render-job")
	if fs.job == "" {
		fmt.Fprintln(os.Stderr, "ghac render-job: --job <id> is required")
		os.Exit(2)
	}
	data := readIn(fs.in)
	compile.SetSourceWorkflowRelPath(fs.sourcePath)
	compile.SetSelfHostedNamespace(fs.selfHostedNamespace)
	res, err := compile.Compile(data, fs.in)
	fail(err)
	key := "generated/" + fs.job + ".yml"
	content, ok := res.GeneratedWorkflows[key]
	if !ok {
		fmt.Fprintf(os.Stderr, "ghac render-job: no job %q in %s\n", fs.job, fs.in)
		os.Exit(1)
	}
	writeOut(fs.out, content)
}

type flags struct {
	in, out, job, sourcePath, selfHostedNamespace string
}

func parseFlags(args []string, subcmd string) flags {
	f := flags{sourcePath: ".github/workflows/workflow.yml"}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--in":
			i++
			f.in = args[i]
		case "--out":
			i++
			f.out = args[i]
		case "--job":
			i++
			f.job = args[i]
		case "--source-path":
			i++
			f.sourcePath = args[i]
		case "--self-hosted-namespace":
			i++
			f.selfHostedNamespace = args[i]
		default:
			fmt.Fprintf(os.Stderr, "ghac %s: unknown flag %q\n", subcmd, args[i])
			os.Exit(2)
		}
	}
	if f.in == "" {
		fmt.Fprintf(os.Stderr, "ghac %s: --in <workflow.yml> is required\n", subcmd)
		os.Exit(2)
	}
	return f
}

func readIn(path string) []byte {
	data, err := os.ReadFile(path)
	fail(err)
	return data
}

func writeOut(path, content string) {
	if path == "" {
		fmt.Print(content)
		return
	}
	fail(os.WriteFile(path, []byte(content), 0o644))
}

func fail(err error) {
	if err == nil {
		return
	}
	if ue, ok := err.(*compile.UnsupportedError); ok {
		fmt.Fprintf(os.Stderr, "ghac: UNSUPPORTED: %s\n", ue.Error())
	} else {
		fmt.Fprintf(os.Stderr, "ghac: error: %s\n", err.Error())
	}
	os.Exit(1)
}
