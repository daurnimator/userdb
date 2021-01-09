NAMESPACE ?= userdb

.PHONY: help
help:
	@echo "build       		 - compile/order all sql files to out directory"
	@echo "fetch       		 - fetch submodules"
	@echo "fetch-latest      - fetch submodules at latest upstream master refs"
	@echo "test        		 - run tests with in-place PostgreSQL"
	@echo "install     		 - Setup schemas on local system PostgreSQL"
	@echo "clean       		 - Delete generated files"
	@echo "develop     		 - Load schema into temp db and launch shell"
	@echo "docker-build 	 - Build database container with preloaded schema"
	@echo "docker-start 	 - Start database container"
	@echo "docker-stop 	  	 - Stop database container"
	@echo "docker-test  	 - run tests from a predictable test container"
	@echo "docker-test-build - build test container"
	@echo "docker-test-shell - run shell from a test container"

out/json-schemas.sql: schema/sql/json-schemas.sql
	mkdir -p $(@D)
	./scripts/build schema < "$<" > "$@"

.PHONY: build
build: out/json-schemas.sql

schema/ext/json-schema/%:
	git submodule update --init --recursive $(@D)

test/sql/plpgunit/%:
	git submodule update --init --recursive $(@D)

.PHONY: fetch
fetch: schema/ext/json-schema/ test/sql/plpgunit/

.PHONY: fetch-latest
fetch-latest:
	git submodule foreach 'git checkout master && git pull'

SCHEMA_FILES := \
	schema/sql/schema.sql \
	schema/sql/access.sql \
	schema/sql/api.sql \
	schema/sql/metrics.sql \
	schema/sql/nss.sql \
	schema/sql/reserved.sql \
	schema/sql/stats.sql \
	schema/ext/json-schema/postgres-json-schema--0.1.0.sql \
	out/json-schemas.sql

.PHONY: install
install: $(SCHEMA_FILES)
	psql -v ON_ERROR_STOP=1 $(foreach file,$(SCHEMA_FILES),-f $(file));

.PHONY: develop
develop:
	./scripts/test.sh develop

.PHONY: test
test: \
	docker-test-build \
	docker-restart \
	docker-test \
	docker-stop

.PHONY: test-shell
test-shell: \
	docker-test-build \
	docker-restart \
	docker-test-shell \
	docker-stop

.PHONY: clean
clean:
	rm -rf out

.PHONY: docker-build
docker-build: fetch
	docker build -t local/$(NAMESPACE):latest .
	docker build \
		--build-arg=POSTGREST_VERSION=v6.0.2 \
		-t local/$(NAMESPACE)-postgrest \
		modules/postgrest/docker/

.PHONY: docker-restart
docker-restart: docker-stop docker-start

.PHONY: docker-start
docker-start:
	docker network inspect $(NAMESPACE) \
	|| docker network create $(NAMESPACE)
	docker inspect -f '{{.State.Running}}' $(NAMESPACE) 2>/dev/null \
	|| docker run  \
		--detach=true \
		--network=$(NAMESPACE) \
		--name=$(NAMESPACE) \
		-p 5432:5432 \
		local/$(NAMESPACE)
	docker inspect -f '{{.State.Running}}' $(NAMESPACE)-postgrest 2>/dev/null \
	|| docker run \
		--rm \
		--detach=true \
		--name $(NAMESPACE)-postgrest \
		--network=$(NAMESPACE) \
		--env PGRST_DB_URI="postgres://postgres@$(NAMESPACE)/userdb" \
  		--env PGRST_DB_SCHEMA="v1" \
  		--env PGRST_DB_ANON_ROLE="api-anon" \
  		--env PGRST_JWT_SECRET="a_test_only_postgrest_jwt_secret" \
		local/$(NAMESPACE)-postgrest

.PHONY: docker-stop
docker-stop:
	docker inspect -f '{{.State.Running}}' $(NAMESPACE) 2>/dev/null \
	&& docker rm -f $(NAMESPACE) || true
	docker inspect -f '{{.State.Running}}' $(NAMESPACE)-postgrest 2>/dev/null \
	&& docker rm -f $(NAMESPACE)-postgrest || true

.PHONY: docker-log
docker-log:
	docker logs -f $(NAMESPACE)

.PHONY: docker-clean
docker-clean: docker-stop
	docker image rm -f local/$(NAMESPACE)

.PHONY: docker-test
docker-test: docker-stop docker-build docker-start docker-test-build
	docker run \
		-it \
		--rm \
		--hostname=$(NAMESPACE)-test \
		--name $(NAMESPACE)-test \
		--network=$(NAMESPACE) \
		--env CONTAINER="$(NAMESPACE)" \
		--env PGPASSWORD=test_password \
		--env PGHOST=$(NAMESPACE) \
		--env PGDATABASE=$(NAMESPACE) \
		--env PGUSER=postgres \
		local/$(NAMESPACE)-test

.PHONY: docker-test-shell
docker-test-shell: docker-stop docker-build docker-start docker-test-build
	docker run \
		--rm \
		-it \
		--hostname=$(NAMESPACE)-test \
		--name $(NAMESPACE)-test \
		--network=$(NAMESPACE) \
		--env CONTAINER="$(NAMESPACE)" \
		--env PGPASSWORD=test_password \
		--env PGHOST=$(NAMESPACE) \
		--env PGDATABASE=$(NAMESPACE) \
		--env PGUSER=postgres \
		local/$(NAMESPACE)-test \
		bash

.PHONY: docker-test-build
docker-test-build:
	docker build -t local/$(NAMESPACE)-test test/
