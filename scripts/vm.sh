#!/usr/bin/env bash
# Prende, apaga o muestra las VMs de Azure. Quedan apagadas (deallocated: sin costo de cómputo,
# la IP y el dominio no cambian) y se prenden para usarlas. Al prender, Swarm levanta el stack
# solo y además se corre el workflow Deploy, para tomar lo que se mergeó con la VM apagada.
# Azure las apaga igual todas las noches (auto-shutdown), por si queda alguna prendida.
#
#   scripts/vm.sh start dev     scripts/vm.sh stop all     scripts/vm.sh status
set -euo pipefail

RESOURCE_GROUP=snippet-searcher
REPO=GarroteSantiago/snippet-searcher-infra
USER_NAME=azureuser

action=${1:-status}
target=${2:-all}
case "$target" in
    all) envs=(dev prod) ;;
    dev | prod) envs=("$target") ;;
    *) echo "uso: scripts/vm.sh start|stop|status [dev|prod|all]" >&2; exit 1 ;;
esac

vm() { echo "snippet-searcher-$1"; }
fqdn() { az vm show -d -g "$RESOURCE_GROUP" -n "$(vm "$1")" --query fqdns -o tsv; }

case "$action" in
    start)
        for env in "${envs[@]}"; do az vm start -g "$RESOURCE_GROUP" -n "$(vm "$env")" --no-wait; done
        for env in "${envs[@]}"; do
            az vm wait -g "$RESOURCE_GROUP" -n "$(vm "$env")" --custom "instanceView.statuses[?code=='PowerState/running']" --interval 5
            host=$(fqdn "$env")
            until ssh -o ConnectTimeout=5 -o BatchMode=yes "$USER_NAME@$host" true 2>/dev/null; do sleep 3; done
            gh workflow run deploy.yml -R "$REPO" -f environment="$env"
            echo "$env prendida: https://$host (desplegando lo último: gh run list -R $REPO --workflow deploy.yml)"
        done
        ;;
    stop)
        for env in "${envs[@]}"; do az vm deallocate -g "$RESOURCE_GROUP" -n "$(vm "$env")" --no-wait; done
        for env in "${envs[@]}"; do
            az vm wait -g "$RESOURCE_GROUP" -n "$(vm "$env")" --custom "instanceView.statuses[?code=='PowerState/deallocated']" --interval 5
            echo "$env apagada"
        done
        ;;
    status)
        for env in "${envs[@]}"; do
            printf '%-5s %s\n' "$env" "$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$(vm "$env")" --query "instanceView.statuses[?starts_with(code, 'PowerState')].displayStatus | [0]" -o tsv)"
        done
        ;;
    *) echo "uso: scripts/vm.sh start|stop|status [dev|prod|all]" >&2; exit 1 ;;
esac
