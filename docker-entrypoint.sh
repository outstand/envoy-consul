#!/usr/bin/env sh
set -e

# You can set CONSUL_BIND_INTERFACE to the name of the interface you'd like to
# bind to and this will look up the IP and pass the proper -bind= option along
# to Consul.
CONSUL_BIND=
if [ -n "$CONSUL_BIND_INTERFACE" ]; then
  CONSUL_BIND_ADDRESS=$(ip -o -4 addr list $CONSUL_BIND_INTERFACE | head -n1 | awk '{print $4}' | cut -d/ -f1)
  if [ -z "$CONSUL_BIND_ADDRESS" ]; then
    echo "Could not find IP for interface '$CONSUL_BIND_INTERFACE', exiting"
    exit 1
  fi

  CONSUL_BIND="-bind=$CONSUL_BIND_ADDRESS"
  echo "==> Found address '$CONSUL_BIND_ADDRESS' for interface '$CONSUL_BIND_INTERFACE', setting bind option..."
fi

# You can set CONSUL_CLIENT_INTERFACE to the name of the interface you'd like to
# bind client intefaces (HTTP, DNS, and RPC) to and this will look up the IP and
# pass the proper -client= option along to Consul.
CONSUL_CLIENT=
if [ -n "$CONSUL_CLIENT_INTERFACE" ]; then
  CONSUL_CLIENT_ADDRESS=$(ip -o -4 addr list $CONSUL_CLIENT_INTERFACE | head -n1 | awk '{print $4}' | cut -d/ -f1)
  if [ -z "$CONSUL_CLIENT_ADDRESS" ]; then
    echo "Could not find IP for interface '$CONSUL_CLIENT_INTERFACE', exiting"
    exit 1
  fi

  CONSUL_CLIENT="-client=$CONSUL_CLIENT_ADDRESS"
  echo "==> Found address '$CONSUL_CLIENT_ADDRESS' for interface '$CONSUL_CLIENT_INTERFACE', setting client option..."
fi

# CONSUL_DATA_DIR is exposed as a volume for possible persistent storage. The
# CONSUL_CONFIG_DIR isn't exposed as a volume but you can compose additional
# config files in there if you use this image as a base, or use CONSUL_LOCAL_CONFIG
# below.
CONSUL_DATA_DIR=/consul/data
CONSUL_CONFIG_DIR=/consul/config

# You can also set the CONSUL_LOCAL_CONFIG environemnt variable to pass some
# Consul configuration JSON without having to bind any volumes.
if [ -n "$CONSUL_LOCAL_CONFIG" ]; then
	echo "$CONSUL_LOCAL_CONFIG" > "$CONSUL_CONFIG_DIR/local.json"
fi

# If the user is trying to run Consul directly with some arguments, then
# pass them to Consul.
if [ "${1:0:1}" = '-' ]; then
    set -- consul "$@"
fi

# Look for Consul subcommands.
if [ "$1" = 'agent' ]; then
    shift
    set -- consul agent \
        -data-dir="$CONSUL_DATA_DIR" \
        -config-dir="$CONSUL_CONFIG_DIR" \
        $CONSUL_BIND \
        $CONSUL_CLIENT \
        "$@"
elif [ "$1" = 'version' ]; then
    # This needs a special case because there's no help output.
    set -- consul "$@"
elif consul --help "$1" 2>&1 | grep -q "consul $1"; then
    # We can't use the return code to check for the existence of a subcommand, so
    # we have to use grep to look for a pattern in the help output.
    set -- consul "$@"
fi

# If we are running Consul, make sure it executes as the proper user.
if [ "$1" = 'consul' -a -z "${CONSUL_DISABLE_PERM_MGMT+x}" ]; then
    # If the data or config dirs are bind mounted then chown them.
    # Note: This checks for root ownership as that's the most common case.
    if [ "$(stat -c %u "$CONSUL_DATA_DIR")" != "$(id -u consul)" ]; then
        chown consul:consul "$CONSUL_DATA_DIR"
    fi
    if [ "$(stat -c %u "$CONSUL_CONFIG_DIR")" != "$(id -u consul)" ]; then
        chown consul:consul "$CONSUL_CONFIG_DIR"
    fi

    # If requested, set the capability to bind to privileged ports before
    # we drop to the non-root user. Note that this doesn't work with all
    # storage drivers (it won't work with AUFS).
    if [ ! -z ${CONSUL_ALLOW_PRIVILEGED_PORTS+x} ]; then
        setcap "cap_net_bind_service=+ep" /bin/consul
        setcap "cap_net_bind_service=+ep" /usr/local/bin/envoy
    fi

    set -- su-exec consul:consul "$@"
fi



if [ "$ENVOY_UID" != "0" ]; then
    if [ -n "$ENVOY_UID" ]; then
        usermod -u "$ENVOY_UID" consul
    fi
    if [ -n "$ENVOY_GID" ]; then
        groupmod -g "$ENVOY_GID" consul
    fi
    # Ensure the envoy user is able to write to container logs
    # chown envoy:envoy /dev/stdout /dev/stderr
fi

if [ "$1" = 'envoy' ]; then
        # set the log level if the $loglevel variable is set
        if [ -n "$loglevel" ]; then
                set -- "$@" --log-level "$loglevel"
        fi
    set -- su-exec consul:consul "$@"
fi

if [ "$1" = 'start-proxy' ]; then
  set -x
  echo Starting envoy proxy

  consul connect envoy -envoy-version $ENVOY_VERSION -gateway=ingress -http-addr 192.168.65.3:8500 -grpc-addr 192.168.65.3:8502 || true
else
  exec "$@"
fi
