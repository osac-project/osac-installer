INSTALLER_NAMESPACE ?= osac
VALUES_FILE ?= values/development/values.yaml

.PHONY: help
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ Helm Chart Management

.PHONY: sync-charts
sync-charts: ## Update submodules to latest main and rebuild chart dependencies
	git submodule update --init --recursive --remote
	helm dependency build charts/osac/

.PHONY: helm-deps
helm-deps: ## Build Helm chart dependencies
	helm dependency build charts/osac/

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
setup: ## Run setup.sh
	./scripts/setup.sh

.PHONY: teardown
teardown: ## Teardown OSAC deployment
	./scripts/teardown.sh

##@ Validation

.PHONY: helm-validate
helm-validate: helm-lint ## Validate Helm chart (lint + template)
	helm template osac charts/osac/ --values $(VALUES_FILE) > /dev/null
	@echo "Validation passed."
