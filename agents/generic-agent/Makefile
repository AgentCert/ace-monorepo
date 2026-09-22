IMAGE_REPO ?= agentcert/generic-agent
IMAGE_TAG  ?= v1.0.0
IMAGE      := $(IMAGE_REPO):$(IMAGE_TAG)
CHART      := ../../agent-charts/charts/generic-agent
NAMESPACE  ?= sock-shop

.PHONY: build kind-load push lint template install uninstall logs

build:
	docker build -t $(IMAGE) .

kind-load: build
	./build-generic-agent.sh

push: build
	docker push $(IMAGE)

lint:
	helm lint $(CHART)

template:
	helm template generic-agent $(CHART) --namespace $(NAMESPACE)

install:
	helm upgrade --install generic-agent $(CHART) \
	  --namespace $(NAMESPACE) --create-namespace

uninstall:
	helm uninstall generic-agent --namespace $(NAMESPACE)

logs:
	kubectl logs -n $(NAMESPACE) deploy/generic-agent -c agent -f
