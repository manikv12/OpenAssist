FROM node:22.20.0-bookworm-slim

ARG CODEX_VERSION=0.150.1

RUN useradd --create-home --uid 10001 openassist \
  && npm install --global "@openai/codex@${CODEX_VERSION}" \
  && mkdir -p /app /runtime/codex /runtime/empty \
  && chown -R openassist:openassist /app /runtime

WORKDIR /app
COPY package.json ./package.json
RUN npm install --omit=dev --ignore-scripts \
  && npm cache clean --force
COPY container ./container

USER openassist
ENV NODE_ENV=production \
    CODEX_HOME=/runtime/codex \
    OPENASSIST_EMPTY_WORKSPACE=/runtime/empty \
    PORT=8080
EXPOSE 8080

CMD ["node", "container/server.mjs"]
