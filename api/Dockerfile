FROM node:26-slim
WORKDIR /app
# Node 25 以降は corepack が同梱されないので npm で入れる
RUN npm install -g pnpm@10.33.2
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --prod --frozen-lockfile
COPY src ./src
ENV NODE_ENV=production HOST=0.0.0.0
USER node
# 型を外して直接実行する（ビルドなし）
CMD ["node", "src/main.ts"]
