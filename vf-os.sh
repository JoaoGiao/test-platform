#!/bin/bash
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
#set -o xtrace

CURRENT_DIR=$(pwd)
if command -v cygpath &> /dev/null; then CURRENT_DIR=`cygpath -aw $(pwd)`; fi

INITIAL_COMPOSE_FILE="0_platform_compose.yml"
NETWORK_COMPOSE_FILE="1_networks_compose.yml"
DOCKER_COMPOSE_ALIAS="docker-compose"
PROJECTNAME="vfos"
PERSISTENT_VOLUME="/persist"

mkdir -p .control_build
cd .control_build

cat << EOF > Dockerfile
FROM docker/compose:1.22.0
RUN apk --no-cache add dumb-init
ENTRYPOINT ["/usr/bin/dumb-init", "-c"]
CMD ["cat","/dev/stdout"]
EOF
docker build . -t vfos/control

cd ../


mkdir -p .compose
mkdir -p .persist
mkdir -p .persist/aim_persist
chown -R 1000:1000 ./.persist/aim_persist

cat << EOF > .compose/$INITIAL_COMPOSE_FILE
version: '3'

services:
  reverse-proxy:
    image: traefik:latest # The official Traefik docker image
    restart: "unless-stopped"
    command: "--api --docker --docker.watch=true --defaultentrypoints=http --entryPoints='Name:http Address::80' --entryPoints='Name:che Address::8081'"
    ports:
      - "8080:8080"
      - "80:80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - default
      - execution-manager-net
      - system-dashboard-net
  registry:
    image: registry:2  #newer versions give "docker-credential-secretservice not installed or not available in PATH"
    restart: "unless-stopped"
    ports:
      - "5000:5000"    #Docker registry's can't handle subpath endpoints, need to be root-level citizen
    networks:
      - execution-manager-net
    volumes:
      - $CURRENT_DIR/.persist/registry_persist:/var/lib/registry
  execution-manager:
    image: localhost:5000/vfos/exec-manager
    restart: "unless-stopped"
    depends_on:
      - registry
    labels:
      - "traefik.frontend.rule=PathPrefixStrip:/executionservices"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $CURRENT_DIR/.compose:/var/run/compose
      - $CURRENT_DIR/.persist/executionservices_persist:$PERSISTENT_VOLUME
    environment:
      - DOCKER_COMPOSE_PATH=/var/run/compose
      - HOST_PWD=$CURRENT_DIR
    networks:
      - execution-manager-net
  aim:
    image: localhost:5000/vfos/aim
    restart: "unless-stopped"
    depends_on:
      - registry
    command: ["-b", "0.0.0.0","-Dkeycloak.profile.feature.docker=enabled", "-Dkeycloak.import=/opt/jboss/vf-OS-realm.json"]
    environment:
      - KEYCLOAK_USER=admin
      - KEYCLOAK_PASSWORD=vf-OS-test
      - PROXY_ADDRESS_FORWARDING=true
    networks:
      - execution-manager-net
    volumes:
      - $CURRENT_DIR/.persist/aim_persist:/opt/jboss/keycloak/standalone/data
    labels:
      - "traefik.frontend.rule=PathPrefix:/aim"
      - "traefik.frontend.priority=-1"
      - "traefik.port=8080"
      - "traefik.docker.network=execution-manager-net"
  deployment:
    image: localhost:5000/vfos/deploy  #newer versions give "docker-credential-secretservice not installed or not available in PATH"
    restart: "unless-stopped"
    depends_on:
      - registry
      - execution-manager
    privileged: true
    labels:
      - "traefik.frontend.rule=PathPrefixStrip:/deployment"
      - "traefik.frontend.priority=-1"
    networks:
      - execution-manager-net
    volumes:
      - $CURRENT_DIR/.persist/deployment_persist:$PERSISTENT_VOLUME
  portal:
    image: localhost:5000/vfos/portal
    restart: "unless-stopped"
    depends_on:
      - registry
    labels:
      - "traefik.frontend.rule=PathPrefix:/"
      - "traefik.frontend.priority=-1"
    networks:
      - execution-manager-net
  dashboard:
    image: localhost:5000/vfos/system-dashboard
    restart: "unless-stopped"
    depends_on:
      - registry
    labels:
      - "traefik.frontend.rule=PathPrefixStrip:/systemdashboard"
      - "traefik.frontend.priority=-1"
    networks:
      - system-dashboard-net
  testserver:
    image: localhost:5000/vfos/test-server
    restart: "unless-stopped"
    depends_on:
      - registry
    labels:
      - "traefik.frontend.rule=PathPrefixStrip:/testserver"
    volumes:
      - $CURRENT_DIR/testImages:/usr/src/app/static
    networks:
      - execution-manager-net
  packager:
    image: localhost:5000/vfos/packaging
    restart: "unless-stopped"
    labels:
      - "traefik.frontend.rule=PathPrefixStrip:/packaging"
    environment:
      - DOCKER_COMPOSE_PATH=/var/run/compose
      - HOST_PWD=$CURRENT_DIR
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $CURRENT_DIR/.compose:/var/run/compose
      - $CURRENT_DIR/.persist/che_data:/data
    depends_on:
      - registry
      - execution-manager
    networks:
      - execution-manager-net
  che:
    image: hub.caixamagica.pt/vfos/studio:latest
    restart: "unless-stopped"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $CURRENT_DIR/.persist/che_data:/data
      - $CURRENT_DIR/.persist/che_conf:/conf
      - $CURRENT_DIR/.persist/che_logs:/logs
    network_mode: host
    environment:
      - CHE_SINGLE_PORT=true
      - CHE_HOST=localhost
      - CHE_DOCKER_IP_EXTERNAL=127.0.0.1
      - CHE_PORT=8081
      - CHE_REGISTRY_HOST=localhost
    labels:
      - vf-OS=true
      - vf-OS.frontendUri=localhost:8081/
      - "traefik.enable=true"
      - "traefik.frontend.entryPoints=che"
  frontend_editor:
    image: gklasen/vfos_frontend_editor:latest
    restart: "unless-stopped"
    labels:
      - "traefik.main.frontend.rule=PathPrefix:/frontend_editor"
      - "traefik.main.port=80"
      - "traefik.iframe.frontend.rule=PathPrefix:/frontend_iframe"
      - "traefik.iframe.port=4201"
    networks:
      - execution-manager-net
  processapi:
    image: informationcatalyst/vfos-process-api
    hostname: processapi
    labels:
      - vf-OS=true
      - "traefik.frontend.rule=PathPrefixStrip:/processapi"
      - "traefik.main.port=5000"
    environment:
      - RUN_TYPE=processapi
      - CorsOrigins=*
      - StorageType=remote
      - RemoteStorageSettings__Address=https://icemain2.hopto.org:7080
      - MarketplaceSettings__Address=https://vfos-datahub.ascora.de/v1
      - StudioSettings__Address=http://172.17.0.1:8081/
  processdesigner:
    image: informationcatalyst/vfos-process-designer
    hostname: processdesigner
    labels:
      - vf-OS=true
      - "traefik.frontend.rule=PathPrefixStrip:/processdesigner"
    environment:
      - "RUN_TYPE=processdesigner"
      - "API_END_POINT=http://localhost/processapi"
    depends_on:
      - processapi
  idm:
    image: vfos/idm
    hostname: idm
    environment:
      - IDM_DB_HOST=security_mysql
    depends_on:
      - security_mysql
    networks:
      - execution-manager-net
  security_mysql:
    image: mysql:5.7.23
    hostname: security_mysql
    volumes:
      - $CURRENT_DIR/security/mysql/data:/var/lib/mysql
    networks:
      - execution-manager-net

