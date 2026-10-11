# Flutter Web в Docker с Caddy

Подготовка выполнена 11 октября 2026. Публичный сайт не развёрнут; DNS и VPS не изменялись. База остаётся в Supabase. Контейнер сайта не выполняет SQL и не запускает установщики.

## Файлы и версии

- `Dockerfile`: builder на Ubuntu 24.04, Flutter 3.47.5, Dart 3.13.4; тег Flutter дополнительно проверяется по коммиту `6a19cca56475dbfba1478ee68d7bd0c2ef891da1`. Runtime — Caddy 2.10.2 Alpine и `/srv` из `build/web`. SDK, `.git`, Dart-исходники и инструменты builder в runtime не копируются.
- `.dockerignore`: разрешает только Flutter-исходники, web, runtime assets, файлы зависимостей и два вспомогательных файла сборки. Реальная конфигурация поступает отдельно через BuildKit secret. IDE, `.git`, дампы, архивы, серверный Python, SQL, source_assets и локальные резервные копии не входят в контекст.
- `Caddyfile`: hostname из `SITE_DOMAIN`, автоматический публичный HTTPS и HTTP → HTTPS, SPA fallback только для GET/HEAD без признаков статического ресурса, отдельные 404 для ресурсов/API, gzip/zstd и обязательная перепроверка кэша. `/srv` — файлы внутри образа. Health endpoint слушает только loopback:8081.
- `compose.yaml`: один сайт, TCP 80/443, постоянные именованные volumes Caddy, `unless-stopped`, json-file логи 3 × 10 МБ, проверка файлов и HTTP-запрос BusyBox wget. PostgreSQL, Redis, Nginx, Docker socket и bind mounts отсутствуют.
- `.env.deploy.example`: пример runtime-настроек; скопировать в `.env.deploy`, который исключён из Git.
- `deploy/validate_client_config.py`: проверка разрешённых ключей JSON и SHA-256 для корректного сброса build cache при изменении настроек.
- `web/flutter_bootstrap.js`, `deploy/flutter_service_worker.js`: отключают старый Flutter offline cache; не удаляют localStorage, Supabase-сессию или журнал операций.
- `deploy/verify_web_http.py`: HTTP smoke-проверки, Python standard library, без обращения к БД.

Образы builder/runtime дополнительно закреплены по digest в Dockerfile. Их обновляют отдельным изменением после проверки, а не через `latest`.

## Настройки и архитектура

До сборки узнать на VPS `uname -m`: `x86_64` → `linux/amd64`, `aarch64` → `linux/arm64`. Другие архитектуры пока не поддерживаются этим процессом. **Пример amd64 не означает, что ваш VPS уже проверен.**

`SITE_PLATFORM` обязателен в Compose и `--platform` обязателен в приведённых командах buildx. Runtime Caddy выбирается для VPS, независимо от архитектуры локального компьютера. Builder намеренно Linux amd64: на ARM-компьютере потребуется настроенный Docker Desktop/BuildKit с эмуляцией x86_64. Результат Flutter Web — JS/Wasm и ресурсы, не нативный серверный бинарный файл. На слабом VPS запускать готовый образ из реестра.

Клиентские настройки передаются **при сборке** через существующий `--dart-define-from-file`. Подготовить приватный `config/local.json` по `config/example.json`:

```json
{
  "SUPABASE_URL": "https://YOUR_PROJECT.supabase.co",
  "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_REPLACE_WITH_PUBLIC_KEY",
  "BACKUP_API_URL": ""
}
```

Разрешены только эти три ключа. Приложение и валидатор требуют новый `sb_publishable_` ключ, не legacy JWT anon. `BACKUP_API_URL` необязателен: оставить пустым, если отдельный сервер резервных копий ещё не подключён. Если используется — это публичный HTTPS адрес его API без пароля или токена; сервер отдельно должен разрешать Origin сайта. Здесь этот сервер не разворачивается.

`service_role`, `sb_secret_`, пароль БД, S3/AWS ключи, приватные ключи и прочие административные настройки запрещены в этом JSON. BuildKit secret скрывает исходный файл от контекста и слоёв, **но разрешённые значения будут видны в браузерном JS**. Доступ к данным обеспечивается Supabase Auth и RLS, а не скрытием публичного ключа.

