build-frontend:
    cd internal/frontend && pnpm build && cd -

build-firstrun:
    cd internal/firstrun && pnpm build && cd -

build-arm: build-frontend build-firstrun
    env CGO_ENABLED=0 GOOS=linux GOARCH=arm go build -ldflags="-s -w"

build: build-frontend build-firstrun
    env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w"

run:
    air

dev:
    cd internal/frontend && pnpm dev --host && cd -
