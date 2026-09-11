CHART  := charts/autoscale-platform
VALUES ?= values/local.yaml
RELEASE ?= platform
NAMESPACE ?= autoscale-platform

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: deps
deps: ## Vendor the service charts from the sibling repositories
	helm dependency build $(CHART)

.PHONY: lint
lint: deps ## Lint the umbrella chart against every environment's values
	@for file in values/*.yaml; do \
		echo "--- $$file"; \
		helm lint $(CHART) --values "$$file" || exit 1; \
	done

.PHONY: template
template: deps ## Render the manifests, for reading or diffing
	@mkdir -p out
	helm template $(RELEASE) $(CHART) \
		--namespace $(NAMESPACE) \
		--values $(VALUES) > out/$(notdir $(basename $(VALUES))).yaml
	@echo "wrote out/$(notdir $(basename $(VALUES))).yaml"

.PHONY: template-all
template-all: deps ## Render every environment
	@for file in values/*.yaml; do $(MAKE) --no-print-directory template VALUES=$$file; done

.PHONY: verify
verify: ## Run the whole platform locally and check it does what it claims
	./verify.sh

.PHONY: install-local
install-local: deps ## Install into a local cluster. NEVER run this against vikingvault.
	@echo "This installs directly with helm. On an ArgoCD-managed cluster that"
	@echo "creates a second owner and selfHeal will revert it. Local clusters only."
	@echo ""
	helm upgrade --install $(RELEASE) $(CHART) \
		--namespace $(NAMESPACE) --create-namespace \
		--values $(VALUES)

.PHONY: uninstall-local
uninstall-local: ## Remove a local install
	helm uninstall $(RELEASE) --namespace $(NAMESPACE)

.PHONY: clean
clean: ## Remove rendered output and vendored charts
	rm -rf out $(CHART)/charts $(CHART)/Chart.lock
