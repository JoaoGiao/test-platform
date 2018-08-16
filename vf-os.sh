#!/bin/sh
#
# Run docker-compose in a container, modified for vf-OS by including our initial compose-file.
#
# This script will attempt to mirror the host paths by using volumes for the
# following paths:
#   * $(pwd)
#   * $(dirname $COMPOSE_FILE) if it's set
#   * $HOME if it's set
#
# You can add additional volumes (or any docker run options) using
# the $COMPOSE_OPTIONS environment variable.
#


set -e

VERSION="1.21.2"
IMAGE="docker/compose:$VERSION"

INITIAL_COMPOSE_FILE=".vfos_compose.yml"
DOCKER_COMPOSE_ALIAS="docker-compose"

cat << EOF > $INITIAL_COMPOSE_FILE
version: '3'

services:
  reverse-proxy:
    image: traefik:latest # The official Traefik docker image
    restart: "unless-stopped"
    command: "--api --docker --docker.watch=true --web"
    ports:
      - "8080:8080"
      - "80:80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - default
      - execution-manager-net
      - system-dashboard-net
      - asset-net-00
      - asset-net-01
      - asset-net-02
      - asset-net-03
      - asset-net-04
      - asset-net-05
      - asset-net-06
      - asset-net-07
      - asset-net-08
      - asset-net-09
      - asset-net-10
      - asset-net-11
  execution-manager:
    image: exec-manager
    restart: "unless-stopped"
    labels:
      - "traefik.frontend.rule=PathPrefixStrip:/executionservices"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $(pwd):$(pwd)
    environment:
      - DOCKER_COMPOSE_PATH=$(pwd)
    networks:
      - execution-manager-net
  aim:
    image: jboss/keycloak
    restart: "unless-stopped"
    command: ["-b", "0.0.0.0","-Dkeycloak.profile.feature.docker=enabled"]
    environment:
      - KEYCLOAK_USER=admin
      - KEYCLOAK_PASSWORD=vf-OS-test
    networks:
      - execution-manager-net
    labels:
      - "traefik.frontend.rule=PathPrefixStrip:/aim"
      - "traefik.frontend.priority=-1"
      - "traefik.port=8080"
      - "traefik.docker.network=execution-manager-net"
  registry:
    image: registry:2
    restart: "unless-stopped"
    networks:
      - execution-manager-net
  portal:
    image: portal
    restart: "unless-stopped"
    labels:
      - "traefik.frontend.rule=PathPrefix:/"
      - "traefik.frontend.priority=-1"
    networks:
      - execution-manager-net
  dashboard:
    image: system-dashboard
    restart: "unless-stopped"
    labels:
      - "traefik.frontend.rule=PathPrefixStrip:/systemdashboard"
      - "traefik.frontend.priority=-1"
    networks:
      - system-dashboard-net

networks:
    execution-manager-net:
       driver: bridge
    system-dashboard-net:
       driver: bridge
    asset-net-00:
       driver: bridge
    asset-net-01:
       driver: bridge
    asset-net-02:
       driver: bridge
    asset-net-03:
       driver: bridge
    asset-net-04:
       driver: bridge
    asset-net-05:
       driver: bridge
    asset-net-06:
       driver: bridge
    asset-net-07:
       driver: bridge
    asset-net-08:
       driver: bridge
    asset-net-09:
       driver: bridge
    asset-net-10:
       driver: bridge
    asset-net-11:
       driver: bridge
EOF

# Setup options for connecting to docker host
if [ -z "$DOCKER_HOST" ]; then
    DOCKER_HOST="/var/run/docker.sock"
fi
if [ -S "$DOCKER_HOST" ]; then
    DOCKER_ADDR="-v $DOCKER_HOST:$DOCKER_HOST -e DOCKER_HOST"
else
    DOCKER_ADDR="-e DOCKER_HOST -e DOCKER_TLS_VERIFY -e DOCKER_CERT_PATH"
fi


# Setup volume mounts for compose config and context
if [ "$(pwd)" != '/' ]; then
    VOLUMES="-v $(pwd):$(pwd)"
fi
if [ -n "$INITIAL_COMPOSE_FILE" ]; then
    cat << EOF > $DOCKER_COMPOSE_ALIAS
#!/bin/sh
/usr/local/bin/docker-compose --file $INITIAL_COMPOSE_FILE \$@

EOF
chmod +x $DOCKER_COMPOSE_ALIAS
    COMPOSE_OPTIONS="$COMPOSE_OPTIONS -e PATH=.:$PATH"
    compose_dir=$(realpath $(dirname $INITIAL_COMPOSE_FILE))
fi
# TODO: also check --file argument
if [ -n "$compose_dir" ]; then
    VOLUMES="$VOLUMES -v $compose_dir:$compose_dir"
fi
if [ -n "$HOME" ]; then
    VOLUMES="$VOLUMES -v $HOME:$HOME -v $HOME:/root" # mount $HOME in /root to share docker.config
fi

# Only allocate tty if we detect one
if [ -t 1 ]; then
    DOCKER_RUN_OPTIONS="-t"
fi
if [ -t 0 ]; then
    DOCKER_RUN_OPTIONS="$DOCKER_RUN_OPTIONS -i"
fi


docker run --detach --name vf_os_platform_exec_control --rm $DOCKER_RUN_OPTIONS $DOCKER_ADDR $COMPOSE_OPTIONS $VOLUMES -w "$(pwd)" --entrypoint=/bin/sh $IMAGE -c 'cat /dev/stdout' &
sleep 5; docker exec vf_os_platform_exec_control docker-compose up &

