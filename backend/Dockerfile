FROM node:20-alpine AS base
WORKDIR /app

# Install dependencies
FROM base AS deps
COPY package*.json ./
RUN npm ci --omit=dev

# Build stage (generate Prisma client)
FROM base AS builder
RUN apk add --no-cache openssl
COPY package*.json ./
RUN npm ci
COPY . .
RUN npx prisma generate

# Production stage
FROM base AS runner
ENV NODE_ENV=production
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

RUN apk add --no-cache openssl

COPY --from=deps /app/node_modules ./node_modules
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
COPY . .

EXPOSE 3000

# prisma/migrations/ is not committed to the repo, so `migrate deploy` alone
# would leave a fresh database without tables. Fall back to `db push`, which
# syncs the schema directly (and refuses destructive changes).
CMD ["sh", "-c", "if ls prisma/migrations/*/migration.sql >/dev/null 2>&1; then npx prisma migrate deploy; else npx prisma db push --skip-generate; fi && node src/index.js"]
