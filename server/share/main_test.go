package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const secret = "test-secret-at-least-16"

func newTestServer(t *testing.T) (*server, *time.Time) {
	t.Helper()
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	srv, err := newServer(store, secret)
	if err != nil {
		t.Fatal(err)
	}
	clock := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	srv.now = func() time.Time { return clock }
	return srv, &clock
}

func do(t *testing.T, srv *server, req *http.Request) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	srv.routes().ServeHTTP(rec, req)
	return rec
}

func create(t *testing.T, srv *server, body string, ttl string) (id, token string) {
	t.Helper()
	req := httptest.NewRequest("POST", "/api/shares?ttl="+ttl, bytes.NewBufferString(body))
	req.Header.Set("Authorization", "Bearer "+secret)
	rec := do(t, srv, req)
	if rec.Code != 200 {
		t.Fatalf("create: got %d, want 200", rec.Code)
	}
	var out struct{ ID, Token string }
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	return out.ID, out.Token
}

func TestPublishReadRevoke(t *testing.T) {
	srv, _ := newTestServer(t)
	id, token := create(t, srv, "ciphertext", "month")

	rec := do(t, srv, httptest.NewRequest("GET", "/api/blob/"+id, nil))
	if rec.Code != 200 || rec.Body.String() != "ciphertext" {
		t.Fatalf("read: got %d %q", rec.Code, rec.Body.String())
	}

	del := httptest.NewRequest("DELETE", "/api/shares/"+id, nil)
	del.Header.Set("Authorization", "Bearer "+secret)
	del.Header.Set("X-Share-Token", token)
	if rec := do(t, srv, del); rec.Code != 204 {
		t.Fatalf("revoke: got %d, want 204", rec.Code)
	}

	rec = do(t, srv, httptest.NewRequest("GET", "/api/blob/"+id, nil))
	if rec.Code != 404 {
		t.Fatalf("read after revoke: got %d, want 404", rec.Code)
	}
}

// Контракт §3.6: несуществующее, просроченное и отозванное неотличимы. Три
// случая проверяются вместе и сравниваются друг с другом, а не с константой —
// иначе расхождение в теле или заголовке проехало бы мимо.
func TestMissingExpiredRevokedAnswerAlike(t *testing.T) {
	srv, clock := newTestServer(t)

	expiredID, _ := create(t, srv, "one", "week")
	revokedID, revokedToken := create(t, srv, "two", "month")

	del := httptest.NewRequest("DELETE", "/api/shares/"+revokedID, nil)
	del.Header.Set("Authorization", "Bearer "+secret)
	del.Header.Set("X-Share-Token", revokedToken)
	do(t, srv, del)

	*clock = clock.Add(8 * 24 * time.Hour)

	missing := do(t, srv, httptest.NewRequest("GET", "/api/blob/AAAAAAAAAAAAAAAAAAAAAA", nil))
	expired := do(t, srv, httptest.NewRequest("GET", "/api/blob/"+expiredID, nil))
	revoked := do(t, srv, httptest.NewRequest("GET", "/api/blob/"+revokedID, nil))

	for name, rec := range map[string]*httptest.ResponseRecorder{
		"expired": expired, "revoked": revoked,
	} {
		if rec.Code != missing.Code {
			t.Errorf("%s: status %d, missing gives %d", name, rec.Code, missing.Code)
		}
		if rec.Body.String() != missing.Body.String() {
			t.Errorf("%s: body %q, missing gives %q", name, rec.Body.String(), missing.Body.String())
		}
	}
	if missing.Code != 404 {
		t.Errorf("missing: got %d, want 404", missing.Code)
	}
}

// Токен отзыва — единственное, что отделяет владельца от прохожего. Чужой
// токен обязан отвечать ровно тем же, чем отсутствие шера: разный ответ
// подтвердил бы, что такой id занят.
func TestRevokeWithWrongTokenLooksLikeMissing(t *testing.T) {
	srv, _ := newTestServer(t)
	id, _ := create(t, srv, "ciphertext", "month")

	_, other := create(t, srv, "other", "month")
	req := httptest.NewRequest("DELETE", "/api/shares/"+id, nil)
	req.Header.Set("Authorization", "Bearer "+secret)
	req.Header.Set("X-Share-Token", other)
	if rec := do(t, srv, req); rec.Code != 404 {
		t.Fatalf("wrong token: got %d, want 404", rec.Code)
	}

	if rec := do(t, srv, httptest.NewRequest("GET", "/api/blob/"+id, nil)); rec.Code != 200 {
		t.Fatalf("share should survive a wrong-token revoke: got %d", rec.Code)
	}
}

