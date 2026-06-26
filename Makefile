INSTALLER_NAMESPACE ?= osac
VALUES_FILE ?= values/development.yaml
DEPLOY_MODE ?= helm

.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

BUMP_CHART ?=
BUMP_VERSION ?=

##@ Helm Chart Management

.PHONY: sync-charts
sync-charts: ## Update submodules to latest main (for kustomize and dev-deps)
	git submodule update --init --recursive --remote

.PHONY: helm-deps
helm-deps: ## Build Helm chart dependencies (pulls from OCI registry)
	helm dependency build charts/osac/

.PHONY: dev-deps
dev-deps: ## Build chart deps from local submodules (for development)
	git submodule update --init --recursive
	cp charts/osac/Chart.yaml charts/osac/Chart.yaml.bak
	./scripts/rewrite-chart-deps-local.sh && \
		helm dependency build charts/osac/; \
		rc=$$?; mv charts/osac/Chart.yaml.bak charts/osac/Chart.yaml; exit $$rc

.PHONY: bump-chart
bump-chart: ## Bump a subchart version: make bump-chart BUMP_CHART=fulfillment-service BUMP_VERSION=0.0.68
	@test -n "$(BUMP_CHART)" || { echo "Usage: make bump-chart BUMP_CHART=<name> BUMP_VERSION=<ver>"; exit 1; }
	@test -n "$(BUMP_VERSION)" || { echo "Usage: make bump-chart BUMP_CHART=<name> BUMP_VERSION=<ver>"; exit 1; }
	yq -i '(.dependencies[] | select(.name == "$(BUMP_CHART)")).version = "$(BUMP_VERSION)"' charts/osac/Chart.yaml
	rm -f charts/osac/Chart.lock
	helm dependency build charts/osac/
	@echo "Bumped $(BUMP_CHART) to $(BUMP_VERSION)"

.PHONY: helm-lint
helm-lint: ## Lint the umbrella chart
	helm dependency build charts/osac/
	helm lint charts/osac/

.PHONY: helm-template
helm-template: ## Dry-run render all templates
	helm dependency build charts/osac/
	helm template osac charts/osac/ --values $(VALUES_FILE)

##@ Deployment

.PHONY: helm-deploy
helm-deploy: ## Deploy OSAC to current cluster using Helm
	helm dependency build charts/osac/
	helm upgrade --install osac charts/osac/ \
		--namespace $(INSTALLER_NAMESPACE) \
		--create-namespace \
		--values $(VALUES_FILE) \
		--timeout 40m \
		--wait

.PHONY: helm-undeploy
helm-undeploy: ## Uninstall OSAC from current cluster
	helm uninstall osac --namespace $(INSTALLER_NAMESPACE)

.PHONY: setup
setup: ## Run setup.sh with DEPLOY_MODE=helm
	DEPLOY_MODE=$(DEPLOY_MODE) ./scripts/setup.sh

.PHONY: teardown
teardown: ## Teardown OSAC deployment
	./scripts/teardown.sh

##@ Container

HELM_IMAGE ?= osac-installer-helm:latest

.PHONY: container-build
container-build: ## Build the helm tooling container
	podman build -t $(HELM_IMAGE) -f Containerfile.helm .

.PHONY: container-run
container-run: ## Run a make target in the container: make container-run TARGET=helm-lint
	@test -n "$(TARGET)" || { echo "Usage: make container-run TARGET=<target>"; exit 1; }
	podman run --rm -v "$$(pwd):/charts:Z" -w /charts $(HELM_IMAGE) $(TARGET)

##@ Validation

.PHONY: helm-validate
helm-validate: helm-lint ## Validate Helm chart (lint + template)
	helm template osac charts/osac/ --values $(VALUES_FILE) > /dev/null
	@echo "Validation passed."

.PHONY: validate-values-schema
validate-values-schema: ## Check that every values key has a matching schema entry
	python3 scripts/validate-values-schema.py charts/osac/values.schema.json \
		charts/osac/values.yaml \
		charts/osac/values-example.yaml \
		values/*/values.yaml
