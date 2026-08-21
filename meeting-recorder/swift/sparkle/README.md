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
./build.sh && ./notarize.sh && ./package-dmg.sh && ./make-appcast.sh
# Залей ВСЁ, что напечатал make-appcast: DMG + Propeller.dmg + appcast.xml + *.delta
# (он печатает готовую строку gh release upload)
```

`make-appcast.sh` кладёт в фид дельта-патчи к пяти предыдущим образам: полный DMG —
282 МБ, патч 1.16.6 → 1.16.7 — 1,0 МБ. Кто сидит на версии старше, чем есть патч,
качает полный образ, как раньше.

Перед печатью он применяет каждый патч к тому образу, который тот патчит, и сверяет
результат с приложением из этого релиза — файл за файлом (sha256, права, симлинки),
плюс `codesign` и `stapler`. Полный прогон ≈ 18 с. `VERIFY_DELTAS=0` выключает
проверку — только для отладки самого скрипта, не для релиза.
