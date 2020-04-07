.DEFAULT_GOAL := help
SHELL := /bin/bash
Q = @
Q_FLAG = -q
QUIET_FLAG = --quiet
V_FLAG =
S_FLAG = -s
X_FLAG =
UNAME_S := $(shell uname -s)
CONTAINER_BUILDER = buildah
CONTAINER_RUNNER = podman
GOOS=linux
ifeq ($(UNAME_S),Darwin)
	CONTAINER_BUILDER = docker
	CONTAINER_RUNNER = docker
        GOOS = darwin
endif

# Create output directory for artifacts and test results. ./out is supposed to
# be a safe place for all targets to write to while knowing that all content
# inside of ./out is wiped once "make clean" is run.
$(shell mkdir -p ./out);

.PHONY: help
help: ## Credit: https://gist.github.com/prwhite/8168133#gistcomment-2749866
	@awk '{ if ($$0 ~ /^.PHONY: [a-zA-Z\-\_0-9]+$$/) { \
			helpCommand = substr($$0, index($$0, ":") + 2); \
		} else if ($$0 ~ /^[a-zA-Z\-\_0-9.]+:/) { \
			helpCommand = substr($$0, 0, index($$0, ":")); \
			if (helpMessage) { \
				printf "\033[36m%-25s\033[0m %s\n", \
					helpCommand, helpMessage; \
				helpMessage = ""; \
			} \
		} else if ($$0 ~ /^##/) { \
			if (helpMessage) { \
				helpMessage = helpMessage"\n                     "substr($$0, 3); \
			} else { \
				helpMessage = substr($$0, 3); \
			} \
		} \
		}' \
		$(MAKEFILE_LIST)


#-----------------------------------------------------------------------------
# Global Variables
#-----------------------------------------------------------------------------

# By default the project should be build under GOPATH/src/github.com/<orgname>/<reponame>
GO_PACKAGE_ORG_NAME ?= $(shell basename $$(dirname $$PWD))
GO_PACKAGE_REPO_NAME ?= $(shell basename $$PWD)
GO_PACKAGE_PATH ?= github.com/${GO_PACKAGE_ORG_NAME}/${GO_PACKAGE_REPO_NAME}
GO_PACKAGE_REPO_NAME = jenkins-operator
CGO_ENABLED ?= 0
GO111MODULE ?= on
GOCACHE ?= "$(shell echo ${PWD})/out/gocache"

# This variable is for artifacts to be archived by Prow jobs at OpenShift CI
# The actual value will be set by the OpenShift CI accordingly
ARTIFACT_DIR ?= "$(shell echo ${PWD})/out"

GOCOV_DIR ?= $(ARTIFACT_DIR)/test-coverage
GOCOV_FILE_TEMPL ?= $(GOCOV_DIR)/REPLACE_TEST.txt
GOCOV ?= "-covermode=atomic -coverprofile REPLACE_FILE"

GIT_COMMIT_ID = $(shell git rev-parse --short HEAD)

OPERATOR_VERSION ?= 0.0.4
OPERATOR_GROUP ?= ${GO_PACKAGE_ORG_NAME}
OPERATOR_IMAGE ?= quay.io/${OPERATOR_GROUP}/${GO_PACKAGE_REPO_NAME}
OPERATOR_TAG_SHORT ?= $(OPERATOR_VERSION)
OPERATOR_TAG_LONG ?= $(OPERATOR_VERSION)-$(GIT_COMMIT_ID)

QUAY_TOKEN ?= ""

MANIFESTS_DIR ?= ./deploy/olm-catalog/jenkins-operator/
MANIFESTS_TMP ?= ./tmp/manifests

GOLANGCI_LINT_BIN=./out/golangci-lint

