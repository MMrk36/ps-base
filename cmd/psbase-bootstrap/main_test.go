package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestExpectedHashSupportsChecksumFormats(t *testing.T) {
	const hash = "7C74E03B20A75B59715847439D046A6214B1863EE79B187872980F139BB4A05F"
	const name = "PowerShell-7.7.0-win-x64.zip"

	cases := []struct {
		name string
		row  string
	}{
		{name: "GNU style", row: hash + " *" + name},
		{name: "BSD style", row: "SHA256 (" + name + ") = " + hash},
		{name: "filename first", row: name + " " + hash},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "hashes.sha256")
			if err := os.WriteFile(path, []byte(testCase.row+"\n"), 0600); err != nil {
				t.Fatal(err)
			}
			actual, err := expectedHash(path, name)
			if err != nil {
				t.Fatal(err)
			}
			if actual != hash {
				t.Fatalf("expected %s, got %s", hash, actual)
			}
		})
	}
}

func TestExpectedHashRejectsMissingEntry(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hashes.sha256")
	if err := os.WriteFile(path, []byte("0123456789abcdef\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := expectedHash(path, "PowerShell-7.7.0-win-x64.zip"); err == nil {
		t.Fatal("expected missing checksum error")
	}
}
