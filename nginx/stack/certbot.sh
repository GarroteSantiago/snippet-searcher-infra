#!/bin/sh
# Certificado de Let's Encrypt para $DOMAIN: lo emite la primera vez y después intenta renovarlo
# cada 12 h (certbot renew solo renueva los que vencen en menos de 30 días). Desafío HTTP-01 por
# el webroot que NGINX sirve en el puerto 80. LETSENCRYPT_STAGING=true usa el entorno de prueba
# (sin límites, pero el navegador no confía en el certificado).
set -u

staging=""
[ "${LETSENCRYPT_STAGING:-false}" = true ] && staging=--staging

until [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; do
    # shellcheck disable=SC2086
    certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
        --email "$LETSENCRYPT_EMAIL" --agree-tos --non-interactive $staging && break
    # Let's Encrypt limita los intentos fallidos (5 por hora): no reintentar más seguido
    echo "No se pudo emitir el certificado de $DOMAIN; reintento en 15 minutos" >&2
    sleep 900
done

while :; do
    sleep 43200
    certbot renew --webroot -w /var/www/certbot
done