# -- Variables for uploading code coverage reports to Codecov.io --
# This default path is set by the OpenShift CI
CODECOV_TOKEN_PATH ?= "/usr/local/redhat-developer-jenkins-operator-codecov-token/token"
CODECOV_TOKEN ?= @$(CODECOV_TOKEN_PATH)
REPO_OWNER := $(shell echo $$CLONEREFS_OPTIONS | jq '.refs[0].org')
REPO_NAME := $(shell echo $$CLONEREFS_OPTIONS | jq '.refs[0].repo')
BASE_COMMIT := $(shell echo $$CLONEREFS_OPTIONS | jq '.refs[0].base_sha')
PR_COMMIT := $(shell echo $$CLONEREFS_OPTIONS | jq '.refs[0].pulls[0].sha')
PULL_NUMBER := $(shell echo $$CLONEREFS_OPTIONS | jq '.refs[0].pulls[0].number')

.PHONY: clean
## Removes temp directories
clean:
	$(Q)-rm -rf ${V_FLAG} ./out

## dependencies: run 'go mod vendor' to resets the vendor folder to what is defined in go.mod.
dependencies: go.mod go.sum
	$(Q)GOCACHE=$(GOCACHE) go mod vendor ${V_FLAG}

.PHONY: build
## Build: compile the operator for Linux/AMD64.
build: out/operator

.PHONY: unit-tests
## Runs the unit tests without code coverage
unit-tests:
	$(info Running unit test: $@)
	$(Q)GO111MODULE=$(GO111MODULE) GOCACHE=$(GOCACHE) \
		go test $(shell GOCACHE="$(GOCACHE)" go list ./...|grep -v e2e) -v -mod vendor $(TEST_EXTRA_ARGS)

.PHONY: deploy
## Deploy: operator rbac and crds
deploy: deploy-rbac deploy-crds

.PHONY: run-local
## Local: Run operator locally
run-local: deploy-clean deploy-rbac deploy-crds
	$(Q)operator-sdk up local

.PHONY: e2e-tests
## Runs the e2e tests locally from test/e2e dir
e2e-tests: e2e-setup
	$(info Running E2E test: $@)
	$(Q)GO111MODULE=$(GO111MODULE) GOCACHE=$(GOCACHE) \
		operator-sdk test local ./test/e2e \
			--debug \
			--namespace $(TEST_NAMESPACE) \
			--up-local \
			--go-test-flags "-timeout=5m -test.v"

# Generate namespace name for test
out/test-namespace:
	@echo -n "test-namespace-$(shell uuidgen | tr '[:upper:]' '[:lower:]')" > ./out/test-namespace

.PHONY: get-test-namespace
get-test-namespace: out/test-namespace
	$(eval TEST_NAMESPACE := $(shell cat ./out/test-namespace))

# E2E test
.PHONY: e2e-setup
e2e-setup: e2e-cleanup
	$(Q)kubectl create namespace $(TEST_NAMESPACE)
	$(Q)kubectl --namespace $(TEST_NAMESPACE) apply -f ./test/e2e/setup/jenkins_v1alpha2_crd.yaml

.PHONY: e2e-cleanup
e2e-cleanup: get-test-namespace
	$(Q)-kubectl delete namespace $(TEST_NAMESPACE) --timeout=45s --wait

.PHONY: test
# Test: Runs unit and integration (e2e) tests
test: unit-tests e2e-tests

.PHONY: lint
## Runs linters on Go code files and YAML files - DISABLED TEMPORARILY
lint: setup-venv lint-go-code lint-yaml courier

YAML_FILES := $(shell find . -path ./vendor -prune -o -type f -regex ".*y[a]ml" -print)
.PHONY: lint-yaml
# runs yamllint on all yaml files
lint-yaml: ${YAML_FILES}
	$(Q)./out/venv3/bin/pip install yamllint
	$(Q)./out/venv3/bin/yamllint -c .yamllint $(YAML_FILES)

.PHONY: lint-go-code
# Checks the code with golangci-lint
lint-go-code: $(GOLANGCI_LINT_BIN)
	$(Q)GOCACHE=$(GOCACHE) ./out/golangci-lint ${V_FLAG} run --deadline=30m

