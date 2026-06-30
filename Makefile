# Makefile for purerl-tidal
#
# Build workflow:
#   1. rebar3 get-deps     - fetch Erlang dependencies (cowboy, ranch)
#   2. rebar3 compile      - compile Erlang dependencies
#   3. spago build         - PureScript → CoreFn → Erlang (via purs-backend-erl)
#                            CoreFn in output/, .erl files in output-erl/
#   4. erlc                - compile .erl → .beam files in ebin/
#
# Usage:
#   make              - full build
#   make test         - run tests
#   make run          - start the server
#   make clean        - clean PureScript output
#   make distclean    - clean everything including deps

.PHONY: all deps ps erl erl-quick test run start clean distclean help

# Default target
all: erl

help:
	@echo "purerl-tidal build targets:"
	@echo "  make           - full build (deps + ps + erl)"
	@echo "  make deps      - fetch and compile Erlang dependencies"
	@echo "  make ps        - compile PureScript to Erlang (via purs-backend-erl)"
	@echo "  make erl       - compile Erlang to beam (includes ps)"
	@echo "  make test      - run the test suite"
	@echo "  make run       - build and start the server"
	@echo "  make start     - start the server (incremental rebuild + run)"
	@echo "  make clean     - clean PureScript output"
	@echo "  make distclean - clean everything"

# Erlang dependencies (cowboy, ranch)
deps:
	@echo "==> Fetching Erlang dependencies..."
	rebar3 get-deps
	@echo "==> Compiling Erlang dependencies..."
	rebar3 compile

# PureScript compilation (spago invokes purs-backend-erl as backend)
# Generates CoreFn in output/, then .erl files in output-erl/
ps:
	@echo "==> Building PureScript (purs-backend-erl)..."
	spago build

# Erlang compilation (compiles .erl to .beam in ebin/).  Depends on
# `ps` (spago) so we first regenerate output-erl/, then run erl-quick
# to compile every changed module.
erl: ps erl-quick
	@echo "==> Build complete. BEAM files in ebin/"

# Just the erlc step, no spago.  For the DeepStar restart hot path:
# refreshes any .beam whose corresponding output-erl/.erl is newer.
# erlc skips files whose .beam is already up-to-date, so this is
# sub-second when nothing's changed.  Assumes `spago build` (or
# `make ps`) has already populated output-erl/ — if you edited .purs
# without running spago, that's a different (louder) failure.
erl-quick:
	@echo "==> Compiling Erlang to BEAM..."
	@mkdir -p ebin
	@find output-erl -name "*.erl" -exec erlc -disable-feature maybe_expr -o ebin {} \; 2>&1 | grep -v "Warning:" || true
	@erlc -disable-feature maybe_expr -o ebin src/tidal_log.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_anchor_log.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_link_anchor.erl
	@erlc -disable-feature maybe_expr -o ebin src/purerl_tidal_app.erl
	@erlc -disable-feature maybe_expr -o ebin src/purerl_tidal_sup.erl
	@cp src/purerl_tidal.app.src ebin/purerl_tidal.app
	@erlc -disable-feature maybe_expr -o ebin src/tidal_voice.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_voice_sup.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_clock.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_dispatcher.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_state_pub.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_control_bus.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_scale_bus.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_yarns_state.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_session_walker.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_conductor.erl
	@erlc -disable-feature maybe_expr -o ebin src/balistes_tables.erl
	@erlc -disable-feature maybe_expr -o ebin src/balistes_engine.erl
	@erlc -disable-feature maybe_expr -o ebin src/balistes_voice_sup.erl
	@erlc -disable-feature maybe_expr -o ebin src/balistes_voice.erl
	@erlc -disable-feature maybe_expr -o ebin src/repetitor_library_zr_african.erl
	@erlc -disable-feature maybe_expr -o ebin src/repetitor_engine.erl
	@erlc -disable-feature maybe_expr -o ebin src/repetitor_voice_sup.erl
	@erlc -disable-feature maybe_expr -o ebin src/repetitor_voice.erl
	@erlc -disable-feature maybe_expr -o ebin src/odonus_engine.erl
	@erlc -disable-feature maybe_expr -o ebin src/odonus_voice_sup.erl
	@erlc -disable-feature maybe_expr -o ebin src/odonus_voice.erl
	@erlc -disable-feature maybe_expr -o ebin src/reef_voice.erl
	@erlc -disable-feature maybe_expr -o ebin src/virtual_selene_voice_sup.erl
	@erlc -disable-feature maybe_expr -o ebin src/virtual_selene_voice.erl
	@erlc -disable-feature maybe_expr -o ebin src/selene_pattern_voice_sup.erl
	@erlc -disable-feature maybe_expr -o ebin src/selene_pattern_voice.erl

# Run tests
test: erl
	@echo "==> Running tests..."
	ERL_LIBS="_build/default/lib" erl -pa ebin -noshell \
		-eval 'F = test_main@ps:main(), F()' \
		-s init stop

# Run the Branched guided tour (test/Test/BranchedTour.purs)
tour: erl
	@echo "==> Running Branched tour..."
	ERL_LIBS="_build/default/lib" erl -pa ebin -noshell \
		-eval 'F = test_branchedTour@ps:runTour(), F()' \
		-s init stop

# Start the server (with rebuild)
run: erl
	@echo "==> Starting purerl-tidal server on port 3012..."
	@echo "    WebSocket: ws://localhost:3012/ws"
	@echo "    Press Ctrl+C to stop"
	ERL_LIBS="_build/default/lib" erl -pa ebin -noshell \
		-eval 'F = main@ps:main(), F()'

# Start the server.  Depends on `erl` so the BEAMs in ebin/ can't lag
# behind output-erl/.  An incremental erlc pass is sub-second when
# nothing's changed; the cost of skipping it is hours of "why is this
# function undef" debugging (see feedback_purerl_tidal_make_not_spago
# in agent memory).
start: erl
	@echo "==> Starting purerl-tidal server on port 3012..."
	@echo "    WebSocket: ws://localhost:3012/ws"
	@echo "    Press Ctrl+C to stop"
	ERL_LIBS="_build/default/lib" erl -pa ebin -noshell \
		-eval 'F = main@ps:main(), F()'

# Clean PureScript output
clean:
	@echo "==> Cleaning PureScript output..."
	rm -rf output
	rm -rf output-erl
	rm -rf ebin/*.beam

# Clean everything
distclean: clean
	@echo "==> Cleaning all build artifacts..."
	rm -rf _build
	rm -rf .spago
	rm -rf ebin

# Rebuild everything from scratch
rebuild: distclean deps all
