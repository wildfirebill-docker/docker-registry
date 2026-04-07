.PHONY: all build build-sqlite build-mariadb run-sqlite run-mariadb clean test

all: build

build: build-sqlite build-mariadb

build-sqlite:
	cd backend && CGO_ENABLED=1 go build -o ../bin/registry-sqlite

build-mariadb:
	cd backend && CGO_ENABLED=1 go build -o ../bin/registry-mariadb

run-sqlite:
	docker-compose -f docker/docker-compose.sqlite.yml up -d

run-mariadb:
	docker-compose -f docker/docker-compose.mariadb.yml up -d

stop:
	docker-compose -f docker/docker-compose.sqlite.yml down || true
	docker-compose -f docker/docker-compose.mariadb.yml down || true

clean:
	rm -rf bin/
	docker rm -f docker-registry-sqlite docker-registry-mariadb docker-registry-mariadb-app docker-registry-mariadb || true

test:
	cd backend && go test -v ./...

deps:
	cd backend && go mod download
	cd backend && go mod tidy

build-images:
	docker build -f docker/Dockerfile.sqlite -t docker-registry-sqlite .
	docker build -f docker/Dockerfile.mariadb -t docker-registry-mariadb .

build-iso:
	cd os-builder && ./build-iso.sh

build-vm:
	cd vm-builder && ./build-vm.sh