$(GOLANGCI_LINT_BIN):
	$(Q)curl -sfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b ./out v1.19.1

.PHONY: coverage
## Runs the unit tests with code coverage
coverage:
	$(info Running unit test: $@)
	$(eval GOCOV_FILE := $(shell echo $(GOCOV_FILE_TEMPL) | sed -e 's,REPLACE_TEST,$(@),'))
	$(eval GOCOV_FLAGS := $(shell echo $(GOCOV) | sed -e 's,REPLACE_FILE,$(GOCOV_FILE),'))
	$(Q)mkdir -p $(GOCOV_DIR)
	$(Q)rm -vf '$(GOCOV_DIR)/*.txt'
	$(Q)GO111MODULE=$(GO111MODULE) GOCACHE=$(GOCACHE) \
		go test $(shell GOCACHE="$(GOCACHE)" go list ./...|grep -v e2e) $(GOCOV_FLAGS) -v -mod vendor $(TEST_EXTRA_ARGS)
	$(Q)GOCACHE=$(GOCACHE) go tool cover -func=$(GOCOV_FILE)

.PHONY: e2e-tests-olm-ci
# OLM-E2E: Adds the operator as a subscription, and run e2e tests without any setup.
e2e-tests-olm-ci:
	$(Q)sed -e "s,REPLACE_IMAGE,registry.svc.ci.openshift.org/${OPENSHIFT_BUILD_NAMESPACE}/stable:jenkins-operator-registry," ./test/operator-hub/catalog_source.yaml | kubectl apply -f -
	$(Q)kubectl apply -f ./test/operator-hub/subscription.yaml
	$(eval DEPLOYED_NAMESPACE := openshift-operators)
	$(Q)./hack/check-crds.sh
	$(Q)operator-sdk --verbose test local ./test/e2e --no-setup --go-test-flags "-timeout=15m"

out/operator:
	$(Q)GOARCH=amd64 GOOS=$(GOOS) go build ${V_FLAG} -o ./out/$(GO_PACKAGE_REPO_NAME) cmd/manager/main.go

## Build-Image: using operator-sdk to build a new image
build-image:
	$(Q)operator-sdk build --image-builder=$(CONTAINER_BUILDER) "$(OPERATOR_IMAGE):$(OPERATOR_TAG_LONG)"

## Generate-K8S: after modifying _types, generate Kubernetes scaffolding.
generate-k8s:
	$(Q)GOCACHE=$(GOCACHE) operator-sdk generate k8s

## Generate-OpenAPI: after modifying _types, generate OpenAPI scaffolding.
generate-openapi:
	$(Q)GOCACHE=$(GOCACHE) operator-sdk generate openapi

## Generate CSV: using operator-sdk generate cluster-service-version for current operator version
generate-csv:
	operator-sdk olm-catalog gen-csv --csv-version=$(OPERATOR_VERSION) --verbose

