package main

import (
	"archive/zip"
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	repository      = "MMrk36/ps-base"
	powershellRepo  = "PowerShell/PowerShell"
	productFolder   = "PedroScripts/PSBase"
	userAgent       = "PedroScripts-PSBase-Bootstrap"
)

type release struct {
	TagName string `json:"tag_name"`
	Assets  []struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
	} `json:"assets"`
}

type bootstrapManifest struct {
	Version           string `json:"version"`
	PowerShellVersion string `json:"powershellVersion"`
	AppAsset           string `json:"appAsset"`
	AppSHA256          string `json:"appSha256"`
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--self-test" {
		fmt.Println("PS Base bootstrapper self-test passed.")
		return
	}
	if runtime.GOOS != "windows" || runtime.GOARCH != "amd64" {
		fail(errors.New("PS Base currently supports Windows x64 only."))
	}
	if err := run(); err != nil {
		fail(err)
	}
}

func run() error {
	fmt.Println("Pedro Scripts | PS Base")
	fmt.Println("Checking GitHub for the latest installer...")
	client := &http.Client{Timeout: 15 * time.Minute}
	releases, err := getJSON[[]release](client, "https://api.github.com/repos/"+repository+"/releases?per_page=20")
	if err != nil {
		return fmt.Errorf("could not check PS Base releases: %w", err)
	}
	var latest release
	for _, candidate := range releases {
		if candidate.TagName != "" && len(candidate.Assets) > 0 {
			latest = candidate
			break
		}
	}
	if latest.TagName == "" {
		return errors.New("no published PS Base release is available yet")
	}

	manifestURL := assetURL(latest, "psbase-bootstrap.json")
	if manifestURL == "" {
		return errors.New("the latest PS Base release is missing its bootstrap manifest")
	}
	var manifest bootstrapManifest
	if err := downloadJSON(client, manifestURL, &manifest); err != nil {
		return fmt.Errorf("could not read the PS Base release manifest: %w", err)
	}
	if !validVersion(manifest.Version) || manifest.Version != strings.TrimPrefix(latest.TagName, "v") ||
		!validVersion(manifest.PowerShellVersion) ||
		filepath.Base(manifest.AppAsset) != manifest.AppAsset || !strings.HasSuffix(strings.ToLower(manifest.AppAsset), ".zip") ||
		!validSHA256(manifest.AppSHA256) {
		return errors.New("the PS Base release manifest is incomplete, inconsistent or invalid")
	}

	localAppData := os.Getenv("LOCALAPPDATA")
	if localAppData == "" {
		return errors.New("Windows LOCALAPPDATA could not be located")
	}
	root := filepath.Join(localAppData, productFolder)
	if err := os.MkdirAll(root, 0700); err != nil {
		return fmt.Errorf("could not create the PS Base application directory: %w", err)
	}
	versionRoot := filepath.Join(root, manifest.Version)
	runtimeRoot := filepath.Join(root, "runtime-"+manifest.PowerShellVersion)

	if !fileExists(filepath.Join(versionRoot, "PS-Base-GUI.ps1")) ||
		!fileExists(filepath.Join(versionRoot, "PS-Base.ps1")) ||
		!fileExists(filepath.Join(versionRoot, "catalog", "resources.json")) {
		fmt.Println("Downloading PS Base installer files...")
		if err := installApplication(client, latest, manifest, versionRoot, root); err != nil {
			return err
		}
	} else {
		fmt.Println("PS Base installer files are up to date.")
	}

	pwsh := filepath.Join(runtimeRoot, "pwsh.exe")
	if !fileExists(pwsh) {
		fmt.Printf("Downloading portable PowerShell %s...\n", manifest.PowerShellVersion)
		if err := installPowerShell(client, manifest.PowerShellVersion, runtimeRoot, root); err != nil {
			return err
		}
	}

	gui := filepath.Join(versionRoot, "PS-Base-GUI.ps1")
	fmt.Println("Starting PS Base...")
	cmd := exec.Command(pwsh, "-NoLogo", "-NoProfile", "-STA", "-File", gui)
	cmd.Dir = versionRoot
	cmd.Env = append(os.Environ(), "PATH="+runtimeRoot+string(os.PathListSeparator)+os.Getenv("PATH"))
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func installApplication(client *http.Client, rel release, manifest bootstrapManifest, target, root string) error {
	url := assetURL(rel, manifest.AppAsset)
	if url == "" {
		return fmt.Errorf("release asset %q was not found", manifest.AppAsset)
	}
	archivePath := filepath.Join(root, manifest.AppAsset+".download")
	if err := downloadFile(client, url, archivePath); err != nil {
		return fmt.Errorf("could not download installer files: %w", err)
	}
	defer os.Remove(archivePath)

	hash, err := hashFile(archivePath)
	if err != nil {
		return err
	}
	if !strings.EqualFold(hash, manifest.AppSHA256) {
		return errors.New("PS Base installer download failed SHA-256 verification")
	}
	return extractZipAtomic(archivePath, target, root, false)
}

func installPowerShell(client *http.Client, version, target, root string) error {
	apiURL := "https://api.github.com/repos/" + powershellRepo + "/releases/tags/v" + version
	rel, err := getJSON[release](client, apiURL)
	if err != nil {
		return fmt.Errorf("could not find portable PowerShell %s: %w", version, err)
	}
	zipName := "PowerShell-" + version + "-win-x64.zip"
	zipURL := assetURL(rel, zipName)
	hashURL := assetURL(rel, "hashes.sha256")
	if zipURL == "" || hashURL == "" {
		return errors.New("the official PowerShell release is missing its archive or checksum file")
	}

	hashFilePath := filepath.Join(root, "powershell-hashes-"+version+".txt")
	if err := downloadFile(client, hashURL, hashFilePath); err != nil {
		return fmt.Errorf("could not download the official PowerShell checksums: %w", err)
	}
	defer os.Remove(hashFilePath)
	expected, err := expectedHash(hashFilePath, zipName)
	if err != nil {
		return err
	}

	archivePath := filepath.Join(root, zipName+".download")
	if err := downloadFile(client, zipURL, archivePath); err != nil {
		return fmt.Errorf("could not download portable PowerShell: %w", err)
	}
	defer os.Remove(archivePath)
	actual, err := hashFile(archivePath)
	if err != nil {
		return err
	}
	if !strings.EqualFold(actual, expected) {
		return errors.New("portable PowerShell failed official SHA-256 verification")
	}
	return extractZipAtomic(archivePath, target, root, true)
}

func extractZipAtomic(archivePath, target, root string, isRuntime bool) error {
	temp := filepath.Join(root, ".extract-"+fmt.Sprintf("%d", time.Now().UnixNano()))
	if err := os.MkdirAll(temp, 0700); err != nil {
		return err
	}
	defer os.RemoveAll(temp)

	reader, err := zip.OpenReader(archivePath)
	if err != nil {
		return fmt.Errorf("invalid ZIP archive: %w", err)
	}
	defer reader.Close()

	if len(reader.File) > 100000 {
		return errors.New("archive contains too many entries")
	}
	var expandedBytes uint64
	for _, entry := range reader.File {
		expandedBytes += entry.UncompressedSize64
		if expandedBytes > 4*1024*1024*1024 {
			return errors.New("archive exceeds the maximum expanded size")
		}
		name := filepath.Clean(filepath.FromSlash(entry.Name))
		if name == "." || filepath.IsAbs(name) || name == ".." || strings.Contains(name, ":") ||
			strings.Contains(entry.Name, "\\") || strings.HasPrefix(name, ".."+string(os.PathSeparator)) {
			return errors.New("archive contains an unsafe file path")
		}
		destination := filepath.Join(temp, name)
		if !within(temp, destination) {
			return errors.New("archive entry escapes the extraction directory")
		}
		if entry.Mode()&os.ModeSymlink != 0 {
			return errors.New("archive contains an unsupported symbolic link")
		}
		if entry.FileInfo().IsDir() {
			if err := os.MkdirAll(destination, 0700); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
			return err
		}
		input, err := entry.Open()
		if err != nil {
			return err
		}
		output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			input.Close()
			return err
		}
		_, copyErr := io.Copy(output, input)
		input.Close()
		closeErr := output.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
	}
	if isRuntime {
		if !fileExists(filepath.Join(temp, "pwsh.exe")) {
			return errors.New("portable PowerShell archive does not contain pwsh.exe at its root")
		}
	} else if !fileExists(filepath.Join(temp, "PS-Base-GUI.ps1")) ||
		!fileExists(filepath.Join(temp, "PS-Base.ps1")) ||
		!fileExists(filepath.Join(temp, "catalog", "resources.json")) {
		return errors.New("PS Base application archive is incomplete")
	}

	if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
		return err
	}
	backup := target + ".previous"
	if err := os.RemoveAll(backup); err != nil {
		return err
	}
	hadTarget := false
	if _, err := os.Stat(target); err == nil {
		if err := os.Rename(target, backup); err != nil {
			return fmt.Errorf("could not stage the previous installation: %w", err)
		}
		hadTarget = true
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := os.Rename(temp, target); err != nil {
		if hadTarget {
			_ = os.Rename(backup, target)
		}
		return fmt.Errorf("could not activate the downloaded files: %w", err)
	}
	if hadTarget {
		_ = os.RemoveAll(backup)
	}
	return nil
}

