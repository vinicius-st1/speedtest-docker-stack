FROM nginx:stable-alpine

# Remove o default.conf (e o script que tenta alterá-lo automaticamente)
RUN rm -f /etc/nginx/conf.d/default.conf \
 && rm -f /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh

# Não copiamos config aqui: ela é montada como speedtest.conf (gerada pelo render.py)
