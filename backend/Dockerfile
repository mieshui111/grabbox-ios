# GrabBox 后端（可选）：给 iOS 版提供 YouTube / Instagram 的服务端解析
# 用法（在群晖或任意 Docker 机器上）：
#   docker build -t grabbox-backend .
#   docker run -d --name grabbox-backend --restart unless-stopped -p 8421:8421 grabbox-backend
# 手机上填 http://<NAS_IP>:8421
FROM python:3.12-alpine

RUN apk add --no-cache ffmpeg nodejs \
    && pip install --no-cache-dir yt-dlp

WORKDIR /app
COPY server.mjs .
VOLUME /app/dl
EXPOSE 8421

CMD ["node", "server.mjs"]
