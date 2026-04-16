# Build stage
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.2
ARG DEBIAN_VERSION=bookworm-20260406-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:bookworm-slim"

FROM ${BUILDER_IMAGE} AS builder

# Install build dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential git curl ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set build environment
ENV MIX_ENV=prod

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install mix dependencies
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only $MIX_ENV && \
    mix deps.compile

# Copy application source
COPY lib lib
COPY priv priv
COPY assets assets

# Compile application
RUN mix compile

# Build assets
RUN mix assets.deploy

# Build release
RUN mix release

# Runtime stage
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y \
      libstdc++6 \
      openssl \
      libncurses5 \
      locales \
      python3 \
      ca-certificates \
      curl \
      ffmpeg && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Copy the release from the build stage
COPY --from=builder /app/_build/prod/rel/cham ./

# Copy Python scripts (used by pipeline stages via uv run)
COPY scripts scripts

# Set runtime environment
ENV PHX_SERVER=true

EXPOSE 4000

CMD ["bin/cham", "start"]