`CLIENT_CONFIG_SHA256` должен совпадать с хешем именно переданного JSON. BuildKit не учитывает изменение содержимого secret при кэшировании; новый хеш меняет слой сборки. Runtime environment контейнера не меняет скомпилированные клиентские настройки. Для их изменения нужен новый образ и новый release tag.

Заменить `finance.example.com` в `.env.deploy` и командах DNS/HTTPS; `YOUR_PROJECT` и publishable key — только в локальном клиентском JSON; `VPS_IP`, `deploy`, путь SSH-ключа/порт — в SSH/SCP командах. `SITE_IMAGE` заменить на выбранный реестр и уникальный тег, например `ghcr.io/iialexbalex-art/finance_app:web-20261011-1`. Не перезаписывать существующий release tag. Для строгого закрепления после push можно использовать `имя:тег@sha256:...`.

## Локальный компьютер — PowerShell

Нужны Docker Desktop в режиме Linux containers и работающий buildx. Сейчас Docker на этой машине не установлен. Установка Docker Desktop и настройка виртуализации выполняются отдельно.

```powershell
cd D:\finance_app
Copy-Item .env.deploy.example .env.deploy
# Отредактировать .env.deploy: домен, архитектуру VPS и release tag.
docker version
docker buildx version
docker compose --env-file .env.deploy config --quiet

# Эти значения согласовать с .env.deploy и результатом uname -m на VPS.
$sitePlatform = 'linux/amd64'
$siteImage = 'ghcr.io/iialexbalex-art/finance_app:web-20261011-1'
$clientHash = (Get-FileHash config/local.json -Algorithm SHA256).Hash.ToLower()

# Локальная сборка одной целевой архитектуры.
docker buildx build --platform $sitePlatform --load --tag $siteImage --secret id=client_config,src=config/local.json --build-arg CLIENT_CONFIG_SHA256=$clientHash .
```

Проверить runtime, не публикуя домен и не занимая локальные 80/443:

```powershell
docker run --detach --name finance-web-smoke --platform $sitePlatform --publish 127.0.0.1:18080:80 --env SITE_DOMAIN=http://127.0.0.1 --volume finance_web_smoke_data:/data --volume finance_web_smoke_config:/config $siteImage
docker inspect --format '{{json .State.Health}}' finance-web-smoke
python deploy/verify_web_http.py http://127.0.0.1:18080
# Если Python отсутствует в PATH: uv run --no-project python deploy/verify_web_http.py http://127.0.0.1:18080

docker exec finance-web-smoke sh -c 'command -v wget; test -s /srv/main.dart.js; test ! -e /opt/flutter; test ! -e /app; test ! -e /srv/config/local.json; ! command -v git; ! command -v dart; ! command -v flutter'
docker image inspect --format '{{.Os}}/{{.Architecture}}' $siteImage
docker history --no-trunc $siteImage
```

Проверка отсутствия серверных секретов: изучить `docker history`, `docker image inspect` и файлы `/srv`. Для проверки всего образа, включая слои, использовать `docker image save` в **приватный** каталог `.local-backups`, распаковать все layer tar и просканировать известные серверные секреты локально, не выводя их значения. Публичный publishable key обнаруживаться должен. Если реальные серверные значения недоступны аудитору, нельзя объявлять полный поиск таких значений выполненным. Allowlist контекста и отсутствие секретов в build arguments дополнительно уменьшают риск, но не заменяют эту проверку готового образа.

Проверить сохранение volumes при пересоздании без удаления данных:

```powershell
docker exec finance-web-smoke sh -c 'printf persistence-test > /data/.finance-qa; printf persistence-test > /config/.finance-qa'
docker rm --force finance-web-smoke
docker run --detach --name finance-web-smoke --platform $sitePlatform --publish 127.0.0.1:18080:80 --env SITE_DOMAIN=http://127.0.0.1 --volume finance_web_smoke_data:/data --volume finance_web_smoke_config:/config $siteImage
docker exec finance-web-smoke sh -c 'test "$(cat /data/.finance-qa)" = persistence-test && test "$(cat /config/.finance-qa)" = persistence-test'
docker exec finance-web-smoke rm /data/.finance-qa /config/.finance-qa
```

Это проверка хранения, не выдачи настоящего сертификата. Затем собрать вторую отличимую версию под новым тегом, повторить запуск с теми же volumes, проверить HTTP и браузерную свежесть; вернуть предыдущий тег и повторить проверки. Контейнер smoke удалить после работы; его volumes можно оставить. Не использовать команды удаления production volumes.

