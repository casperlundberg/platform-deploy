CHART  := charts/autoscale-platform
VALUES ?= values/local.yaml
RELEASE ?= platform
NAMESPACE ?= autoscale-platform

# The service charts, in the sibling repositories. Deployed one ArgoCD
# Application each — see argocd/ and item 8 in docs/infra-handover.md.
SERVICES := autoscaler simlab-api simlab-web

# The GitOps source of truth for the ArgoCD Applications. Not this repository
# — argocd/ holds copies so that this repo states the contract on its own, and
# check-argocd keeps them honest. Override if it is checked out elsewhere; the
# check skips itself when the path is absent, which is the case in CI.
INFRA ?= ../../../../vikingvault/vikingvault-infrastructure
INFRA_APPS := $(INFRA)/devops/argocd-applications

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | \
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

.PHONY: check-values
check-values: deps ## Check that values/vikingvault.yaml and values/vikingvault/ still agree
	@# The cluster is deployed from values/vikingvault/, one file per ArgoCD
	@# Application. values/vikingvault.yaml is the same configuration written
	@# for the umbrella chart, which is what `make template` renders and what
	@# the umbrella Application would use. Two statements of one configuration
	@# drift, so this asserts they do not, the same way the Go services assert
	@# their route table and openapi.yaml describe one surface.
	@#
	@# It compares rendered manifests rather than the values files, because
	@# that is the property worth holding: both paths must produce the same
	@# objects. The umbrella prefixes every "# Source:" with the parent chart,
	@# hence the sed; the sort is because concatenating three renders orders
	@# resources differently from one render. Sorting lines would hide a
	@# transposition that preserved every line, which no values change does.
	@mkdir -p out
	@helm template $(RELEASE) $(CHART) --namespace $(NAMESPACE) \
		--values values/vikingvault.yaml \
		| sed 's|^# Source: autoscale-platform/charts/|# Source: |' | sort > out/.umbrella
	@: > out/.split
	@for svc in $(SERVICES); do \
		helm template $(RELEASE) ../$$svc/deploy/chart --namespace $(NAMESPACE) \
			--values values/vikingvault/$$svc.yaml >> out/.split || exit 1; \
	done
	@sort -o out/.split out/.split
	@diff -q out/.umbrella out/.split >/dev/null || { \
		echo "values/vikingvault.yaml and values/vikingvault/ have drifted:"; \
		diff -u out/.umbrella out/.split | grep '^[+-][^+-]' | head -40; \
		exit 1; \
	}
	@echo "✓ values/vikingvault.yaml and values/vikingvault/ render the same manifests"

.PHONY: check-argocd
check-argocd: ## Check argocd/ still matches the Applications in the infra repo
	@# One shell for the whole check: a skip has to stop the rest of the recipe,
	@# and each recipe line would otherwise run in a shell of its own.
	@if [ ! -d "$(INFRA_APPS)" ]; then \
		echo "skipped: $(INFRA_APPS) not present (set INFRA=... to check)"; \
	else \
		failed=0; \
		for svc in $(SERVICES); do \
			live="$(INFRA_APPS)/autoscale-platform-$$svc.yaml"; \
			if [ ! -f "$$live" ]; then \
				echo "missing in the infra repo: $$live"; failed=1; \
			elif tail -n +7 "argocd/$$svc.yaml" | diff -q - "$$live" >/dev/null; then \
				echo "  argocd/$$svc.yaml matches"; \
			else \
				echo "argocd/$$svc.yaml has diverged from $$live:"; \
				tail -n +7 "argocd/$$svc.yaml" | diff -u - "$$live" | grep '^[+-][^+-]' | head -20; \
				failed=1; \
			fi; \
		done; \
		exit $$failed; \
	fi

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

.PHONY: e2e
e2e: ## Run the end-to-end check as a Job in the cluster, and tail it
	@# The script is kept as a file rather than embedded in the Job, so it can
	@# be read, diffed and compiled on its own; the ConfigMap is rebuilt from it
	@# on every run so there is no stale copy to be confused by.
	@kubectl create configmap platform-e2e --namespace $(NAMESPACE) \
		--from-file=e2e.py=e2e/e2e.py --dry-run=client -o yaml | kubectl apply -f -
	@kubectl delete job platform-e2e --namespace $(NAMESPACE) --ignore-not-found --wait
	@# The token Secret is named differently depending on how the platform was
	@# installed: a cluster using auth.existingSecret has whatever name it chose
	@# (autoscaler-api-token here), while a self-contained install has the chart
	@# generate <release>-autoscaler-api-token. job.yaml names the first, because
	@# that is what this project deploys; this finds whichever actually exists so
	@# the same check runs against a laptop cluster unchanged.
	@secret=$$(kubectl get secret --namespace $(NAMESPACE) --no-headers \
		-o custom-columns=NAME:.metadata.name 2>/dev/null \
		| grep -E '(^|-)autoscaler-api-token$$' | head -1); \
	if [ -z "$$secret" ]; then \
		echo "no *autoscaler-api-token Secret in $(NAMESPACE) -- is the platform installed?"; \
		exit 1; \
	fi; \
	echo "using token Secret: $$secret"; \
	sed "s/name: autoscaler-api-token/name: $$secret/" e2e/job.yaml | kubectl apply -f -
	@echo
	@kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=platform-e2e \
		--namespace $(NAMESPACE) --timeout=120s >/dev/null 2>&1 || true
	@kubectl logs -f job/platform-e2e --namespace $(NAMESPACE) 2>/dev/null || \
		kubectl logs job/platform-e2e --namespace $(NAMESPACE)
	@# kubectl logs -f exits 0 whatever the Job did, so the Job's own condition
	@# is what decides this target's exit code.
	@kubectl wait --for=condition=complete job/platform-e2e --namespace $(NAMESPACE) --timeout=5s >/dev/null 2>&1 \
		&& echo "\n✓ e2e passed" \
		|| { echo "\n✗ e2e failed -- see the checks above"; exit 1; }

.PHONY: e2e-clean
e2e-clean: ## Remove the e2e Job and its ConfigMap
	@kubectl delete job platform-e2e --namespace $(NAMESPACE) --ignore-not-found
	@kubectl delete configmap platform-e2e --namespace $(NAMESPACE) --ignore-not-found

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
