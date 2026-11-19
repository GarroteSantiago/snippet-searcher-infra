#!/bin/sh
# NGINX en Swarm. Arranca con el puerto 80 solo (desafío de Let's Encrypt) hasta que certbot deja
# el certificado de $DOMAIN en el volumen compartido; entonces suma el 443. Con el 443 prendido
# recarga cada 12 h para tomar los certificados renovados.
set -eu

cert=/etc/letsencrypt/live/$DOMAIN/fullchain.pem

render() {
    # shellcheck disable=SC2016 # envsubst recibe el nombre literal, no su valor
    envsubst '$DOMAIN' < "/etc/nginx/stack/$1.conf.template" > "/etc/nginx/conf.d/$1.conf"
}

rm -f /etc/nginx/conf.d/*.conf
render http
[ -f "$cert" ] && render https

(
    while :; do
        if [ -f /etc/nginx/conf.d/https.conf ]; then
            sleep 43200
        else
            sleep 30
            [ -f "$cert" ] || continue
            render https
            echo "Certificado de $DOMAIN encontrado: HTTPS prendido"
        fi
        nginx -s reload
    done
) &

exec nginx -g 'daemon off;'
