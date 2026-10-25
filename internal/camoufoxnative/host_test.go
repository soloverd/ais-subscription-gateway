//go:build !windows

package camoufoxnative

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// startTestHost 는 가짜 Camoufox 를 실행하는 브라우저 호스트를 열고 socket 경로와 가짜 브라우저가 남기는 파일 경로를 반환한다.
// 가짜 브라우저는 자신의 PID 와 CAMOU_CONFIG_1 을 기록하고 BiDi 엔드포인트를 출력한 뒤 대기한다
func startTestHost(t *testing.T) (socket, pidFile, configFile, executable string) {
	t.Helper()
	if _, err := os.Stat("/bin/sh"); err != nil {
		t.Skip("POSIX shell 이 필요합니다")
	}
	// unix socket 경로 길이 제한 때문에 짧은 임시 디렉터리를 쓴다
	root, err := os.MkdirTemp("", "bh")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	release := filepath.Join(root, "release")
	if err := os.Mkdir(release, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(release, "application.ini"), []byte("[App]\nVersion="+camoufoxRelease+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	pidFile, configFile = filepath.Join(root, "pid"), filepath.Join(root, "config")
	script := "#!/bin/sh\necho $$ > " + pidFile + "\nprintf %s \"$CAMOU_CONFIG_1\" > " + configFile + "\necho ws://127.0.0.1:9/session\nexec sleep 60\n"
	executable = filepath.Join(release, "camoufox")
	if err := os.WriteFile(executable, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	socket = filepath.Join(root, "host.sock")
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan error, 1)
	go func() { finished <- (&HostServer{Socket: socket}).Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		if err := <-finished; err != nil {
			t.Errorf("브라우저 호스트 종료: %v", err)
		}
	})
	for deadline := time.Now().Add(3 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(socket); err == nil {
			return socket, pidFile, configFile, executable
		}
		if time.Now().After(deadline) {
			t.Fatal("브라우저 호스트 socket 이 만들어지지 않았습니다")
		}
	}
}

// TestLaunchBrowserOnHost 는 사용자 세션의 브라우저 호스트가 브라우저를 띄워 엔드포인트를 돌려주고,
// 서비스 쪽에서 닫으면 브라우저를 종료하며 서비스의 임시 profile 만 정리되는지 검증한다
func TestLaunchBrowserOnHost(t *testing.T) {
	socket, pidFile, configFile, executable := startTestHost(t)
	profile, lock, err := createProfile()
	if err != nil {
		t.Fatal(err)
	}
	var cleaned atomic.Int32
	process, endpoint, err := launchBrowserOnHost(
		context.Background(), socket,
		hostRequest{Executable: executable, Profile: profile, Config: map[string]any{"marker": "set"}},
		profile, lock, 5*time.Second, func() { cleaned.Add(1) },
	)
	if err != nil {
		_ = removeProfile(profile, lock)
		t.Fatal(err)
	}
	if endpoint != "ws://127.0.0.1:9/session" {
		t.Fatalf("endpoint = %q", endpoint)
	}
	data, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	if config, err := os.ReadFile(configFile); err != nil || !strings.Contains(string(config), `"marker":"set"`) {
		t.Fatalf("지문 설정 전달 = %q %v", config, err)
	}
	if err := process.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(profile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("profile 이 남았습니다: %v", err)
	}
	if cleaned.Load() != 1 {
		t.Fatalf("cleanup 호출 = %d", cleaned.Load())
	}
	for deadline := time.Now().Add(3 * time.Second); ; time.Sleep(20 * time.Millisecond) {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("브라우저 프로세스 %d 가 종료되지 않았습니다", pid)
		}
	}
}

// TestLaunchBrowserOnHostWithoutSession 은 사용자 세션의 브라우저 호스트가 없을 때 재시도 가능한 세션 필요 오류와 정리 상태를 검증한다
func TestLaunchBrowserOnHostWithoutSession(t *testing.T) {
	profile, lock, err := createProfile()
	if err != nil {
		t.Fatal(err)
	}
	var cleaned atomic.Int32
	_, _, err = launchBrowserOnHost(
		context.Background(), filepath.Join(t.TempDir(), "none.sock"), hostRequest{Profile: profile}, profile, lock,
		time.Second, func() { cleaned.Add(1) },
	)
	var required *SessionRequiredError
	if !errors.As(err, &required) || required.ErrorCode() != "gui_session_required" || required.HTTPStatus() != 503 {
		t.Fatalf("err = %v", err)
	}
	if _, statErr := os.Stat(profile); !errors.Is(statErr, os.ErrNotExist) || cleaned.Load() != 1 {
		t.Fatalf("정리 상태 profile=%v cleanup=%d", statErr, cleaned.Load())
	}
}

// TestStartupAbortNeedsUserSession 은 macOS 에서 브라우저가 창 시스템 등록 단계의 SIGABRT 로 끝나면 세션 필요 오류로 안내하는지 검증한다
func TestStartupAbortNeedsUserSession(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS 창 시스템 세션 제약 전용입니다")
	}
	var cleaned atomic.Int32
	_, _, err := startBrowserCommand(
		context.Background(), exec.Command("/bin/sh", "-c", "kill -ABRT $$"), "", nil, nil, 5*time.Second, func() { cleaned.Add(1) },
	)
	var required *SessionRequiredError
	if !errors.As(err, &required) || cleaned.Load() != 1 {
		t.Fatalf("err = %v cleanup=%d", err, cleaned.Load())
	}
}
