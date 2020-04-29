#!/bin/bash

# bash wrappers for docker run commands
# should work on linux, perhaps on OSX
# useful for connecting GUI to container
SOCK=/tmp/.X11-unix
XAUTH=/tmp/.docker.xauth
xauth nlist $DISPLAY | sed -e 's/^..../ffff/' | xauth -f $XAUTH nmerge -
chmod 755 $XAUTH


#
# Helper Functions
#
dcleanup(){
	local containers
	mapfile -t containers < <(docker ps -aq 2>/dev/null)
	docker rm "${containers[@]}" 2>/dev/null
	local volumes
	mapfile -t volumes < <(docker ps --filter status=exited -q 2>/dev/null)
	docker rm -v "${volumes[@]}" 2>/dev/null
	local images
	mapfile -t images < <(docker images --filter dangling=true -q 2>/dev/null)
	docker rmi "${images[@]}" 2>/dev/null
}
del_stopped(){
	local name=$1
	local state
	state=$(docker inspect --format "{{.State.Running}}" "$name" 2>/dev/null)

	if [[ "$state" == "false" ]]; then
		docker rm "$name"
	fi
}
relies_on(){
	for container in "$@"; do
		local state
		state=$(docker inspect --format "{{.State.Running}}" "$container" 2>/dev/null)

		if [[ "$state" == "false" ]] || [[ "$state" == "" ]]; then
			echo "$container is not running, starting it for you."
			$container
		fi
	done
}

relies_on_network(){
    for network in "$@"; do
        local state
        state=$(docker network inspect --format "{{.Created}}" "$network" 2>/dev/null)

        if [[ "$state" == "false" ]] || [[ "$state" == "" ]]; then
            echo "$network is not up, creating it for you."
            docker network create --driver bridge $network
        fi
    done
}

relies_on_volume(){
    for volume in "$@"; do
        local state
        state=$(docker volume inspect --format "{{.CreatedAt}}" "$volume" 2>/dev/null)

        if [[ "$state" == "false" ]] || [[ "$state" == "" ]]; then
            echo "$volume does not exist, creating it."
            docker volume create $volume
        fi
    done
}


postgraphile(){
    relies_on postgres
    relies_on_network postgres_nw
    docker run -it \
           --rm \
           -v ${PWD}:/home/user \
	   -v /etc/localtime:/etc/localtime:ro \
           --user $(id -u):$(id -g) \
           -e "PGPASSWORD=${PGPASSWORD}" \
           -e "PGUSER=${PGUSER}" \
           -e "PGHOST=postgres" \
           -e "PGDATABASE=shopping" \
           -e "PGDATABASE=shopping" \
           --network=postgres_nw \
           --label traefik.enable=true \
           --label traefik.http.services.postgraphile.loadbalancer.server.port=5433 \
           --label traefik.http.routers.postgraphile.entrypoints=postgraphile \
           --label 'traefik.http.routers.postgraphile.rule=PathPrefix(`/`)' \
           --name postgraphile \
           jmarca/postgraphile --port 5433 --schema public --append-plugins postgraphile-plugin-connection-filter
}

postgres(){
    relies_on_network postgres_nw
    relies_on_volume postgres_data

    #       --network=image_uploader_nw \
    echo "postgres password is ${POSTGRES_PASSWORD}"
    docker run -d --rm \
	   -v /etc/localtime:/etc/localtime:ro \
           -v $PWD:/work \
           --mount source=postgres_data,target="/var/lib/postgresql/data" \
           --network=postgres_nw \
           --name postgres \
           jmarca/postgresql:routing

    sleep 2
}

postgres_environment(){
    relies_on postgres
    sleep 1
    docker exec -e PGPASS -e PGUSER -it postgres bash
}


