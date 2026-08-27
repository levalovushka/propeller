package main

import (
	"crypto/subtle"
	"embed"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// Сервис шеринга саммари по ссылке. Контракт — SERVER.md §3.
//
// Сервер не видит содержимого: приложение шифрует саммари ключом, который
// уезжает во фрагменте ссылки (после «#») и на сервер не отправляется никогда.
// Здесь лежат байты, срок и хеш токена отзыва — и всё.
//
// Из этого следует всё остальное устройство: листинга нет, поиска нет, статуса
// «есть такой шер?» нет. Несуществующее, просроченное и отозванное отвечают
// одним и тем же пустым 404 (§3.6) — иначе сервер становится справочником о
// том, кто чем делился.

//go:embed viewer/index.html
var viewerFS embed.FS

const (
	// Саммари — это текст. Мегабайт gzip'нутого текста это уже не саммари,
	// а чья-то ошибка или чей-то умысел; два — потолок с запасом вдвое.
	maxBlobBytes = 2 << 20

	week  = 7 * 24 * time.Hour
	month = 30 * 24 * time.Hour
)

type server struct {
	store  *Store
	viewer []byte
	secret string
	limit  *limiter
	now    func() time.Time
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8080", "listen address")
	dir := flag.String("dir", "/var/lib/propeller-share", "share storage directory")
	flag.Parse()

	secret := os.Getenv("PROPELLER_SHARE_SECRET")
	// Пустой секрет означал бы, что публиковать может кто угодно. Это не то
	// состояние, в котором стоит подниматься и ждать первого запроса.
	if len(secret) < 16 {
		log.Fatal("PROPELLER_SHARE_SECRET is missing or shorter than 16 chars")
	}

	store, err := NewStore(*dir)
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	srv, err := newServer(store, secret)
	if err != nil {
		log.Fatalf("viewer: %v", err)
	}

	go srv.sweepForever()

	log.Printf("propeller-share listening on %s, dir %s", *addr, *dir)
	http.ListenAndServe(*addr, srv.routes())
}

func newServer(store *Store, secret string) (*server, error) {
	viewer, err := viewerFS.ReadFile("viewer/index.html")
	if err != nil {
		return nil, err
	}
	return &server{
		store:  store,
		viewer: viewer,
		secret: secret,
		// Страница и блоб — два запроса; шестьдесят в минуту это тридцать
		// открытий, чего живому читателю хватает с большим запасом.
		limit: newLimiter(60, 20),
		now:   time.Now,
	}, nil
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/shares", s.handleCreate)
	mux.HandleFunc("DELETE /api/shares/{id}", s.handleDelete)
	mux.HandleFunc("GET /api/blob/{id}", s.handleBlob)
	mux.HandleFunc("GET /api/health", s.handleHealth)
	mux.HandleFunc("GET /s/{id}", s.handleViewer)
	return mux
}

func (s *server) sweepForever() {
	for {
		time.Sleep(time.Hour)
		now := s.now()
		if n := s.store.Sweep(now); n > 0 {
			log.Printf("swept %d expired shares", n)
		}
		s.limit.sweep(now)
	}
}

// POST /api/shares?ttl=week|month — тело это шифротекст как есть.
//
// Сырые байты, а не JSON с base64: блоб и так непрозрачен, а base64 — это
// треть лишнего трафика и лишний повод его разбирать.
func (s *server) handleCreate(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	var ttl time.Duration
	switch r.URL.Query().Get("ttl") {
	case "week":
		ttl = week
	case "month", "":
		ttl = month
	default:
		// Вечных ссылок нет: бэкапов у сервера нет осознанно (SERVER.md §1),
		// и обещание, которое переживёт машину, было бы враньём.
		http.Error(w, "ttl must be week or month", http.StatusBadRequest)
		return
	}

	blob, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBlobBytes))
	if err != nil {
		http.Error(w, "body too large", http.StatusRequestEntityTooLarge)
		return
	}
	if len(blob) == 0 {
		http.Error(w, "empty body", http.StatusBadRequest)
		return
	}

	expires := s.now().Add(ttl)
	id, token, err := s.store.Put(blob, expires)
	if err != nil {
		log.Printf("put: %v", err)
		http.Error(w, "storage failure", http.StatusInternalServerError)
		return
	}
	noStore(w)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"id":        id,
		"token":     token,
		"expiresAt": expires.Unix(),
	})
}

func (s *server) handleDelete(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	err := s.store.Delete(r.PathValue("id"), r.Header.Get("X-Share-Token"), s.now())
	noStore(w)
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleBlob(w http.ResponseWriter, r *http.Request) {
	if !s.limit.allow(clientIP(r), s.now()) {
		w.WriteHeader(http.StatusTooManyRequests)
		return
	}
	blob, err := s.store.Get(r.PathValue("id"), s.now())
	noStore(w)
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(blob)
}

// Страница отдаётся под любым правильным id, даже несуществующим.
//
// Это не небрежность: 404 на самой странице сделал бы её оракулом
// существования — по коду ответа было бы видно, что ссылка живая, ещё до
// расшифровки. «Ссылки больше нет» рисует сам вьюер, получив 404 на блоб.
func (s *server) handleViewer(w http.ResponseWriter, r *http.Request) {
	if !s.limit.allow(clientIP(r), s.now()) {
		w.WriteHeader(http.StatusTooManyRequests)
		return
	}
	if !validID(r.PathValue("id")) {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	noStore(w)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("X-Robots-Tag", "noindex, nofollow")
	w.Write(s.viewer)
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	noStore(w)
	w.Write([]byte("ok\n"))
}

func (s *server) authorized(r *http.Request) bool {
	header := r.Header.Get("Authorization")
	token, ok := strings.CutPrefix(header, "Bearer ")
	if !ok {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(s.secret)) == 1
}

// Ничего из этого сервиса не кэшируется. Промежуточный кэш, сохранивший
// шифротекст, пережил бы отзыв публикации — то есть «Снять с публикации»
// перестало бы что-либо значить.
func noStore(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
}
