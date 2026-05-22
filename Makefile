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

.PHONY: all deps ps erl test run start clean distclean help

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
	@echo "  make start     - start the server (no rebuild)"
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

# Erlang compilation (compiles .erl to .beam in ebin/)
erl: ps
	@echo "==> Compiling Erlang to BEAM..."
	@mkdir -p ebin
	@find output-erl -name "*.erl" -exec erlc -disable-feature maybe_expr -o ebin {} \; 2>&1 | grep -v "Warning:" || true
	@# Standalone Erlang utility modules (no PureScript counterpart, not foreign).
	@erlc -disable-feature maybe_expr -o ebin src/tidal_log.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_anchor_log.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_link_anchor.erl
	@# OTP application + top-level supervisor.
	@erlc -disable-feature maybe_expr -o ebin src/purerl_tidal_app.erl
	@erlc -disable-feature maybe_expr -o ebin src/purerl_tidal_sup.erl
	@cp src/purerl_tidal.app.src ebin/purerl_tidal.app
	@# Voice gen_server + supervisor (per-voice supervision tree).
	@erlc -disable-feature maybe_expr -o ebin src/tidal_voice.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_voice_sup.erl
	@# Clock (gen_statem) and Dispatcher (gen_server).
	@erlc -disable-feature maybe_expr -o ebin src/tidal_clock.erl
	@erlc -disable-feature maybe_expr -o ebin src/tidal_dispatcher.erl
	@# State publisher (gen_server) — replaces MIDIScheduler.publishState.
	@erlc -disable-feature maybe_expr -o ebin src/tidal_state_pub.erl
	@# Live control bus (knob → ETS → State.controls).
	@erlc -disable-feature maybe_expr -o ebin src/tidal_control_bus.erl
	@# Live active-scale bus (set-scale verb → ETS → Window.activeScale).
	@erlc -disable-feature maybe_expr -o ebin src/tidal_scale_bus.erl
	@# Per-yarns-cell voice allocator state (yarns macro verb).
	@erlc -disable-feature maybe_expr -o ebin src/tidal_yarns_state.erl
	@# Phase 4 typeful-cues Session walker (reload-baseline path).
	@erlc -disable-feature maybe_expr -o ebin src/tidal_session_walker.erl
	@# Section conductor (MVP-2 play-piece path).
	@erlc -disable-feature maybe_expr -o ebin src/tidal_conductor.erl
	@# Balistes virtual module (BEAM-native MI Balistes clone).
	@erlc -disable-feature maybe_expr -o ebin src/balistes_tables.erl
	@erlc -disable-feature maybe_expr -o ebin src/balistes_engine.erl
	@erlc -disable-feature maybe_expr -o ebin src/balistes_voice_sup.erl
	@erlc -disable-feature maybe_expr -o ebin src/balistes_voice.erl
	@# Repetitor virtual module (ZR-inspired, BEAM-native).
	@erlc -disable-feature maybe_expr -o ebin src/repetitor_library_zr_african.erl
	@erlc -disable-feature maybe_expr -o ebin src/repetitor_engine.erl
	@erlc -disable-feature maybe_expr -o ebin src/repetitor_voice_sup.erl
	@erlc -disable-feature maybe_expr -o ebin src/repetitor_voice.erl
	@# René machine (Make-Noise René-inspired Cartesian sequencer).
	@erlc -disable-feature maybe_expr -o ebin src/rene_engine.erl
	@erlc -disable-feature maybe_expr -o ebin src/rene_voice_sup.erl
	@erlc -disable-feature maybe_expr -o ebin src/rene_voice.erl
	@# Virtual polysignal (BEAM-native polysignal targeting Virtual <prefix>).
	@erlc -disable-feature maybe_expr -o ebin src/virtual_polysignal_voice_sup.erl
	@erlc -disable-feature maybe_expr -o ebin src/virtual_polysignal_voice.erl
	@echo "==> Build complete. BEAM files in ebin/"

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

# Start the server (no rebuild)
start:
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
