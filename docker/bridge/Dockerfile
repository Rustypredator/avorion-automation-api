# FrankenPHP is Caddy with PHP embedded, so the web server and the bridge that writes
# the galaxy's request files are one process.
FROM dunglas/frankenphp:1-php8.3-alpine

# Lets Caddy bind :80 and :443 when the container runs as an unprivileged user, which
# it does whenever BRIDGE_USER is set to the account the game server runs as.
RUN apk add --no-cache libcap \
    && setcap cap_net_bind_service=+ep /usr/local/bin/frankenphp

# The history store talks to Postgres, and the base image ships only pdo_sqlite. This
# pulls libpq in with it. install-php-extensions comes with the FrankenPHP image and
# handles the build dependencies, so nothing here needs a second build stage.
RUN install-php-extensions pdo_pgsql

COPY php.ini /usr/local/etc/php/conf.d/bridge.ini
COPY public/ /app/public/

# Outside the web root on purpose. Caddy's php_server executes any .php file it can find
# under /app/public, so a library that only makes sense when index.php includes it does
# not belong there - and poll.php, which runs as its own service, would be an endpoint
# anyone could trigger.
COPY src/ /app/src/
