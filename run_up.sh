#!/usr/bin/env bash
COMPOSE_BIN=/usr/local/bin/docker-compose
SERVICE_FILE=/Users/dmitrykar/tra_cicd/service.yml
INTERVAL=10

start(){
    echo "Starting infra services: consul, cassandra, kafka, ZK, postgres"
    $COMPOSE_BIN -f $SERVICE_FILE up -d consul cassandra kafka zk postgres

    echo "Waiting for $INTERVAL seconds until infra services become up"
    SLEEP $INTERVAL

    echo "Populating configs for consul service"
    $COMPOSE_BIN -f $SERVICE_FILE exec consul bash /tmp/consul_init.sh

    echo "Creating SSIDATA user and DB"
    $COMPOSE_BIN -f $SERVICE_FILE exec postgres psql -U postgres -f /tmp/ssidata_init.sql

    echo "Create SSI schema"
    $COMPOSE_BIN -f $SERVICE_FILE exec postgres psql -U postgres -d ssidata -a -f /tmp/ssi_schema.sql

    echo ""
    echo "Starting Netting and SSI services"
    $COMPOSE_BIN -f $SERVICE_FILE up -d netting ssi

    set_ect_hosts
}

stop(){
    echo "Stopping and removing all services"
    $COMPOSE_BIN -f $SERVICE_FILE down
    remove_etc_hosts

}

status(){

    $COMPOSE_BIN -f $SERVICE_FILE ps
}

set_ect_hosts(){
    echo "127.0.0.1 zk kafka cassandra consul postgres netting ssi" >> /etc/hosts
}

remove_etc_hosts(){
    grep -v "127.0.0.1 zk kafka cassandra consul postgres netting ssi" /etc/hosts > /tmp/hosts; sudo mv /tmp/hosts /etc/hosts
}

case $1 in
        start)
                start
                status
                ;;
        stop)
                stop
                ;;
        restart)
                stop
                start
                ;;
        status)
                status
                ;;
        *)
        echo "Not supported params. Use one of the following: start|stop|restart|status "
        exit
esac
