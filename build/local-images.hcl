variable "REGISTRY" { default = "ingress-nginx-local" }
variable "GOLANG_VERSION" {}
variable "TAG" {}
variable "NGINX_TAG" {}
variable "CERTGEN_TAG" {}
variable "ERROR_PAGES_TAG" {}
variable "COMMIT_SHA" {}

group "default" {
  targets = ["controller", "kube-webhook-certgen", "custom-error-pages"]
}

target "nginx" {
  context = "images/nginx/rootfs"
  tags = ["${REGISTRY}/nginx:${NGINX_TAG}"]
}

target "controller-binaries" {
  context = "."
  dockerfile = "build/controller-binaries.Dockerfile"
  args = {
    GOLANG_VERSION = GOLANG_VERSION
    TAG = TAG
    COMMIT_SHA = COMMIT_SHA
  }
}

target "controller" {
  context = "rootfs"
  contexts = {
    nginx-base = "target:nginx"
    controller-binaries = "target:controller-binaries"
  }
  args = {
    BASE_IMAGE = "nginx-base"
    VERSION = TAG
    COMMIT_SHA = COMMIT_SHA
  }
  tags = ["${REGISTRY}/controller:${TAG}"]
}

target "controller-chroot" {
  inherits = ["controller"]
  dockerfile = "Dockerfile-chroot"
  tags = ["${REGISTRY}/controller-chroot:${TAG}"]
}

target "kube-webhook-certgen" {
  context = "images/kube-webhook-certgen/rootfs"
  args = { GOLANG_VERSION = GOLANG_VERSION }
  tags = ["${REGISTRY}/kube-webhook-certgen:${CERTGEN_TAG}"]
}

target "custom-error-pages" {
  context = "images/custom-error-pages/rootfs"
  args = { GOLANG_VERSION = GOLANG_VERSION }
  tags = ["${REGISTRY}/custom-error-pages:${ERROR_PAGES_TAG}"]
}
