package camoufoxnative

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/gofrs/flock"
)

// HostSocketEnv 는 GUI 사용자 세션의 브라우저 호스트(browser-host)가 듣는 unix socket 경로를 지정하는 환경변수다.
// 로그인 전에 시작되는 LaunchDaemon 문맥에서는 Camoufox 가 창 시스템(WindowServer)에 등록하지 못해 종료되므로,
// 이 값이 있으면 웹 로그인 브라우저의 프로세스 기동만 사용자 세션의 호스트에 맡기고 BiDi 연결과 로그인 처리는 서비스가 그대로 수행한다.
const HostSocketEnv = "CAMOUFOX_HOST_SOCKET"

// hostDialTimeout 은 브라우저 호스트에 연결하는 최대 대기 시간이다.
const hostDialTimeout = 3 * time.Second

// hostRequestTimeout 은 호스트가 연결 직후 기동 요청을 읽는 최대 대기 시간이다.
const hostRequestTimeout = 10 * time.Second

// SessionRequiredError 는 웹 로그인 브라우저를 띄울 Mac 사용자 세션이 없다는 오류다.
// 기존 계정 호출과 대시보드에는 영향이 없으며, 사용자가 Mac에 로그인한 뒤 다시 시도하면 된다.
type SessionRequiredError struct {
	// Reason 은 사용자에게 보여 줄 구체적 원인이다.
	Reason string
}

// Error 는 원인과 재시도 방법을 함께 반환한다.
func (err *SessionRequiredError) Error() string {
	return "Mac 사용자 로그인 세션이 필요합니다: " + err.Reason + ". Mac에 로그인한 뒤 다시 시도하세요. 저장된 계정 호출과 대시보드는 계속 동작합니다"
}

// HTTPStatus 는 관리 API 응답 상태 코드다.
func (*SessionRequiredError) HTTPStatus() int { return http.StatusServiceUnavailable }

// ErrorCode 는 관리 화면이 언어별 안내문으로 바꾸는 오류 코드다.
func (*SessionRequiredError) ErrorCode() string { return "gui_session_required" }

// HostConfigured 는 웹 로그인 브라우저를 사용자 세션의 브라우저 호스트로 띄우도록 설정되었는지 반환한다.
func HostConfigured() bool { return hostSocketPath() != "" }

// hostSocketPath 는 macOS 에서만 설정을 읽는다. 창 시스템 세션 문제는 macOS 고유의 제약이기 때문이다.
func hostSocketPath() string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	return strings.TrimSpace(os.Getenv(HostSocketEnv))
}

// hostRequest 는 서비스가 브라우저 호스트에 보내는 기동 요청이다. Camoufox 지문 설정과 임시 profile 만 전달하고 실행 인자는 호스트가 정한다.
type hostRequest struct {
	Executable string         `json:"executable"`
	Profile    string         `json:"profile"`
	Config     map[string]any `json:"config"`
}

// hostResponse 는 브라우저 호스트의 응답이다. BiDi 엔드포인트 또는 기동 실패 원인 중 하나만 채워진다.
type hostResponse struct {
	Endpoint string `json:"endpoint,omitempty"`
	Error    string `json:"error,omitempty"`
}

// launchBrowserOnHost 는 사용자 세션의 브라우저 호스트에 headless 브라우저 기동을 맡기고 BiDi 엔드포인트를 받는다.
// 연결이 유지되는 동안 브라우저가 살아 있으며, 연결을 닫으면 호스트가 브라우저 프로세스 그룹을 종료한다.
func launchBrowserOnHost(
	ctx context.Context, socket string, request hostRequest, profile string, lock *flock.Flock, readyTimeout time.Duration, cleanup func(),
) (*browserProcess, string, error) {
	fail := func(err error) (*browserProcess, string, error) {
		_ = removeProfile(profile, lock)
		cleanup()
		return nil, "", err
	}
	dialer := net.Dialer{Timeout: hostDialTimeout}
	connection, err := dialer.DialContext(ctx, "unix", socket)
	if err != nil {
		if ctx.Err() != nil {
			return fail(ctx.Err())
		}
		return fail(&SessionRequiredError{Reason: "사용자 세션의 브라우저 호스트에 연결할 수 없습니다 (" + err.Error() + ")"})
	}
	if err := json.NewEncoder(connection).Encode(request); err != nil {
		_ = connection.Close()
		return fail(fmt.Errorf("브라우저 호스트에 요청 전송: %w", err))
	}
	stop := context.AfterFunc(ctx, func() { _ = connection.Close() })
	defer stop()
	_ = connection.SetReadDeadline(time.Now().Add(readyTimeout))
	reader := bufio.NewReader(connection)
	var response hostResponse
	if err := json.NewDecoder(reader).Decode(&response); err != nil {
		_ = connection.Close()
		if ctx.Err() != nil {
			return fail(ctx.Err())
		}
		return fail(fmt.Errorf("브라우저 호스트 응답 대기: %w", err))
	}
	_ = connection.SetReadDeadline(time.Time{})
	if response.Error != "" {
		_ = connection.Close()
		return fail(errors.New("브라우저 호스트: " + response.Error))
	}
	process := &browserProcess{done: make(chan struct{}), profile: profile, lock: lock, host: connection}
	go func() {
		// 호스트가 브라우저 종료 또는 연결 종료를 알리는 방법은 연결을 닫는 것뿐이다.
		_, _ = io.Copy(io.Discard, reader)
		_ = connection.Close()
		process.mu.Lock()
		process.waitErr = errors.New("사용자 세션의 브라우저가 종료되었습니다")
		process.mu.Unlock()
		cleanup()
		close(process.done)
	}()
	return process, normalizeBiDiEndpoint(response.Endpoint), nil
}

