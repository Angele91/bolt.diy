# ---- build stage ----
FROM node:22-bookworm-slim AS build
WORKDIR /app

# CI-friendly env
ENV HUSKY=0
ENV CI=true

# Install git and use pnpm
RUN apt-get update && apt-get install -y --no-install-recommends git \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable && corepack prepare pnpm@9.15.9 --activate

# Accept (optional) build-time public URL for Remix/Vite (Coolify can pass it)
ARG VITE_PUBLIC_APP_URL
ENV VITE_PUBLIC_APP_URL=${VITE_PUBLIC_APP_URL}

# Install deps efficiently
COPY package.json pnpm-lock.yaml* ./
RUN pnpm fetch

# Copy source and build
COPY . .
# install with dev deps (needed to build)
RUN pnpm install --offline --frozen-lockfile

# Build the Remix app (SSR + client)
RUN NODE_OPTIONS=--max-old-space-size=4096 pnpm run build

# We need to keep development dependencies for development mode
# For production, we would prune them but this causes issues with remix
# RUN pnpm prune --prod --ignore-scripts


# ---- runtime stage ----
FROM node:22-bookworm-slim AS runtime
WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000
ENV HOST=0.0.0.0

# Node is already in /usr/local/bin in the base image

# Install curl, wget, git and enable pnpm globally
RUN apt-get update && apt-get install -y --no-install-recommends curl wget git \
  && rm -rf /var/lib/apt/lists/* \
  && corepack enable && corepack prepare pnpm@9.15.9 --activate

# Copy only what we need to run
COPY --from=build /app/build /app/build
COPY --from=build /app/node_modules /app/node_modules
COPY --from=build /app/package.json /app/package.json
COPY --from=build /app/pre-start.cjs /app/pre-start.cjs
COPY --from=build /app/vite.config.ts /app/vite.config.ts
COPY --from=build /app/vite-electron.config.ts /app/vite-electron.config.ts
COPY --from=build /app/uno.config.ts /app/uno.config.ts
COPY --from=build /app/tsconfig.json /app/tsconfig.json
COPY --from=build /app/bindings.sh /app/bindings.sh

EXPOSE 3000

# Healthcheck for Coolify
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 \
  CMD curl -fsS http://localhost:3000/ || exit 1

# Start the Remix server
CMD ["node", "build/server/index.js"]


# ---- development stage ----
# Using runtime as base instead of build to force production mode
FROM runtime AS development

# Copy app source files for development
COPY --from=build /app/app /app/app
COPY --from=build /app/public /app/public

# Initialize git repository for development (needed by pre-start.cjs)
RUN git init && \
    git config user.email "dev@bolt.diy" && \
    git config user.name "Dev User" && \
    touch .gitignore && \
    git add .gitignore && \
    git commit -m "Initial commit"

# Define environment variables for development
ARG GROQ_API_KEY
ARG HuggingFace_API_KEY
ARG OPENAI_API_KEY
ARG ANTHROPIC_API_KEY
ARG OPEN_ROUTER_API_KEY
ARG GOOGLE_GENERATIVE_AI_API_KEY
ARG OLLAMA_API_BASE_URL
ARG XAI_API_KEY
ARG TOGETHER_API_KEY
ARG TOGETHER_API_BASE_URL
ARG AWS_BEDROCK_CONFIG
ARG VITE_LOG_LEVEL=debug
ARG DEFAULT_NUM_CTX

ENV GROQ_API_KEY=${GROQ_API_KEY} \
    HuggingFace_API_KEY=${HuggingFace_API_KEY} \
    OPENAI_API_KEY=${OPENAI_API_KEY} \
    ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY} \
    OPEN_ROUTER_API_KEY=${OPEN_ROUTER_API_KEY} \
    GOOGLE_GENERATIVE_AI_API_KEY=${GOOGLE_GENERATIVE_AI_API_KEY} \
    OLLAMA_API_BASE_URL=${OLLAMA_API_BASE_URL} \
    XAI_API_KEY=${XAI_API_KEY} \
    TOGETHER_API_KEY=${TOGETHER_API_KEY} \
    TOGETHER_API_BASE_URL=${TOGETHER_API_BASE_URL} \
    AWS_BEDROCK_CONFIG=${AWS_BEDROCK_CONFIG} \
    VITE_LOG_LEVEL=${VITE_LOG_LEVEL} \
    DEFAULT_NUM_CTX=${DEFAULT_NUM_CTX} \
    RUNNING_IN_DOCKER=true

RUN mkdir -p /app/run
# Make sure all binaries are available anywhere in the container
ENV PATH="/usr/local/bin:${PATH}:/app/node_modules/.bin"
# Make bindings.sh executable
RUN chmod +x /app/bindings.sh
CMD ["pnpm", "run", "dockerstart"]