### Доставка через реестр / CI

```powershell
docker login ghcr.io
# Аутентификация локально: PAT с нужными правами или CI credential; не в Dockerfile/JSON.
docker buildx build --platform $sitePlatform --push --tag $siteImage --secret id=client_config,src=config/local.json --build-arg CLIENT_CONFIG_SHA256=$clientHash .
# При необходимости обе архитектуры: --platform linux/amd64,linux/arm64
# Для multi-platform push нужен buildx builder с поддержкой этих платформ.
```

В CI подготовить JSON как временный файл из **только публичных** переменных, вычислить его SHA-256, передать secret mount и выполнить эту же сборку/push с уникальным release tag. Доступ к реестру хранить в CI secrets. Не передавать клиентской сборке административные секреты Supabase/БД/S3. Публичный деплой не настроен. Ручная проверочная сборка GitHub Actions описана ниже.

## Ubuntu VPS — сначала обследование

С локального компьютера:

```powershell
ssh -p 22 -i C:\Users\YOUR_USER\.ssh\id_ed25519 deploy@VPS_IP
```

Проверить fingerprint сервера по данным провайдера. Использовать ваш реальный SSH порт и ключ. На VPS:

```bash
uname -m
cat /etc/os-release
sudo ss -ltnp '( sport = :80 or sport = :443 )'
sudo ss -lunp '( sport = :443 )'
sudo sshd -T | awk '$1 == "port" {print}'
sudo ufw status verbose
docker version
sudo systemctl status docker --no-pager
dpkg -l docker.io docker-compose docker-compose-v2 podman-docker containerd runc 2>/dev/null
```

Если 80/443 заняты панелью управления или существующим сайтом, **остановиться и согласовать освобождение портов или отдельный IP/VPS**. Caddy этой конфигурации должен сам принимать 80/443. Не останавливать службы, не удалять Docker/containerd и не менять настройки панели автоматически. Если Docker уже используется, проверить совместимость и сохранить существующие контейнеры.

### Установка Docker Engine и Compose plugin

Для чистого совместимого Ubuntu 24.04 LTS, после проверки конфликтов, выполнить установку из официального apt-репозитория. Если обнаружены конфликтующие пакеты — сначала отдельно согласовать их миграцию; команд слепого удаления здесь нет.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl dnsutils
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$VERSION_CODENAME" "$(dpkg --print-architecture)" | sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo docker version
sudo docker compose version
```

Docker-команды на VPS далее используют `sudo`; добавление пользователя в группу docker здесь не требуется. Установочные версии Engine/Compose выбрать из поддерживаемых apt-пакетов Ubuntu, записать для эксплуатации; версии образов приложения закреплены отдельно.

### DNS и firewall

У провайдера DNS создать A-запись `finance.example.com` → `VPS_IP` (публичный IPv4). AAAA добавлять **только** при рабочем IPv6 на VPS и доступном TCP 80/443 по IPv6. Неправильную прежнюю AAAA исправить отдельно после проверки. Если DNS-провайдер включает HTTP proxy, для первой прямой проверки использовать режим DNS only; не менять существующую конфигурацию вслепую.

```bash
dig +short A finance.example.com
dig +short AAAA finance.example.com
```

Проверить правила у провайдера VPS, firewall ОС и ограничения панели. Разрешить входящий TCP 80 и 443. Сохранить используемый SSH порт и доступ из второго SSH-сеанса перед изменениями. Если **UFW уже управляет firewall**, после просмотра правил допустимы:

```bash
SSH_PORT=22  # заменить фактическим SSH портом из обследования
sudo ufw allow "$SSH_PORT/tcp"
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status verbose
```

Не выполнять `ufw reset`/`ufw enable` автоматически. Docker published ports могут обходить обычные UFW правила; ограничения доступа проверять также на firewall провайдера и в цепочке DOCKER-USER. В этой конфигурации наружу публикуются только TCP 80/443; health и Caddy admin API не публикуются.

## Ubuntu VPS — запуск готового образа

После реального разрешения на публикацию и проверки DNS/портов создать каталог релиза; доставить только `compose.yaml` и заполненный `.env.deploy` (например SCP с локального компьютера):

```powershell
scp -P 22 compose.yaml .env.deploy deploy@VPS_IP:/home/deploy/finance-web/
```

Каталог назначения должен уже существовать. На VPS:

```bash
mkdir -p /home/deploy/finance-web
cd /home/deploy/finance-web
chmod 600 .env.deploy
# Для приватного GHCR: sudo docker login ghcr.io
sudo docker compose --env-file .env.deploy config --quiet
sudo docker compose --env-file .env.deploy pull site
sudo docker compose --env-file .env.deploy up -d --no-build
sudo docker compose --env-file .env.deploy ps
sudo docker compose --env-file .env.deploy logs --tail=100 site
```

Caddy получает сертификат автоматически, если hostname и публичный DNS корректны, ACME доступен и порты открыты. На машине вне VPS:

```bash
curl -I http://finance.example.com
curl -I https://finance.example.com
python3 deploy/verify_web_http.py https://finance.example.com
```

Ожидаются HTTP → HTTPS redirect, валидный сертификат без `-k`, HTTP 200 для главной/существующих ресурсов/SPA оболочки, 404 для отсутствующих ресурсов. Health можно проверить на VPS:

```bash
sudo docker compose --env-file .env.deploy exec site wget -q -O /dev/null http://127.0.0.1:8081/healthz
sudo docker inspect --format '{{json .State.Health}}' "$(sudo docker compose --env-file .env.deploy ps -q site)"
sudo docker compose --env-file .env.deploy logs --follow --tail=100 site
```

Получение сертификата **не проверено**, пока эти команды не выполнены для вашего реального домена. HTTP health сам по себе не подтверждает внешнюю доступность или HTTPS.

## Маршруты, кэш и Supabase перед публикацией

В текущем Dart-коде `MaterialApp(home: ...)`; разделы переключаются через `AppSection`, без GoRouter и URL-путей разделов. Caddy возвращает оболочку приложения на extensionless путях (например `/reports`) для обновления страницы/будущей маршрутизации; это **не добавляет навигацию к разделу по URL**. Фрагментные маршруты `/#/...` обрабатываются браузером. Пути ресурсов с расширением и `/assets/*`, `/icons/*`, `/canvaskit/*`, `/api/*` не получают SPA fallback.