// terminateBrowserHost 는 쓰기 방향만 닫아 호스트에 종료를 알리고, 호스트가 브라우저를 종료한 뒤 연결을 닫으면 done 이 닫힌다.
func terminateBrowserHost(_ context.Context, process *browserProcess) error {
	if unix, ok := process.host.(*net.UnixConn); ok {
		return unix.CloseWrite()
	}
	return process.host.Close()
}

// HostServer 는 GUI 사용자 세션에서 실행되어 서비스 대신 브라우저 프로세스를 띄우는 브라우저 호스트다.
// 서비스 외 어떤 입력도 받지 않도록 unix socket 은 소유자만 접근 가능한 디렉터리에 0600 으로 만든다.
type HostServer struct {
	// Socket 은 듣는 unix socket 경로다.
	Socket string
	// Log 는 브라우저 출력과 호스트 진단을 받는다.
	Log io.Writer
}

// validateHostProfile 은 서비스가 만든 임시 profile 만 받아들인다.
func validateHostProfile(profile string) error {
	if !filepath.IsAbs(profile) || !strings.HasPrefix(filepath.Base(profile), profilePrefix) {
		return errors.New("profile 경로가 올바르지 않습니다")
	}
	info, err := os.Lstat(filepath.Join(profile, profileLockName))
	if err != nil || !info.Mode().IsRegular() {
		return errors.New("profile 이 서비스가 만든 임시 profile 이 아닙니다")
	}
	return nil
}

// Run 은 socket 을 열고 ctx 가 끝날 때까지 기동 요청을 처리한다.
func (host *HostServer) Run(ctx context.Context) error {
	directory := filepath.Dir(host.Socket)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("브라우저 호스트 디렉터리 생성: %w", err)
	}
	info, err := os.Stat(directory)
	if err != nil {
		return fmt.Errorf("브라우저 호스트 디렉터리 확인: %w", err)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("브라우저 호스트 디렉터리 %s 는 소유자만 접근할 수 있어야 합니다 (현재 %v)", directory, info.Mode().Perm())
	}
	if err := os.Remove(host.Socket); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("이전 브라우저 호스트 socket 제거: %w", err)
	}
	listener, err := net.Listen("unix", host.Socket)
	if err != nil {
		return fmt.Errorf("브라우저 호스트 시작: %w", err)
	}
	defer os.Remove(host.Socket)
	if err := os.Chmod(host.Socket, 0o600); err != nil {
		_ = listener.Close()
		return fmt.Errorf("브라우저 호스트 socket 권한: %w", err)
	}
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	var group sync.WaitGroup
	defer group.Wait()
	for {
		connection, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("브라우저 호스트 연결 수락: %w", err)
		}
		group.Go(func() { host.serve(ctx, connection) })
	}
}

// serve 는 연결 하나의 브라우저 기동부터 종료까지를 처리한다.
func (host *HostServer) serve(ctx context.Context, connection net.Conn) {
	defer connection.Close()
	_ = connection.SetReadDeadline(time.Now().Add(hostRequestTimeout))
	reader := bufio.NewReader(connection)
	var request hostRequest
	if err := json.NewDecoder(reader).Decode(&request); err != nil {
		return
	}
	_ = connection.SetReadDeadline(time.Time{})
	reply := func(response hostResponse) { _ = json.NewEncoder(connection).Encode(response) }
	process, endpoint, err := host.start(ctx, request)
	if err != nil {
		reply(hostResponse{Error: err.Error()})
		return
	}
	defer process.Close()
	reply(hostResponse{Endpoint: endpoint})
	gone := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, reader)
		close(gone)
	}()
	select {
	case <-gone:
	case <-process.done:
	case <-ctx.Done():
	}
}

// start 는 요청을 검증하고 headless 브라우저를 띄워 BiDi 엔드포인트를 얻는다.
func (host *HostServer) start(ctx context.Context, request hostRequest) (*browserProcess, string, error) {
	executable, err := validateCamoufoxExecutable(request.Executable)
	if err != nil {
		return nil, "", fmt.Errorf("Camoufox 실행 파일: %w", err)
	}
	if err := validateHostProfile(request.Profile); err != nil {
		return nil, "", err
	}
	environment, err := camoufoxEnvironment(request.Config)
	if err != nil {
		return nil, "", err
	}
	command := exec.Command(executable, browserArguments(true, request.Profile)...)
	command.Env = environment
	configureBrowserProcess(command, true)
	return startBrowserCommand(ctx, command, "", nil, host.Log, 0, func() {})
}
