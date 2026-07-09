FROM node:22-alpine AS base
RUN corepack enable && corepack prepare pnpm@10.26.2 --activate
WORKDIR /app

FROM base AS deps
# pnpm-workspace.yaml carries the overrides config the lockfile was
# resolved against — without it --frozen-lockfile fails with
# ERR_PNPM_LOCKFILE_CONFIG_MISMATCH
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

FROM base AS build
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN pnpm build

FROM node:22-alpine AS production
RUN npm install -g serve@14
COPY --from=build /app/dist /app
EXPOSE 3000
CMD ["serve", "/app", "-l", "3000"]
