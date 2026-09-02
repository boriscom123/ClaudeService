# Node 24 «Krypton» — актуальный LTS (поддержка до апреля 2028).
# Node 20 снят с поддержки в апреле 2026, обновление обязательное, не косметическое.
FROM node:24-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
EXPOSE 3002
CMD ["node", "index.js"]
