SHELL          := bash
.SHELLFLAGS    := -eu -o pipefail -c

PLATFORM       := $(shell uname | tr '[:upper:]' '[:lower:]')
HCLFMT         := $(shell command -v hclfmt 2> /dev/null)
VAULT_POLICIES := $(wildcard nomad_jobs/*.vault)
NOMAD_JOBS     := $(wildcard nomad_jobs/*.nomad)
# new (portable)
DOMAIN         := $(shell sed -n 's/^[[:space:]]*domain:[[:space:]]*//p' group_vars/all.yml | head -n1)

# First goal acts as default
#
# Uses `script` to log output to file but preserve color output:
# https://superuser.com/a/1434381 (macOS/BSD of course has totally different flags)
#
# Varant machine name "loadbalancer" is only chosen to prevent the Ansible provisioner from
# running for each Vagrant machine. The Ansible playbook is designed to configure *all* hosts.
.PHONY: up
up: ## DEFAULT: Start all virtual machines and provision them.
	vagrant up
	@echo "vagrant provision --provision-with ansible loadbalancer"
ifeq (darwin, $(PLATFORM))
	@script -Fq .vagrant/ansible-$$(date +%Y-%m-%dT%H-%M-%S).log vagrant provision --provision-with ansible loadbalancer
else
	@script -efq .vagrant/ansible-$$(date +%Y-%m-%dT%H-%M-%S).log -c 'vagrant provision --provision-with ansible loadbalancer'
endif


help: ## Displays help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-z0-9A-Z_-]+:.*?##/ { printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)


.PHONY: clean
clean: ## Destroy all virtual machines and delete temporary data.
	vagrant destroy -f
	rm -f .vagrant/ssh_config
	rm -f .vagrant/*.log
	rm -rf .vagrant/provisioners
	rm -rf certificates credentials


.PHONY: format-hcl
format-hcl: $(NOMAD_JOBS) $(VAULT_POLICIES) ## Format HCL files (Nomad jobs and Vault policies).
ifndef HCLFMT
	GO111MODULE=on go install github.com/hashicorp/hcl/v2/cmd/hclfmt@latest
endif
	hclfmt -check -w $^


.PHONY: lint-jobs
lint-jobs: $(NOMAD_JOBS) ## Lint Nomad jobs.
	@for job in $^; do \
		echo -e "\n$${job}:"; \
		nomad job validate $${job} | tr -d '\000-\011\013\014\016-\037' | tail -n +3; \
	done


.PHONY: lint-yaml
lint-yaml: ## Lint Ansible YAML files.
	git ls-files '*.yml' '*.yaml' | while read -r file ; do yamllint "$$file"; done
	ansible-lint -v


.PHONY: lint
lint: format-hcl lint-jobs lint-yaml ## Combined task for format-hcl lint-jobs lint-yaml.


.PHONY: run-jobs
run-jobs: ## Push all Nomad jobs to the cluster, plan and run them.
	@vagrant ssh-config > .vagrant/ssh_config
	@scp -F .vagrant/ssh_config nomad_jobs/*.nomad consul-nomad-node1:/home/vagrant/nomad_jobs/
	@vagrant ssh consul-nomad-node1 -c 'export NOMAD_VAR_domain="$(DOMAIN)"; export NOMAD_VAR_grafana_url="http://grafana.$(DOMAIN)"; \
		for job in nomad_jobs/*.nomad; do \
			nomad job plan "$$job"; \
			nomad job run "$$job"; \
			echo -e "\n"; \
		done'


.PHONY: test
test: ## Run basic tests on deployed cluster.
	ansible-playbook -i .vagrant/provisioners/ansible/inventory/vagrant_ansible_inventory tests/test.yml
