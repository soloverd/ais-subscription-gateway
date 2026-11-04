package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Mag1cFall/AIStudio2API/internal/camoufoxnative"
)

// sessionAdmin 은 Mac 사용자 세션이 없어 로그인 브라우저를 띄울 수 없는 서비스를 흉내 낸다
type sessionAdmin struct {
	AdminService
}

func (sessionAdmin) CreateAccount(context.Context, AccountCreateInput, *camoufoxnative.LiveView) (AdminAccount, error) {
	return AdminAccount{}, &camoufoxnative.SessionRequiredError{Reason: "브라우저 호스트에 연결할 수 없습니다"}
}

func (sessionAdmin) LoginAccount(context.Context, string, *camoufoxnative.LiveView) (AdminAccount, error) {
	return AdminAccount{}, errors.Join(&camoufoxnative.SessionRequiredError{Reason: "브라우저 호스트에 연결할 수 없습니다"})
}

// TestWebLoginRequiresAdminAndExplainsMissingSession 은 인증 없는 원격 로그인 요청이 거부되고,
// 인증된 요청은 사용자 세션 부재를 재시도 가능한 오류 코드로 받는지 검증한다
func TestWebLoginRequiresAdminAndExplainsMissingSession(t *testing.T) {
	serve := func(handler http.Handler, remote, method, path, body, cookie string) *httptest.ResponseRecorder {
		request := httptest.NewRequest(method, path, strings.NewReader(body))
		request.RemoteAddr = remote
		if cookie != "" {
			request.Header.Set("Cookie", cookie)
		}
		recorder := httptest.NewRecorder()
		handler.ServeHTTP(recorder, request)
		return recorder
	}
	paths := [][2]string{
		{"POST", "/api/accounts"}, {"POST", "/api/accounts/a@example.com/login"}, {"GET", "/api/login-view/v"},
		{"POST", "/api/pairing"}, {"POST", "/api/control/stop"},
	}
	open := NewHandler(nil, Config{Admin: sessionAdmin{}})
	for _, path := range paths {
		if got := serve(open, "192.0.2.1:5000", path[0], path[1], "{}", ""); got.Code != http.StatusForbidden {
			t.Fatalf("관리 인증 꺼짐 + 원격 %s %s = %d", path[0], path[1], got.Code)
		}
	}
	handler := NewHandler(nil, Config{Admin: sessionAdmin{}, AdminAuthEnabled: true, AdminUsername: "admin", AdminPassword: "secret"})
	for _, path := range paths {
		if got := serve(handler, "192.0.2.1:5000", path[0], path[1], "{}", ""); got.Code != http.StatusUnauthorized {
			t.Fatalf("세션 없음 %s %s = %d", path[0], path[1], got.Code)
		}
	}
	login := serve(handler, "192.0.2.1:5000", "POST", "/api/auth/login", `{"username":"admin","password":"secret"}`, "")
	cookies := login.Result().Cookies()
	if login.Code != http.StatusOK || len(cookies) == 0 {
		t.Fatalf("로그인 = %d %s", login.Code, login.Body)
	}
	// 로그인은 계정 작업으로 비동기 실행되므로, 작업 항목에 세션 필요 오류 코드가 기록되는지 확인한다
	for _, path := range paths[:2] {
		response := serve(handler, "192.0.2.1:5000", path[0], path[1], `{"view":"v"}`, cookies[0].String())
		var started struct {
			Task AccountTask `json:"task"`
		}
		if response.Code != http.StatusAccepted || json.Unmarshal(response.Body.Bytes(), &started) != nil || started.Task.ID == "" {
			t.Fatalf("로그인 작업 시작 %s = %d %s", path[1], response.Code, response.Body)
		}
		var item AccountTaskItem
		for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
			var listed struct {
				Tasks []AccountTask `json:"tasks"`
			}
			tasks := serve(handler, "192.0.2.1:5000", "GET", "/api/accounts/tasks", "", cookies[0].String())
			if json.Unmarshal(tasks.Body.Bytes(), &listed) != nil {
				t.Fatalf("작업 목록 = %d %s", tasks.Code, tasks.Body)
			}
			for _, task := range listed.Tasks {
				if task.ID == started.Task.ID && len(task.Items) == 1 {
					item = task.Items[0]
				}
			}
			if item.State == "failed" || item.State == "done" {
				break
			}
		}
		if item.State != "failed" || item.Code != "gui_session_required" {
			t.Fatalf("세션 없음 안내 %s = %+v", path[1], item)
		}
	}
}