EOF

#Setup basic network configuration
./assignNetwork.js

# Setup options for connecting to docker host
if [ -z "$DOCKER_HOST" ]; then
    DOCKER_HOST="/var/run/docker.sock"
fi
if [ -S "$DOCKER_HOST" ]; then
    DOCKER_ADDR="-v $DOCKER_HOST:$DOCKER_HOST -e DOCKER_HOST"
else
    DOCKER_ADDR="-e DOCKER_HOST -e DOCKER_TLS_VERIFY -e DOCKER_CERT_PATH"
fi

# Only allocate tty if we detect one
if [ -t 1 ]; then
    DOCKER_RUN_OPTIONS="-t"
fi
if [ -t 0 ]; then
    DOCKER_RUN_OPTIONS="$DOCKER_RUN_OPTIONS -i"
fi

#Initial startup:
cat << EOF > .compose/$DOCKER_COMPOSE_ALIAS
#!/bin/sh

/usr/local/bin/docker-compose -p $PROJECTNAME \`ls -1 /compose/*.yml | sed -e 's/^/-f /' | tr '\n' ' '\` \$@

EOF
chmod +x .compose/$DOCKER_COMPOSE_ALIAS
COMPOSE_OPTIONS="$COMPOSE_OPTIONS -e PATH=.:/compose:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
VOLUMES="-v $CURRENT_DIR/.compose:/compose"

docker run --detach --name vf_os_platform_exec_control --rm $DOCKER_RUN_OPTIONS $DOCKER_ADDR $COMPOSE_OPTIONS $VOLUMES vfos/control &

until `docker ps | grep -q "vf_os_platform_exec_control"` && [ "`docker inspect -f {{.State.Running}} vf_os_platform_exec_control`"=="true" ]; do
    sleep 0.1;
done;

#Start registry
docker exec vf_os_platform_exec_control docker-compose up --no-recreate --remove-orphans -d registry  &

until `docker ps | grep -q "vfos_registry_1"` && [ "`docker inspect -f {{.State.Running}} vfos_registry_1`"=="true" ]; do
    sleep 0.1;
done;

if [[ "$1" == "dev" ]]; then
    #Only start the registry, for building support
    echo "Started registry."
else
    #Start everything
    docker exec vf_os_platform_exec_control docker-compose up --no-recreate --remove-orphans -d ;
fi
