# =============================================================================
# snowflake-claims-platform — Makefile
# -----------------------------------------------------------------------------
# 100% Snowflake-only synthetic healthcare claims platform.
# Ingestion is internal-stage + PUT + COPY INTO ONLY. No S3/GCS/Blob/Airflow/etc.
# Data is SYNTHETIC. Never treat it as real CMS/Medicare/Medicaid/PHI.
#
# All tooling runs from a local virtualenv at ./.venv (Python 3.13 — dbt does
# not yet support 3.14). `make venv` creates it and installs everything.
#
# Usage:
#   make venv           # create ./.venv and install dbt + snow CLI + deps
#   make gen-data
#   make sf-setup
#   make stage-load
#   make dbt-build DBT_TARGET=dev
# =============================================================================

# ----- Virtualenv / interpreter ----------------------------------------------
VENV        ?= .venv
PY313       ?= /opt/homebrew/opt/python@3.13/bin/python3.13
PYTHON      := $(VENV)/bin/python
PIP         := $(VENV)/bin/pip
DBT         := $(VENV)/bin/dbt
SNOW        := $(VENV)/bin/snow

# ----- Configurable variables ------------------------------------------------
# ENV         : logical environment (dev|prod). Selects DB CLAIMS_DEV/CLAIMS_PROD.
# DBT_TARGET  : dbt target profile (dev|prod|ci). Defaults from ENV.
# SF_CONN     : named snow CLI connection (see .snowflake/config.toml).
ENV         ?= dev
DBT_TARGET  ?= $(ENV)
SF_CONN     ?= my_example_connection
DBT_DIR     ?= dbt
DATA_OUT    ?= data_generator/output

# Point the snow CLI and dbt at the repo-local config (git-ignored).
export SNOWFLAKE_HOME := $(CURDIR)/.snowflake
export DBT_PROFILES_DIR := $(CURDIR)/$(DBT_DIR)

# Map ENV -> Snowflake database name (single-vendor, no external services).
ifeq ($(ENV),prod)
SF_DATABASE ?= CLAIMS_PROD
else
SF_DATABASE ?= CLAIMS_DEV
endif

# Ordered setup scripts 001..012 (see docs/architecture.md / README.md).
SETUP_SCRIPTS := $(sort $(wildcard snowflake/setup/0*.sql))

.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
.PHONY: help
help: ## Show this help (default target)
	@echo "snowflake-claims-platform — make targets"
	@echo "  ENV=$(ENV)  DBT_TARGET=$(DBT_TARGET)  SF_DATABASE=$(SF_DATABASE)  SF_CONN=$(SF_CONN)"
	@echo "  venv=$(VENV)  SNOWFLAKE_HOME=$(SNOWFLAKE_HOME)"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# -----------------------------------------------------------------------------
.PHONY: venv
venv: ## Create ./.venv (Python 3.13) and install dbt + snow CLI + all deps
	$(PY313) -m venv $(VENV)
	$(PIP) install --upgrade pip setuptools wheel
	$(PIP) install -r requirements-dev.txt
	@echo ">> venv ready: $$($(PYTHON) --version)"
	@$(DBT) --version | grep -E 'installed|snowflake' || true
	@$(SNOW) --version || true

# -----------------------------------------------------------------------------
.PHONY: install
install: ## (Re)install/upgrade pinned tooling into an existing ./.venv
	$(PIP) install -r requirements-dev.txt

# -----------------------------------------------------------------------------
.PHONY: gen-data
gen-data: ## Generate SYNTHETIC claims NDJSON into data_generator/output/
	$(PYTHON) data_generator/generate_synthetic_claims.py --out $(DATA_OUT)

# -----------------------------------------------------------------------------
.PHONY: sf-test
sf-test: ## Verify the snow CLI connection (opens browser for SSO)
	$(SNOW) connection test --connection $(SF_CONN)

