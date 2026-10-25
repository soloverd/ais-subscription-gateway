package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/Mag1cFall/AIStudio2API/internal/camoufoxnative"
)

// runBrowserHost 는 Mac 사용자 로그인 세션(LaunchAgent 등)에서 실행되어, 로그인 전부터 떠 있는 서비스 대신
// 웹 로그인용 Camoufox 프로세스를 띄우는 브라우저 호스트다. 로그인 상태 저장과 계정 처리는 모두 서비스가 수행한다.
func runBrowserHost(ctx context.Context) error {
	socket := strings.TrimSpace(os.Getenv(camoufoxnative.HostSocketEnv))
	if socket == "" {
		return errors.New(camoufoxnative.HostSocketEnv + " 환경변수에 unix socket 절대 경로를 지정하세요")
	}
	if !filepath.IsAbs(socket) {
		return fmt.Errorf("%s 는 절대 경로여야 합니다: %s", camoufoxnative.HostSocketEnv, socket)
	}
	return (&camoufoxnative.HostServer{Socket: socket, Log: os.Stderr}).Run(ctx)
}
