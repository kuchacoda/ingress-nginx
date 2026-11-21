#!/usr/bin/env bash

# Copyright 2026 The Kubernetes Authors.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "$*" >&2; exit 1; }
usage() { echo "Usage: $0 {latest|plan|build|publish}" >&2; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  latest|plan|build|publish) mode=$1 ;;
  *) usage; exit 2 ;;
esac
[[ $# == 1 ]] || { usage; exit 2; }

upstream=https://github.com/chainguard-forks/ingress-nginx
url=$(curl -fsSL --retry 2 --max-time 30 -o /dev/null -w '%{url_effective}' "$upstream/releases/latest")
release=${url##*/}
[[ $url == "$upstream/releases/tag/$release" && $release =~ ^controller-v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "Expected a stable controller release at $upstream/releases/latest, got $url"
if [[ $mode == latest ]]; then
  echo "$release"
  exit 0
fi

# Keep FETCH_HEAD available to the maintainer's sync commands.
upstream_main=refs/ingress-nginx/chainguard-main
git fetch --quiet --no-tags --no-write-fetch-head "$upstream.git" \
  "refs/heads/main:$upstream_main" "refs/tags/$release:refs/tags/$release"
upstream_sha=$(git rev-parse "refs/tags/$release^{commit}")
COMMIT_SHA=$(git rev-parse HEAD)
base=$(git merge-base --all "$COMMIT_SHA" "$upstream_main") ||
  die "Cannot find the upstream base. Use a full clone with the release merged."
[[ $base == "$upstream_sha" ]] || die "Checkout is not based on $release ($upstream_sha). See the release runbook."
TAG=${release#controller-}
printf 'Upstream %s (%s), fork %s\n' "$release" "$upstream_sha" "$COMMIT_SHA" >&2
if [[ $mode == publish ]]; then
  registry_host=${REGISTRY:-}
  registry_host=${registry_host%%/*}
  [[ ${REGISTRY:-} == */* && $REGISTRY != *://* && $REGISTRY != */ &&
     ( $registry_host == localhost || $registry_host == *.* || $registry_host == *:* ) ]] ||
    die "Set REGISTRY to the registry host and project path."
fi
REGISTRY=${REGISTRY:-ingress-nginx-local}
export TAG COMMIT_SHA REGISTRY
images=(controller kube-webhook-certgen custom-error-pages)

if [[ $mode != plan ]]; then
  changes=$(git status --porcelain --untracked-files=normal)
  [[ -z $changes ]] || die "Release builds use committed sources. Use a clean checkout of $COMMIT_SHA."
fi

if [[ $mode != publish ]]; then
  options=(--set '*.platform=linux/amd64' --provenance=false)
  for image in "${images[@]}"; do
    options+=(--set "$image.tags=$REGISTRY/$image:$TAG"
              --set "$image.labels.org.opencontainers.image.source=https://github.com/kuchacoda/ingress-nginx"
              --set "$image.labels.org.opencontainers.image.version=$TAG"
              --set "$image.labels.org.opencontainers.image.revision=$COMMIT_SHA")
  done
  if [[ -n ${BUILD_CA_CERT:-} ]]; then
    [[ $BUILD_CA_CERT = /* && -r $BUILD_CA_CERT ]] || die "BUILD_CA_CERT must be an absolute readable CA bundle path."
    options+=(--set "*.secrets=id=build_ca,src=$BUILD_CA_CERT" --allow "fs.read=$BUILD_CA_CERT")
  fi
  if [[ $mode == plan ]]; then
    exec ./build/local-images.sh --print "${options[@]}"
  fi
  ./build/local-images.sh "${options[@]}"
  version=$(docker run --rm --pull=never --platform linux/amd64 "$REGISTRY/controller:$TAG" /nginx-ingress-controller --version)
  printf '%s\n' "$version"
  [[ $(awk '$1=="Release:" {print $2}' <<< "$version") == "$TAG" &&
     $(awk '$1=="Build:" {print $2}' <<< "$version") == "$COMMIT_SHA" ]] ||
    die "The controller binary does not match this release and checkout."
  docker run --rm -i --pull=never --platform linux/amd64 "$REGISTRY/controller:$TAG" sh -ec \
    'cat >/tmp/release-test.conf && nginx -t -c /tmp/release-test.conf' <<'NGINX'
load_module /etc/nginx/modules/ngx_http_geoip2_module.so;
load_module /etc/nginx/modules/ngx_http_brotli_filter_module.so;
load_module /etc/nginx/modules/ngx_http_brotli_static_module.so;
load_module /etc/nginx/modules/ngx_http_auth_digest_module.so;
load_module /etc/nginx/modules/ngx_http_modsecurity_module.so;
load_module /etc/nginx/modules/otel_ngx_module.so;
pid /tmp/release-test.pid;
error_log stderr;
events {}
http {}
NGINX
  docker run --rm --pull=never --platform linux/amd64 "$REGISTRY/kube-webhook-certgen:$TAG" --help >/dev/null
  exit 0
fi

# Use Docker's existing login for both transports. Read raw manifests so checking
# an existing tag does not require downloading any layers from the registry CDN.
case ${RELEASE_PUSH_TOOL:-docker} in
  docker) ;;
  regctl) command -v regctl >/dev/null || die "Install regctl for RELEASE_PUSH_TOOL=regctl." ;;
  *) die "RELEASE_PUSH_TOOL must be docker or regctl." ;;
esac
command -v jq >/dev/null || die "Install jq to verify registry manifests."
command -v shasum >/dev/null || die "Install shasum to print registry digests."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Returns 0 for matching content, 1 for a missing tag. Any other error stops the release.
published() {
  local ref=$1 id=$2 remote_id digest child
  if docker buildx imagetools inspect --raw "$ref" >"$tmp/manifest" 2>"$tmp/error"; then
    remote_id=$(jq -r '.config.digest // empty' "$tmp/manifest") || die "Invalid manifest for $ref"
    if [[ -z $remote_id ]]; then
      child=$(jq -er '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")] |
        if length == 1 then .[0].digest else error("expected one linux/amd64 manifest") end' "$tmp/manifest") ||
        die "Cannot verify the linux/amd64 image in $ref. Keeping the published tag."
      remote_id=$(docker buildx imagetools inspect --raw "${ref%:*}@$child" | jq -er '.config.digest') ||
        die "Cannot verify the child manifest of $ref."
    fi
    [[ $remote_id == "$id" ]] || die "$ref already exists with different content. Keeping the published tag."
    digest=$(shasum -a 256 <"$tmp/manifest") || die "Cannot hash the manifest for $ref"
    printf '%s@sha256:%s\n' "$ref" "${digest%% *}"
    return 0
  fi
  if grep -Fxq "ERROR: $ref: not found" "$tmp/error" || grep -Fqi 'manifest unknown' "$tmp/error"; then
    return 1
  fi
  cat "$tmp/error" >&2
  die "Could not check $ref in the registry."
}

pending=()
expected="linux/amd64 $TAG $COMMIT_SHA"
for image in "${images[@]}"; do
  ref="$REGISTRY/$image:$TAG"
  docker image inspect --format '{{.Id}}' "$ref" >"$tmp/$image.local-id" ||
    die "Run $0 build in this checkout first."
  # Docker's containerd store uses the manifest or index digest as its local ID.
  # Hash the actual image config for a comparison that also works on classic Docker.
  docker image save -o "$tmp/$image.tar" "$ref"
  config=$(tar -xOf "$tmp/$image.tar" manifest.json | jq -er '
    if length == 1 then .[0].Config else error("expected a single-platform release build") end')
  tar -xOf "$tmp/$image.tar" "$config" >"$tmp/$image.json"
  metadata=$(jq -r '[.os + "/" + .architecture, .config.Labels["org.opencontainers.image.version"],
    .config.Labels["org.opencontainers.image.revision"]] | join(" ")' "$tmp/$image.json")
  [[ $metadata == "$expected" ]] || die "Local $ref does not match $expected. Run $0 build first."
  checksum=$(shasum -a 256 <"$tmp/$image.json")
  id="sha256:${checksum%% *}"
  printf '%s\n' "$id" >"$tmp/$image.id"
  if ! published "$ref" "$id"; then pending+=("$image"); fi
done

(( ${#pending[@]} )) || exit 0
for image in "${pending[@]}"; do
  ref="$REGISTRY/$image:$TAG"
  id=$(cat "$tmp/$image.id")
  [[ $(docker image inspect --format '{{.Id}}' "$ref") == "$(cat "$tmp/$image.local-id")" ]] ||
    die "Local $ref changed during publication."
  if published "$ref" "$id"; then continue; fi
  if [[ ${RELEASE_PUSH_TOOL:-docker} == regctl ]]; then
    regctl image import "$ref" "$tmp/$image.tar"
  else
    docker push "$ref"
  fi
  published "$ref" "$id" || die "$ref is missing after upload."
done
