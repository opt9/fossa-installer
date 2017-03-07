#!/usr/bin/env bash

set +e

if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

TOP_DIR="$(dirname "$(readlink -f "$0")")"

. $TOP_DIR/config.env
. $TOP_DIR/configure.sh

function setup {
  echo "Welcome to the Fossa setup tool! Let's get started"
  echo
  configure_environment
  save_configuration
  setup_system
  download_extensions
  setup_database

  echo
  echo "And we're done! Fossa is ready to be used!"
  echo
}

function save_configuration {
  set | egrep '^((app|db|db_rubygems|github|jira|bitbucket)__.*|secret)=' > $TOP_DIR/config.env
}

function setup_system {
  # Update the registry
  apt-get update
  apt-get -y install apt-transport-https ca-certificates
  apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D

  # Download and install docker, postgres
  # NOTE: Do not use Docker 1.9.1 because of: https://github.com/docker/docker/issues/18180
  grep -Fq "deb https://apt.dockerproject.org/repo ubuntu-trusty main" < /etc/apt/sources.list.d/docker.list || ( touch /etc/apt/sources.list.d/docker.list ; echo "deb https://apt.dockerproject.org/repo ubuntu-trusty main" >> /etc/apt/sources.list.d/docker.list )
  apt-get update
  apt-get purge lxc-docker
  apt-get install -y docker-engine postgresql-9.3 postgresql-contrib-9.3 postgresql-server-dev-9.3 curl tar default-jdk

  # Replace "ubuntu" with your username, if it's different
  usermod -aG docker ubuntu
  usermod -aG docker admin

  # Edit docker config to use "devicemapper" over "aufs" due to issues with aufs on Ubuntu
  grep -Fq "DOCKER_OPTS=\"--storage-driver=devicemapper --storage-opt dm.basesize=20G\"" < /etc/default/docker || ( touch /etc/default/docker ; echo "DOCKER_OPTS=\"--storage-driver=devicemapper --storage-opt dm.basesize=20G\"" >> /etc/default/docker )

  # Configure forwarding
  ufw disable

  # Find the line net.ipv6.conf.default.forwarding=1 and uncomment it (or add it) in the file underneath:
  egrep -q '^\#\s*net\.ipv6\.conf\.(all|default)\.forwarding\=1' /etc/sysctl.conf && sed -i.bk -r 's/^\s*\#net\.ipv6\.conf\.(all|default)\.forwarding\=1/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf
  sysctl -p /etc/sysctl.conf

  restart docker
}

function download_extensions {
   curl -L https://github.com/fossas/pg_fossa/archive/v1.1.tar.gz | tar -zxv -C tools/pg/extensions/ --strip-components=1
}

function setup_database {
  sudo cp tools/pg/extensions/* $( pg_config | grep SHAREDIR | awk '{print $3}' )/extension/

  # In the file below, find the IPv4 host configuration and make sure it looks like this:
  # host    all             all             0.0.0.0/0            md5
  sudo -u postgres mv /etc/postgresql/9.3/main/pg_hba.conf /etc/postgresql/9.3/main/pg_hba.conf.bk
  sudo -u postgres cp $TOP_DIR/pg_hba.conf /etc/postgresql/9.3/main/

  # In this file, find listen_addresses and set it to '0.0.0.0'
  sudo -u postgres mv /etc/postgresql/9.3/main/postgresql.conf /etc/postgresql/9.3/main/postgresql.conf.bk
  sudo -u postgres cp $TOP_DIR/postgresql.conf /etc/postgresql/9.3/main/

  # See http://www.postgresql.org/docs/9.0/static/libpq-pgpass.html
  # hostname:port:database:username:password
  # TODO: Grok tmp dir of system (not always /tmp)
  # PGPASSFILE=/tmp/.fossapgpass
  # echo "$db__hostname:$db__port:$db__database:$db__username:$db__password" > $PGPASSFILE
  sudo -u postgres psql -c "CREATE DATABASE \"$db__database\""
  sudo -u postgres psql -c "CREATE USER $db__username WITH PASSWORD '$db__password';"
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"$db__database\" TO $db__username;"

  sudo -u postgres psql -c "CREATE DATABASE \"$db_rubygems__database\""
  sudo -u postgres psql -c "CREATE USER $db_rubygems__username WITH PASSWORD '$db_rubygems__password';"
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"$db_rubygems__database\" TO $db_rubygems__username;"

  # Install trigram extension
  sudo -u postgres psql fossa -c "CREATE EXTENSION IF NOT EXISTS pg_trgm"

  # Install pg_fossa extension
  sudo -u postgres psql fossa -c "CREATE EXTENSION IF NOT EXISTS pg_fossa"

  service postgresql restart

  # rm $PGPASSFILE
}

setup