package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Хранилище шеров — каталог с двумя файлами на шер и больше ничем.
//
// Базы нет сознательно: у шера ровно один ключ доступа (id), никаких запросов
// кроме «дай по id» не существует, а листинга нет по контракту (SERVER.md §3.6).
// Файловая система уже умеет всё, что здесь нужно, и переживает kill -9 без
// восстановления журнала — в отличие от SQLite, которому для этого нужен CGO
// либо чистая реализация в зависимостях.
//
//	<id>.bin   шифротекст как прислали, ни байтом больше
//	<id>.json  {"exp": unix-секунды, "th": sha256(token) в hex}
//
// Токена отзыва в открытом виде на сервере нет: он у владельца в приложении,
// здесь только его хеш. Утечка каталога не даёт снять чужую публикацию.
type Store struct {
	dir string
}

// Мета живёт отдельным файлом, а не в начале блоба, чтобы подметание
// просроченных не открывало шифротекст вообще никогда.
type meta struct {
	Exp       int64  `json:"exp"`
	TokenHash string `json:"th"`
}

var errNotFound = errors.New("not found")

func NewStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &Store{dir: dir}, nil
}

// Идентификатор шера: 16 случайных байт в base64url без набивки — 22 символа.
//
// Это единственное, что защищает существование записи (содержимое защищено
// ключом, которого сервер не видит). 2^128 не перебирается, но id всё равно
// проверяется на занятость: коллизия здесь означала бы затирание чужого шера.
func (s *Store) newID() (string, error) {
	for range 8 {
		id, err := randomToken()
		if err != nil {
			return "", err
		}
		if _, err := os.Stat(s.metaPath(id)); os.IsNotExist(err) {
			return id, nil
		}
	}
	return "", errors.New("id space exhausted")
}

func randomToken() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b[:]), nil
}

func (s *Store) blobPath(id string) string { return filepath.Join(s.dir, id+".bin") }
func (s *Store) metaPath(id string) string { return filepath.Join(s.dir, id+".json") }

// Put кладёт шифротекст и возвращает id и токен отзыва.
//
// Порядок записи — блоб, потом мета: наоборот получился бы момент, в который
// шер уже «существует», а читать нечего. Оба файла пишутся во временный и
// переименовываются, так что оборванная запись не оставляет половину.
func (s *Store) Put(blob []byte, expires time.Time) (id, token string, err error) {
	id, err = s.newID()
	if err != nil {
		return "", "", err
	}
	token, err = randomToken()
	if err != nil {
		return "", "", err
	}
	if err := writeAtomic(s.blobPath(id), blob); err != nil {
		return "", "", err
	}
	m, err := json.Marshal(meta{Exp: expires.Unix(), TokenHash: hashToken(token)})
	if err != nil {
		return "", "", err
	}
	if err := writeAtomic(s.metaPath(id), m); err != nil {
		os.Remove(s.blobPath(id))
		return "", "", err
	}
	return id, token, nil
}

// Get отдаёт шифротекст и срок, до которого он жив. Просроченный шер
// неотличим от несуществующего уже здесь, а не в обработчике: так ошибиться
// в одном из вызовов невозможно.
//
// Срок отдаётся наружу заголовком, чтобы страница могла сказать читателю, что
// ссылка временная. Нового знания это никому не даёт: спросить срок можно
// только по id, а ответ 200 и без того означает «шер существует».
func (s *Store) Get(id string, now time.Time) (blob []byte, expires time.Time, err error) {
	if !validID(id) {
		return nil, time.Time{}, errNotFound
	}
	m, err := s.meta(id)
	if err != nil {
		return nil, time.Time{}, errNotFound
	}
	if now.Unix() >= m.Exp {
		return nil, time.Time{}, errNotFound
	}
	blob, err = os.ReadFile(s.blobPath(id))
	if err != nil {
		return nil, time.Time{}, errNotFound
	}
	return blob, time.Unix(m.Exp, 0), nil
}

// Delete снимает публикацию. Неверный токен отвечает тем же, чем отсутствие
// шера: иначе по ответу можно было бы узнать, что такой id занят.
func (s *Store) Delete(id, token string, now time.Time) error {
	if !validID(id) || !validID(token) {
		return errNotFound
	}
	m, err := s.meta(id)
	if err != nil || now.Unix() >= m.Exp {
		return errNotFound
	}
	if subtle.ConstantTimeCompare([]byte(m.TokenHash), []byte(hashToken(token))) != 1 {
		return errNotFound
	}
	os.Remove(s.blobPath(id))
	os.Remove(s.metaPath(id))
	return nil
}

// Sweep удаляет просроченное. Читается только мета: подметальщик не имеет
// повода открывать шифротекст, и не открывает.
func (s *Store) Sweep(now time.Time) (removed int) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return 0
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".json") {
			continue
		}
		id := strings.TrimSuffix(name, ".json")
		m, err := s.meta(id)
		if err != nil || now.Unix() >= m.Exp {
			os.Remove(s.blobPath(id))
			os.Remove(s.metaPath(id))
			removed++
		}
	}
	return removed
}

func (s *Store) meta(id string) (meta, error) {
	var m meta
	raw, err := os.ReadFile(s.metaPath(id))
	if err != nil {
		return m, err
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		return m, err
	}
	return m, nil
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// Идентификатор приходит из пути запроса, а склеивается с каталогом — то есть
// это ровно то место, где «..» превращается в чтение чужого файла. Форма id
// известна точно (22 символа алфавита base64url), поэтому проверяется она, а не
// отсутствие обхода: белый список не забывает случаев.
func validID(id string) bool {
	if len(id) != 22 {
		return false
	}
	for _, c := range []byte(id) {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '-', c == '_':
		default:
			return false
		}
	}
	return true
}

func writeAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