# -----------------------------------------------------------------------------
.PHONY: sf-setup
sf-setup: ## Run Snowflake setup scripts 001-012 (idempotent) via snow CLI
	@echo ">> Running Snowflake setup against ENV=$(ENV) (DB=$(SF_DATABASE)) conn=$(SF_CONN)"
	@for f in $(SETUP_SCRIPTS); do \
		echo ">> $$f"; \
		$(SNOW) sql --connection $(SF_CONN) --filename $$f \
			-D "env=$(ENV)" -D "database=$(SF_DATABASE)" -D "claims_db=$(SF_DATABASE)" || exit 1; \
	done

# -----------------------------------------------------------------------------
.PHONY: stage-load
stage-load: ## PUT NDJSON to internal stage + COPY INTO RAW (no external storage)
	@echo ">> Staging + loading SYNTHETIC data into $(SF_DATABASE).RAW"
	$(SNOW) sql --connection $(SF_CONN) --filename snowflake/load/put_and_copy.sql \
		-D "env=$(ENV)" -D "database=$(SF_DATABASE)" -D "data_out=$(DATA_OUT)"

# -----------------------------------------------------------------------------
.PHONY: dbt-deps
dbt-deps: ## Install dbt package dependencies
	cd $(DBT_DIR) && $(CURDIR)/$(DBT) deps

# -----------------------------------------------------------------------------
.PHONY: dbt-seed
dbt-seed: ## Load dbt reference seeds (code sets, plan types, etc.)
	cd $(DBT_DIR) && $(CURDIR)/$(DBT) seed --target $(DBT_TARGET)

# -----------------------------------------------------------------------------
.PHONY: dbt-build
dbt-build: ## dbt build (run + test) BRONZE->SILVER->GOLD->SEMANTIC
	cd $(DBT_DIR) && $(CURDIR)/$(DBT) build --target $(DBT_TARGET)

# -----------------------------------------------------------------------------
.PHONY: dbt-test
dbt-test: ## Run dbt tests only (DQ + DCM reconciliation)
	cd $(DBT_DIR) && $(CURDIR)/$(DBT) test --target $(DBT_TARGET)

# -----------------------------------------------------------------------------
.PHONY: dbt-parse
dbt-parse: ## Parse/compile the dbt project (no warehouse writes)
	cd $(DBT_DIR) && $(CURDIR)/$(DBT) parse --target $(DBT_TARGET)

# -----------------------------------------------------------------------------
.PHONY: dbt-docs
dbt-docs: ## Generate dbt docs + lineage graph
	cd $(DBT_DIR) && $(CURDIR)/$(DBT) docs generate --target $(DBT_TARGET)

# ===== dbt Projects on Snowflake (dbt runs INSIDE Snowflake) =================
# Deploys the dbt project as a native DBT PROJECT object and executes it
# server-side via EXECUTE DBT PROJECT. No external runner. See
# docs/dbt_on_snowflake.md and snowflake/setup/013_create_dbt_on_snowflake.sql.
SF_DBT_PROJECT ?= CLAIMS_DBT_PROJECT
SF_DBT_EAI     ?= CLAIMS_DBT_EAI

.PHONY: dbt-sf-deploy
dbt-sf-deploy: ## Deploy local dbt project to Snowflake as a DBT PROJECT object
	$(SNOW) dbt deploy $(SF_DBT_PROJECT) \
		--source $(DBT_DIR) \
		--profiles-dir $(DBT_DIR)/snowflake_profiles \
		--default-target $(DBT_TARGET) \
		--external-access-integration $(SF_DBT_EAI) \
		--connection $(SF_CONN) --force

.PHONY: dbt-sf-deps
dbt-sf-deps: ## Run `dbt deps` inside Snowflake (needs EXTERNAL ACCESS INTEGRATION)
	$(SNOW) sql --connection $(SF_CONN) \
		-q "EXECUTE DBT PROJECT $(SF_DATABASE).DBT.$(SF_DBT_PROJECT) ARGS='deps';"

.PHONY: dbt-sf-build
dbt-sf-build: ## Run `dbt build` inside Snowflake (EXECUTE DBT PROJECT)
	$(SNOW) sql --connection $(SF_CONN) \
		-q "EXECUTE DBT PROJECT $(SF_DATABASE).DBT.$(SF_DBT_PROJECT) ARGS='build --target $(DBT_TARGET)';"