Все файлы обязаны перепроверяться через `Cache-Control: no-cache, max-age=0, must-revalidate`; `immutable` для ресурсов с неизменными именами не используется. ETag/304 экономят трафик. Новая версия загружается при следующем открытии/обновлении страницы; уже открытая вкладка не превращается мгновенно в новую версию. Сборка включает локальный CanvasKit (`--no-web-resources-cdn`).

Старый service worker получает retirement script по прежнему `/flutter_service_worker.js`; activation удаляет только три известных Flutter cache и отменяет регистрацию. Новый bootstrap также удаляет прежние регистрации Flutter и при необходимости перезагружает контролируемую вкладку. Новый offline worker не регистрируется; offline-режим намеренно не обещается. На браузере с ранее установленной версией проверить обновление без очистки данных сайта. Изменение origin (localhost → домен) создаёт отдельное хранилище браузера: прежний локальный журнал автоматически не переносится.

Реальный вход сейчас использует `signInWithPassword`, выход — local scope. До публикации вручную проверить владельца и менеджера: вход, обновление вкладки, выход, отсутствие доступа к чужим пространствам/запрещённым кошелькам/остаткам, фактические запреты Supabase RLS при прямом API-запросе с токеном менеджера. Не откатывать рабочую БД ради проверки; использовать согласованные тестовые аккаунты/записи.

