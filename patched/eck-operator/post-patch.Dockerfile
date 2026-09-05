ARG BASE
FROM docker.io/library/golang:1.26.8-alpine@sha256:ce864e7223ac17b1775e6fd0b4c0db580c2eb50e7953a427916379e4b92a1628 AS builder

WORKDIR /build
ADD https://github.com/elastic/cloud-on-k8s.git#386c7b14f2d1bbb7f2af1e7da997e64875f16e47 .
RUN go get github.com/google/cel-go@v0.29.0 google.golang.org/grpc@v1.83.1 && \
    CGO_ENABLED=0 GOOS=linux go build -mod=readonly -a -o /elastic-operator \
      -ldflags='-X github.com/elastic/cloud-on-k8s/v3/pkg/about.version=3.5.0 -X github.com/elastic/cloud-on-k8s/v3/pkg/about.buildHash=386c7b14 -X github.com/elastic/cloud-on-k8s/v3/pkg/about.buildDate=2026-08-04T08:29:12Z -X github.com/elastic/cloud-on-k8s/v3/pkg/about.buildSnapshot=false' \
      github.com/elastic/cloud-on-k8s/v3/cmd

FROM ${BASE}
COPY --from=builder /elastic-operator /elastic-operator