.PHONY: dbt-sf-test
dbt-sf-test: ## Run `dbt test` inside Snowflake (EXECUTE DBT PROJECT)
	$(SNOW) sql --connection $(SF_CONN) \
		-q "EXECUTE DBT PROJECT $(SF_DATABASE).DBT.$(SF_DBT_PROJECT) ARGS='test --target $(DBT_TARGET)';"

.PHONY: dbt-sf-run-task
dbt-sf-run-task: ## Trigger the scheduled native dbt build TASK once
	$(SNOW) sql --connection $(SF_CONN) \
		-q "EXECUTE TASK $(SF_DATABASE).DBT.CLAIMS_DBT_BUILD_DAILY;"

# ===== Infrastructure as a Snowflake DCM project (declarative; see dcm/) ======
# Provisions roles/warehouses/db/schemas/control+audit+bronze+semantic tables +
# grants declaratively. PLAN previews the change set; DEPLOY applies it. The PRD
# variant swaps database -> CLAIMS_PROD via the PROD manifest configuration.
DCM_PROJECT_OBJ ?= OPS_DB.DCM.CLAIMS_INFRA_DCM_DEV
DCM_TARGET      ?= DCM_DEV

.PHONY: dcm-create
dcm-create: ## Create the DCM PROJECT object (first time; needs OPS_DB.DCM bootstrap)
	$(SNOW) dcm create $(DCM_PROJECT_OBJ) --from dcm --target $(DCM_TARGET) --connection $(SF_CONN)

.PHONY: dcm-plan
dcm-plan: ## Preview the infra change set (dry run -> out/plan_result.json)
	$(SNOW) dcm plan $(DCM_PROJECT_OBJ) --from dcm --target $(DCM_TARGET) --connection $(SF_CONN) --save-output

.PHONY: dcm-deploy
dcm-deploy: ## Apply the DCM infra change set (CREATE/ALTER/DROP to match definitions)
	$(SNOW) dcm deploy $(DCM_PROJECT_OBJ) --from dcm --target $(DCM_TARGET) --connection $(SF_CONN) --save-output

# -----------------------------------------------------------------------------
.PHONY: tf-init
tf-init: ## terraform init (Snowflake provider only — no cloud backends)
	cd terraform && terraform init

# -----------------------------------------------------------------------------
.PHONY: tf-plan
tf-plan: ## terraform plan for ENV ($(ENV))
	cd terraform && terraform plan -var-file=environments/$(ENV).tfvars

# -----------------------------------------------------------------------------
.PHONY: tf-apply
tf-apply: ## terraform apply for ENV ($(ENV))
	cd terraform && terraform apply -var-file=environments/$(ENV).tfvars

# -----------------------------------------------------------------------------
.PHONY: mcp-server
mcp-server: ## Run the fallback custom MCP server (stdio) from the venv
	$(PYTHON) mcp/fallback_custom_server/server.py

# -----------------------------------------------------------------------------
.PHONY: lint
lint: ## Lint SQL (sqlfluff) and Python (ruff) if available in the venv
	@$(VENV)/bin/sqlfluff lint $(DBT_DIR)/models 2>/dev/null || echo "sqlfluff not installed — skipping SQL lint"
	@$(VENV)/bin/ruff check data_generator mcp 2>/dev/null || echo "ruff not installed — skipping Python lint"

# -----------------------------------------------------------------------------
.PHONY: clean
clean: ## Remove generated data, dbt artifacts, and python caches
	rm -rf $(DBT_DIR)/target $(DBT_DIR)/dbt_packages $(DBT_DIR)/logs
	find . -type d -name '__pycache__' -prune -exec rm -rf {} +
	find $(DATA_OUT) -type f ! -name '.gitkeep' -delete 2>/dev/null || true

# -----------------------------------------------------------------------------
.PHONY: clean-venv
clean-venv: ## Delete the virtualenv
	rm -rf $(VENV)
