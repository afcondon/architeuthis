# Tilted Radio (Tidal Editor) Erlang Backend
# PureScript compiled to Erlang via Purerl
#
# Build:   docker build -t psd3-tidal-backend .
# Run:     docker run -p 3012:3012 psd3-tidal-backend

FROM erlang:26-alpine

WORKDIR /app

# Copy compiled BEAM files
COPY ebin/ ./ebin/

# Copy rebar3 dependencies
COPY _build/default/lib/ ./_build/default/lib/

# Copy rebar config (for runtime reference)
COPY rebar.config ./

EXPOSE 3012

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s \
  CMD wget -q --spider http://localhost:3012/ || exit 1

# Start Erlang with the application
CMD ["erl", "-pa", "ebin", "_build/default/lib/*/ebin", \
     "-noshell", "-eval", "application:ensure_all_started(purerl_tidal)"]
