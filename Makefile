# SRE challenge — monlab solution. One-command, reproducible deploy.
# Override KUBECONFIG / NODE / TAG as needed.
SHELL        := /bin/bash
ROOT         := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT    := $(ROOT)
export KUBECONFIG ?= $(REPO_ROOT)/_solution/.kube/config
NODE         ?= root@kube.monlab.newt.cz
TAG          ?= 0.1.0
NS           ?= sre-challenge
HELM         := helm
KUBECTL      := kubectl

.PHONY: all images sideload operators data apps observability verify status clean destroy

all: images sideload operators data apps observability verify ## full bring-up

images: ## build front/back/reader images (multi-stage, agents baked in)
	TAG=$(TAG) bash $(ROOT)/scripts/build-images.sh

sideload: ## stream images into the node's cri-o (no registry needed)
	TAG=$(TAG) NODE=$(NODE) bash $(ROOT)/scripts/sideload-images.sh

operators: ## install Strimzi + CloudNativePG operators
	$(HELM) repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
	$(HELM) repo add strimzi https://strimzi.io/charts/ >/dev/null 2>&1 || true
	$(HELM) repo update cnpg strimzi
	$(HELM) upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace --wait
	$(KUBECTL) get ns $(NS) >/dev/null 2>&1 || $(KUBECTL) create ns $(NS)
	$(KUBECTL) label ns $(NS) pod-security.kubernetes.io/enforce=baseline --overwrite
	$(HELM) upgrade --install strimzi strimzi/strimzi-kafka-operator -n $(NS) --set watchAnyNamespace=true --wait

data: ## deploy Kafka (testCommand 32/RF1) + Postgres 16
	$(KUBECTL) apply -f $(ROOT)/k8s/kafka/kafka-metrics-configmap.yaml
	$(KUBECTL) apply -f $(ROOT)/k8s/kafka/kafka-cluster.yaml
	$(KUBECTL) apply -f $(ROOT)/k8s/kafka/kafka-topic.yaml
	$(KUBECTL) apply -f $(ROOT)/k8s/postgres/postgres-cluster.yaml
	$(KUBECTL) -n $(NS) wait --for=condition=Ready kafka/sre-kafka --timeout=300s || true
	$(KUBECTL) -n $(NS) wait --for=condition=Ready cluster.postgresql.cnpg.io/sre-postgres --timeout=300s || true

apps: ## deploy the three apps (umbrella chart)
	$(HELM) dependency build $(ROOT)/chart/sre-apps
	$(HELM) upgrade --install sre $(ROOT)/chart/sre-apps -n $(NS)
	$(KUBECTL) -n $(NS) rollout status deploy/sre-front --timeout=180s
	$(KUBECTL) -n $(NS) rollout status deploy/sre-back   --timeout=180s
	$(KUBECTL) -n $(NS) rollout status deploy/sre-reader --timeout=180s

observability: ## stage dashboards+rules and deploy the monitor-tools instance
	bash $(ROOT)/scripts/assemble-dashboards.sh
	$(HELM) upgrade --install monitor-tools $(ROOT)/monitor-tools -n monitor-tools --create-namespace

mixin: ## (optional) re-render the JVM mixin from grafana jvm-observ-lib (needs docker)
	@echo "See observability/mixin/README.md for the containerised jsonnet render."

verify: ## exercise the pipeline and print a pillar summary
	bash $(ROOT)/scripts/verify.sh

status: ## show releases + pods
	$(HELM) list -A
	$(KUBECTL) -n $(NS) get pods

clean: ## remove app + monitor-tools releases (keep operators + data)
	-$(HELM) uninstall sre -n $(NS)
	-$(HELM) uninstall monitor-tools -n monitor-tools

destroy: ## tear everything down
	-$(HELM) uninstall sre -n $(NS)
	-$(HELM) uninstall monitor-tools -n monitor-tools
	-$(KUBECTL) delete -f $(ROOT)/k8s/kafka/kafka-cluster.yaml
	-$(KUBECTL) delete -f $(ROOT)/k8s/postgres/postgres-cluster.yaml
	-$(HELM) uninstall strimzi -n $(NS)
	-$(HELM) uninstall cnpg -n cnpg-system
	-$(KUBECTL) delete ns $(NS) monitor-tools

help: ## list targets
	@grep -hE '^[a-z].*:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | sort
