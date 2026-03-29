.PHONY: help setup test serve precommit clean-artifacts clean-sandbox clean-assets

help:
	@echo "FluxClaw — common targets:"
	@echo "  make setup          mix deps.get + ecto + assets"
	@echo "  make test           mix test"
	@echo "  make serve          mix phx.server"
	@echo "  make precommit      mix precommit"
	@echo "  make clean-artifacts  remove _build, deps, digested assets, sandbox trees"
	@echo "  make clean-sandbox  remove local sandbox dirs only"
	@echo "  make clean-assets   remove priv/static/assets build output"

setup:
	mix setup

test:
	mix test

serve:
	mix phx.server

precommit:
	mix precommit

clean-sandbox:
	rm -rf flux_claw_sandbox tmp/flux_claw_sandbox tmp/test_flux_claw_sandbox

clean-assets:
	rm -rf priv/static/assets

clean-artifacts: clean-sandbox clean-assets
	rm -rf _build deps
