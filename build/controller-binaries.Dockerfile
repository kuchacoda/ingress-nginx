ARG GOLANG_VERSION
FROM --platform=$BUILDPLATFORM golang:${GOLANG_VERSION}-alpine3.23 AS build

WORKDIR /src
COPY go.mod go.sum ./
COPY cmd/ cmd/
COPY internal/ internal/
COPY pkg/ pkg/
COPY version/ version/
COPY build/build.sh build/build.sh

ARG TARGETARCH
ARG TAG
ARG COMMIT_SHA
RUN --mount=type=secret,id=build_ca,target=/etc/ssl/certs/ca-certificates.crt \
    --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=linux ARCH="$TARGETARCH" PKG=k8s.io/ingress-nginx REPO_INFO=local \
    sh build/build.sh

FROM scratch
ARG TARGETARCH
COPY --from=build /src/rootfs/bin/${TARGETARCH}/ /
