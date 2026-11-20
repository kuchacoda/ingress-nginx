#!/bin/sh

# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu
cd "$(dirname "$0")/.."

GOLANG_VERSION=$(cat GOLANG_VERSION)
TAG=${TAG:-$(cat TAG)}
NGINX_TAG=$(cat images/nginx/TAG)
CERTGEN_TAG=$(cat images/kube-webhook-certgen/TAG)
ERROR_PAGES_TAG=$(cat images/custom-error-pages/TAG)
COMMIT_SHA=${COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}
export GOLANG_VERSION TAG NGINX_TAG CERTGEN_TAG ERROR_PAGES_TAG COMMIT_SHA

exec docker buildx bake -f build/local-images.hcl --load "$@"
