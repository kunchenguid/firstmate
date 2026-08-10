package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/kunchenguid/no-mistakes/internal/scm"
	githubscm "github.com/kunchenguid/no-mistakes/internal/scm/github"
)

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "emit" {
		emit()
		return
	}
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: consumer <response-path>")
		os.Exit(2)
	}
	responsePath := os.Args[1]
	host := githubscm.New(func(ctx context.Context, name string, args ...string) *exec.Cmd {
		childArgs := append([]string{"emit", responsePath, name}, args...)
		return exec.CommandContext(ctx, os.Args[0], childArgs...)
	}, nil, "", "o/r")
	checks, err := host.GetChecks(context.Background(), &scm.PR{Number: "7"})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	for _, check := range checks {
		if check.Failing() {
			fmt.Println("rejected")
			return
		}
	}
	fmt.Println("all-passed")
	os.Exit(1)
}

func emit() {
	if len(os.Args) != 11 {
		fmt.Fprintln(os.Stderr, "unexpected consumer command")
		os.Exit(2)
	}
	want := "gh pr checks 7 --repo o/r --json name,state,bucket,completedAt"
	if got := strings.Join(os.Args[3:], " "); got != want {
		fmt.Fprintf(os.Stderr, "consumer command = %q, want %q\n", got, want)
		os.Exit(2)
	}
	response, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if _, err := os.Stdout.Write(response); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}