func TestCreateRequiresSecret(t *testing.T) {
	srv, _ := newTestServer(t)
	for name, header := range map[string]string{
		"none":  "",
		"wrong": "Bearer nope",
		"raw":   secret,
	} {
		req := httptest.NewRequest("POST", "/api/shares", bytes.NewBufferString("x"))
		if header != "" {
			req.Header.Set("Authorization", header)
		}
		if rec := do(t, srv, req); rec.Code != 401 {
			t.Errorf("%s: got %d, want 401", name, rec.Code)
		}
	}
}

// «Вечной» ссылки нет — решение владельца 2026-08-27, бэкапов у сервера нет.
// Неизвестный срок обязан отказать, а не молча стать месяцем.
func TestTTL(t *testing.T) {
	srv, clock := newTestServer(t)

	weekID, _ := create(t, srv, "w", "week")
	monthID, _ := create(t, srv, "m", "month")
	defaultID, _ := create(t, srv, "d", "")

	req := httptest.NewRequest("POST", "/api/shares?ttl=forever", bytes.NewBufferString("x"))
	req.Header.Set("Authorization", "Bearer "+secret)
	if rec := do(t, srv, req); rec.Code != 400 {
		t.Errorf("ttl=forever: got %d, want 400", rec.Code)
	}

	*clock = clock.Add(8 * 24 * time.Hour)
	if rec := do(t, srv, httptest.NewRequest("GET", "/api/blob/"+weekID, nil)); rec.Code != 404 {
		t.Errorf("week share after 8 days: got %d, want 404", rec.Code)
	}
	for _, id := range []string{monthID, defaultID} {
		if rec := do(t, srv, httptest.NewRequest("GET", "/api/blob/"+id, nil)); rec.Code != 200 {
			t.Errorf("month share after 8 days: got %d, want 200", rec.Code)
		}
	}

	*clock = clock.Add(30 * 24 * time.Hour)
	if rec := do(t, srv, httptest.NewRequest("GET", "/api/blob/"+monthID, nil)); rec.Code != 404 {
		t.Errorf("month share after 38 days: got %d, want 404", rec.Code)
	}
}

// Просроченный шер перестаёт читаться сразу, но с диска его убирает
// подметальщик — и обязан убрать оба файла, а не только мету.
func TestSweepRemovesBothFiles(t *testing.T) {
	srv, clock := newTestServer(t)
	id, _ := create(t, srv, "ciphertext", "week")
	live, _ := create(t, srv, "alive", "month")

	*clock = clock.Add(8 * 24 * time.Hour)
	if n := srv.store.Sweep(*clock); n != 1 {
		t.Fatalf("swept %d, want 1", n)
	}
	for _, path := range []string{srv.store.blobPath(id), srv.store.metaPath(id)} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("%s survived the sweep", filepath.Base(path))
		}
	}
	if _, err := os.Stat(srv.store.blobPath(live)); err != nil {
		t.Errorf("live share was swept: %v", err)
	}
}

// id склеивается с путём каталога, поэтому это то самое место, где «..»
// читает чужой файл. Проверяется форма, а не отсутствие обхода.
func TestIDShapeIsEnforced(t *testing.T) {
	bad := []string{
		"", "short", "../../../../etc/passwd",
		"..%2f..%2fetc%2fpasswd",
		"AAAAAAAAAAAAAAAAAAAAA",   // 21
		"AAAAAAAAAAAAAAAAAAAAAAA", // 23
		"AAAAAAAAAAAAAAAAAAAA.A",  // точка не из алфавита
		"AAAAAAAAAAAAAAAAAAAA/A",
	}
	for _, id := range bad {
		if validID(id) {
			t.Errorf("validID(%q) = true", id)
		}
	}
	if !validID("aZ09-_aZ09-_aZ09-_aZ09") {
		t.Error("valid base64url id rejected")
	}
}

