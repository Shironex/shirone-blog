FROM node:22-alpine AS base
RUN corepack enable && corepack prepare pnpm@10.9.0 --activate
WORKDIR /app

FROM base AS deps
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

FROM base AS build
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN pnpm build

FROM node:22-alpine AS production
RUN npm install -g serve@14
COPY --from=build /app/dist /app
EXPOSE 3000
CMD ["serve", "-s", "/app", "-l", "3000"]