generate-olm:
	operator-courier --verbose flatten $(MANIFESTS_DIR) $(MANIFESTS_TMP)
	cp -vf deploy/*_crd.yaml $(MANIFESTS_TMP)

# Prepare-CSV: using a temporary location copy all operator CRDs and metadata to generate a CSV.
prepare-csv: build-image
	$(eval ICON_BASE64_DATA := $(shell cat ./assets/icon/red-hat-logo.png | base64))
	@rm -rf $(MANIFESTS_TMP) || true
	@mkdir -p ${MANIFESTS_TMP}
	$(Q)./out/venv3/bin/pip install operator-courier --verbose flatten $(MANIFESTS_DIR) $(MANIFESTS_TMP)
	cp -vf deploy/crds/*_crd.yaml $(MANIFESTS_TMP)
	sed -i -e 's,REPLACE_IMAGE,"$(OPERATOR_IMAGE):latest",g' $(MANIFESTS_TMP)/*.yaml
	sed -i -e 's,REPLACE_ICON_BASE64_DATA,$(ICON_BASE64_DATA),' $(MANIFESTS_TMP)/*.yaml
	operator-courier --verbose verify $(MANIFESTS_TMP)

.PHONY: push-operator
# Push-Operator: Uplaod operator to Quay.io application repository
push-operator: prepare-csv
	operator-courier push $(MANIFESTS_TMP) $(OPERATOR_GROUP) $(GO_PACKAGE_REPO_NAME) $(OPERATOR_VERSION) "$(QUAY_TOKEN)"

# Push-Image: push container image to upstream, including latest tag.
push-image: build-image
	$(CONTAINER_RUNNER) tag "$(OPERATOR_IMAGE):$(OPERATOR_TAG_LONG)" "$(OPERATOR_IMAGE):latest"
	$(CONTAINER_RUNNER) push "$(OPERATOR_IMAGE):$(OPERATOR_TAG_LONG)"
	$(CONTAINER_RUNNER) push "$(OPERATOR_IMAGE):latest"

.PHONY: deploy-rbac
# Deploy-RBAC: Setup service account and deploy RBAC
deploy-rbac:
	$(Q)kubectl create -f deploy/service_account.yaml
	$(Q)kubectl create -f deploy/role.yaml
	$(Q)kubectl create -f deploy/role_binding.yaml

.PHONY: deploy-crds
# Deploy-CRD: Deploy CRD
deploy-crds:
	$(Q)kubectl create -f deploy/crds/jenkins_v1alpha2_jenkins_crd.yaml

.PHONY: deploy-clean
# Deploy-Clean: Removing CRDs and CRs
deploy-clean:
	$(Q)-kubectl delete -f deploy/crds/jenkins_v1alpha2_jenkins_cr.yaml
	$(Q)-kubectl delete -f deploy/crds/jenkins_v1alpha2_jenkins_crd.yaml
	$(Q)-kubectl delete -f deploy/operator.yaml
	$(Q)-kubectl delete -f deploy/role_binding.yaml
	$(Q)-kubectl delete -f deploy/role.yaml
	$(Q)-kubectl delete -f deploy/service_account.yaml

.PHONY: install-operator-source
# Install the Jenkins Operator
install-operator-source:
	$(Q)kubectl apply -f jenkins-operator-source.yaml

.PHONY: setup-venv
setup-venv:
	$(Q)python3 -m venv ./out/venv3
	$(Q)./out/venv3/bin/pip install --upgrade setuptools
	$(Q)./out/venv3/bin/pip install --upgrade pip

.PHONY: courier
# Validate manifests using operator-courier
courier:
	$(Q)./out/venv3/bin/pip install operator-courier
	$(Q)./out/venv3/bin/operator-courier flatten $(MANIFESTS_DIR)  ./out/manifests
	$(Q)./out/venv3/bin/operator-courier verify ./out/manifests

.PHONY: upload-codecov-report
# Uploads the test coverage reports to codecov.io.
# DO NOT USE LOCALLY: must only be called by OpenShift CI when processing new PR and when a PR is merged!
upload-codecov-report:
ifneq ($(PR_COMMIT), null)
	@echo "uploading test coverage report for pull-request #$(PULL_NUMBER)..."
	@/bin/bash <(curl -s https://codecov.io/bash) \
		-t $(CODECOV_TOKEN) \
		-f $(GOCOV_DIR)/*.txt \
		-C $(PR_COMMIT) \
		-r $(REPO_OWNER)/$(REPO_NAME) \
		-P $(PULL_NUMBER) \
		-Z > codecov-upload.log
else
	@echo "uploading test coverage report after PR was merged..."
	@/bin/bash <(curl -s https://codecov.io/bash) \
		-t $(CODECOV_TOKEN) \
		-f $(GOCOV_DIR)/*.txt \
		-C $(BASE_COMMIT) \
		-r $(REPO_OWNER)/$(REPO_NAME) \
		-Z > codecov-upload.log
endif
