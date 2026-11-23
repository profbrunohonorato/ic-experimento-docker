# syntax=docker/dockerfile:1

# Imagens-base fixadas por digest (referências validadas em 2026-11-23).
# A tag fica apenas como documentação; o digest é o que garante o conteúdo.

# Etapa 1 — Build: Node.js instala dependências e gera os arquivos estáticos.
FROM node:22-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a AS build

WORKDIR /app

# Copiar apenas os manifestos antes do código preserva o cache da camada
# de dependências enquanto package*.json não mudar.
COPY package*.json ./
RUN npm install -g npm@11.21.1 \
    && npm ci

COPY . .
RUN npm run build

# Etapa 2 — Execução: somente Nginx e o conteúdo de dist/, sem Node.js.
FROM nginx:alpine@sha256:fb4658584bd9a916ffb6f6e365f97c25cfdb2923801f551ea08356e695f14ff7

COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80