В Supabase Auth → URL Configuration проверить `Site URL=https://finance.example.com`. Для magic link, OAuth, reset password, email confirmation или других redirect flows добавить точные разрешённые HTTPS URL, соответствующие реально используемому callback. Эти flows сейчас в коде не реализованы; не придумывать callback и не использовать широкие production wildcards. Настройки менять только при согласованном запуске. [Документация Supabase](https://supabase.com/docs/guides/auth/redirect-urls).

## Обновление, откат и volumes

Сначала собрать/проверить новый образ на компьютере или в CI и отправить новый уникальный тег. На VPS сохранить прежний `.env.deploy` приватно, изменить **только** `SITE_IMAGE` на новый тег, проверить и пересоздать сайт:

```bash
cd /home/deploy/finance-web
cp -p .env.deploy .env.deploy.previous
# Отредактировать SITE_IMAGE в .env.deploy.
sudo docker compose --env-file .env.deploy config --quiet
sudo docker compose --env-file .env.deploy pull site
sudo docker compose --env-file .env.deploy up -d --no-build
sudo docker compose --env-file .env.deploy ps
sudo docker compose --env-file .env.deploy logs --tail=100 site
```

Проверить HTTPS, smoke-тесты и новую версию в браузере. При ошибке вернуть предыдущую конфигурацию/тег:

```bash
cp -p .env.deploy.previous .env.deploy
sudo docker compose --env-file .env.deploy pull site
sudo docker compose --env-file .env.deploy up -d --no-build
```

Этот откат меняет только приложение, не данные Supabase. Хранить предыдущий образ в реестре. Обычное обновление не требует `down`, `down -v` или `docker volume prune`.

Volumes `finance_web_caddy_data` и `finance_web_caddy_config` имеют стабильные имена. Не удалять их при пересоздании контейнера, переезде Compose-файла или откате. `/data` содержит ACME аккаунт/сертификаты/приватные ключи, `/config` — состояние Caddy. Для согласованной копии при обслуживании кратко остановить только сайт, скопировать содержимое этих volumes защищённым административным способом и снова запустить сайт; хранить копию зашифрованной отдельно от VPS и репозитория. Новому серверу передать volumes с сохранением прав. Такая копия не заменяет независимую резервную копию БД Supabase.

## Фактически выполненные проверки

Результаты подготовки описаны ниже; этот список не означает публикацию.

- Checkpoint программы создан и проверен до правок.
- Flutter 3.47.5 / Dart 3.13.4 и официальный тег/commit проверены; `flutter pub get --enforce-lockfile` успешно, lockfile не изменён.
- Локальная release-сборка Flutter Web успешна с allowlist клиентских настроек, локальным CanvasKit и отключённой генерацией offline worker.
- Caddy 2.10.2 Windows из официального релиза проверен по SHA-512; его Caddyfile прошёл `validate`. Локальный HTTP smoke с настоящей release-сборкой: главная, SPA оболочка, JS/иконки/manifest, 404 отсутствующих ресурсов и API, no-cache и gzip — успешно.
- Официальный standalone Compose 2.39.4 проверен по SHA-256; `config --quiet` с примером настроек успешно. Это проверка модели Compose без Docker daemon.
- Валидатор: корректный публичный JSON принят, восемь случаев неверных/опасных настроек или хеша отклонены. 406 объявленных растровых изображений совпадают с release-сборкой по SHA-256; существующие изображения не менялись. 25 текстовых файлов сборки просканированы на типовые токены/ключи/DSN серверных секретов: совпадений нет; исходный JSON, Dart и source maps отсутствуют. Это не полный аудит образа или поиск всех неизвестных секретов.
- Миграция service worker проверена в JavaScript VM для свежей и ранее контролируемой страницы: отмена регистрации, удаление только трёх Flutter-кэшей, загрузка/перезагрузка; retirement worker не перехватывает fetch. Реальная миграция прежнего браузерного offline cache остаётся ручной проверкой.
- Локальный Docker Engine/daemon отсутствует. Эти проверки выполнены в GitHub Actions для настоящего Alpine runtime: сборка, wget health, аудит runtime layers, сохранение тестовых volumes после пересоздания и смена тестового образа с откатом. Production-сертификаты и volumes реального VPS не проверялись. См. фактический CI-прогон ниже.
- Нет адреса/доступа VPS и реального домена. SSH, архитектура VPS, занятость портов, firewall, DNS, ACME/публичный HTTPS, реальные вход/выход и разграничение Supabase на опубликованном origin **не проверены**. Административные настройки Supabase и DNS не изменялись.

Источники: [Docker multi-platform](https://docs.docker.com/build/building/multi-platform/), [BuildKit secrets](https://docs.docker.com/build/building/secrets/), [Docker Engine на Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Flutter Web release](https://docs.flutter.dev/deployment/web), [Caddy automatic HTTPS](https://caddyserver.com/docs/automatic-https), [Caddy try_files](https://caddyserver.com/docs/caddyfile/directives/try_files).

## Ручная сборка GitHub Actions (linux/amd64)

Workflow `.github/workflows/build-web-image.yaml` запускается только вручную через Actions → Build and verify Flutter Web image → Run workflow на `main`. Используется Ubuntu 24.04 runner; официальные Actions закреплены по commit SHA. До Docker build `deploy/audit_web_assets.py` проверяет существование, отслеживание в Git HEAD и включение в pubspec всех ресурсов; изменение байтов растровых изображений относительно коммита запрещено.

Repository secret `WEB_CLIENT_CONFIG` содержит существующий клиентский JSON, предварительно проверенный allowlist-валидатором. В него переданы только публичные клиентские настройки; серверные секреты не передавались. Для смены Supabase или публичного backup API обновить этот secret через GitHub Settings → Secrets and variables → Actions. JSON попадает в builder через BuildKit secret, а его SHA-256 сбрасывает нужный слой кэша.

Образ собирается только для `linux/amd64`, без push в реестр. После сборки проверяются фактическая архитектура, отсутствие SDK/Dart/Git, побайтное совпадение всех bundled assets, типовые секреты во всех runtime layers, Compose healthcheck, HTTP/404/сжатие/кэш, состояние обоих Caddy volumes после пересоздания. Проверка обновления использует отдельный тестовый образ с добавленным статическим файлом; после отката проверяется его исчезновение и сохранение volumes. Это тест смены образа, а не проверка обновления двух исторических production-релизов или реального сертификата.

Только после успешных проверок загружается артефакт `finance-web-linux-amd64-<commit>`: Docker archive `finance-web-linux-amd64.tar` и `asset-audit.json`. Срок хранения — **1 день**; скачать вовремя. В публичном репозитории артефакт нельзя считать приватным хранилищем: в образе есть только разрешённые публичные настройки. Административные секреты в него не включать.

Результат запуска, логи, tag образа и commit видны в Actions run summary. После скачивания и распаковки артефакта на компьютере с Docker или на VPS:

```bash
docker load --input finance-web-linux-amd64.tar
# На VPS при необходимости использовать sudo docker.
# Указать напечатанный при загрузке tag finance-app:web-<commit>-<run_number>
# в SITE_IMAGE файла .env.deploy; SITE_PLATFORM=linux/amd64.
```

Дальнейший запуск на VPS требует отдельного разрешения на публикацию и выполнения проверок домена/портов из этой инструкции. Workflow не подключается к VPS, не меняет DNS, не разворачивает сайт и не проверяет реальные Supabase login/logout/RLS.

## Фактический успешный CI-прогон

11 октября 2026 выполнен [Actions run 38158945162](https://github.com/iialexbalex-art/finance_app/actions/runs/38158945162), итог **success**, проверенный commit `0b07dda04eb3a414b70bcff321273d65e09a9c12`.

- Образ: `finance-app:web-0b07dda04eb3-3`, платформа `linux/amd64`.
- Manifest digest сборки: `sha256:2ab559beef9af504fcc6d0b431239a5dbf6c726daebc8a58c615392ff174be9f`.
- До сборки: 510 используемых изображений и 526 bundled файлов присутствуют в удалённом Git HEAD. Отсутствующих ресурсов не обнаружено; качество изображений не менялось.
- В готовом runtime: все 526 ресурсов совпадают по SHA-256 с checkout; SDK/Dart/Git отсутствуют; 833 файла слоёв прошли поиск типовых серверных секретов. Это поиск известных форматов, а не доказательство отсутствия любого неизвестного секрета.
- Настоящий контейнер стал healthy; HTTP smoke проверил главную, SPA shell, ресурсы, 404, no-cache, retirement worker и gzip. Оба Caddy volumes сохранили тестовое состояние после пересоздания, обновления тестовым образом и отката.
- [Готовый артефакт образа](https://github.com/iialexbalex-art/finance_app/actions/runs/38158945162/artifacts/11709443754): примерно 810 МБ, содержит `finance-web-linux-amd64.tar` и `asset-audit.json`. SHA-256 ZIP-артефакта: `5cf14ef114365baa5c436eac3607e45d732b0d6341568ee7760b560c60f3ec82`.

Артефакт хранится до **12 октября 2026, 22:18 по Asia/Qyzylorda**. Скачать и распаковать до истечения срока; затем `docker load --input finance-web-linux-amd64.tar`. Workflow можно запустить повторно вручную.

Публичный сайт, DNS и VPS не изменялись. Публичный HTTPS, реальные Supabase login/logout/RLS и миграция прежнего браузерного offline cache остаются отдельными проверками перед публикацией.
