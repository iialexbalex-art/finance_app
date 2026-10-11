# Подключение FirstVDS и закрытого Timeweb S3

Подготовлено 07.10.2026. Сервер и S3 в рабочую среду пока не подключены.
Платные ресурсы не создавались. Миграция **018 уже применена**: её установка
и рабочее восстановление не входят в эти шаги.

Пакет: `backups-server-deploy.zip`. Цель: Ubuntu 24.04 LTS x86_64, Python 3.12,
1 vCPU / 2 ГБ RAM / 40 ГБ SSD. Проверки до подключения описаны в
[BACKUPS_SERVER_PREFLIGHT.md](BACKUPS_SERVER_PREFLIGHT.md).

## 1. Закрытое хранилище и ограниченный пользователь

Использовать существующий разрешённый или тестовый бакет Timeweb вне Supabase.
Новые платные услуги подключает пользователь только после решения о покупке.
Выбрать приватный доступ. Не подключать публичный сайт, CDN и публичные ACL/
политику. CORS бакета не требуется: браузер обращается к авторизованному worker.
Не задавать lifecycle, удаляющий оригиналы или живые снимки.

В Timeweb S3 → «Пользователи» создать дополнительного пользователя только для
этого бакета. Основной ключ аккаунта на сервер не передавать.
Для наиболее узких прав подготовлен `server/s3-user-policy.example.json`:
заменить `REPLACE_BUCKET_NAME` на имя бакета, а `finance-backups` — на префикс,
если выбран другой. Дополнительному пользователю не давать широких пресетов
«Управление»/«Чтение и запись» поверх кастомной роли.

Политика разрешает HEAD/GET/PUT, чтение ACL/политики бакета и удаление только
снимков/тестовых объектов. `ListBucket` нужен S3 для ответа 404 на отсутствующий
ключ вместо 403. Удаление оригиналов и реестров версий явно запрещено.
Только администратор S3 применяет кастомную роль через свой защищённый AWS
profile; основной ключ в env worker не записывается:

```sh
aws iam put-user-policy --user-name FINANCE_BACKUP_USER \
  --policy-name finance-backups-worker \
  --policy-document file://s3-user-policy.json \
  --endpoint-url https://s3.twcstorage.ru --region ru-1 --profile s3-admin
```

`s3-user-policy.json` — заполненная копия несекретного шаблона.
Это пользовательская IAM-политика, не публичная bucket policy.
Права кастомной роли на настоящем Timeweb необходимо проверить после подключения.
Если ACL/политика не читаются или условный PUT не поддерживается, проверка
завершится ошибкой; обход защиты не предусмотрен.

