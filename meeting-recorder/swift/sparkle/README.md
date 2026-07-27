# Sparkle (авто-обновления)

Ключи EdDSA для подписи DMG в appcast.

| Файл | Куда |
|------|------|
| `eddsa_pub.txt` | **в git** — попадает в Info.plist как `SUPublicEDKey` |
| `private/eddsa_priv.key` | **НЕ в git** — Keychain (`--account propeller`) + локальный бэкап |

Feed URL по умолчанию:

`https://github.com/levalovushka/propeller/releases/latest/download/appcast.xml`

## Новый ключ (один раз)

```bash
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
$SPARKLE_BIN/generate_keys --account propeller
$SPARKLE_BIN/generate_keys --account propeller -p > sparkle/eddsa_pub.txt
$SPARKLE_BIN/generate_keys --account propeller -x sparkle/private/eddsa_priv.key
```

## Релиз

```bash
./build.sh && ./package-dmg.sh && ./make-appcast.sh
# Залей DMG + appcast.xml в GitHub Release (assets с именами из make-appcast)
```