func TestBlobTooLarge(t *testing.T) {
	srv, _ := newTestServer(t)
	req := httptest.NewRequest("POST", "/api/shares", bytes.NewBuffer(make([]byte, maxBlobBytes+1)))
	req.Header.Set("Authorization", "Bearer "+secret)
	if rec := do(t, srv, req); rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("got %d, want 413", rec.Code)
	}
}

// Страница отдаётся под любым правильным id, даже несуществующим: иначе её код
// ответа стал бы оракулом существования ещё до расшифровки.
func TestViewerIsNotAnExistenceOracle(t *testing.T) {
	srv, _ := newTestServer(t)
	id, _ := create(t, srv, "ciphertext", "month")

	real := do(t, srv, httptest.NewRequest("GET", "/s/"+id, nil))
	fake := do(t, srv, httptest.NewRequest("GET", "/s/AAAAAAAAAAAAAAAAAAAAAA", nil))
	if real.Code != 200 || fake.Code != 200 {
		t.Fatalf("viewer: real %d, fake %d, want both 200", real.Code, fake.Code)
	}
	if real.Body.Len() != fake.Body.Len() {
		t.Error("viewer differs between an existing and a missing share")
	}
	if got := real.Header().Get("X-Robots-Tag"); got != "noindex, nofollow" {
		t.Errorf("X-Robots-Tag = %q", got)
	}
}

// Кэш, переживший отзыв, сделал бы «Снять с публикации» бессмысленным.
//
// Отказы проверяются вместе с удачными ответами: заголовки раньше ставил
// каждый обработчик сам, и 401 с 404 уезжали голыми. Плюс ровно одна строка
// на заголовок — двойную ставили обработчик и Caddy разом.
func TestNoAnswerIsCacheableIncludingRefusals(t *testing.T) {
	srv, _ := newTestServer(t)
	id, _ := create(t, srv, "ciphertext", "month")

	cases := map[string]*http.Request{
		"viewer":  httptest.NewRequest("GET", "/s/"+id, nil),
		"blob":    httptest.NewRequest("GET", "/api/blob/"+id, nil),
		"health":  httptest.NewRequest("GET", "/api/health", nil),
		"missing": httptest.NewRequest("GET", "/api/blob/AAAAAAAAAAAAAAAAAAAAAA", nil),
		"denied":  httptest.NewRequest("POST", "/api/shares", bytes.NewBufferString("x")),
	}
	for name, req := range cases {
		rec := do(t, srv, req)
		values := rec.Header().Values("Cache-Control")
		if len(values) != 1 || values[0] != "private, no-store" {
			t.Errorf("%s: Cache-Control = %q", name, values)
		}
		if got := rec.Header().Values("X-Robots-Tag"); len(got) != 1 {
			t.Errorf("%s: X-Robots-Tag = %q", name, got)
		}
	}
}

func TestRateLimit(t *testing.T) {
	srv, _ := newTestServer(t)
	id, _ := create(t, srv, "ciphertext", "month")

	seen429 := false
	for range 25 {
		rec := do(t, srv, httptest.NewRequest("GET", "/api/blob/"+id, nil))
		if rec.Code == 429 {
			seen429 = true
			break
		}
	}
	if !seen429 {
		t.Fatal("rate limiter never fired over 25 reads from one address")
	}

	// Ведро на адрес, а не на весь сервис: сосед за другим NAT не должен
	// расплачиваться за перебор.
	req := httptest.NewRequest("GET", "/api/blob/"+id, nil)
	req.Header.Set("X-Forwarded-For", "203.0.113.7")
	if rec := do(t, srv, req); rec.Code != 200 {
		t.Fatalf("another address got %d, want 200", rec.Code)
	}
}

// Ограничитель, который верит первой записи `X-Forwarded-For`, обходится одной
// строкой заголовка: клиент называет себя новым адресом на каждый запрос, а
// прокси дописывает настоящий в хвост. Ведро обязано выбираться по хвосту.
func TestAForgedForwardedForBuysNoNewBucket(t *testing.T) {
	srv, _ := newTestServer(t)
	id, _ := create(t, srv, "ciphertext", "month")

	for i := range 40 {
		req := httptest.NewRequest("GET", "/api/blob/"+id, nil)
		req.Header.Set("X-Forwarded-For", fmt.Sprintf("10.0.0.%d, 203.0.113.9", i))
		if do(t, srv, req).Code == 429 {
			return
		}
	}
	t.Fatal("forty reads from one address, each claiming a different one, never hit the limit")
}
