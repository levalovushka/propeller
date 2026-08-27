package main

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Ограничитель на чтение — единственное, что стоит между 2^128 и перебором.
//
// Перебрать id нельзя, но попытка стоит нам диска и трафика, а владельцу —
// счёта. Ведро на IP: `rate` пополнений в секунду, потолок `burst`. Читатель
// саммари делает два запроса (страница и блоб), так что даже десяток —
// это уже не человек.
type limiter struct {
	rate  float64
	burst float64

	mu      sync.Mutex
	buckets map[string]*bucket
}

type bucket struct {
	tokens float64
	seen   time.Time
}

func newLimiter(perMinute, burst int) *limiter {
	return &limiter{
		rate:    float64(perMinute) / 60,
		burst:   float64(burst),
		buckets: make(map[string]*bucket),
	}
}

func (l *limiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{tokens: l.burst, seen: now}
		l.buckets[key] = b
	}
	b.tokens += now.Sub(b.seen).Seconds() * l.rate
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.seen = now

	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// Забытые вёдра выметаются вместе с просроченными шерами: карта на IP растёт
// от любого сканера, а полное ведро неотличимо от отсутствующего.
func (l *limiter) sweep(now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for key, b := range l.buckets {
		if now.Sub(b.seen) > 10*time.Minute {
			delete(l.buckets, key)
		}
	}
}

// Чей это запрос — с точки зрения ограничителя.
//
// Сервис слушает только петлю и стоит за Caddy, поэтому `RemoteAddr` всегда
// 127.0.0.1, а настоящий адрес приходит заголовком.
//
// Берётся **последняя** запись `X-Forwarded-For`, а не первая. Первая — это
// то, что клиент назвал о себе сам: прокси дописывает настоящий адрес в
// хвост, не трогая присланное. Ограничитель, читающий первую запись,
// обходится одной строкой заголовка — новое ведро на каждый запрос. Caddy у
// нас вдобавок перезаписывает заголовок целиком (`header_up`), так что
// запись обычно одна; последняя верна и в этом случае, и если однажды перед
// сервисом окажется второй прокси.
func clientIP(r *http.Request) string {
	if values := r.Header.Values("X-Forwarded-For"); len(values) > 0 {
		hops := strings.Split(values[len(values)-1], ",")
		if ip := strings.TrimSpace(hops[len(hops)-1]); ip != "" {
			return ip
		}
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}