func within(root, path string) bool {
	relative, err := filepath.Rel(root, path)
	return err == nil && relative != ".." &&
		!strings.HasPrefix(relative, ".."+string(os.PathSeparator)) &&
		!filepath.IsAbs(relative)
}

func expectedHash(path, name string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) >= 2 && strings.TrimPrefix(fields[len(fields)-1], "*") == name {
			if validSHA256(fields[0]) {
				return fields[0], nil
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	return "", fmt.Errorf("official checksum for %s was not found", name)
}

func getJSON[T any](client *http.Client, url string) (T, error) {
	var value T
	request, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return value, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", userAgent)
	response, err := client.Do(request)
	if err != nil {
		return value, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return value, fmt.Errorf("GitHub returned HTTP %s", response.Status)
	}
	err = json.NewDecoder(response.Body).Decode(&value)
	return value, err
}

func downloadJSON(client *http.Client, url string, target any) error {
	request, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", userAgent)
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("download returned HTTP %s", response.Status)
	}
	return json.NewDecoder(response.Body).Decode(target)
}

func downloadFile(client *http.Client, url, path string) error {
	request, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", userAgent)
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("download returned HTTP %s", response.Status)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(file, response.Body)
	closeErr := file.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

func assetURL(rel release, name string) string {
	for _, asset := range rel.Assets {
		if asset.Name == name {
			return asset.BrowserDownloadURL
		}
	}
	return ""
}

func hashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func validVersion(value string) bool {
	if value == "" {
		return false
	}
	for _, character := range value {
		if !(character >= '0' && character <= '9') &&
			!(character >= 'A' && character <= 'Z') &&
			!(character >= 'a' && character <= 'z') &&
			character != '.' && character != '-' && character != '+' {
			return false
		}
	}
	base := strings.SplitN(strings.SplitN(value, "-", 2)[0], "+", 2)[0]
	parts := strings.Split(base, ".")
	if len(parts) != 3 {
		return false
	}
	for _, part := range parts {
		if part == "" {
			return false
		}
		for _, character := range part {
			if character < '0' || character > '9' {
				return false
			}
		}
	}
	return true
}

func validSHA256(value string) bool {
	if len(value) != 64 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "PS Base startup error:", err)
	fmt.Println("Press Enter to close.")
	_, _ = bufio.NewReader(os.Stdin).ReadString(10)
	os.Exit(1)
}