backup_db(){
    relies_on postgres
    relies_on_network postgres_nw
    docker run -it --rm \
	   -v /etc/localtime:/etc/localtime:ro \
           --name dump_db \
           --network=postgres_nw \
           -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
           -v ${PWD}:/data \
           postgres:alpine pg_dump -U postgres -h postgres -Fd image_uploader_dev -j 5 -f /data
}


traefik(){
    relies_on_network postgres_nw

    docker run -it --rm \
           -v $PWD/traefik.toml:/etc/traefik/traefik.toml \
	   -v /etc/localtime:/etc/localtime:ro \
           -v /var/run/docker.sock:/var/run/docker.sock \
           --network=postgres_nw \
           --name traefik \
           traefik
}

sqitch(){
    relies_on_network postgres_nw
    relies_on postgres

    # sqitch related, copied from sqitchers/docker-sqitch

    # Determine which Docker image to run.
    SQITCH_IMAGE=${SQITCH_IMAGE:=jmarca/sqitch:latest}

    # Set up required pass-through variables.
    user=${USER-$(whoami)}
    sqitch_passopt=(
        -e "SQITCH_ORIG_SYSUSER=$user" \
        -e "SQITCH_ORIG_EMAIL=$user@$(hostname)" \
        -e "TZ=$(date +%Z)" \
        -e "LESS=${LESS:--R}"
    )

    # Handle OS-specific options.
    case "$(uname -s)" in
        Linux*)
            sqitch_passopt+=(-e "SQITCH_ORIG_FULLNAME=$(getent passwd $user | cut -d: -f5 | cut -d, -f1)")
            sqitch_passopt+=(-u $(id -u ${user}):$(id -g ${user}))
            ;;
        Darwin*)
            sqitch_passopt+=(-e "SQITCH_ORIG_FULLNAME=$(id -P $user | awk -F '[:]' '{print $8}')")
            ;;
        MINGW*|CYGWIN*)
            sqitch_passopt+=(-e "SQITCH_ORIG_FULLNAME=$(net user $user)")
            ;;
        *)
            echo "Unknown OS: $(uname -s)"
            exit 2
            ;;
    esac

    # Iterate over optional Sqitch and engine variables.
    for var in \
        SQITCH_CONFIG SQITCH_USERNAME SQITCH_PASSWORD SQITCH_FULLNAME SQITCH_EMAIL SQITCH_TARGET \
                      DBI_TRACE \
                      PGUSER PGPASSWORD PGHOST PGHOSTADDR PGPORT PGDATABASE PGSERVICE PGOPTIONS PGSSLMODE PGREQUIRESSL PGSSLCOMPRESSION PGREQUIREPEER PGKRBSRVNAME PGKRBSRVNAME PGGSSLIB PGCONNECT_TIMEOUT PGCLIENTENCODING PGTARGETSESSIONATTRS \
                      MYSQL_PWD MYSQL_HOST MYSQL_TCP_PORT \
                      TNS_ADMIN TWO_TASK ORACLE_SID \
                      ISC_USER ISC_PASSWORD \
                      VSQL_HOST VSQL_PORT VSQL_USER VSQL_PASSWORD VSQL_SSLMODE \
                      SNOWSQL_ACCOUNT SNOWSQL_USER SNOWSQL_PWD SNOWSQL_HOST SNOWSQL_PORT SNOWSQL_DATABASE SNOWSQL_REGION SNOWSQL_WAREHOUSE SNOWSQL_PRIVATE_KEY_PASSPHRASE
    do
        if [ -n "${!var}" ]; then
            sqitch_passopt+=(-e $var)
        fi
    done

    # Determine the name of the container home directory.
    homedst=/home/node
    if [ $(id -u ${user}) -eq 0 ]; then
        homedst=/root
    fi
    # Set HOME, since the user ID likely won't be the same as for the sqitch user.
    sqitch_passopt+=(-e "HOME=${homedst}")

    # Run the container with the current and home directories mounted.
    docker run -it --rm \
           -e TZ \
           --network=postgres_nw \
	   -v /etc/localtime:/etc/localtime:ro \
           --mount "type=bind,src=$(pwd),dst=/work" \
           --mount "type=bind,src=$HOME,dst=$homedst" \
           "${sqitch_passopt[@]}" "$SQITCH_IMAGE" sqitch "$@"
}