[Дополнительные пользователи](https://timeweb.cloud/docs/s3-storage/manage-storage/additional-users),
[кастомные роли](https://timeweb.cloud/docs/s3-storage/manage-storage/custom-user-roles),
[Python SDK и реквизиты endpoint/region](https://timeweb.cloud/docs/s3-storage/sdk/python).

## 2. Размещение пакета на Ubuntu

После подключения SSH к разрешённому серверу, от администратора:

```sh
sudo apt-get update
sudo apt-get install -y python3.12-venv unzip nginx
sudo useradd --system --home-dir /srv/finance-backups --shell /usr/sbin/nologin finance-backups
sudo install -d -o root -g root -m 0755 /opt/finance-backups
sudo unzip backups-server-deploy.zip -d /opt/finance-backups
sudo python3.12 -m venv /opt/finance-backups/venv
sudo /opt/finance-backups/venv/bin/pip install -r /opt/finance-backups/server/requirements.txt
sudo /opt/finance-backups/venv/bin/pip check
sudo install -d -o finance-backups -g finance-backups -m 0700 /srv/finance-backups
sudo install -o root -g root -m 0600 /opt/finance-backups/server/environment.example /etc/finance-backups.env
sudoedit /etc/finance-backups.env
```

Если пользователь уже существует, `useradd` повторно не выполнять. После
обновления пакета существующий env не заменять шаблоном. В архиве нет секретов,
финансовых данных или установщика SQL 018; `VERIFY_018.sql` только читает.

Через `sudoedit`/защищённые настройки сервера заполнить:

- `BACKUP_DATABASE_URL`: отдельный LOGIN с членством только в
  `finance_backup_worker`, без superuser/BYPASSRLS. Пароль задаётся
  администратором защищённо; DSN содержит `sslmode=require` или строже.
  После создания LOGIN достаточно `grant finance_backup_worker to finance_backup_login;`.
  Это выдача роли, не повторная миграция. Проверить PostgreSQL-порт/режим
  pooler из настроек этого Supabase-проекта; пароль правильно URL-кодировать.
- `SUPABASE_URL=https://bgyuxibywuxdultxsmiv.supabase.co`, publishable key
  из настроек проекта, точный `APP_ORIGIN` приложения с HTTPS без конечного `/`.
- `BACKUP_STORAGE_BACKEND=s3`, имя бакета, префикс и endpoint/region из его
  настроек; обычно `https://s3.twcstorage.ru`, `ru-1`.
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` дополнительного пользователя.
  Не вводить ключи в чат, аргументы команд, shell history или Flutter config.
- `BACKUP_INDEPENDENT=true` только для реально подключённого приватного
  Timeweb вне Supabase; оставить запас `BACKUP_MIN_FREE_BYTES=5368709120`.

Файл root:root 0600 читает systemd и передаёт env процессу service user.
Не делать env доступным всем и не использовать `systemctl show Environment`.
Нужны исходящие HTTPS к Supabase Auth/Timeweb и TLS PostgreSQL к выбранному
host/port. Входящий API только через nginx HTTPS; 8765 не открывать наружу.

## 3. Сначала реальная проверка S3, затем регистрация оригиналов

Следующая команда читает защищённый env через systemd, без секретов в аргументах:

```sh
sudo systemd-run --wait --pipe --collect --unit=finance-backups-storage-check \
  --property=User=finance-backups --property=Group=finance-backups \
  --property=WorkingDirectory=/opt/finance-backups/server \
  --property=EnvironmentFile=/etc/finance-backups.env --property=UMask=0077 \
  --property=MemoryMax=1G --property=LimitCORE=0 \
  /opt/finance-backups/venv/bin/python backup_worker.py --check-storage
```

Успех: код **0**, JSON `status=storage_verified`, `private=true`,
`conditional_put=true`. Проверка создаёт только одноразовый объект
`finance-backups/checks/<uuid>`, читает его целиком, проверяет SHA-256,
убеждается, что перезапись с `If-None-Match: *` отклонена, и удаляет пробу.
Бизнес-данные и сохранённые копии не меняются. При ошибке — остановить подключение,
исправить реквизиты/доступ/API. Не переключать backend на local ради «успеха».

Передать **всю текущую исходную папку assets без пересжатия** в
`/opt/finance-app-release/assets`, доступную service user на чтение. Не передавать
`.local-backups`, `config/local.json` или весь рабочий проект с секретами.

```sh
sudo systemd-run --wait --pipe --collect --unit=finance-backups-register \
  --property=User=finance-backups --property=Group=finance-backups \
  --property=WorkingDirectory=/opt/finance-backups/server \
  --property=EnvironmentFile=/etc/finance-backups.env --property=UMask=0077 \
  --property=MemoryMax=1G --property=LimitCORE=0 \
  /opt/finance-backups/venv/bin/python backup_worker.py --register-assets /opt/finance-app-release
```

Успех: `release_verified`, 704 пути / 703 уникальных SHA-256 текущего пакета.
Первичная загрузка оригиналов 752585718 байт плюс небольшой реестр. Повторная
регистрация не загружает те же оригиналы снова, но проверяет их через GET.
Регистрацию включать в каждое обновление assets до публикации нового приложения.

## 4. Первый реальный запуск и независимое расписание

```sh
sudo install -m 0644 /opt/finance-backups/server/finance-backups-once.service /etc/systemd/system/
sudo install -m 0644 /opt/finance-backups/server/finance-backups.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start finance-backups-once.service
sudo journalctl -u finance-backups-once.service -n 10 --no-pager
```

Это тот же `tick`, который вызывает ночной поток. `--once`:

| Код | Значение |
| --- | --- |
| 0 | Создана и проверена копия (`created_count`) либо заново проверена уже готовая (`verified_count`). |
| 1 | Сбой, готовность не подтверждена. |
| 2 | Нет заданий/владельцев или нет проверенной копии; ничего не создано. |

Убедиться в `completed`, `failed_count=0`, ненулевом `created_count` или
`verified_count`. `verified_count` не означает новую копию. Затем:

```sh
sudo systemctl enable --now finance-backups.service
sudo systemctl is-active finance-backups.service
sudo systemctl show finance-backups.service -p MemoryCurrent -p MemoryPeak -p MemoryMax
df -h /srv/finance-backups
```

Не устанавливать второй cron/timer для тех же копий. Планировщик работает
в systemd-сервисе на сервере, проверяет очередь каждые 30 секунд, время
**23:59 Asia/Qyzylorda = 18:59 UTC**. После простоя — актуальный catchup.
UUID дня исключает повторный снимок дня. `/status` проверяет живость потока,
heartbeat и максимальную длительность операции. При остановке/зависании
`scheduler_active=false`, `next_run=null`; ошибка хранения видна отдельно.

Проверить перезапуск сервиса/VPS и наблюдать хотя бы один ночной запуск.
Наличие кода расписания или успешный ручной запуск ещё не доказывает ночное
срабатывание. До развёртывания подтверждённого следующего запуска нет.

## 5. HTTPS, приложение и приёмка

Заполнить домен/пути сертификата в `server/nginx.example.conf`, проверить
`sudo nginx -t`, затем reload nginx. Доступ ограничить существующими
настройками firewall/SSH. API слушает 127.0.0.1:8765; небезопасный HTTP не
вносить в Flutter. У nginx выключен access log и буферизация больших тел.

В `config/local.json` приложения добавить только несекретный `BACKUP_API_URL`
с HTTPS-доменом и собрать с `--dart-define-from-file=config/local.json`.
Войти владельцем и открыть «Настройки → Резервные копии»:

1. Видны настоящая готовая копия, место хранения, отдельные размеры новых
   байтов/полного ZIP и следующий запуск при живом scheduler.
2. «Сохранить сейчас» и автоматическое сохранение перед массовым изменением
   работают. Сбой S3 оставляет копию failed и блокирует защищённое изменение.
   Проверять массовые изменения и restore на изолированной тестовой БД.
3. «Скачать» даёт самостоятельный ZIP со всеми оригиналами. Штатная проверка
   и восстановление проходят в отдельной совместимой тестовой среде без
   исходной папки assets/старого хранилища. Рабочую БД для проверки не восстанавливать.
4. Реальные отказ S3, неверный тестовый ключ, обрыв загрузки и повреждение
   тестового объекта не дают «Готово». Финансовые данные/ключи не появляются
   в ответах и журналах. Повреждение проверять только в отдельном тестовом префиксе.
5. Второй запуск не делает PUT неизменившихся оригиналов. Сравнить счётчики
   тестового S3/метрики, RSS/cgroup memory и временный диск на настоящем VPS.

## Ограничения и обслуживание

Одна тяжёлая операция на **одном VPS**. Общая межпроцессная файловая блокировка
в `/srv/finance-backups/.operation.lock` охватывает HTTP, scheduler, регистрацию
и `--once`. Все процессы должны использовать один корень. Несколько VPS
одновременно с этой конфигурацией не поддерживаются. Ожидание 30 секунд,
длительность работы до 25 минут; HTTP-передача до 15 минут и idle timeout 30 с.

Перед записью проверяется свободное место с резервом 5 GiB плюс размер операции.
ZIP не хранится ежедневно. Сжатые снимки занимают отдельные ключи;
дисковый кеш оригиналов сохраняется консервативно. При его росте следить за
местом: автоматического удаления нужных оригиналов нет.

Временные файлы лежат только в маркированных `.tmp/op-<uuid>`. Обрыв запроса
очищается через finally; после аварии они очищаются под общей блокировкой
на старте/следующем tick. Чужие каталоги, симлинки, живые оригиналы и снимки
эта очистка не трогает. Не удалять lock-файл при работающем процессе.

Файлы ограничены 128 MiB, JSON — 64 MiB, архив — 2 GiB. Используется потоковый
одиночный PUT с Content-MD5 и SHA-256 readback, **без multipart**: незаконченных
multipart частей этот worker не создаёт. Если PUT завершился, а ответ потерялся,
повтор принимает только идентичное содержимое. Полностью записанные объекты
незавершённого снимка сохраняются для безопасного повторения; по возрасту их
не удалять. Снимки удаляются только по ID, разрешённым SQL с pins/ретенцией.

Оригиналы адресуются по SHA-256 и записываются условно, никогда не заменяются
worker. При повреждении ключа копия отклоняется; не перезаписывать его вручную
и не снимать контрольные суммы. Защита здесь программная + ограниченные права;
это не WORM/Object Lock и не гарантия против администратора S3.
Неизменившиеся картинки не отправляются снова, но полная проверка требует
скачивания: учитывать исходящий трафик Timeweb при расчёте стоимости.

**Следующий шаг подключения:** получить SSH-доступ к разрешённому тестовому
Ubuntu 24.04 серверу (существующему/пробному), развернуть этот пакет и заполнить
`/etc/finance-backups.env` через защищённый редактор. Первый критерий приёмки —
успешный `--check-storage` из раздела 3. Пароли и ключи в чат не передавать.
