# FrankenPHP is Caddy with PHP embedded, so the web server and the bridge that writes
# the galaxy's request files are one process.
FROM dunglas/frankenphp:1-php8.3-alpine

# Lets Caddy bind :80 and :443 when the container runs as an unprivileged user, which
# it does whenever BRIDGE_USER is set to the account the game server runs as.
RUN apk add --no-cache libcap \
    && setcap cap_net_bind_service=+ep /usr/local/bin/frankenphp

COPY php.ini /usr/local/etc/php/conf.d/bridge.ini
COPY public/ /app/public/