pg_prove(){
    relies_on_network postgres_nw
    relies_on postgres

    # sqitch related, copied from sqitchers/docker-sqitch

    # Determine which Docker image to run.
    PGPROVE_IMAGE=${PGPROVE_IMAGE:=jmarca/sqitch:latest}

    # Set up required pass-through variables.
    user=${USER-$(whoami)}
    sqitch_passopt=(
        -e "SQITCH_ORIG_SYSUSER=$user" \
        -e "SQITCH_ORIG_EMAIL=$user@$(hostname)" \
        -e "TZ=$(date +%Z)" \
        -e "LESS=${LESS:--R}"
    )

    # Handle OS-specific options.
    case "$(uname -s)" in
        Linux*)
            sqitch_passopt+=(-e "SQITCH_ORIG_FULLNAME=$(getent passwd $user | cut -d: -f5 | cut -d, -f1)")
            sqitch_passopt+=(-u $(id -u ${user}):$(id -g ${user}))
            ;;
        Darwin*)
            sqitch_passopt+=(-e "SQITCH_ORIG_FULLNAME=$(id -P $user | awk -F '[:]' '{print $8}')")
            ;;
        MINGW*|CYGWIN*)
            sqitch_passopt+=(-e "SQITCH_ORIG_FULLNAME=$(net user $user)")
            ;;
        *)
            echo "Unknown OS: $(uname -s)"
            exit 2
            ;;
    esac

    # Iterate over optional Sqitch and engine variables.
    for var in \
        SQITCH_CONFIG SQITCH_USERNAME SQITCH_PASSWORD SQITCH_FULLNAME SQITCH_EMAIL SQITCH_TARGET \
                      DBI_TRACE \
                      PGUSER PGPASSWORD PGHOST PGHOSTADDR PGPORT PGDATABASE PGSERVICE PGOPTIONS PGSSLMODE PGREQUIRESSL PGSSLCOMPRESSION PGREQUIREPEER PGKRBSRVNAME PGKRBSRVNAME PGGSSLIB PGCONNECT_TIMEOUT PGCLIENTENCODING PGTARGETSESSIONATTRS \
                      MYSQL_PWD MYSQL_HOST MYSQL_TCP_PORT \
                      TNS_ADMIN TWO_TASK ORACLE_SID \
                      ISC_USER ISC_PASSWORD \
                      VSQL_HOST VSQL_PORT VSQL_USER VSQL_PASSWORD VSQL_SSLMODE \
                      SNOWSQL_ACCOUNT SNOWSQL_USER SNOWSQL_PWD SNOWSQL_HOST SNOWSQL_PORT SNOWSQL_DATABASE SNOWSQL_REGION SNOWSQL_WAREHOUSE SNOWSQL_PRIVATE_KEY_PASSPHRASE
    do
        if [ -n "${!var}" ]; then
            sqitch_passopt+=(-e $var)
        fi
    done

    # Determine the name of the container home directory.
    homedst=/home
    if [ $(id -u ${user}) -eq 0 ]; then
        homedst=/root
    fi
    # Set HOME, since the user ID likely won't be the same as for the sqitch user.
    sqitch_passopt+=(-e "HOME=${homedst}")

    # Run the container with the current and home directories mounted.
    docker run -it --rm \
           --network=postgres_nw \
           --mount "type=bind,src=$(pwd),dst=/work" \
           --mount "type=bind,src=$HOME,dst=$homedst" \
           "${sqitch_passopt[@]}" "$PGPROVE_IMAGE" pg_prove test/*.sql
}
npm(){
    relies_on_network postgres_nw
    relies_on postgres

    # sqitch related, copied from sqitchers/docker-sqitch

    # Determine which Docker image to run.
    NPM_IMAGE=${NPM_IMAGE:=jmarca/sqitch:latest}

    # Set up required pass-through variables.
    user=${USER-$(whoami)}
    sqitch_passopt=(
        -e "SQITCH_ORIG_SYSUSER=$user" \
        -e "SQITCH_ORIG_EMAIL=$user@$(hostname)" \
        -e "TZ=$(date +%Z)" \
        -e "LESS=${LESS:--R}"
    )

    # Handle OS-specific options.
    case "$(uname -s)" in
        Linux*)
            sqitch_passopt+=(-e "SQITCH_ORIG_FULLNAME=$(getent passwd $user | cut -d: -f5 | cut -d, -f1)")
            sqitch_passopt+=(-u $(id -u ${user}):$(id -g ${user}))
            ;;
        Darwin*)
            sqitch_passopt+=(-e "SQITCH_ORIG_FULLNAME=$(id -P $user | awk -F '[:]' '{print $8}')")
            ;;
        MINGW*|CYGWIN*)
            sqitch_passopt+=(-e "SQITCH_ORIG_FULLNAME=$(net user $user)")
            ;;
        *)
            echo "Unknown OS: $(uname -s)"
            exit 2
            ;;
    esac

    # Iterate over optional Sqitch and engine variables.
    for var in \
        SQITCH_CONFIG SQITCH_USERNAME SQITCH_PASSWORD SQITCH_FULLNAME SQITCH_EMAIL SQITCH_TARGET \
                      DBI_TRACE \
                      PGUSER PGPASSWORD PGHOST PGHOSTADDR PGPORT PGDATABASE PGSERVICE PGOPTIONS PGSSLMODE PGREQUIRESSL PGSSLCOMPRESSION PGREQUIREPEER PGKRBSRVNAME PGKRBSRVNAME PGGSSLIB PGCONNECT_TIMEOUT PGCLIENTENCODING PGTARGETSESSIONATTRS \
                      MYSQL_PWD MYSQL_HOST MYSQL_TCP_PORT \
                      TNS_ADMIN TWO_TASK ORACLE_SID \
                      ISC_USER ISC_PASSWORD \
                      VSQL_HOST VSQL_PORT VSQL_USER VSQL_PASSWORD VSQL_SSLMODE \
                      SNOWSQL_ACCOUNT SNOWSQL_USER SNOWSQL_PWD SNOWSQL_HOST SNOWSQL_PORT SNOWSQL_DATABASE SNOWSQL_REGION SNOWSQL_WAREHOUSE SNOWSQL_PRIVATE_KEY_PASSPHRASE
    do
        if [ -n "${!var}" ]; then
            sqitch_passopt+=(-e $var)
        fi
    done

    # Determine the name of the container home directory.
    homedst=/home/node
    if [ $(id -u ${user}) -eq 0 ]; then
        homedst=/root
    fi
    # Set HOME, since the user ID likely won't be the same as for the sqitch user.
    sqitch_passopt+=(-e "HOME=${homedst}")

    # Run the container with the current and home directories mounted.
    docker run -it --rm \
           -e TZ \
	   -v /etc/localtime:/etc/localtime:ro \
           --network=postgres_nw \
           --mount "type=bind,src=$(pwd),dst=/work" \
           --mount "type=bind,src=$HOME/.sqitch,dst=$homedst/.sqitch" \
           --mount "type=bind,src=$HOME/.ssh,dst=$homedst/.ssh" \
           --mount "type=bind,src=$HOME/.gitconfig,dst=$homedst/.gitconfig" \
           "${sqitch_passopt[@]}" "$NPM_IMAGE" npm "$@"
}

build_pgprove(){
    docker build -t jmarca/pgprove -f Docker/Dockerfile.pgprove .
}
build_sqitch(){
    docker build -t jmarca/sqitch -f Docker/Dockerfile.sqitch .
}
