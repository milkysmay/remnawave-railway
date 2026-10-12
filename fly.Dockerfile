# Fly.io build for TiredVPN (TLS over TCP, optional TUN mode).
#
# Fly runs the image as a root process inside a Firecracker microVM, so TUN and
# the netlink/nftables NAT bootstrap (internal/tun/nat_linux.go) have the
# privileges they need without any extra container flags. QUIC/UDP is disabled
# (-no-quic) because Fly's UDP needs a special bind address.
#
# The upstream Dockerfile is left untouched; fly.toml points at this one.

FROM golang:1.26-alpine AS builder

ARG VERSION=fly

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app

COPY go.mod go.sum* ./
# go.mod replaces github.com/vishvananda/netlink with this in-tree copy, so it
# has to be present before the module download step.
COPY third_party/ ./third_party/
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.version=${VERSION}" \
    -o /tiredvpn ./cmd/tiredvpn/

# ---------------------------------------------------------------------------
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata openssl

COPY --from=builder /tiredvpn /usr/local/bin/tiredvpn
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# Fake web root shown to unauthenticated visitors (anti-probe masquerade).
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && mkdir -p /app/www /app/certs \
 && echo '<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>Welcome to nginx!</h1></body></html>' \
    > /app/www/index.html

WORKDIR /app

ENV PORT=443

EXPOSE 443/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
