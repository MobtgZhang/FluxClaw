.PHONY: help setup test assets serve desktop precommit clean-artifacts clean-sandbox clean-assets

ifneq ($(origin PORT), undefined)
export PORT
endif

help:
	@echo "FluxClaw — common targets:"
	@echo "  make setup          mix deps.get + ecto + assets"
	@echo "  make test           mix test"
	@echo "  make serve          start web app; auto-select a free port from 4000"
	@echo "  make serve PORT=4100  start web app on a specific port"
	@echo "  make desktop        start desktop + backend; close window to stop both"
	@echo "  make precommit      mix precommit"
	@echo "  make clean-artifacts  remove _build, deps, digested assets, sandbox trees"
	@echo "  make clean-sandbox  remove local sandbox dirs only"
	@echo "  make clean-assets   remove priv/static/assets build output"

setup:
	mix setup

test:
	mix test

assets:
	mix assets.build

serve: assets
	mix fluxclaw.serve

desktop: assets
	@test -x desktop/node_modules/.bin/electron || npm ci --prefix desktop
	npm run dev --prefix desktop

precommit:
	mix precommit

clean-sandbox:
	rm -rf flux_claw_sandbox tmp/flux_claw_sandbox tmp/test_flux_claw_sandbox

clean-assets:
	rm -rf priv/static/assets

clean-artifacts: clean-sandbox clean-assets
	rm -rf _build deps
