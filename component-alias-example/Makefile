COMPONENTS := menu-ingester meal-gen menu-persister menu-distributor
VERSION    := 0.1.0

# componentize-go v0.4.3 is the first release whose wit-bindgen understands
# `(implements ..)` named imports, and it requires Go >= 1.27.1.
GO              := GOTOOLCHAIN=go1.27.1 go
COMPONENTIZE_GO := $(CURDIR)/.bin/componentize-go

# Push through the registry's Traefik SNI route; hosts pull it by its
# in-cluster name (see manifests/).
PUSH_REGISTRY ?= registry.localhost.cosmonic.sh/library
# The registry's cert is issued by the in-cluster cert-manager CA; wash ignores
# SSL_CERT_FILE and wants it passed explicitly.
REGISTRY_CA   ?= .bin/registry-ca.crt

.PHONY: all tools sync-wit bindings build push deploy test clean

all: build

# Installed rather than `go run`: `go run` exports GOROOT to the child, which
# makes the patched async-capable Go that componentize-go downloads for the
# P3 ingester report the stock GOROOT and fail its async check.
tools: $(COMPONENTIZE_GO)
$(COMPONENTIZE_GO):
	GOBIN=$(CURDIR)/.bin $(GO) install github.com/bytecodealliance/componentize-go@v0.4.3

# Copy the single canonical tst:menu package into each component's wit/deps.
sync-wit:
	@for c in $(COMPONENTS); do \
		mkdir -p components/$$c/wit/deps/tst-menu-0.1.0; \
		cp wit/tst-menu/package.wit components/$$c/wit/deps/tst-menu-0.1.0/; \
	done

# componentize-go writes its own go.mod (module `wit_component`), so go.mod
# and go.sum are generated output here, not source.
bindings: tools sync-wit
	@for c in $(COMPONENTS); do \
		echo "==> bindings $$c"; \
		(cd components/$$c && rm -f go.mod go.sum && \
			$(COMPONENTIZE_GO) bindings --format && $(GO) mod tidy) || exit 1; \
	done

build: bindings
	@for c in $(COMPONENTS); do \
		echo "==> build $$c"; \
		(cd components/$$c && $(COMPONENTIZE_GO) build -o $$c.wasm) || exit 1; \
	done

$(REGISTRY_CA):
	@mkdir -p $(dir $@)
	kubectl -n twosix-dev get secret registry-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > $@

push: $(REGISTRY_CA)
	@for c in $(COMPONENTS); do \
		wash oci push --ca-path $(REGISTRY_CA) $(PUSH_REGISTRY)/$$c:$(VERSION) components/$$c/$$c.wasm || exit 1; \
	done

deploy:
	kubectl apply -f manifests/

test:
	./scripts/test.sh

clean:
	rm -rf .bin components/*/*.wasm
