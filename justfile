default:
    @just --list

# First-time project setup (deps + assets)
setup:
    mix setup

# Install dependencies
deps:
    mix deps.get

# Compile with warnings as errors
compile:
    mix compile --warnings-as-errors

# Format code
fmt:
    mix format

# Check formatting
fmt-check:
    mix format --check-formatted

# Run credo (linter)
credo:
    mix credo --strict

# Run sobelow (security scan)
sobelow:
    mix sobelow --exit low

# Run dialyzer (static analysis)
dialyzer:
    mix dialyzer

# Run tests
test:
    mix test

# Run the Phoenix server
server:
    iex -S mix phx.server

# Fast checks — everything except dialyzer (mirrored by the CI `check` job)
check-fast: fmt-check compile credo sobelow test

# Run all checks (CI equivalent)
check: check-fast dialyzer
