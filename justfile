build-arm:
    env CGO_ENABLED=0 GOOS=linux GOARCH=arm go build -ldflags="-s -w"

build:
    env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w"

run:
    air

dev:
    cd internal/frontend && pnpm dev --host && cd -
