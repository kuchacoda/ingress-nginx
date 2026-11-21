# Обновление форка и сборка релизных образов

Источником версии служит последний опубликованный стабильный релиз Chainguard вида `controller-vX.Y.Z`. В GitLab три образа получают один тег `vX.Y.Z` — `controller`, `kube-webhook-certgen` и `custom-error-pages`. Платформа релизной сборки — `linux/amd64`. [Релизы Chainguard](https://github.com/chainguard-forks/ingress-nginx/releases)

## Принять новый релиз

В полном клоне форка добавьте remote один раз.

```sh
git remote add upstream https://github.com/chainguard-forks/ingress-nginx.git
```

Из корня репозитория получите опубликованный тег и влейте именно его в ветку от `main` форка.

```sh
release=$(./build/release-images.sh latest)
git fetch origin main
git switch -c "sync/$release" origin/main
git fetch --no-tags upstream tag "$release"
git merge --no-ff -m "Update to $release" "refs/tags/$release"
git push -u origin "sync/$release"
```

Откройте PR в `main` форка и выберите **Create a merge commit**. Так Git сохраняет родство с коммитами upstream. Для сборки возьмите SHA принятого PR и выполните `git fetch origin main`, затем `git switch --detach "$merge_sha"`, где `merge_sha` — этот SHA. Полная история нужна для проверки базы. Скрипт сверяет общий коммит текущего checkout и `main` Chainguard с опубликованным тегом. Если появился следующий релиз или в форк попали последующие коммиты upstream, проверка остановит сборку.

Для тестирования промежуточного коммита используйте локальный `build/local-images.sh` и отдельный тег вида `sha-<короткий SHA>`. Релизный тег сохраняет своё содержимое.

## Проверить и собрать

Нужны Git, Bash, curl, Docker с Buildx и возможность запускать контейнеры `linux/amd64`. Задайте тот же `REGISTRY` для сборки и публикации. Значение — хост и путь проекта без схемы и завершающего слеша.

```sh
export REGISTRY=registry.gitlab.com/kodster/ingress-nginx
./build/release-images.sh latest
./build/release-images.sh plan
./build/release-images.sh build
```

`plan` выводит план Bake в JSON. `build` загружает три образа в локальный Docker, записывает тег и SHA форка в OCI-метки, сверяет их с выводом бинарника контроллера, проверяет загрузку модулей через `nginx -t` и запускает `kube-webhook-certgen --help`. Используйте чистый checkout, чтобы коммит однозначно указывал на собранные исходники.

В среде с TLS-прокси перед сборкой задайте `BUILD_CA_CERT` — абсолютный путь к доверенному PEM-файлу с корневыми сертификатами, например `/etc/ssl/certs/ca-certificates.crt` в Codex Cloud. BuildKit монтирует его как временный секрет только в командах, которые загружают зависимости. Для базовых образов доступ к реестрам и доверие к сертификатам также нужны самому Docker.

## Опубликовать и проверить

Команде `publish` нужны `jq`, `shasum` и вход в реестр. Для этого проекта подойдёт GitLab project deploy token с `read_registry` и `write_registry`. Если Docker уже авторизован, переходите сразу к публикации. При использовании переменных окружения передайте пароль через stdin.

```sh
printf '%s' "$GITLAB_DEPLOY_TOKEN" | docker login registry.gitlab.com \
  --username "$GITLAB_REGISTRY_USER" --password-stdin
./build/release-images.sh publish
```

В одноразовом облачном окружении для входа и публикации можно задать отдельный временный каталог `DOCKER_CONFIG` и удалить его после проверки манифестов.

Скрипт сохраняет локальные образы из шага `build` во временный каталог и вычисляет SHA-256 их конфигураций. Он проверяет все три тега, пропускает образы с тем же config digest и останавливается при конфликте с существующим тегом или ошибке доступа. После отправки он перечитывает манифест из реестра и печатает `адрес:тег@sha256:…` для каждого образа. При обрыве повторите `publish` с теми же локальными образами. При нескольких издателях включите правила неизменяемых тегов в самом реестре.

Если Docker за прокси повторяет загрузку слоёв, используйте установленный `regctl` с тем же Docker login и теми же локальными образами. Скрипт передаст недостающие образы через `regctl image import`.

```sh
RELEASE_PUSH_TOOL=regctl ./build/release-images.sh publish
```

Для текущего GitLab нужны `registry.gitlab.com` и `gitlab.com` (авторизация). Для скачивания слоёв с пустым кешем нужен также `cdn.registry.gitlab-static.net`. Для сборки должны быть доступны источники из Dockerfile и `images/nginx/rootfs/build.sh`, включая `dl-cdn.alpinelinux.org`, `nginx.org` и GitHub.

При автоматизации запускайте проверку `latest` по расписанию в форке и открывайте PR на новый релиз. Сборку и публикацию привязывайте к SHA слияния этого PR. События релиза приходят в репозиторий, в котором он опубликован.
