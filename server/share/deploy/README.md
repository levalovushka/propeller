# Установка сервиса шеринга

Машина и всё остальное про неё — [`SERVER.md`](../../../SERVER.md). Здесь ровно
то, что делается один раз руками; дальше обновления идут через
`.github/workflows/deploy-share.yml` (push в `main`, трогающий `server/share/**`).

Первичная установка требует root; деплой из CI — нет, и это единственное, ради
чего пользователю `deploy` даётся одна строка sudo.

## 1. Пользователь, каталоги, секрет

```bash
ssh -i ~/.ssh/propeller_report root@201.24.53.31
useradd --system --no-create-home --shell /usr/sbin/nologin propshare
install -d -o propshare -g propshare -m 0700 /var/lib/propeller-share
install -d -o deploy   -g deploy   -m 0755 /opt/propeller-share
umask 077
printf 'PROPELLER_SHARE_SECRET=%s\n' "$(openssl rand -base64 32)" > /etc/propeller-share.env
chmod 600 /etc/propeller-share.env
```

Ключ из этого файла обязан совпадать с тем, что попадает в сборку. Приложение
берёт его из своего `Info.plist`, а туда его кладёт `build.sh` из файла рядом
с собой:

```bash
printf '%s' '<ключ>' > meeting-recorder/swift/.share-secret   # в .gitignore
cd meeting-recorder/swift && ./build.sh                       # «Share key embedded (…)»
```

**Не Keychain** (решение владельца 2026-08-27): в связке ключей ключ был бы
только у автора — у всех остальных «Поделиться» не работало бы вовсе, а первое
нажатие macOS вынесла бы на подтверждение. Ключ нужен каждому, кто поставил
приложение, значит он часть установки.

В репозитории его нет и быть не может: репозиторий публичный. Внутри сборки он
есть и извлекается — `plutil -p /Applications/Propeller.app/Contents/Info.plist`.
Он гейтит только **выпуск** ссылок: прочитать чужой шер им нельзя, снять чужую
публикацию нельзя. Меняется вместе здесь и в сборке, иначе разъедутся.

## 2. Юнит и одна строка sudo

```bash
# propeller-share.service лежит рядом с этим файлом
systemctl daemon-reload
systemctl enable --now propeller-share
systemctl is-active propeller-share
curl -s http://127.0.0.1:8080/api/health

# Чтобы CI мог перезапустить сервис и ничего больше:
echo 'deploy ALL=(root) NOPASSWD: /bin/systemctl restart propeller-share' \
  > /etc/sudoers.d/deploy-propeller-share
chmod 440 /etc/sudoers.d/deploy-propeller-share
visudo -c
```

## 3. Проверка снаружи

Caddy уже проксирует `/s/*` и `/api/*` на `localhost:8080` — конфиг для сервиса
править не надо.

```bash
curl -s https://propeller.report/api/health                     # ok
curl -si https://propeller.report/api/blob/AAAAAAAAAAAAAAAAAAAAAA | head -1   # 404
curl -si https://propeller.report/s/AAAAAAAAAAAAAAAAAAAAAA | head -1          # 200, вьюер
```

Последняя строка — не оплошность: страница отдаётся под любым правильным id.
404 на ней сделал бы её оракулом существования, а по контракту
(`SERVER.md` §3.6) несуществующее, просроченное и отозванное неотличимы.

## Что где лежит

| путь | что |
|---|---|
| `/opt/propeller-share/propeller-share` | бинарь, кладёт CI |
| `/var/lib/propeller-share/` | шеры: `<id>.bin` (шифротекст) и `<id>.json` (срок, хеш токена) |
| `/etc/propeller-share.env` | секрет публикации, root:root 0600 |
| `/etc/systemd/system/propeller-share.service` | юнит |

Бэкапов нет и не нужно: ссылки живут неделю или месяц, шифротекст без ключа
бесполезен, а ключей здесь нет вовсе.
